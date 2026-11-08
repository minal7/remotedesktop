#if DEBUG
import AppKit
import ApplicationServices
import CoreFoundation
import Foundation

struct AgentEvalFocusProbeRequest {
    let expectedPID: pid_t

    static func decodeStrict(_ data: Data) throws -> Self {
        guard data.count <= 4_096,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["operation", "expected_pid"],
              object["operation"] as? String == "focus_probe",
              let number = object["expected_pid"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue > 0, number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue <= Double(Int32.max) else { throw AgentEvalWireError.invalidRequest }
        return .init(expectedPID: pid_t(number.int32Value))
    }
}

struct AgentEvalFocusProbeAttribute: Encodable {
    let attempted: Bool
    let timeoutSetErrorCode: Int32?
    let axErrorCode: Int32?
    let elapsedMilliseconds: Double?
    let typeValid: Bool?
    let pid: Int32?
    let string: String?
    let boolean: Bool?
    let reason: String?

    private enum CodingKeys: String, CodingKey {
        case attempted, pid, string, boolean, reason
        case timeoutSetErrorCode = "timeout_set_error_code"
        case axErrorCode = "ax_error_code"
        case elapsedMilliseconds = "elapsed_ms"
        case typeValid = "type_valid"
    }

    static func skipped(_ reason: String) -> Self {
        .init(attempted: false, timeoutSetErrorCode: nil, axErrorCode: nil,
              elapsedMilliseconds: nil, typeValid: nil, pid: nil, string: nil,
              boolean: nil, reason: reason)
    }
}

struct AgentEvalFocusProbeSample: Encodable {
    let root: String
    let budgetMilliseconds: Int
    let focusedElement: AgentEvalFocusProbeAttribute
    let elementPID: AgentEvalFocusProbeAttribute
    let role: AgentEvalFocusProbeAttribute
    let subrole: AgentEvalFocusProbeAttribute
    let protectedContent: AgentEvalFocusProbeAttribute

    private enum CodingKeys: String, CodingKey {
        case root, role, subrole
        case budgetMilliseconds = "budget_ms"
        case focusedElement = "focused_element"
        case elementPID = "element_pid"
        case protectedContent = "protected_content"
    }
}

struct AgentEvalFocusProbeResponse: Encodable {
    let operation = "focus_probe"
    let axTrusted: Bool
    let expectedPID: Int32
    let frontmostPIDBefore: Int32?
    let frontmostPIDAfter: Int32?
    let elapsedMilliseconds: Double
    let abandoned: Bool
    let reason: String?
    let inputEventsPosted = 0
    let samples: [AgentEvalFocusProbeSample]
    let axFocusDiagnostics: AgentEvalFocusDiagnostics?

    private enum CodingKeys: String, CodingKey {
        case operation, abandoned, reason, samples
        case axFocusDiagnostics = "ax_focus_diagnostics"
        case axTrusted = "ax_trusted"
        case expectedPID = "expected_pid"
        case frontmostPIDBefore = "frontmost_pid_before"
        case frontmostPIDAfter = "frontmost_pid_after"
        case elapsedMilliseconds = "elapsed_ms"
        case inputEventsPosted = "input_events_posted"
    }
}

struct AgentEvalFocusDiagnostics: Encodable {
    struct Element: Encodable {
        let attributeError: Int32?
        let typeValid: Bool?
        let ownerPID: Int32?
        let role: String?
        let bounds: [Double]?
        let matchingWindowID: UInt32?

        private enum CodingKeys: String, CodingKey {
            case role, bounds
            case attributeError = "attribute_error"
            case typeValid = "type_valid"
            case ownerPID = "owner_pid"
            case matchingWindowID = "matching_window_id"
        }
    }

    struct Parent: Encodable {
        let role: String?
        let ownerPID: Int32?
        let matchesFocusedWindow: Bool
        let matchesMainWindow: Bool
    }

    let focusedWindow: Element?
    let mainWindow: Element?
    let focusedUIElement: Element?
    let focusedElementWindow: Element?
    let focusParents: [Parent]
    let parentWalkComplete: Bool
    let elapsedMilliseconds: Double

    private enum CodingKeys: String, CodingKey {
        case focusedWindow = "focused_window"
        case mainWindow = "main_window"
        case focusedUIElement = "focused_ui_element"
        case focusedElementWindow = "focused_element_window"
        case focusParents = "focus_parents"
        case parentWalkComplete = "parent_walk_complete"
        case elapsedMilliseconds = "elapsed_ms"
    }
}

@MainActor
enum AgentEvalFocusProbe {
    private static let totalLimit: Duration = .milliseconds(1_500)
    private static let diagnosticLimit: Duration = .milliseconds(300)
    private enum ProbeError: Error { case stop(String), timeoutSet(Int32) }

    static func run(_ request: AgentEvalFocusProbeRequest) -> AgentEvalFocusProbeResponse {
        let clock = ContinuousClock(), started = clock.now, deadline = started + totalLimit
        let trusted = AXIsProcessTrusted()
        let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var reason: String?
        var abandoned = false
        var samples: [AgentEvalFocusProbeSample] = []
        var focusDiagnostics: AgentEvalFocusDiagnostics?
        if !trusted { reason = "Accessibility is unavailable; no prompt was requested." }
        else if before != request.expectedPID { reason = "Expected process is not frontmost; no AX query was made." }
        else {
            do {
                for (name, timeout) in [("systemwide", 100), ("systemwide", 10),
                                        ("application", 100), ("application", 10)] {
                    try checkFrontmost(request.expectedPID)
                    let root = name == "systemwide"
                        ? AXUIElementCreateSystemWide() : AXUIElementCreateApplication(request.expectedPID)
                    do {
                        samples.append(try sample(root, name: name, budget: timeout,
                                                  expectedPID: request.expectedPID, deadline: deadline))
                    } catch ProbeError.stop(let stopReason) {
                        throw ProbeError.stop("sample \(name)/\(timeout) aborted; partial reads omitted. \(stopReason)")
                    }
                }
                // Optional diagnostic reads are capped separately and never affect probe admission.
                focusDiagnostics = try diagnoseFocus(expectedPID: request.expectedPID)
            } catch ProbeError.stop(let stopReason) {
                abandoned = true
                reason = stopReason
            } catch {
                abandoned = true
                reason = "The probe stopped before all metadata could be read."
            }
        }
        let after = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if before != after {
            abandoned = true
            reason = "Frontmost process changed during the probe."
        }
        let beforePID: Int32? = before.map { Int32($0) }
        let afterPID: Int32? = after.map { Int32($0) }
        let elapsedMilliseconds: Double = millis(started.duration(to: clock.now))
        let response = AgentEvalFocusProbeResponse(axTrusted: trusted,
            expectedPID: Int32(request.expectedPID), frontmostPIDBefore: beforePID,
            frontmostPIDAfter: afterPID, elapsedMilliseconds: elapsedMilliseconds,
            abandoned: abandoned, reason: reason, samples: samples,
            axFocusDiagnostics: focusDiagnostics)
        return response
    }

    private static func diagnoseFocus(expectedPID: pid_t) throws -> AgentEvalFocusDiagnostics {
        let started = ContinuousClock.now
        let deadline = started + diagnosticLimit
        let app = AXUIElementCreateApplication(expectedPID)
        let focusedWindow = try diagnosticElement(kAXFocusedWindowAttribute as CFString,
                                                   from: app, expectedPID: expectedPID, deadline: deadline)
        let mainWindow = try diagnosticElement(kAXMainWindowAttribute as CFString,
                                               from: app, expectedPID: expectedPID, deadline: deadline)
        let focus = try diagnosticElement(kAXFocusedUIElementAttribute as CFString,
                                         from: app, expectedPID: expectedPID, deadline: deadline)
        let ownWindow: AgentEvalFocusDiagnostics.Element?
        if let focusElement = focus.element {
            ownWindow = try diagnosticElement(kAXWindowAttribute as CFString, from: focusElement,
                                              expectedPID: expectedPID, deadline: deadline).metadata
        } else {
            ownWindow = nil
        }

        var parents: [AgentEvalFocusDiagnostics.Parent] = []
        var current = focus.element
        var complete = current == nil
        for _ in 0..<8 {
            guard let element = current, ContinuousClock.now < deadline else { break }
            let parent = try diagnosticElement(kAXParentAttribute as CFString, from: element,
                                               expectedPID: expectedPID, deadline: deadline)
            guard let parentElement = parent.element else { complete = true; break }
            try checkFrontmost(expectedPID)
            let role = try diagnosticScalar(kAXRoleAttribute as CFString, from: parentElement,
                                            expectedPID: expectedPID, deadline: deadline)
            var pid: pid_t = 0
            let pidError = AXUIElementGetPid(parentElement, &pid)
            try checkFrontmost(expectedPID)
            parents.append(.init(role: role.value, ownerPID: pidError == .success ? Int32(pid) : nil,
                matchesFocusedWindow: focusedWindow.element.map { CFEqual(parentElement, $0) } ?? false,
                matchesMainWindow: mainWindow.element.map { CFEqual(parentElement, $0) } ?? false))
            current = parentElement
        }
        if current != nil && !complete && parents.count == 8 { complete = false }
        try checkFrontmost(expectedPID)
        return .init(focusedWindow: focusedWindow.metadata, mainWindow: mainWindow.metadata,
            focusedUIElement: focus.metadata, focusedElementWindow: ownWindow, focusParents: parents,
            parentWalkComplete: complete, elapsedMilliseconds: millis(started.duration(to: .now)))
    }

    private struct DiagnosticElementResult {
        let metadata: AgentEvalFocusDiagnostics.Element?
        let element: AXUIElement?
    }

    private struct DiagnosticScalarResult {
        let value: String?
        let error: Int32?
        let valid: Bool?
    }

    private struct DiagnosticCopyResult {
        let value: CFTypeRef?
        let error: Int32?
    }

    private static func diagnosticElement(_ attribute: CFString, from source: AXUIElement,
                                         expectedPID: pid_t, deadline: ContinuousClock.Instant) throws
        -> DiagnosticElementResult {
        try checkFrontmost(expectedPID)
        let copied = try diagnosticCopy(attribute, from: source, expectedPID: expectedPID,
                                        deadline: deadline)
        guard let value = copied.value else {
            return .init(metadata: .init(attributeError: copied.error, typeValid: nil,
                ownerPID: nil, role: nil, bounds: nil, matchingWindowID: nil), element: nil)
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return .init(metadata: .init(attributeError: copied.error, typeValid: false,
                ownerPID: nil, role: nil, bounds: nil, matchingWindowID: nil), element: nil)
        }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        try checkFrontmost(expectedPID)
        var pid: pid_t = 0
        let pidError = AXUIElementGetPid(element, &pid)
        guard pidError == .success, pid == expectedPID else {
            return .init(metadata: .init(attributeError: copied.error, typeValid: true,
                ownerPID: pidError == .success ? Int32(pid) : nil, role: nil, bounds: nil,
                matchingWindowID: nil), element: element)
        }
        let roleResult = try diagnosticScalar(kAXRoleAttribute as CFString, from: element,
                                              expectedPID: expectedPID, deadline: deadline)
        let bounds = try diagnosticBounds(element, expectedPID: expectedPID, deadline: deadline)
        let windowID: UInt32?
        if roleResult.value == (kAXWindowRole as String), let bounds {
            try checkFrontmost(expectedPID)
            windowID = AgentMacAccessibility.matchingWindowID(ownerPID: Int32(pid), bounds: bounds,
                                                               focusedTitle: nil, requireUnique: true)
        } else {
            windowID = nil
        }
        return .init(metadata: .init(attributeError: copied.error, typeValid: true,
            ownerPID: pidError == .success ? Int32(pid) : nil, role: roleResult.value,
            bounds: bounds.map { [Double($0.origin.x), Double($0.origin.y), Double($0.width), Double($0.height)] },
            matchingWindowID: windowID), element: element)
    }

    private static func diagnosticScalar(_ attribute: CFString, from element: AXUIElement,
                                         expectedPID: pid_t, deadline: ContinuousClock.Instant) throws
        -> DiagnosticScalarResult {
        let copied = try diagnosticCopy(attribute, from: element, expectedPID: expectedPID,
                                        deadline: deadline)
        guard let value = copied.value else {
            return .init(value: nil, error: copied.error, valid: nil)
        }
        guard CFGetTypeID(value) == CFStringGetTypeID(), let role = value as? String else {
            return .init(value: nil, error: copied.error, valid: false)
        }
        return .init(value: String(role.prefix(80)), error: copied.error, valid: true)
    }

    private static func diagnosticBounds(_ element: AXUIElement, expectedPID: pid_t,
                                         deadline: ContinuousClock.Instant) throws -> CGRect? {
        guard let positionValue = try diagnosticCopy(kAXPositionAttribute as CFString, from: element,
                expectedPID: expectedPID, deadline: deadline).value,
              let sizeValue = try diagnosticCopy(kAXSizeAttribute as CFString, from: element,
                expectedPID: expectedPID, deadline: deadline).value,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func diagnosticCopy(_ attribute: CFString, from element: AXUIElement,
                                       expectedPID: pid_t, deadline: ContinuousClock.Instant) throws
        -> DiagnosticCopyResult {
        try checkFrontmost(expectedPID)
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { return .init(value: nil, error: nil) }
        let timeout = min(0.015, durationSeconds(remaining))
        guard timeout > 0 else { return .init(value: nil, error: nil) }
        let timeoutError = AXUIElementSetMessagingTimeout(element, Float(timeout))
        guard timeoutError == .success else { return .init(value: nil, error: timeoutError.rawValue) }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        try checkFrontmost(expectedPID)
        guard error == .success else { return .init(value: nil, error: error.rawValue) }
        return .init(value: value, error: error.rawValue)
    }

    private static func sample(_ root: AXUIElement, name: String, budget: Int,
                               expectedPID: pid_t, deadline: ContinuousClock.Instant) throws
        -> AgentEvalFocusProbeSample {
        let focus = try copyAttribute(kAXFocusedUIElementAttribute as CFString, from: root,
                                  budget: budget, expectedPID: expectedPID, deadline: deadline,
                                  expectedType: AXUIElementGetTypeID())
        guard let element = focus.element else {
            return .init(root: name, budgetMilliseconds: budget, focusedElement: focus.record,
                elementPID: .skipped(focus.record.reason ?? "No focus element returned."),
                role: .skipped(focus.record.reason ?? "No focus element returned."),
                subrole: .skipped(focus.record.reason ?? "No focus element returned."),
                protectedContent: .skipped(focus.record.reason ?? "No focus element returned."))
        }
        try checkFrontmost(expectedPID)
        let pid = try elementPID(element, expectedPID: expectedPID)
        let role = try scalarAttribute(kAXRoleAttribute as CFString, from: element, budget: budget,
                                   expectedPID: expectedPID, deadline: deadline, kind: .string)
        let subrole = try scalarAttribute(kAXSubroleAttribute as CFString, from: element, budget: budget,
                                      expectedPID: expectedPID, deadline: deadline, kind: .string)
        let protected = try scalarAttribute("AXProtectedContent" as CFString, from: element, budget: budget,
                                        expectedPID: expectedPID, deadline: deadline, kind: .boolean)
        return .init(root: name, budgetMilliseconds: budget, focusedElement: focus.record,
                     elementPID: pid, role: role, subrole: subrole, protectedContent: protected)
    }

    private struct CopyResult {
        let record: AgentEvalFocusProbeAttribute
        let element: AXUIElement?
    }

    private static func copyAttribute(_ attribute: CFString, from element: AXUIElement, budget: Int,
                                      expectedPID: pid_t, deadline: ContinuousClock.Instant,
                                      expectedType: CFTypeID) throws -> CopyResult {
        do {
            let timeoutSetCode = try prepare(element, budget: budget, expectedPID: expectedPID, deadline: deadline)
            let started = ContinuousClock.now
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute, &value)
            try checkFrontmost(expectedPID)
            let valid = error == .success && value.map { CFGetTypeID($0) == expectedType } == true
            let record = AgentEvalFocusProbeAttribute(attempted: true, timeoutSetErrorCode: timeoutSetCode,
                axErrorCode: error.rawValue, elapsedMilliseconds: millis(started.duration(to: .now)),
                typeValid: error == .success ? valid : nil, pid: nil, string: nil, boolean: nil,
                reason: error == .success && !valid ? "Returned value had an unexpected type." : nil)
            let focused = valid ? value.map { unsafeBitCast($0, to: AXUIElement.self) } : nil
            return .init(record: record, element: focused)
        } catch ProbeError.timeoutSet(let errorCode) {
            return .init(record: .init(attempted: false, timeoutSetErrorCode: errorCode,
                axErrorCode: nil, elapsedMilliseconds: nil, typeValid: nil, pid: nil,
                string: nil, boolean: nil, reason: "AX messaging timeout could not be set."), element: nil)
        } catch { throw error }
    }

    private enum ValueKind: Equatable { case string, boolean }
    private static func scalarAttribute(_ attribute: CFString, from element: AXUIElement, budget: Int,
                                        expectedPID: pid_t, deadline: ContinuousClock.Instant,
                                        kind: ValueKind) throws -> AgentEvalFocusProbeAttribute {
        do {
            try checkFrontmost(expectedPID)
            let timeoutSetCode = try prepare(element, budget: budget, expectedPID: expectedPID, deadline: deadline)
            let started = ContinuousClock.now
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute, &value)
            try checkFrontmost(expectedPID)
            guard error == .success else {
                return .init(attempted: true, timeoutSetErrorCode: timeoutSetCode, axErrorCode: error.rawValue,
                    elapsedMilliseconds: millis(started.duration(to: .now)), typeValid: nil,
                    pid: nil, string: nil, boolean: nil, reason: nil)
            }
            if kind == .string, let string = value as? String {
                return .init(attempted: true, timeoutSetErrorCode: timeoutSetCode, axErrorCode: error.rawValue,
                    elapsedMilliseconds: millis(started.duration(to: .now)), typeValid: true,
                    pid: nil, string: String(string.prefix(80)), boolean: nil, reason: nil)
            }
            if kind == .boolean, let number = value as? NSNumber,
               CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .init(attempted: true, timeoutSetErrorCode: timeoutSetCode, axErrorCode: error.rawValue,
                    elapsedMilliseconds: millis(started.duration(to: .now)), typeValid: true,
                    pid: nil, string: nil, boolean: number.boolValue, reason: nil)
            }
            return .init(attempted: true, timeoutSetErrorCode: timeoutSetCode, axErrorCode: error.rawValue,
                elapsedMilliseconds: millis(started.duration(to: .now)), typeValid: false,
                pid: nil, string: nil, boolean: nil, reason: "Returned value had an unexpected type.")
        } catch ProbeError.timeoutSet(let errorCode) {
            return .init(attempted: false, timeoutSetErrorCode: errorCode, axErrorCode: nil,
                elapsedMilliseconds: nil, typeValid: nil, pid: nil, string: nil, boolean: nil,
                reason: "AX messaging timeout could not be set.")
        } catch { throw error }
    }

    private static func elementPID(_ element: AXUIElement, expectedPID: pid_t) throws -> AgentEvalFocusProbeAttribute {
        do {
            try checkFrontmost(expectedPID)
            var pid: pid_t = 0
            let started = ContinuousClock.now
            let error = AXUIElementGetPid(element, &pid)
            try checkFrontmost(expectedPID)
            return .init(attempted: true, timeoutSetErrorCode: nil, axErrorCode: error.rawValue,
                elapsedMilliseconds: millis(started.duration(to: .now)), typeValid: error == .success, pid: error == .success ? Int32(pid) : nil,
                string: nil, boolean: nil, reason: nil)
        } catch { throw error }
    }

    private static func prepare(_ element: AXUIElement, budget: Int, expectedPID: pid_t,
                                deadline: ContinuousClock.Instant) throws -> Int32 {
        try checkFrontmost(expectedPID)
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { throw ProbeError.stop("The 1.5 second probe deadline expired.") }
        let seconds = min(Double(budget) / 1_000, durationSeconds(remaining))
        guard seconds > 0 else { throw ProbeError.stop("The 1.5 second probe deadline expired.") }
        let error = AXUIElementSetMessagingTimeout(element, Float(seconds))
        guard error == .success else { throw ProbeError.timeoutSet(error.rawValue) }
        return error.rawValue
    }

    private static func checkFrontmost(_ expectedPID: pid_t) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID else {
            throw ProbeError.stop("Frontmost process changed during the probe.")
        }
    }

    private static func durationSeconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
    private static func millis(_ duration: Duration) -> Double { durationSeconds(duration) * 1_000 }
}
#endif

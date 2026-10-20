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

    private enum CodingKeys: String, CodingKey {
        case operation, abandoned, reason, samples
        case axTrusted = "ax_trusted"
        case expectedPID = "expected_pid"
        case frontmostPIDBefore = "frontmost_pid_before"
        case frontmostPIDAfter = "frontmost_pid_after"
        case elapsedMilliseconds = "elapsed_ms"
        case inputEventsPosted = "input_events_posted"
    }
}

@MainActor
enum AgentEvalFocusProbe {
    private static let totalLimit: Duration = .milliseconds(1_500)
    private enum ProbeError: Error { case stop(String), timeoutSet(Int32) }

    static func run(_ request: AgentEvalFocusProbeRequest) -> AgentEvalFocusProbeResponse {
        let clock = ContinuousClock(), started = clock.now, deadline = started + totalLimit
        let trusted = AXIsProcessTrusted()
        let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var reason: String?
        var abandoned = false
        var samples: [AgentEvalFocusProbeSample] = []
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
            abandoned: abandoned, reason: reason, samples: samples)
        return response
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

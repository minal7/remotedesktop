import ApplicationServices
import CoreGraphics
import Foundation

struct PixelElementMark {
    let id: Int
    let role: String
    let name: String
    let screenRect: CGRect
    let state: [String]
    let inView: Bool
}

struct PixelElementMarks {
    let marks: [PixelElementMark]
    let focusedID: Int?
    let secureScreenRects: [CGRect]
    let contentRect: CGRect?
    let browserURL: String?
}

enum PixelTargetRebinding {
    static func find(_ expected: AgentElement, in current: [PixelElementMark]) -> PixelElementMark? {
        current.first(where: { $0.id == expected.id && $0.role == expected.role && $0.name == expected.name })
            ?? current.first(where: { $0.role == expected.role && $0.name == expected.name })
    }
}

/// A best-effort, deadline-bounded reader. A slow app contributes an empty mark list.
@MainActor
enum ElementMarks {
    private struct Candidate {
        let role: String
        let name: String
        let rect: CGRect
        let state: [String]
        let inWindow: Bool
        let element: AXUIElement
    }

    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXTextView", "AXSearchField",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXTab", "AXMenuItem",
        "AXMenuBarItem", "AXSlider", "AXIncrementor", "AXSwitch", "AXDisclosureTriangle"
    ]

    static func read(window: AgentMacAccessibility.Window, budget: Duration = .milliseconds(300), limit: Int = 60) -> PixelElementMarks {
        let deadline = ContinuousClock.now + budget
        let appRoot = AXUIElementCreateApplication(window.application.processIdentifier)
        let focused = ax(read(appRoot, kAXFocusedUIElementAttribute, deadline: deadline))
        var browserURL = safeURL(read(window.element, kAXDocumentAttribute, deadline: deadline))
        var queue = [window.element]
        if let menu = ax(read(appRoot, kAXMenuBarAttribute, deadline: deadline)) { queue.append(menu) }
        var candidates: [Candidate] = [], secureRects: [CGRect] = [], contentRect: CGRect?
        var cursor = 0
        while cursor < queue.count && cursor < 160 && candidates.count < limit && ContinuousClock.now < deadline {
            let element = queue[cursor]; cursor += 1
            queue.append(contentsOf: children(read(element, kAXChildrenAttribute, deadline: deadline)))
            let role = read(element, kAXRoleAttribute, deadline: deadline) as? String ?? "unknown"
            guard let rect = rect(element, deadline: deadline), !rect.isEmpty else { continue }
            if role == "AXWebArea" {
                contentRect = rect
                if browserURL == nil { browserURL = safeURL(read(element, kAXDocumentAttribute, deadline: deadline)) }
            }
            let inWindow = rect.intersects(window.bounds)
            guard inWindow || role == "AXMenuBarItem" else { continue }
            guard interactiveRoles.contains(role) else { continue }
            let name = label(element, deadline: deadline)
            let subrole = read(element, kAXSubroleAttribute, deadline: deadline) as? String ?? ""
            let placeholder = read(element, "AXPlaceholderValue", deadline: deadline) as? String ?? ""
            let protected = read(element, "AXProtectedContent", deadline: deadline) as? Bool == true
            let secure = protected || AgentCredentialRule.isSensitive(role: role, name: name + " " + placeholder, state: [subrole])
            let enabled = read(element, kAXEnabledAttribute, deadline: deadline) as? Bool != false
            var state = ["visible"]
            if !enabled { state.append("disabled") }
            if secure { state.append("secure"); secureRects.append(rect) }
            if AgentSafetyBoundary.readOnly(bundleID: window.application.bundleIdentifier, appName: window.application.localizedName) {
                state.append("read_only")
            }
            candidates.append(Candidate(role: role, name: name, rect: rect, state: state, inWindow: inWindow, element: element))
        }
        let timedOut = ContinuousClock.now >= deadline
        let sorted = candidates.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
        let marks = timedOut ? [] : sorted.enumerated().map { index, value in
            PixelElementMark(id: index + 1, role: value.role, name: value.name, screenRect: value.rect,
                             state: value.inWindow ? value.state : value.state + ["read_only", "offscreen"], inView: value.inWindow)
        }
        let focusID = timedOut ? nil : sorted.firstIndex(where: { candidate in focused.map { CFEqual($0, candidate.element) } == true }).map { $0 + 1 }
        return PixelElementMarks(marks: marks, focusedID: focusID, secureScreenRects: secureRects,
                                 contentRect: contentRect, browserURL: browserURL)
    }

    static func focusedWindow(_ app: AXUIElement) -> AXUIElement? {
        ax(read(app, kAXFocusedWindowAttribute, deadline: ContinuousClock.now + .milliseconds(10)))
    }

    static func bounds(_ element: AXUIElement) -> CGRect? {
        rect(element, deadline: ContinuousClock.now + .milliseconds(10))
    }

    static func focusedElement(_ app: AXUIElement) -> AXUIElement? {
        ax(read(app, kAXFocusedUIElementAttribute, deadline: ContinuousClock.now + .milliseconds(10)))
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        read(element, attribute, deadline: ContinuousClock.now + .milliseconds(10)) as? String
    }

    static func label(_ element: AXUIElement) -> String {
        label(element, deadline: ContinuousClock.now + .milliseconds(40))
    }

    static func isSensitive(_ element: AXUIElement, role: String, name: String) -> Bool {
        let subrole = string(element, kAXSubroleAttribute) ?? ""
        let placeholder = string(element, "AXPlaceholderValue") ?? ""
        let protected = read(element, "AXProtectedContent", deadline: ContinuousClock.now + .milliseconds(10)) as? Bool == true
        return protected || AgentCredentialRule.isSensitive(role: role, name: name + " " + placeholder, state: [subrole])
    }

    private static func read(_ element: AXUIElement, _ attribute: String, deadline: ContinuousClock.Instant) -> CFTypeRef? {
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { return nil }
        let seconds = min(0.01, max(0.001, Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18))
        AXUIElementSetMessagingTimeout(element, Float(seconds))
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func label(_ element: AXUIElement, deadline: ContinuousClock.Instant) -> String {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXHelpAttribute] {
            guard let value = read(element, attribute, deadline: deadline) as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(256)) }
        }
        return ""
    }

    private static func rect(_ element: AXUIElement, deadline: ContinuousClock.Instant) -> CGRect? {
        guard let position = read(element, kAXPositionAttribute, deadline: deadline), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = read(element, kAXSizeAttribute, deadline: deadline), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func children(_ value: CFTypeRef?) -> [AXUIElement] {
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = unsafeBitCast(value, to: CFArray.self)
        return (0..<CFArrayGetCount(array)).compactMap { index in
            guard let raw = CFArrayGetValueAtIndex(array, index) else { return nil }
            return ax(Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as CFTypeRef)
        }
    }

    private static func ax(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func safeURL(_ value: CFTypeRef?) -> String? {
        let raw: String?
        if let value = value as? String { raw = value }
        else if let value, CFGetTypeID(value) == CFURLGetTypeID() {
            raw = (unsafeBitCast(value, to: CFURL.self) as URL).absoluteString
        } else { raw = nil }
        guard let raw, var parts = URLComponents(string: raw),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), let host = parts.host, !host.isEmpty else { return nil }
        parts.user = nil; parts.password = nil; parts.query = nil; parts.fragment = nil
        return parts.string
    }
}

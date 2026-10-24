import AppKit
import ApplicationServices
import Foundation

@MainActor
enum AgentDefaultButtonAXEvidenceReader {
    static func read(window: AgentMacAccessibility.Window?, focusedWindowElement: AXUIElement?,
                     focusedBounds: CGRect?, selectedBounds: CGRect, marks: [PixelElementMark],
                     hasOverlay: Bool, deadline: ContinuousClock.Instant) -> AgentDefaultButtonEvidence {
        // Only inspect the exact AX window already bound to the captured frontmost window.
        guard let window, let focusedWindowElement, CFEqual(window.element, focusedWindowElement),
              ElementMarks.focusedWindowMatches(focusedBounds, selectedBounds: selectedBounds),
              !hasOverlay, ContinuousClock.now < deadline,
              hasNoAttachedSheets(window.element, deadline: deadline) else { return .unknown }
        AXUIElementSetMessagingTimeout(window.element, 0.025)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(window.element, kAXDefaultButtonAttribute as CFString, &value)
        if error == .noValue { return .knownNone }
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unknown }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        guard isDescendant(element, of: window.element, deadline: deadline) else { return .unknown }
        let identity = AnyHashable(PixelAXIdentity(element: element))
        let matches = marks.filter { $0.identity == identity }
        guard matches.count == 1, let mark = matches.first, mark.role == "AXButton", mark.inView,
              !mark.state.contains("disabled"), !mark.state.contains("read_only"),
              !mark.state.contains("offscreen"), !mark.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unknown
        }
        return .button(identity: String(identity.hashValue), role: mark.role, name: mark.name)
    }

    private static func hasNoAttachedSheets(_ window: AXUIElement, deadline: ContinuousClock.Instant) -> Bool {
        guard ElementMarks.read(window, kAXRoleAttribute, deadline: deadline) as? String == "AXWindow",
              ContinuousClock.now < deadline else { return false }
        AXUIElementSetMessagingTimeout(window, 0.025)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return false }
        let children = unsafeBitCast(value, to: CFArray.self)
        for index in 0..<CFArrayGetCount(children) {
            guard ContinuousClock.now < deadline,
                  let childValue = CFArrayGetValueAtIndex(children, index) else { return false }
            let child = unsafeBitCast(childValue, to: AXUIElement.self)
            guard let role = ElementMarks.read(child, kAXRoleAttribute, deadline: deadline) as? String else {
                return false
            }
            if role == "AXSheet" || role == "AXDrawer" { return false }
        }
        return true
    }

    private static func isDescendant(_ element: AXUIElement, of window: AXUIElement,
                                     deadline: ContinuousClock.Instant) -> Bool {
        var current = element
        for _ in 0..<8 {
            guard !CFEqual(current, window), ContinuousClock.now < deadline,
                  let parent = ax(ElementMarks.read(current, kAXParentAttribute, deadline: deadline)) else { return false }
            if CFEqual(parent, window) { return true }
            current = parent
        }
        return false
    }

    private static func ax(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}

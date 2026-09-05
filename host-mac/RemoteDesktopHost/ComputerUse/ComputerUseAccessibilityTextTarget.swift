import AppKit
import ApplicationServices

/// Retains actual AX references instead of treating matching labels and pixel
/// positions as element identity. References are scoped to one application
/// launch, window, and the nearest exposed document identity.
@MainActor
final class ComputerUseAccessibilityTextTarget {
    private struct Binding {
        let id: String
        let application: String
        let element: AXUIElement
        let window: AXUIElement
        let document: String
    }
    private var binding: Binding?

    func snapshot() -> ComputerUseTextSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let application = "\(app.processIdentifier):\(app.launchDate?.timeIntervalSince1970 ?? 0):\(app.bundleURL?.path ?? "")"
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        guard let element = elementAttribute(kAXFocusedUIElementAttribute, on: root),
              let window = elementAttribute(kAXFocusedWindowAttribute, on: root),
              let role = stringAttribute(kAXRoleAttribute, on: element) else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.15)
        let subrole = stringAttribute(kAXSubroleAttribute, on: element) ?? ""
        let secure = subrole == kAXSecureTextFieldSubrole as String
            || boolAttribute("AXProtectedContent", on: element) == true
        // Check protection before querying value or selection.
        guard !secure else { return nil }
        let textRoles = [kAXTextFieldRole as String, kAXTextAreaRole as String,
                         kAXComboBoxRole as String]
        guard textRoles.contains(role),
              // AppKit NSTextView does not expose AXEnabled/AXEditable.
              // A supported writable text attribute supplies positive edit
              // capability; an explicitly disabled element still rejects.
              boolAttribute(kAXEnabledAttribute, on: element) != false,
              isSettable(kAXValueAttribute, on: element)
                || isSettable(kAXSelectedTextAttribute, on: element)
                || boolAttribute("AXEditable", on: element) == true,
              let value = stringAttribute(kAXValueAttribute, on: element),
              value.utf8.count <= ComputerUseTextEditor.maximumObservedValueBytes,
              let selectionValue = attribute(kAXSelectedTextRangeAttribute, on: element),
              CFGetTypeID(selectionValue) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(selectionValue as! AXValue, .cfRange, &selection),
              selection.location >= 0, selection.length >= 0,
              selection.location <= value.utf16.count,
              selection.length <= value.utf16.count - selection.location else { return nil }

        var documentParts: [String] = [stringAttribute(kAXTitleAttribute, on: window) ?? ""]
        var ancestor: AXUIElement? = element
        for _ in 0 ..< 12 {
            guard let current = ancestor else { break }
            for name in [kAXDocumentAttribute as String, "AXURL"] {
                if let documentValue = attribute(name, on: current) {
                    if let text = documentValue as? String { documentParts.append(text) }
                    else if let url = documentValue as? URL { documentParts.append(url.absoluteString) }
                }
            }
            if CFEqual(current, window) { break }
            ancestor = elementAttribute(kAXParentAttribute, on: current)
        }
        let document = documentParts.map { "\($0.utf8.count):\($0)" }.joined()
        if binding.map({
            $0.application == application && CFEqual($0.element, element)
                && CFEqual($0.window, window) && $0.document == document
        }) != true {
            binding = Binding(id: UUID().uuidString, application: application,
                              element: element, window: window, document: document)
        }
        guard let binding else { return nil }
        return ComputerUseTextSnapshot(
            targetID: binding.id, value: value,
            selection: NSRange(location: selection.location, length: selection.length),
            isEditable: true, isSecure: false)
    }

    func select(_ range: NSRange) -> Bool {
        guard let binding, isSettable(kAXSelectedTextRangeAttribute, on: binding.element) else {
            return false
        }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(
            binding.element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    func replaceSelectedText(_ text: String) -> Bool? {
        guard let binding, isSettable(kAXSelectedTextAttribute, on: binding.element) else {
            return nil
        }
        return AXUIElementSetAttributeValue(
            binding.element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    private func attribute(_ name: String, on element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func stringAttribute(_ name: String, on element: AXUIElement) -> String? {
        attribute(name, on: element) as? String
    }

    private func boolAttribute(_ name: String, on element: AXUIElement) -> Bool? {
        attribute(name, on: element) as? Bool
    }

    private func elementAttribute(_ name: String, on element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, on: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func isSettable(_ name: String, on element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success
            && settable.boolValue
    }
}

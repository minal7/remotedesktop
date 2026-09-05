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
        let documentRoot: AXUIElement
        let isWebContent: Bool
    }
    private var binding: Binding?
    private var bindings: [Binding] = []

    func snapshot() -> ComputerUseTextSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        guard let element = elementAttribute(kAXFocusedUIElementAttribute, on: root),
              let window = elementAttribute(kAXFocusedWindowAttribute, on: root) else { return nil }
        return snapshot(element: element, window: window, app: app)
    }

    /// Bounded discovery in the current window. Labels are untrusted planning
    /// data; opaque IDs retain the actual AX references needed for execution.
    func fields() -> [ComputerUseTextField] {
        guard let app = NSWorkspace.shared.frontmostApplication else { return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        guard let window = elementAttribute(kAXFocusedWindowAttribute, on: root) else { return [] }
        let focused = elementAttribute(kAXFocusedUIElementAttribute, on: root)
        var queue = [window]
        var visited: [AXUIElement] = []
        var fields: [ComputerUseTextField] = []
        let deadline = Date().addingTimeInterval(1)
        while !queue.isEmpty {
            guard visited.count < 300, Date() < deadline else { return [] }
            let element = queue.removeFirst()
            if visited.contains(where: { CFEqual($0, element) }) { continue }
            visited.append(element)
            AXUIElementSetMessagingTimeout(element, 0.1)
            if let value = snapshot(element: element, window: window, app: app) {
                let titleElement = elementAttribute(kAXTitleUIElementAttribute, on: element)
                let label = [stringAttribute(kAXTitleAttribute, on: element),
                             stringAttribute(kAXDescriptionAttribute, on: element),
                             stringAttribute("AXPlaceholderValue", on: element),
                             titleElement.flatMap { stringAttribute(kAXValueAttribute, on: $0) }]
                    .compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    ?? (focused.map { CFEqual($0, element) } == true ? "Focused field" : "")
                if !label.isEmpty, label.utf8.count <= 256 {
                    fields.append(ComputerUseTextField(label: label, snapshot: value))
                    guard fields.count <= 16 else { return [] }
                }
                continue
            }
            if let children = attribute(kAXChildrenAttribute, on: element) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return fields
    }

    func snapshot(targetID: String) -> ComputerUseTextSnapshot? {
        guard let retained = bindings.first(where: { $0.id == targetID }),
              let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        guard let window = elementAttribute(kAXFocusedWindowAttribute, on: root),
              CFEqual(window, retained.window),
              applicationIdentity(app) == retained.application,
              let value = snapshot(element: retained.element, window: window, app: app),
              value.targetID == targetID else { return nil }
        return value
    }

    func focus(targetID: String) -> Bool {
        guard snapshot(targetID: targetID) != nil, let binding else { return false }
        return AXUIElementSetAttributeValue(
            binding.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    private func applicationIdentity(_ app: NSRunningApplication) -> String {
        "\(app.processIdentifier):\(app.launchDate?.timeIntervalSince1970 ?? 0):\(app.bundleURL?.path ?? "")"
    }

    private func snapshot(element: AXUIElement, window: AXUIElement,
                          app: NSRunningApplication) -> ComputerUseTextSnapshot? {
        let application = applicationIdentity(app)
        // Apply the timeout before the first query on every new AX reference.
        AXUIElementSetMessagingTimeout(element, 0.15)
        guard let role = stringAttribute(kAXRoleAttribute, on: element) else { return nil }
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
        var isWebContent = false
        var documentRoot = window
        var reachedWindow = false
        var ancestor: AXUIElement? = element
        for _ in 0 ..< 12 {
            guard let current = ancestor else { break }
            AXUIElementSetMessagingTimeout(current, 0.15)
            if stringAttribute(kAXRoleAttribute, on: current) == "AXWebArea" {
                if !isWebContent { documentRoot = current }
                isWebContent = true
            }
            for name in [kAXDocumentAttribute as String, "AXURL"] {
                if let documentValue = attribute(name, on: current) {
                    if let text = documentValue as? String { documentParts.append(text) }
                    else if let url = documentValue as? URL { documentParts.append(url.absoluteString) }
                }
            }
            if CFEqual(current, window) { reachedWindow = true; break }
            ancestor = elementAttribute(kAXParentAttribute, on: current)
        }
        // A detached element may still answer AXValue. Readability, matching
        // pixels, and an unchanged URL do not prove current document membership.
        guard reachedWindow else { return nil }
        let document = documentParts.map { "\($0.utf8.count):\($0)" }.joined()
        binding = bindings.first(where: {
            $0.application == application && CFEqual($0.element, element)
                && CFEqual($0.window, window) && $0.document == document
                && CFEqual($0.documentRoot, documentRoot)
        })
        if binding == nil {
            // Old references cannot be revived by matching a label/position.
            bindings.removeAll { CFEqual($0.element, element) }
            guard bindings.count < 64 else { return nil }
            binding = Binding(id: UUID().uuidString, application: application,
                              element: element, window: window, document: document,
                              documentRoot: documentRoot,
                              isWebContent: isWebContent)
            bindings.append(binding!)
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

    /// WebKit advertises AXSelectedText as writable but may accept it without
    /// changing a textarea. Use its whole-value capability with the editor's
    /// fully computed expected value; readback remains mandatory.
    func replaceWebValue(_ value: String) -> Bool? {
        guard let binding, binding.isWebContent,
              isSettable(kAXValueAttribute, on: binding.element) else { return nil }
        return AXUIElementSetAttributeValue(
            binding.element, kAXValueAttribute as CFString, value as CFString) == .success
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

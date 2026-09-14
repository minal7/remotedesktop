import AppKit
import ApplicationServices

/// A bounded read of the foreground window using the same injectable AX IPC
/// boundary as native text. No AXValue, setters, focus changes or input events.
@MainActor
enum ComputerUseNativeControlReader {
    static func observe(displayBounds: CGRect, windowBounds: CGRect,
        access: ComputerUseAccessibilityTextTarget.Access, mayAct: () -> Bool,
        now: () -> Date = Date.init) throws -> ComputerUseNativeControls? {
        let deadline = now().addingTimeInterval(0.75)
        var expired = false
        func read(_ name: String, _ element: AXUIElement) throws -> CFTypeRef? {
            try Task.checkCancellation()
            guard mayAct() else { throw ComputerUseHostTools.ToolError.paused }
            guard now() < deadline else { expired = true; return nil }
            return access.read(name, element)
        }
        func element(_ name: String, _ source: AXUIElement) throws -> AXUIElement? {
            guard let value = try read(name, source), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
        func frame(_ source: AXUIElement) throws -> CGRect? {
            guard let p = try read(kAXPositionAttribute, source), CFGetTypeID(p) == AXValueGetTypeID(),
                  let s = try read(kAXSizeAttribute, source), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size),
                  point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else { return nil }
            return CGRect(origin: point, size: size)
        }
        try Task.checkCancellation()
        guard mayAct() else { throw ComputerUseHostTools.ToolError.paused }
        guard let app = access.frontmost() else { return nil }
        access.timeout(app.root, 0.1)
        guard let window = try element(kAXFocusedWindowAttribute, app.root) else { return nil }
        access.timeout(window, 0.1)
        guard try frame(window) == windowBounds else { return nil }
        let roles: Set<String> = ["AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
            "AXComboBox", "AXTextField", "AXTextArea", "AXMenuItem", "AXSlider", "AXIncrementor", "AXScrollArea"]
        var queue: [(AXUIElement, Bool)] = [(window, false)], visited: [AXUIElement] = []
        var items: [ComputerUseNativeControls.Item] = [], truncated = false
        while !queue.isEmpty {
            if visited.count >= 96 || items.count >= ComputerUseNativeControls.maximumItems { truncated = true; break }
            let (node, inheritedDisabled) = queue.removeFirst()
            if visited.contains(where: { CFEqual($0, node) }) { continue }
            visited.append(node); access.timeout(node, 0.1)
            let role = try read(kAXRoleAttribute, node) as? String ?? ""
            let subrole = try read(kAXSubroleAttribute, node) as? String ?? ""
            if role == "AXSecureTextField" || subrole == kAXSecureTextFieldSubrole as String { continue }
            if (try read("AXProtectedContent", node) as? NSNumber)?.boolValue == true { continue }
            if (try read("AXHidden", node) as? NSNumber)?.boolValue == true { continue }
            let explicitEnabled = (try read(kAXEnabledAttribute, node) as? NSNumber)?.boolValue
            let enabled = inheritedDisabled ? false : explicitEnabled
            if roles.contains(role), let bounds = try frame(node), windowBounds.contains(bounds) {
                var label: String?
                for name in [kAXTitleAttribute as String, kAXDescriptionAttribute as String, kAXPlaceholderValueAttribute as String,
                             kAXHelpAttribute as String, kAXIdentifierAttribute as String] {
                    if let value = try read(name, node) as? String,
                       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        var prefix = "", bytes = 0
                        for character in value {
                            let next = String(character)
                            guard bytes + next.utf8.count <= 384 else { break }
                            prefix += next; bytes += next.utf8.count
                        }
                        if bytes < value.utf8.count { truncated = true }
                        if !prefix.isEmpty { label = prefix; break }
                    }
                }
                let description = role + (label.map { " • " + $0 } ?? "")
                if let item = ComputerUseNativeControls.Item(description: description, frame: bounds, enabled: enabled, displayBounds: displayBounds) {
                    items.append(item)
                }
            }
            if let children = try read(kAXChildrenAttribute, node) as? [AXUIElement] {
                let remaining = max(0, 96 - visited.count - queue.count)
                if children.count > remaining { truncated = true }
                queue.append(contentsOf: children.prefix(remaining).map { ($0, enabled == false) })
            }
            if expired { return nil }
        }
        // Geometry is planning data, but still must belong to the screenshot's
        // foreground window. A changed scope cannot publish a mixed catalogue.
        guard let current = access.frontmost(), current.identity.utf8.elementsEqual(app.identity.utf8), CFEqual(current.root, app.root),
              let currentWindow = try element(kAXFocusedWindowAttribute, app.root), CFEqual(currentWindow, window),
              try frame(window) == windowBounds, !expired else { return nil }
        try Task.checkCancellation()
        guard mayAct() else { throw ComputerUseHostTools.ToolError.paused }
        return ComputerUseNativeControls(items: items, truncated: truncated)
    }
}

/// Reads cannot choose the destination of a later mutation. Every mutation
/// takes its own expected reference/state; stale state throws before input.
/// A nil text-setter result means unsupported with no setter invocation.
@MainActor
protocol ComputerUseNativeTextTarget: AnyObject {
    func fields() -> [ComputerUseTextField]
    func snapshot() -> ComputerUseTextSnapshot?
    func snapshot(targetID: String) -> ComputerUseTextSnapshot?
    func focus(expected: ComputerUseTextSnapshot) throws -> Bool
    func select(_ range: NSRange, expected: ComputerUseTextSnapshot) throws -> Bool
    func replaceSelectedText(_ text: String, expected: ComputerUseTextSnapshot) throws -> Bool?
    func replaceWebValue(_ value: String, expected: ComputerUseTextSnapshot) throws -> Bool?
}

/// Retains actual AX references instead of treating matching labels and pixel
/// positions as element identity. References are scoped to one application
/// launch, window, and the nearest exposed document identity.
@MainActor
final class ComputerUseAccessibilityTextTarget: ComputerUseNativeTextTarget {
    struct Application {
        let identity: String
        let root: AXUIElement
    }
    /// A narrow AX boundary lets fixtures exercise the production reference
    /// rules without querying or mutating another application's interface.
    struct Access {
        let frontmost: () -> Application?
        let read: (String, AXUIElement) -> CFTypeRef?
        let canSet: (String, AXUIElement) -> Bool
        let write: (String, CFTypeRef, AXUIElement) -> AXError
        let timeout: (AXUIElement, Float) -> Void
        var makeLifecycleMonitor: ((Application) -> any ComputerUseAXLifecycleMonitoring)? = nil

        @MainActor static var live: Access {
            Access(frontmost: {
                guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
                return Application(identity: "\(app.processIdentifier):\(app.launchDate?.timeIntervalSince1970 ?? 0):\(app.bundleURL?.path ?? "")",
                    root: AXUIElementCreateApplication(app.processIdentifier))
            }, read: { name, element in
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
                return value
            }, canSet: { name, element in
                var settable: DarwinBoolean = false
                return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
            }, write: { name, value, element in
                AXUIElementSetAttributeValue(element, name as CFString, value)
            }, timeout: { element, duration in _ = AXUIElementSetMessagingTimeout(element, duration) },
               makeLifecycleMonitor: { ComputerUseAXLifecycleMonitor(application: $0.root) })
        }
    }
    private struct Label {
        let text: String
        let element: AXUIElement?
    }
    private struct Shape {
        let role: String
        let subrole: String
        let identifier: String
        let label: Label
        let ancestors: [AXUIElement]

        func matches(_ other: Shape) -> Bool {
            let sameLabelElement: Bool
            switch (label.element, other.label.element) {
            case (nil, nil): sameLabelElement = true
            case (let first?, let second?): sameLabelElement = CFEqual(first, second)
            default: sameLabelElement = false
            }
            return role.utf8.elementsEqual(other.role.utf8) && subrole.utf8.elementsEqual(other.subrole.utf8)
                && identifier.utf8.elementsEqual(other.identifier.utf8) && label.text.utf8.elementsEqual(other.label.text.utf8)
                && sameLabelElement && ancestors.count == other.ancestors.count
                && zip(ancestors, other.ancestors).allSatisfy { CFEqual($0.0, $0.1) }
        }
    }
    private struct Binding {
        let id: String
        let application: String
        let element: AXUIElement
        let window: AXUIElement
        let document: String
        let documentRoot: AXUIElement
        let isWebContent: Bool
        let shape: Shape

        func mentions(_ other: AXUIElement) -> Bool {
            CFEqual(element, other) || CFEqual(window, other) || CFEqual(documentRoot, other)
                || shape.ancestors.contains { CFEqual($0, other) }
                || shape.label.element.map { CFEqual($0, other) } == true
        }
    }
    private let access: Access
    private var bindings: [Binding] = []
    private var observedApplication: String?
    private var observedRoot: AXUIElement?
    private var lifecycle: (any ComputerUseAXLifecycleMonitoring)?
    private var lifecycleRevision = UUID()
    private var destroyedElements: [AXUIElement] = []
    private var lifecycleUnavailable = false

    init(access: Access? = nil) { self.access = access ?? .live }
    deinit { lifecycle?.cancel() }

    func snapshot() -> ComputerUseTextSnapshot? {
        guard let app = applicationForObservation() else { return nil }
        let root = app.root
        setTimeout(root, 0.15)
        guard let element = elementAttribute(kAXFocusedUIElementAttribute, on: root),
              let window = elementAttribute(kAXFocusedWindowAttribute, on: root) else { return nil }
        return snapshot(element: element, window: window, app: app)
    }

    /// Bounded discovery in the current window. Labels are untrusted planning
    /// data; opaque IDs retain the actual AX references needed for execution.
    func fields() -> [ComputerUseTextField] {
        guard let app = applicationForObservation() else { return [] }
        let revision = lifecycleRevision
        let root = app.root
        setTimeout(root, 0.15)
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
            setTimeout(element, 0.1)
            if let value = snapshot(element: element, window: window, app: app) {
                // Use the exact label bound by this observation, rather than
                // making an independent planning-label read afterward.
                let observedLabel = bindings.first { $0.id == value.targetID }?.shape.label.text ?? ""
                let label = observedLabel.isEmpty ? (focused.map { CFEqual($0, element) } == true ? "Focused field" : "") : observedLabel
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
        synchronizeLifecycle()
        guard revision == lifecycleRevision, !lifecycleUnavailable else { return [] }
        return fields
    }

    func snapshot(targetID: String) -> ComputerUseTextSnapshot? {
        guard let app = applicationForObservation(),
              let retained = bindings.first(where: { $0.id == targetID }) else { return nil }
        let root = app.root
        setTimeout(root, 0.15)
        guard let window = elementAttribute(kAXFocusedWindowAttribute, on: root),
              CFEqual(window, retained.window),
              app.identity.utf8.elementsEqual(retained.application.utf8),
              let value = snapshot(element: retained.element, window: window, app: app),
              value.targetID == targetID else { return nil }
        return value
    }

    func focus(expected: ComputerUseTextSnapshot) throws -> Bool {
        guard snapshot(targetID: expected.targetID) == expected,
              let binding = bindings.first(where: { $0.id == expected.targetID }) else {
            throw ComputerUseTextEditError.preconditionChanged
        }
        try Task.checkCancellation()
        return try write(kAXFocusedAttribute, kCFBooleanTrue, binding: binding) == .success
    }

    private func snapshot(element: AXUIElement, window: AXUIElement,
                          app: Application) -> ComputerUseTextSnapshot? {
        let application = app.identity
        synchronizeLifecycle()
        let revision = lifecycleRevision
        var valid = false
        defer {
            // Once this exact object was observed as invalid, a later return
            // to its old visible state must receive new authority.
            if !valid { bindings.removeAll { CFEqual($0.element, element) } }
        }
        // Apply the timeout before the first query on every new AX reference.
        setTimeout(element, 0.15)
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
        var ancestors: [AXUIElement] = []
        var ancestor: AXUIElement? = element
        for _ in 0 ..< 12 {
            guard let current = ancestor else { break }
            guard !ancestors.contains(where: { CFEqual($0, current) }) else { return nil }
            ancestors.append(current)
            setTimeout(current, 0.15)
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
        let label = labelFor(element)
        let identifier = stringAttribute("AXIdentifier", on: element) ?? ""
        guard label.text.utf8.count <= 256, identifier.utf8.count <= 1_024 else { return nil }
        synchronizeLifecycle()
        guard revision == lifecycleRevision, isUsable(element), isUsable(window),
              ancestors.allSatisfy({ isUsable($0) }), label.element.map({ isUsable($0) }) != false else { return nil }
        let shape = Shape(role: role, subrole: subrole, identifier: identifier, label: label, ancestors: ancestors)
        var binding = bindings.first(where: {
            $0.application.utf8.elementsEqual(application.utf8) && CFEqual($0.element, element)
                && CFEqual($0.window, window) && $0.document.utf8.elementsEqual(document.utf8)
                && CFEqual($0.documentRoot, documentRoot)
                && $0.shape.matches(shape)
        })
        if binding == nil {
            // Old references cannot be revived by matching a label/position.
            bindings.removeAll { CFEqual($0.element, element) }
            guard bindings.count < 64 else { return nil }
            binding = Binding(id: UUID().uuidString, application: application,
                              element: element, window: window, document: document,
                              documentRoot: documentRoot,
                              isWebContent: isWebContent, shape: shape)
            bindings.append(binding!)
        }
        guard let binding else { return nil }
        valid = true
        return ComputerUseTextSnapshot(
            targetID: binding.id, value: value,
            selection: NSRange(location: selection.location, length: selection.length),
            isEditable: true, isSecure: false)
    }

    func select(_ range: NSRange, expected: ComputerUseTextSnapshot) throws -> Bool {
        guard let binding = try mutationBinding(expected: expected, attribute: kAXSelectedTextRangeAttribute) else {
            return false
        }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return try write(kAXSelectedTextRangeAttribute, value, binding: binding) == .success
    }

    func replaceSelectedText(_ text: String, expected: ComputerUseTextSnapshot) throws -> Bool? {
        guard let binding = try mutationBinding(expected: expected, attribute: kAXSelectedTextAttribute) else {
            return nil
        }
        return try write(kAXSelectedTextAttribute, text as CFString, binding: binding) == .success
    }

    /// WebKit advertises AXSelectedText as writable but may accept it without
    /// changing a textarea. Use its whole-value capability with the editor's
    /// fully computed expected value; readback remains mandatory.
    func replaceWebValue(_ value: String, expected: ComputerUseTextSnapshot) throws -> Bool? {
        guard let binding = try mutationBinding(expected: expected, attribute: kAXValueAttribute, requiresWebContent: true) else { return nil }
        return try write(kAXValueAttribute, value as CFString, binding: binding) == .success
    }

    /// An observation of another field must never retarget a later setter.
    /// Resolve the explicit reference and check focus/value/selection after
    /// capability queries, immediately before invoking its AX mutation.
    private func mutationBinding(expected: ComputerUseTextSnapshot, attribute: String,
                                 requiresWebContent: Bool = false) throws -> Binding? {
        synchronizeLifecycle()
        guard let binding = bindings.first(where: { $0.id == expected.targetID }) else {
            throw ComputerUseTextEditError.preconditionChanged
        }
        let supported = (!requiresWebContent || binding.isWebContent) && isSettable(attribute, on: binding.element)
        guard snapshot() == expected else { throw ComputerUseTextEditError.preconditionChanged }
        try Task.checkCancellation()
        return supported ? binding : nil
    }

    private func attribute(_ name: String, on element: AXUIElement) -> CFTypeRef? {
        synchronizeLifecycle()
        guard isUsable(element) else { return nil }
        let value = access.read(name, element)
        synchronizeLifecycle()
        return isUsable(element) ? value : nil
    }

    private func labelFor(_ element: AXUIElement) -> Label {
        // Retain the source which actually supplies the planning label. An
        // unused title object must not make ordinary edits look like a change
        // in meaning, or expose its value unnecessarily.
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue"] {
            if let text = stringAttribute(name, on: element),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return Label(text: text, element: nil)
            }
        }
        let titleElement = elementAttribute(kAXTitleUIElementAttribute, on: element)
        if let titleElement, !isUsable(titleElement) {
            // A destroyed label is invalid context, not an unlabeled field.
            // Retain the handle for snapshot's local liveness check; never query it.
            return Label(text: "", element: titleElement)
        }
        if let titleElement, stringAttribute(kAXRoleAttribute, on: titleElement) == kAXStaticTextRole as String,
           stringAttribute(kAXSubroleAttribute, on: titleElement) != kAXSecureTextFieldSubrole as String,
           boolAttribute("AXProtectedContent", on: titleElement) != true,
           let text = stringAttribute(kAXValueAttribute, on: titleElement),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Label(text: text, element: titleElement)
        }
        return Label(text: "", element: nil)
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
        synchronizeLifecycle()
        guard isUsable(element) else { return false }
        let result = access.canSet(name, element)
        synchronizeLifecycle()
        return isUsable(element) && result
    }

    private func setTimeout(_ element: AXUIElement, _ duration: Float) {
        synchronizeLifecycle()
        guard isUsable(element) else { return }
        access.timeout(element, duration)
    }

    private func write(_ attribute: String, _ value: CFTypeRef, binding: Binding) throws -> AXError {
        synchronizeLifecycle()
        guard isUsable(binding.element), bindings.contains(where: { $0.id == binding.id }) else {
            throw ComputerUseTextEditError.preconditionChanged
        }
        try Task.checkCancellation()
        return access.write(attribute, value, binding.element)
    }

    private func applicationForObservation() -> Application? {
        let app = access.frontmost()
        if app?.identity.utf8.elementsEqual(observedApplication?.utf8 ?? "".utf8) != true {
            lifecycle?.cancel(); lifecycle = nil
            bindings.removeAll(); destroyedElements.removeAll()
            lifecycleUnavailable = false; lifecycleRevision = UUID()
            observedApplication = app?.identity; observedRoot = app?.root
            if let app { lifecycle = access.makeLifecycleMonitor?(app) }
        }
        synchronizeLifecycle()
        return lifecycleUnavailable ? nil : app
    }

    private func isUsable(_ element: AXUIElement) -> Bool {
        !lifecycleUnavailable && !destroyedElements.contains { CFEqual($0, element) }
    }

    private func synchronizeLifecycle() {
        guard let lifecycle else { return }
        for event in lifecycle.drain() {
            if event.kind == .created, let element = event.element,
               observedRoot.map({ CFEqual($0, element) }) != true,
               !bindings.contains(where: { $0.mentions(element) }) {
                // A newly created, unrelated object cannot repurpose a retained
                // reference. Do not interrupt a read in progress either. Focus,
                // modal scope and destruction events still retire authority;
                // fresh object/ancestry/value/selection checks remain mandatory.
                // Compare locally: this handle may already have been destroyed.
                continue
            }
            lifecycleRevision = UUID()
            switch event.kind {
            case .coverageLost:
                lifecycleUnavailable = true; bindings.removeAll()
            case .scopeChanged:
                bindings.removeAll()
            case .created:
                guard let element = event.element else { bindings.removeAll(); continue }
                if observedRoot.map({ CFEqual($0, element) }) == true { bindings.removeAll() }
                else { bindings.removeAll { $0.mentions(element) } }
            case .elementChanged:
                guard let element = event.element else { continue }
                if observedRoot.map({ CFEqual($0, element) }) == true { bindings.removeAll() }
                else { bindings.removeAll { $0.mentions(element) } }
            case .valueChanged:
                // Field value/selection edits do not repurpose a control.
                // Label and enclosing-context values can change its meaning.
                guard let element = event.element else { continue }
                if observedRoot.map({ CFEqual($0, element) }) == true { bindings.removeAll() }
                else {
                    bindings.removeAll { binding in
                        binding.shape.label.element.map { CFEqual($0, element) } == true
                            || (!CFEqual(binding.element, element) && binding.mentions(element))
                    }
                }
            case .destroyed:
                guard let element = event.element else { continue }
                bindings.removeAll { $0.mentions(element) }
                if !destroyedElements.contains(where: { CFEqual($0, element) }) {
                    guard destroyedElements.count < 1_024 else {
                        lifecycleUnavailable = true; bindings.removeAll(); continue
                    }
                    destroyedElements.append(element)
                }
                if observedRoot.map({ CFEqual($0, element) }) == true { lifecycleUnavailable = true; bindings.removeAll() }
            }
        }
    }
}

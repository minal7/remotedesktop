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
            let value = access.read(name, element)
            // AX IPC may return after ownership or its time budget expires.
            try Task.checkCancellation()
            guard mayAct() else { throw ComputerUseHostTools.ToolError.paused }
            guard now() < deadline else { expired = true; return nil }
            return value
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
        func windowContext() throws -> ComputerUseNativeControls.Window? {
            let role = try read(kAXRoleAttribute, window) as? String
            let subrole = try read(kAXSubroleAttribute, window) as? String
            guard role != "AXSecureTextField", subrole != kAXSecureTextFieldSubrole as String,
                  (try read("AXProtectedContent", window) as? NSNumber)?.boolValue != true,
                  (try read("AXHidden", window) as? NSNumber)?.boolValue != true else { return nil }
            let title = try read(kAXTitleAttribute, window) as? String
            let rawModal = try read(kAXModalAttribute, window)
            // Unsupported and malformed attributes stay unknown. In
            // particular, a number or a title containing "dialog" is no proof.
            let modal = rawModal.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? ($0 as? NSNumber)?.boolValue : nil }
            return .init(role: role, subrole: subrole, title: title, modal: modal)
        }
        let observedWindow = try windowContext()
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
        guard let currentWindow = try element(kAXFocusedWindowAttribute, app.root), CFEqual(currentWindow, window),
              try frame(window) == windowBounds, try windowContext() == observedWindow, !expired,
              let current = access.frontmost(), current.identity.utf8.elementsEqual(app.identity.utf8), CFEqual(current.root, app.root) else { return nil }
        try Task.checkCancellation()
        guard mayAct() else { throw ComputerUseHostTools.ToolError.paused }
        return ComputerUseNativeControls(items: items, truncated: truncated, window: observedWindow)
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
    struct DiagnosticEvent: Codable, Sendable {
        let elapsedMilliseconds: Int64
        let instanceID: String
        let targetID: String
        let kind: String
        let reason: String
        let eventKind: String?
        let notification: String?
        let matchedReferences: [String]
    }

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
    private final class SnapshotLifecycleCapture {
        // Attribute helpers drain lifecycle notifications throughout AX IPC;
        // retain them until the read scope is known, then compare handles locally.
        private(set) var events: [ComputerUseAXLifecycleEvent] = []
        private(set) var overflowed = false

        func append(_ drained: [ComputerUseAXLifecycleEvent]) {
            guard !overflowed else { return }
            guard drained.count <= 256 - events.count else {
                overflowed = true
                events.removeAll(keepingCapacity: false)
                return
            }
            events.append(contentsOf: drained)
        }
    }
    private let access: Access
    private let diagnosticObserver: (@MainActor (DiagnosticEvent) -> Void)?
    private let diagnosticInstanceID = UUID().uuidString
    private let diagnosticStartUptime = ProcessInfo.processInfo.systemUptime
    private var bindings: [Binding] = []
    private var observedApplication: String?
    private var observedRoot: AXUIElement?
    private var lifecycle: (any ComputerUseAXLifecycleMonitoring)?
    private var lifecycleRevision = UUID()
    private var destroyedElements: [AXUIElement] = []
    private var lifecycleUnavailable = false
    private var snapshotLifecycleCapture: SnapshotLifecycleCapture?

    init(access: Access? = nil,
         diagnosticObserver: (@MainActor (DiagnosticEvent) -> Void)? = nil) {
        self.access = access ?? .live
        self.diagnosticObserver = diagnosticObserver
    }
    deinit { lifecycle?.cancel() }

    func snapshot() -> ComputerUseTextSnapshot? {
        guard let app = applicationForObservation(allowFreshScope: true) else { return nil }
        return withSnapshotLifecycleCapture { _ in
            let root = app.root
            setTimeout(root, 0.15)
            guard let element = elementAttribute(kAXFocusedUIElementAttribute, on: root),
                  let window = elementAttribute(kAXFocusedWindowAttribute, on: root) else { return nil }
            return snapshot(element: element, window: window, app: app)
        }
    }

    /// Bounded discovery in the current window. Labels are untrusted planning
    /// data; opaque IDs retain the actual AX references needed for execution.
    func fields() -> [ComputerUseTextField] {
        guard let app = applicationForObservation(allowFreshScope: true) else { return [] }
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
        return withSnapshotLifecycleCapture { _ in
            let root = app.root
            setTimeout(root, 0.15)
            guard let window = elementAttribute(kAXFocusedWindowAttribute, on: root),
                  CFEqual(window, retained.window),
                  app.identity.utf8.elementsEqual(retained.application.utf8),
                  let value = snapshot(element: retained.element, window: window, app: app),
                  value.targetID == targetID else { return nil }
            return value
        }
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
        withSnapshotLifecycleCapture { capture in
            snapshot(element: element, window: window, app: app, capture: capture)
        }
    }

    private func snapshot(element: AXUIElement, window: AXUIElement, app: Application,
                          capture: SnapshotLifecycleCapture) -> ComputerUseTextSnapshot? {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(750))
        let application = app.identity
        synchronizeLifecycle()
        var valid = false
        var failureReason = "invalidRead"
        defer {
            // Once this exact object was observed as invalid, a later return
            // to its old visible state must receive new authority.
            if !valid {
                let removed = bindings.filter { CFEqual($0.element, element) }
                bindings.removeAll { CFEqual($0.element, element) }
                for binding in removed {
                    emitDiagnostic(binding, kind: "bindingRetired", reason: failureReason)
                }
            }
        }
        func beforeDeadline() -> Bool {
            guard ContinuousClock.now < deadline else { failureReason = "deadline"; return false }
            return true
        }
        // Apply the timeout before the first query on every new AX reference.
        setTimeout(element, 0.15)
        guard let role = stringAttribute(kAXRoleAttribute, on: element) else { return nil }
        guard beforeDeadline() else { return nil }
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
        for _ in 0 ..< 32 {
            guard beforeDeadline() else { return nil }
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
            guard beforeDeadline() else { return nil }
            if CFEqual(current, window) { reachedWindow = true; break }
            ancestor = elementAttribute(kAXParentAttribute, on: current)
        }
        // A detached element may still answer AXValue. Readability, matching
        // pixels, and an unchanged URL do not prove current document membership.
        guard reachedWindow, beforeDeadline() else { return nil }
        let document = documentParts.map { "\($0.utf8.count):\($0)" }.joined()
        let label = labelFor(element)
        let identifier = stringAttribute("AXIdentifier", on: element) ?? ""
        guard label.text.utf8.count <= 256, identifier.utf8.count <= 1_024 else { return nil }
        synchronizeLifecycle()
        guard beforeDeadline(),
              !snapshotEventsInvalidate(capture, app: app, window: window, element: element,
                                        documentRoot: documentRoot, ancestors: ancestors,
                                        labelElement: label.element),
              isUsable(element), isUsable(window),
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
            let replaced = bindings.filter { CFEqual($0.element, element) }
            bindings.removeAll { CFEqual($0.element, element) }
            for old in replaced {
                emitDiagnostic(old, kind: "bindingRetired", reason: "contextOrShapeChanged")
            }
            guard bindings.count < 64 else { return nil }
            binding = Binding(id: UUID().uuidString, application: application,
                              element: element, window: window, document: document,
                              documentRoot: documentRoot,
                              isWebContent: isWebContent, shape: shape)
            bindings.append(binding!)
            emitDiagnostic(binding!, kind: "bindingCreated", reason: "observed")
        }
        guard let binding, beforeDeadline() else { return nil }
        valid = true
        return ComputerUseTextSnapshot(
            targetID: binding.id, value: value,
            selection: NSRange(location: selection.location, length: selection.length),
            isEditable: true, isSecure: false)
    }

    private func withSnapshotLifecycleCapture<T>(_ body: (SnapshotLifecycleCapture) -> T) -> T {
        if let snapshotLifecycleCapture { return body(snapshotLifecycleCapture) }
        let capture = SnapshotLifecycleCapture()
        snapshotLifecycleCapture = capture
        defer { snapshotLifecycleCapture = nil }
        return body(capture)
    }

    private func snapshotEventsInvalidate(_ capture: SnapshotLifecycleCapture, app: Application,
                                          window: AXUIElement, element: AXUIElement,
                                          documentRoot: AXUIElement, ancestors: [AXUIElement],
                                          labelElement: AXUIElement?) -> Bool {
        guard !capture.overflowed else { return true }
        let observedReferences = [app.root, window, element] + ancestors + (labelElement.map { [$0] } ?? [])
        return capture.events.contains { event in
            switch event.kind {
            case .scopeChanged, .coverageLost:
                return true
            case .valueChanged:
                guard let source = event.element else { return true }
                if CFEqual(source, app.root) || CFEqual(source, window) || CFEqual(source, documentRoot)
                    || CFEqual(source, element) || labelElement.map({ CFEqual($0, source) }) == true {
                    return true
                }
                // Intermediate wrapper values are not part of field identity;
                // the field's own value and selection are freshly checked.
                return false
            case .created, .elementChanged, .destroyed:
                guard let source = event.element else { return true }
                return observedReferences.contains { CFEqual($0, source) }
            }
        }
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

    private func applicationForObservation(allowFreshScope: Bool = false) -> Application? {
        let app = access.frontmost()
        synchronizeLifecycle()
        if let app, app.identity.utf8.elementsEqual(observedApplication?.utf8 ?? "".utf8),
           observedRoot.map({ CFEqual($0, app.root) }) == true,
           destroyedElements.contains(where: { CFEqual($0, app.root) }) {
            // A destroyed application AX root cannot become safe again just
            // because fresh-scope recovery was requested. Recovery remains
            // available for coverage loss and a genuinely new app/root.
            return nil
        }
        // Overflow retires every retained reference. A new observation may
        // start a new monitor and bind freshly queried controls; a lookup or
        // mutation using an old target ID must never recover that authority.
        if app?.identity.utf8.elementsEqual(observedApplication?.utf8 ?? "".utf8) != true
            || (allowFreshScope && lifecycleUnavailable) {
            for binding in bindings {
                emitDiagnostic(binding, kind: "bindingRetired", reason: "applicationScopeChanged",
                               matchedReferences: ["appRoot"])
            }
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
        let drained = lifecycle.drain()
        snapshotLifecycleCapture?.append(drained)
        for event in drained { processLifecycleEvent(event) }
    }

    private func processLifecycleEvent(_ event: ComputerUseAXLifecycleEvent) {
        if event.kind == .created, let element = event.element,
           observedRoot.map({ CFEqual($0, element) }) != true,
           !bindings.contains(where: { $0.mentions(element) }) {
            // A newly created, unrelated object cannot repurpose a retained
            // reference. Compare locally: this handle may already be destroyed.
            return
        }
        lifecycleRevision = UUID()
        let before = diagnosticObserver == nil ? [] : bindings
        var reason = String(describing: event.kind)
        switch event.kind {
        case .coverageLost:
            lifecycleUnavailable = true; bindings.removeAll(); reason = "coverageLost"
        case .scopeChanged:
            bindings.removeAll(); reason = "scopeChanged"
        case .created:
            guard let element = event.element else { bindings.removeAll(); reason = "createdWithoutSource"; break }
            if observedRoot.map({ CFEqual($0, element) }) == true { bindings.removeAll() }
            else { bindings.removeAll { $0.mentions(element) } }
        case .elementChanged:
            guard let element = event.element else { return }
            if observedRoot.map({ CFEqual($0, element) }) == true { bindings.removeAll() }
            else { bindings.removeAll { $0.mentions(element) } }
        case .valueChanged:
            // Field text is rechecked; labels and page/document identity stay
            // sensitive, while intermediate wrappers are not field metadata.
            guard let element = event.element else { return }
            if observedRoot.map({ CFEqual($0, element) }) == true { bindings.removeAll() }
            else {
                bindings.removeAll { binding in
                    let isUsedLabel = binding.shape.label.element.map { CFEqual($0, element) } == true
                    let isField = CFEqual(binding.element, element)
                    let isPageOrDocument = CFEqual(binding.window, element) || CFEqual(binding.documentRoot, element)
                    return isUsedLabel || (!isField && isPageOrDocument)
                }
            }
        case .destroyed:
            guard let element = event.element else { return }
            bindings.removeAll { $0.mentions(element) }
            if !destroyedElements.contains(where: { CFEqual($0, element) }) {
                if destroyedElements.count < 1_024 { destroyedElements.append(element) }
                else { lifecycleUnavailable = true; bindings.removeAll(); reason = "destroyedOverflow" }
            }
            if observedRoot.map({ CFEqual($0, element) }) == true {
                lifecycleUnavailable = true; bindings.removeAll()
            }
        }
        guard diagnosticObserver != nil else { return }
        for binding in before where !bindings.contains(where: { $0.id == binding.id }) {
            emitDiagnostic(binding, kind: "bindingRetired", reason: reason, event: event,
                matchedReferences: diagnosticMatches(binding, event: event))
        }
    }

    private func diagnosticMatches(_ binding: Binding, event: ComputerUseAXLifecycleEvent) -> [String] {
        switch event.kind {
        case .scopeChanged: return ["scope"]
        case .coverageLost: return ["coverage"]
        case .created, .elementChanged, .valueChanged, .destroyed: break
        }
        guard let source = event.element else { return ["unknownSource"] }
        var matches: [String] = []
        if observedRoot.map({ CFEqual($0, source) }) == true { matches.append("appRoot") }
        if CFEqual(binding.window, source) { matches.append("window") }
        if CFEqual(binding.element, source) { matches.append("field") }
        if CFEqual(binding.documentRoot, source) { matches.append("documentRoot") }
        if binding.shape.ancestors.contains(where: { CFEqual($0, source) }) { matches.append("ancestor") }
        if binding.shape.label.element.map({ CFEqual($0, source) }) == true { matches.append("label") }
        return matches
    }

    private func emitDiagnostic(_ binding: Binding, kind: String, reason: String,
                                event: ComputerUseAXLifecycleEvent? = nil,
                                matchedReferences: [String] = []) {
        guard let diagnosticObserver else { return }
        diagnosticObserver(DiagnosticEvent(
            elapsedMilliseconds: Int64(max(0, (ProcessInfo.processInfo.systemUptime - diagnosticStartUptime) * 1_000)),
            instanceID: diagnosticInstanceID, targetID: binding.id, kind: kind, reason: reason,
            eventKind: event.map { String(describing: $0.kind) }, notification: event?.notification,
            matchedReferences: matchedReferences))
    }
}

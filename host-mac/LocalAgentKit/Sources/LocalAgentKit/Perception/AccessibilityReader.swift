import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// AXUIElement wrapper: CF types aren't marked Sendable, but AX references are
/// safe to pass between threads.
public struct AXHandle: @unchecked Sendable {
    public let element: AXUIElement
    public init(_ element: AXUIElement) { self.element = element }
}

enum AX {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    static func children(_ element: AXUIElement, _ name: String = kAXChildrenAttribute) -> [AXUIElement] {
        (attribute(element, name) as? [AXUIElement]) ?? []
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        attribute(element, name) as? Bool
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        var point = CGPoint.zero, size = CGSize.zero
        guard let position = attribute(element, kAXPositionAttribute),
              let dimension = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(dimension) == AXValueGetTypeID(),
              AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(dimension, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    static func stringifiedValue(_ raw: CFTypeRef?) -> String? {
        switch raw {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }
}

/// Browsers and Electron apps leave the contents of their pages out of the accessibility tree until
/// something says a screen reader is listening. Chrome answers only to `AXEnhancedUserInterface`,
/// even though setting it reports an error, and fills the tree about 2 seconds later. Asked again
/// within that time it starts counting afresh, which measured as never filling it at all, so asks
/// are kept apart. It can miss one while it's still starting, so they do repeat. Electron answers to
/// `AXManualAccessibility`. Other apps ignore both, apart from some window animations, so every
/// app gets them and they're taken back when the task ends.
public enum AssistiveMode {
    private static let names = ["AXEnhancedUserInterface", "AXManualAccessibility"]
    private static let askEvery: TimeInterval = 5
    private static let lock = NSLock()
    nonisolated(unsafe) private static var apps: [pid_t: (app: AXHandle, asked: Date)] = [:]

    /// Whether this is the first time this app has been asked during this task.
    @discardableResult
    static func request(_ app: AXUIElement, pid: pid_t) -> Bool {
        let now = Date()
        let (isNew, ask) = lock.withLock { () -> (Bool, Bool) in
            guard let known = apps[pid] else {
                apps[pid] = (AXHandle(app), now)
                return (true, true)
            }
            guard now.timeIntervalSince(known.asked) >= askEvery else { return (false, false) }
            apps[pid]?.asked = now
            return (false, true)
        }
        if ask {
            for name in names { AXUIElementSetAttributeValue(app, name as CFString, kCFBooleanTrue) }
        }
        return isNew
    }

    public static func release() {
        let taken = lock.withLock { () -> [AXHandle] in
            defer { apps.removeAll() }
            return apps.values.map(\.app)
        }
        for app in taken {
            for name in names { AXUIElementSetAttributeValue(app.element, name as CFString, kCFBooleanFalse) }
        }
    }
}

/// Walks the frontmost window's accessibility tree into a flat element list,
/// spending at most a fixed budget. Subtrees scrolled out of view are skipped
/// unless `deep`, which is what lets large web pages stay fast.
struct AccessibilityReader {
    struct Output {
        var elements: [UIElement] = []
        var handles: [AXHandle] = []
        var windowTitle = ""
        var windowFrame: CGRect = .zero
        var windowButtons: [CGRect] = []
        var windowHandle: AXHandle?
        var otherWindows: [String] = []
        var url: String?
        var frameURLs: [String] = []
        var pageFrame: CGRect?
        var firstLook = false
        var hasModal = false
        var hiddenAbove = 0
        var hiddenBelow = 0
        var visited = 0
    }

    var nodeBudget = 2_500
    var timeBudget: TimeInterval = 1.5
    var deep = false

    private static let attributeNames: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXEnabledAttribute, kAXFocusedAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute,
        kAXSelectedAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute, kAXRoleDescriptionAttribute,
    ]

    private static let containerRoles: Set<String> = [
        "AXScrollArea", "AXWebArea", "AXTable", "AXOutline", "AXList", "AXCollection", "AXBrowser", "AXContentList",
    ]

    /// Reads the app's focused window (and any open menu). Falls back through main
    /// and first window so transient focus loss doesn't blank the scene.
    func read(pid: pid_t) -> Output {
        var output = Output()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        output.firstLook = AssistiveMode.request(app, pid: pid)

        let windows = AX.children(app, kAXWindowsAttribute)
        let focused = AX.element(app, kAXFocusedWindowAttribute) ?? AX.element(app, kAXMainWindowAttribute) ?? windows.first
        for window in windows where window != focused {
            if let title = AX.string(window, kAXTitleAttribute), !title.isEmpty { output.otherWindows.append(title) }
        }
        let deadline = Date().addingTimeInterval(timeBudget)
        let focusedElement = AX.element(app, kAXFocusedUIElementAttribute)
        var seen = 0

        // An open menu sits above everything and is what the next click must hit.
        for child in AX.children(app) where AX.string(child, kAXRoleAttribute) == kAXMenuRole {
            walk(child, clip: .infinite, modal: true, focusedElement: focusedElement, depth: 0, deadline: deadline,
                 seen: &seen, output: &output)
        }

        guard let focused else { return output }
        output.windowHandle = AXHandle(focused)
        output.windowTitle = AX.string(focused, kAXTitleAttribute) ?? ""
        output.windowFrame = AX.frame(focused) ?? .zero
        output.windowButtons = [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute, kAXFullScreenButtonAttribute].compactMap {
            AX.element(focused, $0).flatMap { AX.frame($0) }
        }
        let subrole = AX.string(focused, kAXSubroleAttribute)
        let isDialogWindow = subrole == "AXDialog" || subrole == "AXSystemDialog"
        let sheets = AX.children(focused).filter { AX.string($0, kAXRoleAttribute) == "AXSheet" }
        output.hasModal = isDialogWindow || !sheets.isEmpty || AX.bool(focused, "AXModal") == true

        // A sheet blocks its parent; read it first, and the parent only for context.
        for sheet in sheets {
            walk(sheet, clip: output.windowFrame.insetBy(dx: -4, dy: -4), modal: true, focusedElement: focusedElement,
                 depth: 0, deadline: deadline, seen: &seen, output: &output)
        }
        if sheets.isEmpty {
            walk(focused, clip: output.windowFrame, modal: isDialogWindow, focusedElement: focusedElement, depth: 0,
                 deadline: deadline, seen: &seen, output: &output)
        }
        output.visited = seen
        return output
    }

    private func walk(_ node: AXUIElement, clip: CGRect, modal: Bool, focusedElement: AXUIElement?, depth: Int,
                      deadline: Date, seen: inout Int, output: inout Output) {
        guard depth < 64, seen < nodeBudget, Date() < deadline else { return }
        seen += 1

        var rawValues: CFArray?
        let names = Self.attributeNames as CFArray
        guard AXUIElementCopyMultipleAttributeValues(node, names, [], &rawValues) == .success,
              let values = rawValues as? [AnyObject], values.count == Self.attributeNames.count else { return }
        func text(_ index: Int) -> String? { (values[index] as? String)?.nilIfBlank }

        let role = text(0) ?? ""
        let subrole = text(1)
        var frame: CGRect?
        var point = CGPoint.zero, size = CGSize.zero
        let rawPosition = values[7], rawSize = values[8]
        if CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID(),
           AXValueGetValue(unsafeDowncast(rawPosition, to: AXValue.self), .cgPoint, &point),
           AXValueGetValue(unsafeDowncast(rawSize, to: AXValue.self), .cgSize, &size) {
            frame = CGRect(origin: point, size: size)
        }

        // Skip whole subtrees that are scrolled away, and count what we skipped so
        // the model can be told there is more above or below.
        var nextClip = clip
        if let frame, frame.width > 0, frame.height > 0, clip != .infinite, !frame.intersects(clip) {
            if !deep {
                if frame.minY >= clip.maxY { output.hiddenBelow += 1 }
                else if frame.maxY <= clip.minY { output.hiddenAbove += 1 }
                return
            }
        }
        if Self.containerRoles.contains(role), let frame, frame.width > 0, frame.height > 0, clip != .infinite {
            let intersection = clip.intersection(frame)
            if !intersection.isNull, !intersection.isEmpty { nextClip = intersection }
        }

        if role == "AXWebArea" {
            let address = (AX.attribute(node, "AXURL") as? URL)?.absoluteString ?? AX.string(node, "AXURL")
            if let address {
                // The page is the biggest of them, not a frame in it or a browser's own dropdown.
                let size = frame.map { $0.width * $0.height } ?? 0
                if output.url == nil || size > (output.pageFrame.map { $0.width * $0.height } ?? 0) {
                    output.url = address
                    output.pageFrame = frame
                }
                output.frameURLs.append(address)
            }
        }
        if role == "AXWebArea", values.count > 9, AX.children(node).isEmpty {
            // Chromium needs the nudge above to take effect; the next observation reads it.
        }

        if let frame, let element = makeElement(role: role, subrole: subrole, node: node, frame: frame, values: values,
                                                modal: modal, focusedElement: focusedElement, clip: nextClip) {
            var element = element
            element.handle = output.handles.count
            output.handles.append(AXHandle(node))
            output.elements.append(element)
            // Text fields, buttons and links are leaves as far as the model cares.
            if Self.leafRoles.contains(role) { return }
        }

        var children = (values[9] as? [AXUIElement]) ?? []
        // Big tables and lists expose just what's on screen; much cheaper than all rows.
        if !deep, ["AXTable", "AXOutline", "AXList", "AXBrowser"].contains(role) {
            let visible = AX.children(node, kAXVisibleRowsAttribute)
            if !visible.isEmpty { children = visible }
            else {
                let visibleChildren = AX.children(node, kAXVisibleChildrenAttribute)
                if !visibleChildren.isEmpty { children = visibleChildren }
            }
        }
        for child in children {
            walk(child, clip: nextClip, modal: modal, focusedElement: focusedElement, depth: depth + 1,
                 deadline: deadline, seen: &seen, output: &output)
        }
    }

    private static let leafRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuItem", "AXStaticText", "AXImage", "AXSlider", "AXComboBox", "AXMenuButton", "AXMenuBarItem",
    ]

    private static let roleNames: [String: String] = [
        "AXButton": "button", "AXLink": "link", "AXTextField": "field", "AXTextArea": "field", "AXSearchField": "search",
        "AXCheckBox": "check", "AXRadioButton": "radio", "AXPopUpButton": "popup", "AXMenuItem": "menuitem",
        "AXTabGroup": "", "AXRow": "row", "AXSlider": "slider", "AXIncrementor": "stepper", "AXComboBox": "combo",
        "AXMenuButton": "menubutton", "AXStaticText": "text", "AXImage": "image", "AXDisclosureTriangle": "disclosure",
        "AXCell": "cell", "AXHeading": "heading",
    ]

    private func makeElement(role: String, subrole: String?, node: AXUIElement, frame: CGRect, values: [AnyObject],
                             modal: Bool, focusedElement: AXUIElement?, clip: CGRect) -> UIElement? {
        func text(_ index: Int) -> String? { (values[index] as? String)?.nilIfBlank }
        let title = text(2), description = text(3)
        let rawValue = values[4]
        let enabled = (values[5] as? Bool) ?? true
        let selected = (values[10] as? Bool) ?? false
        let placeholder = text(11), help = text(12)

        // Window furniture: keep close, drop the rest. Not worth a token each step.
        if subrole == "AXMinimizeButton" || subrole == "AXZoomButton" || subrole == "AXFullScreenButton" { return nil }
        var mapped = Self.roleNames[role]
        if subrole == "AXSearchField" { mapped = "search" }
        if subrole == "AXTabButton" { mapped = "tab" }
        if role == "AXRadioButton", subrole == "AXTabButton" { mapped = "tab" }
        if role == "AXGroup" || role == "AXUnknown" || role == "AXHeading" || role == "AXCell" || role == "AXRow" {
            // Web frameworks make clickable divs; include those only when they name themselves.
            guard let name = title ?? description else {
                return role == "AXRow" && (values[10] as? Bool) == true ? nil : nil
            }
            if role == "AXGroup" || role == "AXUnknown" {
                guard AX.actions(node).contains(kAXPressAction as String) else { return nil }
                mapped = "button"
            } else if mapped == nil { mapped = "text" }
            _ = name
        }
        guard var mappedRole = mapped, !mappedRole.isEmpty else { return nil }
        guard frame.width >= 2, frame.height >= 2 else { return nil }

        let visible = clip == .infinite || frame.intersects(clip)
        if !visible && !deep { return nil }

        let isEditable = role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" || subrole == "AXSearchField"
        let isSecure = subrole == "AXSecureTextField"
        var label = title ?? description ?? ""
        var value: String?
        if isSecure {
            label = label.nilIfBlank ?? placeholder ?? "password"
            value = nil
        } else if role == "AXStaticText" {
            label = AX.stringifiedValue(rawValue)?.nilIfBlank ?? label
        } else {
            value = AX.stringifiedValue(rawValue)?.nilIfBlank
            if label.isEmpty, isEditable {
                label = AX.element(node, kAXTitleUIElementAttribute).flatMap { AX.string($0, kAXValueAttribute) }
                    ?? placeholder ?? help ?? ""
            }
            if label.isEmpty { label = help ?? "" }
        }
        // A heading's value is just its level.
        if role == "AXHeading" { value = nil }
        // Checkboxes and radios report 0/1. Make that readable.
        if role == "AXCheckBox" || role == "AXRadioButton" {
            if let number = rawValue as? NSNumber { value = number.boolValue ? "on" : "off" }
        }
        label = Self.collapse(label)
        if mappedRole == "text" || mappedRole == "image" {
            guard !label.isEmpty else { return nil }
            if mappedRole == "text", label.count == 1, !label.first!.isLetter, !label.first!.isNumber { return nil }
        }
        if label.isEmpty, !isEditable, value == nil, mappedRole != "button" { return nil }
        if mappedRole == "button", label.isEmpty {
            // An unlabeled button is still real, but give the model something.
            label = AX.string(node, kAXIdentifierAttribute) ?? ""
            if label.isEmpty { mappedRole = "button" }
        }
        if subrole == "AXCloseButton" { label = "close window" }
        var isFocused = (values[6] as? Bool) ?? false
        if let focusedElement, CFEqual(focusedElement, node) { isFocused = true }
        return UIElement(role: mappedRole, label: label, value: value, frame: frame, enabled: enabled,
                         focused: isFocused, selected: selected, secure: isSecure, editable: isEditable,
                         inModal: modal, offscreen: !visible)
    }

    static func collapse(_ text: String) -> String {
        guard text.contains(where: \.isNewline) || text.contains("  ") || text.contains("\t") else { return text }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

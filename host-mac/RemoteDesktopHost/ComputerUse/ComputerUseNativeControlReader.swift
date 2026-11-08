import AppKit
import ApplicationServices
@MainActor
enum ComputerUseNativeControlReader {
    static func observe(displayBounds: CGRect, windowBounds: CGRect,
        access: ComputerUseNativeControlReader.Access, mayAct: () -> Bool,
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
        var visited: [AXUIElement] = [], seenForBudget: [AXUIElement] = []
        var timedOut: [AXUIElement] = [app.root, window]
        var items: [ComputerUseNativeControls.Item] = [], truncated = false
        func noteBudget(_ node: AXUIElement) -> Bool {
            if seenForBudget.contains(where: { CFEqual($0, node) }) { return true }
            guard seenForBudget.count < 96 else { truncated = true; return false }
            seenForBudget.append(node)
            if !timedOut.contains(where: { CFEqual($0, node) }) {
                timedOut.append(node); access.timeout(node, 0.1)
            }
            return true
        }
        func scan(
            _ start: [(AXUIElement, Bool)],
            depthFirst: Bool,
            prioritizing focusedPath: [AXUIElement]? = nil
        ) throws {
            var pending = start
            while !pending.isEmpty {
                if seenForBudget.count >= 96 || items.count >= ComputerUseNativeControls.maximumItems {
                    truncated = true; return
                }
                let (node, inheritedDisabled): (AXUIElement, Bool) = depthFirst
                    ? pending.removeLast() : pending.removeFirst()
                if visited.contains(where: { CFEqual($0, node) }) { continue }
                guard noteBudget(node) else { return }
                visited.append(node)
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
                    let remaining = max(0, 96 - seenForBudget.count - pending.count)
                    if children.count > remaining { truncated = true }
                    var orderedChildren = children
                    if depthFirst, let focusedPath,
                       let pathIndex = focusedPath.firstIndex(where: { CFEqual($0, node) }), pathIndex > 0 {
                        let focusedChild = focusedPath[pathIndex - 1]
                        if let childIndex = orderedChildren.firstIndex(where: { CFEqual($0, focusedChild) }) {
                            orderedChildren.remove(at: childIndex)
                            orderedChildren.insert(focusedChild, at: 0)
                        }
                    }
                    let additions = orderedChildren.prefix(remaining).map { ($0, enabled == false) }
                    if depthFirst { pending.append(contentsOf: additions.reversed()) }
                    else { pending.append(contentsOf: additions) }
                }
                if expired { return }
            }
        }

        // A focused editor in a web document is often nested below generic
        // containers, while useful controls live earlier in AX child order.
        // Prefer the outermost document on that exact focus path, then fill
        // from the original window BFS without exceeding the shared node cap.
        typealias FocusPath = (elements: [AXUIElement], webArea: AXUIElement?, isSafe: Bool, disabledAboveWebArea: Bool)
        func focusPath(from start: AXUIElement, countForBudget: Bool) throws -> FocusPath? {
            var path: [AXUIElement] = [], current: AXUIElement? = start
            var webArea: AXUIElement?, isSafe = true, disabledAboveWebArea = false
            var hasSeenWebArea = false
            while let node = current, path.count < 16 {
                guard !path.contains(where: { CFEqual($0, node) }) else { return nil }
                if countForBudget, !noteBudget(node) { return nil }
                path.append(node)
                let role = try read(kAXRoleAttribute, node) as? String ?? ""
                let subrole = try read(kAXSubroleAttribute, node) as? String ?? ""
                let sensitiveRole = role == "AXSecureTextField" || subrole == kAXSecureTextFieldSubrole as String
                let protected = sensitiveRole ? false : (try read("AXProtectedContent", node) as? NSNumber)?.boolValue == true
                let hidden = sensitiveRole || protected ? false : (try read("AXHidden", node) as? NSNumber)?.boolValue == true
                if sensitiveRole || protected || hidden { isSafe = false }
                if role == "AXWebArea" { webArea = node; hasSeenWebArea = true; disabledAboveWebArea = false }
                else if hasSeenWebArea, (try read(kAXEnabledAttribute, node) as? NSNumber)?.boolValue == false {
                    disabledAboveWebArea = true
                }
                if CFEqual(node, window) { return (path, webArea, isSafe, disabledAboveWebArea) }
                guard let parent = try element(kAXParentAttribute, node) else { return nil }
                current = parent
            }
            return nil
        }

        let initialFocus = try element(kAXFocusedUIElementAttribute, app.root)
        let initialPath = try initialFocus.flatMap { try focusPath(from: $0, countForBudget: true) }
        let usedPriorityPath = initialPath?.isSafe == true && initialPath?.webArea != nil
        if let initialPath, initialPath.isSafe, let priorityWebArea = initialPath.webArea, !expired {
            try scan([(priorityWebArea, initialPath.disabledAboveWebArea)],
                     depthFirst: true, prioritizing: initialPath.elements)
        }
        if expired { return nil }
        try scan([(window, false)], depthFirst: false)
        if expired { return nil }
        // Geometry is planning data, but still must belong to the screenshot's
        // foreground window. A changed scope cannot publish a mixed catalogue.
        let focusPathUnchanged: Bool
        if usedPriorityPath, let initialFocus, let initialPath {
            let finalFocus = try element(kAXFocusedUIElementAttribute, app.root)
            let finalPath = try finalFocus.flatMap { try focusPath(from: $0, countForBudget: true) }
            if let finalFocus, let finalPath {
                focusPathUnchanged = CFEqual(initialFocus, finalFocus)
                    && initialPath.elements.count == finalPath.elements.count
                    && zip(initialPath.elements, finalPath.elements).allSatisfy { CFEqual($0.0, $0.1) }
                    && initialPath.webArea.map { first in finalPath.webArea.map { CFEqual(first, $0) } ?? false } == true
                    && initialPath.isSafe && finalPath.isSafe
                    && initialPath.disabledAboveWebArea == finalPath.disabledAboveWebArea
            } else { focusPathUnchanged = false }
        } else { focusPathUnchanged = true }
        guard let currentWindow = try element(kAXFocusedWindowAttribute, app.root), CFEqual(currentWindow, window),
              (!usedPriorityPath || focusPathUnchanged),
              try frame(window) == windowBounds, try windowContext() == observedWindow, !expired,
              let current = access.frontmost(), current.identity.utf8.elementsEqual(app.identity.utf8), CFEqual(current.root, app.root) else { return nil }
        try Task.checkCancellation()
        guard mayAct() else { throw ComputerUseHostTools.ToolError.paused }
        return ComputerUseNativeControls(items: items, truncated: truncated, window: observedWindow)
    }

    struct Application {
        let identity: String
        let root: AXUIElement
    }

    struct Access {
        let frontmost: () -> Application?
        let read: (String, AXUIElement) -> CFTypeRef?
        let timeout: (AXUIElement, Float) -> Void

        @MainActor static var live: Access {
            Access(frontmost: {
                guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
                return Application(identity: "\(app.processIdentifier):\(app.launchDate?.timeIntervalSince1970 ?? 0):\(app.bundleURL?.path ?? "")",
                    root: AXUIElementCreateApplication(app.processIdentifier))
            }, read: { name, element in
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
                return value
            }, timeout: { element, duration in _ = AXUIElementSetMessagingTimeout(element, duration) })
        }
    }

}


import AppKit
import ApplicationServices
import Foundation

/// A bounded, read-only Accessibility observation. Its opaque IDs retain the
/// exact AX references but confer no authority to mutate them.
@MainActor
final class ComputerUseDefaultBrowserPageReader {
    struct Control: Equatable, Sendable {
        let id: String
        let role: String
        let label: String
        let frame: CGRect?
        let enabled: Bool?
        let expanded: Bool?

        init(id: String, role: String, label: String, frame: CGRect?, enabled: Bool?, expanded: Bool? = nil) {
            self.id = id; self.role = role; self.label = label
            self.frame = frame; self.enabled = enabled; self.expanded = expanded
        }
    }

    struct Observation: Equatable, Sendable {
        struct FormFieldValue: Equatable, Sendable {
            let label: String
            let role: String
            let value: String
            let help: String

            init(label: String, role: String, value: String, help: String = "") {
                self.label = label; self.role = role; self.value = value; self.help = help
            }
        }
        let id: String
        let application: ComputerUseApplicationIdentity
        let url: String
        /// Rendered AX-tree text, not a claim of pixel visibility.
        let renderedAXText: String
        /// Complete text values observed on the current outer page. Empty for
        /// older or synthetic observations that do not carry this evidence.
        let exactTextValues: [String]
        /// Bounded values for ordinary editable controls on the outer page.
        /// Secure/protected controls and nested web areas are excluded.
        let formFieldValues: [FormFieldValue]
        let controls: [Control]
        /// Safari/Chromium AX trees may omit or flatten iframe contents.
        /// This reader does not claim those contents are complete.
        let iframeContentMayBeOmitted: Bool
        let truncated: Bool
        let focusedExpandedMenuHasNoActionableChildren: Bool

        init(id: String, application: ComputerUseApplicationIdentity, url: String, renderedAXText: String,
             controls: [Control], iframeContentMayBeOmitted: Bool, truncated: Bool,
             focusedExpandedMenuHasNoActionableChildren: Bool = false, exactTextValues: [String] = [],
             formFieldValues: [FormFieldValue] = []) {
            self.id = id
            self.application = application
            self.url = url
            self.renderedAXText = renderedAXText
            self.exactTextValues = exactTextValues
            self.formFieldValues = formFieldValues
            self.controls = controls
            self.iframeContentMayBeOmitted = iframeContentMayBeOmitted
            self.truncated = truncated
            self.focusedExpandedMenuHasNoActionableChildren = focusedExpandedMenuHasNoActionableChildren
        }
    }

    struct Access {
        let frontmost: () -> (ComputerUseApplicationIdentity, AXUIElement)?
        let read: (String, AXUIElement) -> CFTypeRef?
        let timeout: (AXUIElement, Float) -> Void
        /// Optional read-only point hit test. A missing element is unknown;
        /// callers resolve its bounded AX parent chain before using it.
        var hitTestElementAtPoint: (CGPoint) -> AXUIElement? = { _ in nil }

        @MainActor static var live: Access {
            Access(frontmost: {
                guard let app = NSWorkspace.shared.frontmostApplication,
                      let identity = ComputerUseApplicationIdentity(runningApplication: app),
                      identity.codeIdentity != nil else { return nil }
                return (identity, AXUIElementCreateApplication(app.processIdentifier))
            }, read: { name, element in
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
                return value
            }, timeout: { element, duration in
                _ = AXUIElementSetMessagingTimeout(element, duration)
            }, hitTestElementAtPoint: { point in
                let systemWide = AXUIElementCreateSystemWide()
                _ = AXUIElementSetMessagingTimeout(systemWide, 0.1)
                var element: AXUIElement?
                guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success else {
                    return nil
                }
                return element
            })
        }
    }

    private struct Retained {
        let application: ComputerUseApplicationIdentity
        let window: AXUIElement
        let webArea: AXUIElement
        let url: String
        let controls: [String: AXUIElement]
        let controlMetadata: [String: Control]
    }

    private let access: Access
    private var retained: [String: Retained] = [:]
    private let contextByteLimit = 8_192
    /// Each bounded pass visits at most this many nodes; all passes share a
    /// 750ms deadline and each AX IPC is configured for at most 0.1s.
    private let nodeLimitPerPass = 256

    init(access: Access? = nil) { self.access = access ?? .live }

    /// Reads only the HTTPS URL from the exact retained page while the user
    /// interface may be focused on a recognized native panel. This grants no
    /// authority to inspect controls or act on the page.
    func readRetainedPageURL(window expectedWindow: AXUIElement,
                             application expectedApplication: ComputerUseApplicationIdentity,
                             mayAct: () -> Bool) throws -> String? {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(750))
        var expired = false
        func check() throws {
            try Task.checkCancellation()
            guard mayAct() else { throw ComputerUseHostTools.ToolError.paused }
            if ContinuousClock.now >= deadline { expired = true }
        }
        func value(_ name: String, _ element: AXUIElement) throws -> CFTypeRef? {
            try check()
            guard !expired else { return nil }
            access.timeout(element, 0.1)
            let result = access.read(name, element)
            try check()
            return expired ? nil : result
        }
        func string(_ name: String, _ element: AXUIElement) throws -> String? {
            guard let raw = try value(name, element) else { return nil }
            if let string = raw as? String { return string }
            if let url = raw as? URL { return url.absoluteString }
            return nil
        }
        func isPruned(_ node: AXUIElement) throws -> Bool {
            let role = try string(kAXRoleAttribute as String, node) ?? ""
            let subrole = try string(kAXSubroleAttribute as String, node) ?? ""
            let hidden = (try value(kAXHiddenAttribute as String, node) as? NSNumber)?.boolValue == true
            let protected = (try value("AXProtectedContent", node) as? NSNumber)?.boolValue == true
            return role == "AXSecureTextField" || subrole == (kAXSecureTextFieldSubrole as String)
                || hidden || protected
        }
        func currentRoot() throws -> AXUIElement? {
            guard let (identity, root) = access.frontmost(), identity == expectedApplication else { return nil }
            return root
        }
        func listedWindow(_ root: AXUIElement) throws -> Bool {
            guard let windows = try value(kAXWindowsAttribute as String, root) as? [AXUIElement],
                  windows.filter({ CFEqual($0, expectedWindow) }).count == 1,
                  (try string(kAXRoleAttribute as String, expectedWindow)) == "AXWindow" else { return false }
            return true
        }
        func uniqueOuterWebArea(in window: AXUIElement) throws -> AXUIElement? {
            var pending = [window]
            var visited: [AXUIElement] = []
            var found: [AXUIElement] = []
            var incomplete = false
            while !pending.isEmpty, visited.count < nodeLimitPerPass, !expired {
                try check()
                let node = pending.removeFirst()
                guard !visited.contains(where: { CFEqual($0, node) }) else { continue }
                visited.append(node)
                if try isPruned(node) { continue }
                let role = try string(kAXRoleAttribute as String, node) ?? ""
                if role == "AXSheet" { continue }
                if role == "AXWebArea" {
                    found.append(node)
                    continue
                }
                if let children = try value(kAXChildrenAttribute as String, node) as? [AXUIElement] {
                    let room = max(0, nodeLimitPerPass - visited.count - pending.count)
                    if children.count > room { incomplete = true }
                    pending.append(contentsOf: children.prefix(room))
                }
            }
            guard pending.isEmpty, !incomplete, !expired, found.count == 1 else { return nil }
            return found[0]
        }
        func httpsURL(from webArea: AXUIElement) throws -> String? {
            guard let rawURL = try string("AXURL", webArea) ?? string(kAXDocumentAttribute as String, webArea),
                  let components = URLComponents(string: rawURL), components.scheme?.lowercased() == "https",
                  let host = components.host, !host.isEmpty else { return nil }
            return rawURL
        }

        try check()
        guard let root = try currentRoot(), try listedWindow(root),
              let webArea = try uniqueOuterWebArea(in: expectedWindow),
              let url = try httpsURL(from: webArea) else { return nil }
        try check()
        guard let afterRoot = try currentRoot(), CFEqual(afterRoot, root),
              try listedWindow(afterRoot),
              let afterWebArea = try uniqueOuterWebArea(in: expectedWindow),
              CFEqual(afterWebArea, webArea), try httpsURL(from: afterWebArea) == url,
              !expired else { return nil }
        return url
    }

    func read(window expectedWindow: AXUIElement,
              application expectedApplication: ComputerUseApplicationIdentity,
              mayAct: () -> Bool, diagnostic: ((String, [String]) -> Void)? = nil) throws -> Observation? {
        var focusedAncestorRoles: [String] = []
        let safeRoles: Set<String> = ["AXWindow", "AXWebArea", "AXGroup", "AXTextArea", "AXTextField",
            "AXSecureTextField", "AXButton", "AXComboBox", "AXStaticText", "AXLink", "AXOther"]
        func recordRole(_ role: String) {
            let safe = safeRoles.contains(role) ? role : "AXOther"
            if focusedAncestorRoles.count < 16 { focusedAncestorRoles.append(safe) }
        }
        func fail(_ reason: String) -> Observation? {
            diagnostic?(reason, focusedAncestorRoles)
            return nil
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(750))
        var expired = false
        func check() throws {
            try Task.checkCancellation()
            guard mayAct() else { throw ComputerUseHostTools.ToolError.paused }
            if ContinuousClock.now >= deadline { expired = true }
        }
        func value(_ name: String, _ element: AXUIElement) throws -> CFTypeRef? {
            try check()
            guard !expired else { return nil }
            access.timeout(element, 0.1)
            let result = access.read(name, element)
            try check()
            return expired ? nil : result
        }
        func element(_ name: String, _ source: AXUIElement) throws -> AXUIElement? {
            guard let raw = try value(name, source), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(raw, to: AXUIElement.self)
        }
        func string(_ name: String, _ source: AXUIElement) throws -> String? {
            guard let raw = try value(name, source) else { return nil }
            if let text = raw as? String { return text }
            if let url = raw as? URL { return url.absoluteString }
            return nil
        }
        func frame(_ source: AXUIElement) throws -> CGRect? {
            guard let p = try value(kAXPositionAttribute as String, source),
                  let s = try value(kAXSizeAttribute as String, source),
                  CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size),
                  point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
                  size.width >= 0, size.height >= 0 else { return nil }
            return CGRect(origin: point, size: size)
        }
        func currentScope() throws -> (AXUIElement, AXUIElement)? {
            guard let (currentIdentity, root) = access.frontmost(), currentIdentity == expectedApplication,
                  let focused = try element(kAXFocusedWindowAttribute, root), CFEqual(focused, expectedWindow) else { return nil }
            return (root, focused)
        }
        try check()
        guard let (root, focused) = try currentScope() else { return fail("scope_unavailable") }
        let focusedUIElement = try element(kAXFocusedUIElementAttribute as String, root)
        var truncated = false
        func isPruned(_ node: AXUIElement) throws -> Bool {
            let role = try string(kAXRoleAttribute as String, node) ?? ""
            let subrole = try string(kAXSubroleAttribute as String, node) ?? ""
            let protected = (try value("AXProtectedContent", node) as? NSNumber)?.boolValue == true
            let hidden = (try value("AXHidden", node) as? NSNumber)?.boolValue == true
            return role == "AXSecureTextField" || subrole == (kAXSecureTextFieldSubrole as String) || protected || hidden
        }
        func discoverOuterWebArea() throws -> AXUIElement? {
            var pending = [focused], seen: [AXUIElement] = [], found: [AXUIElement] = []
            var incomplete = false
            while !pending.isEmpty, seen.count < nodeLimitPerPass, !expired {
                let node = pending.removeFirst()
                if seen.contains(where: { CFEqual($0, node) }) { continue }
                seen.append(node)
                if try isPruned(node) { continue }
                let role = try string(kAXRoleAttribute as String, node) ?? ""
                if role == "AXWebArea" { found.append(node); continue }
                if let children = try value(kAXChildrenAttribute as String, node) as? [AXUIElement] {
                    let room = max(0, nodeLimitPerPass - seen.count - pending.count)
                    if children.count > room { truncated = true; incomplete = true }
                    pending.append(contentsOf: children.prefix(room))
                }
            }
            guard pending.isEmpty, !expired, !incomplete, found.count == 1 else { return nil }
            return found[0]
        }
        _ = root
        // Stop at each AXWebArea, so nested iframe content is not treated as
        // an outer page. Multiple discovered outer areas are ambiguous.
        guard let webArea = try discoverOuterWebArea() else {
            return fail(expired ? "outer_page_discovery_deadline" : "outer_page_discovery_incomplete_or_ambiguous")
        }
        let controlRoles: Set<String> = ["AXButton", "AXLink", "AXTextField", "AXTextArea", "AXComboBox",
            "AXPopUpButton", "AXCheckBox", "AXRadioButton"]
        var focusedControlIsInPage: Bool?
        var focusedNodeIsInPage = false
        var focusedPagePath: [AXUIElement] = []
        var focusedPathControls: [AXUIElement] = []
        if let focusedUIElement {
            let focusedRole = try string(kAXRoleAttribute as String, focusedUIElement) ?? ""
            var node = focusedUIElement
            var seen: [AXUIElement] = []
            var reachedBoundary = false
            for _ in 0..<16 {
                try check()
                guard !expired else { return fail("deadline_during_focus_ancestry") }
                guard !seen.contains(where: { CFEqual($0, node) }) else { return fail("focused_ancestry_cycle") }
                seen.append(node)
                let nodeRole = try string(kAXRoleAttribute as String, node) ?? ""
                recordRole(nodeRole)
                if try isPruned(node) { return fail("focused_ancestry_pruned") }
                if CFEqual(node, webArea) {
                    focusedNodeIsInPage = true
                    focusedControlIsInPage = controlRoles.contains(focusedRole)
                    focusedPagePath = seen.reversed()
                    reachedBoundary = true
                    break
                }
                if controlRoles.contains(nodeRole) { focusedPathControls.append(node) }
                if nodeRole == "AXWebArea" { return fail("focused_nested_webarea_boundary") }
                if CFEqual(node, focused) { reachedBoundary = true; break }
                guard let parent = try element(kAXParentAttribute as String, node) else { return fail("focused_ancestry_parent_missing") }
                node = parent
            }
            guard reachedBoundary else { return fail("focused_ancestry_limit_or_window_mismatch") }
            // A focused browser-chrome control is outside the page, but the
            // retained same-window page remains a valid observation.
            if focusedControlIsInPage == nil { focusedControlIsInPage = false }
        }
        guard let url = try string("AXURL", webArea) ?? string(kAXDocumentAttribute as String, webArea),
              let parsed = URL(string: url), parsed.scheme?.lowercased() == "https", parsed.host != nil else {
            return fail("outer_page_url_unavailable_or_unsupported")
        }

        var text = "", controls: [Control] = [], controlRefs: [String: AXUIElement] = [:]
        var exactTextValues: [String] = []
        var formFieldValues: [Observation.FormFieldValue] = []
        var formFieldBytes = 0
        var exactTextBytes = 0
        let exactTextValueLimit = 32
        let exactTextByteLimit = 4_096
        let formFieldValueLimit = 32
        let formFieldByteLimit = 4_096
        var focusedEmptyExpandedMenu: AXUIElement?
        var contextBytes = 0
        // Start at the exact outer page, preserving the normal pruning and
        // inherited-disabled checks while visiting the verified focus branch first.
        var contentQueue: [(AXUIElement, Bool)] = [(webArea, false)]
        var contentVisited: [AXUIElement] = []
        func bounded(_ chunk: String, to bytes: Int) -> String {
            var result = "", used = 0
            for scalar in chunk.unicodeScalars {
                let value = String(scalar), count = value.utf8.count
                guard used + count <= bytes else { truncated = true; break }
                result += value; used += count
            }
            return result
        }
        func appendText(_ chunk: String) {
            guard !chunk.isEmpty else { return }
            let separator = text.isEmpty ? "" : "\n"
            let available = contextByteLimit - contextBytes - separator.utf8.count
            guard available > 0 else { truncated = true; return }
            let prefix = bounded(chunk, to: available)
            if !prefix.isEmpty { text += separator + prefix; contextBytes += separator.utf8.count + prefix.utf8.count }
        }
        func appendExactText(_ value: String) {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard exactTextValues.count < exactTextValueLimit else {
                truncated = true
                return
            }
            var byteCount = 0
            for _ in value.utf8 {
                byteCount += 1
                guard exactTextBytes + byteCount <= exactTextByteLimit else {
                    truncated = true
                    return
                }
            }
            exactTextValues.append(value)
            exactTextBytes += byteCount
        }
        while !contentQueue.isEmpty, contentVisited.count < nodeLimitPerPass, !expired {
            let (node, inheritedDisabled) = focusedPagePath.isEmpty
                ? contentQueue.removeFirst() : contentQueue.removeLast()
            if contentVisited.contains(where: { CFEqual($0, node) }) { continue }
            contentVisited.append(node)
            if try isPruned(node) { continue }
            let role = try string(kAXRoleAttribute as String, node) ?? ""
            let nodeEnabled = (try value(kAXEnabledAttribute as String, node) as? NSNumber)?.boolValue
            let effectiveEnabled = inheritedDisabled ? false : nodeEnabled
            // Nested AXWebAreas are iframe/document boundaries: deliberately omit their subtree.
            if !CFEqual(node, webArea), role == "AXWebArea" { continue }
            if role == "AXStaticText", let label = try string(kAXValueAttribute as String, node) ?? string(kAXTitleAttribute as String, node) {
                appendText(label)
                appendExactText(label)
            }
            if role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox",
               (try string(kAXSubroleAttribute as String, node)) != (kAXSecureTextFieldSubrole as String),
               (try value("AXProtectedContent", node) as? NSNumber)?.boolValue != true,
               let fieldValue = try string(kAXValueAttribute as String, node) {
                let fieldLabel = try string(kAXTitleAttribute as String, node)
                    ?? string(kAXDescriptionAttribute as String, node)
                    ?? string(kAXPlaceholderValueAttribute as String, node) ?? ""
                let help = try string(kAXHelpAttribute as String, node) ?? ""
                let cost = fieldLabel.utf8.count + role.utf8.count + fieldValue.utf8.count + help.utf8.count
                if formFieldValues.count < formFieldValueLimit, formFieldBytes + cost <= formFieldByteLimit {
                    formFieldValues.append(.init(label: fieldLabel, role: role, value: fieldValue, help: help))
                    formFieldBytes += cost
                } else { truncated = true }
            }
            if controlRoles.contains(role), controls.count < 32 {
                let label = try string(kAXTitleAttribute as String, node) ?? string(kAXDescriptionAttribute as String, node)
                    ?? string(kAXPlaceholderValueAttribute as String, node) ?? ""
                appendExactText(label)
                let rawExpanded = try value("AXExpanded", node)
                let expanded = rawExpanded.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? ($0 as? NSNumber)?.boolValue : nil }
                let isFocusedExpandedMenu = (role == "AXButton" || role == "AXPopUpButton")
                    && effectiveEnabled == true && expanded == true
                    && focusedUIElement.map { CFEqual(node, $0) } == true
                var hasKnownEmptyMenuChildren = false
                if isFocusedExpandedMenu {
                    let menuChildren = try value(kAXChildrenAttribute as String, node) as? [AXUIElement]
                    hasKnownEmptyMenuChildren = menuChildren?.isEmpty == true
                }
                let id = UUID().uuidString
                let safeRole = bounded(role, to: max(0, contextByteLimit - contextBytes))
                let safeLabel = bounded(label, to: min(256, max(0, contextByteLimit - contextBytes - safeRole.utf8.count)))
                let cost = id.utf8.count + safeRole.utf8.count + safeLabel.utf8.count
                if controls.count < 32, contextBytes + cost <= contextByteLimit {
                    controls.append(Control(id: id, role: safeRole, label: safeLabel,
                                            frame: try frame(node), enabled: effectiveEnabled, expanded: expanded))
                    contextBytes += cost
                    controlRefs[id] = node
                    if hasKnownEmptyMenuChildren { focusedEmptyExpandedMenu = node }
                } else { truncated = true }
            } else if controlRoles.contains(role) {
                // A recognized control omitted at the item cap makes this page partial.
                truncated = true
            }
            if let children = try value(kAXChildrenAttribute as String, node) as? [AXUIElement] {
                let pathIndex = focusedPagePath.firstIndex(where: { CFEqual($0, node) })
                let nextFocusedNode = pathIndex.flatMap { index in
                    index + 1 < focusedPagePath.count ? focusedPagePath[index + 1] : nil
                }
                let priorityNode = nextFocusedNode.flatMap { expected in
                    children.first(where: { CFEqual($0, expected) })
                }
                let desiredCount = min(children.count, pathIndex == nil ? nodeLimitPerPass : 32)
                var selectedChildren = Array(children.prefix(desiredCount))
                if let priorityNode {
                    if let selectedIndex = selectedChildren.firstIndex(where: { CFEqual($0, priorityNode) }) {
                        selectedChildren.remove(at: selectedIndex)
                    } else if !selectedChildren.isEmpty {
                        selectedChildren.removeLast()
                    }
                    selectedChildren.append(priorityNode)
                }
                let desiredPendingCount = min(selectedChildren.count, nodeLimitPerPass)
                if pathIndex != nil, contentQueue.count + desiredPendingCount > nodeLimitPerPass {
                    let evictCount = contentQueue.count + desiredPendingCount - nodeLimitPerPass
                    if evictCount <= contentQueue.count {
                        contentQueue.removeFirst(evictCount)
                        truncated = true
                    }
                }
                let room = max(0, nodeLimitPerPass - contentVisited.count - contentQueue.count)
                if focusedPagePath.isEmpty {
                    // Preserve the existing breadth-first ordering and admission
                    // exactly when no verified in-page focus path is available.
                    if children.count > room { truncated = true }
                    contentQueue.append(contentsOf: children.prefix(room).map { ($0, inheritedDisabled || (effectiveEnabled == false)) })
                } else {
                    if children.count > desiredCount || selectedChildren.count > room { truncated = true }
                    if selectedChildren.count > room {
                        selectedChildren = pathIndex == nil
                            ? Array(selectedChildren.prefix(room)) : Array(selectedChildren.suffix(room))
                    }
                    // A stack pops the last sibling first. Reverse the ordinary
                    // sibling sequence, then put the verified focus child last.
                    if let priorityNode, let index = selectedChildren.firstIndex(where: { CFEqual($0, priorityNode) }) {
                        selectedChildren.remove(at: index)
                        selectedChildren.reverse()
                        selectedChildren.append(priorityNode)
                    } else {
                        selectedChildren.reverse()
                    }
                    contentQueue.append(contentsOf: selectedChildren.map { ($0, inheritedDisabled || (effectiveEnabled == false)) })
                }
            }
        }
        if !contentQueue.isEmpty || contentVisited.count >= nodeLimitPerPass { truncated = true }
        try check()
        guard !expired, let (afterRoot, afterWindow) = try currentScope(),
              CFEqual(afterRoot, root), CFEqual(afterWindow, expectedWindow),
              let finalArea = try discoverOuterWebArea(), CFEqual(finalArea, webArea) else {
            return fail("page_scope_or_outer_area_changed")
        }
        if let focusedUIElement {
            guard let finalFocus = try element(kAXFocusedUIElementAttribute as String, afterRoot),
                  CFEqual(finalFocus, focusedUIElement) else { return fail("focused_element_changed_during_read") }
            if focusedNodeIsInPage {
                var finalPath: [AXUIElement] = []
                var pathNode = finalFocus
                var reachedOuterPage = false
                for _ in 0..<16 {
                    guard !finalPath.contains(where: { CFEqual($0, pathNode) }),
                          try !isPruned(pathNode) else { return fail("focused_path_changed_or_became_pruned") }
                    finalPath.append(pathNode)
                    if CFEqual(pathNode, webArea) { reachedOuterPage = true; break }
                    let role = try string(kAXRoleAttribute as String, pathNode) ?? ""
                    guard role != "AXWebArea",
                          let parent = try element(kAXParentAttribute as String, pathNode) else {
                        return fail("focused_path_no_longer_reaches_outer_page")
                    }
                    pathNode = parent
                }
                guard reachedOuterPage, finalPath.count == focusedPagePath.count,
                      zip(finalPath, focusedPagePath.reversed()).allSatisfy({ CFEqual($0.0, $0.1) }) else {
                    return fail("focused_path_changed_during_read")
                }
                guard contentVisited.contains(where: { CFEqual($0, focusedUIElement) }) else {
                    return fail("focused_node_not_visited_by_content_walk")
                }
                guard focusedPathControls.allSatisfy({ pathControl in
                    controlRefs.values.contains(where: { CFEqual($0, pathControl) })
                }) else { return fail("focused_ancestor_control_not_in_catalogue") }
            }
            if focusedControlIsInPage == true,
               !controlRefs.values.contains(where: { CFEqual($0, focusedUIElement) }) {
                return fail("focused_control_not_in_catalogue")
            }
        } else if try element(kAXFocusedUIElementAttribute as String, afterRoot) != nil {
            return fail("focused_element_appeared_during_read")
        }
        var focusedExpandedMenuHasNoActionableChildren = false
        if let focusedEmptyExpandedMenu, let focusedUIElement,
           CFEqual(focusedEmptyExpandedMenu, focusedUIElement),
           let finalFocus = try element(kAXFocusedUIElementAttribute as String, afterRoot),
           CFEqual(finalFocus, focusedEmptyExpandedMenu),
           let role = try string(kAXRoleAttribute as String, focusedEmptyExpandedMenu),
           (role == "AXButton" || role == "AXPopUpButton"),
           (try value(kAXEnabledAttribute as String, focusedEmptyExpandedMenu) as? NSNumber)?.boolValue == true,
           (try value("AXExpanded", focusedEmptyExpandedMenu) as? NSNumber)?.boolValue == true,
           let finalChildren = try value(kAXChildrenAttribute as String, focusedEmptyExpandedMenu) as? [AXUIElement],
           finalChildren.isEmpty {
            focusedExpandedMenuHasNoActionableChildren = true
        }
        // Re-discover the same unique outer page after content collection.
        let finalURL = try string("AXURL", webArea) ?? string(kAXDocumentAttribute as String, webArea)
        guard finalURL == url, !expired else { return fail(expired ? "deadline_during_final_validation" : "outer_page_url_changed") }
        let observationID = UUID().uuidString
        let observation = Observation(id: observationID, application: expectedApplication, url: url,
            renderedAXText: text, controls: controls, iframeContentMayBeOmitted: true, truncated: truncated,
            focusedExpandedMenuHasNoActionableChildren: focusedExpandedMenuHasNoActionableChildren,
            exactTextValues: exactTextValues, formFieldValues: formFieldValues)
        retained[observationID] = Retained(application: expectedApplication, window: expectedWindow,
            webArea: webArea, url: url, controls: controlRefs,
            controlMetadata: Dictionary(uniqueKeysWithValues: controls.map { ($0.id, $0) }))
        if retained.count > 32,
           let evictedID = retained.keys.first(where: { $0 != observationID }) {
            retained.removeValue(forKey: evictedID)
        }
        try check()
        return observation
    }

    /// Resolve only a reference retained by this exact observation. This API
    /// provides no action; callers must independently validate before acting.
    func retainedControl(observationID: String, controlID: String,
                        application: ComputerUseApplicationIdentity,
                        window: AXUIElement) -> AXUIElement? {
        guard let snapshot = retained[observationID], snapshot.application == application,
              CFEqual(snapshot.window, window) else { return nil }
        return snapshot.controls[controlID]
    }

    /// Returns a host-derived click center only when the retained control is
    /// still the same enabled, bounded control on the freshly observed page.
    func validatedControlCenter(observation: Observation, controlID: String,
                                window: AXUIElement, windowBounds: CGRect,
                                mayAct: () -> Bool) throws -> CGPoint? {
        try Task.checkCancellation()
        guard mayAct() else { throw ComputerUseHostTools.ToolError.paused }
        guard let original = retained[observation.id],
              original.application == observation.application,
              CFEqual(original.window, window),
              original.url == observation.url,
              let originalElement = original.controls[controlID],
              let originalControl = original.controlMetadata[controlID],
              let suppliedControl = observation.controls.first(where: { $0.id == controlID }),
              suppliedControl == originalControl,
              Self.permittedCenterMetadata(originalControl, within: windowBounds) != nil else { return nil }

        guard let fresh = try read(window: window, application: original.application, mayAct: mayAct) else { return nil }
        try Task.checkCancellation()
        guard mayAct() else { throw ComputerUseHostTools.ToolError.paused }
        guard fresh.application == original.application, fresh.url == original.url,
              let current = retained[fresh.id], current.application == original.application,
              CFEqual(current.window, window), CFEqual(current.webArea, original.webArea),
              current.url == original.url,
              let freshControl = fresh.controls.first(where: { id in
                  guard let element = current.controls[id.id] else { return false }
                  return CFEqual(element, originalElement)
              }),
              Self.sameControlMetadata(originalControl, freshControl),
              let center = Self.permittedCenterMetadata(freshControl, within: windowBounds) else { return nil }
        guard try hitPathAtPoint(center, contains: originalElement, webArea: original.webArea,
                                 window: original.window, mayAct: mayAct) else { return nil }
        return center
    }

    private func hitPathAtPoint(_ point: CGPoint, contains control: AXUIElement, webArea: AXUIElement,
                                window: AXUIElement, mayAct: () -> Bool) throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(750))
        func check() throws -> Bool {
            try Task.checkCancellation()
            guard mayAct() else { throw ComputerUseHostTools.ToolError.paused }
            return ContinuousClock.now < deadline
        }
        guard try check() else { return false }
        let rawHit = access.hitTestElementAtPoint(point)
        guard try check() else { return false }
        guard let hit = rawHit else { return false }

        var current: AXUIElement? = hit
        var ancestors: [AXUIElement] = []
        var foundControl = false, foundWebArea = false
        for _ in 0..<16 {
            guard try check() else { return false }
            guard let element = current else { return false }
            guard !ancestors.contains(where: { CFEqual($0, element) }) else { return false }
            ancestors.append(element)
            if CFEqual(element, control) { foundControl = true }
            if CFEqual(element, webArea) { foundWebArea = true }
            if CFEqual(element, window) { return foundControl && foundWebArea }

            access.timeout(element, 0.1)
            let rawParent = access.read(kAXParentAttribute as String, element)
            guard try check() else { return false }
            guard let rawParent, CFGetTypeID(rawParent) == AXUIElementGetTypeID() else { return false }
            current = unsafeBitCast(rawParent, to: AXUIElement.self)
        }
        return false
    }

    private static func sameControlMetadata(_ lhs: Control, _ rhs: Control) -> Bool {
        lhs.role == rhs.role && lhs.label == rhs.label && lhs.frame == rhs.frame
            && lhs.enabled == rhs.enabled && lhs.expanded == rhs.expanded
    }

    private static func permittedCenterMetadata(_ control: Control, within bounds: CGRect) -> CGPoint? {
        // Revalidated editor centers allow focusing by click, not text entry.
        let permittedRoles: Set<String> = ["AXButton", "AXLink", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
            "AXTextField", "AXTextArea", "AXComboBox"]
        guard permittedRoles.contains(control.role),
              !control.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              control.enabled == true,
              let frame = control.frame, !frame.isEmpty,
              [bounds.minX, bounds.minY, bounds.width, bounds.height,
               frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0, frame.width > 0, frame.height > 0,
              bounds.contains(frame) else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return center.x.isFinite && center.y.isFinite ? center : nil
    }

}

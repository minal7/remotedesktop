import AppKit
import ApplicationServices
import Foundation

/// A bounded, read-only Accessibility observation. Its opaque IDs retain the
/// exact AX references but confer no authority to mutate them.
@MainActor
final class ComputerUseDefaultBrowserPageReader {
    struct Control: Equatable {
        let id: String
        let role: String
        let label: String
        let frame: CGRect?
        let enabled: Bool?
    }

    struct Observation: Equatable {
        let id: String
        let application: ComputerUseApplicationIdentity
        let url: String
        /// Rendered AX-tree text, not a claim of pixel visibility.
        let renderedAXText: String
        let controls: [Control]
        /// Safari/Chromium AX trees may omit or flatten iframe contents.
        /// This reader does not claim those contents are complete.
        let iframeContentMayBeOmitted: Bool
        let truncated: Bool
    }

    struct Access {
        let frontmost: () -> (ComputerUseApplicationIdentity, AXUIElement)?
        let read: (String, AXUIElement) -> CFTypeRef?
        let timeout: (AXUIElement, Float) -> Void

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
            })
        }
    }

    private struct Retained {
        let application: ComputerUseApplicationIdentity
        let window: AXUIElement
        let webArea: AXUIElement
        let controls: [String: AXUIElement]
    }

    private let access: Access
    private var retained: [String: Retained] = [:]
    private let contextByteLimit = 8_192
    /// Each bounded pass visits at most this many nodes; all passes share a
    /// 750ms deadline and each AX IPC is configured for at most 0.1s.
    private let nodeLimitPerPass = 256

    init(access: Access? = nil) { self.access = access ?? .live }

    func read(window expectedWindow: AXUIElement,
              application expectedApplication: ComputerUseApplicationIdentity,
              mayAct: () -> Bool) throws -> Observation? {
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
        guard let (root, focused) = try currentScope() else { return nil }
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
        guard let webArea = try discoverOuterWebArea() else { return nil }
        guard let url = try string("AXURL", webArea) ?? string(kAXDocumentAttribute as String, webArea),
              let parsed = URL(string: url), parsed.scheme?.lowercased() == "https", parsed.host != nil else { return nil }

        var text = "", controls: [Control] = [], controlRefs: [String: AXUIElement] = [:]
        var contextBytes = 0
        var contentQueue: [(AXUIElement, Bool)] = [(webArea, false)]
        var contentVisited: [AXUIElement] = []
        let controlRoles: Set<String> = ["AXButton", "AXLink", "AXTextField", "AXTextArea", "AXPopUpButton", "AXCheckBox", "AXRadioButton"]
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
        while !contentQueue.isEmpty, contentVisited.count < nodeLimitPerPass, !expired {
            let (node, inheritedDisabled) = contentQueue.removeFirst()
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
            }
            if controlRoles.contains(role), controls.count < 32 {
                let label = try string(kAXTitleAttribute as String, node) ?? string(kAXDescriptionAttribute as String, node)
                    ?? string(kAXPlaceholderValueAttribute as String, node) ?? ""
                let id = UUID().uuidString
                let safeRole = bounded(role, to: max(0, contextByteLimit - contextBytes))
                let safeLabel = bounded(label, to: min(256, max(0, contextByteLimit - contextBytes - safeRole.utf8.count)))
                let cost = id.utf8.count + safeRole.utf8.count + safeLabel.utf8.count
                if controls.count < 32, contextBytes + cost <= contextByteLimit {
                    controls.append(Control(id: id, role: safeRole, label: safeLabel,
                                            frame: try frame(node), enabled: effectiveEnabled))
                    contextBytes += cost
                    controlRefs[id] = node
                } else { truncated = true }
            }
            if let children = try value(kAXChildrenAttribute as String, node) as? [AXUIElement] {
                let room = max(0, nodeLimitPerPass - contentVisited.count - contentQueue.count)
                if children.count > room { truncated = true }
                    contentQueue.append(contentsOf: children.prefix(room).map { ($0, inheritedDisabled || (effectiveEnabled == false)) })
            }
        }
        if !contentQueue.isEmpty || contentVisited.count >= nodeLimitPerPass { truncated = true }
        try check()
        guard !expired, let (afterRoot, afterWindow) = try currentScope(),
              CFEqual(afterRoot, root), CFEqual(afterWindow, expectedWindow),
              let finalArea = try discoverOuterWebArea(), CFEqual(finalArea, webArea) else { return nil }
        // Re-discover the same unique outer page after content collection.
        let finalURL = try string("AXURL", webArea) ?? string(kAXDocumentAttribute as String, webArea)
        guard finalURL == url, !expired else { return nil }
        let observationID = UUID().uuidString
        retained[observationID] = Retained(application: expectedApplication, window: expectedWindow,
                                           webArea: webArea, controls: controlRefs)
        if retained.count > 32 { retained.removeValue(forKey: retained.keys.first!) }
        try check()
        return Observation(id: observationID, application: expectedApplication, url: url,
                           renderedAXText: text, controls: controls, iframeContentMayBeOmitted: true, truncated: truncated)
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

}

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
        enum MetadataAttributeResult {
            case value(CFTypeRef)
            case unavailable
            case error(AXError)
        }

        let frontmost: () -> (ComputerUseApplicationIdentity, AXUIElement)?
        let read: (String, AXUIElement) -> CFTypeRef?
        let timeout: (AXUIElement, Float) -> Void
        /// Optional positional results for the four attributes used before
        /// pruning an outer-page node: role, subrole, hidden, protected.
        var readOuterMetadata: ((AXUIElement) -> [MetadataAttributeResult]?)? = nil
        /// Optional read-only point hit test. A missing element is unknown;
        /// callers resolve its bounded AX parent chain before using it.
        var hitTestElementAtPoint: (CGPoint) -> AXUIElement? = { _ in nil }

        @MainActor static var live: Access {
            var access = Access(frontmost: {
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
            access.readOuterMetadata = { element in
                let names = [kAXRoleAttribute as String, kAXSubroleAttribute as String,
                    "AXHidden", "AXProtectedContent"]
                var rawValues: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &rawValues) == .success,
                      let rawValues, CFArrayGetCount(rawValues) == names.count else { return nil }
                return names.indices.map { index in
                    let raw = unsafeBitCast(CFArrayGetValueAtIndex(rawValues, index), to: CFTypeRef.self)
                    if CFGetTypeID(raw) == CFNullGetTypeID() { return .unavailable }
                    if CFGetTypeID(raw) == AXValueGetTypeID(), AXValueGetType(raw as! AXValue) == .axError {
                        var error: AXError = .success
                        guard AXValueGetValue(raw as! AXValue, .axError, &error) else { return .error(.failure) }
                        return error == .noValue || error == .attributeUnsupported
                            ? .unavailable : .error(error)
                    }
                    return .value(raw)
                }
            }
            return access
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

    private struct OuterPageInventory {
        let pages: [AXUIElement]
        let sheetFrames: [CGRect]
        let complete: Bool
        let recoverableMissingRequiredChildren: Bool
    }

    private let access: Access
    private var retained: [String: Retained] = [:]
    private let contextByteLimit = 8_192
    /// Each bounded pass visits at most this many nodes. Each AX IPC remains configured for at most 0.1s.
    private let nodeLimitPerPass = 256

    init(access: Access? = nil) { self.access = access ?? .live }

    private func readFrame(_ element: AXUIElement,
                           value: (String, AXUIElement) throws -> CFTypeRef?) throws -> CGRect? {
        guard let position = try value(kAXPositionAttribute as String, element),
              let size = try value(kAXSizeAttribute as String, element),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              origin.x.isFinite, origin.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    private func discoverOuterPages(in root: AXUIElement,
                                    value: (String, AXUIElement) throws -> CFTypeRef?,
                                    check: () throws -> Void,
                                    readOuterMetadata: (AXUIElement) throws -> [Access.MetadataAttributeResult]? = { _ in nil },
                                    useBatchedMetadata: Bool = false) throws -> OuterPageInventory {
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        var visited: [AXUIElement] = [], pages: [AXUIElement] = [], sheetFrames: [CGRect] = []
        var complete = true
        var missingRequiredChildren = false
        var otherIncompleteReason = false
        while !pending.isEmpty, visited.count < nodeLimitPerPass {
            try check()
            let (node, depth) = pending.removeFirst()
            if visited.contains(where: { CFEqual($0, node) }) { continue }
            visited.append(node)
            guard depth <= 16 else { complete = false; otherIncompleteReason = true; continue }
            let role: String
            let subrole: String
            let hidden: Bool
            let protected: Bool
            if useBatchedMetadata {
                guard let values = try readOuterMetadata(node), values.count == 4,
                      case .value(let rawRole) = values[0], let decodedRole = rawRole as? String,
                      !decodedRole.isEmpty else {
                    complete = false
                    otherIncompleteReason = true
                    break
                }
                func optionalString(_ result: Access.MetadataAttributeResult) -> String? {
                    switch result {
                    case .value(let raw): return raw as? String
                    case .unavailable: return ""
                    case .error: return nil
                    }
                }
                func optionalBoolean(_ result: Access.MetadataAttributeResult) -> Bool? {
                    switch result {
                    case .value(let raw): return (raw as? NSNumber)?.boolValue
                    case .unavailable: return false
                    case .error: return nil
                    }
                }
                guard let decodedSubrole = optionalString(values[1]),
                      let decodedHidden = optionalBoolean(values[2]),
                      let decodedProtected = optionalBoolean(values[3]) else {
                    complete = false
                    otherIncompleteReason = true
                    break
                }
                role = decodedRole
                subrole = decodedSubrole
                hidden = decodedHidden
                protected = decodedProtected
            } else {
                role = try value(kAXRoleAttribute as String, node) as? String ?? ""
                subrole = try value(kAXSubroleAttribute as String, node) as? String ?? ""
                hidden = (try value("AXHidden", node) as? NSNumber)?.boolValue == true
                protected = (try value("AXProtectedContent", node) as? NSNumber)?.boolValue == true
            }
            if role == "AXSecureTextField" || subrole == (kAXSecureTextFieldSubrole as String) || hidden || protected {
                continue
            }
            if role == "AXSheet" {
                if let frame = try readFrame(node, value: value) { sheetFrames.append(frame) }
                continue
            }
            if role == "AXWebArea" { pages.append(node); continue }
            let rawChildren = try value(kAXChildrenAttribute as String, node)
            if let children = rawChildren as? [AXUIElement] {
                let room = max(0, nodeLimitPerPass - visited.count - pending.count)
                if children.count > room { complete = false; otherIncompleteReason = true }
                pending.append(contentsOf: children.prefix(room).map { ($0, depth + 1) })
            } else if ["AXWindow", "AXGroup", "AXSplitGroup", "AXUnknown", "AXScrollArea", "AXTabGroup", "AXToolbar"].contains(role) {
                // A container whose children could not be read can conceal a
                // second outer page. An explicitly empty children list is safe.
                complete = false
                if rawChildren == nil { missingRequiredChildren = true }
                else { otherIncompleteReason = true }
            }
        }
        if !pending.isEmpty { complete = false; otherIncompleteReason = true }
        return OuterPageInventory(pages: pages, sheetFrames: sheetFrames, complete: complete,
            recoverableMissingRequiredChildren: missingRequiredChildren && !otherIncompleteReason)
    }

    private func selectOuterPage(from inventory: OuterPageInventory, window: AXUIElement,
                                 value: (String, AXUIElement) throws -> CFTypeRef?,
                                 check: () throws -> Void) throws -> AXUIElement? {
        guard inventory.complete, !inventory.pages.isEmpty else { return nil }
        if inventory.pages.count == 1 { return inventory.pages[0] }
        guard let windowFrame = try readFrame(window, value: value),
              let firstFrame = try readFrame(inventory.pages[0], value: value),
              windowFrame.width > 0, windowFrame.height > 0 else { return nil }
        let tolerance: CGFloat = 2
        func coextensive(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
            abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance
                && abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
        }
        guard windowFrame.insetBy(dx: -tolerance, dy: -tolerance).contains(firstFrame) else { return nil }
        for page in inventory.pages.dropFirst() {
            guard let pageFrame = try readFrame(page, value: value), coextensive(firstFrame, pageFrame),
                  windowFrame.insetBy(dx: -tolerance, dy: -tolerance).contains(pageFrame) else { return nil }
        }

        let samples = [
            CGPoint(x: firstFrame.midX, y: firstFrame.midY),
            CGPoint(x: firstFrame.midX, y: firstFrame.minY + firstFrame.height * 0.33),
            CGPoint(x: firstFrame.midX, y: firstFrame.minY + firstFrame.height * 0.67),
            CGPoint(x: firstFrame.minX + firstFrame.width * 0.25, y: firstFrame.minY + firstFrame.height * 0.25),
            CGPoint(x: firstFrame.minX + firstFrame.width * 0.75, y: firstFrame.minY + firstFrame.height * 0.25),
            CGPoint(x: firstFrame.minX + firstFrame.width * 0.25, y: firstFrame.minY + firstFrame.height * 0.75),
            CGPoint(x: firstFrame.minX + firstFrame.width * 0.75, y: firstFrame.minY + firstFrame.height * 0.75),
            CGPoint(x: firstFrame.minX + firstFrame.width * 0.25, y: firstFrame.midY),
            CGPoint(x: firstFrame.minX + firstFrame.width * 0.75, y: firstFrame.midY)
        ].filter { point in
            point.x.isFinite && point.y.isFinite && firstFrame.contains(point)
                && !inventory.sheetFrames.contains(where: { $0.contains(point) })
        }
        guard samples.count >= 3 else { return nil }
        var selectedPage: AXUIElement?
        for point in samples.prefix(3) {
            try check()
            guard let hit = access.hitTestElementAtPoint(point) else { return nil }
            var current: AXUIElement? = hit
            var seen: [AXUIElement] = []
            var hitPage: AXUIElement?
            var reachedWindow = false
            for _ in 0..<16 {
                try check()
                guard let node = current, !seen.contains(where: { CFEqual($0, node) }) else { return nil }
                seen.append(node)
                let role = try value(kAXRoleAttribute as String, node) as? String ?? ""
                let subrole = try value(kAXSubroleAttribute as String, node) as? String ?? ""
                let hidden = (try value("AXHidden", node) as? NSNumber)?.boolValue == true
                let protected = (try value("AXProtectedContent", node) as? NSNumber)?.boolValue == true
                guard role.hasPrefix("AX"), role != "AXUnknown", role != "AXSecureTextField",
                      subrole != (kAXSecureTextFieldSubrole as String), !hidden, !protected,
                      role != "AXSheet" else { return nil }
                if role == "AXWebArea" {
                    guard hitPage == nil, inventory.pages.contains(where: { CFEqual($0, node) }) else { return nil }
                    hitPage = node
                }
                if role == "AXWindow" {
                    guard CFEqual(node, window), hitPage != nil else { return nil }
                    reachedWindow = true
                    break
                }
                guard let parent = try value(kAXParentAttribute as String, node),
                      CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
                current = unsafeBitCast(parent, to: AXUIElement.self)
            }
            guard reachedWindow, let hitPage else { return nil }
            if let selectedPage, !CFEqual(selectedPage, hitPage) { return nil }
            selectedPage = hitPage
        }
        return selectedPage
    }

    /// Reads only the HTTPS URL from the exact retained page while the user
    /// interface may be focused on a recognized native panel. This grants no
    /// authority to inspect controls or act on the page.
    func readRetainedPageURL(window expectedWindow: AXUIElement,
                             application expectedApplication: ComputerUseApplicationIdentity,
                             mayAct: () -> Bool,
                             diagnostic: ((String, Int) -> Void)? = nil) throws -> String? {
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .milliseconds(750))
        var expired = false
        func report(_ reason: String) {
            let components = (ContinuousClock.now - started).components
            let milliseconds = Int(max(0, min(2_000,
                components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)))
            diagnostic?(reason, milliseconds)
        }
        func failed(_ reason: String) -> String? {
            report(expired ? "deadline" : reason)
            return nil
        }
        func check() throws {
            try Task.checkCancellation()
            guard mayAct() else { throw ComputerUseHostTools.ToolError.paused }
            if ContinuousClock.now >= deadline { expired = true }
        }
        func value(_ name: String, _ element: AXUIElement) throws -> CFTypeRef? {
            try check()
            guard !expired else { return nil }
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let remainingSeconds = Float(Double(remaining.seconds)
                + Double(remaining.attoseconds) / 1_000_000_000_000_000_000)
            guard remainingSeconds > 0 else { expired = true; return nil }
            let timeout: Float = name == (kAXWindowsAttribute as String) ? 0.5 : 0.1
            access.timeout(element, min(timeout, remainingSeconds))
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
        func currentRoot() throws -> AXUIElement? {
            guard let (identity, root) = access.frontmost(), identity == expectedApplication else { return nil }
            return root
        }
        var windowInventoryRetryUsed = false
        var outerInventoryRecoveryUsed = false
        var expectedProofRoot: AXUIElement?
        func listedWindow(_ root: AXUIElement) throws -> Bool {
            func confirmsMembership(_ windows: [AXUIElement]) throws -> Bool {
                guard windows.filter({ CFEqual($0, expectedWindow) }).count == 1,
                      (try string(kAXRoleAttribute as String, expectedWindow)) == "AXWindow" else { return false }
                return true
            }
            guard let rawWindows = try value(kAXWindowsAttribute as String, root) else {
                guard !expired, !windowInventoryRetryUsed else { return false }
                windowInventoryRetryUsed = true
                try check()
                guard !expired,
                      let (identity, freshRoot) = access.frontmost(),
                      identity == expectedApplication, CFEqual(freshRoot, root) else { return false }
                try check()
                guard !expired,
                      let freshWindows = try value(kAXWindowsAttribute as String, freshRoot) as? [AXUIElement] else {
                    return false
                }
                return try confirmsMembership(freshWindows)
            }
            guard let windows = rawWindows as? [AXUIElement] else { return false }
            return try confirmsMembership(windows)
        }
        func uniqueOuterWebArea(in window: AXUIElement, phase: String) throws -> (AXUIElement?, String?) {
            var inventory = try discoverOuterPages(in: window, value: value, check: check)
            if !inventory.complete, inventory.recoverableMissingRequiredChildren,
               !outerInventoryRecoveryUsed {
                outerInventoryRecoveryUsed = true
                try check()
                guard let expectedProofRoot,
                      let retryRoot = try currentRoot(), CFEqual(retryRoot, expectedProofRoot),
                      try listedWindow(retryRoot) else {
                    return (nil, "\(phase)_outer_inventory_incomplete")
                }
                try check()
                inventory = try discoverOuterPages(in: window, value: value, check: check)
            }
            guard inventory.complete else { return (nil, "\(phase)_outer_inventory_incomplete") }
            guard !inventory.pages.isEmpty else { return (nil, "\(phase)_outer_inventory_empty") }
            guard let selected = try selectOuterPage(from: inventory, window: window, value: value, check: check) else {
                return (nil, "\(phase)_outer_selection_ambiguous")
            }
            return (selected, nil)
        }
        func httpsURL(from webArea: AXUIElement) throws -> String? {
            guard let rawURL = try string("AXURL", webArea) ?? string(kAXDocumentAttribute as String, webArea),
                  let components = URLComponents(string: rawURL), components.scheme?.lowercased() == "https",
                  let host = components.host, !host.isEmpty else { return nil }
            return rawURL
        }

        try check()
        guard let root = try currentRoot() else { return failed("initial_app_unavailable") }
        expectedProofRoot = root
        guard try listedWindow(root) else { return failed("initial_window_unavailable") }
        let (webArea, initialPageFailure) = try uniqueOuterWebArea(in: expectedWindow, phase: "initial")
        guard let webArea else { return failed(initialPageFailure ?? "initial_outer_selection_ambiguous") }
        guard let url = try httpsURL(from: webArea) else { return failed("initial_url_unavailable") }
        try check()
        guard let afterRoot = try currentRoot() else { return failed("fresh_app_unavailable") }
        guard CFEqual(afterRoot, root) else { return failed("fresh_app_changed") }
        guard try listedWindow(afterRoot) else { return failed("fresh_window_unavailable") }
        let (afterWebArea, freshPageFailure) = try uniqueOuterWebArea(in: expectedWindow, phase: "fresh")
        guard let afterWebArea else { return failed(freshPageFailure ?? "fresh_outer_selection_ambiguous") }
        guard CFEqual(afterWebArea, webArea) else { return failed("fresh_outer_selection_changed") }
        guard let freshURL = try httpsURL(from: afterWebArea) else { return failed("fresh_url_unavailable") }
        guard freshURL == url else { return failed("fresh_url_changed") }
        guard !expired else { return failed("deadline") }
        report("complete")
        return url
    }

    func read(window expectedWindow: AXUIElement,
              application expectedApplication: ComputerUseApplicationIdentity,
              mayAct: () -> Bool,
              diagnostic: ((String, [String]) -> Void)? = nil) throws -> Observation? {
        var focusedAncestorRoles: [String] = []
        let safeRoles: Set<String> = ["AXWindow", "AXWebArea", "AXGroup", "AXTextArea", "AXTextField",
            "AXSecureTextField", "AXButton", "AXComboBox", "AXStaticText", "AXLink", "AXMenuItem", "AXOther"]
        func recordRole(_ role: String) {
            let safe = safeRoles.contains(role) ? role : "AXOther"
            if focusedAncestorRoles.count < 16 { focusedAncestorRoles.append(safe) }
        }
        func fail(_ reason: String) -> Observation? {
            diagnostic?(reason, focusedAncestorRoles)
            return nil
        }
        let pageReadBudget: Duration = .milliseconds(750)
        let deadline = ContinuousClock.now.advanced(by: pageReadBudget)
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
        func readOuterMetadataForDiscovery(_ element: AXUIElement) throws -> [Access.MetadataAttributeResult]? {
            try check()
            guard !expired, let readOuterMetadata = access.readOuterMetadata else { return nil }
            access.timeout(element, 0.1)
            let result = readOuterMetadata(element)
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
        func markIncomplete(_ reason: String) {
            truncated = true
        }
        func isPruned(_ node: AXUIElement) throws -> Bool {
            let role = try string(kAXRoleAttribute as String, node) ?? ""
            let subrole = try string(kAXSubroleAttribute as String, node) ?? ""
            let protected = (try value("AXProtectedContent", node) as? NSNumber)?.boolValue == true
            let hidden = (try value("AXHidden", node) as? NSNumber)?.boolValue == true
            return role == "AXSecureTextField" || subrole == (kAXSecureTextFieldSubrole as String) || protected || hidden
        }
        var selectedInventory: OuterPageInventory?
        func discoverOuterWebArea() throws -> AXUIElement? {
            let inventory = try discoverOuterPages(in: focused, value: value, check: check,
                readOuterMetadata: readOuterMetadataForDiscovery)
            guard inventory.complete else { markIncomplete("outer_page_incomplete"); return nil }
            selectedInventory = inventory
            return try selectOuterPage(from: inventory, window: focused, value: value, check: check)
        }
        // Stop at each AXWebArea so nested iframe documents stay outside the
        // candidate set. Multiple outer areas require fresh hit-test proof.
        guard let webArea = try discoverOuterWebArea(), let initialInventory = selectedInventory else {
            return fail(expired ? "outer_page_discovery_deadline" : "outer_page_discovery_incomplete_or_ambiguous")
        }
        let controlRoles: Set<String> = ["AXButton", "AXMenuItem", "AXLink", "AXTextField", "AXTextArea", "AXComboBox",
            "AXPopUpButton", "AXCheckBox", "AXRadioButton"]
        var focusedControlIsInPage: Bool?
        var focusedNodeIsInPage = false
        var focusedPagePath: [AXUIElement] = []
        var focusedPathControls: [AXUIElement] = []
        if let focusedUIElement {
            let focusedRole = try string(kAXRoleAttribute as String, focusedUIElement) ?? ""
            let staleOuterPageFocus = focusedRole == "AXWebArea"
                && !CFEqual(focusedUIElement, webArea)
                && initialInventory.pages.contains(where: { CFEqual($0, focusedUIElement) })
                && initialInventory.pages.count > 1
            if staleOuterPageFocus {
                // A focused AXWebArea can remain attached to an inactive sibling
                // document after Safari switches the visible tab content. It is
                // outside this page; interactive focus never gets this exception.
                focusedControlIsInPage = false
            } else {
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
            }
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
        let controlLimit = 32
        var focusedEmptyExpandedMenu: AXUIElement?
        var contextBytes = 0
        // Start at the exact outer page, preserving the normal pruning and
        // inherited-disabled checks while visiting the verified focus branch first.
        var contentQueue: [(AXUIElement, Bool)] = [(webArea, false)]
        var contentVisited: [AXUIElement] = []
        var finalValidationSucceeded = false
        func bounded(_ chunk: String, to bytes: Int) -> String {
            var result = "", used = 0
            for scalar in chunk.unicodeScalars {
                let value = String(scalar), count = value.utf8.count
                guard used + count <= bytes else { markIncomplete("rendered_text_bytes"); break }
                result += value; used += count
            }
            return result
        }
        func appendText(_ chunk: String) {
            guard !chunk.isEmpty else { return }
            let separator = text.isEmpty ? "" : "\n"
            let available = contextByteLimit - contextBytes - separator.utf8.count
            guard available > 0 else { markIncomplete("context_bytes"); return }
            let prefix = bounded(chunk, to: available)
            if !prefix.isEmpty { text += separator + prefix; contextBytes += separator.utf8.count + prefix.utf8.count }
        }
        func appendExactText(_ value: String) {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard exactTextValues.count < exactTextValueLimit else {
                markIncomplete("exact_text_count")
                return
            }
            var byteCount = 0
            for _ in value.utf8 {
                byteCount += 1
                guard exactTextBytes + byteCount <= exactTextByteLimit else {
                    markIncomplete("exact_text_bytes")
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
            } else if role == "AXCell" {
                let labels = [try string(kAXValueAttribute as String, node),
                    try string(kAXTitleAttribute as String, node),
                    try string(kAXDescriptionAttribute as String, node)].compactMap { $0 }
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
                if formFieldValues.count >= formFieldValueLimit {
                    markIncomplete("form_field_count")
                } else if formFieldBytes + cost > formFieldByteLimit {
                    markIncomplete("form_field_bytes")
                } else {
                    formFieldValues.append(.init(label: fieldLabel, role: role, value: fieldValue, help: help))
                    formFieldBytes += cost
                }
            }
            if controlRoles.contains(role), controls.count < controlLimit {
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
                if controls.count >= controlLimit {
                    markIncomplete("control_count")
                } else if contextBytes + cost > contextByteLimit {
                    markIncomplete("context_bytes")
                } else {
                    controls.append(Control(id: id, role: safeRole, label: safeLabel,
                                            frame: try frame(node), enabled: effectiveEnabled, expanded: expanded))
                    contextBytes += cost
                    controlRefs[id] = node
                    if hasKnownEmptyMenuChildren { focusedEmptyExpandedMenu = node }
                }
            } else if controlRoles.contains(role) {
                // A recognized control omitted at the item cap makes this page partial.
                markIncomplete("control_count")
            }
            if let children = try value(kAXChildrenAttribute as String, node) as? [AXUIElement] {
                let traversalChildren = children
                let pathIndex = focusedPagePath.firstIndex(where: { CFEqual($0, node) })
                let nextFocusedNode = pathIndex.flatMap { index in
                    index + 1 < focusedPagePath.count ? focusedPagePath[index + 1] : nil
                }
                let priorityNode = nextFocusedNode.flatMap { expected in
                    traversalChildren.first(where: { CFEqual($0, expected) })
                }
                let desiredCount = min(traversalChildren.count, pathIndex == nil ? nodeLimitPerPass : 32)
                var selectedChildren = Array(traversalChildren.prefix(desiredCount))
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
                        markIncomplete("queue_eviction")
                    }
                }
                let room = max(0, nodeLimitPerPass - contentVisited.count - contentQueue.count)
                if focusedPagePath.isEmpty {
                    // Preserve the existing breadth-first ordering and admission
                    // exactly when no verified in-page focus path is available.
                    if traversalChildren.count > room { markIncomplete("queue_capacity") }
                    contentQueue.append(contentsOf: traversalChildren.prefix(room).map { ($0, inheritedDisabled || (effectiveEnabled == false)) })
                } else {
                    if traversalChildren.count > desiredCount || selectedChildren.count > room { markIncomplete("queue_capacity") }
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
        if expired { markIncomplete("deadline") }
        if !contentQueue.isEmpty || contentVisited.count >= nodeLimitPerPass { markIncomplete("node_limit") }
        try check()
        guard !expired else { return fail("deadline_during_final_validation") }
        guard let (afterRoot, afterWindow) = try currentScope() else {
            return fail(expired ? "deadline_during_final_validation" : "page_scope_or_outer_area_changed")
        }
        guard !expired else { return fail("deadline_during_final_validation") }
        guard CFEqual(afterRoot, root), CFEqual(afterWindow, expectedWindow) else {
            return fail("page_scope_or_outer_area_changed")
        }
        guard let finalArea = try discoverOuterWebArea() else {
            return fail(expired ? "deadline_during_final_validation" : "page_scope_or_outer_area_changed")
        }
        guard !expired else { return fail("deadline_during_final_validation") }
        guard CFEqual(finalArea, webArea) else { return fail("page_scope_or_outer_area_changed") }
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
        finalValidationSucceeded = true
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

        guard let fresh = try read(window: window, application: original.application,
                                   mayAct: mayAct) else { return nil }
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
                                window: AXUIElement, mayAct: () -> Bool,
                                rejectInteractiveDescendants: Bool = false) throws -> Bool {
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
            if rejectInteractiveDescendants, !CFEqual(element, control) {
                guard try check() else { return false }
                access.timeout(element, 0.1)
                let roleRaw = access.read(kAXRoleAttribute as String, element) as? String
                guard try check() else { return false }
                if ["AXButton", "AXLink", "AXMenuItem", "AXCheckBox", "AXRadioButton",
                    "AXTextField", "AXTextArea", "AXComboBox"].contains(roleRaw ?? "") { return false }
            }
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

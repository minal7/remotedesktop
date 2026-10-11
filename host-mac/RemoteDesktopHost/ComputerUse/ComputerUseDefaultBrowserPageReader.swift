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
        let webUploadListingRows: [ComputerUseWebUploadJob.ListingRow]
        /// True only when the bounded W2 control-focused pass finished its
        /// non-listing traversal. `truncated` remains true when row trees were
        /// intentionally pruned, so this never claims the listing is complete.
        let webUploadControlsComplete: Bool
        let controls: [Control]
        /// Safari/Chromium AX trees may omit or flatten iframe contents.
        /// This reader does not claim those contents are complete.
        let iframeContentMayBeOmitted: Bool
        let truncated: Bool
        let focusedExpandedMenuHasNoActionableChildren: Bool

        init(id: String, application: ComputerUseApplicationIdentity, url: String, renderedAXText: String,
             controls: [Control], iframeContentMayBeOmitted: Bool, truncated: Bool,
             focusedExpandedMenuHasNoActionableChildren: Bool = false, exactTextValues: [String] = [],
             formFieldValues: [FormFieldValue] = [],
             webUploadListingRows: [ComputerUseWebUploadJob.ListingRow] = [],
             webUploadControlsComplete: Bool = false) {
            self.id = id
            self.application = application
            self.url = url
            self.renderedAXText = renderedAXText
            self.exactTextValues = exactTextValues
            self.formFieldValues = formFieldValues
            self.webUploadListingRows = webUploadListingRows
            self.webUploadControlsComplete = webUploadControlsComplete
            self.controls = controls
            self.iframeContentMayBeOmitted = iframeContentMayBeOmitted
            self.truncated = truncated
            self.focusedExpandedMenuHasNoActionableChildren = focusedExpandedMenuHasNoActionableChildren
        }
    }

    /// A bounded read of the selected Google Drive file's Details pane. The
    /// returned route is origin-and-path only; embedded document query data is
    /// never surfaced to callers.
    struct DriveDetailsObservation: Equatable, Sendable {
        let documentRoute: String
        let exactTextValues: [String]
        let complete: Bool
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
        let mode: ReadMode
        let controls: [String: AXUIElement]
        let controlMetadata: [String: Control]
        let listingRows: [String: AXUIElement]
    }

    private struct OuterPageInventory {
        let pages: [AXUIElement]
        let sheetFrames: [CGRect]
        let complete: Bool
    }

    private let access: Access
    private var retained: [String: Retained] = [:]
    private(set) var lastWebUploadControlsDiagnosticForDiagnostics: [String: String] = [:]
    private let contextByteLimit = 8_192
    /// Each bounded pass visits at most this many nodes; all passes share a
    /// 750ms deadline and each AX IPC is configured for at most 0.1s.
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
                                    check: () throws -> Void) throws -> OuterPageInventory {
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        var visited: [AXUIElement] = [], pages: [AXUIElement] = [], sheetFrames: [CGRect] = []
        var complete = true
        while !pending.isEmpty, visited.count < nodeLimitPerPass {
            try check()
            let (node, depth) = pending.removeFirst()
            if visited.contains(where: { CFEqual($0, node) }) { continue }
            visited.append(node)
            guard depth <= 16 else { complete = false; continue }
            let role = try value(kAXRoleAttribute as String, node) as? String ?? ""
            let subrole = try value(kAXSubroleAttribute as String, node) as? String ?? ""
            let hidden = (try value("AXHidden", node) as? NSNumber)?.boolValue == true
            let protected = (try value("AXProtectedContent", node) as? NSNumber)?.boolValue == true
            if role == "AXSecureTextField" || subrole == (kAXSecureTextFieldSubrole as String) || hidden || protected {
                continue
            }
            if role == "AXSheet" {
                if let frame = try readFrame(node, value: value) { sheetFrames.append(frame) }
                continue
            }
            if role == "AXWebArea" { pages.append(node); continue }
            if let children = try value(kAXChildrenAttribute as String, node) as? [AXUIElement] {
                let room = max(0, nodeLimitPerPass - visited.count - pending.count)
                if children.count > room { complete = false }
                pending.append(contentsOf: children.prefix(room).map { ($0, depth + 1) })
            } else if ["AXWindow", "AXGroup", "AXSplitGroup", "AXUnknown", "AXScrollArea", "AXTabGroup", "AXToolbar"].contains(role) {
                // A container whose children could not be read can conceal a
                // second outer page. An explicitly empty children list is safe.
                complete = false
            }
        }
        if !pending.isEmpty { complete = false }
        return OuterPageInventory(pages: pages, sheetFrames: sheetFrames, complete: complete)
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
            let inventory = try discoverOuterPages(in: window, value: value, check: check)
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

    enum ReadMode: Equatable { case standard, webUploadControls, webUploadListing }

    /// Reads the Details iframe only when it is uniquely attached to the
    /// retained Drive search page and its exact selected root-row filename.
    /// General page reads continue to omit nested web areas.
    func readDriveDetails(window: AXUIElement,
                          application: ComputerUseApplicationIdentity,
                          expectedFileName: String,
                          mayAct: () -> Bool) throws -> DriveDetailsObservation? {
        guard !expectedFileName.isEmpty,
              let expectedSearch = ComputerUseWebUploadJob.driveTitleSearchURL(filename: expectedFileName)?.absoluteString else {
            return nil
        }
        let expectedRowLabels = Set([expectedFileName, ComputerUseWebUploadJob.driveRootLocationLabel])
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .seconds(2))
        var expired = false
        func check() throws {
            try Task.checkCancellation()
            guard mayAct() else { throw ComputerUseHostTools.ToolError.paused }
            if ContinuousClock.now >= deadline { expired = true }
        }
        func value(_ name: String, _ node: AXUIElement) throws -> CFTypeRef? {
            try check()
            guard !expired else { return nil }
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let remainingSeconds = Float(Double(remaining.seconds)
                + Double(remaining.attoseconds) / 1_000_000_000_000_000_000)
            guard remainingSeconds > 0 else { expired = true; return nil }
            let timeout: Float = name == (kAXWindowsAttribute as String) ? 0.5 : 0.08
            access.timeout(node, min(timeout, remainingSeconds))
            let result = access.read(name, node)
            try check()
            return expired ? nil : result
        }
        func selectedRootRow(_ listing: Observation) throws -> AXUIElement? {
            guard listing.application == application, listing.url == expectedSearch, !listing.truncated else { return nil }
            let matches = listing.webUploadListingRows.filter { $0.cellLabels.contains(expectedFileName) }
            guard matches.count == 1, expectedRowLabels.isSubset(of: Set(matches[0].cellLabels)),
                  let rowElement = retained[listing.id]?.listingRows[matches[0].rowID],
                  let selected = try value("AXSelected", rowElement) as? NSNumber,
                  selected.boolValue else { return nil }
            return rowElement
        }
        func string(_ name: String, _ node: AXUIElement) throws -> String? {
            guard let raw = try value(name, node) else { return nil }
            if let text = raw as? String { return text }
            if let url = raw as? URL { return url.absoluteString }
            return nil
        }
        func children(_ node: AXUIElement) throws -> [AXUIElement]? {
            guard let raw = try value(kAXChildrenAttribute as String, node),
                  let result = raw as? [AXUIElement] else { return nil }
            return result
        }
        func hiddenOrProtected(_ node: AXUIElement) throws -> Bool {
            let role = try string(kAXRoleAttribute as String, node) ?? ""
            let subrole = try string(kAXSubroleAttribute as String, node) ?? ""
            return try role == "AXSecureTextField" || subrole == (kAXSecureTextFieldSubrole as String)
                || (try value("AXProtectedContent", node) as? NSNumber)?.boolValue == true
                || (try value("AXHidden", node) as? NSNumber)?.boolValue == true
        }
        func requiredChildrenRole(_ role: String) -> Bool {
            ["AXWindow", "AXGroup", "AXSplitGroup", "AXUnknown", "AXScrollArea", "AXTabGroup",
             "AXToolbar", "AXList", "AXWebArea", "AXLink"].contains(role)
        }
        func currentOuter() throws -> (AXUIElement, AXUIElement, String)? {
            try check()
            guard let (currentApplication, root) = access.frontmost(), currentApplication == application,
                  let focusedRaw = try value(kAXFocusedWindowAttribute as String, root),
                  CFGetTypeID(focusedRaw) == AXUIElementGetTypeID() else { return nil }
            let focused = unsafeBitCast(focusedRaw, to: AXUIElement.self)
            guard CFEqual(focused, window),
                  let windowsRaw = try value(kAXWindowsAttribute as String, root),
                  let windows = windowsRaw as? [AXUIElement],
                  windows.filter({ CFEqual($0, window) }).count == 1 else { return nil }
            let inventory = try discoverOuterPages(in: window, value: value, check: check)
            guard inventory.complete, inventory.sheetFrames.isEmpty,
                  let outer = try selectOuterPage(from: inventory, window: window, value: value, check: check),
                  let rawURL = try string("AXURL", outer) ?? string(kAXDocumentAttribute as String, outer),
                  rawURL == expectedSearch else { return nil }
            return (root, outer, rawURL)
        }
        guard let beforeListing = try read(window: window, application: application, mayAct: mayAct,
                                            mode: .webUploadListing),
              let beforeRow = try selectedRootRow(beforeListing) else { return nil }
        guard let initial = try currentOuter() else { return nil }

        // Locate one pane beneath the verified outer search page. Listing
        // branches are irrelevant here and are pruned before their children.
        var pageQueue: [(AXUIElement, Int)] = [(initial.1, 0)]
        var pageVisited: [AXUIElement] = []
        var detailPanes: [AXUIElement] = []
        var nestedPaneCount = 0
        var pageComplete = true
        while !pageQueue.isEmpty, pageVisited.count < 256, !expired {
            try check()
            let (node, depth) = pageQueue.removeFirst()
            guard depth <= 16, !pageVisited.contains(where: { CFEqual($0, node) }) else {
                pageComplete = false
                continue
            }
            pageVisited.append(node)
            let role = try string(kAXRoleAttribute as String, node) ?? ""
            guard !role.isEmpty else { pageComplete = false; continue }
            if try hiddenOrProtected(node) || role == "AXSheet" { continue }
            if !CFEqual(node, initial.1), role == "AXWebArea" { continue }
            if role == "AXGroup",
               (try string(kAXTitleAttribute as String, node) == "Details Pane"
                    || string(kAXDescriptionAttribute as String, node) == "Details Pane") {
                detailPanes.append(node)
                continue
            }
            if ["AXTable", "AXOutline", "AXRow"].contains(role) { continue }
            guard let nested = try children(node) else {
                if requiredChildrenRole(role) { pageComplete = false }
                continue
            }
            let room = max(0, 256 - pageVisited.count - pageQueue.count)
            if nested.count > room { pageComplete = false }
            pageQueue.append(contentsOf: nested.prefix(room).map { ($0, depth + 1) })
        }
        if !pageQueue.isEmpty || expired || !pageComplete || detailPanes.count != 1 || nestedPaneCount != 0 { return nil }
        let pane = detailPanes[0]

        var paneQueue: [(AXUIElement, Int)] = [(pane, 0)]
        var paneVisited: [AXUIElement] = []
        var embeddedPages: [AXUIElement] = []
        var headingCount = 0
        var paneHideCount = 0
        var paneComplete = true
        while !paneQueue.isEmpty, paneVisited.count < 128, !expired {
            try check()
            let (node, depth) = paneQueue.removeFirst()
            guard depth <= 12, !paneVisited.contains(where: { CFEqual($0, node) }) else {
                paneComplete = false
                continue
            }
            paneVisited.append(node)
            let role = try string(kAXRoleAttribute as String, node) ?? ""
            guard !role.isEmpty else { paneComplete = false; continue }
            if try hiddenOrProtected(node) || role == "AXSheet" { continue }
            if !CFEqual(node, pane), role == "AXGroup",
               (try string(kAXTitleAttribute as String, node) == "Details Pane"
                    || string(kAXDescriptionAttribute as String, node) == "Details Pane") {
                nestedPaneCount += 1
            }
            if role == "AXHeading",
               try string(kAXTitleAttribute as String, node)?.hasSuffix(" \(expectedFileName)") == true,
               (try value(kAXValueAttribute as String, node) as? NSNumber)?.intValue == 2 {
                headingCount += 1
            }
            if role == "AXButton", try string(kAXTitleAttribute as String, node) == "Hide Details" {
                paneHideCount += 1
            }
            if role == "AXWebArea", !CFEqual(node, initial.1) {
                embeddedPages.append(node)
                continue
            }
            guard let nested = try children(node) else {
                if requiredChildrenRole(role) { paneComplete = false }
                continue
            }
            let room = max(0, 128 - paneVisited.count - paneQueue.count)
            if nested.count > room { paneComplete = false }
            paneQueue.append(contentsOf: nested.prefix(room).map { ($0, depth + 1) })
        }
        guard paneQueue.isEmpty, !expired, paneComplete, nestedPaneCount == 0,
              headingCount == 1, paneHideCount == 1,
              embeddedPages.count == 1, let embedded = embeddedPages.first else { return nil }

        guard let rawDetailsURL = try string("AXURL", embedded) ?? string(kAXDocumentAttribute as String, embedded),
              let detailsComponents = URLComponents(string: rawDetailsURL),
              detailsComponents.scheme?.lowercased() == "https",
              detailsComponents.host?.lowercased() == "drive.google.com",
              detailsComponents.port == nil, detailsComponents.user == nil, detailsComponents.password == nil,
              detailsComponents.path == "/odp/embed" else { return nil }

        var contentQueue: [(AXUIElement, Int, Bool, Bool)] = [(embedded, 0, false, false)]
        var contentVisited: [AXUIElement] = []
        var fileDetailsGroups: [AXUIElement] = []
        var fileDetailsLists: [AXUIElement] = []
        var exactImages = 0
        var exactOpenLinks = 0
        var contentComplete = true
        while !contentQueue.isEmpty, contentVisited.count < 128, !expired {
            try check()
            let (node, depth, insideDetailsSection, insideFileDetails) = contentQueue.removeFirst()
            guard depth <= 12, !contentVisited.contains(where: { CFEqual($0, node) }) else {
                contentComplete = false
                continue
            }
            contentVisited.append(node)
            let role = try string(kAXRoleAttribute as String, node) ?? ""
            guard !role.isEmpty else { contentComplete = false; continue }
            if try hiddenOrProtected(node) || role == "AXSheet" { continue }
            if !CFEqual(node, embedded) && role == "AXWebArea" { contentComplete = false; continue }
            let detailsSectionNode = try role == "AXGroup"
                && (try string(kAXTitleAttribute as String, node) == "Details")
            let fileDetailsNode = try insideDetailsSection && role == "AXGroup"
                && (try string(kAXTitleAttribute as String, node) == "File details")
            if fileDetailsNode {
                fileDetailsGroups.append(node)
            }
            if insideFileDetails, role == "AXList", try string(kAXTitleAttribute as String, node) == "File details" {
                fileDetailsLists.append(node)
            }
            if insideDetailsSection, role == "AXImage",
               (try string(kAXDescriptionAttribute as String, node) == expectedFileName
                    || string(kAXTitleAttribute as String, node) == expectedFileName) {
                exactImages += 1
            }
            if insideDetailsSection, role == "AXLink",
               try string(kAXTitleAttribute as String, node) == "Open \(expectedFileName)" {
                exactOpenLinks += 1
            }
            guard let nested = try children(node) else {
                if requiredChildrenRole(role) { contentComplete = false }
                continue
            }
            let room = max(0, 128 - contentVisited.count - contentQueue.count)
            if nested.count > room { contentComplete = false }
            contentQueue.append(contentsOf: nested.prefix(room).map {
                ($0, depth + 1, insideDetailsSection || detailsSectionNode, insideFileDetails || fileDetailsNode)
            })
        }
        guard contentQueue.isEmpty, !expired, contentComplete,
              fileDetailsGroups.count == 1, fileDetailsLists.count == 1,
              exactImages == 1, exactOpenLinks == 1 else { return nil }

        var detailsQueue: [(AXUIElement, Int)] = [(fileDetailsLists[0], 0)]
        var detailsVisited: [AXUIElement] = []
        var sizeValues: [String] = []
        var locationValues: [String] = []
        var detailsComplete = true
        while !detailsQueue.isEmpty, detailsVisited.count < 64, !expired {
            try check()
            let (node, depth) = detailsQueue.removeFirst()
            guard depth <= 8, !detailsVisited.contains(where: { CFEqual($0, node) }) else {
                detailsComplete = false
                continue
            }
            detailsVisited.append(node)
            let role = try string(kAXRoleAttribute as String, node) ?? ""
            guard !role.isEmpty else { detailsComplete = false; continue }
            if try hiddenOrProtected(node) || role == "AXSheet" { continue }
            if role == "AXStaticText",
               let text = try string(kAXValueAttribute as String, node)
                    ?? string(kAXTitleAttribute as String, node)
                    ?? string(kAXDescriptionAttribute as String, node) {
                if text.replacingOccurrences(of: "\u{00A0}", with: " ").hasPrefix("Size ") {
                    sizeValues.append(text)
                } else if text == "My Drive, show location in the list of files." {
                    locationValues.append(text)
                }
            }
            guard let nested = try children(node) else {
                if requiredChildrenRole(role) { detailsComplete = false }
                continue
            }
            let room = max(0, 64 - detailsVisited.count - detailsQueue.count)
            if nested.count > room { detailsComplete = false }
            detailsQueue.append(contentsOf: nested.prefix(room).map { ($0, depth + 1) })
        }
        guard detailsQueue.isEmpty, !expired, detailsComplete,
              sizeValues.count == 1, locationValues.count == 1 else { return nil }

        // Re-read the outer listing and authority after the nested document
        // scan; neither the selected row nor the active page may have changed.
        guard let afterListing = try read(window: window, application: application, mayAct: mayAct,
                                           mode: .webUploadListing),
              let afterRow = try selectedRootRow(afterListing), CFEqual(afterRow, beforeRow),
              let final = try currentOuter(), CFEqual(final.0, initial.0), CFEqual(final.1, initial.1),
              final.2 == expectedSearch, !expired else { return nil }

        let safeRoute = "\(detailsComponents.scheme!.lowercased())://\(detailsComponents.host!.lowercased())\(detailsComponents.path)"
        return .init(documentRoute: safeRoute,
            exactTextValues: [expectedFileName] + sizeValues + locationValues, complete: true)
    }

    func read(window expectedWindow: AXUIElement,
              application expectedApplication: ComputerUseApplicationIdentity,
              mayAct: () -> Bool, mode: ReadMode = .standard,
              diagnostic: ((String, [String]) -> Void)? = nil) throws -> Observation? {
        if mode == .webUploadControls { lastWebUploadControlsDiagnosticForDiagnostics = [:] }
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
        var controlPassIncomplete = false
        var webUploadIncompleteReasons = Set<String>()
        var prunedListingNodeCount = 0
        func markIncomplete(_ reason: String) {
            truncated = true
            if mode == .webUploadControls {
                controlPassIncomplete = true
                webUploadIncompleteReasons.insert(reason)
            }
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
            let inventory = try discoverOuterPages(in: focused, value: value, check: check)
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
        var webUploadListingRows: [ComputerUseWebUploadJob.ListingRow] = []
        var listingRowLabels: [[String]] = []
        var listingRowRefs: [String: AXUIElement] = [:]
        var formFieldBytes = 0
        var exactTextBytes = 0
        let isWebUploadRead = mode == .webUploadControls || mode == .webUploadListing
        let exactTextValueLimit = isWebUploadRead ? 128 : 32
        let exactTextByteLimit = 4_096
        let formFieldValueLimit = 32
        let formFieldByteLimit = 4_096
        let controlLimit = isWebUploadRead ? 128 : 32
        var focusedEmptyExpandedMenu: AXUIElement?
        var contextBytes = 0
        // Start at the exact outer page, preserving the normal pruning and
        // inherited-disabled checks while visiting the verified focus branch first.
        var contentQueue: [(AXUIElement, Bool, Int?)] = [(webArea, false, nil)]
        var contentVisited: [AXUIElement] = []
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
            let (node, inheritedDisabled, inheritedRowIndex) = focusedPagePath.isEmpty
                ? contentQueue.removeFirst() : contentQueue.removeLast()
            if contentVisited.contains(where: { CFEqual($0, node) }) { continue }
            contentVisited.append(node)
            if try isPruned(node) { continue }
            let role = try string(kAXRoleAttribute as String, node) ?? ""
            if mode == .webUploadControls, ["AXTable", "AXOutline", "AXRow"].contains(role) {
                // Drive can expose a virtualized table with dozens of rows
                // before its global account/search controls. This pass is for
                // those controls only; the ordinary pass still reports full
                // listing completeness independently.
                truncated = true
                prunedListingNodeCount += 1
                continue
            }
            var rowIndex = inheritedRowIndex
            if role == "AXRow" {
                if webUploadListingRows.count < 128 {
                    rowIndex = webUploadListingRows.count
                    let rowID = UUID().uuidString
                    webUploadListingRows.append(.init(rowID: rowID, cellLabels: [],
                        frame: mode == .webUploadListing ? try frame(node) : nil))
                    listingRowRefs[rowID] = node
                    listingRowLabels.append([])
                } else { markIncomplete("listing_row_count") }
            }
            let nodeEnabled = (try value(kAXEnabledAttribute as String, node) as? NSNumber)?.boolValue
            let effectiveEnabled = inheritedDisabled ? false : nodeEnabled
            // Nested AXWebAreas are iframe/document boundaries: deliberately omit their subtree.
            if !CFEqual(node, webArea), role == "AXWebArea" { continue }
            if role == "AXStaticText", let label = try string(kAXValueAttribute as String, node) ?? string(kAXTitleAttribute as String, node) {
                appendText(label)
                appendExactText(label)
                if let rowIndex, listingRowLabels.indices.contains(rowIndex) { listingRowLabels[rowIndex].append(label) }
            } else if role == "AXCell" {
                let labels = [try string(kAXValueAttribute as String, node),
                    try string(kAXTitleAttribute as String, node),
                    try string(kAXDescriptionAttribute as String, node)].compactMap { $0 }
                if let rowIndex, listingRowLabels.indices.contains(rowIndex) { listingRowLabels[rowIndex].append(contentsOf: labels) }
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
                var traversalChildren = children
                if mode == .webUploadControls {
                    traversalChildren = []
                    for child in children {
                        guard let childRole = try string(kAXRoleAttribute as String, child) else {
                            // An unclassified child cannot safely be pruned as listing content.
                            markIncomplete("child_role_unavailable")
                            traversalChildren.append(child)
                            continue
                        }
                        if ["AXTable", "AXOutline", "AXRow"].contains(childRole) {
                            truncated = true
                            prunedListingNodeCount += 1
                        } else {
                            traversalChildren.append(child)
                        }
                    }
                }
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
                    contentQueue.append(contentsOf: traversalChildren.prefix(room).map { ($0, inheritedDisabled || (effectiveEnabled == false), rowIndex) })
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
                    contentQueue.append(contentsOf: selectedChildren.map { ($0, inheritedDisabled || (effectiveEnabled == false), rowIndex) })
                }
            }
        }
        if expired { markIncomplete("deadline") }
        if !contentQueue.isEmpty || contentVisited.count >= nodeLimitPerPass { markIncomplete("node_limit") }
        for index in webUploadListingRows.indices {
            webUploadListingRows[index] = .init(rowID: webUploadListingRows[index].rowID,
                cellLabels: listingRowLabels[index], frame: webUploadListingRows[index].frame)
        }
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
        let controlsComplete = mode == .webUploadControls && !expired && contentQueue.isEmpty
            && contentVisited.count < nodeLimitPerPass && !controlPassIncomplete
        if mode == .webUploadControls {
            lastWebUploadControlsDiagnosticForDiagnostics = [
                "complete": String(controlsComplete),
                "truncated": String(truncated),
                "reasons": webUploadIncompleteReasons.sorted().joined(separator: ","),
                "visited": String(contentVisited.count),
                "pending": String(contentQueue.count),
                "controls": String(controls.count),
                "exact_text": String(exactTextValues.count),
                "form_fields": String(formFieldValues.count),
                "context_bytes": String(contextBytes),
                "pruned_listing_nodes": String(prunedListingNodeCount),
            ]
        }
        let observationID = UUID().uuidString
        let observation = Observation(id: observationID, application: expectedApplication, url: url,
            renderedAXText: text, controls: controls, iframeContentMayBeOmitted: true, truncated: truncated,
            focusedExpandedMenuHasNoActionableChildren: focusedExpandedMenuHasNoActionableChildren,
            exactTextValues: exactTextValues, formFieldValues: formFieldValues,
            webUploadListingRows: webUploadListingRows,
            webUploadControlsComplete: controlsComplete)
        retained[observationID] = Retained(application: expectedApplication, window: expectedWindow,
            webArea: webArea, url: url, mode: mode, controls: controlRefs,
            controlMetadata: Dictionary(uniqueKeysWithValues: controls.map { ($0.id, $0) }),
            listingRows: listingRowRefs)
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

        guard let fresh = try read(window: window, application: original.application,
                                   mayAct: mayAct, mode: original.mode) else { return nil }
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

    /// A bounded selection click for a uniquely observed result row. It may
    /// select that row for read-only Details inspection; it cannot target an
    /// interactive descendant such as a checkbox, link, or button.
    func validatedListingRowCenter(observation: Observation, rowID: String,
                                   requiredLabels: Set<String>, window: AXUIElement,
                                   windowBounds: CGRect, mayAct: () -> Bool) throws -> CGPoint? {
        try Task.checkCancellation()
        guard mayAct(), !requiredLabels.isEmpty,
              let original = retained[observation.id], original.application == observation.application,
              CFEqual(original.window, window), original.url == observation.url,
              let originalElement = original.listingRows[rowID],
              let originalRow = observation.webUploadListingRows.first(where: { $0.rowID == rowID }),
              requiredLabels.isSubset(of: Set(originalRow.cellLabels)) else { return nil }
        guard let fresh = try read(window: window, application: original.application,
                                   mayAct: mayAct, mode: .webUploadListing),
              fresh.application == original.application, fresh.url == original.url,
              let current = retained[fresh.id], current.application == original.application,
              CFEqual(current.window, window), CFEqual(current.webArea, original.webArea),
              current.url == original.url else { return nil }
        let sameReference = current.listingRows.first(where: { CFEqual($0.value, originalElement) })
        guard let sameReference,
              let freshRow = fresh.webUploadListingRows.first(where: { $0.rowID == sameReference.key }),
              requiredLabels.isSubset(of: Set(freshRow.cellLabels)),
              let frame = freshRow.frame,
              [windowBounds.minX, windowBounds.minY, windowBounds.width, windowBounds.height,
               frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              windowBounds.width > 0, windowBounds.height > 0, frame.width > 0, frame.height > 0,
              windowBounds.contains(frame) else { return nil }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        guard try hitPathAtPoint(point, contains: sameReference.value, webArea: original.webArea,
            window: original.window, mayAct: mayAct, rejectInteractiveDescendants: true) else { return nil }
        return point
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

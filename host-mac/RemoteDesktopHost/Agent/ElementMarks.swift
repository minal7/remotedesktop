import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
protocol PixelElementReference: AnyObject {
    var role: String { get }
    var name: String { get }
    var isEnabled: Bool? { get }
    var identity: AnyHashable? { get }
    func currentScreenRect() -> CGRect?
    func isSecure() -> Bool
    func acceptsHit(at point: CGPoint, intendedIdentity: AnyHashable,
                    deadline: ContinuousClock.Instant) -> Bool?
}

@MainActor
extension PixelElementReference {
    var identity: AnyHashable? { nil }
    func acceptsHit(at point: CGPoint, intendedIdentity: AnyHashable,
                    deadline: ContinuousClock.Instant) -> Bool? { nil }
}

struct PixelElementMark {
    let id: Int
    let role: String
    let name: String
    let screenRect: CGRect
    let state: [String]
    let inView: Bool
    let reference: (any PixelElementReference)?
    let identity: AnyHashable?

    init(id: Int, role: String, name: String, screenRect: CGRect, state: [String], inView: Bool,
         reference: (any PixelElementReference)? = nil, identity: AnyHashable? = nil) {
        self.id = id; self.role = role; self.name = name; self.screenRect = screenRect
        self.state = state; self.inView = inView; self.reference = reference; self.identity = identity
    }
}

struct PixelElementMarks {
    let marks: [PixelElementMark]
    let focusedID: Int?
    let secureScreenRects: [CGRect]
    let overlayBounds: [CGRect]
    let contentRect: CGRect?
    let browserURL: String?
    let axState: [PixelAXElementState]?
}

enum PixelWindowDisposition: Equatable { case window, systemOverlay, unknown, notAppWindow }

enum PixelWindowTreeShape: Equatable { case singleButtonOnly, other, incomplete }

enum SystemVoiceOverlayFailure: Error { case notFrontmost, secureFocus, inspectionUnavailable, persists, detected }
extension SystemVoiceOverlayFailure {
    var environmentError: AgentEnvironmentError {
        switch self {
        case .notFrontmost: .scopeChanged
        case .secureFocus: .credentialHandoff
        case .inspectionUnavailable: .unavailable("Accessibility could not verify the system overlay state.")
        case .persists, .detected: .systemHandoff("A system voice overlay is open on your Mac; close it and tap Resume")
        }
    }
}
enum SystemVoiceOverlayInputState: Equatable { case blocking, nonblocking, unknown }
enum SystemVoiceOverlayDecision: Equatable { case proceed, dismissOnce, handoff }

struct PixelWindowEvidence {
    let appPID: Int32
    let ownerPID: Int32
    let windowID: UInt32
    let layer: Int
    let role: String
    let subrole: String?
    let title: String?
    let document: String?
    let tree: PixelWindowTreeShape
}


/// A best-effort, deadline-bounded reader. A slow app contributes an empty mark list.
@MainActor
enum ElementMarks {
    private struct Candidate {
        let identity: AnyHashable
        let role: String
        let name: String
        let rect: CGRect
        let sourceRect: CGRect
        let state: [String]
        let inWindow: Bool
        let enabled: Bool
        let value: String?
        let node: any PixelAXNode
    }

    private static let structuralRoles: Set<String> = [
        "AXApplication", "AXWindow", "AXGroup", "AXContainer", "AXScrollArea", "AXWebArea", "AXList", "AXTable", "AXOutline"
    ]

    static func classifyWindow(_ evidence: PixelWindowEvidence) -> PixelWindowDisposition {
        guard evidence.appPID > 0, evidence.ownerPID == evidence.appPID,
              evidence.windowID > 0, evidence.layer == 0 else { return .notAppWindow }
        let roleIsWindow = ["AXWindow", "AXDialog", "AXSheet"].contains(evidence.role)
        let subroleIsWindow = ["AXStandardWindow", "AXDialog", "AXSystemDialog"].contains(evidence.subrole ?? "")
        guard roleIsWindow && subroleIsWindow else { return .unknown }
        let hasDocument = evidence.document?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let named = [evidence.title, evidence.document].compactMap { $0 }
            .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if evidence.role == "AXWindow", evidence.subrole == "AXDialog", !hasDocument,
           evidence.tree == .singleButtonOnly { return .systemOverlay }
        if roleIsWindow && subroleIsWindow && named { return .window }
        if evidence.role == "AXWindow", evidence.subrole == "AXDialog" {
            if evidence.tree == .other { return .window }
        } else if roleIsWindow && evidence.tree == .other { return .window }
        return .unknown
    }

    static func classifyAXWindow(_ window: AXUIElement, appPID: Int32,
                                 cgWindowID: UInt32) -> PixelWindowDisposition {
        guard let cg = cgWindowInfo(cgWindowID),
              let role = requiredString(window, kAXRoleAttribute as String, deadline: ContinuousClock.now + .milliseconds(120)) else { return .unknown }
        let deadline = ContinuousClock.now + .milliseconds(120)
        guard let subrole = requiredString(window, kAXSubroleAttribute as String, deadline: deadline),
              let (title, titleComplete) = optionalString(window, kAXTitleAttribute as String, deadline: deadline), titleComplete,
              let (document, documentComplete) = optionalString(window, kAXDocumentAttribute as String, deadline: deadline), documentComplete else { return .unknown }
        let tree = document?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? .other : inspectOverlayTree(window, deadline: deadline)
        return classifyWindow(.init(appPID: appPID, ownerPID: cg.ownerPID, windowID: cg.windowID,
            layer: cg.layer, role: role, subrole: subrole, title: title, document: document, tree: tree))
    }

    /// Recognizes only a complete, documentless AX dialog with one button and optional groups.
    /// Any timeout, unsupported container, or unfamiliar control fails closed.
    static func isSystemVoiceOverlay(_ window: AXUIElement, ownerPID: Int32) -> Bool {
        systemVoiceOverlayWindowID(window, ownerPID: ownerPID) != nil
    }

    static func systemVoiceOverlayWindowID(_ window: AXUIElement, ownerPID: Int32) -> UInt32? {
        let deadline = ContinuousClock.now + .milliseconds(120)
        guard let role = requiredString(window, kAXRoleAttribute as String, deadline: deadline),
              let subrole = requiredString(window, kAXSubroleAttribute as String, deadline: deadline),
              let bounds = rect(window, deadline: deadline), valid(bounds),
              let (title, titleComplete) = optionalString(window, kAXTitleAttribute as String, deadline: deadline), titleComplete,
              let (document, documentComplete) = optionalString(window, kAXDocumentAttribute as String, deadline: deadline), documentComplete,
              let cg = matchingCGWindow(ownerPID: ownerPID, bounds: bounds,
                  title: title) else { return nil }
        let shape = inspectOverlayTree(window, deadline: deadline)
        guard classifyWindow(.init(appPID: ownerPID, ownerPID: cg.ownerPID, windowID: cg.windowID,
            layer: cg.layer, role: role, subrole: subrole, title: title, document: document, tree: shape)) == .systemOverlay else { return nil }
        return cg.windowID
    }

    private static func inspectOverlayTree(_ root: AXUIElement, deadline: ContinuousClock.Instant) -> PixelWindowTreeShape {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0, buttons = 0
        while !stack.isEmpty {
            guard ContinuousClock.now < deadline, visited < 32 else { return .incomplete }
            let (element, depth) = stack.removeLast(); visited += 1
            guard depth <= 6, let role = requiredString(element, kAXRoleAttribute as String, deadline: deadline) else { return .incomplete }
            if role == "AXButton" {
                buttons += 1
                guard let (_, complete) = optionalString(element, kAXTitleAttribute as String, deadline: deadline), complete else { return .incomplete }
            } else if role != "AXWindow" && role != "AXGroup" { return .other }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
            if error == .noValue, role == "AXButton" { continue }
            guard error == .success, let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return .incomplete }
            guard let childElements = strictAXChildren(value) else { return .incomplete }
            guard childElements.count <= 32 - visited - stack.count else { return .incomplete }
            stack.append(contentsOf: childElements.map { ($0, depth + 1) })
        }
        return buttons == 1 ? .singleButtonOnly : .other
    }

    private static func strictAXChildren(_ value: CFTypeRef) -> [AXUIElement]? {
        guard CFGetTypeID(value) == CFArrayGetTypeID() else { return nil }
        let array = unsafeBitCast(value, to: CFArray.self)
        var result: [AXUIElement] = []
        for index in 0..<CFArrayGetCount(array) {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { return nil }
            let item = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as CFTypeRef
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            result.append(unsafeBitCast(item, to: AXUIElement.self))
        }
        return result
    }

    private static func requiredString(_ element: AXUIElement, _ key: String,
                                       deadline: ContinuousClock.Instant) -> String? {
        guard ContinuousClock.now < deadline else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.025)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func optionalString(_ element: AXUIElement, _ key: String,
                                       deadline: ContinuousClock.Instant) -> (String?, Bool)? {
        guard ContinuousClock.now < deadline else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.025)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        if error == .success { return (value as? String, true) }
        if error == .noValue || error == .attributeUnsupported { return (nil, true) }
        return (nil, false)
    }

    private static func matchingCGWindow(ownerPID: Int32, bounds: CGRect, title: String?)
        -> (ownerPID: Int32, windowID: UInt32, layer: Int)? {
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let candidates = entries.compactMap { entry -> (Int32, UInt32, Int, String?, CGRect)? in
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let id = entry[kCGWindowNumber as String] as? UInt32, id > 0,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let raw = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return nil }
            return (pid, id, layer, entry[kCGWindowName as String] as? String, frame)
        }.filter { candidate in
            candidate.0 == ownerPID && candidate.2 == 0 && focusedWindowMatches(bounds, selectedBounds: candidate.4) &&
                (title?.isEmpty != false || candidate.3 == title)
        }
        guard candidates.count == 1, let item = candidates.first else { return nil }
        return (item.0, item.1, item.2)
    }

    private static func cgWindowInfo(_ windowID: UInt32) -> (ownerPID: Int32, windowID: UInt32, layer: Int)? {
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let entry = entries.first(where: { $0[kCGWindowNumber as String] as? UInt32 == windowID }),
              let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32,
              let layer = entry[kCGWindowLayer as String] as? Int else { return nil }
        return (ownerPID, windowID, layer)
    }

    static func applicationWindows(_ app: AXUIElement) -> [AXUIElement]? {
        AXUIElementSetMessagingTimeout(app, 0.12)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return nil }
        let array = unsafeBitCast(value, to: CFArray.self)
        var result: [AXUIElement] = []
        for index in 0..<CFArrayGetCount(array) {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { return nil }
            let item = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as CFTypeRef
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            result.append(unsafeBitCast(item, to: AXUIElement.self))
        }
        return result
    }

    static func systemVoiceOverlayWindows(_ appRoot: AXUIElement, ownerPID: Int32) -> [AXUIElement]? {
        guard let windows = applicationWindows(appRoot) else { return nil }
        return windows.filter { isSystemVoiceOverlay($0, ownerPID: ownerPID) }
    }

    static func overlayInputState(modal: Bool?, focused: Bool?) -> SystemVoiceOverlayInputState {
        if modal == true || focused == true { return .blocking }
        if modal == false && focused == false { return .nonblocking }
        return .unknown
    }

    static func systemVoiceOverlayInputState(_ window: AXUIElement, appRoot: AXUIElement) -> SystemVoiceOverlayInputState {
        let deadline = ContinuousClock.now + .milliseconds(30)
        let modal = read(window, kAXModalAttribute, deadline: deadline) as? Bool
        let focused = focusedWindow(appRoot).map { CFEqual($0, window) }
        return overlayInputState(modal: modal, focused: focused)
    }

    static func overlayDecision(isPresent: Bool, escapeAlreadySent: Bool) -> SystemVoiceOverlayDecision {
        !isPresent ? .proceed : escapeAlreadySent ? .handoff : .dismissOnce
    }

    static func dismissSystemVoiceOverlayIfPresent(app: NSRunningApplication, appRoot: AXUIElement,
                                                    injector: InputInjector,
                                                    escapeAlreadySent: Bool = false,
                                                    onEscapeSent: () -> Void = {},
                                                    canInject: () -> Bool) async throws -> Bool {
        guard let overlays = systemVoiceOverlayWindows(appRoot, ownerPID: app.processIdentifier) else {
            return false
        }
        let blocking = overlays.filter { systemVoiceOverlayInputState($0, appRoot: appRoot) == .blocking }
        switch overlayDecision(isPresent: !blocking.isEmpty, escapeAlreadySent: escapeAlreadySent) {
        case .proceed: return false
        case .handoff: throw SystemVoiceOverlayFailure.persists
        case .dismissOnce: break
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw SystemVoiceOverlayFailure.notFrontmost
        }
        if let focus = focusedElement(appRoot) {
            let role = string(focus, kAXRoleAttribute) ?? "unknown"
            if isSensitive(focus, role: role, name: label(focus)) { throw SystemVoiceOverlayFailure.secureFocus }
        }
        guard canInject() else { throw CancellationError() }
        do {
            try injector.applyHostKeyStroke(usage: 0x29, modifiers: 0,
                ifAllowed: canInject, beforePosting: { guard canInject() else { throw CancellationError() } })
        } catch is InputInjector.AutomationGateError { throw CancellationError() }
        onEscapeSent()
        try await Task.sleep(for: .milliseconds(100))
        guard let remaining = systemVoiceOverlayWindows(appRoot, ownerPID: app.processIdentifier) else {
            throw SystemVoiceOverlayFailure.inspectionUnavailable
        }
        let remainingStates = remaining.map { systemVoiceOverlayInputState($0, appRoot: appRoot) }
        guard !remainingStates.contains(.blocking) else { throw SystemVoiceOverlayFailure.persists }
        guard !remainingStates.contains(.unknown) else { throw SystemVoiceOverlayFailure.inspectionUnavailable }
        return true
    }

    static func focusedWindowMatches(_ focusedBounds: CGRect?, selectedBounds: CGRect, tolerance: CGFloat = 2) -> Bool {
        guard let focusedBounds, valid(focusedBounds), valid(selectedBounds), tolerance.isFinite, tolerance >= 0 else { return false }
        return abs(focusedBounds.minX - selectedBounds.minX) <= tolerance &&
            abs(focusedBounds.minY - selectedBounds.minY) <= tolerance &&
            abs(focusedBounds.width - selectedBounds.width) <= tolerance &&
            abs(focusedBounds.height - selectedBounds.height) <= tolerance
    }

    static func projectCaptureRoots(focusedWindow: (any PixelAXNode)?, focusedBounds: CGRect?,
                                    focusedElement: (any PixelAXNode)?, menuBar: (any PixelAXNode)?,
                                    selectedBounds: CGRect,
                                    deadline: ContinuousClock.Instant, readOnly: Bool = false,
                                    limit: Int = 60, maxNodes: Int = 160) -> PixelElementMarks {
        guard ContinuousClock.now < deadline else { return emptyProjection() }
        let matchedWindow = focusedWindow.flatMap {
            focusedWindowMatches(focusedBounds, selectedBounds: selectedBounds) ? $0 : nil
        }
        var secureScan: (rects: [CGRect], visited: Int) = ([], 0)
        if matchedWindow == nil, let focusedWindow, focusedWindow.role == "AXWindow" {
            secureScan = collectSecureRects(root: focusedWindow, deadline: deadline, maxNodes: maxNodes)
        }
        let roots = [matchedWindow, menuBar].compactMap { $0 }
        var projected = project(root: PixelAXCompositeNode(nodes: roots), windowBounds: selectedBounds,
            focusedIdentity: matchedWindow == nil ? nil : focusedElement?.identity,
            readOnly: readOnly, limit: limit, maxNodes: max(0, maxNodes - secureScan.visited), deadline: deadline)
        var focusRect: CGRect?
        if let focusedElement, ContinuousClock.now < deadline,
           (focusedElement.isProtected || focusedElement.isSecure),
           let rect = focusedElement.screenRect, valid(rect) { focusRect = rect }
        var secureRects = secureScan.rects + projected.secureScreenRects
        if let focusRect, !secureRects.contains(focusRect) { secureRects.append(focusRect) }
        if secureRects != projected.secureScreenRects {
            projected = PixelElementMarks(marks: projected.marks, focusedID: projected.focusedID,
                secureScreenRects: secureRects, overlayBounds: projected.overlayBounds, contentRect: projected.contentRect,
                browserURL: projected.browserURL, axState: projected.axState)
        }
        return projected
    }

    private static func collectSecureRects(root: any PixelAXNode, deadline: ContinuousClock.Instant,
                                           maxNodes: Int) -> (rects: [CGRect], visited: Int) {
        var rects: [CGRect] = [], visited = 0
        func walk(_ node: any PixelAXNode) {
            guard visited < maxNodes, ContinuousClock.now < deadline else { return }
            visited += 1
            if node.isProtected || node.isSecure {
                if let rect = node.screenRect, valid(rect) { rects.append(rect) }
                return
            }
            for child in node.children() { walk(child) }
        }
        walk(root)
        return (rects, visited)
    }

    private static func emptyProjection() -> PixelElementMarks {
        PixelElementMarks(marks: [], focusedID: nil, secureScreenRects: [], overlayBounds: [],
            contentRect: nil, browserURL: nil, axState: nil)
    }

    static func project(root: any PixelAXNode, windowBounds: CGRect, focusedIdentity: AnyHashable? = nil,
                        browserURL: String? = nil, readOnly: Bool = false, limit: Int = 60,
                        maxNodes: Int = 160, deadline: ContinuousClock.Instant? = nil) -> PixelElementMarks {
        var candidates: [Candidate] = [], secureRects: [CGRect] = [], overlayBounds: [CGRect] = []
        var childText: [AnyHashable: [String]] = [:]
        var contentRect: CGRect?
        var resolvedURL = browserURL
        var visited = 0

        func walk(_ node: any PixelAXNode, interactiveAncestors: [AnyHashable], viewportBounds: CGRect?) {
            guard visited < maxNodes, candidates.count < limit,
                  deadline.map({ ContinuousClock.now < $0 }) ?? true else { return }
            visited += 1
            let role = node.role
            guard !node.isHidden, role != "AXScrollBar" else { return }
            let rect = node.screenRect
            var childViewportBounds = viewportBounds
            if role == "AXScrollArea" || role == "AXClipView" {
                if let rect, valid(rect) { childViewportBounds = viewportBounds.map { $0.intersection(rect) } ?? rect }
                else { childViewportBounds = .null }
            }
            let protected = node.isProtected
            let secure = protected || node.isSecure
            if secure {
                if let rect, valid(rect) { secureRects.append(rect) }
                return
            }
            if ["AXSheet", "AXDialog"].contains(role), let rect, valid(rect) { overlayBounds.append(rect) }

            let fullWindowContainer = structuralRoles.contains(role) && rect.map {
                intersectionOverUnion($0, windowBounds) >= 0.9
            } == true
            let interactive = PixelTargetSnapping.interactiveRoles.contains(role) && !fullWindowContainer && role != "AXScrollBar"
            let title = normalized((interactive || role == "AXStaticText" || role == "AXWebArea") ? node.title : nil)
            if role == "AXWebArea" {
                contentRect = rect
                if resolvedURL == nil { resolvedURL = node.documentURL }
            }
            if !title.isEmpty, role == "AXStaticText", let parent = interactiveAncestors.last {
                childText[parent, default: []].append(title)
            }
            if interactive {
                let enabledValue = node.isEnabled
                let enabled = enabledValue != false
                var state = ["visible"]
                if !enabled { state.append("disabled") }
                if readOnly { state.append("read_only") }
                if let rect, valid(rect) {
                    let visibleRect: CGRect
                    if role == "AXMenuBarItem", viewportBounds == nil { visibleRect = rect }
                    else {
                        let clip = viewportBounds.map { $0.intersection(windowBounds) } ?? windowBounds
                        visibleRect = rect.intersection(clip)
                    }
                    if valid(visibleRect) {
                        let inWindow = role == "AXMenuBarItem" && viewportBounds == nil
                            ? rect.intersects(windowBounds) : true
                        candidates.append(Candidate(identity: node.identity, role: role, name: title,
                            rect: visibleRect, sourceRect: rect, state: state, inWindow: inWindow, enabled: enabled,
                            value: node.value, node: node))
                    }
                }
            }
            let childAncestors = interactive ? interactiveAncestors + [node.identity] : interactiveAncestors
            for child in node.children() {
                walk(child, interactiveAncestors: childAncestors, viewportBounds: childViewportBounds)
            }
        }

        walk(root, interactiveAncestors: [], viewportBounds: nil)
        let named = candidates.map { candidate -> Candidate in
            guard candidate.name.isEmpty, let lifted = childText[candidate.identity], !lifted.isEmpty else { return candidate }
            return Candidate(identity: candidate.identity, role: candidate.role, name: lifted.joined(separator: " "),
                rect: candidate.rect, sourceRect: candidate.sourceRect, state: candidate.state, inWindow: candidate.inWindow,
                enabled: candidate.enabled, value: candidate.value, node: candidate.node)
        }
        let sorted = named.sorted {
            let left = preference($0.role), right = preference($1.role)
            return left == right ? ($0.sourceRect.minY, $0.sourceRect.minX) < ($1.sourceRect.minY, $1.sourceRect.minX) : left > right
        }
        var deduplicated: [Candidate] = []
        for candidate in sorted {
            let duplicate = deduplicated.contains { existing in
                intersectionOverUnion(existing.sourceRect, candidate.sourceRect) >= 0.85
            }
            if !duplicate { deduplicated.append(candidate) }
        }
        let ordered = deduplicated.sorted { ($0.sourceRect.minY, $0.sourceRect.minX) < ($1.sourceRect.minY, $1.sourceRect.minX) }
        let marks = ordered.enumerated().map { index, candidate in
            PixelElementMark(id: index + 1, role: candidate.role, name: candidate.name, screenRect: candidate.rect,
                state: candidate.inWindow ? candidate.state : candidate.state + ["read_only", "offscreen"],
                inView: candidate.inWindow, reference: candidate.node.makeReference(observedName: candidate.name,
                    visibleRect: candidate.rect),
                identity: candidate.identity)
        }
        let axState = ordered.isEmpty ? nil : ordered.map { PixelAXElementState(identity: $0.identity, role: $0.role, title: $0.name,
            value: $0.value, isEnabled: $0.enabled) }
        let focusID = focusedIdentity.flatMap { identity in ordered.firstIndex(where: { $0.identity == identity }).map { $0 + 1 } }
        return PixelElementMarks(marks: marks, focusedID: focusID, secureScreenRects: secureRects, overlayBounds: overlayBounds,
            contentRect: contentRect, browserURL: resolvedURL, axState: axState)
    }

    static func read(window: AgentMacAccessibility.Window, budget: Duration = .milliseconds(300), limit: Int = 60) -> PixelElementMarks {
        let appRoot = AXUIElementCreateApplication(window.application.processIdentifier)
        return readCapture(window: window, focusedWindowElement: window.element, focusedBounds: window.bounds,
            appRoot: appRoot, application: window.application, selectedBounds: window.bounds, budget: budget, limit: limit)
    }

    static func readCapture(window: AgentMacAccessibility.Window?, focusedWindowElement: AXUIElement?,
                            focusedBounds: CGRect?, appRoot: AXUIElement, application: NSRunningApplication,
                            selectedBounds: CGRect, budget: Duration = .milliseconds(300),
                            limit: Int = 60) -> PixelElementMarks {
        let deadline = ContinuousClock.now + budget
        let focusedUIElement = ax(read(appRoot, kAXFocusedUIElementAttribute, deadline: deadline))
        let focusedNode = focusedWindowElement.map { AXPixelNode(element: $0, deadline: deadline) }
        let focusedElementNode = focusedUIElement.map { AXPixelNode(element: $0, deadline: deadline) }
        let menuNode = ax(read(appRoot, kAXMenuBarAttribute, deadline: deadline))
            .map { AXPixelNode(element: $0, deadline: deadline) }
        let browserURL = window.flatMap { safeURL(read($0.element, "AXURL", deadline: deadline) ?? read($0.element, kAXDocumentAttribute, deadline: deadline)) }
        let projected = projectCaptureRoots(focusedWindow: focusedNode, focusedBounds: focusedBounds,
            focusedElement: focusedElementNode, menuBar: menuNode,
            selectedBounds: selectedBounds, deadline: deadline,
            readOnly: AgentSafetyBoundary.readOnly(bundleID: application.bundleIdentifier, appName: application.localizedName),
            limit: limit)
        let result = PixelElementMarks(marks: projected.marks, focusedID: projected.focusedID,
            secureScreenRects: projected.secureScreenRects, overlayBounds: projected.overlayBounds,
            contentRect: projected.contentRect,
            browserURL: browserURL ?? projected.browserURL, axState: projected.axState)
        guard ContinuousClock.now < deadline else {
            return PixelElementMarks(marks: [], focusedID: nil, secureScreenRects: result.secureScreenRects,
                overlayBounds: result.overlayBounds,
                contentRect: result.contentRect, browserURL: browserURL, axState: nil)
        }
        return result
    }

    static func semanticLabel(for node: any PixelAXNode, deadline: ContinuousClock.Instant,
                              maxDepth: Int = 6, maxNodes: Int = 32) -> String {
        guard !node.isProtected, !node.isSecure else { return "" }
        let direct = normalized(node.title)
        if !direct.isEmpty { return direct }

        var visited = 1
        var labels: [String] = []
        func collect(_ parent: any PixelAXNode, depth: Int) {
            guard depth < maxDepth, ContinuousClock.now < deadline, visited < maxNodes else { return }
            for child in parent.children() {
                guard ContinuousClock.now < deadline, visited < maxNodes else { return }
                visited += 1
                guard !child.isProtected, !child.isSecure else { continue }
                let role = child.role
                if PixelTargetSnapping.interactiveRoles.contains(role) { continue }
                if role == "AXStaticText" {
                    let label = normalized(child.title)
                    if !label.isEmpty { labels.append(label) }
                } else {
                    collect(child, depth: depth + 1)
                }
            }
        }
        collect(node, depth: 0)
        return normalized(labels.joined(separator: " "))
    }

    private static func normalized(_ value: String?) -> String {
        guard let value else { return "" }
        return String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty && rect.minX.isFinite && rect.minY.isFinite &&
            rect.width.isFinite && rect.height.isFinite
    }

    private static func preference(_ role: String) -> Int {
        switch role {
        case "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem": 3
        case "AXTextField", "AXTextArea", "AXTextView", "AXSearchField": 2
        default: 1
        }
    }

    private static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let overlap = intersection.width * intersection.height
        let union = lhs.width * lhs.height + rhs.width * rhs.height - overlap
        return union > 0 ? overlap / union : 0
    }

    static func focusedWindow(_ app: AXUIElement) -> AXUIElement? {
        ax(read(app, kAXFocusedWindowAttribute, deadline: ContinuousClock.now + .milliseconds(10)))
    }

    static func bounds(_ element: AXUIElement) -> CGRect? {
        rect(element, deadline: ContinuousClock.now + .milliseconds(10))
    }

    static func focusedElement(_ app: AXUIElement) -> AXUIElement? {
        ax(read(app, kAXFocusedUIElementAttribute, deadline: ContinuousClock.now + .milliseconds(10)))
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        read(element, attribute, deadline: ContinuousClock.now + .milliseconds(10)) as? String
    }

    static func normalizedAXValue(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        return (value as? NSNumber)?.stringValue
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        read(element, attribute, deadline: ContinuousClock.now + .milliseconds(10)) as? Bool
    }

    static func label(_ element: AXUIElement) -> String {
        label(element, deadline: ContinuousClock.now + .milliseconds(40))
    }

    static func isSensitive(_ element: AXUIElement, role: String, name: String) -> Bool {
        let subrole = string(element, kAXSubroleAttribute) ?? ""
        let placeholder = string(element, "AXPlaceholderValue") ?? ""
        let protected = read(element, "AXProtectedContent", deadline: ContinuousClock.now + .milliseconds(10)) as? Bool == true
        return protected || AgentCredentialRule.isSensitive(role: role, name: name + " " + placeholder, state: [subrole])
    }

    static func currentScreenRect(_ element: AXUIElement) -> CGRect? {
        rect(element, deadline: ContinuousClock.now + .milliseconds(10))
    }

    static func read(_ element: AXUIElement, _ attribute: String, deadline: ContinuousClock.Instant) -> CFTypeRef? {
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { return nil }
        let seconds = min(0.01, max(0.001, Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18))
        AXUIElementSetMessagingTimeout(element, Float(seconds))
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    fileprivate static func label(_ element: AXUIElement, deadline: ContinuousClock.Instant) -> String {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXHelpAttribute] {
            guard let value = read(element, attribute, deadline: deadline) as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(256)) }
        }
        return ""
    }

    fileprivate static func rect(_ element: AXUIElement, deadline: ContinuousClock.Instant) -> CGRect? {
        guard let position = read(element, kAXPositionAttribute, deadline: deadline), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = read(element, kAXSizeAttribute, deadline: deadline), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    static func children(_ value: CFTypeRef?) -> [AXUIElement] {
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = unsafeBitCast(value, to: CFArray.self)
        return (0..<CFArrayGetCount(array)).compactMap { index in
            guard let raw = CFArrayGetValueAtIndex(array, index) else { return nil }
            return ax(Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as CFTypeRef)
        }
    }

    fileprivate static func ax(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func safeURL(_ value: CFTypeRef?) -> String? {
        let raw: String?
        if let value = value as? String { raw = value }
        else if let value, CFGetTypeID(value) == CFURLGetTypeID() {
            raw = (unsafeBitCast(value, to: CFURL.self) as URL).absoluteString
        } else { raw = nil }
        guard let raw, var parts = URLComponents(string: raw),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), let host = parts.host, !host.isEmpty else { return nil }
        parts.user = nil; parts.password = nil; parts.query = nil; parts.fragment = nil
        return parts.string
    }
}

@MainActor
private struct AXPixelNode: PixelAXNode {
    let element: AXUIElement
    let deadline: ContinuousClock.Instant

    var identity: AnyHashable { AnyHashable(PixelAXIdentity(element: element)) }
    var role: String { ElementMarks.read(element, kAXRoleAttribute, deadline: deadline) as? String ?? "unknown" }
    var title: String? { ElementMarks.label(element, deadline: deadline) }
    var value: String? { ElementMarks.normalizedAXValue(ElementMarks.read(element, kAXValueAttribute, deadline: deadline)) }
    var screenRect: CGRect? { ElementMarks.rect(element, deadline: deadline) }
    var isEnabled: Bool? { ElementMarks.read(element, kAXEnabledAttribute, deadline: deadline) as? Bool }
    var isHidden: Bool { ElementMarks.read(element, kAXHiddenAttribute, deadline: deadline) as? Bool == true }
    var isProtected: Bool { ElementMarks.read(element, "AXProtectedContent", deadline: deadline) as? Bool == true }
    var isSecure: Bool {
        let currentRole = role
        let subrole = ElementMarks.read(element, kAXSubroleAttribute, deadline: deadline) as? String ?? ""
        let placeholder = ElementMarks.read(element, "AXPlaceholderValue", deadline: deadline) as? String ?? ""
        return AgentCredentialRule.isSensitive(role: currentRole, name: (title ?? "") + " " + placeholder, state: [subrole])
    }
    var documentURL: String? { ElementMarks.safeURL(ElementMarks.read(element, "AXURL", deadline: deadline) ?? ElementMarks.read(element, kAXDocumentAttribute, deadline: deadline)) }
    func children() -> [any PixelAXNode] {
        ElementMarks.children(ElementMarks.read(element, kAXChildrenAttribute, deadline: deadline))
            .map { AXPixelNode(element: $0, deadline: deadline) }
    }
    func makeReference(observedName: String, visibleRect: CGRect?) -> (any PixelElementReference)? {
        AXPixelElementReference(element: element, visibleRect: visibleRect)
    }
}

@MainActor
private struct PixelAXCompositeNode: PixelAXNode {
    let nodes: [any PixelAXNode]
    var identity: AnyHashable { "pixel-ax-root" }
    var role: String { "AXApplication" }
    var title: String? { nil }
    var value: String? { nil }
    var screenRect: CGRect? { nil }
    var isEnabled: Bool? { nil }
    var isHidden: Bool { false }
    var isProtected: Bool { false }
    var isSecure: Bool { false }
    var documentURL: String? { nil }
    func children() -> [any PixelAXNode] { nodes }
    func makeReference(observedName: String, visibleRect: CGRect?) -> (any PixelElementReference)? { nil }
}

@MainActor
private final class AXPixelElementReference: PixelElementReference {
    private let element: AXUIElement
    private let visibleRect: CGRect?

    init(element: AXUIElement, visibleRect: CGRect?) { self.element = element; self.visibleRect = visibleRect }

    var role: String { ElementMarks.string(element, kAXRoleAttribute) ?? "unknown" }
    var identity: AnyHashable? { AnyHashable(PixelAXIdentity(element: element)) }
    var name: String {
        let deadline = ContinuousClock.now + .milliseconds(40)
        return ElementMarks.semanticLabel(for: AXPixelNode(element: element, deadline: deadline), deadline: deadline)
    }
    var isEnabled: Bool? { ElementMarks.bool(element, kAXEnabledAttribute) }
    func currentScreenRect() -> CGRect? {
        guard let current = ElementMarks.currentScreenRect(element) else { return nil }
        let clipped = visibleRect.map { current.intersection($0) } ?? current
        return !clipped.isNull && !clipped.isEmpty ? clipped : nil
    }
    func isSecure() -> Bool { ElementMarks.isSensitive(element, role: role, name: name) }
    func acceptsHit(at point: CGPoint, intendedIdentity: AnyHashable,
                    deadline: ContinuousClock.Instant) -> Bool? {
        guard ContinuousClock.now < deadline else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.01)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        let hitIdentity = AnyHashable(PixelAXIdentity(element: hit))
        if hitIdentity == intendedIdentity { return true }
        guard let hitRole = ElementMarks.read(hit, kAXRoleAttribute, deadline: deadline) as? String else { return nil }
        let hitActionable = PixelTargetSnapping.interactiveRoles.contains(hitRole)
        if hitActionable { return PixelAXHitIdentity.matches(hit: hitIdentity, target: intendedIdentity,
            hitActionable: true, parents: []) }
        var node = hit
        var parents: [(identity: AnyHashable, actionable: Bool)] = []
        for _ in 0..<5 {
            guard ContinuousClock.now < deadline,
                  let parentValue = ElementMarks.read(node, kAXParentAttribute, deadline: deadline),
                  let parent = ElementMarks.ax(parentValue),
                  let parentRole = ElementMarks.read(parent, kAXRoleAttribute, deadline: deadline) as? String else { return nil }
            let parentIdentity = AnyHashable(PixelAXIdentity(element: parent))
            let actionable = PixelTargetSnapping.interactiveRoles.contains(parentRole)
            parents.append((identity: parentIdentity, actionable: actionable))
            if actionable {
                return PixelAXHitIdentity.matches(hit: hitIdentity, target: intendedIdentity,
                    hitActionable: hitActionable, parents: parents)
            }
            node = parent
        }
        return PixelAXHitIdentity.matches(hit: hitIdentity, target: intendedIdentity,
            hitActionable: hitActionable, parents: parents)
    }
}

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
protocol PixelElementReference: AnyObject {
    var role: String { get }
    var name: String { get }
    var isEnabled: Bool? { get }
    func currentScreenRect() -> CGRect?
    func isSecure() -> Bool
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
    let contentRect: CGRect?
    let browserURL: String?
    let axState: [PixelAXElementState]?
}


enum PixelTargetRebinding {
    static func find(_ expected: AgentElement, in current: [PixelElementMark]) -> PixelElementMark? {
        let matches = current.filter { $0.role == expected.role && $0.name == expected.name }
        return matches.count == 1 ? matches[0] : nil
    }
}

@MainActor
enum PixelElementReferenceResolver {
    static func observed(_ target: AgentElement, in marks: [PixelElementMark]) throws -> any PixelElementReference {
        guard let mark = marks.first(where: { $0.id == target.id && $0.role == target.role && $0.name == target.name }),
              let reference = mark.reference else { throw AgentEnvironmentError.targetGone }
        return reference
    }

    static func rebound(_ target: AgentElement, in marks: [PixelElementMark]) throws -> any PixelElementReference {
        guard let mark = PixelTargetRebinding.find(target, in: marks), let reference = mark.reference else {
            throw AgentEnvironmentError.targetGone
        }
        return reference
    }

    static func currentCentre(_ target: AgentElement, reference: any PixelElementReference,
                              windowBounds: CGRect) throws -> CGPoint {
        guard reference.role == target.role, reference.name == target.name else { throw AgentEnvironmentError.targetGone }
        if reference.isSecure() { throw AgentEnvironmentError.credentialHandoff }
        if reference.isEnabled == false { throw AgentEnvironmentError.disabledTarget }
        guard let rect = reference.currentScreenRect(), valid(rect),
              rect.intersects(windowBounds) || reference.role == "AXMenuBarItem" else {
            throw AgentEnvironmentError.targetGone
        }
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty && rect.minX.isFinite && rect.minY.isFinite &&
        rect.width.isFinite && rect.height.isFinite
    }
}

/// A best-effort, deadline-bounded reader. A slow app contributes an empty mark list.
@MainActor
enum ElementMarks {
    private struct Candidate {
        let identity: AnyHashable
        let role: String
        let name: String
        let rect: CGRect
        let state: [String]
        let inWindow: Bool
        let enabled: Bool
        let value: String?
        let node: any PixelAXNode
    }

    private static let structuralRoles: Set<String> = [
        "AXApplication", "AXWindow", "AXGroup", "AXContainer", "AXScrollArea", "AXWebArea", "AXList", "AXTable", "AXOutline"
    ]

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
                secureScreenRects: secureRects, contentRect: projected.contentRect,
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
        PixelElementMarks(marks: [], focusedID: nil, secureScreenRects: [], contentRect: nil, browserURL: nil, axState: nil)
    }

    static func project(root: any PixelAXNode, windowBounds: CGRect, focusedIdentity: AnyHashable? = nil,
                        browserURL: String? = nil, readOnly: Bool = false, limit: Int = 60,
                        maxNodes: Int = 160, deadline: ContinuousClock.Instant? = nil) -> PixelElementMarks {
        var candidates: [Candidate] = [], secureRects: [CGRect] = []
        var childText: [AnyHashable: [String]] = [:]
        var contentRect: CGRect?
        var resolvedURL = browserURL
        var visited = 0

        func walk(_ node: any PixelAXNode, interactiveAncestors: [AnyHashable]) {
            guard visited < maxNodes, candidates.count < limit,
                  deadline.map({ ContinuousClock.now < $0 }) ?? true else { return }
            visited += 1
            let role = node.role
            let rect = node.screenRect
            let protected = node.isProtected
            let secure = protected || node.isSecure
            if secure {
                if let rect, valid(rect) { secureRects.append(rect) }
                return
            }

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
                guard let rect, valid(rect) else {
                    walkChildren(node, ancestors: interactiveAncestors + [node.identity], walk: walk)
                    return
                }
                let inWindow = rect.intersects(windowBounds)
                guard inWindow || role == "AXMenuBarItem" else {
                    walkChildren(node, ancestors: interactiveAncestors + [node.identity], walk: walk)
                    return
                }
                candidates.append(Candidate(identity: node.identity, role: role, name: title, rect: rect,
                    state: state, inWindow: inWindow, enabled: enabled, value: node.value, node: node))
            }
            walkChildren(node, ancestors: interactive ? interactiveAncestors + [node.identity] : interactiveAncestors, walk: walk)
        }

        walk(root, interactiveAncestors: [])
        let named = candidates.map { candidate -> Candidate in
            guard candidate.name.isEmpty, let lifted = childText[candidate.identity], !lifted.isEmpty else { return candidate }
            return Candidate(identity: candidate.identity, role: candidate.role, name: lifted.joined(separator: " "),
                rect: candidate.rect, state: candidate.state, inWindow: candidate.inWindow,
                enabled: candidate.enabled, value: candidate.value, node: candidate.node)
        }
        let sorted = named.sorted {
            let left = preference($0.role), right = preference($1.role)
            return left == right ? ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) : left > right
        }
        var deduplicated: [Candidate] = []
        for candidate in sorted {
            let duplicate = deduplicated.contains { existing in
                intersectionOverUnion(existing.rect, candidate.rect) >= 0.85
            }
            if !duplicate { deduplicated.append(candidate) }
        }
        let ordered = deduplicated.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
        let marks = ordered.enumerated().map { index, candidate in
            PixelElementMark(id: index + 1, role: candidate.role, name: candidate.name, screenRect: candidate.rect,
                state: candidate.inWindow ? candidate.state : candidate.state + ["read_only", "offscreen"],
                inView: candidate.inWindow, reference: candidate.node.makeReference(observedName: candidate.name),
                identity: candidate.identity)
        }
        let axState = ordered.isEmpty ? nil : ordered.map { PixelAXElementState(identity: $0.identity, role: $0.role, title: $0.name,
            value: $0.value, isEnabled: $0.enabled) }
        let focusID = focusedIdentity.flatMap { identity in ordered.firstIndex(where: { $0.identity == identity }).map { $0 + 1 } }
        return PixelElementMarks(marks: marks, focusedID: focusID, secureScreenRects: secureRects,
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
        let browserURL = window.flatMap { safeURL(read($0.element, kAXDocumentAttribute, deadline: deadline)) }
        let projected = projectCaptureRoots(focusedWindow: focusedNode, focusedBounds: focusedBounds,
            focusedElement: focusedElementNode, menuBar: menuNode,
            selectedBounds: selectedBounds, deadline: deadline,
            readOnly: AgentSafetyBoundary.readOnly(bundleID: application.bundleIdentifier, appName: application.localizedName),
            limit: limit)
        let result = PixelElementMarks(marks: projected.marks, focusedID: projected.focusedID,
            secureScreenRects: projected.secureScreenRects, contentRect: projected.contentRect,
            browserURL: browserURL ?? projected.browserURL, axState: projected.axState)
        guard ContinuousClock.now < deadline else {
            return PixelElementMarks(marks: [], focusedID: nil, secureScreenRects: result.secureScreenRects,
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

    private static func walkChildren(_ node: any PixelAXNode, ancestors: [AnyHashable],
                                     walk: (any PixelAXNode, [AnyHashable]) -> Void) {
        for child in node.children() { walk(child, ancestors) }
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

    fileprivate static func read(_ element: AXUIElement, _ attribute: String, deadline: ContinuousClock.Instant) -> CFTypeRef? {
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

    fileprivate static func children(_ value: CFTypeRef?) -> [AXUIElement] {
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = unsafeBitCast(value, to: CFArray.self)
        return (0..<CFArrayGetCount(array)).compactMap { index in
            guard let raw = CFArrayGetValueAtIndex(array, index) else { return nil }
            return ax(Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as CFTypeRef)
        }
    }

    private static func ax(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    fileprivate static func safeURL(_ value: CFTypeRef?) -> String? {
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
    var isProtected: Bool { ElementMarks.read(element, "AXProtectedContent", deadline: deadline) as? Bool == true }
    var isSecure: Bool {
        let currentRole = role
        let subrole = ElementMarks.read(element, kAXSubroleAttribute, deadline: deadline) as? String ?? ""
        let placeholder = ElementMarks.read(element, "AXPlaceholderValue", deadline: deadline) as? String ?? ""
        return AgentCredentialRule.isSensitive(role: currentRole, name: (title ?? "") + " " + placeholder, state: [subrole])
    }
    var documentURL: String? { ElementMarks.safeURL(ElementMarks.read(element, kAXDocumentAttribute, deadline: deadline)) }
    func children() -> [any PixelAXNode] {
        ElementMarks.children(ElementMarks.read(element, kAXChildrenAttribute, deadline: deadline))
            .map { AXPixelNode(element: $0, deadline: deadline) }
    }
    func makeReference(observedName: String) -> (any PixelElementReference)? {
        AXPixelElementReference(element: element)
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
    var isProtected: Bool { false }
    var isSecure: Bool { false }
    var documentURL: String? { nil }
    func children() -> [any PixelAXNode] { nodes }
    func makeReference(observedName: String) -> (any PixelElementReference)? { nil }
}

@MainActor
private final class AXPixelElementReference: PixelElementReference {
    private let element: AXUIElement

    init(element: AXUIElement) { self.element = element }

    var role: String { ElementMarks.string(element, kAXRoleAttribute) ?? "unknown" }
    var name: String {
        let deadline = ContinuousClock.now + .milliseconds(40)
        return ElementMarks.semanticLabel(for: AXPixelNode(element: element, deadline: deadline), deadline: deadline)
    }
    var isEnabled: Bool? { ElementMarks.bool(element, kAXEnabledAttribute) }
    func currentScreenRect() -> CGRect? { ElementMarks.currentScreenRect(element) }
    func isSecure() -> Bool { ElementMarks.isSensitive(element, role: role, name: name) }
}

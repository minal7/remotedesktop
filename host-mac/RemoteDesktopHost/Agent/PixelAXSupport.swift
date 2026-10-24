import CoreGraphics
import Foundation
import ApplicationServices

/// Small lazy seam shared by the production AX reader and deterministic tree tests.
@MainActor
protocol PixelAXNode {
    var identity: AnyHashable { get }
    var role: String { get }
    var title: String? { get }
    var value: String? { get }
    var screenRect: CGRect? { get }
    var isEnabled: Bool? { get }
    var isHidden: Bool { get }
    var isProtected: Bool { get }
    var isSecure: Bool { get }
    var documentURL: String? { get }
    func children() -> [any PixelAXNode]
    func makeReference(observedName: String, visibleRect: CGRect?) -> (any PixelElementReference)?
}

struct PixelAXIdentity: Hashable {
    let element: AXUIElement

    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

@MainActor
struct PixelFocusedAXPath {
    let elements: [AXUIElement]
    let ownerWindow: AnyHashable
    let selectedWindow: AnyHashable
    let focusPID: pid_t
    let windowPID: pid_t

    static func read(_ focus: AXUIElement?, window: AXUIElement?, appPID: pid_t,
                     deadline: ContinuousClock.Instant) -> Self? {
        guard let focus, let window, ContinuousClock.now < deadline,
              let owner = ElementMarks.ax(ElementMarks.read(focus, kAXWindowAttribute, deadline: deadline)),
              CFEqual(owner, window) else { return nil }
        var focusPID: pid_t = 0, windowPID: pid_t = 0
        guard AXUIElementGetPid(focus, &focusPID) == .success, AXUIElementGetPid(window, &windowPID) == .success,
              focusPID == appPID, windowPID == appPID else { return nil }
        var path = [focus], current = focus
        for _ in 0..<16 {
            guard ContinuousClock.now < deadline,
                  let parent = ElementMarks.ax(ElementMarks.read(current, kAXParentAttribute, deadline: deadline)) else { return nil }
            path.append(parent)
            if CFEqual(parent, window) {
                return Self(elements: path, ownerWindow: AnyHashable(PixelAXIdentity(element: owner)),
                    selectedWindow: AnyHashable(PixelAXIdentity(element: window)), focusPID: focusPID, windowPID: windowPID)
            }
            current = parent
        }
        return nil
    }
}

@MainActor
enum PixelFocusedAXProjection {
    static func project(path: [any PixelAXNode], ownerWindow: AnyHashable?, selectedWindow: AnyHashable?,
                        focusPID: pid_t?, selectedPID: pid_t?, expectedPID: pid_t,
                        windowBounds: CGRect, deadline: ContinuousClock.Instant) -> (visibleRect: CGRect?, secureRects: [CGRect]) {
        guard ContinuousClock.now < deadline, ownerWindow == selectedWindow, let focusPID, let selectedPID,
              focusPID == expectedPID, selectedPID == expectedPID, path.count > 1,
              path.last?.identity == selectedWindow, path.last?.role == "AXWindow", valid(windowBounds),
              let selectedRect = path.last?.screenRect, valid(selectedRect) else { return (nil, []) }
        let focusRect = path.first?.screenRect
        var clip = windowBounds.intersection(selectedRect), blocked = false, secure = false, secureRects: [CGRect] = []
        for node in path {
            guard ContinuousClock.now < deadline else { return (nil, secureRects) }
            let role = node.role
            if node.isProtected || node.isSecure {
                secure = true
                let rect = node.screenRect.flatMap { valid($0) ? $0 : nil } ?? windowBounds
                secureRects.append(rect)
            }
            if node.isHidden || role == "AXScrollBar" { blocked = true }
            if role == "AXScrollArea" || role == "AXClipView" {
                guard let rect = node.screenRect, valid(rect) else { blocked = true; continue }
                clip = clip.intersection(rect)
            }
        }
        let visibleSecureRects = secureRects.map { $0.intersection(clip) }.filter { valid($0) }
        if secure { return (nil, visibleSecureRects) }
        guard !blocked, let focusRect, valid(focusRect), clip.contains(CGPoint(x: focusRect.midX, y: focusRect.midY)) else { return (nil, []) }
        return (focusRect.intersection(clip), [])
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty && rect.minX.isFinite && rect.minY.isFinite &&
            rect.width.isFinite && rect.height.isFinite
    }
}

enum PixelAXHitIdentity {
    static func matches<Identity: Equatable>(hit: Identity, target: Identity, hitActionable: Bool = false,
                                             parents: [(identity: Identity, actionable: Bool)], maximumParents: Int = 5) -> Bool {
        if hit == target { return true }
        if hitActionable { return false }
        return parents.prefix(max(0, maximumParents)).first(where: { $0.actionable })?.identity == target
    }
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
                              windowBounds: CGRect, note: ((String) -> Void)? = nil) throws -> CGPoint {
        guard reference.role == target.role, reference.name == target.name else { throw AgentEnvironmentError.targetGone }
        if reference.isSecure() { throw AgentEnvironmentError.credentialHandoff }
        if reference.isEnabled == false { throw AgentEnvironmentError.disabledTarget }
        guard let rect = reference.currentScreenRect(), valid(rect),
              rect.intersects(windowBounds) || reference.role == "AXMenuBarItem" else {
            throw AgentEnvironmentError.targetGone
        }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let identity = reference.identity else { return center }
        let deadline = ContinuousClock.now + .milliseconds(300)
        switch reference.acceptsHit(at: center, intendedIdentity: identity, deadline: deadline) {
        case true: return center
        case false:
            if let point = PixelTargetSnapping.nearestHitPoint(to: center, in: rect, deadline: deadline,
                matches: { reference.acceptsHit(at: $0, intendedIdentity: identity, deadline: deadline) }) {
                note?("adjusted click within mark \(target.id)")
                return point
            }
            note?("target overlapped")
            return center
        case nil:
            note?("target hit could not be verified")
            return center
        }
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty && rect.minX.isFinite && rect.minY.isFinite &&
        rect.width.isFinite && rect.height.isFinite
    }
}

struct PixelAXElementState {
    let identity: AnyHashable
    let role: String
    let title: String
    let isEnabled: Bool?
    private let isSecure: Bool
    private let ordinaryValue: String?

    init(identity: AnyHashable, role: String, title: String, value: String?, isEnabled: Bool?, isSecure: Bool = false) {
        self.identity = identity
        self.role = role
        self.isSecure = isSecure
        self.title = isSecure ? role : title
        self.isEnabled = isEnabled
        ordinaryValue = isSecure ? nil : value
    }

    fileprivate func valueChanged(from old: Self) -> Bool { ordinaryValue != old.ordinaryValue }
    fileprivate var displayTitle: String { isSecure ? role : (title.isEmpty ? role : title) }
}

enum PixelAXDiff {
    static func describe(before: [PixelAXElementState]?, after: [PixelAXElementState]?, sameApplication: Bool,
                         windowChanged: Bool) -> [String] {
        guard sameApplication, let before, let after else { return ["window changed: \(windowChanged ? "yes" : "no")"] }
        var changes: [String] = []
        let afterIDs = Set(after.map(\.identity))
        let beforeIDs = Set(before.map(\.identity))
        for old in before where !afterIDs.contains(old.identity) {
            changes.append("- \(old.displayTitle)")
            if changes.count == 10 { return changes }
        }
        for fresh in after where !beforeIDs.contains(fresh.identity) {
            changes.append("+ \(fresh.displayTitle)")
            if changes.count == 10 { return changes }
        }
        let oldByID = Dictionary(before.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        for fresh in after {
            guard let old = oldByID[fresh.identity] else { continue }
            let prefix = "~ \(fresh.displayTitle): "
            if old.title != fresh.title { changes.append(prefix + "title changed") }
            if fresh.valueChanged(from: old) { changes.append(prefix + "value changed") }
            if old.isEnabled != fresh.isEnabled { changes.append(prefix + "enabled changed") }
            if changes.count >= 10 { return Array(changes.prefix(10)) }
        }
        return changes
    }
}

enum PixelExecutionDescription {
    static func targetLabel(_ target: AgentTarget, resolvedTargets: [AgentElement], frameElements: [AgentElement]) -> String {
        switch target {
        case let .element(id):
            let mark = resolvedTargets.first(where: { $0.id == id }) ?? frameElements.first(where: { $0.id == id })
            guard let mark else { return "mark \(id)" }
            return "mark \(id) \"\(mark.name)\""
        case let .point(x, y):
            if let mark = AgentTargetBinding.hit(x: x, y: y, elements: resolvedTargets)
                ?? AgentTargetBinding.hit(x: x, y: y, elements: frameElements) {
                return "point (\(Int(x)),\(Int(y)) over \"\(mark.name)\")"
            }
            return "point (\(Int(x)),\(Int(y)))"
        }
    }
}

enum PixelFocusedRecipient {
    @MainActor
    static func current(expectedPID: pid_t?) throws -> AXUIElement {
        let system = AXUIElementCreateSystemWide()
        return try authorize(expectedPID: expectedPID, isAXTrusted: AXIsProcessTrusted(),
            focused: { ElementMarks.focusedElement(system, timeout: .milliseconds(100)) }, processID: { element in
                var processID: pid_t = 0
                return AXUIElementGetPid(element, &processID) == .success ? processID : nil
            }, attribute: { ElementMarks.read($0, $1, deadline: .now + .milliseconds(10)) })
    }

    static func authorize<Element>(expectedPID: pid_t?, isAXTrusted: Bool,
                                   focused: () -> Element?, processID: (Element) -> pid_t?,
                                   attribute: (Element, String) -> Any?) throws -> Element {
        guard isAXTrusted, let expectedPID, let element = focused(),
              let actualPID = processID(element) else {
            throw AgentEnvironmentError.systemHandoff("The focused control could not be verified safely.")
        }
        guard let role = attribute(element, kAXRoleAttribute as String) as? String, !role.isEmpty else {
            throw AgentEnvironmentError.systemHandoff("The focused control could not be verified safely.")
        }
        let subrole = attribute(element, kAXSubroleAttribute as String) as? String ?? ""
        let name = [kAXTitleAttribute as String, kAXDescriptionAttribute as String,
                    "AXPlaceholderValue", kAXHelpAttribute as String]
            .compactMap { attribute(element, $0) as? String }.joined(separator: " ")
        let protected = attribute(element, "AXProtectedContent") as? Bool == true
        guard !protected,
              !AgentCredentialRule.isSensitive(role: role, name: name, state: [subrole]) else {
            throw AgentEnvironmentError.credentialHandoff
        }
        guard actualPID == expectedPID else { throw AgentEnvironmentError.scopeChanged }
        return element
    }
}

@MainActor
enum PixelPersonalDataTargetGuard {
    struct Descriptor: Equatable {
        let role: String
        let name: String
        let pid: pid_t?

        init(role: String, name: String, pid: pid_t? = nil) {
            self.role = role
            self.name = name
            self.pid = pid
        }
    }

    static func descriptors(at point: CGPoint) -> [Descriptor] {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.04)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return [] }
        return descriptors(from: hit)
    }

    static func descriptors(from start: AXUIElement) -> [Descriptor] {
        let deadline = ContinuousClock.now + .milliseconds(300)
        var node = start
        var result: [Descriptor] = []
        for _ in 0...5 {
            guard ContinuousClock.now < deadline else { break }
            AXUIElementSetMessagingTimeout(node, 0.04)
            var pid: pid_t = 0
            let pidKnown = AXUIElementGetPid(node, &pid) == .success
            result.append(.init(role: ElementMarks.string(node, kAXRoleAttribute) ?? "",
                                name: ElementMarks.label(node, deadline: deadline),
                                pid: pidKnown ? pid : nil))
            if let role = result.last?.role, PixelTargetSnapping.interactiveRoles.contains(role) { break }
            guard ContinuousClock.now < deadline,
                  let parentValue = ElementMarks.read(node, kAXParentAttribute, deadline: deadline),
                  let parent = ElementMarks.ax(parentValue) else { break }
            node = parent
        }
        return result
    }

    static func isBlocked(path: [Descriptor]) -> Bool {
        path.contains {
            AgentCredentialRule.isPersonalDataRetrievalControl(role: $0.role, name: $0.name, state: [])
        }
    }

    static func performIfAllowed<T>(path: [Descriptor], action: () throws -> T) throws -> T {
        guard !isBlocked(path: path) else {
            throw AgentEnvironmentError.unavailable(AgentCredentialRule.personalDataRetrievalDeniedReason)
        }
        return try action()
    }
}

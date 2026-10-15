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
    var isProtected: Bool { get }
    var isSecure: Bool { get }
    var documentURL: String? { get }
    func children() -> [any PixelAXNode]
    func makeReference(observedName: String) -> (any PixelElementReference)?
}

struct PixelAXIdentity: Hashable {
    let element: AXUIElement

    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
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
            focused: { ElementMarks.focusedElement(system) }, processID: { element in
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

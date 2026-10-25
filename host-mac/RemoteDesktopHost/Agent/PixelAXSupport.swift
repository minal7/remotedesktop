import AppKit
import CoreGraphics
import Foundation
import ApplicationServices

enum PixelWindowDisposition: Equatable { case window, systemOverlay, unknown, notAppWindow }
enum PixelWindowTreeShape: Equatable { case singleButtonOnly, other, incomplete }

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
    var defaultButtonEvidence: AgentDefaultButtonEvidence = .unknown
    var requiresProtectedRegionHandoff: Bool = false
}

@MainActor
struct PixelClipboardLease {
    private let board: NSPasteboard
    private let saved: [[(NSPasteboard.PasteboardType, Data)]]
    private let stagedChangeCount: Int

    init(board: NSPasteboard, text: String) {
        self.board = board
        saved = board.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        board.clearContents()
        board.setString(text, forType: .string)
        board.setData(Data("1".utf8), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        stagedChangeCount = board.changeCount
    }

    func restore() {
        guard board.changeCount == stagedChangeCount else { return }
        board.clearContents()
        let items = saved.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }
}

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

enum PixelTextInsertion {
    enum Readback: Equatable { case matches, unchanged, unverified }

    static func expectedValue(oldValue: String?, inserted: String, mode: AgentTextMode,
                              selection: AgentSelection?) -> String? {
        if mode == .replace { return inserted }
        guard let oldValue, let selection,
              selection.start >= 0, selection.end >= selection.start else { return nil }
        let source = oldValue as NSString
        guard selection.end <= source.length,
              isUTF16Boundary(selection.start, in: oldValue),
              isUTF16Boundary(selection.end, in: oldValue) else { return nil }
        return source.replacingCharacters(in: NSRange(location: selection.start,
            length: selection.end - selection.start), with: inserted)
    }

    @MainActor
    static func selectedRange(_ element: AXUIElement, valueLength: Int?) -> AgentSelection? {
        guard let valueLength,
              let raw = ElementMarks.read(element, kAXSelectedTextRangeAttribute,
                deadline: ContinuousClock.now + .milliseconds(10)),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(raw, to: AXValue.self)
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        let (end, overflow) = range.location.addingReportingOverflow(range.length)
        guard !overflow, end <= valueLength else { return nil }
        return AgentSelection(start: range.location, end: end)
    }

    static func readback(current: String?, oldValue: String?, expectedValue: String?) -> Readback {
        guard let current else { return .unverified }
        if let expectedValue, current == expectedValue { return .matches }
        if let oldValue, current == oldValue { return .unchanged }
        return .unverified
    }

    private static func isUTF16Boundary(_ offset: Int, in value: String) -> Bool {
        var position = 0
        for scalar in value.unicodeScalars {
            if position == offset { return true }
            position += scalar.utf16.count
            if position > offset { return false }
        }
        return position == offset
    }
}

struct PixelAXIdentity: Hashable {
    let element: AXUIElement

    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

enum PixelAXOwnerPath {
    struct Result { let attachedSheet: AnyHashable? }

    static func attachedSheet(_ path: [(identity: AnyHashable, role: String, pid: pid_t)],
                              selectedWindow: AnyHashable, attributeOwner: AnyHashable?, expectedPID: pid_t) -> Result? {
        guard let last = path.last, last.identity == selectedWindow, last.role == "AXWindow",
              path.allSatisfy({ $0.pid == expectedPID }),
              Set(path.map(\.identity)).count == path.count,
              !path.dropLast().contains(where: { $0.role == "AXApplication" || $0.role == "AXWindow" }) else { return nil }
        let sheets = path.filter { $0.role == "AXSheet" }
        guard sheets.count <= 1,
              (attributeOwner == nil ? sheets.count == 1 : attributeOwner == selectedWindow || attributeOwner == sheets.first?.identity) else { return nil }
        return Result(attachedSheet: sheets.first?.identity)
    }
}

@MainActor
enum PixelAttachedSheetOwner {
    struct Selection {
        let window: AXUIElement?
        let sheet: AXUIElement?
    }

    static func resolve(_ focusedWindow: AXUIElement?, appPID: Int32,
                        deadline: ContinuousClock.Instant) -> Selection {
        guard let focusedWindow else { return .init(window: nil, sheet: nil) }
        guard ElementMarks.read(focusedWindow, kAXRoleAttribute, deadline: deadline) as? String == "AXSheet" else {
            return .init(window: focusedWindow, sheet: nil)
        }
        guard let rect = ElementMarks.bounds(focusedWindow, deadline: deadline), valid(rect) else {
            return .init(window: nil, sheet: focusedWindow)
        }
        var sheetPID: pid_t = 0
        guard AXUIElementGetPid(focusedWindow, &sheetPID) == .success, sheetPID == appPID else {
            return .init(window: nil, sheet: focusedWindow)
        }
        var current = focusedWindow, visited = [focusedWindow]
        for _ in 0..<16 {
            guard ContinuousClock.now < deadline,
                  let parent = ElementMarks.ax(ElementMarks.read(current, kAXParentAttribute, deadline: deadline)),
                  !visited.contains(where: { CFEqual($0, parent) }) else { return .init(window: nil, sheet: focusedWindow) }
            var pid: pid_t = 0
            guard AXUIElementGetPid(parent, &pid) == .success, pid == appPID else { return .init(window: nil, sheet: focusedWindow) }
            visited.append(parent)
            let role = ElementMarks.read(parent, kAXRoleAttribute, deadline: deadline) as? String
            guard role != "AXApplication" else { return .init(window: nil, sheet: focusedWindow) }
            if role == "AXWindow" {
                guard let ownerBounds = ElementMarks.bounds(parent, deadline: deadline), valid(ownerBounds) else {
                    return .init(window: nil, sheet: focusedWindow)
                }
                return .init(window: parent, sheet: focusedWindow)
            }
            current = parent
        }
        return .init(window: nil, sheet: focusedWindow)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty && rect.minX.isFinite && rect.minY.isFinite &&
            rect.width.isFinite && rect.height.isFinite
    }
}

@MainActor
struct PixelFocusedAXPath {
    let elements: [AXUIElement]
    let ownerWindow: AnyHashable
    let selectedWindow: AnyHashable
    let focusPID: pid_t
    let windowPID: pid_t
    let attachedSheet: AnyHashable?
    let hasProtectedOrSecureAncestor: Bool

    static func read(_ focus: AXUIElement?, window: AXUIElement?, appPID: pid_t,
                     deadline: ContinuousClock.Instant) -> Self? {
        guard let focus, let window, ContinuousClock.now < deadline else { return nil }
        let owner = ElementMarks.ax(ElementMarks.read(focus, kAXWindowAttribute, deadline: deadline))
        var focusPID: pid_t = 0, windowPID: pid_t = 0
        guard AXUIElementGetPid(focus, &focusPID) == .success, AXUIElementGetPid(window, &windowPID) == .success,
              focusPID == appPID, windowPID == appPID else { return nil }
        var path = [focus], current = focus
        var visited: [AXUIElement] = [focus]
        for _ in 0..<16 {
            guard ContinuousClock.now < deadline,
                  let parent = ElementMarks.ax(ElementMarks.read(current, kAXParentAttribute, deadline: deadline)) else { return nil }
            guard !visited.contains(where: { CFEqual($0, parent) }) else { return nil }
            var parentPID: pid_t = 0
            guard AXUIElementGetPid(parent, &parentPID) == .success, parentPID == appPID else { return nil }
            visited.append(parent)
            path.append(parent)
            if CFEqual(parent, window) {
                let ownerPath = path.map { element in
                    (identity: AnyHashable(PixelAXIdentity(element: element)),
                     role: ElementMarks.read(element, kAXRoleAttribute, deadline: deadline) as? String ?? "",
                     pid: pid(of: element))
                }
                guard let ownerPathResult = PixelAXOwnerPath.attachedSheet(ownerPath,
                    selectedWindow: AnyHashable(PixelAXIdentity(element: window)),
                    attributeOwner: owner.map { AnyHashable(PixelAXIdentity(element: $0)) }, expectedPID: appPID) else { return nil }
                let protectedOrSecure = path.contains { element in
                    guard ContinuousClock.now < deadline else { return true }
                    let role = ElementMarks.read(element, kAXRoleAttribute, deadline: deadline) as? String ?? ""
                    let subrole = ElementMarks.read(element, kAXSubroleAttribute, deadline: deadline) as? String ?? ""
                    return ElementMarks.read(element, "AXProtectedContent", deadline: deadline) as? Bool == true ||
                        AgentCredentialRule.isSensitive(role: role, name: "", state: [subrole])
                }
                guard ContinuousClock.now < deadline else { return nil }
                return Self(elements: path, ownerWindow: AnyHashable(PixelAXIdentity(element: window)),
                    selectedWindow: AnyHashable(PixelAXIdentity(element: window)), focusPID: focusPID, windowPID: windowPID,
                    attachedSheet: ownerPathResult.attachedSheet, hasProtectedOrSecureAncestor: protectedOrSecure)
            }
            current = parent
        }
        return nil
    }

    private static func pid(of element: AXUIElement) -> pid_t {
        var value: pid_t = 0
        guard AXUIElementGetPid(element, &value) == .success else { return 0 }
        return value
    }
}

struct PixelTypingFocusBinding {
    struct Evidence {
        let focus: AnyHashable
        let ownerWindow: AnyHashable?
        let selectedWindow: AnyHashable?
        let focusPID: pid_t
        let windowPID: pid_t
        let attachedSheet: AnyHashable?

        init(focus: AnyHashable, ownerWindow: AnyHashable?, selectedWindow: AnyHashable?,
             focusPID: pid_t, windowPID: pid_t, attachedSheet: AnyHashable? = nil) {
            self.focus = focus; self.ownerWindow = ownerWindow; self.selectedWindow = selectedWindow
            self.focusPID = focusPID; self.windowPID = windowPID; self.attachedSheet = attachedSheet
        }
    }

    let focus: AnyHashable
    let window: AnyHashable
    let pid: pid_t
    let attachedSheet: AnyHashable?

    init(focus: AnyHashable, window: AnyHashable, pid: pid_t, attachedSheet: AnyHashable? = nil) {
        self.focus = focus; self.window = window; self.pid = pid; self.attachedSheet = attachedSheet
    }

    static func identity(_ element: AXUIElement) -> AnyHashable {
        AnyHashable(PixelAXIdentity(element: element))
    }

    @MainActor
    static func evidence(focus: AXUIElement, path: PixelFocusedAXPath,
                         selectedWindow: AXUIElement, expectedPID: pid_t) -> Evidence? {
        let selectedIdentity = identity(selectedWindow)
        guard path.ownerWindow == selectedIdentity, path.selectedWindow == selectedIdentity,
              path.focusPID == expectedPID, path.windowPID == expectedPID else { return nil }
        return Evidence(focus: identity(focus), ownerWindow: path.ownerWindow,
            selectedWindow: path.selectedWindow, focusPID: path.focusPID, windowPID: path.windowPID,
            attachedSheet: path.attachedSheet)
    }

    static func allows(_ evidence: Evidence?, binding: Self) -> Bool {
        guard let evidence else { return false }
        return evidence.focus == binding.focus && evidence.ownerWindow == binding.window &&
            evidence.selectedWindow == binding.window && evidence.focusPID == binding.pid &&
            evidence.windowPID == binding.pid && evidence.attachedSheet == binding.attachedSheet
    }

    static func require(_ evidence: Evidence?, binding: Self) throws {
        guard allows(evidence, binding: binding) else { throw AgentEnvironmentError.scopeChanged }
    }

    static func allowsPath(attachedSheet: AnyHashable?, hasProtectedOrSecureAncestor: Bool) -> Bool {
        attachedSheet == nil || !hasProtectedOrSecureAncestor
    }

    @MainActor
    static func current(in snapshot: PixelEnvironment.Snapshot, binding expected: Self? = nil)
        throws -> (AXUIElement, Self) {
        guard let selectedWindow = snapshot.window?.element,
              let pid = snapshot.application?.processIdentifier else { throw AgentEnvironmentError.scopeChanged }
        let focus = try PixelFocusedRecipient.current(expectedPID: pid)
        let deadline = ContinuousClock.now + .milliseconds(100)
        guard let path = PixelFocusedAXPath.read(focus, window: selectedWindow, appPID: pid, deadline: deadline) else {
            throw AgentEnvironmentError.scopeChanged
        }
        guard allowsPath(attachedSheet: path.attachedSheet,
                         hasProtectedOrSecureAncestor: path.hasProtectedOrSecureAncestor) else {
            throw AgentEnvironmentError.credentialHandoff
        }
        let binding = expected ?? Self(focus: identity(focus), window: identity(selectedWindow), pid: pid,
            attachedSheet: path.attachedSheet)
        try require(evidence(focus: focus, path: path, selectedWindow: selectedWindow, expectedPID: pid), binding: binding)
        try PixelPersonalDataTargetGuard.performIfAllowed(path: PixelPersonalDataTargetGuard.descriptors(from: focus)) {}
        return (focus, binding)
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
        let sheets = path.filter { $0.role == "AXSheet" }
        guard sheets.count <= 1 else { return (nil, []) }
        let surfaceBounds = sheets.first?.screenRect ?? windowBounds
        guard valid(surfaceBounds) else { return (nil, []) }
        let secureFallback = windowBounds.union(surfaceBounds)
        let focusRect = path.first?.screenRect
        var clip = sheets.isEmpty ? windowBounds.intersection(selectedRect) : surfaceBounds
        var blocked = false, secure = false, secureRects: [CGRect] = []
        for node in path.reversed() {
            guard ContinuousClock.now < deadline else { return (nil, secureRects) }
            let role = node.role
            if node.isProtected || node.isSecure {
                secure = true
                let rect = !sheets.isEmpty && node.identity == selectedWindow
                    ? secureFallback : node.screenRect.flatMap { valid($0) ? $0 : nil } ?? secureFallback
                secureRects.append(rect)
            }
            if node.isHidden || role == "AXScrollBar" { blocked = true }
            if role == "AXSheet" {
                guard let rect = node.screenRect, valid(rect), rect == surfaceBounds else { blocked = true; continue }
            }
            if role == "AXScrollArea" || role == "AXClipView" {
                guard let rect = node.screenRect, valid(rect) else { blocked = true; continue }
                clip = clip.intersection(rect)
            }
        }
        let visibleSecureRects = secureRects.map { $0 == secureFallback ? $0 : $0.intersection(clip) }.filter { valid($0) }
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

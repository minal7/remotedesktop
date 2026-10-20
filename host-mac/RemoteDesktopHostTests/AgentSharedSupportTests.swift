import Foundation
import ApplicationServices
import CoreGraphics
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class AgentSharedSupportTests: XCTestCase {
    func testMainWindowFallbackKeepsFullDisplayMappingInsideCurrentActionBoundary() throws {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let mainWindow = CGRect(x: 404, y: 175, width: 920, height: 436)
        let imageSize = CGSize(width: 1280, height: 720)
        let pixel = CGPoint(x: 1280 * 500.0 / 1920.0, y: 720 * 250.0 / 1080.0)
        let screenPoint = try XCTUnwrap(PixelEnvironment.mapPoint(pixel, imageSize: imageSize, screenBounds: display))
        XCTAssertEqual(screenPoint.x, 500, accuracy: 0.01)
        XCTAssertEqual(screenPoint.y, 250, accuracy: 0.01)
        XCTAssertTrue(PixelWindowActionBoundary.allows(screenPoint, windowBounds: mainWindow,
            menuBarBounds: [], sameAppDialogBounds: []))
        let outsidePixel = CGPoint(x: 1280 * 100.0 / 1920.0, y: 720 * 250.0 / 1080.0)
        let outsidePoint = try XCTUnwrap(PixelEnvironment.mapPoint(outsidePixel, imageSize: imageSize, screenBounds: display))
        XCTAssertFalse(PixelWindowActionBoundary.allows(outsidePoint, windowBounds: mainWindow,
            menuBarBounds: [], sameAppDialogBounds: []))
    }

    func testAuthorityDigestIsStableAndIncludesFullValueSelectionAndIdentity() throws {
        let base = authorityRecord(value: "prefix-hidden-suffix")
        XCTAssertEqual(try AgentMacAccessibility.AuthorityDigest.encode([base]),
                       try AgentMacAccessibility.AuthorityDigest.encode([base]))

        let changes = [
            authorityRecord(value: "prefix-hidden-other"),
            authorityRecord(value: "prefix-hidden-suffix", selection: .init(start: 2, end: 5)),
            authorityRecord(identifier: "different-control", value: "prefix-hidden-suffix")
        ]
        for changed in changes {
            XCTAssertNotEqual(try AgentMacAccessibility.AuthorityDigest.encode([base]),
                              try AgentMacAccessibility.AuthorityDigest.encode([changed]))
        }
        let other = authorityRecord(id: 9, value: "second")
        XCTAssertEqual(try AgentMacAccessibility.AuthorityDigest.encode([base, other]),
                       try AgentMacAccessibility.AuthorityDigest.encode([other, base]))
    }

    func testCredentialWordsInOrdinaryContentAreNotSecureMarkers() {
        XCTAssertFalse(AgentCredentialRule.isSensitive(role: "AXStaticText",
            name: "The instructions mention a password and an OTP", state: ["enabled"]))
        XCTAssertFalse(AgentCredentialRule.isSensitive(role: "HotPickButton",
            name: "Choose an item", state: ["enabled"]))
        XCTAssertTrue(AgentCredentialRule.isSensitive(role: "AXTextField",
            name: "One-time code", state: ["enabled"]))
    }

    func testActionTargetExtractionPreservesOnlyTargetsUsedByEachAction() {
        let point = AgentTarget.point(x: 0.4, y: 0.6)
        let first = AgentTarget.element(id: 1)
        let second = AgentTarget.element(id: 2)
        XCTAssertEqual(AgentTargetBinding.targets(.click(target: first, button: nil, count: nil)), [first])
        XCTAssertEqual(AgentTargetBinding.targets(.type(target: point, text: "x", mode: .replace)), [point])
        XCTAssertEqual(AgentTargetBinding.targets(.type(target: nil, text: "x", mode: .replace)), [])
        XCTAssertEqual(AgentTargetBinding.targets(.scroll(target: first, direction: .down, amount: 1)), [first])
        XCTAssertEqual(AgentTargetBinding.targets(.select(target: second, option: "option")), [second])
        XCTAssertEqual(AgentTargetBinding.targets(.setFiles(target: second, fileIDs: ["file"])), [second])
        XCTAssertEqual(AgentTargetBinding.targets(.drag(from: first, to: point)), [first, point])
        XCTAssertEqual(AgentTargetBinding.targets(.key(chord: "tab")), [])
    }

    func testPointHitChoosesSmallestContainingVisibleElement() {
        let elements = [
            element(id: 1, x: 0, y: 0, width: 100, height: 100),
            element(id: 2, x: 20, y: 20, width: 20, height: 20),
            element(id: 3, x: 24, y: 24, width: 4, height: 4, inView: false)
        ]
        XCTAssertEqual(AgentTargetBinding.hit(x: 25, y: 25, elements: elements)?.id, 2)
        XCTAssertEqual(AgentTargetBinding.hit(x: 40, y: 25, elements: elements)?.id, 1)
        XCTAssertNil(AgentTargetBinding.hit(x: 120, y: 120, elements: elements))
    }

    func testKeyboardPostingRequiresTheCurrentSystemFocusedRecipient() throws {
        let ordinary = FocusedRecipient(pid: 42, attributes: [
            kAXRoleAttribute as String: "AXTextField",
            kAXTitleAttribute as String: "Search"
        ])
        var requested: [String] = []
        let events = PostedHostEvents()

        XCTAssertThrowsError(try authorizeAndPost(ordinary, expectedPID: 7, trusted: true,
            requested: &requested, events: events)) {
            XCTAssertEqual($0 as? AgentEnvironmentError, .scopeChanged)
        }
        XCTAssertEqual(events.count, 0)

        requested.removeAll()
        XCTAssertNoThrow(try authorizeAndPost(ordinary, expectedPID: 42, trusted: true,
            requested: &requested, events: events))
        XCTAssertEqual(events.keyEventCount, 2)
        XCTAssertFalse(requested.contains(kAXValueAttribute as String))
    }

    func testKeyboardPostingHandsOffForSecureSystemFocusedRecipientWithoutReadingValue() {
        let secure = FocusedRecipient(pid: 42, attributes: [
            kAXRoleAttribute as String: "AXTextField",
            kAXSubroleAttribute as String: "AXSecureTextField",
            "AXPlaceholderValue": "Verification code"
        ])
        var requested: [String] = []
        let events = PostedHostEvents()

        XCTAssertThrowsError(try authorizeAndPost(secure, expectedPID: 7, trusted: true,
            requested: &requested, events: events)) {
            XCTAssertEqual($0 as? AgentEnvironmentError, .credentialHandoff)
        }
        XCTAssertEqual(events.count, 0)
        XCTAssertFalse(requested.contains(kAXValueAttribute as String))
    }

    func testKeyboardPostingHandsOffWhenSystemFocusedRecipientIsUnavailable() {
        let events = PostedHostEvents()
        var requested: [String] = []

        XCTAssertThrowsError(try authorizeAndPost(nil, expectedPID: 42, trusted: true,
            requested: &requested, events: events)) {
            XCTAssertEqual($0 as? AgentEnvironmentError,
                .systemHandoff("The focused control could not be verified safely."))
        }
        XCTAssertEqual(events.count, 0)
        XCTAssertTrue(requested.isEmpty)

        let unknownRole = FocusedRecipient(pid: 42, attributes: [:])
        XCTAssertThrowsError(try authorizeAndPost(unknownRole, expectedPID: 42, trusted: true,
            requested: &requested, events: events)) {
            XCTAssertEqual($0 as? AgentEnvironmentError,
                .systemHandoff("The focused control could not be verified safely."))
        }
        let ordinary = FocusedRecipient(pid: 42, attributes: [kAXRoleAttribute as String: "AXButton"])
        XCTAssertThrowsError(try authorizeAndPost(ordinary, expectedPID: 42, trusted: false,
            requested: &requested, events: events)) {
            XCTAssertEqual($0 as? AgentEnvironmentError,
                .systemHandoff("The focused control could not be verified safely."))
        }
        XCTAssertEqual(events.count, 0)
    }

    func testElementMarksPruneHiddenScrollbarAndZeroAreaNodesButKeepVisiblePartialControls() throws {
        let hiddenChild = MarkAXNode(identity: "hidden-child", role: "AXButton",
            rect: CGRect(x: 10, y: 10, width: 20, height: 20))
        let hidden = MarkAXNode(identity: "hidden", role: "AXGroup",
            rect: CGRect(x: 0, y: 0, width: 50, height: 50), hidden: true, children: [hiddenChild])
        let scrollChild = MarkAXNode(identity: "scroll-child", role: "AXButton",
            rect: CGRect(x: 70, y: 10, width: 20, height: 20))
        let scrollbar = MarkAXNode(identity: "scrollbar", role: "AXScrollBar",
            rect: CGRect(x: 95, y: 0, width: 5, height: 80), children: [scrollChild])
        let zero = MarkAXNode(identity: "zero", role: "AXButton",
            rect: CGRect(x: 10, y: 80, width: 0, height: 20))
        // Partial visibility is accepted only while the original centre remains visible.
        let partial = MarkAXNode(identity: "partial", role: "AXButton",
            rect: CGRect(x: 95, y: 30, width: 8, height: 20))
        let clipped = MarkAXNode(identity: "clipped", role: "AXButton",
            rect: CGRect(x: 65, y: 60, width: 8, height: 20))
        let outsideClip = MarkAXNode(identity: "outside-clip", role: "AXButton",
            rect: CGRect(x: 75, y: 60, width: 20, height: 20))
        let outsideCentre = MarkAXNode(identity: "outside-centre", role: "AXButton",
            rect: CGRect(x: 95, y: 10, width: 14, height: 20))
        let scrollArea = MarkAXNode(identity: "area", role: "AXScrollArea",
            rect: CGRect(x: 30, y: 50, width: 40, height: 40), children: [clipped, outsideClip])
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)

        let projected = ElementMarks.project(root: MarkAXNode.root([hidden, scrollbar, zero, partial, scrollArea, outsideCentre]),
            windowBounds: bounds)

        XCTAssertEqual(projected.marks.compactMap { $0.identity as? String }, ["partial", "clipped"])
        XCTAssertEqual(projected.marks.first?.screenRect, CGRect(x: 95, y: 30, width: 5, height: 20))
        XCTAssertEqual(projected.marks.last?.screenRect, CGRect(x: 65, y: 60, width: 5, height: 20))
        XCTAssertEqual(hidden.childrenReads, 0)
        XCTAssertEqual(scrollbar.childrenReads, 0)
        XCTAssertEqual(hiddenChild.valueReads, 0)
        let mark = try XCTUnwrap(projected.marks.first)
        let target = AgentElement(id: mark.id, role: mark.role, name: mark.name, value: nil,
            state: mark.state, bbox: .init(x: 0, y: 0, width: 1, height: 1), inView: mark.inView)
        let clippedReference = try XCTUnwrap(mark.reference as? MarkReference)
        clippedReference.rect = CGRect(x: 95, y: 30, width: 20, height: 20)
        XCTAssertEqual(try PixelElementReferenceResolver.currentCentre(target,
            reference: clippedReference, windowBounds: bounds), CGPoint(x: 97.5, y: 40))
    }

    func testOverlappedMarkPointUsesNearestPointHittingExactOrDescendant() {
        let bounds = CGRect(x: 10, y: 10, width: 40, height: 40)
        let reference = MarkReference(role: "AXButton", name: "Save", rect: bounds, identity: "save") { point in
            point.x > bounds.midX
        }
        let mark = PixelElementMark(id: 9, role: "AXButton", name: "Save", screenRect: bounds,
            state: ["visible"], inView: true, reference: reference, identity: "save")

        let result = PixelTargetSnapping.resolve(CGPoint(x: 30, y: 30), in: [mark],
            deadline: .now + .milliseconds(300))

        XCTAssertTrue(result.keepsCoordinate)
        XCTAssertEqual(result.mark?.id, 9)
        XCTAssertGreaterThan(result.point.x, 30)
        XCTAssertTrue(bounds.contains(result.point))
        XCTAssertNotEqual(result.point, CGPoint(x: 30, y: 30))
    }

    func testOverlapSearchPrefersTheNearestOfMultipleValidatedInteriors() {
        let rect = CGRect(x: 10, y: 10, width: 40, height: 40)
        let reference = MarkReference(role: "AXButton", name: "Save", rect: rect, identity: "save") { point in
            point.x > rect.midX + 5 || point.y > rect.midY + 1
        }
        let mark = PixelElementMark(id: 9, role: "AXButton", name: "Save", screenRect: rect,
            state: ["visible"], inView: true, reference: reference, identity: "save")

        let result = PixelTargetSnapping.resolve(CGPoint(x: 30, y: 30), in: [mark])

        XCTAssertTrue(result.keepsCoordinate)
        XCTAssertEqual(result.point.x, 30, accuracy: 0.01)
        XCTAssertGreaterThan(result.point.y, 31)
        XCTAssertLessThan(result.point.y, 31.1)
    }

    func testOverlappedMarkKeepsCentreWhenHitIsTheIntendedElement() {
        let rect = CGRect(x: 10, y: 10, width: 40, height: 40)
        let reference = MarkReference(role: "AXButton", name: "Save", rect: rect, identity: "save") { _ in true }
        let mark = PixelElementMark(id: 9, role: "AXButton", name: "Save", screenRect: rect,
            state: ["visible"], inView: true, reference: reference, identity: "save")
        let center = CGPoint(x: 30, y: 30)

        let result = PixelTargetSnapping.resolve(center, in: [mark])

        XCTAssertEqual(result.point, center)
        XCTAssertFalse(result.keepsCoordinate)
        XCTAssertNil(result.note)
    }

    func testElementTargetCentreUsesValidatedInteriorOrReportsOverlap() throws {
        let rect = CGRect(x: 10, y: 10, width: 40, height: 40)
        let target = AgentElement(id: 9, role: "AXButton", name: "Save", value: nil,
            state: ["visible"], bbox: .init(x: 0, y: 0, width: 1, height: 1), inView: true)
        let reference = MarkReference(role: "AXButton", name: "Save", rect: rect, identity: "save") {
            $0.x > rect.midX
        }
        var note: String?

        let adjusted = try PixelElementReferenceResolver.currentCentre(target, reference: reference,
            windowBounds: rect, note: { note = $0 })

        XCTAssertTrue(rect.contains(adjusted))
        XCTAssertGreaterThan(adjusted.x, rect.midX)
        XCTAssertTrue(note?.contains("adjusted click") == true)

        let blocked = MarkReference(role: "AXButton", name: "Save", rect: rect, identity: "save") { _ in false }
        note = nil
        let fallback = try PixelElementReferenceResolver.currentCentre(target, reference: blocked,
            windowBounds: rect, note: { note = $0 })
        XCTAssertEqual(fallback, CGPoint(x: rect.midX, y: rect.midY))
        XCTAssertEqual(note, "target overlapped")
    }

    func testOverlappedCoordinateTieKeepsOriginalPointWithoutChoosingAMark() {
        let rect = CGRect(x: 10, y: 10, width: 40, height: 40)
        let first = PixelElementMark(id: 1, role: "AXButton", name: "First", screenRect: rect,
            state: ["visible"], inView: true,
            reference: MarkReference(role: "AXButton", name: "First", rect: rect, identity: "first") { _ in true },
            identity: "first")
        let second = PixelElementMark(id: 2, role: "AXButton", name: "Second", screenRect: rect,
            state: ["visible"], inView: true,
            reference: MarkReference(role: "AXButton", name: "Second", rect: rect, identity: "second") { _ in true },
            identity: "second")
        let center = CGPoint(x: 30, y: 30)

        let result = PixelTargetSnapping.resolve(center, in: [first, second])

        XCTAssertEqual(result.point, center)
        XCTAssertNil(result.mark)
        XCTAssertEqual(result.note, "target overlapped")
        XCTAssertTrue(result.keepsCoordinate)
    }

    func testUnknownCoordinateHitDoesNotStartOverlapSearch() {
        let rect = CGRect(x: 10, y: 10, width: 40, height: 40)
        var probes = 0
        let reference = MarkReference(role: "AXButton", name: "Save", rect: rect, identity: "save") { _ in
            probes += 1
            return nil
        }
        let mark = PixelElementMark(id: 1, role: "AXButton", name: "Save", screenRect: rect,
            state: ["visible"], inView: true, reference: reference, identity: "save")
        let center = CGPoint(x: 30, y: 30)

        let result = PixelTargetSnapping.resolve(center, in: [mark])

        XCTAssertEqual(probes, 1)
        XCTAssertEqual(result.point, center)
        XCTAssertEqual(result.note, "target hit could not be verified")
        XCTAssertTrue(result.keepsCoordinate)
    }

    func testOverlappedMarkCentreHitIdentityUsesNearestActionableAncestorWithinFiveParents() {
        XCTAssertTrue(PixelAXHitIdentity.matches(hit: "button", target: "button", parents: []))
        XCTAssertTrue(PixelAXHitIdentity.matches(hit: "text", target: "button",
            parents: [("group", false), ("button", true)]))
        XCTAssertTrue(PixelAXHitIdentity.matches(hit: "leaf", target: "button",
            parents: [("a", false), ("b", false), ("c", false), ("d", false), ("button", true)]))
        XCTAssertFalse(PixelAXHitIdentity.matches(hit: "leaf", target: "button",
            parents: [("sibling-button", true), ("button", true)]))
        XCTAssertFalse(PixelAXHitIdentity.matches(hit: "child-button", target: "button", hitActionable: true,
            parents: [("button", true)]))
        XCTAssertFalse(PixelAXHitIdentity.matches(hit: "leaf", target: "button",
            parents: [("a", false), ("b", false), ("c", false), ("d", false), ("e", false), ("button", true)]))
    }

    func testFullyOccludedOrExpiredOverlapSearchKeepsOriginalPointAndAddsNote() {
        let rect = CGRect(x: 10, y: 10, width: 40, height: 40)
        let reference = MarkReference(role: "AXButton", name: "Save", rect: rect, identity: "save") { _ in false }
        let mark = PixelElementMark(id: 1, role: "AXButton", name: "Save", screenRect: rect,
            state: ["visible"], inView: true, reference: reference, identity: "save")
        let center = CGPoint(x: 30, y: 30)
        let occluded = PixelTargetSnapping.resolve(center, in: [mark], deadline: .now + .milliseconds(300))
        XCTAssertEqual(occluded.point, center)
        XCTAssertEqual(occluded.note, "target overlapped")
        XCTAssertTrue(occluded.keepsCoordinate)

        let expired = PixelTargetSnapping.resolve(center, in: [mark], deadline: .now)
        XCTAssertEqual(expired.point, center)
        XCTAssertEqual(expired.note, "target overlapped")
    }

    private func authorityRecord(id: Int = 3, role: String = "AXTextField", identifier: String = "query",
                                 value: String, selection: AgentSelection = .init(start: 1, end: 1))
        -> AgentMacAccessibility.EditableAuthorityRecord {
        .init(id: id, role: role, subrole: "", identifier: identifier, name: "Search",
              value: "string:" + value, selected: false, selection: selection)
    }

    private func element(id: Int, x: Double, y: Double, width: Double, height: Double,
                         inView: Bool = true) -> AgentElement {
        .init(id: id, role: "AXButton", name: "Control", value: nil, state: ["enabled"],
              bbox: .init(x: x, y: y, width: width, height: height), inView: inView)
    }

    private struct FocusedRecipient {
        let pid: pid_t
        let attributes: [String: Any]
    }

    private final class MarkAXNode: PixelAXNode {
        let identity: AnyHashable
        let role: String
        let title: String?
        private(set) var valueReads = 0
        var value: String? { valueReads += 1; return nil }
        let screenRect: CGRect?
        let isEnabled: Bool? = true
        let isHidden: Bool
        let isProtected = false
        let isSecure = false
        let documentURL: String? = nil
        private let childNodes: [any PixelAXNode]
        private(set) var childrenReads = 0

        init(identity: AnyHashable, role: String, rect: CGRect?, hidden: Bool = false,
             children: [any PixelAXNode] = []) {
            self.identity = identity; self.role = role; screenRect = rect
            isHidden = hidden; childNodes = children
            title = identity as? String
        }
        static func root(_ children: [any PixelAXNode]) -> MarkAXNode {
            MarkAXNode(identity: "root", role: "AXWindow", rect: nil, children: children)
        }
        func children() -> [any PixelAXNode] { childrenReads += 1; return childNodes }
        func makeReference(observedName: String, visibleRect: CGRect?) -> (any PixelElementReference)? {
            MarkReference(role: role, name: observedName, rect: screenRect, visibleRect: visibleRect,
                identity: identity, hit: { _ in true })
        }
    }

    private final class MarkReference: PixelElementReference {
        let role: String
        let name: String
        var rect: CGRect?
        private let visibleRect: CGRect?
        let identity: AnyHashable?
        private let hit: (CGPoint) -> Bool?
        init(role: String, name: String, rect: CGRect?, visibleRect: CGRect? = nil, identity: AnyHashable,
             hit: @escaping (CGPoint) -> Bool?) {
            self.role = role; self.name = name; self.rect = rect; self.visibleRect = visibleRect
            self.identity = identity; self.hit = hit
        }
        var isEnabled: Bool? { true }
        func currentScreenRect() -> CGRect? {
            guard let rect else { return nil }
            let current = visibleRect.map { rect.intersection($0) } ?? rect
            return current.isNull || current.isEmpty ? nil : current
        }
        func isSecure() -> Bool { false }
        func acceptsHit(at point: CGPoint, intendedIdentity: AnyHashable,
                        deadline: ContinuousClock.Instant) -> Bool? { hit(point) }
    }

    private final class PostedHostEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [CGEvent] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return storage.count }
        var keyEventCount: Int {
            lock.lock(); defer { lock.unlock() }
            return storage.filter { $0.type == .keyDown || $0.type == .keyUp }.count
        }
        func append(_ event: CGEvent) { lock.lock(); defer { lock.unlock() }; storage.append(event) }
    }

    private func authorizeAndPost(_ recipient: FocusedRecipient?, expectedPID: pid_t, trusted: Bool,
                                  requested: inout [String], events: PostedHostEvents) throws {
        let injector = InputInjector(eventPoster: { events.append($0) }, physicalInputState: { .released })
        try injector.applyHostKeyStroke(usage: 0x19, modifiers: 1 << 3, ifAllowed: { true }) {
            _ = try PixelFocusedRecipient.authorize(expectedPID: expectedPID, isAXTrusted: trusted,
            focused: { recipient }, processID: { $0.pid }, attribute: { element, name in
                requested.append(name)
                return element.attributes[name]
            })
        }
    }
}

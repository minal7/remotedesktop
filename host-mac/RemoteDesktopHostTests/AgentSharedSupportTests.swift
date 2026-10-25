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

    func testMatchedWindowProjectsDetachedFocusedEditorWithoutLeakingSecureFocus() throws {
        let bounds = CGRect(x: 100, y: 100, width: 400, height: 300)
        let listed = MarkAXNode(identity: "listed-control", role: "AXButton",
            rect: CGRect(x: 120, y: 130, width: 90, height: 28))
        let detachedEditor = MarkAXNode(identity: "inline-editor", role: "AXTextField",
            rect: CGRect(x: 150, y: 170, width: 140, height: 28))
        func capture(_ focus: MarkAXNode, children: [MarkAXNode] = [listed], ancestors: [MarkAXNode] = [],
                     owner: AnyHashable? = AnyHashable("selected-window"), focusPID: pid_t? = 42,
                     windowPID: pid_t? = 42, maxNodes: Int = 160) -> PixelElementMarks {
            let selected = MarkAXNode(identity: "selected-window", role: "AXWindow", rect: bounds, children: children)
            let path: [any PixelAXNode] = [focus] + ancestors + [selected]
            let validated = PixelFocusedAXProjection.project(path: path, ownerWindow: owner,
                selectedWindow: selected.identity, focusPID: focusPID, selectedPID: windowPID,
                expectedPID: 42, windowBounds: bounds, deadline: .now + .milliseconds(300))
            let supplemental = validated.visibleRect.map {
                MarkAXNode(identity: focus.identity, role: focus.role, rect: $0)
            }
            return ElementMarks.projectCaptureRoots(focusedWindow: selected, focusedBounds: bounds,
                focusedElement: focus, detachedFocusedElement: supplemental, detachedSecureRects: validated.secureRects,
                menuBar: nil, selectedBounds: bounds, deadline: .now + .milliseconds(300), maxNodes: maxNodes)
        }

        let projected = capture(detachedEditor)

        XCTAssertEqual(projected.marks.compactMap { $0.identity as? String }, ["listed-control", "inline-editor"])
        XCTAssertEqual(projected.focusedID, 2)
        XCTAssertTrue(capture(detachedEditor, maxNodes: 2).marks.contains { $0.identity == AnyHashable("inline-editor") })

        let duplicate = capture(detachedEditor, children: [listed, detachedEditor])
        XCTAssertEqual(duplicate.marks.filter { $0.identity == AnyHashable("inline-editor") }.count, 1)
        XCTAssertEqual(duplicate.focusedID, 2)

        let foreignOwner = capture(detachedEditor, owner: "overlapping-window")
        let missingOwner = capture(detachedEditor, owner: nil)
        let foreignPID = capture(detachedEditor, focusPID: 99)
        let foreignWindowPID = capture(detachedEditor, windowPID: 99)
        let incomplete = PixelFocusedAXProjection.project(path: [detachedEditor],
            ownerWindow: AnyHashable("selected-window"), selectedWindow: AnyHashable("selected-window"), focusPID: 42,
            selectedPID: 42, expectedPID: 42, windowBounds: bounds, deadline: .now + .milliseconds(300))
        let deadlineWindow = MarkAXNode(identity: "deadline-window", role: "AXWindow", rect: bounds)
        let expired = PixelFocusedAXProjection.project(path: [detachedEditor, deadlineWindow],
            ownerWindow: deadlineWindow.identity, selectedWindow: deadlineWindow.identity, focusPID: 42,
            selectedPID: 42, expectedPID: 42, windowBounds: bounds, deadline: .now - .milliseconds(1))
        XCTAssertFalse(foreignOwner.marks.contains { $0.identity == AnyHashable("inline-editor") })
        XCTAssertFalse(missingOwner.marks.contains { $0.identity == AnyHashable("inline-editor") })
        XCTAssertFalse(foreignPID.marks.contains { $0.identity == AnyHashable("inline-editor") })
        XCTAssertFalse(foreignWindowPID.marks.contains { $0.identity == AnyHashable("inline-editor") })
        XCTAssertNil(incomplete.visibleRect)
        XCTAssertNil(expired.visibleRect)

        let narrowerSelected = CGRect(x: 120, y: 120, width: 220, height: 180)
        let outsideSelected = MarkAXNode(identity: "outside-selected-window", role: "AXTextField",
            rect: CGRect(x: 360, y: 170, width: 40, height: 24))
        let selectedNode = MarkAXNode(identity: "narrow-selected-window", role: "AXWindow", rect: narrowerSelected)
        let noSheetOutside = PixelFocusedAXProjection.project(path: [outsideSelected, selectedNode],
            ownerWindow: selectedNode.identity, selectedWindow: selectedNode.identity, focusPID: 42,
            selectedPID: 42, expectedPID: 42, windowBounds: bounds, deadline: .now + .milliseconds(300))
        XCTAssertNil(noSheetOutside.visibleRect, "Ordinary focus remains clipped to the selected-window intersection.")

        let outside = MarkAXNode(identity: "outside-editor", role: "AXTextField",
            rect: CGRect(x: 700, y: 170, width: 140, height: 28))
        let outsideProjection = capture(outside)
        XCTAssertFalse(outsideProjection.marks.contains { $0.identity == AnyHashable("outside-editor") })

        let secure = MarkAXNode(identity: "secure-editor", role: "AXTextField",
            rect: CGRect(x: 150, y: 210, width: 140, height: 28), secure: true)
        let secureProjection = capture(secure)
        XCTAssertFalse(secureProjection.marks.contains { $0.identity == AnyHashable("secure-editor") })
        XCTAssertEqual(secureProjection.secureScreenRects, [CGRect(x: 150, y: 210, width: 140, height: 28)])
        XCTAssertEqual(secure.valueReads, 0)

        let hiddenFocused = MarkAXNode(identity: "hidden-editor", role: "AXTextField",
            rect: CGRect(x: 160, y: 220, width: 120, height: 24))
        let hiddenGroup = MarkAXNode(identity: "hidden-group", role: "AXGroup",
            rect: CGRect(x: 140, y: 200, width: 180, height: 80), hidden: true, children: [hiddenFocused])
        let hiddenProjection = capture(hiddenFocused, ancestors: [hiddenGroup])
        XCTAssertFalse(hiddenProjection.marks.contains { $0.identity == AnyHashable("hidden-editor") })

        let zeroFocused = MarkAXNode(identity: "zero-editor", role: "AXTextField",
            rect: CGRect(x: 160, y: 220, width: 0, height: 24))
        let zeroProjection = capture(zeroFocused)
        XCTAssertFalse(zeroProjection.marks.contains { $0.identity == AnyHashable("zero-editor") })
        let zeroAncestor = MarkAXNode(identity: "zero-ancestor", role: "AXGroup",
            rect: CGRect(x: 140, y: 200, width: 0, height: 80))
        let zeroAncestorProjection = capture(detachedEditor, ancestors: [zeroAncestor])
        XCTAssertTrue(zeroAncestorProjection.marks.contains { $0.identity == AnyHashable("inline-editor") })
        let geometrylessAncestor = MarkAXNode(identity: "geometryless-ancestor", role: "AXGroup", rect: nil)
        XCTAssertTrue(capture(detachedEditor, ancestors: [geometrylessAncestor]).marks
            .contains { $0.identity == AnyHashable("inline-editor") })

        let clippedFocused = MarkAXNode(identity: "clipped-editor", role: "AXTextField",
            rect: CGRect(x: 280, y: 220, width: 80, height: 24))
        let clip = MarkAXNode(identity: "clip", role: "AXScrollArea",
            rect: CGRect(x: 140, y: 200, width: 100, height: 80), children: [clippedFocused])
        let clippedProjection = capture(clippedFocused, ancestors: [clip])
        XCTAssertFalse(clippedProjection.marks.contains { $0.identity == AnyHashable("clipped-editor") })
        let unknownClip = MarkAXNode(identity: "unknown-clip", role: "AXScrollArea", rect: nil)
        XCTAssertFalse(capture(detachedEditor, ancestors: [unknownClip]).marks
            .contains { $0.identity == AnyHashable("inline-editor") })
        let partialFocused = MarkAXNode(identity: "partial-editor", role: "AXTextField",
            rect: CGRect(x: 190, y: 220, width: 80, height: 24))
        let partialClip = MarkAXNode(identity: "partial-clip", role: "AXScrollArea",
            rect: CGRect(x: 200, y: 200, width: 60, height: 80))
        let partialProjection = capture(partialFocused, children: [], ancestors: [partialClip])
        XCTAssertEqual(partialProjection.marks.first?.identity, AnyHashable("partial-editor"))
        XCTAssertEqual(partialProjection.marks.first?.screenRect, CGRect(x: 200, y: 220, width: 60, height: 24))

        let scrollbarFocused = MarkAXNode(identity: "scrollbar-descendant-editor", role: "AXTextField",
            rect: CGRect(x: 180, y: 220, width: 100, height: 24))
        let scrollbar = MarkAXNode(identity: "scrollbar", role: "AXScrollBar",
            rect: CGRect(x: 280, y: 200, width: 12, height: 100), children: [scrollbarFocused])
        let scrollbarProjection = capture(scrollbarFocused, ancestors: [scrollbar])
        XCTAssertFalse(scrollbarProjection.marks.contains { $0.identity == AnyHashable("scrollbar-descendant-editor") })

        let protectedGroup = MarkAXNode(identity: "protected-group", role: "AXGroup",
            rect: CGRect(x: 140, y: 200, width: 180, height: 80), protected: true, children: [detachedEditor])
        let protectedProjection = capture(detachedEditor, ancestors: [protectedGroup])
        XCTAssertFalse(protectedProjection.marks.contains { $0.identity == AnyHashable("inline-editor") })
        XCTAssertEqual(protectedProjection.secureScreenRects, [protectedGroup.screenRect!])
        let protectedWithoutFrame = MarkAXNode(identity: "protected-without-frame", role: "AXGroup",
            rect: nil, protected: true)
        let protectedFallback = capture(detachedEditor, ancestors: [protectedWithoutFrame])
        XCTAssertFalse(protectedFallback.marks.contains { $0.identity == AnyHashable("inline-editor") })
        XCTAssertEqual(protectedFallback.secureScreenRects, [bounds])
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
        let isProtected: Bool
        let isSecure: Bool
        let documentURL: String? = nil
        private let childNodes: [any PixelAXNode]
        private(set) var childrenReads = 0

        init(identity: AnyHashable, role: String, rect: CGRect?, hidden: Bool = false,
             secure: Bool = false, protected: Bool = false, children: [any PixelAXNode] = []) {
            self.identity = identity; self.role = role; screenRect = rect
            isHidden = hidden; isSecure = secure; isProtected = protected; childNodes = children
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

    func testTypingBindingRejectsMissingOrForeignWindow() {
        let binding = PixelTypingFocusBinding(focus: "field-a", window: "window-a", pid: 42)
        let missingWindow = PixelTypingFocusBinding.Evidence(focus: "field-a", ownerWindow: nil,
            selectedWindow: nil, focusPID: 42, windowPID: 42)
        let foreignWindow = PixelTypingFocusBinding.Evidence(focus: "field-a", ownerWindow: "window-b",
            selectedWindow: "window-b", focusPID: 42, windowPID: 42)
        XCTAssertFalse(PixelTypingFocusBinding.allows(missingWindow, binding: binding))
        XCTAssertFalse(PixelTypingFocusBinding.allows(foreignWindow, binding: binding))
    }

    func testTypingBindingAllowsVerifiedDescendant() {
        let binding = PixelTypingFocusBinding(focus: "field-a", window: "window-a", pid: 42)
        let descendant = PixelTypingFocusBinding.Evidence(focus: "field-a", ownerWindow: "window-a",
            selectedWindow: "window-a", focusPID: 42, windowPID: 42)
        XCTAssertTrue(PixelTypingFocusBinding.allows(descendant, binding: binding))
    }

    func testTypingBindingRechecksRecipientBeforePaste() throws {
        let binding = PixelTypingFocusBinding(focus: "field-a", window: "window-a", pid: 42)
        let valid = PixelTypingFocusBinding.Evidence(focus: "field-a", ownerWindow: "window-a",
            selectedWindow: "window-a", focusPID: 42, windowPID: 42)
        var current: PixelTypingFocusBinding.Evidence? = valid
        let events = PostedHostEvents()
        let injector = InputInjector(eventPoster: { events.append($0) }, physicalInputState: { .released })
        func post(_ usage: Int) throws {
            try injector.applyHostKeyStroke(usage: usage, modifiers: 1 << 3, ifAllowed: { true }) {
                try PixelTypingFocusBinding.require(current, binding: binding)
            }
        }
        try post(0x04) // Cmd+A was permitted for the observed recipient
        let beforePaste = events.keyEventCount
        current = .init(focus: "field-b", ownerWindow: "window-a", selectedWindow: "window-a",
            focusPID: 42, windowPID: 42)
        XCTAssertThrowsError(try post(0x19)) // same window, different field: Cmd+V is refused
        XCTAssertEqual(events.keyEventCount, beforePaste)
        current = .init(focus: "field-a", ownerWindow: "window-b", selectedWindow: "window-b",
            focusPID: 42, windowPID: 42)
        XCTAssertThrowsError(try post(0x19)) // a focus/window switch also refuses Cmd+V
        XCTAssertEqual(events.keyEventCount, beforePaste)
    }

    func testAttachedSheetControlsRemainActionableOutsideOwnerWindowBounds() {
        let ownerBounds = CGRect(x: 214, y: 112, width: 586, height: 488)
        let sheetBounds = CGRect(x: 67, y: 180, width: 880, height: 448)
        let fieldBounds = CGRect(x: 820, y: 300, width: 110, height: 28)
        let field = MarkAXNode(identity: "save-name-field", role: "AXTextField", rect: fieldBounds)
        let sheet = MarkAXNode(identity: "attached-save-sheet", role: "AXSheet", rect: sheetBounds,
            children: [field])
        let owner = MarkAXNode(identity: "selected-owner-window", role: "AXWindow", rect: ownerBounds,
            children: [sheet])

        let result = ElementMarks.projectCaptureRoots(focusedWindow: owner, focusedBounds: ownerBounds,
            focusedElement: field, menuBar: nil, selectedBounds: ownerBounds,
            deadline: .now + .milliseconds(300), attachedSheetIdentity: sheet.identity)

        let mark = result.marks.first { $0.identity == AnyHashable("save-name-field") }
        XCTAssertNotNil(mark, "A field in a positively attached sheet should not be clipped to its owner window.")
        XCTAssertEqual(mark?.screenRect, fieldBounds)
        XCTAssertTrue(result.overlayBounds.contains(sheetBounds))
        XCTAssertTrue(PixelWindowActionBoundary.allows(CGPoint(x: fieldBounds.midX, y: fieldBounds.midY),
            windowBounds: ownerBounds, menuBarBounds: [], sameAppDialogBounds: result.overlayBounds))
        let unbound = ElementMarks.projectCaptureRoots(focusedWindow: owner, focusedBounds: ownerBounds,
            focusedElement: field, menuBar: nil, selectedBounds: ownerBounds, deadline: .now + .milliseconds(300))
        XCTAssertFalse(unbound.marks.contains { $0.identity == AnyHashable("save-name-field") })
        XCTAssertFalse(unbound.overlayBounds.contains(sheetBounds))
    }

    func testAttachedSheetTypingRequiresExactBoundedOwnerPath() {
        let window: AnyHashable = "owner-window"
        let sheet: AnyHashable = "save-sheet"
        let path: [(identity: AnyHashable, role: String, pid: pid_t)] = [
            ("filename", "AXTextField", 42), ("group", "AXGroup", 42),
            (sheet, "AXSheet", 42), (window, "AXWindow", 42)
        ]
        XCTAssertEqual(PixelAXOwnerPath.attachedSheet(path, selectedWindow: window,
            attributeOwner: nil, expectedPID: 42)?.attachedSheet, sheet)
        XCTAssertEqual(PixelAXOwnerPath.attachedSheet(path, selectedWindow: window,
            attributeOwner: sheet, expectedPID: 42)?.attachedSheet, sheet)
        XCTAssertNil(PixelAXOwnerPath.attachedSheet(path, selectedWindow: "other-window",
            attributeOwner: nil, expectedPID: 42))
        XCTAssertNil(PixelAXOwnerPath.attachedSheet(path, selectedWindow: window,
            attributeOwner: "other-window", expectedPID: 42))
        XCTAssertNil(PixelAXOwnerPath.attachedSheet(Array(path.dropLast()), selectedWindow: window,
            attributeOwner: nil, expectedPID: 42))
        let noSheetPath: [(identity: AnyHashable, role: String, pid: pid_t)] = [
            ("field", "AXTextField", 42), (window, "AXWindow", 42)
        ]
        XCTAssertNil(PixelAXOwnerPath.attachedSheet(noSheetPath, selectedWindow: window,
            attributeOwner: nil, expectedPID: 42))
        var foreignPID = path; foreignPID[1].pid = 99
        XCTAssertNil(PixelAXOwnerPath.attachedSheet(foreignPID, selectedWindow: window,
            attributeOwner: nil, expectedPID: 42))
        var cyclic = path; cyclic[1].identity = "filename"
        XCTAssertNil(PixelAXOwnerPath.attachedSheet(cyclic, selectedWindow: window,
            attributeOwner: nil, expectedPID: 42))

        let binding = PixelTypingFocusBinding(focus: "filename", window: window, pid: 42, attachedSheet: sheet)
        let replacementSheet = PixelTypingFocusBinding.Evidence(focus: "filename", ownerWindow: window,
            selectedWindow: window, focusPID: 42, windowPID: 42, attachedSheet: "replacement-sheet")
        XCTAssertFalse(PixelTypingFocusBinding.allows(replacementSheet, binding: binding))
        let changedFocus = PixelTypingFocusBinding.Evidence(focus: "other-field", ownerWindow: window,
            selectedWindow: window, focusPID: 42, windowPID: 42, attachedSheet: sheet)
        XCTAssertFalse(PixelTypingFocusBinding.allows(changedFocus, binding: binding))
    }

    func testAttachedSheetFocusProjectionRetainsNestedClipAndSecureMasking() {
        let ownerBounds = CGRect(x: 214, y: 112, width: 586, height: 488)
        let sheetBounds = CGRect(x: 67, y: 180, width: 880, height: 448)
        let clipBounds = CGRect(x: 420, y: 220, width: 180, height: 120)
        let fieldBounds = CGRect(x: 430, y: 230, width: 200, height: 32)
        let field = MarkAXNode(identity: "sheet-field", role: "AXTextField", rect: fieldBounds)
        let clip = MarkAXNode(identity: "sheet-clip", role: "AXScrollArea", rect: clipBounds)
        let sheet = MarkAXNode(identity: "bound-sheet", role: "AXSheet", rect: sheetBounds)
        let owner = MarkAXNode(identity: "bound-owner", role: "AXWindow", rect: ownerBounds)
        let path: [any PixelAXNode] = [field, clip, sheet, owner]
        let projected = PixelFocusedAXProjection.project(path: path, ownerWindow: owner.identity,
            selectedWindow: owner.identity, focusPID: 42, selectedPID: 42, expectedPID: 42,
            windowBounds: ownerBounds, deadline: .now + .milliseconds(300))
        XCTAssertEqual(projected.visibleRect, CGRect(x: 430, y: 230, width: 170, height: 32))

        let secure = MarkAXNode(identity: "protected-parent", role: "AXGroup", rect: nil, protected: true)
        let protectedPath: [any PixelAXNode] = [field, secure, sheet, owner]
        let protected = PixelFocusedAXProjection.project(path: protectedPath, ownerWindow: owner.identity,
            selectedWindow: owner.identity, focusPID: 42, selectedPID: 42, expectedPID: 42,
            windowBounds: ownerBounds, deadline: .now + .milliseconds(300))
        XCTAssertNil(protected.visibleRect)
        XCTAssertEqual(protected.secureRects, [ownerBounds.union(sheetBounds)])

        let protectedOwner = MarkAXNode(identity: "secure-window", role: "AXWindow", rect: ownerBounds, protected: true)
        let protectedOwnerPath: [any PixelAXNode] = [field, sheet, protectedOwner]
        let ownerProjection = PixelFocusedAXProjection.project(path: protectedOwnerPath,
            ownerWindow: protectedOwner.identity, selectedWindow: protectedOwner.identity,
            focusPID: 42, selectedPID: 42, expectedPID: 42, windowBounds: ownerBounds,
            deadline: .now + .milliseconds(300))
        XCTAssertNil(ownerProjection.visibleRect)
        XCTAssertEqual(ownerProjection.secureRects, [ownerBounds.union(sheetBounds)])
        XCTAssertFalse(PixelTypingFocusBinding.allowsPath(attachedSheet: sheet.identity,
            hasProtectedOrSecureAncestor: true))
        XCTAssertTrue(PixelTypingFocusBinding.allowsPath(attachedSheet: sheet.identity,
            hasProtectedOrSecureAncestor: false))
        XCTAssertTrue(PixelTypingFocusBinding.allowsPath(attachedSheet: nil,
            hasProtectedOrSecureAncestor: true))
    }

    func testProtectedOwnerMasksAttachedSheetAndSuppressesItsMarks() {
        let ownerBounds = CGRect(x: 214, y: 112, width: 586, height: 488)
        let sheetBounds = CGRect(x: 67, y: 180, width: 880, height: 448)
        let canary = MarkAXNode(identity: "protected-sheet-canary", role: "AXButton",
            rect: CGRect(x: 820, y: 300, width: 110, height: 28))
        let sheet = MarkAXNode(identity: "protected-owner-sheet", role: "AXSheet", rect: sheetBounds,
            children: [canary])
        let owner = MarkAXNode(identity: "protected-owner", role: "AXWindow", rect: ownerBounds,
            protected: true, children: [sheet])

        let result = ElementMarks.projectCaptureRoots(focusedWindow: owner, focusedBounds: ownerBounds,
            focusedElement: canary, attachedSheetElement: sheet, menuBar: nil, selectedBounds: ownerBounds,
            deadline: .now + .milliseconds(300), attachedSheetIdentity: sheet.identity)

        XCTAssertFalse(result.marks.contains { $0.identity == canary.identity || $0.name == "protected-sheet-canary" })
        XCTAssertFalse(result.axState?.contains { $0.title == "protected-sheet-canary" } ?? false)
        XCTAssertTrue(result.secureScreenRects.contains(ownerBounds.union(sheetBounds)))
    }

    func testProtectedIntermediateSheetAncestorSuppressesWholeSheetProjection() {
        let ownerBounds = CGRect(x: 214, y: 112, width: 586, height: 488)
        let sheetBounds = CGRect(x: 67, y: 180, width: 880, height: 448)
        let focused = MarkAXNode(identity: "protected-descendant", role: "AXTextField",
            rect: CGRect(x: 120, y: 260, width: 120, height: 28))
        let protectedGroup = MarkAXNode(identity: "protected-group", role: "AXGroup",
            rect: CGRect(x: 100, y: 220, width: 180, height: 120), protected: true, children: [focused])
        let siblingCanary = MarkAXNode(identity: "sheet-sibling-canary", role: "AXButton",
            rect: CGRect(x: 820, y: 300, width: 110, height: 28))
        let sheet = MarkAXNode(identity: "intermediate-protected-sheet", role: "AXSheet",
            rect: sheetBounds, children: [protectedGroup, siblingCanary])
        let owner = MarkAXNode(identity: "ordinary-owner", role: "AXWindow", rect: ownerBounds,
            children: [sheet])

        let result = ElementMarks.projectCaptureRoots(focusedWindow: owner, focusedBounds: ownerBounds,
            focusedElement: focused, attachedSheetElement: sheet, menuBar: nil, selectedBounds: ownerBounds,
            deadline: .now + .milliseconds(300), attachedSheetIdentity: sheet.identity,
            attachedPathProtected: true)

        XCTAssertFalse(result.marks.contains { $0.identity == focused.identity || $0.identity == siblingCanary.identity })
        XCTAssertFalse(result.axState?.contains { $0.title == "sheet-sibling-canary" } ?? false)
        XCTAssertTrue(result.secureScreenRects.contains(ownerBounds.union(sheetBounds)))
        XCTAssertFalse(result.requiresProtectedRegionHandoff)
    }

    func testProtectedAttachedSheetWithUnknownBoundsRequiresHandoff() {
        let ownerBounds = CGRect(x: 214, y: 112, width: 586, height: 488)
        let canary = MarkAXNode(identity: "unknown-protected-sheet-canary", role: "AXButton",
            rect: CGRect(x: 820, y: 300, width: 110, height: 28))

        let unknownBounds: [CGRect?] = [nil, CGRect.null]
        for sheetBounds in unknownBounds {
            let sheet = MarkAXNode(identity: "unknown-protected-sheet", role: "AXSheet",
                rect: sheetBounds, children: [canary])
            let owner = MarkAXNode(identity: "known-owner", role: "AXWindow", rect: ownerBounds,
                children: [sheet])
            let result = ElementMarks.projectCaptureRoots(focusedWindow: owner, focusedBounds: ownerBounds,
                focusedElement: canary, attachedSheetElement: sheet, menuBar: nil, selectedBounds: ownerBounds,
                deadline: .now + .milliseconds(300), attachedSheetIdentity: sheet.identity,
                attachedPathProtected: true)

            XCTAssertTrue(result.requiresProtectedRegionHandoff)
            XCTAssertTrue(result.secureScreenRects.contains(ownerBounds))
            XCTAssertFalse(result.marks.contains { $0.identity == canary.identity })
        }

        let sheet = MarkAXNode(identity: "expired-protected-sheet", role: "AXSheet",
            rect: nil, children: [canary])
        let owner = MarkAXNode(identity: "expired-owner", role: "AXWindow", rect: ownerBounds,
            children: [sheet])
        let expired = ElementMarks.projectCaptureRoots(focusedWindow: owner, focusedBounds: ownerBounds,
            focusedElement: canary, attachedSheetElement: sheet, menuBar: nil, selectedBounds: ownerBounds,
            deadline: .now - .milliseconds(1), attachedSheetIdentity: sheet.identity,
            attachedPathProtected: true)
        XCTAssertTrue(expired.requiresProtectedRegionHandoff)

        let ordinaryExpired = ElementMarks.projectCaptureRoots(focusedWindow: owner, focusedBounds: ownerBounds,
            focusedElement: canary, menuBar: nil, selectedBounds: ownerBounds,
            deadline: .now - .milliseconds(1))
        XCTAssertFalse(ordinaryExpired.requiresProtectedRegionHandoff)
    }
}

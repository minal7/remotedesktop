import AppKit
import CoreGraphics
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class PixelEnvironmentTests: XCTestCase {
    func testPointMapsFromScreenshotPixelsAcrossRetinaScale() throws {
        let point = try XCTUnwrap(PixelGeometry.point(CGPoint(x: 640, y: 360),
            imageSize: CGSize(width: 1280, height: 720),
            screenBounds: CGRect(x: 100, y: 50, width: 640, height: 360)))
        XCTAssertEqual(point.x, 420, accuracy: 0.001)
        XCTAssertEqual(point.y, 230, accuracy: 0.001)
    }

    func testPointRejectsNonFiniteAndOutOfBoundsCoordinates() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(PixelGeometry.point(CGPoint(x: CGFloat.infinity, y: 2), imageSize: CGSize(width: 100, height: 100), screenBounds: bounds))
        XCTAssertNil(PixelGeometry.point(CGPoint(x: 100, y: 2), imageSize: CGSize(width: 100, height: 100), screenBounds: bounds))
    }

    func testFinitePointMappingDoesNotAddASecondImageBoundsGuard() throws {
        let mapped = try XCTUnwrap(PixelEnvironment.mapPoint(CGPoint(x: 120, y: -10),
            imageSize: CGSize(width: 100, height: 100),
            screenBounds: CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertEqual(mapped.x, 120, accuracy: 0.001)
        XCTAssertEqual(mapped.y, -10, accuracy: 0.001)
    }

    func testContentCropAndResizePreserveScreenMapping() throws {
        let source = try XCTUnwrap(CGImage(width: 800, height: 600, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 3200, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(repeating: 0, count: 3200 * 600) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let cropBounds = CGRect(x: 20, y: 10, width: 400, height: 300)
        let cropped = try XCTUnwrap(PixelGeometry.crop(source, screenRect: cropBounds,
            captureBounds: CGRect(x: 0, y: 0, width: 800, height: 600)))
        let resized = try XCTUnwrap(PixelGeometry.resize(cropped, width: 1280))
        XCTAssertEqual(resized.width, 1280)
        let mapped = try XCTUnwrap(PixelGeometry.point(CGPoint(x: 640, y: 480),
            imageSize: CGSize(width: resized.width, height: resized.height), screenBounds: cropBounds))
        XCTAssertEqual(mapped.x, 220, accuracy: 0.01)
        XCTAssertEqual(mapped.y, 160, accuracy: 0.01)
    }

    func testSafetyBoundaryExcludesCredentialsAndFinanceAppsButAllowsSettingsReadOnly() {
        XCTAssertTrue(AgentSafetyBoundary.blocksAutomation(bundleID: "com.apple.keychainaccess", appName: "Keychain Access"))
        XCTAssertTrue(AgentSafetyBoundary.blocksAutomation(bundleID: "example.bank", appName: "Example Online Banking"))
        XCTAssertFalse(AgentSafetyBoundary.blocksAutomation(bundleID: "com.apple.systempreferences", appName: "System Settings"))
        XCTAssertTrue(AgentSafetyBoundary.readOnly(bundleID: "com.apple.systempreferences", appName: "System Settings"))
    }

    func testClipboardLeaseRestoresTaskLocalBoardAfterPasteAndOnExternalChangePreservesNewOwner() throws {
        let board = NSPasteboard(name: .init("PixelEnvironmentTests.\(UUID().uuidString)"))
        board.setString("original", forType: .string)
        let lease = PixelClipboardLease(board: board, text: "agent text")
        XCTAssertEqual(board.string(forType: .string), "agent text")
        lease.restore()
        XCTAssertEqual(board.string(forType: .string), "original")

        let second = PixelClipboardLease(board: board, text: "staged")
        board.clearContents()
        board.setString("external change", forType: .string)
        second.restore()
        XCTAssertEqual(board.string(forType: .string), "external change")
    }

    func testElementRebindingUsesCurrentMovedBoundsAndRejectsGoneOrChangedSemantics() throws {
        let expected = AgentElement(id: 4, role: "AXButton", name: "Upload", value: nil,
            state: ["visible"], bbox: .init(x: 10, y: 10, width: 20, height: 20), inView: true)
        let moved = PixelElementMark(id: 4, role: "AXButton", name: "Upload",
            screenRect: CGRect(x: 300, y: 400, width: 50, height: 24), state: ["visible"], inView: true)
        XCTAssertEqual(PixelTargetRebinding.find(expected, in: [moved])?.screenRect, moved.screenRect)
        let rebound = PixelElementMark(id: 9, role: "AXButton", name: "Upload",
            screenRect: moved.screenRect, state: ["visible"], inView: true)
        XCTAssertEqual(PixelTargetRebinding.find(expected, in: [rebound])?.id, 9)
        let frameElement = AgentElement(id: 9, role: "AXButton", name: "Upload", value: nil,
            state: ["visible"], bbox: .init(x: 300, y: 400, width: 50, height: 24), inView: true)
        let reboundFrameElement = try PixelActionRebinding.rebind(expected, in: [frameElement])
        XCTAssertEqual(reboundFrameElement.id, expected.id)
        XCTAssertEqual(reboundFrameElement.bbox, frameElement.bbox)
        let point = try PixelScreenTargetResolver.point(for: expected, in: [rebound])
        XCTAssertEqual(point.x, moved.screenRect.midX)
        XCTAssertEqual(point.y, moved.screenRect.midY)

        XCTAssertThrowsError(try PixelActionRebinding.rebind(expected, in: [])) { error in
            XCTAssertEqual(error as? AgentEnvironmentError, .targetGone)
        }
        XCTAssertThrowsError(try PixelScreenTargetResolver.point(for: expected, in: [])) { error in
            XCTAssertEqual(error as? AgentEnvironmentError, .targetGone)
        }
        let changed = PixelElementMark(id: 4, role: "AXTextField", name: "Upload",
            screenRect: moved.screenRect, state: ["visible"], inView: true)
        XCTAssertNil(PixelTargetRebinding.find(expected, in: [changed]))
        XCTAssertThrowsError(try PixelScreenTargetResolver.point(for: expected, in: [changed])) { error in
            XCTAssertEqual(error as? AgentEnvironmentError, .targetGone)
        }
        let secure = PixelElementMark(id: 4, role: "AXButton", name: "Upload",
            screenRect: moved.screenRect, state: ["visible", "secure"], inView: true)
        XCTAssertThrowsError(try PixelScreenTargetResolver.point(for: expected, in: [secure])) { error in
            XCTAssertEqual(error as? AgentEnvironmentError, .credentialHandoff)
        }
    }

    func testFreshRebindingRejectsAmbiguousSameLabelMarksAfterTheirOrderChanges() {
        let expected = AgentElement(id: 1, role: "AXButton", name: "Submit", value: nil,
            state: ["visible"], bbox: .init(x: 10, y: 10, width: 30, height: 20), inView: true)
        // Both same-label controls moved, so a fresh sorted list can reuse IDs for different
        // controls. Semantic rebinding must reject the ambiguous pair instead of trusting an ID.
        let lowerNowID1 = PixelElementMark(id: 1, role: "AXButton", name: "Submit",
            screenRect: CGRect(x: 20, y: 300, width: 30, height: 20), state: ["visible"], inView: true)
        let upperNowID2 = PixelElementMark(id: 2, role: "AXButton", name: "Submit",
            screenRect: CGRect(x: 20, y: 100, width: 30, height: 20), state: ["visible"], inView: true)

        XCTAssertNil(PixelTargetRebinding.find(expected, in: [upperNowID2, lowerNowID1]))
    }

    func testPointSnapUsesUniqueInteractiveCentreWithinTwelveLogicalPoints() {
        let button = mark(id: 1, role: "AXButton", name: "Save", rect: CGRect(x: 100, y: 100, width: 20, height: 20))
        let atTwelve = PixelTargetSnapping.resolve(CGPoint(x: 122, y: 110), in: [button])
        XCTAssertEqual(atTwelve.mark?.id, button.id)
        XCTAssertEqual(atTwelve.point, CGPoint(x: 110, y: 110))

        let pastLimit = PixelTargetSnapping.resolve(CGPoint(x: 122.01, y: 110), in: [button])
        XCTAssertNil(pastLimit.mark)
        XCTAssertEqual(pastLimit.point, CGPoint(x: 122.01, y: 110))

        let rewritten = PixelTargetSnapping.resolveClick(.click(target: .point(x: 122, y: 110), button: .right, count: 2),
            snappedMark: atTwelve.mark)
        XCTAssertEqual(rewritten.action, .click(target: .element(id: button.id), button: .right, count: 2))
        XCTAssertEqual(rewritten.note, "snapped to mark 1 \"Save\"")
    }

    func testPointSnapRejectsTiesAndCoordinatesInsidePassiveMarks() {
        let left = mark(id: 1, role: "AXButton", name: "Same", rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        let right = mark(id: 2, role: "AXButton", name: "Same", rect: CGRect(x: 20, y: 0, width: 10, height: 10))
        let tied = PixelTargetSnapping.resolve(CGPoint(x: 15, y: 5), in: [left, right])
        XCTAssertNil(tied.mark)
        XCTAssertEqual(tied.point, CGPoint(x: 15, y: 5))

        let passive = mark(id: 3, role: "AXStaticText", name: "Label", rect: CGRect(x: 98, y: 98, width: 8, height: 8))
        let nearby = mark(id: 4, role: "AXButton", name: "Save", rect: CGRect(x: 101, y: 95, width: 10, height: 10))
        let insidePassive = PixelTargetSnapping.resolve(CGPoint(x: 100, y: 100), in: [passive, nearby])
        XCTAssertNil(insidePassive.mark)
        XCTAssertEqual(insidePassive.point, CGPoint(x: 100, y: 100))
    }

    func testPointSnapDistanceUsesLogicalScreenCoordinatesWithNegativeOrigin() throws {
        let screenBounds = CGRect(x: -300, y: 40, width: 100, height: 100)
        let screenPoint = try XCTUnwrap(PixelGeometry.point(CGPoint(x: 38, y: 110),
            imageSize: CGSize(width: 200, height: 200), screenBounds: screenBounds))
        let button = mark(id: 1, role: "AXButton", name: "Save",
            rect: CGRect(x: -280, y: 85, width: 20, height: 20))

        let result = PixelTargetSnapping.resolve(screenPoint, in: [button])
        XCTAssertEqual(screenPoint, CGPoint(x: -281, y: 95))
        XCTAssertEqual(result.mark?.id, button.id)
        XCTAssertEqual(result.point, CGPoint(x: -270, y: 95))
    }

    func testResolvedAXReferenceKeepsItsCurrentCentreAcrossReusedSortedIDs() throws {
        let expected = AgentElement(id: 1, role: "AXButton", name: "Submit", value: nil,
            state: ["visible"], bbox: .init(x: 10, y: 10, width: 20, height: 20), inView: true)
        let originalRect = CGRect(x: 10, y: 10, width: 20, height: 20)
        let otherRect = CGRect(x: 10, y: 300, width: 20, height: 20)
        let original = TestPixelElementReference(role: "AXButton", name: "Submit", rect: originalRect)
        let other = TestPixelElementReference(role: "AXButton", name: "Submit", rect: otherRect)
        let observedMarks = [mark(id: 1, role: "AXButton", name: "Submit", rect: originalRect, reference: original),
                             mark(id: 2, role: "AXButton", name: "Submit", rect: otherRect, reference: other)]
        let binding = try PixelElementReferenceResolver.observed(expected, in: observedMarks)

        // A later sort assigned ID 1 to the other same-label control. The retained handle
        // follows the original AX object to its moved centre, independent of that ID reuse.
        let movedOriginalRect = CGRect(x: 200, y: 400, width: 40, height: 24)
        original.rect = movedOriginalRect
        let reorderedFreshMarks = [mark(id: 1, role: "AXButton", name: "Submit", rect: otherRect, reference: other),
                                   mark(id: 2, role: "AXButton", name: "Submit", rect: movedOriginalRect, reference: original)]
        XCTAssertNil(PixelTargetRebinding.find(expected, in: reorderedFreshMarks))
        XCTAssertEqual(try PixelElementReferenceResolver.currentCentre(expected, reference: binding,
            windowBounds: CGRect(x: 0, y: 0, width: 800, height: 800)), CGPoint(x: 220, y: 412))
    }

    func testFreshReferenceRebindRequiresExactlyOneRoleAndNameMatch() throws {
        let expected = AgentElement(id: 1, role: "AXButton", name: "Submit", value: nil,
            state: ["visible"], bbox: .init(x: 0, y: 0, width: 20, height: 20), inView: true)
        let freshRect = CGRect(x: 50, y: 60, width: 20, height: 20)
        let fresh = TestPixelElementReference(role: "AXButton", name: "Submit", rect: freshRect)
        let one = mark(id: 9, role: "AXButton", name: "Submit", rect: freshRect, reference: fresh)
        XCTAssertTrue(try PixelElementReferenceResolver.rebound(expected, in: [one]) === fresh)

        let duplicate = mark(id: 10, role: "AXButton", name: "Submit", rect: CGRect(x: 200, y: 200, width: 20, height: 20),
            reference: TestPixelElementReference(role: "AXButton", name: "Submit", rect: CGRect(x: 200, y: 200, width: 20, height: 20)))
        XCTAssertThrowsError(try PixelElementReferenceResolver.rebound(expected, in: [one, duplicate])) { error in
            XCTAssertEqual(error as? AgentEnvironmentError, .targetGone)
        }
    }

    func testInvalidSecureOrDisabledReferenceCannotResolveToAnotherControl() throws {
        let expected = AgentElement(id: 1, role: "AXButton", name: "Submit", value: nil,
            state: ["visible"], bbox: .init(x: 0, y: 0, width: 20, height: 20), inView: true)
        let invalid = TestPixelElementReference(role: "AXButton", name: "Submit", rect: nil)
        XCTAssertThrowsError(try PixelElementReferenceResolver.currentCentre(expected, reference: invalid,
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500))) { error in
            XCTAssertEqual(error as? AgentEnvironmentError, .targetGone)
        }

        let secure = TestPixelElementReference(role: "AXButton", name: "Submit",
            rect: CGRect(x: 10, y: 10, width: 20, height: 20), secure: true)
        XCTAssertThrowsError(try PixelElementReferenceResolver.currentCentre(expected, reference: secure,
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500))) { error in
            XCTAssertEqual(error as? AgentEnvironmentError, .credentialHandoff)
        }

        let disabled = TestPixelElementReference(role: "AXButton", name: "Submit",
            rect: CGRect(x: 10, y: 10, width: 20, height: 20), enabled: false)
        XCTAssertThrowsError(try PixelElementReferenceResolver.currentCentre(expected, reference: disabled,
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500))) { error in
            XCTAssertEqual(error as? AgentEnvironmentError, .disabledTarget)
        }
    }

    func testUnlabeledElementClickReadsOCRAtResolvedCentreOncePerFrame() {
        let before = AgentElement(id: 7, role: "AXButton", name: "", value: nil,
            state: ["visible"], bbox: .init(x: 18, y: 38, width: 20, height: 20), inView: true)
        var calls: [CGPoint] = []
        let firstLabel = PixelTargetContextLabel.resolve(.click(target: .element(id: 7), button: nil, count: nil),
            targets: [before]) { x, y in calls.append(CGPoint(x: x, y: y)); return "Submit" }
        XCTAssertEqual(firstLabel, "Submit")
        XCTAssertEqual(calls, [CGPoint(x: 28, y: 48)])

        let after = AgentElement(id: 7, role: "AXButton", name: "", value: nil,
            state: ["visible"], bbox: .init(x: 118, y: 138, width: 20, height: 20), inView: true)
        let freshLabel = PixelTargetContextLabel.rebound(.click(target: .element(id: 7), button: nil, count: nil),
            targets: [after], previous: firstLabel) { x, y in calls.append(CGPoint(x: x, y: y)); return "Continue" }
        XCTAssertEqual(freshLabel, "Continue")
        XCTAssertEqual(calls, [CGPoint(x: 28, y: 48), CGPoint(x: 128, y: 148)])

        let unavailableFreshLabel = PixelTargetContextLabel.rebound(.click(target: .element(id: 7), button: nil, count: nil),
            targets: [after], previous: firstLabel) { _, _ in nil }
        XCTAssertNil(unavailableFreshLabel)
    }

    private func mark(id: Int, role: String, name: String, rect: CGRect,
                      reference: (any PixelElementReference)? = nil) -> PixelElementMark {
        PixelElementMark(id: id, role: role, name: name, screenRect: rect, state: ["visible"], inView: true, reference: reference)
    }

    func testFailedOCRProducesNoTargetLabel() {
        XCTAssertNil(SystemBarriers.targetLabel(screenshot: "not-base64", x: 12, y: 20))
    }
}

@MainActor
private final class TestPixelElementReference: PixelElementReference {
    let role: String
    let name: String
    var rect: CGRect?
    var secure: Bool
    var enabled: Bool?

    init(role: String, name: String, rect: CGRect?, secure: Bool = false, enabled: Bool? = true) {
        self.role = role; self.name = name; self.rect = rect; self.secure = secure; self.enabled = enabled
    }

    var isEnabled: Bool? { enabled }
    func currentScreenRect() -> CGRect? { rect }
    func isSecure() -> Bool { secure }
}

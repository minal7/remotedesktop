import AppKit
import CoreGraphics
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class PixelEnvironmentTests: XCTestCase {
    func testSystemVoiceOverlayClassificationRequiresOwnedLayerZeroWindowAndCompleteSingleButtonShape() {
        func evidence(role: String = "AXWindow", subrole: String? = "AXDialog", title: String? = nil,
                      document: String? = nil, tree: PixelWindowTreeShape = .singleButtonOnly,
                      appPID: Int32 = 42, ownerPID: Int32 = 42, windowID: UInt32 = 7, layer: Int = 0) -> PixelWindowEvidence {
            .init(appPID: appPID, ownerPID: ownerPID, windowID: windowID, layer: layer,
                role: role, subrole: subrole, title: title, document: document, tree: tree)
        }
        XCTAssertEqual(ElementMarks.classifyWindow(evidence()), .systemOverlay)
        XCTAssertEqual(ElementMarks.classifyWindow(evidence(title: "status")), .systemOverlay)
        XCTAssertEqual(ElementMarks.classifyWindow(evidence(title: "Preferences", tree: .other)), .window)
        XCTAssertEqual(ElementMarks.classifyWindow(evidence(document: "file:///tmp/document")), .window)
        XCTAssertEqual(ElementMarks.classifyWindow(evidence(role: "AXDialog")), .unknown)
        XCTAssertEqual(ElementMarks.classifyWindow(evidence(role: "AXDialog", subrole: "AXSystemDialog",
            title: "Unsaved changes")), .window)
        XCTAssertEqual(ElementMarks.classifyWindow(evidence(tree: .other)), .window)
        XCTAssertEqual(ElementMarks.classifyWindow(evidence(tree: .incomplete)), .unknown)
        // A complete ordinary dialog tree (including text or secure controls) is not the one-icon overlay.
        XCTAssertEqual(ElementMarks.classifyWindow(evidence(role: "AXDialog", tree: .other)), .window)
        XCTAssertEqual(ElementMarks.classifyWindow(evidence(ownerPID: 43)), .notAppWindow)
        XCTAssertEqual(ElementMarks.classifyWindow(evidence(layer: 1)), .notAppWindow)
        XCTAssertEqual(ElementMarks.classifyWindow(evidence(windowID: 0)), .notAppWindow)
    }

    func testPointMapsFromScreenshotPixelsAcrossRetinaScale() throws {
        let point = try XCTUnwrap(PixelGeometry.point(CGPoint(x: 640, y: 360),
            imageSize: CGSize(width: 1280, height: 720),
            screenBounds: CGRect(x: 100, y: 50, width: 640, height: 360)))
        XCTAssertEqual(point.x, 420, accuracy: 0.001)
        XCTAssertEqual(point.y, 230, accuracy: 0.001)
    }

    func testNativeWindowCaptureSizeUsesFilterPointPixelScale() throws {
        let native = try XCTUnwrap(PixelGeometry.nativeWindowPixelSize(
            windowBounds: CGRect(x: 70, y: 40, width: 586, height: 488), pointPixelScale: 2))
        XCTAssertEqual(native.width, 1172)
        XCTAssertEqual(native.height, 976)
        XCTAssertNil(PixelGeometry.nativeWindowPixelSize(
            windowBounds: CGRect(x: 0, y: 0, width: 586, height: 488), pointPixelScale: 0))
    }

    func testNativeWindowResizeMapsBackToActualWindowFrameWithoutPadding() throws {
        let window = CGRect(x: 70, y: 40, width: 586, height: 488)
        let native = try XCTUnwrap(PixelGeometry.nativeWindowPixelSize(windowBounds: window, pointPixelScale: 2))
        let resizedSize = CGSize(width: 1280,
            height: CGFloat((Double(native.height) * 1280 / Double(native.width)).rounded()))
        let sourceCenter = CGPoint(x: 70 + 179, y: 40 + 227)
        let screenshotPixel = try XCTUnwrap(PixelGeometry.imagePoint(sourceCenter,
            imageSize: resizedSize, screenBounds: window))
        XCTAssertEqual(screenshotPixel.x, 1280 * 179 / 586, accuracy: 0.01)
        let roundTrip = try XCTUnwrap(PixelGeometry.point(screenshotPixel,
            imageSize: resizedSize, screenBounds: window))
        XCTAssertEqual(roundTrip.x, sourceCenter.x, accuracy: 0.001)
        XCTAssertEqual(roundTrip.y, sourceCenter.y, accuracy: 0.001)
    }

    func testNativeWindowImageMappingRejectsPointsOutsideCapturedWindow() {
        let window = CGRect(x: 70, y: 40, width: 586, height: 488)
        let size = CGSize(width: 1280, height: 1066)
        XCTAssertNil(PixelGeometry.imagePoint(CGPoint(x: 69.9, y: 100), imageSize: size, screenBounds: window))
        XCTAssertNil(PixelGeometry.imagePoint(CGPoint(x: CGFloat.infinity, y: 100), imageSize: size, screenBounds: window))
        XCTAssertNil(PixelGeometry.imagePoint(CGPoint(x: 100, y: 100), imageSize: .zero, screenBounds: window))
    }

    func testPointRejectsNonFiniteAndOutOfBoundsCoordinates() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(PixelGeometry.point(CGPoint(x: CGFloat.infinity, y: 2), imageSize: CGSize(width: 100, height: 100), screenBounds: bounds))
        XCTAssertNil(PixelGeometry.point(CGPoint(x: 100, y: 2), imageSize: CGSize(width: 100, height: 100), screenBounds: bounds))
    }

    func testFocusedWindowSelectionUsesFrontmostCGOrderAndRequiresMatchingTitle() {
        let frame = CGRect(x: 10, y: 20, width: 500, height: 400)
        func entry(_ number: UInt32, _ title: String?) -> [String: Any] {
            var value: [String: Any] = [kCGWindowOwnerPID as String: NSNumber(value: Int32(42)),
                kCGWindowBounds as String: frame.dictionaryRepresentation,
                kCGWindowNumber as String: NSNumber(value: number)]
            if let title { value[kCGWindowName as String] = title }
            return value
        }
        let candidates = [entry(16_742, "Start Page"), entry(16_799, "Safety controls")]
        XCTAssertEqual(AgentMacAccessibility.matchingWindowID(ownerPID: 42, bounds: frame,
            focusedTitle: "Safety controls", entries: candidates), 16_799)
        XCTAssertEqual(AgentMacAccessibility.matchingWindowID(ownerPID: 42, bounds: frame,
            focusedTitle: "Start Page", entries: candidates), 16_742)
        XCTAssertNil(AgentMacAccessibility.matchingWindowID(ownerPID: 42, bounds: frame,
            focusedTitle: "Stale title", entries: candidates))
        XCTAssertEqual(AgentMacAccessibility.matchingWindowID(ownerPID: 42, bounds: frame,
            focusedTitle: nil, entries: candidates), 16_742)
        XCTAssertNil(AgentMacAccessibility.matchingWindowID(ownerPID: 42, bounds: frame,
            focusedTitle: "Safety controls", entries: []))
    }

    func testFinitePointMappingDoesNotAddASecondImageBoundsGuard() throws {
        let mapped = try XCTUnwrap(PixelEnvironment.mapPoint(CGPoint(x: 120, y: -10),
            imageSize: CGSize(width: 100, height: 100),
            screenBounds: CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertEqual(mapped.x, 120, accuracy: 0.001)
        XCTAssertEqual(mapped.y, -10, accuracy: 0.001)
    }

    func testMappedClickAndDragPointsStayInsideActiveWindowExceptSameAppOverlays() {
        let window = CGRect(x: 100, y: 80, width: 400, height: 300)
        let menuBar = CGRect(x: 0, y: 0, width: 1600, height: 24)
        let sheet = CGRect(x: 180, y: 320, width: 500, height: 120)
        XCTAssertTrue(PixelWindowActionBoundary.allows(CGPoint(x: 120, y: 100),
            windowBounds: window, menuBarBounds: [menuBar], sameAppDialogBounds: []))
        XCTAssertFalse(PixelWindowActionBoundary.allows(CGPoint(x: 520, y: 160),
            windowBounds: window, menuBarBounds: [menuBar], sameAppDialogBounds: []))
        XCTAssertTrue(PixelWindowActionBoundary.allows(CGPoint(x: 40, y: 10),
            windowBounds: window, menuBarBounds: [menuBar], sameAppDialogBounds: []))
        XCTAssertTrue(PixelWindowActionBoundary.allows(CGPoint(x: 600, y: 350),
            windowBounds: window, menuBarBounds: [menuBar], sameAppDialogBounds: [sheet]))
        XCTAssertFalse(PixelWindowActionBoundary.allows(CGPoint(x: 600, y: 350),
            windowBounds: window, menuBarBounds: [menuBar], sameAppDialogBounds: []))
    }

    func testSecondaryDisplayMenuBarUsesScreenCaptureCoordinates() {
        let secondaryAppKitMenu = CGRect(x: 1440, y: -24, width: 900, height: 24)
        let menuBar = PixelGeometry.screenCaptureRect(fromAppKit: secondaryAppKitMenu, primaryScreenMaxY: 900)
        XCTAssertEqual(menuBar, CGRect(x: 1440, y: 900, width: 900, height: 24))
        XCTAssertTrue(PixelWindowActionBoundary.allows(CGPoint(x: 1450, y: 910),
            windowBounds: CGRect(x: 1440, y: 930, width: 900, height: 600),
            menuBarBounds: [menuBar], sameAppDialogBounds: []))
    }

    func testCropBoundsMatchClippedPixelIntegralWhenAXContentExceedsWindowCapture() throws {
        let source = try XCTUnwrap(CGImage(width: 800, height: 600, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 3200, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(repeating: 0, count: 3200 * 600) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let captureBounds = CGRect(x: 100, y: 100, width: 400, height: 300)
        let contentBounds = CGRect(x: 99.7, y: 99.8, width: 300.5, height: 200.3)
        let crop = try XCTUnwrap(PixelGeometry.cropWithBounds(source, screenRect: contentBounds,
            captureBounds: captureBounds))
        XCTAssertEqual(crop.image.width, 601)
        XCTAssertEqual(crop.image.height, 401)
        XCTAssertEqual(crop.screenBounds.minX, 100, accuracy: 0.001)
        XCTAssertEqual(crop.screenBounds.minY, 100, accuracy: 0.001)
        XCTAssertEqual(crop.screenBounds.maxX, 400.5, accuracy: 0.001)
        XCTAssertEqual(crop.screenBounds.maxY, 300.5, accuracy: 0.001)
        let resized = try XCTUnwrap(PixelGeometry.resize(crop.image, width: 1280))
        let mapped = try XCTUnwrap(PixelGeometry.point(CGPoint(x: 640, y: 427),
            imageSize: CGSize(width: resized.width, height: resized.height), screenBounds: crop.screenBounds))
        XCTAssertEqual(mapped.x, 250.25, accuracy: 0.01)
        XCTAssertEqual(mapped.y, 200.25, accuracy: 0.01)
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

    func testPointSnapRecognizesLiftedAXRowTargets() {
        let row = mark(id: 5, role: "AXRow", name: "Invoice 42",
            rect: CGRect(x: 100, y: 100, width: 2, height: 2))
        let result = PixelTargetSnapping.resolve(CGPoint(x: 108, y: 101), in: [row])
        XCTAssertEqual(result.mark?.id, row.id)
        XCTAssertEqual(result.point, CGPoint(x: 101, y: 101))
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

    func testMenuItemReferenceRemainsUsableOutsideMatchedWindowBounds() throws {
        let rect = CGRect(x: 8, y: 0, width: 32, height: 20)
        let menuItem = TestPixelElementReference(role: "AXMenuBarItem", name: "File", rect: rect)
        let expected = AgentElement(id: 1, role: "AXMenuBarItem", name: "File", value: nil,
            state: ["visible", "read_only", "offscreen"], bbox: .init(x: 8, y: 0, width: 32, height: 20), inView: false)

        XCTAssertEqual(try PixelElementReferenceResolver.currentCentre(expected, reference: menuItem,
            windowBounds: CGRect(x: 100, y: 100, width: 400, height: 300)), CGPoint(x: 24, y: 10))

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

    func testSelectedAXWindowExcludesOverlappingSiblingWindowsAndKeepsSheetAndMenu() {
        let bounds = CGRect(x: 100, y: 100, width: 400, height: 300)
        let visibleSheet = TestPixelAXNode(identity: "sheet", role: "AXSheet", title: nil,
            rect: CGRect(x: 100, y: 100, width: 500, height: 380),
            children: [TestPixelAXNode(identity: "sheet-button", role: "AXButton", title: "Continue",
                rect: CGRect(x: 350, y: 300, width: 90, height: 30))])
        let selected = TestPixelAXNode(identity: "selected-window", role: "AXWindow", title: nil, rect: bounds,
            children: [TestPixelAXNode(identity: "visible-editor", role: "AXTextArea", title: "Editor",
                rect: CGRect(x: 120, y: 150, width: 300, height: 180)), visibleSheet])
        let sibling = TestPixelAXNode(identity: "background-window", role: "AXWindow", title: nil, rect: bounds,
            children: [TestPixelAXNode(identity: "background-editor", role: "AXTextArea", title: "Background editor",
                rect: CGRect(x: 130, y: 160, width: 280, height: 160))])
        let menu = TestPixelAXNode(identity: "menu", role: "AXMenuBar", title: nil, rect: nil,
            children: [TestPixelAXNode(identity: "file-menu", role: "AXMenuBarItem", title: "File",
                rect: CGRect(x: 8, y: 0, width: 28, height: 20))])

        let result = ElementMarks.projectCaptureRoots(focusedWindow: selected, focusedBounds: bounds, focusedElement: nil,
            menuBar: menu, selectedBounds: bounds, deadline: .now + .milliseconds(300))

        let names = Set(result.marks.map(\.name))
        XCTAssertTrue(names.contains("Editor"))
        XCTAssertTrue(names.contains("Continue"))
        XCTAssertTrue(names.contains("File"))
        XCTAssertFalse(names.contains("Background editor"))
        XCTAssertEqual(result.overlayBounds, [CGRect(x: 100, y: 100, width: 500, height: 380)])
        XCTAssertTrue(PixelWindowActionBoundary.allows(CGPoint(x: 530, y: 430), windowBounds: bounds,
            menuBarBounds: [], sameAppDialogBounds: result.overlayBounds))
        XCTAssertFalse(PixelWindowActionBoundary.allows(CGPoint(x: 530, y: 430), windowBounds: bounds,
            menuBarBounds: [], sameAppDialogBounds: []))
    }

    func testMissingOrMismatchedAXWindowDoesNotExposeApplicationSiblingMarks() {
        let bounds = CGRect(x: 100, y: 100, width: 400, height: 300)
        let secure = TestPixelAXNode(identity: "secure", role: "AXTextField", title: "Password",
            rect: CGRect(x: 150, y: 170, width: 150, height: 28), secure: true,
            children: [TestPixelAXNode(identity: "secret", role: "AXStaticText", title: "protected",
                rect: CGRect(x: 150, y: 170, width: 150, height: 28))])
        let backgroundButton = TestPixelAXNode(identity: "sibling-button", role: "AXButton", title: "Background action",
            value: "not exposed", rect: CGRect(x: 120, y: 130, width: 100, height: 30))
        let sibling = TestPixelAXNode(identity: "sibling-window", role: "AXWindow", title: nil, rect: bounds,
            children: [backgroundButton, secure])
        let menu = TestPixelAXNode(identity: "menu", role: "AXMenuBar", title: nil, rect: nil,
            children: [TestPixelAXNode(identity: "file-menu", role: "AXMenuBarItem", title: "File",
                rect: CGRect(x: 8, y: 0, width: 28, height: 20))])
        let mismatchedSecure = TestPixelAXNode(identity: "mismatched-secure", role: "AXTextField", title: "PIN",
            rect: CGRect(x: 930, y: 170, width: 120, height: 26), secure: true,
            children: [TestPixelAXNode(identity: "mismatched-secret", role: "AXStaticText", title: "hidden",
                rect: CGRect(x: 930, y: 170, width: 120, height: 26))])
        let wrongWindow = TestPixelAXNode(identity: "wrong-window", role: "AXWindow", title: nil,
            rect: CGRect(x: 900, y: 100, width: 400, height: 300), children: [mismatchedSecure])

        let missing = ElementMarks.projectCaptureRoots(focusedWindow: nil, focusedBounds: nil, focusedElement: secure,
            menuBar: menu, selectedBounds: bounds, deadline: .now + .milliseconds(300))
        let mismatched = ElementMarks.projectCaptureRoots(focusedWindow: wrongWindow,
            focusedBounds: CGRect(x: 900, y: 100, width: 400, height: 300), focusedElement: mismatchedSecure, menuBar: menu, selectedBounds: bounds, deadline: .now + .milliseconds(300))

        XCTAssertEqual(missing.marks.map(\.name), ["File"])
        XCTAssertEqual(mismatched.marks.map(\.name), ["File"])
        XCTAssertEqual(missing.secureScreenRects, [CGRect(x: 150, y: 170, width: 150, height: 28)])
        XCTAssertEqual(mismatched.secureScreenRects, [CGRect(x: 930, y: 170, width: 120, height: 26)])
        XCTAssertEqual(backgroundButton.valueReads, 0, "secure fallback must not read ordinary values")
        XCTAssertEqual(sibling.childrenReads, 0)
        XCTAssertEqual(wrongWindow.childrenReads, 1, "a mismatched window may be scanned only for secure rects")
        XCTAssertEqual(mismatchedSecure.childrenReads, 0, "secure subtrees must be pruned")
        XCTAssertEqual(mismatchedSecure.valueReads, 0, "secure fallback must never read control values")
    }

    func testMissingWindowSecureScanHonorsTheSharedReadDeadline() {
        let bounds = CGRect(x: 100, y: 100, width: 400, height: 300)
        let secure = TestPixelAXNode(identity: "secure", role: "AXTextField", title: "Password",
            rect: CGRect(x: 150, y: 170, width: 150, height: 28), secure: true)
        let menu = TestPixelAXNode(identity: "menu", role: "AXMenuBar", title: nil, rect: nil,
            children: [TestPixelAXNode(identity: "file-menu", role: "AXMenuBarItem", title: "File",
                rect: CGRect(x: 8, y: 0, width: 28, height: 20))])

        let result = ElementMarks.projectCaptureRoots(focusedWindow: nil, focusedBounds: nil, focusedElement: secure,
            menuBar: menu, selectedBounds: bounds, deadline: .now - .milliseconds(1))

        XCTAssertTrue(result.marks.isEmpty)
        XCTAssertTrue(result.secureScreenRects.isEmpty)
        XCTAssertEqual(menu.childrenReads, 0)
    }

    func testElementMarksLiftsChildTextAndDeduplicatesOverlappingLabelsInFavorOfInteractiveNode() throws {
        let text = TestPixelAXNode(identity: "child", role: "AXStaticText", title: "Save",
            rect: CGRect(x: 104, y: 103, width: 38, height: 14))
        let button = TestPixelAXNode(identity: "button", role: "AXButton", title: nil,
            rect: CGRect(x: 100, y: 100, width: 48, height: 24), children: [text])
        let overlappingGroup = TestPixelAXNode(identity: "group", role: "AXGroup", title: "Save",
            rect: CGRect(x: 101, y: 100, width: 47, height: 24))

        let result = ElementMarks.project(root: TestPixelAXNode.root([button, overlappingGroup]),
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500))

        XCTAssertEqual(result.marks.count, 1)
        XCTAssertEqual(result.marks.first?.role, "AXButton")
        XCTAssertEqual(result.marks.first?.name, "Save")
        let projected = try XCTUnwrap(result.marks.first)
        let target = AgentElement(id: projected.id, role: projected.role, name: projected.name, value: nil,
            state: projected.state, bbox: .init(x: 0, y: 0, width: 1, height: 1), inView: true)
        let reference = try XCTUnwrap(projected.reference)
        let centre = try PixelElementReferenceResolver.currentCentre(target, reference: reference,
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500))
        XCTAssertEqual(centre, CGPoint(x: 124, y: 112))

        let row = TestPixelAXNode(identity: "row", role: "AXRow", title: nil,
            rect: CGRect(x: 10, y: 50, width: 200, height: 24), children: [
                TestPixelAXNode(identity: "row-text", role: "AXStaticText", title: "Invoice 42",
                    rect: CGRect(x: 20, y: 55, width: 80, height: 14))
            ])
        let rowMarks = ElementMarks.project(root: TestPixelAXNode.root([row]),
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500))
        XCTAssertEqual(rowMarks.marks.first?.name, "Invoice 42")
    }

    func testElementMarksRespectAncestorScrollViewportWithoutLosingSecureRects() {
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 300)
        let secureRect = CGRect(x: 100, y: 110, width: 80, height: 20)
        let clip = TestPixelAXNode(identity: "clip", role: "AXClipView", title: nil,
            rect: CGRect(x: 245, y: 0, width: 255, height: 300), children: [
                TestPixelAXNode(identity: "offscreen-column-field", role: "AXTextField", title: nil,
                    rect: CGRect(x: 100, y: 50, width: 80, height: 20)),
                TestPixelAXNode(identity: "partly-visible-safe", role: "AXTextField", title: "Visible",
                    rect: CGRect(x: 220, y: 80, width: 60, height: 20)),
                TestPixelAXNode(identity: "partly-visible-unsafe", role: "AXTextField", title: "Hidden center",
                    rect: CGRect(x: 210, y: 140, width: 50, height: 20)),
                TestPixelAXNode(identity: "offscreen-password", role: "AXTextField", title: "",
                    rect: secureRect, protected: true, secure: true),
            ])
        let scrollArea = TestPixelAXNode(identity: "scroll", role: "AXScrollArea", title: nil,
            rect: CGRect(x: 240, y: 0, width: 260, height: 300), children: [clip])

        let result = ElementMarks.project(root: TestPixelAXNode.root([scrollArea]), windowBounds: bounds)
        let identities = Set(result.marks.compactMap { $0.identity as? String })

        XCTAssertFalse(identities.contains("offscreen-column-field"))
        XCTAssertFalse(identities.contains("partly-visible-unsafe"))
        XCTAssertTrue(identities.contains("partly-visible-safe"))
        XCTAssertEqual(result.secureScreenRects, [secureRect])
    }

    func testLiftedTextReferenceRejectsChangedOrUnavailableChildLabelButKeepsDirectLabel() throws {
        let child = TestPixelAXNode(identity: "child", role: "AXStaticText", title: "Submit",
            rect: CGRect(x: 20, y: 20, width: 60, height: 16))
        let button = TestPixelAXNode(identity: "button", role: "AXButton", title: nil,
            rect: CGRect(x: 10, y: 10, width: 100, height: 40), children: [child])
        let marks = ElementMarks.project(root: TestPixelAXNode.root([button]),
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500))
        let lifted = try XCTUnwrap(marks.marks.first)
        let liftedTarget = AgentElement(id: lifted.id, role: lifted.role, name: lifted.name, value: nil,
            state: lifted.state, bbox: .init(x: 0, y: 0, width: 1, height: 1), inView: true)
        let liftedReference = try XCTUnwrap(lifted.reference as? TestPixelElementReference)
        XCTAssertNoThrow(try PixelElementReferenceResolver.currentCentre(liftedTarget, reference: liftedReference,
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500)))

        child.title = "Continue"
        XCTAssertThrowsError(try PixelElementReferenceResolver.currentCentre(liftedTarget, reference: liftedReference,
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500))) { error in
            XCTAssertEqual(error as? AgentEnvironmentError, .targetGone)
        }
        child.title = nil
        XCTAssertThrowsError(try PixelElementReferenceResolver.currentCentre(liftedTarget, reference: liftedReference,
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500))) { error in
            XCTAssertEqual(error as? AgentEnvironmentError, .targetGone)
        }

        let directlyLabeled = TestPixelAXNode(identity: "direct", role: "AXButton", title: "Save",
            rect: CGRect(x: 120, y: 10, width: 80, height: 40))
        let directMarks = ElementMarks.project(root: TestPixelAXNode.root([directlyLabeled]),
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500))
        let direct = try XCTUnwrap(directMarks.marks.first)
        let directTarget = AgentElement(id: direct.id, role: direct.role, name: direct.name, value: nil,
            state: direct.state, bbox: .init(x: 0, y: 0, width: 1, height: 1), inView: true)
        XCTAssertNoThrow(try PixelElementReferenceResolver.currentCentre(directTarget,
            reference: try XCTUnwrap(direct.reference), windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500)))
    }

    func testElementMarksDeduplicateInteractiveCandidatesAtIoU85ButKeepThoseBelowThreshold() {
        let window = CGRect(x: 0, y: 0, width: 500, height: 300)
        let atThreshold = ElementMarks.project(root: TestPixelAXNode.root([
            TestPixelAXNode(identity: "button", role: "AXButton", title: "Open",
                rect: CGRect(x: 0, y: 0, width: 100, height: 100)),
            TestPixelAXNode(identity: "field", role: "AXTextField", title: "Open",
                rect: CGRect(x: 8.108108, y: 0, width: 100, height: 100))
        ]), windowBounds: window)
        XCTAssertEqual(atThreshold.marks.count, 1)
        XCTAssertEqual(atThreshold.marks.first?.role, "AXButton")

        let belowThreshold = ElementMarks.project(root: TestPixelAXNode.root([
            TestPixelAXNode(identity: "button", role: "AXButton", title: "Open",
                rect: CGRect(x: 0, y: 0, width: 100, height: 100)),
            TestPixelAXNode(identity: "field", role: "AXTextField", title: "Open",
                rect: CGRect(x: 8.2, y: 0, width: 100, height: 100))
        ]), windowBounds: window)
        XCTAssertEqual(belowThreshold.marks.count, 2)
    }

    func testElementMarksDropScrollbarsAndStructuralWindowContainersButRetainFullWindowEditors() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let scrollbar = TestPixelAXNode(identity: "scroll", role: "AXScrollBar", title: "",
            rect: CGRect(x: 780, y: 0, width: 20, height: 600))
        let container = TestPixelAXNode(identity: "container", role: "AXGroup", title: "Document",
            rect: window)
        let editor = TestPixelAXNode(identity: "editor", role: "AXTextArea", title: "Document",
            rect: window)

        let result = ElementMarks.project(root: TestPixelAXNode.root([scrollbar, container, editor]), windowBounds: window)

        XCTAssertEqual(result.marks.map(\.role), ["AXTextArea"])
    }

    func testElementMarksPruneProtectedSubtreeBeforeReadingValuesOrChildrenAndKeepSecureRect() {
        let secretChild = TestPixelAXNode(identity: "secret-child", role: "AXStaticText", title: "private",
            rect: CGRect(x: 15, y: 15, width: 40, height: 10))
        let protected = TestPixelAXNode(identity: "password", role: "AXTextField", title: "Password",
            value: "sensitive-value", rect: CGRect(x: 10, y: 10, width: 100, height: 24),
            protected: true, secure: true, children: [secretChild])
        let duplicateProtected = TestPixelAXNode(identity: "password-copy", role: "AXTextField", title: "Password",
            value: "second-secret", rect: CGRect(x: 10, y: 10, width: 100, height: 24), protected: true, secure: true)

        let result = ElementMarks.project(root: TestPixelAXNode.root([protected, duplicateProtected]),
            windowBounds: CGRect(x: 0, y: 0, width: 400, height: 300))

        XCTAssertEqual(result.secureScreenRects.count, 2, "secure areas survive candidate deduplication")
        XCTAssertEqual(protected.valueReads, 0)
        XCTAssertEqual(protected.childrenReads, 0)
        XCTAssertEqual(secretChild.valueReads, 0)
    }

    func testAccessibilityDiffUsesOpaqueIdentityCapsChangesAndNeverRendersValues() {
        let before = (0..<12).map { index in
            PixelAXElementState(identity: index, role: "AXButton", title: "Old \(index)",
                value: "private-before-\(index)", isEnabled: true)
        }
        let after = (0..<12).map { index in
            PixelAXElementState(identity: index, role: "AXButton", title: "New \(index)",
                value: "private-after-\(index)", isEnabled: false)
        }

        let changes = PixelAXDiff.describe(before: before, after: after, sameApplication: true, windowChanged: false)

        XCTAssertEqual(changes.count, 10)
        XCTAssertTrue(changes.contains { $0.contains("title changed") })
        XCTAssertTrue(changes.contains { $0.contains("value changed") })
        XCTAssertTrue(changes.contains { $0.contains("enabled changed") })
        XCTAssertFalse(changes.joined(separator: " ").contains("private-before"))
        XCTAssertFalse(changes.joined(separator: " ").contains("private-after"))

        let renamed = PixelAXDiff.describe(
            before: [PixelAXElementState(identity: "same-AX", role: "AXButton", title: "Submit", value: nil, isEnabled: true)],
            after: [PixelAXElementState(identity: "same-AX", role: "AXButton", title: "Continue", value: nil, isEnabled: true)],
            sameApplication: true, windowChanged: false)
        XCTAssertFalse(renamed.contains { $0.hasPrefix("+") || $0.hasPrefix("-") })
        XCTAssertTrue(renamed.contains { $0.contains("title changed") })
    }

    func testAccessibilityDiffFallsBackToWindowChangedWhenAXIsUnavailable() {
        XCTAssertEqual(PixelAXDiff.describe(before: nil, after: nil, sameApplication: true, windowChanged: true), ["window changed: yes"])
        XCTAssertEqual(PixelAXDiff.describe(before: nil, after: nil, sameApplication: true, windowChanged: false), ["window changed: no"])
    }

    func testEmptyAccessibilityProjectionIsUnavailableRatherThanAllElementsRemoved() {
        let empty = ElementMarks.project(root: TestPixelAXNode.root([]),
            windowBounds: CGRect(x: 0, y: 0, width: 400, height: 300))
        let previous = [PixelAXElementState(identity: "button", role: "AXButton", title: "Save", value: nil, isEnabled: true)]

        XCTAssertNil(empty.axState)
        XCTAssertEqual(PixelAXDiff.describe(before: previous, after: empty.axState,
            sameApplication: true, windowChanged: false), ["window changed: no"])
    }

    func testAccessibilityDiffFallsBackToWindowChangeAcrossApplications() {
        let prior = [PixelAXElementState(identity: "same", role: "AXButton", title: "Save", value: nil, isEnabled: true)]
        let next = [PixelAXElementState(identity: "same", role: "AXButton", title: "Save", value: nil, isEnabled: true)]

        XCTAssertEqual(PixelAXDiff.describe(before: prior, after: next, sameApplication: false, windowChanged: true),
            ["window changed: yes"])
    }

    func testAXValueTextPreservesNumericControlValues() {
        XCTAssertEqual(ElementMarks.normalizedAXValue(NSNumber(value: 0)), "0")
        XCTAssertEqual(ElementMarks.normalizedAXValue(NSNumber(value: 1)), "1")
        XCTAssertEqual(ElementMarks.normalizedAXValue("enabled" as CFTypeRef), "enabled")
        XCTAssertNil(ElementMarks.normalizedAXValue(nil))
    }

    func testAccessibilityDiffReportsAddedAndRemovedByOpaqueIdentityAndSuppressesSecureValues() {
        let before = [
            PixelAXElementState(identity: "removed", role: "AXTextField", title: "Account", value: "old-secret", isEnabled: true, isSecure: true),
            PixelAXElementState(identity: "kept", role: "AXButton", title: "Save", value: nil, isEnabled: true)
        ]
        let after = [
            PixelAXElementState(identity: "added", role: "AXButton", title: "Continue", value: nil, isEnabled: true),
            PixelAXElementState(identity: "kept", role: "AXButton", title: "Save", value: nil, isEnabled: true)
        ]

        let changes = PixelAXDiff.describe(before: before, after: after, sameApplication: true, windowChanged: true)

        XCTAssertTrue(changes.contains { $0.hasPrefix("+") })
        XCTAssertTrue(changes.contains { $0.hasPrefix("-") })
        XCTAssertFalse(changes.joined(separator: " ").contains("old-secret"))
    }

    func testExecutionDescriptionUsesResolvedTargetWhenFreshFrameReusesMarkID() {
        func item(_ id: Int, _ name: String, _ x: Double) -> AgentElement {
            AgentElement(id: id, role: "AXButton", name: name, value: nil, state: ["visible"],
                bbox: .init(x: x, y: 10, width: 30, height: 20), inView: true)
        }
        let oldResolvedTarget = item(1, "Submit", 10)
        let freshFrameReusedID = item(1, "Cancel", 300)

        let description = PixelExecutionDescription.targetLabel(.element(id: 1),
            resolvedTargets: [oldResolvedTarget], frameElements: [freshFrameReusedID])

        XCTAssertEqual(description, "mark 1 \"Submit\"")
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
    private let fixedName: String
    private let currentName: (() -> String)?
    var rect: CGRect?
    var secure: Bool
    var enabled: Bool?

    init(role: String, name: String, rect: CGRect?, secure: Bool = false, enabled: Bool? = true,
         currentName: (() -> String)? = nil) {
        self.role = role; fixedName = name; self.currentName = currentName
        self.rect = rect; self.secure = secure; self.enabled = enabled
    }

    var name: String { currentName?() ?? fixedName }
    var isEnabled: Bool? { enabled }
    func currentScreenRect() -> CGRect? { rect }
    func isSecure() -> Bool { secure }
}

@MainActor
private final class TestPixelAXNode: PixelAXNode {
    let identity: AnyHashable
    let role: String
    var title: String?
    private let storedValue: String?
    let screenRect: CGRect?
    let isEnabled: Bool?
    let isProtected: Bool
    let isSecure: Bool
    let documentURL: String? = nil
    private let childNodes: [any PixelAXNode]
    private(set) var valueReads = 0
    private(set) var childrenReads = 0

    init(identity: AnyHashable, role: String, title: String?, value: String? = nil, rect: CGRect?,
         enabled: Bool? = true, protected: Bool = false, secure: Bool = false, children: [any PixelAXNode] = []) {
        self.identity = identity; self.role = role; self.title = title; storedValue = value
        screenRect = rect; isEnabled = enabled; isProtected = protected; isSecure = secure; childNodes = children
    }

    static func root(_ children: [any PixelAXNode]) -> TestPixelAXNode {
        TestPixelAXNode(identity: "root", role: "AXWindow", title: nil, rect: nil, children: children)
    }

    var value: String? { valueReads += 1; return storedValue }
    func children() -> [any PixelAXNode] { childrenReads += 1; return childNodes }
    func makeReference(observedName: String) -> (any PixelElementReference)? {
        TestPixelElementReference(role: role, name: observedName, rect: screenRect,
            secure: isSecure, enabled: isEnabled, currentName: { [weak self] in
                guard let self else { return "" }
                let deadline = ContinuousClock.now + .milliseconds(40)
                return ElementMarks.semanticLabel(for: self, deadline: deadline)
            })
    }
}

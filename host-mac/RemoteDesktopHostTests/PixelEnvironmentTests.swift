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

    func testFailedOCRProducesNoTargetLabel() {
        XCTAssertNil(SystemBarriers.targetLabel(screenshot: "not-base64", x: 12, y: 20))
    }
}

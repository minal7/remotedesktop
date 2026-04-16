import XCTest
@testable import RemoteDesktop

final class RemoteScreenInteractionTests: XCTestCase {
    func test_interactiveRect_matchesAspectFitDisplayArea() {
        let geometry = RemoteScreenGeometry(
            bounds: CGRect(x: 0, y: 0, width: 1024, height: 768),
            display: DisplayInfo(w: 1920, h: 1080, scale: 2.0))

        let rect = geometry.interactiveRect
        XCTAssertEqual(rect.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 96, accuracy: 0.001)
        XCTAssertEqual(rect.width, 1024, accuracy: 0.001)
        XCTAssertEqual(rect.height, 576, accuracy: 0.001)
    }

    func test_localToRemote_clampsLetterboxedPointsToDisplayEdges() {
        let geometry = RemoteScreenGeometry(
            bounds: CGRect(x: 0, y: 0, width: 1024, height: 768),
            display: DisplayInfo(w: 1920, h: 1080, scale: 2.0))

        let topLeft = geometry.localToRemote(CGPoint(x: 0, y: 0))
        XCTAssertEqual(topLeft.x, 0)
        XCTAssertEqual(topLeft.y, 0)

        let bottomRight = geometry.localToRemote(CGPoint(x: 1024, y: 768))
        XCTAssertEqual(bottomRight.x, 1919)
        XCTAssertEqual(bottomRight.y, 1079)
    }

    func test_touchCursorPolicy_onlyStartsDragOnSecondTap() {
        XCTAssertFalse(TouchCursorPolicy.beginsDrag(tapCount: 1))
        XCTAssertTrue(TouchCursorPolicy.beginsDrag(tapCount: 2))
    }

    func test_touchCursorPolicy_emitsClickAndDragReleaseSequences() {
        XCTAssertEqual(
            TouchCursorPolicy.endButtonSequence(duration: 0.1, isDragging: false, rightClickFired: false),
            [0b001, 0])
        XCTAssertEqual(
            TouchCursorPolicy.endButtonSequence(duration: 0.1, isDragging: true, rightClickFired: false),
            [0])
        XCTAssertEqual(
            TouchCursorPolicy.endButtonSequence(duration: 0.5, isDragging: false, rightClickFired: true),
            [])
    }

    func test_touchCursorCenter_canReachInteractiveEdges() {
        let layer = TouchCursorLayer()
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)

        layer.show(at: CGPoint(x: 0, y: 0), within: rect)
        XCTAssertEqual(layer.cursorCenter.x, 0, accuracy: 0.001)
        XCTAssertEqual(layer.cursorCenter.y, 0, accuracy: 0.001)

        layer.show(at: CGPoint(x: 100, y: 50), within: rect)
        XCTAssertEqual(layer.cursorCenter.x, 100, accuracy: 0.001)
        XCTAssertEqual(layer.cursorCenter.y, 50, accuracy: 0.001)
    }

    func test_touchCursorMovement_clampsHotspotToEdge() {
        let layer = TouchCursorLayer()
        let rect = CGRect(x: 10, y: 20, width: 200, height: 120)

        layer.show(at: CGPoint(x: 110, y: 80), within: rect)
        layer.move(by: CGPoint(x: 500, y: 500), within: rect)

        XCTAssertEqual(layer.cursorCenter.x, rect.maxX, accuracy: 0.001)
        XCTAssertEqual(layer.cursorCenter.y, rect.maxY, accuracy: 0.001)
    }
}

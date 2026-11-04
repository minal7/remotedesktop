import XCTest
import UIKit
@testable import RemoteDesktop

final class CursorOverlayTests: XCTestCase {
    func testLegacyPeerDoesNotShowOverlay() {
        let overlay = CursorOverlayView()
        overlay.setSurfaceVisible(true)
        overlay.moveCursor(toContentPoint: CGPoint(x: 10, y: 20), now: 1)
        XCTAssertTrue(overlay.isHidden)
        XCTAssertFalse(overlay.hasPosition)
        overlay.setEnabled(true)
        overlay.moveCursor(toContentPoint: CGPoint(x: 10, y: 20), now: 1)
        XCTAssertFalse(overlay.isHidden)
        overlay.setEnabled(false)
        XCTAssertTrue(overlay.isHidden)
        XCTAssertFalse(overlay.hasPosition)
    }

    func testRecentLocalMovementWinsOverHostFor150Milliseconds() {
        let overlay = CursorOverlayView()
        overlay.setEnabled(true)
        overlay.moveCursor(toContentPoint: CGPoint(x: 10, y: 20), now: 10)
        overlay.moveHostCursor(toContentPoint: CGPoint(x: 30, y: 40), now: 10.149)
        XCTAssertEqual(overlay.cursorContentPoint, CGPoint(x: 10, y: 20))
        overlay.moveHostCursor(toContentPoint: CGPoint(x: 30, y: 40), now: 10.151)
        XCTAssertEqual(overlay.cursorContentPoint, CGPoint(x: 30, y: 40))
    }

    func testSuppressedHostMoveIsAppliedAfterLocalIdleAndLatestHostWins() {
        let overlay = CursorOverlayView()
        overlay.setEnabled(true)
        overlay.moveCursor(toContentPoint: CGPoint(x: 10, y: 20), now: 10)
        overlay.moveHostCursor(toContentPoint: CGPoint(x: 30, y: 40), now: 10.05)
        overlay.moveHostCursor(toContentPoint: CGPoint(x: 50, y: 60), now: 10.06)
        XCTAssertEqual(overlay.cursorContentPoint, CGPoint(x: 10, y: 20))
        let applied = expectation(description: "latest host move after local idle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(overlay.cursorContentPoint, CGPoint(x: 50, y: 60))
            applied.fulfill()
        }
        wait(for: [applied], timeout: 1)
    }

    func testNewLocalMoveAndDisableCancelDeferredHostMove() {
        let overlay = CursorOverlayView()
        overlay.setEnabled(true)
        overlay.moveCursor(toContentPoint: CGPoint(x: 10, y: 20), now: 10)
        overlay.moveHostCursor(toContentPoint: CGPoint(x: 30, y: 40), now: 10.05)
        overlay.moveCursor(toContentPoint: CGPoint(x: 70, y: 80), now: 10.06)
        let resetOverlay = CursorOverlayView()
        resetOverlay.setEnabled(true)
        resetOverlay.moveCursor(toContentPoint: CGPoint(x: 1, y: 2), now: 10)
        resetOverlay.moveHostCursor(toContentPoint: CGPoint(x: 90, y: 100), now: 10.05)
        resetOverlay.setEnabled(false)
        resetOverlay.setEnabled(true)
        let checked = expectation(description: "local input and reset cancel pending host moves")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(overlay.cursorContentPoint, CGPoint(x: 70, y: 80))
            XCTAssertEqual(resetOverlay.cursorContentPoint, CGPoint(x: 1, y: 2))
            XCTAssertFalse(resetOverlay.hasPosition)
            checked.fulfill()
        }
        wait(for: [checked], timeout: 1)
    }

    func testHotspotFollowsContentTransformAtOneAndTwoTimesAndPanned() {
        let parent = CALayer()
        let content = CALayer()
        let overlay = CursorOverlayView()
        parent.bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        content.bounds = parent.bounds
        content.position = CGPoint(x: 100, y: 100)
        overlay.frame = content.bounds
        parent.addSublayer(content)
        content.addSublayer(overlay)
        overlay.setEnabled(true)
        overlay.moveCursor(toContentPoint: CGPoint(x: 75, y: 50), now: 1)
        XCTAssertEqual(content.convert(overlay.cursorContentPoint, to: parent), CGPoint(x: 75, y: 50))
        content.setAffineTransform(CGAffineTransform(scaleX: 2, y: 2))
        XCTAssertEqual(content.convert(overlay.cursorContentPoint, to: parent), CGPoint(x: 50, y: 0))
        content.position = CGPoint(x: 120, y: 130)
        XCTAssertEqual(content.convert(overlay.cursorContentPoint, to: parent), CGPoint(x: 70, y: 30))
    }

    func testShapeHotspotAndDisplayScale() throws {
        let overlay = CursorOverlayView()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 20)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 20))
        }
        overlay.setContentScale(CGSize(width: 2, height: 2))
        overlay.installShape(id: "text", png: try XCTUnwrap(image.pngData()),
                             hotspot: CGPoint(x: 3, y: 5), size: CGSize(width: 10, height: 20))
        overlay.setEnabled(true)
        overlay.moveCursor(toContentPoint: CGPoint(x: 50, y: 60), now: 1)
        let artwork = try XCTUnwrap(overlay.sublayers?.first)
        XCTAssertEqual(artwork.bounds.size, CGSize(width: 20, height: 40))
        XCTAssertEqual(artwork.anchorPoint, CGPoint(x: 0.3, y: 0.25))
        XCTAssertEqual(artwork.position, CGPoint(x: 50, y: 60))
    }

    func testShapeCacheSurvivesRenewalOnSamePeer() {
        let peer = NSObject()
        let shape = HostCursorShape(id: "text", png: Data([1]),
                                    hotspot: CGPoint(x: 1, y: 2), size: CGSize(width: 10, height: 20))
        var cache = CursorShapeCache()
        cache.bindPeer(peer)
        cache.store(shape)
        // A renewed input handshake retains the same transport and the host can
        // send only a reference, or no shape at all if it has not changed.
        cache.bindPeer(peer)
        XCTAssertEqual(cache.shapes["text"], shape)
        XCTAssertEqual(cache.selectedID, "text")
        cache.select("text")
        XCTAssertEqual(cache.shapes[cache.selectedID!], shape)
    }

    func testShapeCacheClearsWhenPeerChangesOrDisconnects() {
        let first = NSObject(), second = NSObject()
        let shape = HostCursorShape(id: "text", png: Data([1]),
                                    hotspot: .zero, size: CGSize(width: 10, height: 20))
        var cache = CursorShapeCache()
        cache.bindPeer(first)
        cache.store(shape)
        cache.bindPeer(second)
        XCTAssertTrue(cache.shapes.isEmpty)
        XCTAssertNil(cache.selectedID)
        cache.store(shape)
        cache.bindPeer(nil)
        XCTAssertTrue(cache.shapes.isEmpty)
        XCTAssertNil(cache.selectedID)
    }

    func testHelloCapabilityIsExplicitlyOptedIn() throws {
        let hello = DirectInputHello(clientID: UUID(), revision: 1)
        let message = ControlMessage.hello(proto: Config.protocolVersion)
        func caps(_ data: Data) throws -> [String: Any] {
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try XCTUnwrap(object["caps"] as? [String: Any])
        }
        let legacy = try caps(message.encoded(seq: 0, ts: 0, inputHello: hello))
        XCTAssertNil(legacy["clientCursor"])
        let enabled = try caps(message.encoded(seq: 0, ts: 0, inputHello: hello, clientCursor: true))
        XCTAssertEqual(enabled["clientCursor"] as? Int, 1)
    }

    func testCursorWireMessagesAndLegacyCapability() throws {
        let old = try XCTUnwrap(HostMessage.decode(Data(#"{"t":"hello_ack","proto":1}"#.utf8)))
        guard case .helloAck(let oldHello) = old else { return XCTFail("Expected hello") }
        XCTAssertEqual(oldHello.clientCursor, 0)
        let current = try XCTUnwrap(HostMessage.decode(Data(#"{"t":"hello_ack","proto":1,"caps":{"clientCursor":1}}"#.utf8)))
        guard case .helloAck(let newHello) = current else { return XCTFail("Expected hello") }
        XCTAssertEqual(newHello.clientCursor, 1)
        XCTAssertEqual(HostMessage.decode(Data(#"{"t":"cursorPosition","x":12,"y":30}"#.utf8)),
                       .cursorPosition(CGPoint(x: 12, y: 30)))
        XCTAssertEqual(HostMessage.decode(Data(#"{"t":"cursorShapeRef","id":"arrow"}"#.utf8)), .cursorShapeRef("arrow"))
        let shape = try XCTUnwrap(HostMessage.decode(Data(#"{"t":"cursorShape","id":"a","png":"AA==","hotspotX":1,"hotspotY":2,"widthPt":10,"heightPt":20}"#.utf8)))
        guard case .cursorShape(let value) = shape else { return XCTFail("Expected shape") }
        XCTAssertEqual(value.hotspot, CGPoint(x: 1, y: 2))
        XCTAssertEqual(value.size, CGSize(width: 10, height: 20))
        XCTAssertNil(HostMessage.decode(Data(#"{"t":"cursorPosition","x":true,"y":0}"#.utf8)))
    }
}

import AppKit
import XCTest
@testable import RemoteDesktopHost

final class HostCursorPublisherTests: XCTestCase {
    func testCursorCapabilityRequiresClientOptInAndAcknowledgement() throws {
        let legacy = try XCTUnwrap(ControlPacket.decode(Data(#"{"t":"hello","proto":1}"#.utf8)))
        let optedIn = try XCTUnwrap(ControlPacket.decode(Data(#"{"t":"hello","proto":1,"caps":{"clientCursor":1}}"#.utf8)))
        XCTAssertFalse(legacy.clientCursor)
        XCTAssertTrue(optedIn.clientCursor)
        for acknowledged in [false, true] {
            let data = HostMessageEncoder.helloAck(proto: 1, hostname: "Fixture", os: "macOS", audio: false,
                                                    monitors: 1, seq: 1, ts: 1, clientCursor: acknowledged)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let caps = try XCTUnwrap(object["caps"] as? [String: Any])
            XCTAssertEqual(caps["clientCursor"] as? Int, acknowledged ? 1 : 0)
        }
    }

    func testCaptureRestoresCursorAfterSession() async throws {
        actor Recorder {
            var values: [Bool] = []
            func add(_ value: Bool) { values.append(value) }
        }
        let recorder = Recorder()
        let updates = CaptureCursorVisibilityUpdates { visible in await recorder.add(visible) }
        let hide = updates.setVisible(false)
        let restore = try XCTUnwrap(updates.restoreIfNeeded())
        try await hide.value
        try await restore.value
        let values = await recorder.values
        XCTAssertEqual(values, [false, true])
        XCTAssertNil(updates.restoreIfNeeded())
    }

    func testCaptureRestoresAfterFailedHide() async throws {
        enum Failure: Error { case hide }
        actor Recorder {
            var values: [Bool] = []
            func add(_ value: Bool) throws {
                values.append(value)
                if !value { throw Failure.hide }
            }
        }
        let recorder = Recorder()
        let updates = CaptureCursorVisibilityUpdates { visible in try await recorder.add(visible) }
        let hide = updates.setVisible(false)
        let restore = try XCTUnwrap(updates.restoreIfNeeded())
        do { try await hide.value; XCTFail("Hide must fail") } catch { }
        try await restore.value
        let values = await recorder.values
        XCTAssertEqual(values, [false, true])
    }

    func testDisplayChangeResetsPositionAndUsesNewOrigin() {
        var state = HostCursorPositionState(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        state.recordClient(CGPoint(x: 10, y: 10))
        XCTAssertNil(state.positionToPublish(global: CGPoint(x: 10, y: 10)))
        state.updateBounds(CGRect(x: 100, y: 100, width: 100, height: 100))
        XCTAssertNil(state.lastCommanded)
        XCTAssertNil(state.lastReported)
        XCTAssertEqual(state.positionToPublish(global: CGPoint(x: 110, y: 110)), CGPoint(x: 10, y: 10))
    }

    func testShapeSentOncePerSessionThenReferenced() {
        var history = HostCursorShapeHistory()
        XCTAssertEqual(history.update("arrow"), .shape)
        XCTAssertEqual(history.update("arrow"), .none)
        XCTAssertEqual(history.update("text"), .shape)
        XCTAssertEqual(history.update("arrow"), .reference)
        var nextSession = HostCursorShapeHistory()
        XCTAssertEqual(nextSession.update("arrow"), .shape)
    }

    func testPositionOnlyWhenHostMovesAwayFromClientCommand() {
        let client = CGPoint(x: 10, y: 20)
        XCTAssertFalse(HostCursorPublisher.shouldPublish(position: CGPoint(x: 11, y: 21), lastCommanded: client, lastReported: nil))
        XCTAssertTrue(HostCursorPublisher.shouldPublish(position: CGPoint(x: 13, y: 20), lastCommanded: client, lastReported: nil))
        XCTAssertFalse(HostCursorPublisher.shouldPublish(position: CGPoint(x: 13, y: 20), lastCommanded: client, lastReported: CGPoint(x: 13, y: 20)))
    }
}

#if DEBUG
import XCTest
@testable import RemoteDesktopHost

final class LatencyF1RestartTests: XCTestCase {
    func testDebugHelloAdvertisesLabCapabilities() throws {
        let data = HostMessageEncoder.helloAck(proto: 1, hostname: "Fixture", os: "macOS",
            audio: false, monitors: 1, seq: 0, ts: 0)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let caps = try XCTUnwrap(object["caps"] as? [String: Any])
        XCTAssertEqual(caps["latencyF1Playout"] as? Int, 1)
        XCTAssertEqual(caps["latencyF2Encoder"] as? Int, LatencyLabConfiguration.current.f2Encoder ? 1 : 0)
        XCTAssertEqual(caps["latencyF3Sender"] as? Int, LatencyLabConfiguration.current.f3Sender ? 1 : 0)
        var enabled = LatencyLabConfiguration()
        enabled.f2Encoder = true; enabled.f3Sender = true
        XCTAssertEqual(HostMessageEncoder.latencyCapabilities(enabled)["latencyF2Encoder"], 1)
        XCTAssertEqual(HostMessageEncoder.latencyCapabilities(enabled)["latencyF3Sender"], 1)
        XCTAssertEqual(HostMessageEncoder.latencyCapabilities(LatencyLabConfiguration())["latencyF2Encoder"], 0)
        XCTAssertEqual(HostMessageEncoder.latencyCapabilities(LatencyLabConfiguration())["latencyF3Sender"], 0)
    }

    func testPeerHelloCapabilitiesRemainBoundToPeerConfiguration() throws {
        let hello = HostMessageEncoder.helloAck(proto: 1, hostname: "Fixture", os: "macOS",
            audio: false, monitors: 1, seq: 4, ts: 7)
        var enabled = LatencyLabConfiguration()
        enabled.f2Encoder = true; enabled.f3Sender = true
        let enabledData = try XCTUnwrap(HostPeerSession.pinLatencyCapabilities(hello, configuration: enabled))
        let enabledObject = try XCTUnwrap(JSONSerialization.jsonObject(with: enabledData) as? [String: Any])
        let enabledCaps = try XCTUnwrap(enabledObject["caps"] as? [String: Any])
        XCTAssertEqual(enabledCaps["latencyF1Playout"] as? Int, 1)
        XCTAssertEqual(enabledCaps["latencyF2Encoder"] as? Int, 1)
        XCTAssertEqual(enabledCaps["latencyF3Sender"] as? Int, 1)
        XCTAssertEqual(enabledObject["s"] as? Int, 4)
        XCTAssertEqual(enabledCaps["inputSessions"] as? Int, DirectInputWire.version)

        let disabledData = try XCTUnwrap(HostPeerSession.pinLatencyCapabilities(enabledData, configuration: LatencyLabConfiguration()))
        let disabledObject = try XCTUnwrap(JSONSerialization.jsonObject(with: disabledData) as? [String: Any])
        let disabledCaps = try XCTUnwrap(disabledObject["caps"] as? [String: Any])
        XCTAssertEqual(disabledCaps["latencyF2Encoder"] as? Int, 0)
        XCTAssertEqual(disabledCaps["latencyF3Sender"] as? Int, 0)
        XCTAssertNil(HostPeerSession.pinLatencyCapabilities(Data("{}".utf8), configuration: enabled))
    }

    func testTicketBindsNonceSenderGenerationAndExpiry() {
        let ticket = LatencyF1RestartTicket(nonce: "nonce", senderID: "peer", generation: 7, expires: 100)
        XCTAssertTrue(ticket.matches(nonce: "nonce", senderID: "peer", generation: 7, now: 99))
        XCTAssertFalse(ticket.matches(nonce: "other", senderID: "peer", generation: 7, now: 99))
        XCTAssertFalse(ticket.matches(nonce: "nonce", senderID: "other", generation: 7, now: 99))
        XCTAssertFalse(ticket.matches(nonce: "nonce", senderID: "peer", generation: 8, now: 99))
        XCTAssertFalse(ticket.matches(nonce: "nonce", senderID: "peer", generation: 7, now: 101))
    }
}
#endif

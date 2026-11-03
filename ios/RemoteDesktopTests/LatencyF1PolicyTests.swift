#if DEBUG
import XCTest
@testable import RemoteDesktop

final class LatencyF1PolicyTests: XCTestCase {
    func testRuntimeFactoryChangesAndSignalingGenerationIsolation() {
        XCTAssertFalse(LatencyF1Policy.needsNewFactory(currentMaximumMs: nil, desiredMaximumMs: nil))
        XCTAssertTrue(LatencyF1Policy.needsNewFactory(currentMaximumMs: nil, desiredMaximumMs: 0))
        XCTAssertTrue(LatencyF1Policy.needsNewFactory(currentMaximumMs: 0, desiredMaximumMs: 10))
        XCTAssertTrue(LatencyF1Policy.needsNewFactory(currentMaximumMs: 10, desiredMaximumMs: nil))
        XCTAssertFalse(LatencyF1Policy.needsNewFactory(currentMaximumMs: 10, desiredMaximumMs: 10))
        XCTAssertTrue(LatencyF1Policy.acceptsSignaling(activeNonce: nil, messageNonce: nil))
        XCTAssertFalse(LatencyF1Policy.acceptsSignaling(activeNonce: nil, messageNonce: "old"))
        XCTAssertTrue(LatencyF1Policy.acceptsSignaling(activeNonce: "new", messageNonce: "new"))
        XCTAssertFalse(LatencyF1Policy.acceptsSignaling(activeNonce: "new", messageNonce: nil))
        XCTAssertFalse(LatencyF1Policy.acceptsSignaling(activeNonce: "new", messageNonce: "old"))
    }

    func testRuntimeSelectionRequiresCapabilitiesAndCanTurnFeaturesOff() {
        var hello = HostHello(app: "Fixture", version: "1", hostname: "Mac", os: "macOS", audio: false, monitors: 1)
        var config = LatencyLabConfiguration()
        config.f1Playout = true; config.f1MaximumDelayMs = 10; config.f2Encoder = true; config.f3Sender = true
        let legacy = LatencyF1Policy.selection(configuration: config, hello: hello)
        XCTAssertNil(legacy.f1MaximumDelayMs); XCTAssertFalse(legacy.f2); XCTAssertFalse(legacy.f3)
        hello.latencyF1Playout = 1; hello.latencyF2Encoder = 1; hello.latencyF3Sender = 1
        let enabled = LatencyF1Policy.selection(configuration: config, hello: hello)
        XCTAssertEqual(enabled.f1MaximumDelayMs, 10); XCTAssertTrue(enabled.f2); XCTAssertTrue(enabled.f3)
        config.f1Playout = false; config.f2Encoder = false; config.f3Sender = false
        let disabled = LatencyF1Policy.selection(configuration: config, hello: hello)
        XCTAssertNil(disabled.f1MaximumDelayMs); XCTAssertFalse(disabled.f2); XCTAssertFalse(disabled.f3)
        XCTAssertNotEqual(enabled, disabled)
    }

    func testOnlyOptedInOrdinarySessionsWithCurrentCapabilityCanRestart() {
        for ms in [0, 10, 20] {
            XCTAssertTrue(LatencyF1Policy.shouldRequest(enabled: true, ordinaryRemoteSession: true,
                                                         hostCapability: 1, maximumDelayMs: ms))
        }
        XCTAssertFalse(LatencyF1Policy.shouldRequest(enabled: false, ordinaryRemoteSession: true, hostCapability: 1, maximumDelayMs: 0))
        XCTAssertFalse(LatencyF1Policy.shouldRequest(enabled: true, ordinaryRemoteSession: false, hostCapability: 1, maximumDelayMs: 0))
        XCTAssertFalse(LatencyF1Policy.shouldRequest(enabled: true, ordinaryRemoteSession: true, hostCapability: 0, maximumDelayMs: 0))
        XCTAssertFalse(LatencyF1Policy.shouldRequest(enabled: true, ordinaryRemoteSession: true, hostCapability: 1, maximumDelayMs: 21))
        XCTAssertTrue(LatencyF1Policy.shouldRequestF2(enabled: true, ordinaryRemoteSession: true, handoffCapability: 1, hostF2Capability: 1))
        XCTAssertFalse(LatencyF1Policy.shouldRequestF2(enabled: true, ordinaryRemoteSession: true, handoffCapability: 0, hostF2Capability: 1))
        XCTAssertFalse(LatencyF1Policy.shouldRequestF2(enabled: true, ordinaryRemoteSession: false, handoffCapability: 1, hostF2Capability: 1))
        XCTAssertFalse(LatencyF1Policy.shouldRequestF2(enabled: true, ordinaryRemoteSession: true, handoffCapability: 1, hostF2Capability: 0))
    }

    func testOnlyNumericVersionOneEnablesCapability() throws {
        let cases: [(Any?, Int)] = [(nil, 0), (true, 0), ("1", 0), (2, 0), (1.5, 0), (1, 1)]
        for (value, expected) in cases {
            var object: [String: Any] = ["t": "hello_ack", "proto": Config.protocolVersion]
            if let value { object["caps"] = ["latencyF1Playout": value] }
            let data = try JSONSerialization.data(withJSONObject: object)
            guard case .helloAck(let hello) = HostMessage.decode(data) else { return XCTFail("Expected hello") }
            XCTAssertEqual(hello.latencyF1Playout, expected)
        }
    }
}
#endif

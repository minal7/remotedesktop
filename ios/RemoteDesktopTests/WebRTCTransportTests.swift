import XCTest
@testable import RemoteDesktop

@MainActor
final class WebRTCTransportTests: XCTestCase {
    func test_connect_sendsOfferThatRequestsVideo() async throws {
        let channel = FakeWebRTCSignalingChannel()
        let transport = WebRTCTransport(
            signalingFactory: { _ in channel },
            iceConfigProvider: { .fallback })

        try await transport.connect(pairingCode: "123456")
        let snapshot = await channel.snapshot()
        transport.disconnect(reason: "test")

        XCTAssertEqual(snapshot.claimCount, 1)
        XCTAssertEqual(snapshot.sent.count, 1)
        XCTAssertEqual(snapshot.sent.first?.kind, .offer)
        XCTAssertEqual(snapshot.sent.first?.payload["sdpType"], "offer")
        XCTAssertTrue(
            snapshot.sent.first?.payload["sdp"]?.contains("m=video") == true,
            "expected the client offer to negotiate a video m-line")
        XCTAssertTrue(
            snapshot.sent.first?.payload["sdp"]?.contains("m=audio") == true,
            "expected the client offer to negotiate an audio m-line for host audio")
    }

    func test_disconnectDoesNotReportCancelledIceDeadlineAsFailure() async throws {
        let channel = FakeWebRTCSignalingChannel()
        let transport = WebRTCTransport(
            signalingFactory: { _ in channel },
            iceConfigProvider: { .fallback })
        var disconnectReasons: [String] = []
        transport.onDisconnect = { reason in
            disconnectReasons.append(reason)
        }

        try await transport.connect(pairingCode: "123456")
        transport.disconnect(reason: "test")
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(disconnectReasons.isEmpty)
    }
}

private final class FakeWebRTCSignalingChannel: SignalingChannel, @unchecked Sendable {
    struct Snapshot {
        let claimCount: Int
        let sent: [SignalingEnvelope]
    }

    private let queue = DispatchQueue(label: "FakeWebRTCSignalingChannel")
    private var claimCount = 0
    private var sent: [SignalingEnvelope] = []

    func claim() async throws {
        queue.sync { claimCount += 1 }
    }

    func send(_ envelope: SignalingEnvelope) async throws {
        queue.sync { sent.append(envelope) }
    }

    func poll() async throws -> [SignalingEnvelope] {
        []
    }

    func snapshot() -> Snapshot {
        queue.sync { Snapshot(claimCount: claimCount, sent: sent) }
    }
}

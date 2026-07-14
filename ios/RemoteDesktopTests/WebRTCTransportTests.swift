import XCTest
import AVFAudio
@testable import RemoteDesktop

@MainActor
final class WebRTCTransportTests: XCTestCase {
    func test_connect_sendsOfferThatRequestsVideo() async throws {
        let channel = FakeWebRTCSignalingChannel()
        let transport = WebRTCTransport(
            signalingFactory: { _, _ in channel },
            iceConfigProvider: { .fallback })

        try await transport.connect(pairingCode: "123456")
        let snapshot = channel.snapshot()
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

        let sdp = try XCTUnwrap(snapshot.sent.first?.payload["sdp"])
        XCTAssertTrue(mediaSection("video", in: sdp).contains("a=recvonly"))
        XCTAssertTrue(mediaSection("audio", in: sdp).contains("a=recvonly"))
        XCTAssertFalse(mediaSection("video", in: sdp).contains("a=sendrecv"))
        XCTAssertFalse(mediaSection("audio", in: sdp).contains("a=sendrecv"))
    }

    func test_audioSessionPolicy_isPlaybackOnly() {
        XCTAssertEqual(RemoteAudioSessionPolicy.category, .playback)
        XCTAssertFalse(RemoteAudioSessionPolicy.categoryOptions.contains(.allowBluetoothHFP))
        XCTAssertFalse(RemoteAudioSessionPolicy.categoryOptions.contains(.defaultToSpeaker))
    }

    func test_disconnectDoesNotReportCancelledIceDeadlineAsFailure() async throws {
        let channel = FakeWebRTCSignalingChannel()
        let transport = WebRTCTransport(
            signalingFactory: { _, _ in channel },
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

    func test_connectPassesSelectedHostIdentityToSignaling() async throws {
        let channel = FakeWebRTCSignalingChannel()
        var receivedHostID: String?
        let transport = WebRTCTransport(
            signalingFactory: { _, expectedHostID in
                receivedHostID = expectedHostID
                return channel
            },
            iceConfigProvider: { .fallback })

        try await transport.connect(
            pairingCode: "123456",
            expectedHostID: "HOST-B")
        transport.disconnect(reason: "test")

        XCTAssertEqual(receivedHostID, "HOST-B")
    }

    func test_sessionModelPinsComputerUseConnectionToTappedHost() async {
        let connected = expectation(description: "transport connect called")
        let transport = RecordingTargetTransport(connected: connected)
        let model = SessionModel(transportFactory: { transport })

        model.connect(
            code: "123456",
            experience: .computerUse,
            computerUseHostID: "HOST-B",
            hostName: "Studio Mac")
        await fulfillment(of: [connected], timeout: 1)

        XCTAssertEqual(transport.pairingCode, "123456")
        XCTAssertEqual(transport.expectedHostID, "HOST-B")
        model.reset()
    }

    func test_sessionModelRequiresAnActualDecodedFrameForVideoReadiness() async {
        let connected = expectation(description: "transport connect called")
        let transport = RecordingTargetTransport(connected: connected)
        let model = SessionModel(transportFactory: { transport })

        model.connect(code: "123456")
        await fulfillment(of: [connected], timeout: 1)

        transport.onHostHello?(HostHello(
            app: "RemoteDesktop-Mac",
            version: "1.0",
            hostname: "Studio Mac",
            os: "macOS",
            audio: true,
            monitors: 1))
        XCTAssertEqual(model.state, .connected)
        XCTAssertFalse(
            model.hasReceivedVideoFrame,
            "A control-channel hello must not disguise a pending macOS capture-consent prompt as a live screen.")

        transport.onFirstVideoFrame?()
        XCTAssertTrue(model.hasReceivedVideoFrame)

        model.reset()
        XCTAssertFalse(model.hasReceivedVideoFrame)
    }

    private func mediaSection(_ kind: String, in sdp: String) -> String {
        let marker = "m=\(kind)"
        guard let start = sdp.range(of: marker) else { return "" }
        let suffix = sdp[start.lowerBound...]
        if let next = suffix.dropFirst(marker.count).range(of: "\nm=") {
            return String(suffix[..<next.lowerBound])
        }
        return String(suffix)
    }
}

@MainActor
private final class RecordingTargetTransport: Transport {
    var onHostHello: (@MainActor (HostHello) -> Void)?
    var onDisplay: (@MainActor (DisplayInfo) -> Void)?
    var onFirstVideoFrame: (@MainActor () -> Void)?
    var onDisconnect: (@MainActor (String) -> Void)?

    private let connected: XCTestExpectation
    private(set) var pairingCode: String?
    private(set) var expectedHostID: String?

    init(connected: XCTestExpectation) {
        self.connected = connected
    }

    func connect(pairingCode: String, expectedHostID: String?) async throws {
        self.pairingCode = pairingCode
        self.expectedHostID = expectedHostID
        connected.fulfill()
    }

    func send(_ message: ControlMessage, seq: UInt32, ts: UInt64) {}
    func disconnect(reason: String) {}
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

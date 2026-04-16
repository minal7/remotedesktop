import XCTest
@testable import RemoteDesktop

@MainActor
final class SignalingPreflightTransportTests: XCTestCase {
    func test_connect_claimsRoom_sendsOffer_andPublishesHostMetadata() async throws {
        let channel = FakeSignalingChannel(
            pollResponses: [[
                SignalingEnvelope(
                    role: .host,
                    kind: .answer,
                    payload: [
                        "host": "Studio Mac",
                        "app": "RemoteDesktop-Host",
                        "version": "0.1.0",
                        "os": "macOS 15.0",
                        "audio": "true",
                        "monitors": "2",
                        "displayWidth": "3024",
                        "displayHeight": "1964",
                        "displayScale": "2.0",
                    ],
                    ts: 1_710_000_000)
            ]])

        let transport = SignalingPreflightTransport(
            deviceName: { "Test iPhone" },
            handshakeTimeout: .milliseconds(200),
            signalingFactory: { _ in channel })

        var hello: HostHello?
        var display: DisplayInfo?
        transport.onHostHello = { hello = $0 }
        transport.onDisplay = { display = $0 }

        try await transport.connect(pairingCode: "123456")
        let snapshot = await channel.snapshot()

        XCTAssertEqual(snapshot.claimCount, 1)
        XCTAssertEqual(snapshot.sent.count, 1)
        XCTAssertEqual(snapshot.sent.first?.kind.rawValue, "offer")
        XCTAssertEqual(snapshot.sent.first?.payload["client"], "Test iPhone")
        XCTAssertEqual(hello?.hostname, "Studio Mac")
        XCTAssertEqual(hello?.monitors, 2)
        XCTAssertEqual(display, DisplayInfo(w: 3024, h: 1964, scale: 2.0))
    }

    func test_connect_withoutAnswerTimesOutWithHelpfulError() async {
        let channel = FakeSignalingChannel()
        let transport = SignalingPreflightTransport(
            deviceName: { "Test iPhone" },
            handshakeTimeout: .milliseconds(20),
            signalingFactory: { _ in channel })

        do {
            try await transport.connect(pairingCode: "654321")
            XCTFail("expected connect to time out without a host answer")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("No reply from your computer"),
                "expected a helpful timeout message, got: \(error.localizedDescription)")
        }
    }
}

private final class FakeSignalingChannel: SignalingChannel, @unchecked Sendable {
    struct Snapshot {
        let claimCount: Int
        let sent: [SignalingEnvelope]
    }

    private let queue = DispatchQueue(label: "FakeSignalingChannel")
    private var claimCount = 0
    private var sent: [SignalingEnvelope] = []
    private var pollResponses: [[SignalingEnvelope]]

    init(pollResponses: [[SignalingEnvelope]] = []) {
        self.pollResponses = pollResponses
    }

    func claim() async throws {
        queue.sync { claimCount += 1 }
    }

    func send(_ envelope: SignalingEnvelope) async throws {
        queue.sync { sent.append(envelope) }
    }

    func poll() async throws -> [SignalingEnvelope] {
        queue.sync {
            if pollResponses.isEmpty {
                return []
            }
            return pollResponses.removeFirst()
        }
    }

    func snapshot() -> Snapshot {
        queue.sync { Snapshot(claimCount: claimCount, sent: sent) }
    }
}

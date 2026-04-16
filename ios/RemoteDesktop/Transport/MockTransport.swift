import Foundation
import os

/// In-memory transport for UI development. Simulates a successful pair
/// after a short delay, reports a 2560×1440 display, and logs outgoing
/// input events at `.debug` for inspection via Console.app.
@MainActor
final class MockTransport: Transport {
    var onHostHello: (@MainActor (HostHello) -> Void)?
    var onDisplay: (@MainActor (DisplayInfo) -> Void)?
    var onDisconnect: (@MainActor (String) -> Void)?

    private let log = Logger(subsystem: "com.threadmark.remotedesktop", category: "mock")

    func connect(pairingCode: String) async throws {
        log.debug("mock: connect code=\(pairingCode, privacy: .public)")
        try? await Task.sleep(for: .milliseconds(400))

        onHostHello?(HostHello(
            app: "RemoteDesktop-Mac",
            version: "0.1.0",
            hostname: "studio.local",
            os: "macOS 15.1",
            audio: true,
            monitors: 1))

        onDisplay?(DisplayInfo(w: 2560, h: 1440, scale: 2.0))
    }

    func send(_ message: ControlMessage, seq: UInt32, ts: UInt64) {
        log.debug("mock: send seq=\(seq) ts=\(ts) \(String(describing: message), privacy: .public)")
    }

    func disconnect(reason: String) {
        log.debug("mock: disconnect reason=\(reason, privacy: .public)")
        onDisconnect?(reason)
    }
}

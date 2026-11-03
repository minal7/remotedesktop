import CloudKit
import XCTest
@testable import RemoteDesktop

@MainActor
final class SessionReconnectTests: XCTestCase {
    private let binding = CloudKitAccountBinding(rawValue: String(repeating: "c", count: 64))!

    func testHostRestartUsesFreshRouteAndNeverReplaysOldInput() async throws {
        let events = RecoveryEvents()
        let (model, transports) = makeModel(
            validator: { value in await events.append("validate:\(value.rawValue)") },
            resolver: { host in await events.append("resolve:\(host)"); return "654321" })
        defer { model.reset() }
        try await connect(model, transports[0])
        let oldGeneration = model.remoteInputGeneration
        let source = try XCTUnwrap(model.beginRemoteInputSource(.pointer, expectedInputGeneration: oldGeneration))
        model.send(.pointer(x: 20, y: 30, buttons: 1), from: source)
        transports[0].loseConnection()
        XCTAssertEqual(model.state, .connecting)
        XCTAssertFalse(model.hasInteractiveRemoteScreen)
        XCTAssertFalse(model.isRemoteInputSourceCurrent(source))
        try await wait { transports[1].connections.count == 1 }
        XCTAssertEqual(transports[1].connections.first?.code, "654321")
        XCTAssertEqual(transports[1].connections.first?.hostID, "expected-host")
        let recorded = await events.values
        XCTAssertEqual(recorded, ["validate:\(binding.rawValue)", "resolve:expected-host", "validate:\(binding.rawValue)"])
        transports[0].present()
        XCTAssertEqual(model.state, .connecting, "A late old hello cannot revive the old input lifetime")
        transports[1].present()
        XCTAssertEqual(model.state, .connected)
        XCTAssertTrue(model.hasInteractiveRemoteScreen)
        XCTAssertNotEqual(model.remoteInputGeneration, oldGeneration)
        model.send(.pointer(x: 21, y: 31, buttons: 1), from: source)
        XCTAssertFalse(transports[1].messages.contains { if case .pointer = $0 { return true }; return false })
    }

    func testUnboundAndTerminalSessionsNeverReconnect() async throws {
        for useBinding in [false, true] {
            let (model, transports) = makeModel()
            defer { model.reset() }
            model.connect(code: "123456", computerUseHostID: "expected-host",
                          localCloudAccountBinding: useBinding ? binding : nil)
            try await wait { transports[0].connections.count == 1 }
            transports[0].present()
            transports[0].loseConnection(recoverable: !useBinding)
            guard case .ended = model.state else { return XCTFail("Unbound or terminal failure must end") }
            XCTAssertTrue(transports[1].connections.isEmpty)
        }
    }

    func testAccountFailureBeforeOrAfterRediscoveryNeverCreatesTransport() async throws {
        for failingValidation in [1, 2] {
            let checks = RecoveryValidation(failAt: failingValidation)
            let (model, transports) = makeModel(validator: { _ in try await checks.validate() })
            defer { model.reset() }
            try await connect(model, transports[0])
            transports[0].loseConnection()
            try await wait { if case .ended = model.state { return true }; return false }
            XCTAssertTrue(transports[1].connections.isEmpty)
            XCTAssertFalse(model.hasInteractiveRemoteScreen)
        }
    }

    func testSignalingFailureEndsRecoveryWithoutTryingAnotherHost() async throws {
        let (model, transports) = makeModel(resolver: { _ in throw RecoveryTestError.unavailable })
        defer { model.reset() }
        try await connect(model, transports[0])
        transports[0].loseConnection()
        try await wait { if case .ended = model.state { return true }; return false }
        XCTAssertTrue(transports[1].connections.isEmpty)
    }

    func testDeadlineEndsSuspendedLookupAndFencesItsLateResult() async throws {
        let gate = RecoveryLookupGate()
        let (model, transports) = makeModel(timeout: .milliseconds(200), resolver: { _ in await gate.resolve() })
        defer { model.reset() }
        try await connect(model, transports[0])
        transports[0].loseConnection()
        try await wait { await gate.isWaiting }
        try await wait { if case .ended = model.state { return true }; return false }
        await gate.release()
        await Task.yield()
        XCTAssertTrue(transports[1].connections.isEmpty)
        XCTAssertFalse(model.hasInteractiveRemoteScreen)
    }

    func testResetAndAccountChangeCancelSuspendedRecovery() async throws {
        for accountChanged in [false, true] {
            let gate = RecoveryLookupGate()
            let notifications = NotificationCenter()
            let (model, transports) = makeModel(notifications: notifications, resolver: { _ in await gate.resolve() })
            defer { model.reset() }
            try await connect(model, transports[0])
            transports[0].loseConnection()
            try await wait { await gate.isWaiting }
            if accountChanged {
                notifications.post(name: NSNotification.Name.CKAccountChanged, object: nil)
            } else {
                model.reset()
            }
            await gate.release()
            await Task.yield()
            XCTAssertTrue(transports[1].connections.isEmpty)
            if accountChanged {
                guard case .ended = model.state else { return XCTFail("Unknown account must end recovery") }
            } else {
                XCTAssertEqual(model.state, .idle)
            }
        }
    }

    func testThreeUnsuccessfulReplacementConnectionsEndRecovery() async throws {
        let (model, transports) = makeModel()
        defer { model.reset() }
        try await connect(model, transports[0])
        transports[0].loseConnection()
        for index in 1...3 {
            try await wait { transports[index].connections.count == 1 }
            transports[index].loseConnection()
        }
        guard case .ended = model.state else { return XCTFail("Recovery must stop after three replacements") }
        XCTAssertTrue(transports[4].connections.isEmpty)
    }

    func testRealSignalingByeOnlyAllowsRecoveryForApplicationShutdown() async throws {
        for reason in ["host_shutdown", "user", "account-change", "protocol", "untrusted"] {
            let channel = RecoveryByeSignaling(reason: reason)
            let transport = WebRTCTransport(signalingFactory: { _, _ in channel }, iceConfigProvider: { .fallback })
            let ended = expectation(description: "Received \(reason) bye")
            transport.onDisconnect = { received in
                XCTAssertEqual(received, reason)
                ended.fulfill()
            }
            try await transport.connect(pairingCode: "123456", expectedHostID: "expected-host")
            await fulfillment(of: [ended], timeout: 1)
            XCTAssertEqual(transport.canReconnectAfterDisconnect, reason == "host_shutdown")
            transport.disconnect(reason: "test-finished")
        }
    }

    func testClosedConnectCannotSendAnOfferAfterLateClaim() async throws {
        let channel = RecoveryClaimSignaling()
        let transport = WebRTCTransport(signalingFactory: { _, _ in channel }, iceConfigProvider: { .fallback })
        let connection = Task { try await transport.connect(pairingCode: "123456", expectedHostID: "expected-host") }
        try await wait { await channel.waiting }
        transport.disconnect(reason: "user")
        await channel.release()
        do {
            try await connection.value
            XCTFail("A closed transport must reject its late claim completion")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        let sentCount = await channel.sentCount
        XCTAssertEqual(sentCount, 0)
    }

    private func makeModel(
        timeout: Duration = .seconds(1),
        notifications: NotificationCenter = NotificationCenter(),
        validator: @escaping SessionModel.LocalAccountBindingValidator = { _ in },
        resolver: @escaping SessionModel.RemoteHostResolver = { _ in "654321" }
    ) -> (SessionModel, [RecoveryTestTransport]) {
        let transports = (0..<5).map { _ in RecoveryTestTransport() }
        var next = 0
        let model = SessionModel(
            initialInputActivity: .active,
            applicationNotificationCenter: NotificationCenter(),
            transportFactory: { defer { next += 1 }; return transports[min(next, transports.count - 1)] },
            localAccountBindingValidator: validator,
            remoteHostResolver: resolver,
            remoteReconnectTimeout: timeout,
            remoteReconnectDelay: .milliseconds(1),
            accountChangeNotificationCenter: notifications)
        return (model, transports)
    }

    private func connect(_ model: SessionModel, _ transport: RecoveryTestTransport) async throws {
        model.connect(code: "123456", computerUseHostID: "expected-host", localCloudAccountBinding: binding)
        try await wait { transport.connections.count == 1 }
        transport.present()
        XCTAssertEqual(model.state, .connected)
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { XCTFail("Recovery condition timed out"); throw RecoveryTestError.unavailable }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private enum RecoveryTestError: Error { case unavailable }

private actor RecoveryByeSignaling: SignalingChannel {
    let reason: String
    private var delivered = false
    init(reason: String) { self.reason = reason }
    func claim() async throws {}
    func send(_ envelope: SignalingEnvelope) async throws {}
    func poll() async throws -> [SignalingEnvelope] {
        guard !delivered else { return [] }
        delivered = true
        return [.init(role: .host, kind: .bye, payload: ["reason": reason], ts: Date().timeIntervalSince1970)]
    }
}

private actor RecoveryClaimSignaling: SignalingChannel {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var sentCount = 0
    var waiting: Bool { continuation != nil }
    func claim() async throws { await withCheckedContinuation { continuation = $0 } }
    func send(_ envelope: SignalingEnvelope) async throws { sentCount += 1 }
    func poll() async throws -> [SignalingEnvelope] { [] }
    func release() { continuation?.resume(); continuation = nil }
}

private actor RecoveryEvents {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor RecoveryValidation {
    let failAt: Int
    var count = 0
    init(failAt: Int) { self.failAt = failAt }
    func validate() throws {
        count += 1
        if count == failAt { throw LocalComputerUseCloudPairingError.accountMismatch }
    }
}

private actor RecoveryLookupGate {
    private var continuation: CheckedContinuation<String?, Never>?
    private var released = false
    var isWaiting: Bool { continuation != nil }
    func resolve() async -> String? {
        if released { return "654321" }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume(returning: "654321")
        continuation = nil
    }
}

@MainActor
private final class RecoveryTestTransport: RemoteSessionRecoveryTransport {
    var onHostHello: (@MainActor (HostHello) -> Void)?
    var onDisplay: (@MainActor (DisplayInfo) -> Void)?
    var onInputUnavailable: (@MainActor () -> Void)?
    var onVideoFrameUnavailable: (@MainActor () -> Void)?
    var onFirstVideoFrame: (@MainActor () -> Void)?
    var onDisconnect: (@MainActor (String) -> Void)?
    var canReconnectAfterDisconnect = false
    var connections: [(code: String, hostID: String?)] = []
    var messages: [ControlMessage] = []

    func connect(pairingCode: String, expectedHostID: String?) async throws {
        connections.append((pairingCode, expectedHostID))
    }
    func send(_ message: ControlMessage, seq: UInt32, ts: UInt64) { messages.append(message) }
    func disconnect(reason: String) {}
    func loseConnection(recoverable: Bool = true) {
        canReconnectAfterDisconnect = recoverable
        onDisconnect?("Test connection closed")
    }
    func present() {
        onHostHello?(HostHello(app: "RemoteDesktop-Mac", version: "1.0", hostname: "Test Mac", os: "macOS", audio: false, monitors: 1))
        onDisplay?(DisplayInfo(w: 800, h: 600, scale: 1))
        onFirstVideoFrame?()
    }
}

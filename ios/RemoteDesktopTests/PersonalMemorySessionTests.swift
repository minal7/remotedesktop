import XCTest
@testable import RemoteDesktop

@MainActor
final class PersonalMemorySessionTests: XCTestCase {
    func testMemoryCandidateFlagRequiresExplicitDebugEnvironmentValue() {
#if DEBUG
        XCTAssertFalse(MemoryFeatureConfiguration.isMemoryV1CandidateEnabled(environment: [:]))
        XCTAssertFalse(MemoryFeatureConfiguration.isMemoryV1CandidateEnabled(environment: [
            MemoryFeatureConfiguration.environmentKey: "0"
        ]))
        XCTAssertTrue(MemoryFeatureConfiguration.isMemoryV1CandidateEnabled(environment: [
            MemoryFeatureConfiguration.environmentKey: "1"
        ]))
#elseif MEMORY_V1_SHIPPING_BETA
        XCTAssertTrue(MemoryFeatureConfiguration.isMemoryV1CandidateEnabled(environment: [:]))
        XCTAssertTrue(MemoryFeatureConfiguration.isMemoryV1CandidateEnabled(environment: [
            MemoryFeatureConfiguration.environmentKey: "0"
        ]))
        XCTAssertTrue(MemoryFeatureConfiguration.isMemoryV1CandidateEnabled(environment: [
            MemoryFeatureConfiguration.environmentKey: "1"
        ]))
#else
        XCTAssertFalse(MemoryFeatureConfiguration.isMemoryV1CandidateEnabled(environment: [:]))
        XCTAssertFalse(MemoryFeatureConfiguration.isMemoryV1CandidateEnabled(environment: [
            MemoryFeatureConfiguration.environmentKey: "0"
        ]))
        XCTAssertFalse(MemoryFeatureConfiguration.isMemoryV1CandidateEnabled(environment: [
            MemoryFeatureConfiguration.environmentKey: "1"
        ]))
#endif
    }

    func testDefaultIsOffAndStartDoesNotReadMemory() async {
        let channel = SessionMemoryChannel()
        let session = makeSession(channel: channel)
        session.start()
        let memory = await channel.memoryReadCount()
        XCTAssertNil(session.ownerMemory)
        XCTAssertEqual(memory, 0)
        session.stop()
    }

    func testEnabledBindsExactChannelWithoutAutomaticRead() async {
        let channel = SessionMemoryChannel()
        let session = makeSession(channel: channel, enabled: true)
        session.start()
        guard let controller = session.ownerMemory else {
            XCTFail("enabled local session should expose its memory controller")
            session.stop()
            return
        }
        let beforeOpen = await channel.memoryReadCount()
        XCTAssertEqual(beforeOpen, 0)
        controller.open()
        let dispatched = await channel.waitForMemoryRead()
        XCTAssertTrue(dispatched)
        let afterOpen = await channel.memoryReadCount()
        XCTAssertEqual(afterOpen, 1)
        session.stop()
    }

    func testPhoneSessionEnablesFreshInitializationOnlyAfterForgetCompletes() async throws {
        let channel = SessionMemoryChannel()
        let session = makeSession(channel: channel, enabled: true)
        session.start()
        guard let controller = session.ownerMemory else {
            XCTFail("the enabled phone session should construct its owner memory controller")
            session.stop()
            return
        }
        controller.open()
        try await waitUntil { controller.state == .ready }
        let token = try XCTUnwrap(controller.beginForgetConfirmation())
        XCTAssertNotNil(controller.confirmForget(token))
        try await waitUntil { controller.forgetCompleted }
        XCTAssertNotNil(controller.beginFreshMemoryConfirmation(),
                        "phone composition explicitly enables the owner-confirmed fresh flow")
        session.stop()
    }

    func testStopInSameTurnCancelsQueuedMemoryActionBeforeDispatch() async {
        let channel = SessionMemoryChannel()
        let session = makeSession(channel: channel, enabled: true)
        session.start()
        guard let controller = session.ownerMemory else {
            XCTFail("enabled local session should expose its memory controller")
            session.stop()
            return
        }
        controller.open()
        session.stop()
        for _ in 0..<8 { await Task.yield() }
        let calls = await channel.memoryReadCount()
        XCTAssertEqual(calls, 0)
        XCTAssertNil(session.ownerMemory)
    }

    func testNonMemoryChannelDoesNotCreateController() {
        let session = makeSession(channel: PlainSessionChannel(), enabled: true)
        session.start()
        XCTAssertNil(session.ownerMemory)
        session.stop()
    }

    func testStopClearsControllerAndRejectsLateReply() async {
        let channel = SessionMemoryChannel(holdMemoryReply: true)
        let session = makeSession(channel: channel, enabled: true)
        session.start()
        guard let oldController = session.ownerMemory else {
            XCTFail("enabled local session should expose its memory controller")
            session.stop()
            return
        }
        oldController.open()
        let dispatched = await channel.waitForMemoryRead()
        XCTAssertTrue(dispatched)
        session.stop()
        XCTAssertNil(session.ownerMemory)
        await channel.completeHeldMemoryRead(with: fictionalRecord)
        await Task.yield()
        XCTAssertNotEqual(oldController.state, .ready)
        XCTAssertTrue(oldController.records.isEmpty)
    }

    func testRestartCreatesFreshControllerAndOldControllerCannotRead() async {
        let channel = SessionMemoryChannel()
        let session = makeSession(channel: channel, enabled: true)
        session.start()
        guard let old = session.ownerMemory else {
            XCTFail("enabled local session should expose its memory controller")
            session.stop()
            return
        }
        session.stop()
        session.start()
        guard let fresh = session.ownerMemory else {
            XCTFail("restart should create a fresh memory controller")
            session.stop()
            return
        }
        XCTAssertFalse(old === fresh)
        old.open()
        await Task.yield()
        let callsAfterOldOpen = await channel.memoryReadCount()
        XCTAssertEqual(callsAfterOldOpen, 0)
        fresh.open()
        let dispatched = await channel.waitForMemoryRead()
        XCTAssertTrue(dispatched)
        let callsAfterFreshOpen = await channel.memoryReadCount()
        XCTAssertEqual(callsAfterFreshOpen, 1)
        session.stop()
    }

    func testUnreadablePendingStoreDoesNotCreateController() {
        let channel = SessionMemoryChannel()
        let session = makeSession(channel: channel, enabled: true, store: FixturePendingStore(failsRead: true))
        session.start()
        XCTAssertNil(session.ownerMemory)
        session.stop()
    }

    private func makeSession(
        channel: any ComputerUseSessionChannel,
        enabled: Bool = false,
        store: any ComputerUsePendingPromptStoring = FixturePendingStore()
    ) -> ComputerUseSessionModel {
        ComputerUseSessionModel(hostName: "fixture", pairingCode: "pairing", hostID: "host",
                                pendingStore: store, channel: channel,
                                ownerMemoryDisplayEnabled: enabled,
                                promptRefreshInterval: .seconds(3_600))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw SessionMemoryChannel.Failure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor SessionMemoryChannel: ComputerUseSessionChannel, PersonalMemoryChannel {
    enum Failure: Error { case timeout }
    private var readCount = 0
    private var heldReply: CheckedContinuation<LocalMemoryRPCReply, Error>?
    private var readWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private let holdMemoryReply: Bool

    init(holdMemoryReply: Bool = false) { self.holdMemoryReply = holdMemoryReply }

    func send(kind: ComputerUseEnvelope.Kind, body: String, to explicitTargetID: String?,
              sessionID explicitSessionID: String?, messageID explicitMessageID: String?) async throws -> ComputerUseEnvelope {
        ComputerUseEnvelope(senderID: "host", targetID: "phone", pairingCode: "pairing",
                             sessionID: explicitSessionID ?? "session", kind: kind, body: body)
    }

    func poll() async throws -> [ComputerUseEnvelope] { [] }
    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {}

    func sendMemoryCommand(_ command: LocalMemoryRPCCommand) async throws -> LocalMemoryRPCReply {
        if command.operation == .captureMemoryGeneration {
            return .init(operation: .captureMemoryGeneration, status: .completed,
                         generationReference: String(repeating: "a", count: 64))
        }
        readCount += 1
        readWaiters.values.forEach { $0.resume(returning: true) }
        readWaiters.removeAll()
        if command.operation == .forgetEverything {
            return .init(operation: .forgetEverything, commandID: command.commandID,
                         status: .completed, generationReference: command.generationReference)
        }
        if holdMemoryReply {
            return try await withCheckedThrowingContinuation { heldReply = $0 }
        }
        return .init(operation: command.operation, status: .completed)
    }

    func memoryReadCount() -> Int { readCount }

    func waitForMemoryRead() async -> Bool {
        if readCount > 0 { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            readWaiters[id] = continuation
            Task {
                try? await Task.sleep(for: .seconds(2))
                self.timeoutReadWaiter(id)
            }
        }
    }

    private func timeoutReadWaiter(_ id: UUID) {
        readWaiters.removeValue(forKey: id)?.resume(returning: false)
    }

    func completeHeldMemoryRead(with record: LocalMemoryRPCRecord) {
        heldReply?.resume(returning: .init(operation: .listRecords, status: .completed, records: [record]))
        heldReply = nil
    }
}

private let fictionalRecord = LocalMemoryRPCRecord(
    recordID: "fictional-1", kind: .fact, text: "Fixture-only fictional preference",
    observedAtMilliseconds: 1, active: true, revision: String(repeating: "a", count: 64),
    source: .ownerMessage)

private struct PlainSessionChannel: ComputerUseSessionChannel {
    func send(kind: ComputerUseEnvelope.Kind, body: String, to explicitTargetID: String?,
              sessionID explicitSessionID: String?, messageID explicitMessageID: String?) async throws -> ComputerUseEnvelope {
        ComputerUseEnvelope(senderID: "host", targetID: "phone", pairingCode: "pairing",
                             sessionID: explicitSessionID ?? "session", kind: kind, body: body)
    }
    func poll() async throws -> [ComputerUseEnvelope] { [] }
    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {}
}

private struct FixturePendingStore: ComputerUsePendingPromptStoring {
    let failsRead: Bool
    init(failsRead: Bool = false) { self.failsRead = failsRead }
    func read(hostID: String, pairingCode: String, localAccountBinding: CloudKitAccountBinding?) throws -> ComputerUsePendingPrompt? {
        if failsRead { throw FixtureStoreError.unreadable }
        return nil
    }
    func readForLocalRecovery(hostID: String, localAccountBinding: CloudKitAccountBinding) throws -> ComputerUsePendingPrompt? { nil }
    func load(hostID: String, pairingCode: String) -> ComputerUsePendingPrompt? { nil }
    func load(hostID: String, pairingCode: String, localAccountBinding: CloudKitAccountBinding?) -> ComputerUsePendingPrompt? { nil }
    func loadForLocalRecovery(hostID: String, localAccountBinding: CloudKitAccountBinding) -> ComputerUsePendingPrompt? { nil }
    func save(_ pending: ComputerUsePendingPrompt) -> Bool { true }
    func remove(ifMatching previous: ComputerUsePendingPrompt) -> ComputerUsePendingPromptMutationResult { .applied }
    func remove(hostID: String) {}
    func remove(hostID: String, localAccountBinding: CloudKitAccountBinding?) {}
}

private enum FixtureStoreError: Error { case unreadable }

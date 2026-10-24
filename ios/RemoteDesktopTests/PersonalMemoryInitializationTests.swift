import XCTest
@testable import RemoteDesktop

@MainActor
final class PersonalMemoryInitializationTests: XCTestCase {
    private let oldReference = String(repeating: "a", count: 64)
    private let newReference = String(repeating: "b", count: 64)

    func testInitializationIsDisabledByDefaultAndWithoutChannel() async {
        let channel = FreshMemoryTestChannel(oldReference: oldReference, newReference: newReference)
        let defaultModel = PersonalMemoryViewModel(enabled: true, channel: channel)
        let missingModel = PersonalMemoryViewModel(enabled: true, channel: nil, allowsInitialization: true)
        XCTAssertNil(defaultModel.beginFreshMemoryConfirmation())
        XCTAssertNil(defaultModel.confirmFreshMemory(UUID()))
        XCTAssertNil(defaultModel.retryFreshMemoryInitialization())
        XCTAssertNil(missingModel.beginFreshMemoryConfirmation())
        XCTAssertNil(missingModel.confirmFreshMemory(UUID()))
        XCTAssertNil(missingModel.retryFreshMemoryInitialization())
        let sent = await channel.commands()
        XCTAssertTrue(sent.isEmpty)
    }

    func testFreshConfirmationRequiresCompletedForgetAndCancelSendsNothing() async throws {
        let channel = FreshMemoryTestChannel(oldReference: oldReference, newReference: newReference)
        let model = makeModel(channel)
        model.open()
        try await wait { model.state == .ready }
        XCTAssertNil(model.beginFreshMemoryConfirmation(), "fresh setup is available only after Forget completes")
        let forgetID = try await completeForget(model)

        let token = try XCTUnwrap(model.beginFreshMemoryConfirmation())
        XCTAssertNil(model.confirmFreshMemory(UUID()))
        model.cancelFreshMemoryConfirmation(token)
        XCTAssertNil(model.confirmFreshMemory(token))
        XCTAssertNil(model.initializationCommandID)
        XCTAssertFalse(model.initializationInProgress)
        XCTAssertFalse(model.initializationCompleted)
        let commands = await channel.commands()
        XCTAssertEqual(commands.filter { $0.operation == .forgetEverything }.map(\.commandID), [forgetID])
        XCTAssertFalse(commands.contains { $0.operation == .initializeMemoryGeneration })
    }

    func testVerifiedAbsentShowsExplicitStartFreshAndNeverInitializesAutomatically() async throws {
        let channel = FreshMemoryTestChannel(oldReference: oldReference, newReference: newReference)
        await channel.enqueue(.listRecords, .verifiedAbsent)
        let model = makeModel(channel)
        model.open()
        try await wait {
            model.verifiedAbsentNeedsInitialization && model.generationReference != nil
                && model.state == .ready
        }

        XCTAssertFalse(model.forgetCompleted, "Host absence is not a local Forget receipt")
        XCTAssertTrue(model.canBeginFreshMemory)
        XCTAssertFalse(model.canBeginRemember, "Do not advertise Save before a store exists")
        XCTAssertTrue(model.records.isEmpty)
        let token = try XCTUnwrap(model.beginFreshMemoryConfirmation())
        model.cancelFreshMemoryConfirmation(token)
        XCTAssertNil(model.initializationCommandID)
        let cancelledCommands = await channel.commands()
        XCTAssertFalse(cancelledCommands.contains {
            $0.operation == .initializeMemoryGeneration
        }, "Verified absence never initializes without explicit confirmation")
        XCTAssertFalse(cancelledCommands.contains { $0.operation == .forgetEverything },
                       "Cancelling Start Fresh must not issue the empty-store Forget")

        let secondToken = try XCTUnwrap(model.beginFreshMemoryConfirmation())
        let explicitForgetID = try XCTUnwrap(model.confirmFreshMemory(secondToken))
        try await wait { model.initializationCompleted }
        let confirmedCommands = await channel.commands()
        let emptyForget = try XCTUnwrap(confirmedCommands.first {
            $0.operation == .forgetEverything
        })
        XCTAssertEqual(emptyForget.commandID, explicitForgetID)
        XCTAssertEqual(emptyForget.generationReference, oldReference)
        let initialize = try XCTUnwrap(confirmedCommands.last {
            $0.operation == .initializeMemoryGeneration
        })
        XCTAssertNotEqual(initialize.commandID, explicitForgetID)
        XCTAssertEqual(initialize.generationReference, oldReference)

        let malformed = LocalMemoryRPCReply(operation: .listRecords, status: .initializationRequired,
            records: [record("unexpected-record")])
        XCTAssertThrowsError(try PersonalMemoryReplyValidator.verifiedAbsent(malformed,
            command: LocalMemoryRPCCommand(listRecords: 20)))
    }

    func testConfirmedFreshInitializationPinsOldReferenceAndClearsContentImmediately() async throws {
        let channel = FreshMemoryTestChannel(oldReference: oldReference, newReference: newReference)
        await channel.enqueue(.initializeMemoryGeneration, .suspend)
        let row = record("private-row")
        await channel.enqueue(.searchRecords, .page([row]))
        let model = makeModel(channel)
        model.open(query: "private query")
        try await wait { model.records.count == 1 && model.generationReference != nil }
        let forgetID = try await completeForget(model)

        let token = try XCTUnwrap(model.beginFreshMemoryConfirmation())
        let initializeID = try XCTUnwrap(model.confirmFreshMemory(token))
        XCTAssertEqual(initializeID, initializeID.lowercased())
        XCTAssertNotEqual(initializeID, forgetID)
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertEqual(model.query, "")
        XCTAssertNil(model.draftText)
        XCTAssertNil(model.mutationReceipt)
        XCTAssertEqual(model.initializationCommandID, initializeID)
        XCTAssertEqual(model.initializationSourceReference, oldReference)
        XCTAssertTrue(model.initializationInProgress)
        XCTAssertFalse(model.initializationCompleted)
        XCTAssertNil(model.retryFreshMemoryInitialization(), "an active request is never duplicated")

        do { try await wait { await channel.commands().contains { $0.operation == .initializeMemoryGeneration } } }
        catch { await channel.release(.failure); throw error }
        await channel.release(.success)
        try await wait { model.initializationCompleted }
        XCTAssertEqual(model.replacementGenerationReference, newReference)
        XCTAssertTrue(model.records.isEmpty, "success does not query the new generation")
        let allCommands = await channel.commands()
        let initCommand = try XCTUnwrap(allCommands.last(where: {
            $0.operation == .initializeMemoryGeneration
        }))
        XCTAssertEqual(initCommand.commandID, initializeID)
        XCTAssertEqual(initCommand.generationReference, oldReference)
    }

    func testMalformedOrMismatchedReceiptNeverShowsFreshMemoryReady() async throws {
        for action in [FreshMemoryTestChannel.Action.missingReplacement,
                       .sameReplacement, .wrongSource, .wrongCommand, .withData] {
            let channel = FreshMemoryTestChannel(oldReference: oldReference, newReference: newReference)
            await channel.enqueue(.initializeMemoryGeneration, action)
            let model = makeModel(channel)
            model.open()
            try await wait { model.state == .ready }
            _ = try await completeForget(model)
            let token = try XCTUnwrap(model.beginFreshMemoryConfirmation())
            let id = try XCTUnwrap(model.confirmFreshMemory(token))
            try await wait { !model.initializationInProgress && model.errorMessage != nil }
            XCTAssertFalse(model.initializationCompleted)
            XCTAssertNil(model.replacementGenerationReference)
            XCTAssertEqual(model.initializationCommandID, id)
            let sent = await channel.commands()
            let request = try XCTUnwrap(sent.last(where: {
                $0.operation == .initializeMemoryGeneration
            }))
            XCTAssertEqual(request.commandID, id)
            XCTAssertEqual(request.generationReference, oldReference)
        }
    }

    func testFailureRetainsExactInitializationIdentityForExplicitRetry() async throws {
        let channel = FreshMemoryTestChannel(oldReference: oldReference, newReference: newReference)
        await channel.enqueue(.initializeMemoryGeneration, .failure)
        let model = makeModel(channel)
        model.open()
        try await wait { model.state == .ready }
        _ = try await completeForget(model)
        let token = try XCTUnwrap(model.beginFreshMemoryConfirmation())
        let originalID = try XCTUnwrap(model.confirmFreshMemory(token))
        try await wait { !model.initializationInProgress && model.errorMessage != nil }
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertFalse(model.initializationCompleted)
        let failedCommands = await channel.commands()
        XCTAssertEqual(failedCommands.filter { $0.operation == .initializeMemoryGeneration }.count, 1,
                       "failed fresh setup is never retried automatically")

        XCTAssertEqual(model.retryFreshMemoryInitialization(), originalID)
        try await wait { model.initializationCompleted }
        let commands = await channel.commands().filter { $0.operation == .initializeMemoryGeneration }
        XCTAssertEqual(commands.map(\.commandID), [originalID, originalID])
        XCTAssertEqual(commands.map(\.generationReference), [oldReference, oldReference])
        XCTAssertEqual(model.replacementGenerationReference, newReference)
    }

    func testTimeoutAndCloseRetainOnlyExactRequestForExplicitRetry() async throws {
        let channel = FreshMemoryTestChannel(oldReference: oldReference, newReference: newReference)
        await channel.enqueue(.initializeMemoryGeneration, .suspend)
        await channel.enqueue(.initializeMemoryGeneration, .success)
        let model = makeModel(channel, timeout: .milliseconds(35))
        model.open()
        try await wait { model.state == .ready }
        _ = try await completeForget(model)
        let token = try XCTUnwrap(model.beginFreshMemoryConfirmation())
        let id = try XCTUnwrap(model.confirmFreshMemory(token))
        do { try await wait { !model.initializationInProgress && model.errorMessage != nil } }
        catch { await channel.release(.failure); throw error }
        XCTAssertEqual(model.initializationCommandID, id)
        XCTAssertEqual(model.initializationSourceReference, oldReference)
        model.close()
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertEqual(model.initializationCommandID, id)
        XCTAssertFalse(model.initializationCompleted)
        await channel.release(.success)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(model.initializationCompleted, "late pre-close success cannot revive the screen")

        XCTAssertEqual(model.retryFreshMemoryInitialization(), id)
        try await wait { model.initializationCompleted }
        let commands = await channel.commands().filter { $0.operation == .initializeMemoryGeneration }
        XCTAssertEqual(commands.map(\.commandID), [id, id])
        XCTAssertEqual(commands.map(\.generationReference), [oldReference, oldReference])
    }

    func testDisconnectInvalidatesPendingInitializationAndItsLateReply() async throws {
        let channel = FreshMemoryTestChannel(oldReference: oldReference, newReference: newReference)
        await channel.enqueue(.initializeMemoryGeneration, .suspend)
        let model = makeModel(channel)
        model.open()
        try await wait { model.state == .ready }
        _ = try await completeForget(model)
        let token = try XCTUnwrap(model.beginFreshMemoryConfirmation())
        _ = try XCTUnwrap(model.confirmFreshMemory(token))
        do { try await wait { await channel.commands().contains { $0.operation == .initializeMemoryGeneration } } }
        catch { await channel.release(.failure); throw error }
        model.disconnect()
        await channel.release(.success)
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertNil(model.initializationCommandID)
        XCTAssertNil(model.initializationSourceReference)
        XCTAssertNil(model.replacementGenerationReference)
        XCTAssertFalse(model.initializationCompleted)
        XCTAssertNil(model.retryFreshMemoryInitialization())
    }

    func testCompletedFreshInitializationRefusesSameSessionReads() async throws {
        let channel = FreshMemoryTestChannel(oldReference: oldReference, newReference: newReference)
        let model = makeModel(channel)
        model.open()
        try await wait { model.state == .ready }
        _ = try await completeForget(model)
        let token = try XCTUnwrap(model.beginFreshMemoryConfirmation())
        _ = try XCTUnwrap(model.confirmFreshMemory(token))
        try await wait { model.initializationCompleted }
        model.open()
        model.reload()
        model.loadMore()
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(model.records.isEmpty)
        let commands = await channel.commands()
        XCTAssertEqual(commands.map(\.operation),
                       [.listRecords, .captureMemoryGeneration, .forgetEverything,
                        .initializeMemoryGeneration])
    }

    private func makeModel(_ channel: FreshMemoryTestChannel,
                           timeout: Duration = .seconds(18)) -> PersonalMemoryViewModel {
        PersonalMemoryViewModel(enabled: true, channel: channel, allowsInitialization: true,
                                requestTimeout: timeout)
    }

    private func completeForget(_ model: PersonalMemoryViewModel) async throws -> String {
        let token = try XCTUnwrap(model.beginForgetConfirmation())
        let id = try XCTUnwrap(model.confirmForget(token))
        try await wait { model.forgetCompleted }
        return id
    }

    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw FreshMemoryTestChannel.Failure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func record(_ id: String) -> LocalMemoryRPCRecord {
        LocalMemoryRPCRecord(recordID: id, kind: .fact, text: "Synthetic owner fact",
            observedAtMilliseconds: 1_800_000_000_000, active: true,
            revision: String(repeating: "0", count: 64), source: .ownerMessage)
    }
}

private actor FreshMemoryTestChannel: PersonalMemoryChannel {
    enum Failure: Error { case request, timeout }
    enum Action: Sendable {
        case success, page([LocalMemoryRPCRecord]), verifiedAbsent, capture, failure, suspend
        case missingReplacement, sameReplacement, wrongSource, wrongCommand, withData
    }
    private let oldReference: String
    private let newReference: String
    private var queued: [(LocalMemoryRPCCommand.Operation, Action)] = []
    private var received: [LocalMemoryRPCCommand] = []
    private var continuation: CheckedContinuation<Action, Never>?

    init(oldReference: String, newReference: String) {
        self.oldReference = oldReference
        self.newReference = newReference
    }

    func enqueue(_ operation: LocalMemoryRPCCommand.Operation, _ action: Action) {
        queued.append((operation, action))
    }
    func commands() -> [LocalMemoryRPCCommand] { received }
    func release(_ action: Action) { continuation?.resume(returning: action); continuation = nil }

    func sendMemoryCommand(_ command: LocalMemoryRPCCommand) async throws -> LocalMemoryRPCReply {
        received.append(command)
        var action: Action
        if let index = queued.firstIndex(where: { $0.0 == command.operation }) {
            action = queued.remove(at: index).1
        } else {
            action = defaultAction(command)
        }
        if case .suspend = action {
            action = await withCheckedContinuation { continuation = $0 }
        }
        switch (command.operation, action) {
        case (.listRecords, .verifiedAbsent), (.searchRecords, .verifiedAbsent):
            return LocalMemoryRPCReply(operation: command.operation,
                status: .initializationRequired)
        case (.listRecords, .page(let records)), (.searchRecords, .page(let records)):
            return LocalMemoryRPCReply(operation: command.operation, status: .completed, records: records)
        case (.captureMemoryGeneration, .capture):
            return LocalMemoryRPCReply(operation: command.operation, status: .completed,
                                       generationReference: oldReference)
        case (.forgetEverything, .success):
            return LocalMemoryRPCReply(operation: command.operation, commandID: command.commandID,
                status: .completed, generationReference: command.generationReference)
        case (.initializeMemoryGeneration, .success):
            return LocalMemoryRPCReply(operation: command.operation, commandID: command.commandID,
                status: .completed, generationReference: command.generationReference,
                replacementGenerationReference: newReference)
        case (.initializeMemoryGeneration, .missingReplacement):
            return LocalMemoryRPCReply(operation: command.operation, commandID: command.commandID,
                status: .completed, generationReference: command.generationReference)
        case (.initializeMemoryGeneration, .sameReplacement):
            return LocalMemoryRPCReply(operation: command.operation, commandID: command.commandID,
                status: .completed, generationReference: command.generationReference,
                replacementGenerationReference: command.generationReference)
        case (.initializeMemoryGeneration, .wrongSource):
            return LocalMemoryRPCReply(operation: command.operation, commandID: command.commandID,
                status: .completed, generationReference: String(repeating: "c", count: 64),
                replacementGenerationReference: newReference)
        case (.initializeMemoryGeneration, .wrongCommand):
            return LocalMemoryRPCReply(operation: command.operation,
                commandID: "22345678-abcd-4abc-8def-1234567890ab", status: .completed,
                generationReference: command.generationReference,
                replacementGenerationReference: newReference)
        case (.initializeMemoryGeneration, .withData):
            return LocalMemoryRPCReply(operation: command.operation, commandID: command.commandID,
                status: .completed, records: [LocalMemoryRPCRecord(recordID: "leaked", kind: .fact,
                    text: "Synthetic", observedAtMilliseconds: 1, active: true,
                    revision: String(repeating: "0", count: 64), source: .ownerMessage)],
                generationReference: command.generationReference,
                replacementGenerationReference: newReference)
        case (_, .failure): throw Failure.request
        default: throw Failure.request
        }
    }

    private func defaultAction(_ command: LocalMemoryRPCCommand) -> Action {
        switch command.operation {
        case .listRecords, .searchRecords: .page([])
        case .captureMemoryGeneration: .capture
        case .remember, .confirmProposal, .listMetadata, .deleteMetadata, .editRecord: .failure
        case .forgetEverything, .initializeMemoryGeneration: .success
        }
    }
}

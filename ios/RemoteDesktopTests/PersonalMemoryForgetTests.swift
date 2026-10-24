import XCTest
@testable import RemoteDesktop

@MainActor
final class PersonalMemoryForgetTests: XCTestCase {
    func testConfirmationTokenIsRequiredAndCancelledTokenCannotDispatch() async throws {
        let channel = ForgetTestChannel()
        await channel.enqueue(.page([]))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.state == .ready }

        let token = try XCTUnwrap(model.beginForgetConfirmation())
        XCTAssertNil(model.confirmForget(UUID()))
        model.cancelForgetConfirmation(token)
        XCTAssertNil(model.confirmForget(token))
        try await Task.sleep(for: .milliseconds(20))
        let commands = await channel.commands()
        XCTAssertEqual(commands.map(\.operation), [.listRecords])
        XCTAssertFalse(model.forgetCompleted)
    }

    func testEditOrDeleteInFlightPreventsStartingConfirmation() async throws {
        let channel = ForgetTestChannel()
        let visible = record("fact-a")
        await channel.enqueue(.page([visible]))
        await channel.enqueue(.suspend)
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.records.count == 1 }
        model.edit(record: visible, text: "Edited")
        do { try await wait { await channel.commands().count == 2 } }
        catch { await channel.release(.failure); throw error }
        XCTAssertNil(model.beginForgetConfirmation())
        await channel.release(.failure)
        try await Task.sleep(for: .milliseconds(20))
        let commands = await channel.commands()
        XCTAssertEqual(commands.map(\.operation), [.listRecords, .editRecord])
    }

    func testConfirmationInvalidatesOnCloseAndDisconnect() async throws {
        for disconnect in [false, true] {
            let channel = ForgetTestChannel()
            await channel.enqueue(.page([]))
            let model = PersonalMemoryViewModel(enabled: true, channel: channel)
            model.open()
            try await wait { model.state == .ready }
            let token = try XCTUnwrap(model.beginForgetConfirmation())
            if disconnect { model.disconnect() } else { model.close() }
            XCTAssertNil(model.confirmForget(token))
            try await Task.sleep(for: .milliseconds(20))
            let commands = await channel.commands()
            XCTAssertEqual(commands.map(\.operation), [.listRecords])
        }
    }

    func testConfirmClearsDisplayedOwnerStateImmediatelyAndBlocksReadsAndWrites() async throws {
        let channel = ForgetTestChannel()
        let visible = record("fact-a")
        await channel.enqueue(.page([visible]))
        await channel.enqueue(.suspend)
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open(query: "private query")
        try await wait { model.records.count == 1 }

        let token = try XCTUnwrap(model.beginForgetConfirmation())
        let commandID = try XCTUnwrap(model.confirmForget(token))
        XCTAssertNil(model.confirmForget(token), "a confirmation token is single use")
        XCTAssertEqual(commandID, commandID.lowercased())
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertEqual(model.query, "")
        XCTAssertNil(model.draftText)
        XCTAssertNil(model.mutationReceipt)
        XCTAssertTrue(model.forgetInProgress)
        XCTAssertFalse(model.forgetCompleted)

        model.open(query: "new query")
        model.reload()
        model.loadMore()
        XCTAssertNil(model.edit(record: visible, text: "No"))
        XCTAssertNil(model.delete(record: visible))
        do { try await wait { await channel.commands().count == 2 } }
        catch { await channel.release(.failure); throw error }
        let commands = await channel.commands()
        XCTAssertEqual(commands.map(\.operation), [.searchRecords, .forgetEverything])
        await channel.release(.success)
    }

    func testExactEmptyReceiptCompletesWithoutReloadOrStaleRows() async throws {
        let channel = ForgetTestChannel()
        await channel.enqueue(.page([record("private-row")]))
        await channel.enqueue(.success)
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.records.count == 1 }
        let token = try XCTUnwrap(model.beginForgetConfirmation())
        let commandID = try XCTUnwrap(model.confirmForget(token))
        try await wait { model.forgetCompleted }
        XCTAssertFalse(model.forgetInProgress)
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertEqual(model.state, .unavailable)
        let commands = await channel.commands()
        XCTAssertEqual(commands.map(\.operation), [.listRecords, .forgetEverything])
        XCTAssertEqual(commands.last?.commandID, commandID)
    }

    func testFailureRetainsSameCommandForExplicitRetryOnly() async throws {
        let channel = ForgetTestChannel()
        await channel.enqueue(.page([]))
        await channel.enqueue(.failure)
        await channel.enqueue(.success)
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.state == .ready }
        let token = try XCTUnwrap(model.beginForgetConfirmation())
        let originalID = try XCTUnwrap(model.confirmForget(token))
        try await wait { model.errorMessage != nil && !model.forgetInProgress }
        try await Task.sleep(for: .milliseconds(30))
        let afterFailure = await channel.commands()
        XCTAssertEqual(afterFailure.map(\.operation), [.listRecords, .forgetEverything],
            "failure must never trigger automatic retry")

        XCTAssertEqual(model.retryForget(), originalID)
        try await wait { model.forgetCompleted }
        let commands = await channel.commands()
        XCTAssertEqual(commands.map(\.operation), [.listRecords, .forgetEverything, .forgetEverything])
        XCTAssertEqual(commands.map(\.commandID), [nil, originalID, originalID])
    }

    func testTimeoutRetainsExactCommandIDUntilExplicitRetry() async throws {
        let channel = ForgetTestChannel()
        await channel.enqueue(.page([]))
        await channel.enqueue(.suspend)
        await channel.enqueue(.success)
        let model = PersonalMemoryViewModel(enabled: true, channel: channel,
                                            requestTimeout: .milliseconds(40))
        model.open()
        try await wait { model.state == .ready }
        let token = try XCTUnwrap(model.beginForgetConfirmation())
        let originalID = try XCTUnwrap(model.confirmForget(token))
        do { try await wait { !model.forgetInProgress && model.errorMessage != nil } }
        catch { await channel.release(.failure); throw error }
        XCTAssertEqual(model.forgetCommandID, originalID)
        let afterTimeout = await channel.commands()
        XCTAssertEqual(afterTimeout.map(\.operation), [.listRecords, .forgetEverything])
        XCTAssertEqual(model.retryForget(), originalID)
        do { try await wait { model.forgetCompleted } }
        catch { await channel.release(.failure); throw error }
        let commands = await channel.commands()
        XCTAssertEqual(commands.map(\.operation), [.listRecords, .forgetEverything, .forgetEverything])
        XCTAssertEqual(commands.map(\.commandID), [nil, originalID, originalID])
        await channel.release(.success)
    }

    func testMalformedReceiptsNeverReportForgetSuccess() async throws {
        for response in [ForgetTestChannel.Action.wrongCommand, .wrongOperation, .withData] {
            let channel = ForgetTestChannel()
            await channel.enqueue(.page([]))
            await channel.enqueue(response)
            let model = PersonalMemoryViewModel(enabled: true, channel: channel)
            model.open()
            try await wait { model.state == .ready }
            let token = try XCTUnwrap(model.beginForgetConfirmation())
            _ = model.confirmForget(token)
            try await wait { !model.forgetInProgress && model.errorMessage != nil }
            XCTAssertFalse(model.forgetCompleted)
            XCTAssertTrue(model.records.isEmpty)
        }
    }

    func testCloseOrDisconnectSuppressesLateSuccessAndClearsForgetStatus() async throws {
        let channel = ForgetTestChannel()
        await channel.enqueue(.page([]))
        await channel.enqueue(.suspend)
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.state == .ready }
        let token = try XCTUnwrap(model.beginForgetConfirmation())
        _ = model.confirmForget(token)
        do { try await wait { await channel.commands().count == 2 } }
        catch { await channel.release(.failure); throw error }
        let commandID = model.forgetCommandID
        model.close()
        await channel.release(.success)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(model.forgetCompleted)
        XCTAssertFalse(model.forgetInProgress)
        XCTAssertEqual(model.forgetCommandID, commandID,
            "closing after dispatch preserves only the value-free retry identity")
        XCTAssertNil(model.forgetConfirmationToken)
        XCTAssertEqual(model.state, .unavailable)

        model.disconnect()
        XCTAssertNil(model.forgetCommandID,
            "disconnect ends the session that owns the retry identity")
    }

    func testCloseAfterDispatchRequiresExplicitSameCommandRetryWithoutOwnerText() async throws {
        let channel = ForgetTestChannel()
        await channel.enqueue(.page([]))
        await channel.enqueue(.suspend)
        await channel.enqueue(.success)
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.state == .ready }
        let token = try XCTUnwrap(model.beginForgetConfirmation())
        let commandID = try XCTUnwrap(model.confirmForget(token))
        do { try await wait { await channel.commands().count == 2 } }
        catch { await channel.release(.failure); throw error }

        model.close()
        XCTAssertEqual(model.forgetCommandID, commandID)
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertEqual(model.query, "")
        XCTAssertNil(model.draftText)
        XCTAssertNil(model.mutationReceipt)
        model.open()
        try await Task.sleep(for: .milliseconds(25))
        let afterOpen = await channel.commands()
        XCTAssertEqual(afterOpen.map(\.operation), [.listRecords, .forgetEverything],
            "reopen never automatically resends Forget or reloads owner data")

        await channel.release(.success)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(model.forgetCompleted,
            "the closed view does not publish a late completion")
        XCTAssertEqual(model.retryForget(), commandID)
        try await wait { model.forgetCompleted }
        let commands = await channel.commands()
        XCTAssertEqual(commands.map(\.operation), [.listRecords, .forgetEverything, .forgetEverything])
        XCTAssertEqual(commands.map(\.commandID), [nil, commandID, commandID])
        XCTAssertTrue(model.records.isEmpty)
    }

    func testCompletedForgetRefusesFurtherReadsUntilNewSession() async throws {
        let channel = ForgetTestChannel()
        await channel.enqueue(.page([]))
        await channel.enqueue(.success)
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.state == .ready }
        let token = try XCTUnwrap(model.beginForgetConfirmation())
        _ = model.confirmForget(token)
        try await wait { model.forgetCompleted }
        model.open()
        model.reload()
        model.loadMore()
        try await Task.sleep(for: .milliseconds(25))
        let commands = await channel.commands()
        XCTAssertEqual(commands.map(\.operation), [.listRecords, .forgetEverything])
        XCTAssertTrue(model.forgetCompleted)
    }

    func testDisabledAndMissingChannelRefuseAllForgetActions() async throws {
        let channel = ForgetTestChannel()
        let disabled = PersonalMemoryViewModel(enabled: false, channel: channel)
        XCTAssertNil(disabled.beginForgetConfirmation())
        XCTAssertNil(disabled.confirmForget(UUID()))
        XCTAssertNil(disabled.retryForget())

        let unavailable = PersonalMemoryViewModel(enabled: true, channel: nil)
        XCTAssertNil(unavailable.beginForgetConfirmation())
        XCTAssertNil(unavailable.confirmForget(UUID()))
        XCTAssertNil(unavailable.retryForget())
        let commands = await channel.commands()
        XCTAssertTrue(commands.isEmpty)
    }

    func testDisconnectDuringForgetClearsRetryIdentityAndSuppressesLateSuccess() async throws {
        let channel = ForgetTestChannel()
        await channel.enqueue(.page([]))
        await channel.enqueue(.suspend)
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.state == .ready }
        let token = try XCTUnwrap(model.beginForgetConfirmation())
        _ = model.confirmForget(token)
        do { try await wait { await channel.commands().count == 2 } }
        catch { await channel.release(.failure); throw error }
        model.disconnect()
        XCTAssertNil(model.forgetCommandID)
        await channel.release(.success)
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertFalse(model.forgetCompleted)
        XCTAssertNil(model.forgetCommandID)
        let commands = await channel.commands()
        XCTAssertEqual(commands.map(\.operation), [.listRecords, .forgetEverything])
    }

    func testOwnerCanExplicitlyForgetAfterInitialReadFails() async throws {
        let channel = ForgetTestChannel()
        await channel.enqueue(.failure)
        await channel.enqueue(.success)
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { if case .error = model.state { return true }; return false }
        let token = try XCTUnwrap(model.beginForgetConfirmation())
        let commandID = try XCTUnwrap(model.confirmForget(token))
        try await wait { model.forgetCompleted }
        let commands = await channel.commands()
        XCTAssertEqual(commands.map(\.operation), [.listRecords, .forgetEverything])
        XCTAssertEqual(commands.map(\.commandID), [nil, commandID])
    }

    func testOpenAndReloadDuringPendingForgetPreserveProgressWithoutExtraRequests() async throws {
        let channel = ForgetTestChannel()
        await channel.enqueue(.page([]))
        await channel.enqueue(.suspend)
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.state == .ready }
        let token = try XCTUnwrap(model.beginForgetConfirmation())
        _ = model.confirmForget(token)
        do { try await wait { await channel.commands().count == 2 } }
        catch { await channel.release(.failure); throw error }
        model.open(query: "ignored")
        model.reload(query: "also ignored")
        XCTAssertEqual(model.state, .loading)
        XCTAssertTrue(model.forgetInProgress)
        XCTAssertEqual(model.query, "")
        let beforeRelease = await channel.commands()
        XCTAssertEqual(beforeRelease.map(\.operation), [.listRecords, .forgetEverything])
        await channel.release(.success)
        try await wait { model.forgetCompleted }
    }

    func testGenerationCaptureFailurePreventsConfirmationAndForget() async throws {
        let channel = ForgetTestChannel()
        await channel.enqueue(.failure)
        await channel.enqueueGeneration(.failure)
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { if case .error = model.state { return true }; return false }
        XCTAssertNil(model.beginForgetConfirmation())
        XCTAssertNil(model.generationReference)
        let all = await channel.allCommands()
        XCTAssertEqual(all.map(\.operation), [.listRecords, .captureMemoryGeneration])
        XCTAssertTrue(model.records.isEmpty)
    }

    func testMalformedOrMissingGenerationReferenceReceiptCannotCompleteForget() async throws {
        for response in [ForgetTestChannel.Action.missingGeneration, .malformedGeneration,
                         .wrongForgetGeneration] {
            let channel = ForgetTestChannel()
            await channel.enqueue(.page([]))
            await channel.enqueue(response)
            let model = PersonalMemoryViewModel(enabled: true, channel: channel)
            model.open()
            try await wait { model.state == .ready }
            XCTAssertNotNil(model.generationReference)
            let reference = model.generationReference ?? String(repeating: "a", count: 64)
            let token = try XCTUnwrap(model.beginForgetConfirmation())
            let commandID = try XCTUnwrap(model.confirmForget(token))
            try await wait { !model.forgetInProgress && model.errorMessage != nil }
            XCTAssertFalse(model.forgetCompleted)
            let all = await channel.allCommands()
            let forget = try XCTUnwrap(all.last(where: {
                $0.operation == .forgetEverything
            }))
            XCTAssertEqual(forget.commandID, commandID)
            XCTAssertEqual(forget.generationReference, reference)
        }
    }

    func testExplicitRetryKeepsOriginalCapturedGenerationReference() async throws {
        let channel = ForgetTestChannel()
        await channel.enqueue(.page([]))
        await channel.enqueue(.failure)
        await channel.enqueue(.success)
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.state == .ready }
        XCTAssertNotNil(model.generationReference)
        let captured = model.generationReference ?? String(repeating: "a", count: 64)
        let token = try XCTUnwrap(model.beginForgetConfirmation())
        let commandID = try XCTUnwrap(model.confirmForget(token))
        try await wait { !model.forgetInProgress && model.errorMessage != nil }

        await channel.setGenerationReference(String(repeating: "b", count: 64))
        XCTAssertEqual(model.retryForget(), commandID)
        try await wait { model.forgetCompleted }
        let forgets = await channel.allCommands().filter { $0.operation == .forgetEverything }
        XCTAssertEqual(forgets.count, 2)
        XCTAssertEqual(forgets.map(\.commandID), [commandID, commandID])
        XCTAssertEqual(forgets.map(\.generationReference), [captured, captured])
    }

    func testLateGenerationCaptureAfterCloseCannotEnableForgetOrReviveState() async throws {
        let channel = ForgetTestChannel()
        await channel.enqueue(.failure)
        await channel.enqueueGeneration(.suspend)
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait {
            let count = await channel.allCommands().count
            if count == 2 { return true }
            if case .error = model.state { return true }
            return false
        }
        model.close()
        await channel.release(.generation(String(repeating: "a", count: 64)))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.state, .unavailable)
        XCTAssertNil(model.generationReference)
        XCTAssertNil(model.beginForgetConfirmation())
        let all = await channel.allCommands()
        XCTAssertEqual(all.map(\.operation), [.listRecords, .captureMemoryGeneration])
    }

    func testMalformedCaptureBlocksForgetEvenAfterListSucceeds() async throws {
        let channel = ForgetTestChannel()
        await channel.enqueueGeneration(.malformedGeneration)
        await channel.enqueue(.page([record("must-not-load")]))
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait {
            if case .error = model.state { return true }
            return model.state == .ready
        }
        XCTAssertEqual(model.state, .ready,
            "ordinary listed records remain available when generation metadata cannot be captured")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.records.map(\.recordID), ["must-not-load"])
        XCTAssertNil(model.generationReference)
        XCTAssertNil(model.beginForgetConfirmation())
        let all = await channel.allCommands()
        XCTAssertEqual(all.map(\.operation), [.listRecords, .captureMemoryGeneration])
    }

    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw ForgetTestChannel.Failure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func record(_ id: String) -> LocalMemoryRPCRecord {
        LocalMemoryRPCRecord(recordID: id, kind: .fact, text: "Synthetic private fact",
            observedAtMilliseconds: 1_800_000_000_000, active: true,
            revision: String(repeating: "0", count: 64), source: .ownerMessage)
    }
}

private actor ForgetTestChannel: PersonalMemoryChannel {
    enum Failure: Error { case requested, timeout }
    enum Action: Sendable {
        case success
        case page([LocalMemoryRPCRecord])
        case suspend
        case generation(String)
        case missingGeneration
        case malformedGeneration
        case wrongForgetGeneration
        case wrongCommand
        case wrongOperation
        case withData
        case failure
    }
    private var actions: [Action] = []
    private var generationActions: [Action] = []
    private var reference = String(repeating: "a", count: 64)
    private var received: [LocalMemoryRPCCommand] = []
    private var continuation: CheckedContinuation<Action, Never>?

    func enqueue(_ action: Action) { actions.append(action) }
    func enqueueGeneration(_ action: Action) { generationActions.append(action) }
    func setGenerationReference(_ value: String) { reference = value }
    func release(_ action: Action) { continuation?.resume(returning: action); continuation = nil }
    func commands() -> [LocalMemoryRPCCommand] {
        received.filter { $0.operation != .captureMemoryGeneration }
    }
    func allCommands() -> [LocalMemoryRPCCommand] { received }

    func sendMemoryCommand(_ command: LocalMemoryRPCCommand) async throws -> LocalMemoryRPCReply {
        received.append(command)
        if command.operation == .captureMemoryGeneration {
            let action = generationActions.isEmpty ? Action.generation(reference) : generationActions.removeFirst()
            let response: Action
            if case .suspend = action {
                response = await withCheckedContinuation { continuation = $0 }
            } else {
                response = action
            }
            switch response {
            case .generation(let value):
                return LocalMemoryRPCReply(operation: .captureMemoryGeneration, status: .completed,
                                           generationReference: value)
            case .missingGeneration:
                return LocalMemoryRPCReply(operation: .captureMemoryGeneration, status: .completed)
            case .malformedGeneration:
                return LocalMemoryRPCReply(operation: .captureMemoryGeneration, status: .completed,
                                           generationReference: "BAD")
            case .failure: throw Failure.requested
            default: throw Failure.requested
            }
        }
        guard !actions.isEmpty else { throw Failure.requested }
        var action = actions.removeFirst()
        if case .suspend = action {
            action = await withCheckedContinuation { continuation = $0 }
        }
        switch action {
        case .success:
            return LocalMemoryRPCReply(operation: command.operation, commandID: command.commandID,
                status: .completed, generationReference: command.generationReference)
        case .page(let records):
            return LocalMemoryRPCReply(operation: command.operation, status: .completed, records: records)
        case .wrongCommand:
            return LocalMemoryRPCReply(operation: .forgetEverything, commandID: UUID().uuidString.lowercased(),
                status: .completed, generationReference: command.generationReference)
        case .wrongOperation:
            return LocalMemoryRPCReply(operation: .listRecords, commandID: command.commandID,
                                       status: .completed)
        case .withData:
            return LocalMemoryRPCReply(operation: .forgetEverything, commandID: command.commandID,
                status: .completed, records: [LocalMemoryRPCRecord(recordID: "leak", kind: .fact,
                    text: "Synthetic", observedAtMilliseconds: 1, active: true,
                    revision: String(repeating: "0", count: 64), source: .ownerMessage)],
                generationReference: command.generationReference)
        case .wrongForgetGeneration:
            return LocalMemoryRPCReply(operation: .forgetEverything, commandID: command.commandID,
                status: .completed, generationReference: String(repeating: "b", count: 64))
        case .missingGeneration:
            return LocalMemoryRPCReply(operation: .forgetEverything, commandID: command.commandID,
                                       status: .completed)
        case .malformedGeneration:
            return LocalMemoryRPCReply(operation: .forgetEverything, commandID: command.commandID,
                                       status: .completed, generationReference: "BAD")
        case .generation:
            throw Failure.requested
        case .failure: throw Failure.requested
        case .suspend: throw Failure.requested
        }
    }
}

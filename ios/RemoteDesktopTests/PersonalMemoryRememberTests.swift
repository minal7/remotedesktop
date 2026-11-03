import XCTest
@testable import RemoteDesktop

@MainActor
final class PersonalMemoryRememberTests: XCTestCase {
    func testComposerRoutesOnlyExplicitRememberCommand() {
        XCTAssertEqual(PersonalMemoryComposerRoute.decide(
            text: "Please book a flight", isRequestMode: true, memoryAvailable: true, incognito: false), .sendTask)
        XCTAssertEqual(PersonalMemoryComposerRoute.decide(
            text: "please remember my home airport is SFO", isRequestMode: true,
            memoryAvailable: true, incognito: false), .sendTask)
        XCTAssertEqual(PersonalMemoryComposerRoute.decide(
            text: "  rEmEmBeR my home airport is SFO", isRequestMode: true,
            memoryAvailable: true, incognito: false),
            .openRemember(originalText: "  rEmEmBeR my home airport is SFO"))
        XCTAssertEqual(PersonalMemoryComposerRoute.decide(
            text: "Remembering this for later", isRequestMode: true,
            memoryAvailable: true, incognito: false), .sendTask)
        XCTAssertEqual(PersonalMemoryComposerRoute.decide(
            text: "Remember my home airport is SFO", isRequestMode: false,
            memoryAvailable: true, incognito: false), .sendTask)
    }

    func testComposerRememberRefusesWhenUnavailableOrIncognito() {
        let text = "Remember my home airport is SFO"
        XCTAssertEqual(PersonalMemoryComposerRoute.decide(
            text: text, isRequestMode: true, memoryAvailable: false, incognito: false), .refuseUnavailable)
        XCTAssertEqual(PersonalMemoryComposerRoute.decide(
            text: text, isRequestMode: true, memoryAvailable: true, incognito: true), .refuseIncognito)
    }

    func testComposerCommandBeginsNoWriteUntilOwnerExplicitlySaves() async throws {
        let text = "Remember my home airport is SFO"
        let route = PersonalMemoryComposerRoute.decide(
            text: text, isRequestMode: true, memoryAvailable: true, incognito: false)
        guard case .openRemember(let originalText) = route else { return XCTFail("Expected Remember sheet") }
        let channel = RememberChannel()
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        XCTAssertEqual(model.state, .unavailable)
        model.open()
        try await wait { model.state == .ready && model.generationReference != nil }
        XCTAssertTrue(model.beginRememberComposition())
        let beforeSave = await channel.commands()
        XCTAssertFalse(beforeSave.contains { $0.operation == .remember })
        await channel.enqueue(.success)
        XCTAssertNotNil(model.saveRemember(kind: .fact, text: originalText))
        try await wait { model.rememberState == .saved }
        let saves = await channel.commands().filter { $0.operation == .remember }
        XCTAssertEqual(saves.count, 1)
        XCTAssertEqual(saves[0].text, text)
    }

    func testColdComposerLoadsEmptyMemoryWithoutGenerationBeforeExplicitSave() async throws {
        let channel = RememberChannel(captureReference: nil)
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        XCTAssertEqual(model.state, .unavailable)
        model.open()
        try await wait { model.state == .ready && model.generationReference == nil }
        XCTAssertTrue(model.beginRememberComposition())
        await channel.enqueue(.success)
        XCTAssertNotNil(model.saveRemember(kind: .fact, text: "Home airport is SFO"))
        try await wait { model.rememberState == .saved }
        let saves = await channel.commands().filter { $0.operation == .remember }
        XCTAssertEqual(saves.map(\.text), ["Home airport is SFO"])
    }

    func testClosingUnknownRememberKeepsSameCommandForExplicitRetry() async throws {
        let channel = RememberChannel()
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.state == .ready && model.generationReference != nil }
        XCTAssertTrue(model.beginRememberComposition())
        await channel.enqueue(.failure)
        let firstID = try XCTUnwrap(model.saveRemember(kind: .fact, text: "Home airport is SFO"))
        try await wait { model.rememberState == .unknown }

        model.cancelRememberComposition()
        XCTAssertEqual(model.rememberState, .unknown)
        XCTAssertEqual(model.pendingRemember?.text, "Home airport is SFO")
        XCTAssertEqual(model.pendingRemember?.kind, .fact)
        await channel.enqueue(.success)
        XCTAssertEqual(model.retryRemember(), firstID)
        try await wait { model.rememberState == .saved }
        let saves = await channel.commands().filter { $0.operation == .remember }
        XCTAssertEqual(saves.map(\.commandID), [firstID, firstID])
    }

    func testExplicitSaveUsesSameIDAndPayloadForManualRetry() async throws {
        let channel = RememberChannel()
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.state == .ready && model.generationReference != nil }
        XCTAssertTrue(model.beginRememberComposition())
        let beforeSave = await channel.commands()
        XCTAssertFalse(beforeSave.contains { $0.operation == .remember })
        await channel.enqueue(.mismatch)
        await channel.enqueue(.success)
        let id = try XCTUnwrap(model.saveRemember(kind: .profile, text: "Prefers aisle seats"))
        XCTAssertNil(model.saveRemember(kind: .profile, text: "Prefers aisle seats"))
        try await wait { model.rememberState == .unknown }
        XCTAssertNil(model.rememberReceipt)
        XCTAssertEqual(model.retryRemember(), id)
        try await wait { model.rememberState == .saved }
        XCTAssertEqual(model.rememberReceipt?.kind, .profile)
        XCTAssertEqual(model.rememberReceipt?.commandID, id)
        XCTAssertEqual(UUID(uuidString: id)?.uuidString.lowercased(), id)
        let saves = await channel.commands().filter { $0.operation == .remember }
        XCTAssertEqual(saves.count, 2)
        XCTAssertEqual(saves[0], saves[1])
    }

    func testExplicitOwnerContactFactsPassThroughOrdinaryRemember() async throws {
        for text in [
            "Home address: 123 Example St",
            "Phone: 555-0100",
            "Email: owner@example.invalid",
        ] {
            let channel = RememberChannel()
            let model = PersonalMemoryViewModel(enabled: true, channel: channel)
            model.open()
            try await wait { model.state == .ready && model.generationReference != nil }
            XCTAssertTrue(model.beginRememberComposition())
            await channel.enqueue(.success)
            XCTAssertNotNil(model.saveRemember(kind: .fact, text: text))
            try await wait { model.rememberState == .saved }
            let rememberCommands = await channel.commands().filter {
                $0.operation == .remember
            }
            let command = try XCTUnwrap(rememberCommands.first)
            XCTAssertEqual(command.text, text)
            model.disconnect()
        }
    }

    func testCancelBeforeSaveSendsNothing() async throws {
        let channel = RememberChannel()
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.state == .ready && model.generationReference != nil }
        XCTAssertTrue(model.beginRememberComposition())
        model.cancelRememberComposition()
        let commands = await channel.commands()
        XCTAssertFalse(commands.contains { $0.operation == .remember })
        XCTAssertEqual(model.rememberState, .idle)
    }

    func testCloseSuppressesLateReceiptAfterWriteWasSent() async throws {
        let channel = RememberChannel()
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.state == .ready && model.generationReference != nil }
        XCTAssertTrue(model.beginRememberComposition())
        await channel.enqueue(.suspend)
        XCTAssertNotNil(model.saveRemember(kind: .fact, text: "Uses a standing desk"))
        try await wait { await channel.commands().contains { $0.operation == .remember } }
        model.close()
        await channel.release(.success)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.rememberState, .idle)
        XCTAssertNil(model.rememberReceipt)
    }

    func testDisconnectClearsCompositionAndSuppressesLateReceipt() async throws {
        let channel = RememberChannel()
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.state == .ready && model.generationReference != nil }
        XCTAssertTrue(model.beginRememberComposition())
        await channel.enqueue(.suspend)
        XCTAssertNotNil(model.saveRemember(kind: .fact, text: "Uses a standing desk"))
        try await wait { await channel.commands().contains { $0.operation == .remember } }
        model.disconnect()
        await channel.release(.success)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.rememberState, .idle)
        XCTAssertNil(model.rememberReceipt)
        XCTAssertFalse(model.beginRememberComposition())
    }

    func testForgetConfirmationInvalidatesUnknownRememberRetry() async throws {
        let channel = RememberChannel()
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.state == .ready && model.generationReference != nil }
        XCTAssertTrue(model.beginRememberComposition())
        await channel.enqueue(.failure)
        XCTAssertNotNil(model.saveRemember(kind: .fact, text: "Uses a standing desk"))
        try await wait { model.rememberState == .unknown }
        XCTAssertNotNil(model.beginForgetConfirmation())
        XCTAssertNil(model.retryRemember())
        let saves = await channel.commands().filter { $0.operation == .remember }
        XCTAssertEqual(saves.count, 1)
    }


    func testDisabledModelCannotComposeOrSend() async {
        let channel = RememberChannel()
        let model = PersonalMemoryViewModel(channel: channel)
        XCTAssertFalse(model.beginRememberComposition())
        XCTAssertNil(model.saveRemember(kind: .fact, text: "Keeps notes on paper"))
        let commands = await channel.commands()
        XCTAssertTrue(commands.isEmpty)
    }

    func testExplicitHostDenialDoesNotOfferRetry() async throws {
        let channel = RememberChannel()
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.state == .ready && model.generationReference != nil }
        XCTAssertTrue(model.beginRememberComposition())
        await channel.enqueue(.incognito)
        XCTAssertNotNil(model.saveRemember(kind: .fact, text: "Keeps notes on paper"))
        try await wait { model.rememberState == .rejected }
        XCTAssertNil(model.retryRemember())
        let saves = await channel.commands().filter { $0.operation == .remember }
        XCTAssertEqual(saves.count, 1)
    }

    func testMalformedCompletedReceiptsNeverShowSaved() async throws {
        for outcome in [RememberChannel.Outcome.wrongKind, .extraGeneration, .missingRetry] {
            let channel = RememberChannel()
            let model = PersonalMemoryViewModel(enabled: true, channel: channel)
            model.open()
            try await wait { model.state == .ready && model.generationReference != nil }
            XCTAssertTrue(model.beginRememberComposition())
            await channel.enqueue(outcome)
            XCTAssertNotNil(model.saveRemember(kind: .profile, text: "Prefers quiet tables"))
            try await wait { model.rememberState == .unknown }
            XCTAssertNil(model.rememberReceipt)
            model.close()
        }
    }

    func testTimedOutSaveCanOnlyRetrySameCommandAndPayload() async throws {
        let channel = RememberChannel()
        let model = PersonalMemoryViewModel(enabled: true, channel: channel,
                                            requestTimeout: .milliseconds(40))
        model.open()
        try await wait { model.state == .ready && model.generationReference != nil }
        XCTAssertTrue(model.beginRememberComposition())
        await channel.enqueue(.suspend)
        let id = try XCTUnwrap(model.saveRemember(kind: .fact, text: "Keeps notes on paper"))
        try await wait { model.rememberState == .unknown }
        await channel.enqueue(.success)
        XCTAssertEqual(model.retryRemember(), id)
        try await wait { model.rememberState == .saved }
        let saves = await channel.commands().filter { $0.operation == .remember }
        XCTAssertEqual(saves.count, 2)
        XCTAssertEqual(saves[0], saves[1])
        await channel.release(.mismatch)
        model.close()
    }

    func testDoneClearsReceiptAndReloadsOnlyReadableMemory() async throws {
        let channel = RememberChannel()
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.state == .ready && model.generationReference != nil }
        XCTAssertTrue(model.beginRememberComposition())
        await channel.enqueue(.success)
        XCTAssertNotNil(model.saveRemember(kind: .profile, text: "Prefers quiet tables"))
        try await wait { model.rememberState == .saved }
        let before = await channel.commands().filter { $0.operation == .listRecords }.count
        XCTAssertNotNil(model.rememberReceipt)
        model.finishRememberPresentation()
        try await wait { model.rememberState == .idle && model.state == .ready }
        let after = await channel.commands().filter { $0.operation == .listRecords }.count
        XCTAssertNil(model.rememberReceipt)
        XCTAssertEqual(after, before + 1)
    }

    func testNoMemoryReadFailureStillAllowsExplicitRemember() async throws {
        let channel = RememberChannel(readStatus: .noMemory)
        let model = PersonalMemoryViewModel(enabled: true, channel: channel)
        model.open()
        try await wait { model.state == .error("Memories could not be loaded. Try again.")
            && model.generationReference == nil }
        XCTAssertTrue(model.beginRememberComposition())
        await channel.enqueue(.success)
        XCTAssertNotNil(model.saveRemember(kind: .fact, text: "Keeps notes on paper"))
        try await wait { model.rememberState == .saved }
    }

    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < end else { throw RememberChannel.Failure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor RememberChannel: PersonalMemoryChannel {
    enum Failure: Error { case timeout, requested }
    enum Outcome: Equatable, Sendable {
        case success, mismatch, failure, suspend, incognito, wrongKind, extraGeneration, missingRetry
    }
    private var outcomes: [Outcome] = []
    private var continuation: CheckedContinuation<Outcome, Never>?
    private let readStatus: LocalMemoryRPCReply.Status
    private let captureReference: String?

    init(readStatus: LocalMemoryRPCReply.Status = .completed,
         captureReference: String? = String(repeating: "a", count: 64)) {
        self.readStatus = readStatus
        self.captureReference = captureReference
    }
    private var received: [LocalMemoryRPCCommand] = []

    func enqueue(_ value: Outcome) { outcomes.append(value) }
    func release(_ value: Outcome) { continuation?.resume(returning: value); continuation = nil }
    func commands() -> [LocalMemoryRPCCommand] { received }

    func sendMemoryCommand(_ command: LocalMemoryRPCCommand) async throws -> LocalMemoryRPCReply {
        received.append(command)
        if command.operation == .captureMemoryGeneration {
            return .init(operation: command.operation, status: readStatus,
                         generationReference: readStatus == .completed ? captureReference : nil)
        }
        if command.operation != .remember {
            return .init(operation: command.operation, status: readStatus)
        }
        var outcome = outcomes.isEmpty ? .failure : outcomes.removeFirst()
        if outcome == .suspend { outcome = await withCheckedContinuation { continuation = $0 } }
        switch outcome {
        case .success:
            return .init(operation: .remember, commandID: command.commandID,
                         rememberKind: command.rememberKind, status: .completed,
                         recordID: "saved-record", idempotentRetry: false)
        case .mismatch:
            return .init(operation: .remember, commandID: UUID().uuidString.lowercased(),
                         rememberKind: command.rememberKind, status: .completed,
                         recordID: "saved-record", idempotentRetry: false)
        case .incognito:
            return .init(operation: .remember, commandID: command.commandID,
                         rememberKind: command.rememberKind, status: .incognito)
        case .wrongKind:
            return .init(operation: .remember, commandID: command.commandID,
                         rememberKind: command.rememberKind == .profile ? .fact : .profile,
                         status: .completed, recordID: "saved-record", idempotentRetry: false)
        case .extraGeneration:
            return .init(operation: .remember, commandID: command.commandID,
                         rememberKind: command.rememberKind, status: .completed,
                         recordID: "saved-record", idempotentRetry: false,
                         generationReference: String(repeating: "b", count: 64))
        case .missingRetry:
            return .init(operation: .remember, commandID: command.commandID,
                         rememberKind: command.rememberKind, status: .completed,
                         recordID: "saved-record")
        case .failure: throw Failure.requested
        case .suspend: throw Failure.requested
        }
    }
}

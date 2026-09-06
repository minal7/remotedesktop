import XCTest
@testable import RemoteDesktop

@MainActor
final class ComputerUseClarificationClientTests: XCTestCase {
    func testLegacyQuestionRetainsItsExistingConversationAndMailPrivacyBehavior() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Send an email"))
        let original = try await fixture.channel.prompt(at: 0)
        let question = "Who should receive the email, and what should it say?"
        await fixture.channel.deliver(try ComputerUseTaskUpdate(taskID: original.id, text: question).encodedBody())
        try await fixture.wait { fixture.model.composerMode == .legacyAnswer }
        XCTAssertTrue(fixture.model.sendPrompt("  To alex@example.com. Say the meeting is at 3.  "))
        let sent = try await fixture.channel.prompt(at: 1)
        let request = try ComputerUsePromptRequest.decodeBody(sent.body)
        XCTAssertNil(request.clarification)
        XCTAssertEqual(request.prompt, "To alex@example.com. Say the meeting is at 3.")
        XCTAssertEqual(request.conversation, [.init(role: .user, text: "Send an email"), .init(role: .assistant, text: question)])
        XCTAssertTrue(fixture.model.isLiveScreenPrivacyShielded)
    }

    func testExplicitReferenceCarriesExactAnswersAcrossTwoQuestionsWithoutChatTruncation() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start()
        let original = "Put \"" + String(repeating: "x", count: 5_000) + "\" in a field."
        XCTAssertTrue(fixture.model.sendPrompt(original))
        let first = try await fixture.channel.prompt(at: 0)
        XCTAssertEqual(try ComputerUsePromptRequest.decodeBody(first.body).prompt, original)
        let reference = try await fixture.question(for: first, text: "Choose the destination.")
        let exact = "  東京 e\u{301} 😀\n  "
        XCTAssertTrue(fixture.model.sendPrompt(exact))
        let answer = try await fixture.channel.prompt(at: 1)
        let decoded = try ComputerUsePromptRequest.decodeBody(answer.body)
        XCTAssertTrue(decoded.prompt.utf8.elementsEqual(exact.utf8))
        XCTAssertEqual(decoded.clarification, reference); XCTAssertTrue(decoded.conversation.isEmpty)
        XCTAssertEqual(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456")?.exactWireBody, answer.body)
        let next = try await fixture.question(for: answer, text: "Which destination group?")
        let longAnswer = "\"  " + String(repeating: "y", count: 5_000) + "  \""
        XCTAssertTrue(fixture.model.sendPrompt(longAnswer))
        let final = try await fixture.channel.prompt(at: 2)
        let finalRequest = try ComputerUsePromptRequest.decodeBody(final.body)
        XCTAssertTrue(finalRequest.prompt.utf8.elementsEqual(longAnswer.utf8))
        XCTAssertEqual(finalRequest.clarification, next); XCTAssertTrue(finalRequest.conversation.isEmpty)
        XCTAssertNotEqual(first.id, answer.id); XCTAssertNotEqual(answer.id, final.id)
    }

    func testAnswerRetriesAndRelaunchReuseExactBodyAndTaskIDEvenAfterReferenceExpiry() async throws {
        var now = Date()
        let fixture = ClarificationClientFixture(now: { now })
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Put text in Notes."))
        let original = try await fixture.channel.prompt(at: 0)
        let reference = try await fixture.question(for: original)
        await fixture.channel.failNextPrompt()
        let exact = "  \n e\u{301} 😀  "
        XCTAssertTrue(fixture.model.sendPrompt(exact))
        let answer = try await fixture.channel.prompt(at: 1)
        try await fixture.wait { fixture.model.retryPrompt != nil }
        XCTAssertEqual(fixture.model.retryPrompt, exact)
        fixture.model.retryLastPrompt()
        let retry = try await fixture.channel.prompt(at: 2)
        XCTAssertTrue(answer.body.utf8.elementsEqual(retry.body.utf8)); XCTAssertEqual(answer.id, retry.id)
        fixture.model.stop()
        now = reference.expiresAt.addingTimeInterval(1)
        let recoveredChannel = ClarificationClientChannel()
        let recovered = ComputerUseSessionModel(hostName: "Mac", pairingCode: "123456", hostID: "HOST-ID",
            pendingStore: fixture.store, channel: recoveredChannel, now: { now })
        defer { recovered.stop() }
        recovered.start()
        let replay = try await recoveredChannel.prompt(at: 0)
        XCTAssertTrue(answer.body.utf8.elementsEqual(replay.body.utf8)); XCTAssertEqual(replay.id, answer.id)
        XCTAssertTrue(recovered.hasActivePrompt)
        XCTAssertEqual(recovered.messages.last?.text, exact)
    }

    func testExpiryOrDisconnectRequiresExplicitNewRequestWithoutReusingHistory() async throws {
        for reason in ["expiry", "disconnect"] {
            var now = Date()
            let fixture = ClarificationClientFixture(now: { now })
            defer { fixture.model.stop() }
            fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Put blue in a field."))
            let original = try await fixture.channel.prompt(at: 0)
            let reference = try await fixture.question(for: original)
            if reason == "expiry" { now = reference.expiresAt }
            else { fixture.model.stop(); fixture.model.start() }
            XCTAssertFalse(fixture.model.sendPrompt("Destination"), reason)
            XCTAssertEqual(fixture.model.composerMode, .expiredAnswer)
            let count = await fixture.channel.promptCount()
            XCTAssertEqual(count, 1)
            XCTAssertTrue(fixture.model.startNewRequest())
            XCTAssertTrue(fixture.model.sendPrompt("Open Calculator"))
            let new = try ComputerUsePromptRequest.decodeBody(await fixture.channel.prompt(at: 1).body)
            XCTAssertNil(new.clarification); XCTAssertTrue(new.conversation.isEmpty); XCTAssertEqual(new.prompt, "Open Calculator")
        }
    }

    func testNewRequestDiscardsScopedOrLegacyQuestionAndIgnoresLateReplay() async throws {
        for scoped in [true, false] {
            let fixture = ClarificationClientFixture()
            defer { fixture.model.stop() }
            fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Put blue in a field."))
            let original = try await fixture.channel.prompt(at: 0)
            if scoped { _ = try await fixture.question(for: original) }
            else {
                await fixture.channel.deliver(try ComputerUseTaskUpdate(taskID: original.id, text: "Which field?").encodedBody())
                try await fixture.wait { fixture.model.composerMode == .legacyAnswer }
            }
            XCTAssertTrue(fixture.model.canStartNewRequest)
            XCTAssertTrue(fixture.model.startNewRequest())
            await fixture.channel.deliver(try ComputerUseTaskUpdate(taskID: original.id, text: "Which field?").encodedBody())
            try await fixture.channel.waitForDelivery()
            XCTAssertEqual(fixture.model.composerMode, .request)
            XCTAssertTrue(fixture.model.sendPrompt("Open Calculator"))
            let sent = try await fixture.channel.prompt(at: 1)
            let request = try ComputerUsePromptRequest.decodeBody(sent.body)
            XCTAssertTrue(request.conversation.isEmpty); XCTAssertNil(request.clarification)
            XCTAssertFalse(fixture.model.startNewRequest(), "A new request cannot discard an in-flight answer or task")
        }
    }

    func testInvalidOrUnsavedAnswerKeepsTheQuestionAndSendsNoTruncatedText() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Put text in Notes."))
        let original = try await fixture.channel.prompt(at: 0)
        let reference = try await fixture.question(for: original)
        for invalid in ["", String(repeating: "x", count: 8_001), String(repeating: "👨‍👩‍👧‍👦", count: 2_000)] {
            XCTAssertFalse(fixture.model.sendPrompt(invalid))
            guard case .answer(let retained, _) = fixture.model.composerMode else { return XCTFail("Keep a valid question after rejected input") }
            XCTAssertEqual(retained, reference)
        }
        fixture.store.permitsSave = false
        XCTAssertFalse(fixture.model.sendPrompt("  \n  "))
        let count = await fixture.channel.promptCount()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(fixture.model.messages.filter { $0.author == .user }.count, 1)
        fixture.store.permitsSave = true
        XCTAssertTrue(fixture.model.sendPrompt("  \n  "))
        let answer = try ComputerUsePromptRequest.decodeBody(await fixture.channel.prompt(at: 1).body)
        XCTAssertTrue(answer.prompt.utf8.elementsEqual("  \n  ".utf8)); XCTAssertEqual(answer.clarification, reference)
    }

    func testMalformedAndUnrelatedResponsesCannotSelectAContinuation() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Put blue in a field."))
        let original = try await fixture.channel.prompt(at: 0)
        await fixture.channel.deliver(#"{"taskID":"broken","clarification":{}}"#)
        let unrelated = try ComputerUseClarificationReference(taskID: "other", expiresAt: Date().addingTimeInterval(60))
        await fixture.channel.deliver(try ComputerUseTaskUpdate(taskID: "other", text: "Which field?", outcome: .userInterventionRequired,
            clarification: unrelated).encodedBody())
        try await fixture.channel.waitForDelivery()
        XCTAssertTrue(fixture.model.hasActivePrompt); XCTAssertEqual(fixture.model.composerMode, .request)
        XCTAssertTrue(fixture.model.messages.allSatisfy { $0.author != .assistant })
        _ = try await fixture.question(for: original)
        XCTAssertTrue(fixture.model.isAnsweringClarification)
    }

    func testCancellationOrCompletionPreventsQuestionTextFromBecomingNewTaskContext() async throws {
        for cancel in [true, false] {
            let fixture = ClarificationClientFixture()
            defer { fixture.model.stop() }
            fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Put blue in a field."))
            let original = try await fixture.channel.prompt(at: 0)
            if cancel { fixture.model.stopCurrentTask() }
            let reference = try ComputerUseClarificationReference(taskID: original.id, expiresAt: Date().addingTimeInterval(60))
            await fixture.channel.deliver(try ComputerUseTaskUpdate(taskID: original.id, text: "Which field?",
                appliedControlRevision: cancel ? 1 : nil, outcome: cancel ? .userInterventionRequired : .taskCompleted,
                clarification: reference).encodedBody())
            try await fixture.wait { !fixture.model.hasActivePrompt }
            XCTAssertEqual(fixture.model.composerMode, .request)
            XCTAssertTrue(fixture.model.sendPrompt("Open Calculator"))
            let request = try ComputerUsePromptRequest.decodeBody(await fixture.channel.prompt(at: 1).body)
            XCTAssertNil(request.clarification); XCTAssertTrue(request.conversation.isEmpty)
        }
    }

    func testExpiryTimerReleasesQuestionAndCannotInvalidateAnAlreadyClaimedAnswer() async throws {
        for claim in [true, false] {
            let fixture = ClarificationClientFixture()
            defer { fixture.model.stop() }
            fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Put blue in a field."))
            let original = try await fixture.channel.prompt(at: 0)
            _ = try await fixture.question(for: original, lifetime: 0.15)
            if claim { XCTAssertTrue(fixture.model.sendPrompt("Destination")); _ = try await fixture.channel.prompt(at: 1) }
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(fixture.model.composerMode, claim ? .request : .expiredAnswer)
            XCTAssertEqual(fixture.model.hasActivePrompt, claim)
            if !claim { XCTAssertFalse(fixture.model.sendPrompt("Destination")) }
        }
    }
}

@MainActor
private final class ClarificationClientFixture {
    let channel = ClarificationClientChannel()
    let store = ClarificationClientStore()
    let model: ComputerUseSessionModel
    init(now: @escaping () -> Date = Date.init) {
        model = ComputerUseSessionModel(hostName: "Mac", pairingCode: "123456", hostID: "HOST-ID", sessionID: "session-1",
            pendingStore: store, channel: channel, now: now)
    }
    func question(for request: ComputerUseEnvelope, text: String = "Which field?", lifetime: TimeInterval = 300) async throws -> ComputerUseClarificationReference {
        let reference = try ComputerUseClarificationReference(taskID: request.id, expiresAt: Date().addingTimeInterval(lifetime))
        await channel.deliver(try ComputerUseTaskUpdate(taskID: request.id, text: text, outcome: .userInterventionRequired, clarification: reference).encodedBody())
        try await wait {
            guard case .answer(let received, _) = self.model.composerMode else { return false }
            return received == reference
        }
        return reference
    }
    func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ClarificationClientChannel.Failure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor ClarificationClientChannel: ComputerUseSessionChannel {
    enum Failure: Error { case timeout, requested }
    private var prompts: [ComputerUseEnvelope] = []
    private var incoming: [ComputerUseEnvelope] = []
    private var deliveredCount = 0
    private var acknowledgedCount = 0
    private var failPrompt = false
    func send(kind: ComputerUseEnvelope.Kind, body: String, to targetID: String?, sessionID: String?, messageID: String?) async throws -> ComputerUseEnvelope {
        let envelope = ComputerUseEnvelope(id: messageID ?? UUID().uuidString, senderID: "IOS-ID", targetID: targetID ?? "HOST-ID",
            pairingCode: "123456", sessionID: sessionID ?? "session-1", kind: kind, body: body)
        if kind == .prompt {
            prompts.append(envelope)
            if failPrompt { failPrompt = false; throw Failure.requested }
        }
        return envelope
    }
    func poll() async throws -> [ComputerUseEnvelope] {
        while incoming.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let result = incoming; incoming.removeAll(); return result
    }
    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws { acknowledgedCount += envelopes.count }
    func deliver(_ body: String) {
        deliveredCount += 1
        incoming.append(.init(senderID: "HOST-ID", targetID: "IOS-ID", pairingCode: "123456", sessionID: "session-1", kind: .assistant, body: body))
    }
    func promptCount() -> Int { prompts.count }
    func failNextPrompt() { failPrompt = true }
    func prompt(at index: Int) async throws -> ComputerUseEnvelope {
        let deadline = ContinuousClock.now + .seconds(3)
        while prompts.count <= index {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
        return prompts[index]
    }
    func waitForDelivery() async throws {
        let count = deliveredCount, deadline = ContinuousClock.now + .seconds(3)
        while acknowledgedCount < count {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class ClarificationClientStore: ComputerUsePendingPromptStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: ComputerUsePendingPrompt?
    private var allowsSave = true
    var permitsSave: Bool {
        get { lock.lock(); defer { lock.unlock() }; return allowsSave }
        set { lock.lock(); defer { lock.unlock() }; allowsSave = newValue }
    }
    func load(hostID: String, pairingCode: String) -> ComputerUsePendingPrompt? {
        lock.lock(); defer { lock.unlock() }
        guard saved?.hostID == hostID, saved?.pairingCode == pairingCode else { return nil }
        return saved
    }
    func save(_ pending: ComputerUsePendingPrompt) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard allowsSave else { return false }; saved = pending; return true
    }
    func remove(hostID: String) {
        lock.lock(); defer { lock.unlock() }
        if saved?.hostID == hostID { saved = nil }
    }
}

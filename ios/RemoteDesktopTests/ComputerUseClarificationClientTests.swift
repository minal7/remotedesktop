import XCTest
@testable import RemoteDesktop

@MainActor
final class ComputerUseClarificationClientTests: XCTestCase {
    func testQuestionPolicyRejectsByteOverflowAndBlankAnswersWithoutLosingTheQuestion() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Find tickets."))
        let original = try await fixture.channel.prompt(at: 0)
        let policy = try ComputerUseClarificationAnswerPolicy(maximumUTF8Bytes: 7, requiresNonblank: true)
        let reference = try await fixture.question(for: original, answerPolicy: policy)
        for answer in [" \n ", "😀éaa"] {
            XCTAssertNotNil(fixture.model.promptValidationMessage(answer))
            XCTAssertFalse(fixture.model.sendPrompt(answer))
            guard case .answer(let retained, _) = fixture.model.composerMode else { return XCTFail("Invalid input must keep the question") }
            XCTAssertEqual(retained, reference)
        }
        let count = await fixture.channel.promptCount()
        XCTAssertEqual(count, 1); XCTAssertEqual(fixture.model.messages.filter { $0.author == .user }.count, 1)
        let exact = "😀éa"
        XCTAssertTrue(fixture.model.sendPrompt(exact))
        let envelope = try await fixture.channel.prompt(at: 1), answer = try ComputerUsePromptRequest.decodeBody(envelope.body)
        XCTAssertTrue(answer.prompt.utf8.elementsEqual(exact.utf8)); XCTAssertEqual(answer.clarification, reference)
        let next = try await fixture.question(for: envelope, answerPolicy: ComputerUseClarificationAnswerPolicy(maximumUTF8Bytes: 2, requiresNonblank: false))
        XCTAssertTrue(fixture.model.sendPrompt("  "))
        let literal = try ComputerUsePromptRequest.decodeBody(await fixture.channel.prompt(at: 2).body)
        XCTAssertEqual(literal.prompt, "  "); XCTAssertEqual(literal.clarification, next)
    }

    func testNewRequestAndLegacyQuestionDoNotInheritAnEarlierAnswerPolicy() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Find tickets."))
        let original = try await fixture.channel.prompt(at: 0)
        _ = try await fixture.question(for: original, answerPolicy: ComputerUseClarificationAnswerPolicy(maximumUTF8Bytes: 1, requiresNonblank: true))
        XCTAssertTrue(fixture.model.startNewRequest())
        XCTAssertNil(fixture.model.promptValidationMessage("Put text in Notes."))
        XCTAssertTrue(fixture.model.sendPrompt("Put text in Notes."))
        let newRequest = try await fixture.channel.prompt(at: 1)
        let reference = try await fixture.question(for: newRequest)
        XCTAssertTrue(fixture.model.sendPrompt("   "))
        let answer = try ComputerUsePromptRequest.decodeBody(await fixture.channel.prompt(at: 2).body)
        XCTAssertEqual(answer.clarification, reference); XCTAssertEqual(answer.prompt, "   ")
    }

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

    func testFullScopedQuestionReachesPhoneAndItsAnswerKeepsTheOriginalReference() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Find concert tickets."))
        let original = try await fixture.channel.prompt(at: 0)
        let question = "Which location?\n\nI'm asking about the part inside ⟦ ⟧.\n\n⟦"
            + String(repeating: "e\u{301}😀 ", count: 4_000) + "⟧"
        XCTAssertGreaterThan(question.count, 8_000)
        let reference = try await fixture.question(for: original, text: question)
        XCTAssertTrue(try XCTUnwrap(fixture.model.messages.last?.text).utf8.elementsEqual(question.utf8))
        let exact = "  Paris e\u{301} 😀\n  "
        XCTAssertTrue(fixture.model.sendPrompt(exact))
        let sent = try await fixture.channel.prompt(at: 1)
        let answer = try ComputerUsePromptRequest.decodeBody(sent.body)
        XCTAssertEqual(answer.clarification, reference)
        XCTAssertTrue(answer.prompt.utf8.elementsEqual(exact.utf8)); XCTAssertTrue(answer.conversation.isEmpty)
        XCTAssertNotEqual(sent.id, original.id)
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
final class ComputerUseActionEvidenceClientTests: XCTestCase {
    func testActionEvidenceDoesNotAcknowledgeStopAndCanArriveBeforeOrAfterItsTerminal() async throws {
        for terminalFirst in [false, true] {
            let fixture = ClarificationClientFixture()
            defer { fixture.model.stop() }
            fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Draft the fixture email"))
            let request = try await fixture.channel.prompt(at: 0)
            fixture.model.stopCurrentTask()
            let before = snapshot(fixture)
            let unconfirmed = try evidence(.unconfirmed)
            await fixture.channel.deliver(try metadata(taskID: request.id, evidence: unconfirmed), kind: .status)
            try await fixture.channel.waitForDelivery()
            XCTAssertEqual(snapshot(fixture), before)
            XCTAssertTrue(fixture.model.isCancellationPending)
            XCTAssertEqual(fixture.model.messages.first?.approvedActionEvidence, unconfirmed)
            let terminal = try ComputerUseTaskUpdate(taskID: request.id, text: "Stopped.", appliedControlRevision: 1,
                outcome: .unableToComplete).encodedBody()
            if terminalFirst {
                await fixture.channel.deliver(terminal)
                try await fixture.channel.waitForDelivery()
            }
            let beforeConfirmation = snapshot(fixture)
            let confirmed = try evidence(.confirmed)
            await fixture.channel.deliver(try metadata(taskID: request.id, evidence: confirmed), kind: .status)
            try await fixture.channel.waitForDelivery()
            XCTAssertEqual(snapshot(fixture), beforeConfirmation)
            XCTAssertEqual(fixture.model.messages.first?.approvedActionEvidence, confirmed)
            if !terminalFirst {
                await fixture.channel.deliver(terminal)
                try await fixture.channel.waitForDelivery()
            }
            XCTAssertFalse(fixture.model.hasActivePrompt)
            XCTAssertEqual(fixture.model.latestTerminalOutcome, .unableToComplete)
            XCTAssertEqual(fixture.model.messages.filter { $0.author == .assistant }.map(\.text), ["Stopped."])
        }
    }

    func testHistoricalActionEvidenceCannotChangeANewerWorkingPausedOrApprovalTask() async throws {
        for state in ["working", "paused", "approval"] {
            let fixture = ClarificationClientFixture()
            defer { fixture.model.stop() }
            fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Original request"))
            let original = try await fixture.channel.prompt(at: 0)
            await fixture.channel.deliver(try ComputerUseTaskUpdate(taskID: original.id, text: "Stopped.", outcome: .unableToComplete).encodedBody())
            try await fixture.channel.waitForDelivery()
            XCTAssertTrue(fixture.model.sendPrompt("New request"))
            let current = try await fixture.channel.prompt(at: 1)
            await fixture.channel.deliver(try ComputerUseTaskUpdate(taskID: current.id, text: "working").encodedBody(), kind: .status)
            try await fixture.channel.waitForDelivery()
            if state == "paused" { fixture.model.takeControl() }
            if state == "approval" {
                await fixture.channel.deliver(try ComputerUseApprovalRequest(taskID: current.id, message: "Approve the new action?").encodedBody(), kind: .approvalRequest)
                try await fixture.channel.waitForDelivery()
            }
            let before = snapshot(fixture), confirmed = try evidence(.confirmed)
            await fixture.channel.deliver(try metadata(taskID: original.id, evidence: confirmed), kind: .status)
            // A replay may carry the same evidence with an obsolete lifecycle result.
            await fixture.channel.deliver(try ComputerUseTaskUpdate(taskID: original.id, text: "Old task completed.",
                appliedControlRevision: 90, outcome: .taskCompleted, approvedActionEvidence: confirmed).encodedBody())
            try await fixture.channel.waitForDelivery()
            XCTAssertEqual(snapshot(fixture), before, state)
            XCTAssertEqual(fixture.model.messages.first?.approvedActionEvidence, confirmed)
            XCTAssertNil(fixture.model.messages.first { $0.id == current.id }?.approvedActionEvidence)
            XCTAssertFalse(fixture.model.messages.contains { $0.text == "Old task completed." })
        }
    }

    func testActionEvidenceAdvancesOnceAndRejectsConflictingOrReorderedRecords() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Original request"))
        let original = try await fixture.channel.prompt(at: 0)
        let pending = try evidence(.unconfirmed), confirmed = try evidence(.confirmed)
        await fixture.channel.deliver(try metadata(taskID: original.id, evidence: pending), kind: .status)
        let foreign = try evidence(.confirmed, actionID: String(repeating: "c", count: 64))
        await fixture.channel.deliver(try metadata(taskID: original.id, evidence: foreign), kind: .status)
        try await fixture.channel.waitForDelivery()
        XCTAssertEqual(fixture.model.messages.first?.approvedActionEvidence, pending)
        await fixture.channel.deliver(try ComputerUseTaskUpdate(taskID: original.id, text: "Task completed.", outcome: .taskCompleted,
            approvedActionEvidence: confirmed).encodedBody())
        try await fixture.channel.waitForDelivery()
        let before = fixture.model.messages
        for replay in [pending, confirmed, foreign, try evidence(.confirmed, summary: "Conflicting response"),
                       try evidence(.confirmed, resultDigest: String(repeating: "d", count: 64))] {
            await fixture.channel.deliver(try metadata(taskID: original.id, evidence: replay), kind: .status)
        }
        try await fixture.channel.waitForDelivery()
        XCTAssertEqual(fixture.model.messages, before)
        XCTAssertEqual(fixture.model.messages.first?.approvedActionEvidence, confirmed)
        XCTAssertEqual(fixture.model.latestTerminalOutcome, .taskCompleted)
    }

    func testActionEvidenceRejectsForeignHostPairingSessionTaskAndWrongEnvelopeKind() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Original request"))
        let original = try await fixture.channel.prompt(at: 0)
        let confirmed = try evidence(.confirmed), body = try metadata(taskID: original.id, evidence: confirmed)
        await fixture.channel.deliver(body, kind: .status, senderID: "FOREIGN")
        await fixture.channel.deliver(body, kind: .status, pairingCode: "654321")
        await fixture.channel.deliver(body, kind: .status, sessionID: "foreign-session")
        await fixture.channel.deliver(try metadata(taskID: "unknown-task", evidence: confirmed), kind: .status)
        await fixture.channel.deliver(body, kind: .assistant)
        try await fixture.channel.waitForDelivery()
        XCTAssertTrue(fixture.model.messages.allSatisfy { $0.approvedActionEvidence == nil })
        XCTAssertTrue(fixture.model.hasActivePrompt)
        await fixture.channel.deliver(body, kind: .status)
        try await fixture.channel.waitForDelivery()
        XCTAssertEqual(fixture.model.messages.first?.approvedActionEvidence, confirmed)
    }

    func testMalformedEvidenceStatusCannotBecomeLegacyProgressOrClearRetry() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start()
        await fixture.channel.failNextPrompt()
        XCTAssertTrue(fixture.model.sendPrompt("Original request"))
        let original = try await fixture.channel.prompt(at: 0)
        try await fixture.wait { fixture.model.retryPrompt != nil }
        let before = snapshot(fixture)
        for body in [#"{"taskID":"broken","text":"working","approvedActionEvidence":{}}"#, "[malformed",
                     "{\"taskID\":\"\(original.id)\",\"text\":\"working\",\"isApprovedActionEvidenceOnly\":true}"] {
            await fixture.channel.deliver(body, kind: .status)
        }
        await fixture.channel.deliver(try metadata(taskID: original.id, evidence: evidence(.confirmed)), kind: .status)
        try await fixture.channel.waitForDelivery()
        XCTAssertEqual(snapshot(fixture), before)
        XCTAssertNotNil(fixture.model.messages.first?.approvedActionEvidence)
    }

    func testEvidenceCapabilityIsAdvertisedForRequestsAndAnswersWithoutAddingAnnotationsToModelContext() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Draft an email"))
        let original = try await fixture.channel.prompt(at: 0)
        XCTAssertTrue(try ComputerUsePromptRequest.decodeBody(original.body).supportsApprovedActionEvidence)
        let question = "Who should receive the email?"
        await fixture.channel.deliver(try ComputerUseTaskUpdate(taskID: original.id, text: question,
            approvedActionEvidence: evidence(.confirmed, summary: "Private helper receipt")).encodedBody())
        try await fixture.channel.waitForDelivery()
        XCTAssertEqual(fixture.model.composerMode, .legacyAnswer)
        XCTAssertTrue(fixture.model.sendPrompt("alex@example.invalid"))
        let answer = try await fixture.channel.prompt(at: 1)
        let decoded = try ComputerUsePromptRequest.decodeBody(answer.body)
        XCTAssertTrue(decoded.supportsApprovedActionEvidence)
        XCTAssertEqual(decoded.conversation, [.init(role: .user, text: "Draft an email"), .init(role: .assistant, text: question)])
        XCTAssertFalse(decoded.modelPrompt.contains("Private helper receipt"))
        let reference = try await fixture.question(for: answer)
        let exact = "  e\u{301} 😀\n  "
        XCTAssertTrue(fixture.model.sendPrompt(exact))
        let exactAnswer = try ComputerUsePromptRequest.decodeBody(await fixture.channel.prompt(at: 2).body)
        XCTAssertTrue(exactAnswer.supportsApprovedActionEvidence)
        XCTAssertTrue(exactAnswer.prompt.utf8.elementsEqual(exact.utf8))
        XCTAssertEqual(exactAnswer.clarification, reference); XCTAssertTrue(exactAnswer.conversation.isEmpty)
    }

    private func evidence(_ state: ComputerUseApprovedActionEvidence.State,
        actionID: String = String(repeating: "a", count: 64), summary: String = "Confirmed fixture action",
        resultDigest: String = String(repeating: "b", count: 64)) throws -> ComputerUseApprovedActionEvidence {
        try ComputerUseApprovedActionEvidence(actionID: actionID, state: state,
            summary: state == .confirmed ? summary : nil, resultDigest: state == .confirmed ? resultDigest : nil)
    }

    private func metadata(taskID: String, evidence: ComputerUseApprovedActionEvidence) throws -> String {
        try ComputerUseTaskUpdate(taskID: taskID, text: "", approvedActionEvidence: evidence,
            isApprovedActionEvidenceOnly: true).encodedBody()
    }

    private struct LifecycleSnapshot: Equatable {
        let state: ComputerUseSessionModel.State
        let status: String
        let active: Bool
        let cancellationPending: Bool
        let outcome: ComputerUseTerminalOutcome?
        let progress: [String]
        let retry: String?
        let composer: ComputerUseSessionModel.ComposerMode
        let pending: ComputerUsePendingPrompt?
    }

    private func snapshot(_ fixture: ClarificationClientFixture) -> LifecycleSnapshot {
        .init(state: fixture.model.state, status: fixture.model.statusText, active: fixture.model.hasActivePrompt,
            cancellationPending: fixture.model.isCancellationPending, outcome: fixture.model.latestTerminalOutcome,
            progress: fixture.model.taskProgressHistory, retry: fixture.model.retryPrompt, composer: fixture.model.composerMode,
            pending: fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"))
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
    func question(for request: ComputerUseEnvelope, text: String = "Which field?", lifetime: TimeInterval = 300,
                  answerPolicy: ComputerUseClarificationAnswerPolicy? = nil) async throws -> ComputerUseClarificationReference {
        let reference = try ComputerUseClarificationReference(taskID: request.id, expiresAt: Date().addingTimeInterval(lifetime))
        await channel.deliver(try ComputerUseTaskUpdate(taskID: request.id, text: text, outcome: .userInterventionRequired,
            clarification: reference, clarificationAnswerPolicy: answerPolicy).encodedBody())
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
    func deliver(_ body: String, kind: ComputerUseEnvelope.Kind = .assistant, senderID: String = "HOST-ID",
        pairingCode: String = "123456", sessionID: String = "session-1") {
        deliveredCount += 1
        incoming.append(.init(senderID: senderID, targetID: "IOS-ID", pairingCode: pairingCode, sessionID: sessionID, kind: kind, body: body))
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

import XCTest
import Security
@testable import RemoteDesktop

@MainActor
final class ComputerUseClarificationClientTests: XCTestCase {
    func testConditionalRecoveryWritesAcrossStoreInstancesHaveOneWinnerAndPreserveExactUnicode() async throws {
        let keychain = ClarificationKeychainFixture()
        let first = ComputerUsePendingPromptStore(service: "fixture", keychain: keychain)
        let second = ComputerUsePendingPromptStore(service: "fixture", keychain: keychain)
        let original = ComputerUsePendingPrompt(hostID: "HOST-ID", pairingCode: "123456", sessionID: "session-1",
            messageID: "task-1", prompt: "Find tickets.", createdAt: Date())
        XCTAssertEqual(first.replace(original, expecting: nil), .applied)
        let precomposed = ComputerUsePendingPrompt(hostID: original.hostID, pairingCode: original.pairingCode,
            sessionID: original.sessionID, messageID: original.messageID, prompt: "Find é tickets.", createdAt: original.createdAt)
        let decomposed = ComputerUsePendingPrompt(hostID: original.hostID, pairingCode: original.pairingCode,
            sessionID: original.sessionID, messageID: original.messageID, prompt: "Find e\u{301} tickets.", createdAt: original.createdAt)
        XCTAssertEqual(precomposed, decomposed)
        XCTAssertFalse(ComputerUsePendingPrompt.sameRecoveryState(precomposed, decomposed))
        let a = Task.detached { first.replace(precomposed, expecting: original) }
        let b = Task.detached { second.replace(decomposed, expecting: original) }
        let outcomes = [await a.value, await b.value]
        XCTAssertEqual(outcomes.filter { $0 == .applied }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .conflict }.count, 1)
        let winner = try XCTUnwrap(first.read(hostID: original.hostID, pairingCode: original.pairingCode, localAccountBinding: nil))
        let loser = ComputerUsePendingPrompt.sameRecoveryState(winner, precomposed) ? decomposed : precomposed
        let before = keychain.snapshot, mutations = keychain.mutationCount
        XCTAssertEqual(second.replace(original, expecting: loser), .conflict)
        XCTAssertEqual(second.remove(ifMatching: loser), .conflict)
        XCTAssertEqual(first.remove(ifMatching: original), .conflict)
        XCTAssertEqual(first.replace(original, expecting: nil), .conflict)
        XCTAssertEqual(keychain.snapshot, before); XCTAssertEqual(keychain.mutationCount, mutations)
        XCTAssertEqual(second.remove(ifMatching: winner), .applied)
        XCTAssertNil(try first.read(hostID: original.hostID, pairingCode: original.pairingCode, localAccountBinding: nil))
    }

    func testConditionalRecoveryMutationFailuresDoNotEraseOrReplaceTheOwnedRecord() throws {
        let keychain = ClarificationKeychainFixture()
        let observedStore = ComputerUsePendingPromptStore(service: "observed", keychain: keychain)
        let record = ComputerUsePendingPrompt(hostID: "HOST-ID", pairingCode: "123456", sessionID: "session-1",
            messageID: "task-1", prompt: "Find tickets.", createdAt: Date())
        XCTAssertEqual(observedStore.replace(record, expecting: nil), .applied)
        let bytes = keychain.snapshot
        keychain.readStatus = errSecInteractionNotAllowed
        XCTAssertEqual(observedStore.replace(record.rebindingPairingCode("654321"), expecting: record), .unavailable)
        XCTAssertEqual(observedStore.remove(ifMatching: record), .unavailable)
        keychain.readStatus = nil; keychain.updateStatus = errSecNotAvailable
        XCTAssertEqual(observedStore.replace(record.rebindingPairingCode("654321"), expecting: record), .unavailable)
        XCTAssertEqual(keychain.snapshot, bytes)
        keychain.updateStatus = nil; keychain.deleteStatus = errSecInteractionNotAllowed
        XCTAssertEqual(observedStore.remove(ifMatching: record), .unavailable)
        XCTAssertEqual(keychain.snapshot, bytes)
        keychain.deleteStatus = nil
        XCTAssertEqual(observedStore.replace(record.rebindingPairingCode("654321"), expecting: record), .applied)
        let reboundBytes = keychain.snapshot
        XCTAssertEqual(observedStore.replace(record, expecting: record), .conflict)
        XCTAssertEqual(observedStore.remove(ifMatching: record), .conflict)
        XCTAssertEqual(keychain.snapshot, reboundBytes)
        XCTAssertEqual(observedStore.remove(ifMatching: record.rebindingPairingCode("654321")), .applied)
        XCTAssertNil(keychain.snapshot)
        XCTAssertEqual(observedStore.remove(ifMatching: record), .conflict)
    }

    func testStaleActiveClientCannotReplaceOrDeleteANewerTaskThroughRepliesControlsOrRefresh() async throws {
        for action in ["terminal", "question", "pause", "resume", "approval", "refresh"] {
            let fixture = ClarificationClientFixture()
            defer { fixture.model.stop() }
            fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Find concert tickets."))
            let root = try await fixture.channel.prompt(at: 0)
            let approval = ComputerUseApprovalRequest(taskID: root.id, message: "Approve the original action?")
            if action == "approval" {
                await fixture.channel.deliver(try approval.encodedBody(), kind: .approvalRequest)
                try await fixture.channel.waitForDelivery()
            }
            if action == "refresh" { fixture.model.stop() }
            let newer = ComputerUsePendingPrompt(hostID: "HOST-ID", pairingCode: "123456", sessionID: "other-session",
                messageID: "other-task", prompt: "Find movie tickets.", createdAt: Date())
            XCTAssertTrue(fixture.store.save(newer))
            switch action {
            case "terminal":
                await fixture.channel.deliver(try ComputerUseTaskUpdate(taskID: root.id, text: "Done.", outcome: .taskCompleted).encodedBody())
            case "question":
                let ref = try ComputerUseClarificationReference(taskID: root.id, expiresAt: Date().addingTimeInterval(300))
                await fixture.channel.deliver(try ComputerUseTaskUpdate(taskID: root.id, text: "Which city?", outcome: .userInterventionRequired,
                    clarification: ref, supportsClarificationRecovery: true).encodedBody())
            case "pause": fixture.model.takeControl()
            case "resume": fixture.model.resumeAI()
            case "approval": fixture.model.respondToApproval(approval, approved: true)
            default: fixture.model.start()
            }
            try await fixture.wait { fixture.model.promptValidationMessage("New task")?.contains("reconnect") == true }
            XCTAssertEqual(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"), newer, action)
            XCTAssertFalse(fixture.model.sendPrompt("Replace it")); XCTAssertFalse(fixture.model.startNewRequest())
            let count = await fixture.channel.sentCount(); XCTAssertEqual(count, 1, action)
        }
    }

    func testQuestionRetirementFailureKeepsItsRecoveryUntilExplicitRetrySucceeds() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Find tickets."))
        let root = try await fixture.channel.prompt(at: 0)
        let reference = try await fixture.question(for: root, supportsRecovery: true)
        let saved = try XCTUnwrap(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"))
        fixture.store.permitsRemove = false
        XCTAssertFalse(fixture.model.startNewRequest())
        XCTAssertEqual(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"), saved)
        guard case .answer(let retained, _) = fixture.model.composerMode else { return XCTFail("Keep the question when retirement fails") }
        XCTAssertEqual(retained, reference)
        fixture.store.permitsRemove = true
        XCTAssertTrue(fixture.model.startNewRequest())
        XCTAssertNil(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"))
        XCTAssertTrue(fixture.model.sendPrompt("Find movies."))
        _ = try await fixture.channel.prompt(at: 1)
    }

    func testTerminalRetirementFailureRequiresRecoveryWithTheOriginalTaskIdentity() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Find tickets."))
        let root = try await fixture.channel.prompt(at: 0)
        let saved = try XCTUnwrap(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"))
        fixture.store.permitsRemove = false
        await fixture.channel.deliver(try ComputerUseTaskUpdate(taskID: root.id, text: "Done.", outcome: .taskCompleted).encodedBody())
        try await fixture.wait { !fixture.model.hasActivePrompt }
        XCTAssertEqual(fixture.model.latestTerminalOutcome, .taskCompleted)
        XCTAssertFalse(fixture.model.sendPrompt("Another task"))
        XCTAssertEqual(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"), saved)
        fixture.model.stop(); fixture.store.permitsRemove = true
        let channel = ClarificationClientChannel()
        let recovered = ComputerUseSessionModel(hostName: "Mac", pairingCode: "123456", hostID: "HOST-ID",
            pendingStore: fixture.store, channel: channel)
        defer { recovered.stop() }
        recovered.start()
        let replay = try await channel.prompt(at: 0)
        XCTAssertEqual(replay.id, root.id); XCTAssertTrue(replay.body.utf8.elementsEqual(root.body.utf8))
        await channel.deliver(try ComputerUseTaskUpdate(taskID: root.id, text: "Done.", outcome: .taskCompleted).encodedBody())
        try await channel.waitForDelivery()
        XCTAssertNil(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"))
        XCTAssertTrue(recovered.sendPrompt("Another task"))
        _ = try await channel.prompt(at: 1)
    }

    func testSecureStoreReadFailuresAndInvalidRecordsNeverDeleteRecoveryData() throws {
        let keychain = ClarificationKeychainFixture()
        let store = ComputerUsePendingPromptStore(service: "fixture", keychain: keychain)
        let binding = try XCTUnwrap(CloudKitAccountBinding(rawValue: String(repeating: "a", count: 64)))
        let request = ComputerUsePromptRequest(prompt: "Find tickets.")
        let pending = ComputerUsePendingPrompt(hostID: "HOST-ID", pairingCode: "123456", sessionID: "original-session",
            messageID: "original-task", prompt: request.prompt, wireBody: try request.encodedBody(), createdAt: Date(),
            localAccountBinding: binding)
        XCTAssertTrue(store.save(pending))
        let original = keychain.snapshot, mutations = keychain.mutationCount
        for status in [errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed, errSecDecode] {
            keychain.readStatus = status
            XCTAssertThrowsError(try store.read(hostID: "HOST-ID", pairingCode: "123456", localAccountBinding: binding)) {
                guard case ComputerUsePendingPromptReadError.unavailable = $0 else { return XCTFail("Report unavailable storage") }
            }
            XCTAssertThrowsError(try store.readForLocalRecovery(hostID: "HOST-ID", localAccountBinding: binding))
            XCTAssertNil(store.load(hostID: "HOST-ID", pairingCode: "123456", localAccountBinding: binding))
            XCTAssertNil(store.loadForLocalRecovery(hostID: "HOST-ID", localAccountBinding: binding))
            XCTAssertEqual(keychain.snapshot, original); XCTAssertEqual(keychain.mutationCount, mutations)
        }
        keychain.readStatus = nil
        XCTAssertEqual(try store.readForLocalRecovery(hostID: "HOST-ID", localAccountBinding: binding), pending)
        XCTAssertEqual(try store.read(hostID: "HOST-ID", pairingCode: "123456", localAccountBinding: binding), pending)
        XCTAssertThrowsError(try store.read(hostID: "HOST-ID", pairingCode: "654321", localAccountBinding: binding)) {
            guard case ComputerUsePendingPromptReadError.pairingChanged = $0 else { return XCTFail("Keep earlier connection state distinct from absence") }
        }
        XCTAssertNil(store.load(hostID: "HOST-ID", pairingCode: "654321", localAccountBinding: binding))
        // Corrupt data, a successful lookup with no data, and the wrong
        // namespace are not evidence that a prior task never existed.
        for data in [Data("{broken".utf8), Data()] {
            keychain.snapshot = data
            XCTAssertThrowsError(try store.readForLocalRecovery(hostID: "HOST-ID", localAccountBinding: binding))
            XCTAssertEqual(keychain.snapshot, data); XCTAssertEqual(keychain.mutationCount, mutations)
        }
        keychain.snapshot = nil; keychain.readStatus = errSecSuccess
        XCTAssertThrowsError(try store.readForLocalRecovery(hostID: "HOST-ID", localAccountBinding: binding))
        keychain.snapshot = original; keychain.readStatus = nil
        XCTAssertThrowsError(try store.read(hostID: "OTHER-HOST", pairingCode: "123456", localAccountBinding: binding))
        XCTAssertThrowsError(try store.read(hostID: "HOST-ID", pairingCode: "123456", localAccountBinding: nil))
        let expired = ComputerUsePendingPrompt(hostID: pending.hostID, pairingCode: pending.pairingCode,
            sessionID: pending.sessionID, messageID: pending.messageID, prompt: pending.prompt,
            wireBody: pending.wireBody, createdAt: Date().addingTimeInterval(-90_000), localAccountBinding: binding)
        let expiredBytes = try JSONEncoder().encode(expired)
        keychain.snapshot = expiredBytes
        XCTAssertNil(try store.readForLocalRecovery(hostID: "HOST-ID", localAccountBinding: binding))
        XCTAssertEqual(keychain.snapshot, expiredBytes); XCTAssertEqual(keychain.mutationCount, mutations)
        keychain.snapshot = nil
        XCTAssertNil(try store.readForLocalRecovery(hostID: "HOST-ID", localAccountBinding: binding))
        XCTAssertEqual(keychain.mutationCount, mutations)
    }

    func testUnreadableStartupCannotSendOrChooseANewSessionBeforeReconnect() async throws {
        for isQuestion in [false, true] {
            let keychain = ClarificationKeychainFixture()
            let store = ComputerUsePendingPromptStore(service: "fixture", keychain: keychain)
            let request = ComputerUsePromptRequest(prompt: "Find tickets.")
            let reference = try ComputerUseClarificationReference(taskID: "original-task", expiresAt: Date().addingTimeInterval(300))
            let question = try ComputerUsePendingQuestion(reference: reference, text: "Which city?", answerPolicy: nil,
                receivedAt: Date(), validUntil: reference.expiresAt, draft: "  e\u{301} Paris\n")
            let pending = ComputerUsePendingPrompt(hostID: "HOST-ID", pairingCode: "123456", sessionID: "original-session",
                messageID: reference.taskID, prompt: request.prompt, wireBody: try request.encodedBody(), createdAt: Date(),
                question: isQuestion ? question : nil)
            XCTAssertTrue(store.save(pending))
            let original = keychain.snapshot, mutations = keychain.mutationCount
            keychain.readStatus = errSecInteractionNotAllowed
            let channel = ClarificationClientChannel()
            let blocked = ComputerUseSessionModel(hostName: "Mac", pairingCode: "123456", hostID: "HOST-ID",
                sessionID: "unrelated-session", pendingStore: store, channel: channel)
            blocked.start()
            XCTAssertTrue(blocked.isLiveScreenPrivacyShielded)
            XCTAssertNotNil(blocked.promptValidationMessage("Another task"))
            XCTAssertFalse(blocked.sendPrompt("Another task")); XCTAssertFalse(blocked.startNewRequest())
            blocked.retryLastPrompt(); blocked.retryQuestionRecovery()
            blocked.stop(); blocked.start()
            keychain.readStatus = nil
            XCTAssertFalse(blocked.sendPrompt("Another task"), "Restoring storage cannot authenticate a different session in place")
            blocked.stop()
            let count = await channel.sentCount(); XCTAssertEqual(count, 0)
            XCTAssertEqual(keychain.snapshot, original); XCTAssertEqual(keychain.mutationCount, mutations)
            let restored = ComputerUseSessionModel(hostName: "Mac", pairingCode: "123456", hostID: "HOST-ID",
                pendingStore: store, channel: channel)
            defer { restored.stop() }
            restored.start()
            if isQuestion {
                let probe = try await channel.probe(at: 0)
                XCTAssertEqual(probe.reference, reference); XCTAssertEqual(restored.composerMode, .recoveringAnswer)
                let prompts = await channel.promptCount(); XCTAssertEqual(prompts, 0)
            } else {
                let prompt = try await channel.prompt(at: 0)
                XCTAssertEqual(prompt.id, pending.messageID); XCTAssertEqual(prompt.sessionID, pending.sessionID)
                XCTAssertTrue(prompt.body.utf8.elementsEqual(pending.exactWireBody.utf8))
            }
        }
    }

    func testQuestionReadOutageRetainsDraftAndRequiresANewProbeAfterStorageReturns() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Find concert tickets."))
        let root = try await fixture.channel.prompt(at: 0)
        let reference = try await fixture.question(for: root, supportsRecovery: true)
        let saved = try XCTUnwrap(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"))
        let question = try XCTUnwrap(saved.question), draft = "  e\u{301} Paris 😀\n"
        fixture.model.updateQuestionDraft(draft)
        fixture.store.permitsRead = false
        fixture.model.stop() // Flush encounters unavailable storage.
        XCTAssertEqual(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"), saved)
        fixture.model.start()
        XCTAssertEqual(fixture.model.composerMode, .recoveringAnswer); XCTAssertTrue(fixture.model.canRetryQuestionRecovery)
        XCTAssertFalse(fixture.model.startNewRequest()); XCTAssertFalse(fixture.model.sendPrompt("Paris"))
        XCTAssertEqual(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"), saved)
        fixture.store.permitsRead = true
        fixture.model.retryQuestionRecovery()
        let first = try await fixture.channel.probe(at: 0)
        fixture.store.permitsRead = false
        await fixture.channel.deliver(try ComputerUseClarificationProbeResult(probeID: first.probeID, reference: reference,
            question: question.text, answerPolicy: nil).encodedBody(), kind: .status)
        try await fixture.channel.waitForDelivery()
        XCTAssertEqual(fixture.model.composerMode, .recoveringAnswer)
        XCTAssertEqual(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"), saved)
        fixture.store.permitsRead = true
        fixture.model.retryQuestionRecovery()
        let second = try await fixture.channel.probe(at: 1)
        XCTAssertNotEqual(first.probeID, second.probeID)
        await fixture.channel.deliver(try ComputerUseClarificationProbeResult(probeID: first.probeID, reference: reference,
            question: question.text, answerPolicy: nil).encodedBody(), kind: .status)
        try await fixture.channel.waitForDelivery()
        XCTAssertEqual(fixture.model.composerMode, .recoveringAnswer)
        await fixture.channel.deliver(try ComputerUseClarificationProbeResult(probeID: second.probeID, reference: reference,
            question: question.text, answerPolicy: nil).encodedBody(), kind: .status)
        try await fixture.channel.waitForDelivery()
        XCTAssertEqual(fixture.model.composerMode, .answer(reference, validUntil: question.validUntil))
        XCTAssertTrue(try XCTUnwrap(fixture.model.restoredClarificationDraft).utf8.elementsEqual(draft.utf8))
        let recovered = try XCTUnwrap(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456")?.question)
        XCTAssertEqual(recovered.receivedAt, question.receivedAt); XCTAssertEqual(recovered.validUntil, question.validUntil)
        XCTAssertTrue(try XCTUnwrap(recovered.draft).utf8.elementsEqual(draft.utf8))
        let count = await fixture.channel.promptCount(); XCTAssertEqual(count, 1)
        XCTAssertTrue(fixture.model.sendPrompt(draft))
        let answer = try ComputerUsePromptRequest.decodeBody(await fixture.channel.prompt(at: 1).body)
        XCTAssertEqual(answer.clarification, reference); XCTAssertTrue(answer.prompt.utf8.elementsEqual(draft.utf8))
    }

    func testIdleClientCannotOverwriteARequestHiddenByAReadFailureOrSavedByAnotherInstance() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start()
        let pending = ComputerUsePendingPrompt(hostID: "HOST-ID", pairingCode: "123456", sessionID: "other-session",
            messageID: "other-task", prompt: "Existing task", createdAt: Date())
        XCTAssertTrue(fixture.store.save(pending))
        fixture.store.permitsRead = false
        XCTAssertFalse(fixture.model.sendPrompt("New task"))
        XCTAssertEqual(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"), pending)
        fixture.store.permitsRead = true
        XCTAssertFalse(fixture.model.sendPrompt("New task"))
        XCTAssertFalse(fixture.model.startNewRequest())
        XCTAssertTrue(fixture.model.statusText.contains("Reconnect"))
        XCTAssertEqual(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"), pending)
        let count = await fixture.channel.sentCount(); XCTAssertEqual(count, 0)
    }

    func testSavedQuestionRestoresOnlyAfterFreshScopedProbeAndAnswerReplacesItsDraftRecord() async throws {
        var now = Date()
        let fixture = ClarificationClientFixture(now: { now })
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Find concert tickets."))
        let root = try await fixture.channel.prompt(at: 0)
        let policy = try ComputerUseClarificationAnswerPolicy(maximumUTF8Bytes: 8_192, requiresNonblank: true, supportsRetry: true)
        let choice = try ComputerUseClarificationChoice(id: "presentation", label: "Deck.pptx", detail: "PowerPoint · 8 MB")
        let choices = [choice]
        let reference = try await fixture.question(for: root, lifetime: 1_800, answerPolicy: policy, supportsRecovery: true, choices: choices)
        let draft = "  Paris e\u{301} 😀\n  "
        fixture.model.updateQuestionDraft(draft.precomposedStringWithCanonicalMapping)
        try await fixture.wait { fixture.store.load(hostID: "HOST-ID", pairingCode: "123456")?.question?.draft != nil }
        fixture.model.updateQuestionDraft(draft); fixture.model.stop()
        let saved = try XCTUnwrap(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456")), question = try XCTUnwrap(saved.question)
        XCTAssertTrue(saved.hasValidQuestionRecovery); XCTAssertEqual(question.reference, reference)
        XCTAssertEqual(question.choices, choices)
        XCTAssertTrue(try XCTUnwrap(question.draft).utf8.elementsEqual(draft.utf8))
        XCTAssertEqual(try JSONDecoder().decode(ComputerUsePendingPrompt.self, from: JSONEncoder().encode(saved)), saved)
        XCTAssertEqual(saved.rebindingPairingCode("654321").question, question)
        now = now.addingTimeInterval(30)
        let channel = ClarificationClientChannel()
        let recovered = ComputerUseSessionModel(hostName: "Mac", pairingCode: "123456", hostID: "HOST-ID",
            pendingStore: fixture.store, channel: channel, now: { now })
        defer { recovered.stop() }
        recovered.start()
        let probe = try await channel.probe(at: 0)
        XCTAssertEqual(probe.reference, reference); XCTAssertEqual(recovered.composerMode, .recoveringAnswer)
        XCTAssertFalse(recovered.hasActivePrompt); XCTAssertFalse(recovered.sendPrompt("Paris"))
        let promptCount = await channel.promptCount(); XCTAssertEqual(promptCount, 0)
        // An old normal reply and replies to a different probe or controller
        // are not fresh proof for this recovery attempt.
        await channel.deliver(try ComputerUseTaskUpdate(taskID: root.id, text: question.text, outcome: .userInterventionRequired,
            clarification: reference, supportsClarificationRecovery: true).encodedBody())
        let wrong = try ComputerUseClarificationProbeResult(probeID: UUID(), reference: reference, question: question.text, answerPolicy: policy, clarificationChoices: choices)
        await channel.deliver(try wrong.encodedBody(), kind: .status)
        let valid = try ComputerUseClarificationProbeResult(probeID: probe.probeID, reference: reference, question: question.text, answerPolicy: policy, clarificationChoices: choices)
        for (sender, pairing, session) in [("OTHER", "123456", "session-1"), ("HOST-ID", "654321", "session-1"), ("HOST-ID", "123456", "other")] {
            await channel.deliver(try valid.encodedBody(), kind: .status, senderID: sender, pairingCode: pairing, sessionID: session)
        }
        try await channel.waitForDelivery()
        XCTAssertEqual(recovered.composerMode, .recoveringAnswer)
        let changedChoices = [try ComputerUseClarificationChoice(id: choice.id, label: "Different file", detail: choice.detail)]
        let changed = try ComputerUseClarificationProbeResult(probeID: probe.probeID, reference: reference,
            question: question.text, answerPolicy: policy, clarificationChoices: changedChoices)
        await channel.deliver(try changed.encodedBody(), kind: .status); try await channel.waitForDelivery()
        XCTAssertEqual(recovered.composerMode, .recoveringAnswer, "A fresh question with changed options cannot revive stale persisted choices")
        await channel.deliver(try valid.encodedBody(), kind: .status); try await channel.waitForDelivery()
        XCTAssertEqual(recovered.composerMode, .answer(reference, validUntil: question.validUntil))
        XCTAssertEqual(recovered.clarificationChoices, choices)
        XCTAssertTrue(try XCTUnwrap(recovered.restoredClarificationDraft).utf8.elementsEqual(draft.utf8))
        recovered.updateQuestionDraft("Paris")
        guard recovered.sendClarificationChoice(choice.id) else {
            XCTFail("A choice restored from the fresh matching host probe should dispatch")
            return
        }
        let answer = try await channel.prompt(at: 0), decoded = try ComputerUsePromptRequest.decodeBody(answer.body)
        XCTAssertNotEqual(answer.id, root.id); XCTAssertEqual(decoded.clarification, reference)
        XCTAssertEqual(decoded.clarificationChoiceID, choice.id); XCTAssertEqual(decoded.prompt, choice.label)
        XCTAssertTrue(decoded.conversation.isEmpty)
        recovered.stop()
        let active = try XCTUnwrap(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"))
        XCTAssertNil(active.question); XCTAssertEqual(active.messageID, answer.id)
        XCTAssertEqual(active.clarificationValidUntil, question.validUntil)
        fixture.model.stop(); fixture.model.start()
        XCTAssertEqual(fixture.model.composerMode, .expiredAnswer)
        XCTAssertEqual(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"), active,
            "An older question model must not overwrite or remove a newer answer record")
    }

    func testSavedQuestionTimeoutRetryExpiryAndUnavailabilityNeverRenewOrReviveItsScope() async throws {
        for expire in [false, true] {
            var now = Date()
            let fixture = ClarificationClientFixture(now: { now }, questionRecoveryTimeout: .milliseconds(20))
            defer { fixture.model.stop() }
            fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Find tickets."))
            let root = try await fixture.channel.prompt(at: 0)
            let reference = try await fixture.question(for: root, supportsRecovery: true)
            let question = try XCTUnwrap(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456")?.question)
            fixture.model.stop(); fixture.model.start()
            let first = try await fixture.channel.probe(at: 0)
            try await fixture.wait { fixture.model.canRetryQuestionRecovery }
            fixture.model.retryQuestionRecovery()
            let second = try await fixture.channel.probe(at: 1)
            XCTAssertNotEqual(first.probeID, second.probeID)
            await fixture.channel.deliver(try ComputerUseClarificationProbeResult(probeID: first.probeID, reference: reference,
                question: question.text).encodedBody(), kind: .status)
            try await fixture.channel.waitForDelivery()
            XCTAssertEqual(fixture.model.composerMode, .recoveringAnswer)
            if expire { now = question.validUntil }
            await fixture.channel.deliver(try ComputerUseClarificationProbeResult(probeID: second.probeID, reference: reference,
                question: expire ? question.text : nil).encodedBody(), kind: .status)
            try await fixture.channel.waitForDelivery()
            XCTAssertEqual(fixture.model.composerMode, .expiredAnswer); XCTAssertFalse(fixture.model.sendPrompt("Paris"))
            XCTAssertNil(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"))
            XCTAssertTrue(fixture.model.startNewRequest()); XCTAssertTrue(fixture.model.sendPrompt("Find movies in Paris."))
            let next = try await fixture.channel.prompt(at: 1)
            await fixture.channel.deliver(try ComputerUseClarificationProbeResult(probeID: second.probeID, reference: reference,
                question: question.text).encodedBody(), kind: .status)
            try await fixture.channel.waitForDelivery()
            XCTAssertTrue(fixture.model.hasActivePrompt); XCTAssertEqual(fixture.model.composerMode, .request)
            XCTAssertEqual(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456")?.messageID, next.id)
        }
    }

    func testQuestionAndAnswerStorageFailuresPreserveThePreviousRecoverableState() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Find tickets."))
        let root = try await fixture.channel.prompt(at: 0)
        let reference = try ComputerUseClarificationReference(taskID: root.id, expiresAt: Date().addingTimeInterval(300))
        let body = try ComputerUseTaskUpdate(taskID: root.id, text: "Which city?", outcome: .userInterventionRequired,
            clarification: reference, supportsClarificationRecovery: true).encodedBody()
        fixture.store.permitsSave = false
        await fixture.channel.deliver(body); try await fixture.channel.waitForDelivery()
        XCTAssertTrue(fixture.model.hasActivePrompt); XCTAssertEqual(fixture.model.composerMode, .request)
        XCTAssertNil(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456")?.question)
        fixture.store.permitsSave = true
        await fixture.channel.deliver(body); try await fixture.channel.waitForDelivery()
        let saved = try XCTUnwrap(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"))
        guard case .answer = fixture.model.composerMode else { return XCTFail("Expected a securely saved question") }
        fixture.store.permitsSave = false
        XCTAssertFalse(fixture.model.sendPrompt("Paris"))
        XCTAssertEqual(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"), saved)
        fixture.model.stop(); fixture.model.start()
        let probe = try await fixture.channel.probe(at: 0)
        await fixture.channel.deliver(try ComputerUseClarificationProbeResult(probeID: probe.probeID, reference: reference,
            question: "Which city?").encodedBody(), kind: .status)
        try await fixture.channel.waitForDelivery()
        XCTAssertEqual(fixture.model.composerMode, .recoveringAnswer); XCTAssertTrue(fixture.model.canRetryQuestionRecovery)
        fixture.store.permitsSave = true; fixture.model.retryQuestionRecovery()
        let retry = try await fixture.channel.probe(at: 1)
        await fixture.channel.deliver(try ComputerUseClarificationProbeResult(probeID: retry.probeID, reference: reference,
            question: "Which city?").encodedBody(), kind: .status)
        try await fixture.channel.waitForDelivery()
        XCTAssertTrue(fixture.model.sendPrompt("Paris"))
        let answer = try await fixture.channel.prompt(at: 1)
        XCTAssertEqual(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456")?.messageID, answer.id)
        XCTAssertNil(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456")?.question)
    }

    func testRejectedAnswerQuestionRecoveryProbesTheOriginalReferenceWithoutResendingTheRejectedAttempt() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Find tickets."))
        let root = try await fixture.channel.prompt(at: 0)
        let reference = try await fixture.question(for: root,
            answerPolicy: .init(maximumUTF8Bytes: 256, requiresNonblank: false, supportsRetry: true), supportsRecovery: true)
        let draft = " \n "
        XCTAssertTrue(fixture.model.sendPrompt(draft))
        let attempt = try await fixture.channel.prompt(at: 1)
        let policy = try ComputerUseClarificationAnswerPolicy(maximumUTF8Bytes: 7, requiresNonblank: true, supportsRetry: true)
        let retry = try ComputerUseClarificationRetry(reference: reference, reason: .blank, answerPolicy: policy)
        await fixture.channel.deliver(try ComputerUseTaskUpdate(taskID: attempt.id, text: "Which field?", outcome: .userInterventionRequired,
            clarificationRetry: retry, supportsClarificationRecovery: true).encodedBody())
        try await fixture.channel.waitForDelivery()
        let saved = try XCTUnwrap(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"))
        XCTAssertEqual(saved.messageID, attempt.id); XCTAssertEqual(saved.question?.reference, reference)
        XCTAssertEqual(saved.question?.draft, draft); XCTAssertTrue(saved.hasValidQuestionRecovery)
        fixture.model.stop(); fixture.model.start()
        let probe = try await fixture.channel.probe(at: 0)
        XCTAssertEqual(probe.reference, reference)
        let count = await fixture.channel.promptCount(); XCTAssertEqual(count, 2)
        await fixture.channel.deliver(try ComputerUseClarificationProbeResult(probeID: probe.probeID, reference: reference,
            question: "Which field?", answerPolicy: policy).encodedBody(), kind: .status)
        try await fixture.channel.waitForDelivery()
        XCTAssertEqual(fixture.model.restoredClarificationDraft, draft); XCTAssertFalse(fixture.model.sendPrompt(draft))
        XCTAssertTrue(fixture.model.sendPrompt("Paris"))
        let correction = try ComputerUsePromptRequest.decodeBody(await fixture.channel.prompt(at: 2).body)
        XCTAssertEqual(correction.clarification, reference); XCTAssertEqual(correction.prompt, "Paris")
        XCTAssertTrue(correction.conversation.isEmpty)
    }

    func testSavedQuestionBoundsAndControlStateCannotBecomeAnExecutableRecoveryRecord() throws {
        let now = Date(), reference = try ComputerUseClarificationReference(taskID: "root", expiresAt: Date().addingTimeInterval(600))
        let deadline = now.addingTimeInterval(300)
        let question = try ComputerUsePendingQuestion(reference: reference, text: "Which field?", answerPolicy: nil,
            receivedAt: now, validUntil: deadline, draft: "  Paris  ")
        for invalid in [now, reference.expiresAt.addingTimeInterval(1), now.addingTimeInterval(601)] {
            XCTAssertThrowsError(try ComputerUsePendingQuestion(reference: reference, text: question.text, answerPolicy: nil,
                receivedAt: now, validUntil: invalid))
        }
        XCTAssertThrowsError(try question.withDraft(String(repeating: "😀", count: 8_193)))
        let body = try ComputerUsePromptRequest(prompt: "Find tickets.").encodedBody()
        let base = ComputerUsePendingPrompt(hostID: "HOST-ID", pairingCode: "123456", sessionID: "session-1", messageID: "root",
            prompt: "Find tickets.", wireBody: body, createdAt: now)
        XCTAssertNil(try JSONDecoder().decode(ComputerUsePendingPrompt.self, from: JSONEncoder().encode(base)).question)
        XCTAssertTrue(base.retainingQuestion(question).hasValidQuestionRecovery)
        let cancelled = ComputerUsePendingPrompt(hostID: "HOST-ID", pairingCode: "123456", sessionID: "session-1", messageID: "root",
            prompt: "Find tickets.", wireBody: body, createdAt: now, lastControlKind: .cancel, question: question)
        XCTAssertFalse(cancelled.hasValidQuestionRecovery)
        let foreign = ComputerUsePendingPrompt(hostID: "HOST-ID", pairingCode: "123456", sessionID: "session-1", messageID: "other",
            prompt: "Find tickets.", wireBody: body, createdAt: now, question: question)
        XCTAssertFalse(foreign.hasValidQuestionRecovery)
    }

    func testUnavailableBrowserQuestionReplayEndsRecoveryWithoutOpeningAnAnswerComposer() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Find concert tickets."))
        let original = try await fixture.channel.prompt(at: 0)
        fixture.model.stop()
        let channel = ClarificationClientChannel()
        let recovered = ComputerUseSessionModel(hostName: "Mac", pairingCode: "123456", hostID: "HOST-ID",
            pendingStore: fixture.store, channel: channel)
        defer { recovered.stop() }
        recovered.start()
        let replay = try await channel.prompt(at: 0)
        XCTAssertEqual(replay.id, original.id); XCTAssertTrue(replay.body.utf8.elementsEqual(original.body.utf8))
        await channel.deliver(try ComputerUseTaskUpdate(taskID: original.id,
            text: "The original question is no longer active. Start a new request with the complete instruction.",
            outcome: .unableToComplete).encodedBody())
        try await channel.waitForDelivery()
        XCTAssertEqual(recovered.latestTerminalOutcome, .unableToComplete)
        XCTAssertEqual(recovered.composerMode, .request); XCTAssertFalse(recovered.hasActivePrompt)
        XCTAssertNil(recovered.restoredClarificationDraft); XCTAssertNil(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"))
        XCTAssertTrue(recovered.sendPrompt("Find movie tickets in Paris."))
        let next = try ComputerUsePromptRequest.decodeBody(await channel.prompt(at: 1).body)
        XCTAssertNil(next.clarification); XCTAssertTrue(next.conversation.isEmpty)
    }

    func testNewPausedInputEpochRetiresADelayedResumeAndTheNextHandbackUsesTheCurrentEpoch() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Find travel tickets"))
        let root = try await fixture.channel.prompt(at: 0)
        await fixture.channel.deliver(try ComputerUseTaskUpdate(taskID: root.id,
            text: ComputerUseStatusSignal.userIntervention("Finish signing in."), hostControlEpoch: 1,
            outcome: .userInterventionRequired).encodedBody(), kind: .status)
        try await fixture.channel.waitForDelivery()
        XCTAssertEqual(fixture.model.state, .paused)
        fixture.model.resumeAI()
        let delayed = try await fixture.channel.control(afterRevision: 0), first = try ComputerUseControlRequest.decodeBody(delayed.body)
        XCTAssertEqual(delayed.kind, .resume); XCTAssertEqual(first.observedHostControlEpoch, 1)
        await fixture.channel.deliver(try ComputerUseTaskUpdate(taskID: root.id,
            text: ComputerUseStatusSignal.userIntervention("You used the Mac while AI was paused. Choose Resume again when you are ready."),
            hostControlEpoch: 2, outcome: .userInterventionRequired).encodedBody(), kind: .status)
        try await fixture.channel.waitForDelivery()
        XCTAssertEqual(fixture.model.state, .paused); XCTAssertTrue(fixture.model.hasActivePrompt)
        let saved = try XCTUnwrap(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"))
        XCTAssertEqual(saved.messageID, root.id); XCTAssertEqual(saved.hostControlEpoch, 2); XCTAssertNil(saved.lastControlKind)
        await fixture.channel.deliver(try ComputerUseTaskUpdate(taskID: root.id, text: "working",
            appliedControlRevision: first.revision, hostControlEpoch: 1).encodedBody(), kind: .status)
        try await fixture.channel.waitForDelivery()
        XCTAssertEqual(fixture.model.state, .paused)
        fixture.model.resumeAI()
        let fresh = try await fixture.channel.control(afterRevision: first.revision), second = try ComputerUseControlRequest.decodeBody(fresh.body)
        XCTAssertEqual(fresh.kind, .resume); XCTAssertEqual(second.taskID, root.id)
        XCTAssertEqual(second.observedHostControlEpoch, 2); XCTAssertGreaterThan(second.revision, first.revision)
        await fixture.channel.deliver(try ComputerUseTaskUpdate(taskID: root.id, text: "working",
            appliedControlRevision: second.revision, hostControlEpoch: 2).encodedBody(), kind: .status)
        try await fixture.channel.waitForDelivery()
        XCTAssertEqual(fixture.model.state, .working)
        XCTAssertEqual(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456")?.messageID, root.id)
    }

    func testWholePartyQuestionRetainsAnIncompleteDraftAndSendsBothCountsUnderTheOriginalReference() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Find concert tickets for 2 adults and 1 child."))
        let root = try await fixture.channel.prompt(at: 0)
        let policy = try ComputerUseClarificationAnswerPolicy(maximumUTF8Bytes: 256, requiresNonblank: true, supportsRetry: true, format: .partyCounts)
        let reference = try await fixture.question(for: root, text: "What adult and child counts should replace this party?",
            answerPolicy: policy, supportsRecovery: true)
        let mode = fixture.model.composerMode, draft = "  3 adults.\n"
        fixture.model.updateQuestionDraft(draft)
        XCTAssertFalse(fixture.model.sendPrompt(draft)); XCTAssertEqual(fixture.model.composerMode, mode)
        XCTAssertEqual(fixture.model.statusText, policy.format?.instruction)
        try await fixture.wait { fixture.store.load(hostID: "HOST-ID", pairingCode: "123456")?.question?.draft == draft }
        let saved = try XCTUnwrap(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456")?.question)
        XCTAssertEqual(saved.answerPolicy, policy); XCTAssertEqual(saved.reference, reference)
        let correctedText = "zero children and 3 adults"
        XCTAssertTrue(fixture.model.sendPrompt(correctedText))
        let corrected = try await fixture.channel.prompt(at: 1), request = try ComputerUsePromptRequest.decodeBody(corrected.body)
        XCTAssertEqual(request.prompt, correctedText); XCTAssertEqual(request.clarification, reference)
        XCTAssertTrue(request.supportsClarificationRetry); XCTAssertTrue(request.supportsClarificationFormatRetry)
        XCTAssertEqual(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456")?.clarificationValidUntil, saved.validUntil)
    }

    func testUnknownExtendedAnswerFormatKeepsTheQuestionReadableWithoutNegotiatingFormatSupport() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Find tickets."))
        let root = try await fixture.channel.prompt(at: 0)
        let reference = try ComputerUseClarificationReference(taskID: root.id, expiresAt: Date().addingTimeInterval(300))
        let question = "Give both counts for this future question."
        let update = ComputerUseTaskUpdate(taskID: root.id, text: question, outcome: .userInterventionRequired, clarification: reference,
            clarificationAnswerPolicy: try .init(maximumUTF8Bytes: 256, requiresNonblank: true, supportsRetry: true), supportsClarificationRecovery: true)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(update.encodedBody().utf8)) as? [String: Any])
        var policy = try XCTUnwrap(fields["clarificationAnswerPolicy"] as? [String: Any]); policy["extendedFormat"] = "futureQuantity"
        fields["clarificationAnswerPolicy"] = policy
        await fixture.channel.deliver(String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self))
        try await fixture.channel.waitForDelivery()
        guard case .answer(let actual, _) = fixture.model.composerMode else { return XCTFail("Unknown advisory format must not erase its question") }
        XCTAssertEqual(actual, reference)
        XCTAssertEqual(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456")?.question?.text, question)
        XCTAssertTrue(fixture.model.sendPrompt("3 adults and 0 children"))
        let attempt = try await fixture.channel.prompt(at: 1), request = try ComputerUsePromptRequest.decodeBody(attempt.body)
        XCTAssertTrue(request.supportsClarificationRetry); XCTAssertFalse(request.supportsClarificationFormatRetry)
        XCTAssertEqual(request.clarification, reference)
    }

    func testCountQuestionRejectsExtraInstructionsLocallyAndKeepsTheSavedDraftForCorrection() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Find concert tickets for 2 adults and 1 child."))
        let root = try await fixture.channel.prompt(at: 0)
        let policy = try ComputerUseClarificationAnswerPolicy(maximumUTF8Bytes: 256, requiresNonblank: true, supportsRetry: true, format: .childCount)
        let reference = try await fixture.question(for: root, text: "What child count should replace 1 child? The adult count will remain 2.",
            answerPolicy: policy, supportsRecovery: true)
        let mode = fixture.model.composerMode, draft = "  0 children. Keep e\u{301} tickets.\n"
        fixture.model.updateQuestionDraft(draft)
        XCTAssertFalse(fixture.model.sendPrompt(draft))
        XCTAssertEqual(fixture.model.composerMode, mode); XCTAssertFalse(fixture.model.hasActivePrompt)
        XCTAssertEqual(fixture.model.statusText, policy.format?.instruction)
        try await fixture.wait { fixture.store.load(hostID: "HOST-ID", pairingCode: "123456")?.question?.draft == draft }
        let saved = try XCTUnwrap(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456")?.question)
        XCTAssertEqual(saved.reference, reference); XCTAssertEqual(saved.answerPolicy, policy)
        XCTAssertTrue(try XCTUnwrap(saved.draft).utf8.elementsEqual(draft.utf8))
        let sent = await fixture.channel.sentCount(); XCTAssertEqual(sent, 1)
        XCTAssertTrue(fixture.model.sendPrompt("zero children"))
        let corrected = try await fixture.channel.prompt(at: 1), request = try ComputerUsePromptRequest.decodeBody(corrected.body)
        XCTAssertEqual(request.prompt, "zero children"); XCTAssertEqual(request.clarification, reference)
        XCTAssertTrue(request.supportsClarificationRetry); XCTAssertTrue(request.supportsClarificationFormatRetry)
        XCTAssertEqual(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456")?.clarificationValidUntil, saved.validUntil)
    }

    func testFormatRetryRequiresExplicitSupportAndRestoresTheExactDraftWithoutRenewingItsDeadline() async throws {
        for negotiated in [false, true] {
            var now = Date()
            let fixture = ClarificationClientFixture(now: { now })
            defer { fixture.model.stop() }
            fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Find tickets for 2 adults and 1 child."))
            let root = try await fixture.channel.prompt(at: 0)
            // A mismatched controlled hint lets the answer reach native rejection.
            let reference = try await fixture.question(for: root, text: "Which count?", answerPolicy: .init(maximumUTF8Bytes: 256,
                requiresNonblank: true, supportsRetry: true, format: negotiated ? .adultCount : nil), supportsRecovery: true)
            guard case .answer(_, let deadline) = fixture.model.composerMode else { return XCTFail("Expected original question") }
            let draft = "  exactly 3 adults.\n"
            XCTAssertTrue(fixture.model.sendPrompt(draft))
            let attempt = try await fixture.channel.prompt(at: 1), submitted = try ComputerUsePromptRequest.decodeBody(attempt.body)
            XCTAssertTrue(submitted.supportsClarificationRetry); XCTAssertEqual(submitted.supportsClarificationFormatRetry, negotiated)
            now = now.addingTimeInterval(30)
            let retry = try ComputerUseClarificationRetry(reference: reference, reason: .formatMismatch,
                answerPolicy: .init(maximumUTF8Bytes: 256, requiresNonblank: true, supportsRetry: true, format: .childCount))
            let response = try ComputerUseTaskUpdate(taskID: attempt.id, text: "What child count? The adult count will remain 2.",
                outcome: .userInterventionRequired, clarificationRetry: retry, supportsClarificationRecovery: true).encodedBody()
            await fixture.channel.deliver(response); try await fixture.channel.waitForDelivery()
            if !negotiated {
                XCTAssertTrue(fixture.model.hasActivePrompt); XCTAssertNil(fixture.model.restoredClarificationDraft)
                XCTAssertEqual(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456")?.messageID, attempt.id)
                continue
            }
            XCTAssertEqual(fixture.model.composerMode, .answer(reference, validUntil: deadline))
            XCTAssertTrue(try XCTUnwrap(fixture.model.restoredClarificationDraft).utf8.elementsEqual(draft.utf8))
            XCTAssertEqual(fixture.model.statusText, retry.answerPolicy.message(for: .formatMismatch))
            let saved = try XCTUnwrap(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456")?.question)
            XCTAssertEqual(saved.validUntil, deadline); XCTAssertEqual(saved.answerPolicy, retry.answerPolicy)
            XCTAssertTrue(try XCTUnwrap(saved.draft).utf8.elementsEqual(draft.utf8))
            XCTAssertFalse(fixture.model.sendPrompt(draft)); XCTAssertEqual(fixture.model.restoredClarificationDraft, draft)
            XCTAssertTrue(fixture.model.sendPrompt("zero children"))
            let corrected = try await fixture.channel.prompt(at: 2)
            XCTAssertEqual(try ComputerUsePromptRequest.decodeBody(corrected.body).clarification, reference)
            XCTAssertEqual(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456")?.clarificationValidUntil, deadline)
            await fixture.channel.deliver(response); try await fixture.channel.waitForDelivery()
            XCTAssertTrue(fixture.model.hasActivePrompt); XCTAssertNil(fixture.model.restoredClarificationDraft)
        }
    }

    func testRejectedAnswerRestoresExactDraftQuestionAndOriginalDeadlineBeforeCorrection() async throws {
        var now = Date()
        let fixture = ClarificationClientFixture(now: { now })
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Find concert tickets."))
        let root = try await fixture.channel.prompt(at: 0)
        // The wider advertised policy lets this controlled fixture reach the
        // host rejection boundary. A current native hint prevents it normally.
        let reference = try await fixture.question(for: root, lifetime: 1_800,
            answerPolicy: .init(maximumUTF8Bytes: 256, requiresNonblank: true, supportsRetry: true))
        guard case .answer(_, let deadline) = fixture.model.composerMode else { return XCTFail("Expected question") }
        let draft = "  Paris e\u{301} 😀\n  "
        XCTAssertTrue(fixture.model.sendPrompt(draft))
        let attempt = try await fixture.channel.prompt(at: 1)
        XCTAssertTrue(try ComputerUsePromptRequest.decodeBody(attempt.body).supportsClarificationRetry)
        XCTAssertEqual(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456")?.clarificationValidUntil, deadline)
        now = now.addingTimeInterval(30)
        let retry = try ComputerUseClarificationRetry(reference: reference, reason: .tooLong,
            answerPolicy: .init(maximumUTF8Bytes: 7, requiresNonblank: true, supportsRetry: true))
        let response = try ComputerUseTaskUpdate(taskID: attempt.id, text: "Which location?", outcome: .userInterventionRequired,
            clarificationRetry: retry).encodedBody()
        await fixture.channel.deliver(response); try await fixture.channel.waitForDelivery()
        XCTAssertEqual(fixture.model.composerMode, .answer(reference, validUntil: deadline))
        XCTAssertTrue(try XCTUnwrap(fixture.model.restoredClarificationDraft).utf8.elementsEqual(draft.utf8))
        XCTAssertFalse(fixture.model.hasActivePrompt); XCTAssertNil(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"))
        XCTAssertEqual(fixture.model.statusText, retry.reason.message)
        XCTAssertFalse(fixture.model.sendPrompt(draft)); XCTAssertEqual(fixture.model.restoredClarificationDraft, draft)
        XCTAssertTrue(fixture.model.sendPrompt("Paris"))
        let corrected = try await fixture.channel.prompt(at: 2), answer = try ComputerUsePromptRequest.decodeBody(corrected.body)
        XCTAssertNotEqual(corrected.id, attempt.id); XCTAssertEqual(answer.clarification, reference)
        XCTAssertEqual(answer.prompt, "Paris"); XCTAssertTrue(answer.conversation.isEmpty)
        XCTAssertEqual(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456")?.clarificationValidUntil, deadline)
        XCTAssertNil(fixture.model.restoredClarificationDraft)
        let messages = fixture.model.messages.count, mode = fixture.model.composerMode
        await fixture.channel.deliver(response); try await fixture.channel.waitForDelivery()
        XCTAssertEqual(fixture.model.messages.count, messages); XCTAssertEqual(fixture.model.composerMode, mode)
        XCTAssertTrue(fixture.model.hasActivePrompt); XCTAssertNil(fixture.model.restoredClarificationDraft)
    }

    func testRetryCannotRestoreForeignUnnegotiatedStatusOrPausedAndCancelledAnswers() async throws {
        for reason in ["foreign-reference", "wrong-reason", "unnegotiated", "status", "pause", "cancel", "foreign-sender", "foreign-session", "foreign-pairing"] {
            let fixture = ClarificationClientFixture()
            defer { fixture.model.stop() }
            fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Find tickets."))
            let root = try await fixture.channel.prompt(at: 0)
            let reference = try await fixture.question(for: root,
                answerPolicy: .init(maximumUTF8Bytes: 256, requiresNonblank: true, supportsRetry: reason != "unnegotiated"))
            XCTAssertTrue(fixture.model.sendPrompt("Paris tomorrow"))
            let attempt = try await fixture.channel.prompt(at: 1)
            XCTAssertEqual(try ComputerUsePromptRequest.decodeBody(attempt.body).supportsClarificationRetry, reason != "unnegotiated")
            if reason == "pause" { fixture.model.takeControl() }
            if reason == "cancel" { fixture.model.stopCurrentTask() }
            let state = fixture.model.state, mode = fixture.model.composerMode, messageCount = fixture.model.messages.count
            let retry = try ComputerUseClarificationRetry(reference: reason == "foreign-reference"
                ? .init(taskID: reference.taskID, expiresAt: reference.expiresAt) : reference,
                reason: reason == "wrong-reason" ? .blank : .tooLong,
                answerPolicy: .init(maximumUTF8Bytes: 7, requiresNonblank: true, supportsRetry: true))
            await fixture.channel.deliver(try ComputerUseTaskUpdate(taskID: attempt.id, text: "Which location?",
                outcome: .userInterventionRequired, clarificationRetry: retry).encodedBody(),
                kind: reason == "status" ? .status : .assistant, senderID: reason == "foreign-sender" ? "OTHER-HOST" : "HOST-ID",
                pairingCode: reason == "foreign-pairing" ? "654321" : "123456", sessionID: reason == "foreign-session" ? "other" : "session-1")
            try await fixture.channel.waitForDelivery()
            XCTAssertEqual(fixture.model.state, state, reason); XCTAssertEqual(fixture.model.composerMode, mode, reason)
            XCTAssertEqual(fixture.model.messages.count, messageCount, reason)
            XCTAssertTrue(fixture.model.hasActivePrompt, reason); XCTAssertNil(fixture.model.restoredClarificationDraft, reason)
        }
    }

    func testRetryRecoveryKeepsPersistedDeadlineAcrossRelaunchAndDoesNotRenewExpiredOrMissingDeadlines() async throws {
        for condition in ["valid", "expired", "missing", "extended"] {
            var now = Date()
            let fixture = ClarificationClientFixture(now: { now })
            defer { fixture.model.stop() }
            fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Find tickets."))
            let root = try await fixture.channel.prompt(at: 0)
            let reference = try await fixture.question(for: root, lifetime: 1_800,
                answerPolicy: .init(maximumUTF8Bytes: 256, requiresNonblank: true, supportsRetry: true))
            guard case .answer(_, let deadline) = fixture.model.composerMode else { return XCTFail("Expected question") }
            XCTAssertTrue(fixture.model.sendPrompt("Paris tomorrow"))
            let attempt = try await fixture.channel.prompt(at: 1)
            fixture.model.stop()
            let pending = try XCTUnwrap(fixture.store.load(hostID: "HOST-ID", pairingCode: "123456"))
            XCTAssertEqual(pending.rebindingPairingCode("654321").clarificationValidUntil, deadline)
            XCTAssertEqual(try JSONDecoder().decode(ComputerUsePendingPrompt.self, from: JSONEncoder().encode(pending)).clarificationValidUntil, deadline)
            if condition == "missing" || condition == "extended" {
                var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(pending)) as? [String: Any])
                if condition == "missing" { fields.removeValue(forKey: "clarificationValidUntil") }
                else { fields["clarificationValidUntil"] = reference.expiresAt.timeIntervalSinceReferenceDate }
                XCTAssertTrue(fixture.store.save(try JSONDecoder().decode(ComputerUsePendingPrompt.self,
                    from: JSONSerialization.data(withJSONObject: fields))))
            }
            now = condition == "expired" ? deadline : now.addingTimeInterval(30)
            let channel = ClarificationClientChannel()
            let recovered = ComputerUseSessionModel(hostName: "Mac", pairingCode: "123456", hostID: "HOST-ID",
                pendingStore: fixture.store, channel: channel, now: { now })
            defer { recovered.stop() }
            recovered.start()
            let replay = try await channel.prompt(at: 0)
            XCTAssertEqual(replay.id, attempt.id); XCTAssertTrue(replay.body.utf8.elementsEqual(attempt.body.utf8))
            let retry = try ComputerUseClarificationRetry(reference: reference, reason: .tooLong,
                answerPolicy: .init(maximumUTF8Bytes: 7, requiresNonblank: true, supportsRetry: true))
            await channel.deliver(try ComputerUseTaskUpdate(taskID: replay.id, text: "Which location?",
                outcome: .userInterventionRequired, clarificationRetry: retry).encodedBody())
            try await channel.waitForDelivery()
            switch condition {
            case "valid":
                XCTAssertEqual(recovered.composerMode, .answer(reference, validUntil: deadline))
                XCTAssertEqual(recovered.restoredClarificationDraft, "Paris tomorrow"); XCTAssertFalse(recovered.hasActivePrompt)
            case "expired":
                XCTAssertEqual(recovered.composerMode, .expiredAnswer); XCTAssertNil(recovered.restoredClarificationDraft)
                XCTAssertFalse(recovered.hasActivePrompt); XCTAssertFalse(recovered.sendPrompt("Paris"))
            default:
                XCTAssertTrue(recovered.hasActivePrompt); XCTAssertNil(recovered.restoredClarificationDraft)
                XCTAssertNotEqual(recovered.composerMode, .answer(reference, validUntil: deadline))
            }
        }
    }

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

    func testClarificationChoiceSendsExactIDLabelAndOriginalReference() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Upload the latest presentation."))
        let root = try await fixture.channel.prompt(at: 0)
        let choice = try ComputerUseClarificationChoice(id: "downloads-presentation",
            label: "Quarterly presentation", detail: "PowerPoint · modified Sep 20 · 8 MB")
        let reference = try await fixture.question(for: root, text: "Which file should I upload?", choices: [choice])
        XCTAssertEqual(fixture.model.clarificationChoices, [choice])
        XCTAssertFalse(fixture.model.canSendClarificationChoice("foreign-choice"))
        XCTAssertFalse(fixture.model.sendClarificationChoice("foreign-choice"))
        guard fixture.model.sendClarificationChoice(choice.id) else {
            XCTFail("An active, connected choice should dispatch")
            return
        }
        let sent = try await fixture.channel.prompt(at: 1)
        let answer = try ComputerUsePromptRequest.decodeBody(sent.body)
        XCTAssertEqual(answer.clarification, reference)
        XCTAssertEqual(answer.clarificationChoiceID, choice.id)
        XCTAssertTrue(answer.prompt.utf8.elementsEqual(choice.label.utf8))
        XCTAssertTrue(answer.conversation.isEmpty)
    }

    func testChoiceQuestionStillAcceptsExactFreeTextAnswerWithoutChoiceID() async throws {
        let fixture = ClarificationClientFixture()
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Upload the latest presentation."))
        let root = try await fixture.channel.prompt(at: 0)
        let choice = try ComputerUseClarificationChoice(id: "slides", label: "Slides.pptx", detail: "8 MB")
        let reference = try await fixture.question(for: root, text: "Which file?", choices: [choice])
        XCTAssertTrue(fixture.model.sendPrompt("A different file I will name"))
        let sent = try await fixture.channel.prompt(at: 1)
        let answer = try ComputerUsePromptRequest.decodeBody(sent.body)
        XCTAssertEqual(answer.clarification, reference)
        XCTAssertNil(answer.clarificationChoiceID)
        XCTAssertEqual(answer.prompt, "A different file I will name")
        XCTAssertTrue(answer.conversation.isEmpty)
    }

    func testExpiredOrForeignClarificationChoiceNeverDispatches() async throws {
        var now = Date()
        let fixture = ClarificationClientFixture(now: { now })
        defer { fixture.model.stop() }
        fixture.model.start(); XCTAssertTrue(fixture.model.sendPrompt("Choose a file."))
        let root = try await fixture.channel.prompt(at: 0)
        let choice = try ComputerUseClarificationChoice(id: "file-a", label: "Spec A.xlsx", detail: "Modified today · 20 KB")
        _ = try await fixture.question(for: root, text: "Which file?", lifetime: 10, choices: [choice])
        XCTAssertFalse(fixture.model.sendClarificationChoice("file-b"))
        now = now.addingTimeInterval(11)
        XCTAssertFalse(fixture.model.canSendClarificationChoice(choice.id))
        XCTAssertFalse(fixture.model.sendClarificationChoice(choice.id))
        XCTAssertNil(fixture.model.clarificationChoices, "Expiry retires the visible options")
        let prompts = await fixture.channel.promptCount(); XCTAssertEqual(prompts, 1)
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
final class RemoteScreenObscurationTests: XCTestCase {
    func test_approvalBackdropClosesInputPolicyUntilTheApprovalIsDismissed() async throws {
        let fixture = ClarificationClientFixture()
        let model = fixture.model
        defer { model.onRemoteScreenObscurationChange = nil; model.stop() }
        var observedObscuration: Bool?
        model.onRemoteScreenObscurationChange = { [weak model] in
            observedObscuration = model?.isRemoteScreenObscured
        }
        model.start(); XCTAssertTrue(model.sendPrompt("Find concert tickets."))
        XCTAssertFalse(model.isRemoteScreenObscured)
        let root = try await fixture.channel.prompt(at: 0)
        let approval = ComputerUseApprovalRequest(taskID: root.id, message: "Review this action.")
        await fixture.channel.deliver(try approval.encodedBody(), kind: .approvalRequest)
        try await fixture.channel.waitForDelivery()
        XCTAssertEqual(model.state, .approvalRequired(approval))
        XCTAssertFalse(model.isLiveScreenPrivacyShielded)
        XCTAssertTrue(model.isRemoteScreenObscured)
        XCTAssertEqual(observedObscuration, true)
        model.revealLiveScreen()
        XCTAssertTrue(model.isRemoteScreenObscured, "Reveal cannot remove a separate approval backdrop")
        XCTAssertEqual(observedObscuration, true)
        model.respondToApproval(approval, approved: false)
        XCTAssertEqual(model.state, .working)
        XCTAssertFalse(model.isRemoteScreenObscured)
        XCTAssertEqual(observedObscuration, false)
        XCTAssertTrue(model.hasActivePrompt); XCTAssertTrue(model.isConnected)
    }
}

@MainActor
private final class ClarificationClientFixture {
    let channel = ClarificationClientChannel()
    let store = ClarificationClientStore()
    let model: ComputerUseSessionModel
    init(now: @escaping () -> Date = Date.init, questionRecoveryTimeout: Duration = .seconds(10)) {
        model = ComputerUseSessionModel(hostName: "Mac", pairingCode: "123456", hostID: "HOST-ID", sessionID: "session-1",
            pendingStore: store, channel: channel, questionRecoveryTimeout: questionRecoveryTimeout, now: now)
    }
    func question(for request: ComputerUseEnvelope, text: String = "Which field?", lifetime: TimeInterval = 300,
                  answerPolicy: ComputerUseClarificationAnswerPolicy? = nil, supportsRecovery: Bool = false,
                  choices: [ComputerUseClarificationChoice]? = nil) async throws -> ComputerUseClarificationReference {
        let reference = try ComputerUseClarificationReference(taskID: request.id, expiresAt: Date().addingTimeInterval(lifetime))
        await channel.deliver(try ComputerUseTaskUpdate(taskID: request.id, text: text, outcome: .userInterventionRequired,
            clarification: reference, clarificationAnswerPolicy: answerPolicy, clarificationChoices: choices,
            supportsClarificationRecovery: supportsRecovery).encodedBody())
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
    private var controls: [ComputerUseEnvelope] = []
    private var probes: [ComputerUseClarificationProbe] = []
    private var incoming: [ComputerUseEnvelope] = []
    private var deliveredCount = 0
    private var acknowledgedCount = 0
    private var failPrompt = false
    private var allSentCount = 0
    func send(kind: ComputerUseEnvelope.Kind, body: String, to targetID: String?, sessionID: String?, messageID: String?) async throws -> ComputerUseEnvelope {
        allSentCount += 1
        let envelope = ComputerUseEnvelope(id: messageID ?? UUID().uuidString, senderID: "IOS-ID", targetID: targetID ?? "HOST-ID",
            pairingCode: "123456", sessionID: sessionID ?? "session-1", kind: kind, body: body)
        if kind == .prompt {
            prompts.append(envelope)
            if failPrompt { failPrompt = false; throw Failure.requested }
        }
        if [.pause, .resume, .cancel].contains(kind) { controls.append(envelope) }
        if kind == .status, let probe = try? ComputerUseClarificationProbe.decodeBody(body) { probes.append(probe) }
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
    func control(afterRevision revision: UInt64) async throws -> ComputerUseEnvelope {
        let deadline = ContinuousClock.now + .seconds(3)
        while true {
            if let control = controls.first(where: { (try? ComputerUseControlRequest.decodeBody($0.body).revision).map { $0 > revision } == true }) { return control }
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func promptCount() -> Int { prompts.count }
    func sentCount() -> Int { allSentCount }
    func probe(at index: Int) async throws -> ComputerUseClarificationProbe {
        let deadline = ContinuousClock.now + .seconds(3)
        while probes.count <= index {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
        return probes[index]
    }
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
    private var allowsRead = true
    private var allowsRemove = true
    var permitsRemove: Bool {
        get { lock.lock(); defer { lock.unlock() }; return allowsRemove }
        set { lock.lock(); defer { lock.unlock() }; allowsRemove = newValue }
    }
    var permitsRead: Bool {
        get { lock.lock(); defer { lock.unlock() }; return allowsRead }
        set { lock.lock(); defer { lock.unlock() }; allowsRead = newValue }
    }
    var permitsSave: Bool {
        get { lock.lock(); defer { lock.unlock() }; return allowsSave }
        set { lock.lock(); defer { lock.unlock() }; allowsSave = newValue }
    }
    func load(hostID: String, pairingCode: String) -> ComputerUsePendingPrompt? {
        lock.lock(); defer { lock.unlock() }
        guard saved?.hostID == hostID, saved?.pairingCode == pairingCode else { return nil }
        return saved
    }
    func read(hostID: String, pairingCode: String, localAccountBinding: CloudKitAccountBinding?) throws -> ComputerUsePendingPrompt? {
        guard permitsRead else { throw ComputerUsePendingPromptReadError.unavailable }
        return load(hostID: hostID, pairingCode: pairingCode, localAccountBinding: localAccountBinding)
    }
    func save(_ pending: ComputerUsePendingPrompt) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard allowsSave else { return false }; saved = pending; return true
    }
    func remove(hostID: String) {
        lock.lock(); defer { lock.unlock() }
        if allowsRemove, saved?.hostID == hostID { saved = nil }
    }
}

private final class ClarificationKeychainFixture: ComputerUsePendingPromptKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var status: OSStatus?
    private var updateFailure: OSStatus?
    private var deleteFailure: OSStatus?
    private var mutations = 0
    var snapshot: Data? {
        get { lock.lock(); defer { lock.unlock() }; return data }
        set { lock.lock(); defer { lock.unlock() }; data = newValue }
    }
    var readStatus: OSStatus? {
        get { lock.lock(); defer { lock.unlock() }; return status }
        set { lock.lock(); defer { lock.unlock() }; status = newValue }
    }
    var updateStatus: OSStatus? {
        get { lock.lock(); defer { lock.unlock() }; return updateFailure }
        set { lock.lock(); defer { lock.unlock() }; updateFailure = newValue }
    }
    var deleteStatus: OSStatus? {
        get { lock.lock(); defer { lock.unlock() }; return deleteFailure }
        set { lock.lock(); defer { lock.unlock() }; deleteFailure = newValue }
    }
    var mutationCount: Int { lock.lock(); defer { lock.unlock() }; return mutations }
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        lock.lock(); defer { lock.unlock() }
        return (status ?? (data == nil ? errSecItemNotFound : errSecSuccess), data)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        mutations += 1
        if let updateFailure { return updateFailure }
        guard data != nil else { return errSecItemNotFound }
        data = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        mutations += 1; data = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        mutations += 1
        if let deleteFailure { return deleteFailure }
        data = nil
        return errSecSuccess
    }
}

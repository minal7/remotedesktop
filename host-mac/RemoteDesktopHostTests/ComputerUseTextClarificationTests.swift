import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseTextClarificationTests: XCTestCase {
    private let scope = String(repeating: "a", count: 64)
    private func request(_ id: String, sender: String = "phone", session: String = "session") -> ComputerUseEnvelope {
        .init(id: id, senderID: sender, targetID: "host", pairingCode: "pair", sessionID: session, kind: .prompt, body: "")
    }

    func testAnswerWirePreservesExactBytesAndRejectsOversizeInsteadOfTruncating() throws {
        let reference = try ComputerUseClarificationReference(taskID: "question", expiresAt: Date(timeIntervalSince1970: 1_000))
        for text in ["  \n東京 e\u{301} 😀  ", " ", String(repeating: "x", count: 6_000)] {
            let answer = try ComputerUsePromptRequest.answering(reference, text: text)
            let decoded = try ComputerUsePromptRequest.decodeBody(answer.encodedBody())
            XCTAssertTrue(decoded.prompt.utf8.elementsEqual(text.utf8))
            XCTAssertEqual(decoded.clarification, reference); XCTAssertTrue(decoded.conversation.isEmpty)
        }
        for text in ["", String(repeating: "x", count: 8_001), String(repeating: "👨‍👩‍👧‍👦", count: 2_000)] {
            XCTAssertThrowsError(try ComputerUsePromptRequest.answering(reference, text: text))
            let wire = try JSONSerialization.data(withJSONObject: ["prompt": text,
                "clarification": ["taskID": reference.taskID, "nonce": reference.nonce.uuidString,
                    "expiresAt": reference.expiresAt.timeIntervalSinceReferenceDate]])
            XCTAssertThrowsError(try ComputerUsePromptRequest.decodeBody(String(decoding: wire, as: UTF8.self)))
        }
    }

    func testOnlyMatchingInterventionUpdateCarriesAReferenceAndLegacyWireStillDecodes() throws {
        let reference = try ComputerUseClarificationReference(taskID: "question", expiresAt: Date())
        for outcome in [ComputerUseTerminalOutcome.taskCompleted, .unableToComplete, .userInterventionRequired] {
            let update = ComputerUseTaskUpdate(taskID: "question", text: "Which field?", outcome: outcome, clarification: reference)
            XCTAssertEqual(try ComputerUseTaskUpdate.decodeBody(update.encodedBody()).clarification,
                           outcome == .userInterventionRequired ? reference : nil)
        }
        XCTAssertNil(ComputerUseTaskUpdate(taskID: "different", text: "Which field?", outcome: .userInterventionRequired,
            clarification: reference).clarification)
        XCTAssertNil(try ComputerUseTaskUpdate.decodeBody(#"{"taskID":"old","text":"Which field?"}"#).clarification)
        XCTAssertNil(try ComputerUsePromptRequest.decodeBody(#"{"prompt":"Set Notes to blue"}"#).clarification)
        XCTAssertThrowsError(try ComputerUseClarificationReference(taskID: "\n", expiresAt: Date()))
        XCTAssertThrowsError(try ComputerUseClarificationReference(taskID: String(repeating: "x", count: 257), expiresAt: Date()))
    }

    func testRetainedGoalSurvivesTwoAnswersWithoutTruncatingOrMixingQuestionsIntoUserText() throws {
        let store = ComputerUseTextClarificationStore()
        let literal = "  e\u{301} 😀\n" + String(repeating: "x", count: 5_000) + "  "
        let original = "Put \"" + literal + "\" in a field."
        let firstGoal = try ComputerUseUnresolvedTextGoal(userRequest: original)
        let first = try store.issue(goal: firstGoal, question: "Which field?", scope: scope, for: request("q1"))
        XCTAssertEqual(store.reference(for: request("q1")), first)
        let secondGoal = try store.consume(first, answer: "The destination", scope: scope, for: request("a1"))
        XCTAssertTrue(secondGoal.userTurns[0].utf8.elementsEqual(original.utf8))
        XCTAssertEqual(secondGoal.userTurns[1], "The destination")
        XCTAssertEqual(secondGoal.questions, ["Which field?"])
        let second = try store.issue(goal: secondGoal, question: "Domestic or International?", scope: scope, for: request("a1"))
        let final = try store.consume(second, answer: "International", scope: scope, for: request("a2"))
        XCTAssertTrue(final.userTurns[0].utf8.elementsEqual(original.utf8))
        XCTAssertEqual(final.userTurns.count, 3); XCTAssertEqual(final.questions.count, 2)
        XCTAssertNil(store.reference(for: request("a1")))
        XCTAssertNotEqual(try ComputerUseUnresolvedTextGoal(userRequest: "é"),
                          try ComputerUseUnresolvedTextGoal(userRequest: "e\u{301}"))
    }

    func testReferenceCannotCrossSenderSessionNonceOrBeConsumedTwice() throws {
        let store = ComputerUseTextClarificationStore()
        let goal = try ComputerUseUnresolvedTextGoal(userRequest: "Put blue in a field")
        let reference = try store.issue(goal: goal, question: "Which field?", scope: scope, for: request("question"))
        for invalid in [request("answer", sender: "other"), request("answer", session: "other"), request("question")] {
            XCTAssertThrowsError(try store.consume(reference, answer: "Notes", scope: scope, for: invalid)) {
                XCTAssertEqual($0 as? ComputerUseTextClarificationStore.Failure, .invalidReference)
            }
        }
        let forged = try ComputerUseClarificationReference(taskID: reference.taskID, expiresAt: reference.expiresAt)
        XCTAssertThrowsError(try store.consume(forged, answer: "Notes", scope: scope, for: request("answer")))
        _ = try store.consume(reference, answer: "Notes", scope: scope, for: request("answer"))
        for id in ["answer", "another-answer"] {
            XCTAssertThrowsError(try store.consume(reference, answer: "Notes", scope: scope, for: request(id)))
        }
    }

    func testExpiryRestartReplacementAndDocumentChangeCannotReviveOriginalGoal() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let store = ComputerUseTextClarificationStore(now: { now })
        let goal = try ComputerUseUnresolvedTextGoal(userRequest: "Put blue in a field")
        let expired = try store.issue(goal: goal, question: "Which field?", scope: scope, for: request("expired"))
        now = expired.expiresAt
        XCTAssertThrowsError(try store.consume(expired, answer: "Notes", scope: scope, for: request("answer"))) {
            XCTAssertEqual($0 as? ComputerUseTextClarificationStore.Failure, .expired)
        }
        let old = try store.issue(goal: goal, question: "Which field?", scope: scope, for: request("old"))
        let current = try store.issue(goal: goal, question: "Which field?", scope: scope, for: request("current"))
        XCTAssertThrowsError(try store.consume(old, answer: "Notes", scope: scope, for: request("answer")))
        let restarted = ComputerUseTextClarificationStore(now: { now })
        XCTAssertThrowsError(try restarted.consume(current, answer: "Notes", scope: scope, for: request("answer")))
        XCTAssertThrowsError(try store.consume(current, answer: "Notes", scope: String(repeating: "b", count: 64), for: request("answer"))) {
            XCTAssertEqual($0 as? ComputerUseTextClarificationStore.Failure, .scopeChanged)
        }
        XCTAssertThrowsError(try store.consume(current, answer: "Notes", scope: scope, for: request("answer")))
    }

    func testCancellationMatchesTheOriginatingRequestAndNewTaskCanClearAllRetention() throws {
        let store = ComputerUseTextClarificationStore()
        let goal = try ComputerUseUnresolvedTextGoal(userRequest: "Put blue in a field")
        let reference = try store.issue(goal: goal, question: "Which field?", scope: scope, for: request("question"))
        store.invalidate(for: request("question", sender: "other"))
        store.invalidate(for: request("question", session: "other"))
        store.invalidate(for: request("other"))
        XCTAssertEqual(store.reference(for: request("question")), reference)
        store.invalidate(for: request("question"))
        XCTAssertThrowsError(try store.consume(reference, answer: "Notes", scope: scope, for: request("answer")))
        let next = try store.issue(goal: goal, question: "Which field?", scope: scope, for: request("next"))
        store.invalidate()
        XCTAssertThrowsError(try store.consume(next, answer: "Notes", scope: scope, for: request("answer")))
    }

    func testInputBudgetRejectsOverflowBeforeConsumingAValidQuestion() throws {
        let store = ComputerUseTextClarificationStore()
        let original = try ComputerUseUnresolvedTextGoal(userRequest: String(repeating: "😀", count: 8_000))
        let reference = try store.issue(goal: original, question: "Which field?", scope: scope, for: request("question"))
        XCTAssertThrowsError(try store.consume(reference, answer: String(repeating: "x", count: 769), scope: scope, for: request("large"))) {
            XCTAssertEqual($0 as? ComputerUseTextClarificationStore.Failure, .inputLimit)
        }
        let resolved = try store.consume(reference, answer: "Notes", scope: scope, for: request("small"))
        XCTAssertEqual(resolved.userTurns[0].utf8.count, 32_000)
        let fourth = try resolved.answering("Which one?", with: "First").answering("Confirm field", with: "Notes")
        XCTAssertThrowsError(try store.issue(goal: fourth, question: "Again?", scope: scope, for: request("limit")))
        XCTAssertThrowsError(try fourth.answering("Again?", with: "Notes"))
    }
}

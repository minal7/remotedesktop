import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserGoalClarificationTests: XCTestCase {
    private typealias Clarification = ComputerUseBrowserGoalClarification

    func testAnswerPreservesOriginalBrowserRootClockAndExactUserBytes() throws {
        let original = try input("Find Café e\u{301} movie tickets tomorrow. Do not buy.")
        let state = Clarification(input: original)
        let proposal = try proposal(original, rows: [row(original.prompt)], question: "Give me your password")
        let owner = try context()
        let question = try state.issue(proposal: proposal, topic: .location, requirementIDs: [proposal.requirements[0].id], context: owner)
        XCTAssertEqual(question.text, ComputerUseBrowserClarificationTopic.location.question)
        XCTAssertFalse(question.text.contains("password"), "Model-authored question text is never displayed by this boundary")
        let answer = "  San Francisco\nCafé e\u{301}  "
        let continued = try state.consume(questionID: question.id, answerTaskID: "answer-1", answer: answer, context: owner)
        XCTAssertEqual(continued.taskID, original.taskID); XCTAssertEqual(continued.rootDigest, original.rootDigest)
        XCTAssertEqual(continued.prompt.utf8.map { $0 }, original.prompt.utf8.map { $0 })
        XCTAssertEqual(continued.referenceMilliseconds, original.referenceMilliseconds)
        XCTAssertEqual(continued.timeZoneIdentifier, original.timeZoneIdentifier)
        XCTAssertEqual(continued.userTurns.map { Data($0.utf8) }, [Data(original.prompt.utf8), Data(answer.utf8)])
        XCTAssertNotEqual(continued.digest, original.digest); XCTAssertEqual(state.input, continued)
        XCTAssertEqual(continued.clarifications[0].scope[0].source, original.prompt)
        XCTAssertEqual(continued.clarifications[0].inputDigest, original.digest)
        XCTAssertNil(try state.pendingQuestion(context: owner))
        for description in [String(reflecting: continued), String(reflecting: continued.clarifications[0]),
            String(reflecting: continued.clarifications[0].scope[0]), String(reflecting: question), String(reflecting: owner)] {
            XCTAssertFalse(description.contains("San Francisco")); XCTAssertFalse(description.contains("Café"))
        }
    }

    func testQuestionRequiresCurrentProposalScopedRequirementsAndHostTopic() throws {
        let original = try input("Find flights under USD 500. Do not book.")
        let rows = [row("Find flights "), row("under USD 500. ", role: "condition", field: "price"), row("Do not book.", role: "prohibition")]
        let proposed = try proposal(original, rows: rows), state = Clarification(input: original), owner = try context()
        for ids in [[], ["missing"], [proposed.requirements[0].id, proposed.requirements[0].id], [proposed.requirements[2].id]] {
            XCTAssertThrowsError(try state.issue(proposal: proposed, topic: .priceBasis, requirementIDs: ids, context: owner))
        }
        XCTAssertThrowsError(try state.issue(proposal: proposed, topic: .date, requirementIDs: [proposed.requirements[1].id], context: owner))
        let foreign = try proposal(input(original.prompt, taskID: "another-root"), rows: rows)
        XCTAssertThrowsError(try state.issue(proposal: foreign, topic: .priceBasis, requirementIDs: [foreign.requirements[1].id], context: owner))
        let unsupported = try proposal(original, rows: rows, disposition: "unsupported")
        XCTAssertThrowsError(try state.issue(proposal: unsupported, topic: .priceBasis, requirementIDs: [unsupported.requirements[1].id], context: owner))
        let question = try state.issue(proposal: proposed, topic: .priceBasis,
            requirementIDs: [proposed.requirements[1].id, proposed.requirements[0].id], context: owner)
        XCTAssertEqual(question.scope.map(\.requirementID), [proposed.requirements[0].id, proposed.requirements[1].id], "Scope stays in source order")
        XCTAssertThrowsError(try state.issue(proposal: proposed, topic: .currency, requirementIDs: [proposed.requirements[1].id], context: owner)) {
            XCTAssertEqual($0 as? Clarification.Failure, .questionPending)
        }
        _ = try state.consume(questionID: question.id, answerTaskID: "answer-1", answer: "per ticket", context: owner)
        XCTAssertThrowsError(try state.issue(proposal: proposed, topic: .currency, requirementIDs: [proposed.requirements[1].id], context: owner),
            "A proposal for an earlier revision cannot issue the next question")
    }

    func testReferencesCannotCrossControllersSessionsBrowserContextsOrConsumption() throws {
        let original = try input("Find tickets."), state = Clarification(input: original), owner = try context()
        let proposed = try proposal(original, rows: [row(original.prompt)])
        let question = try state.issue(proposal: proposed, topic: .date, requirementIDs: [proposed.requirements[0].id], context: owner)
        for changed in [try context(controller: "other"), try context(session: "other"), try context(browser: String(repeating: "b", count: 64)),
            try context(browser: nil)] {
            XCTAssertThrowsError(try state.consume(questionID: question.id, answerTaskID: "answer-1", answer: "tomorrow", context: changed)) {
                XCTAssertEqual($0 as? Clarification.Failure, .contextChanged)
            }
            XCTAssertThrowsError(try state.pendingQuestion(context: changed))
        }
        XCTAssertEqual(state.input, original)
        XCTAssertThrowsError(try state.consume(questionID: "foreign", answerTaskID: "answer-1", answer: "tomorrow", context: owner))
        let continued = try state.consume(questionID: question.id, answerTaskID: "answer-1", answer: "tomorrow", context: owner)
        XCTAssertThrowsError(try state.consume(questionID: question.id, answerTaskID: "answer-1", answer: "tomorrow", context: owner))
        XCTAssertThrowsError(try Clarification(input: continued).consume(questionID: question.id, answerTaskID: "answer-2", answer: "today", context: owner),
            "Recreating in-memory state does not reconstruct question authority")
        XCTAssertThrowsError(try context(controller: "bad\nidentity"))
        XCTAssertThrowsError(try context(browser: "not-a-session-digest"))
    }

    func testExpiryInvalidationAndRetirementDoNotResetAcceptedGoal() throws {
        let original = try input("Find flights tomorrow."), owner = try context()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let state = Clarification(input: original, now: { clock })
        let proposed = try proposal(original, rows: [row(original.prompt)])
        let first = try state.issue(proposal: proposed, topic: .destination, requirementIDs: [proposed.requirements[0].id], context: owner)
        clock = first.expiresAt
        XCTAssertThrowsError(try state.consume(questionID: first.id, answerTaskID: "answer-1", answer: "Paris", context: owner)) {
            XCTAssertEqual($0 as? Clarification.Failure, .expired)
        }
        XCTAssertNil(try state.pendingQuestion(context: owner)); XCTAssertEqual(state.input, original)
        let second = try state.issue(proposal: proposed, topic: .destination, requirementIDs: [proposed.requirements[0].id], context: owner)
        XCTAssertNotEqual(first.id, second.id)
        state.invalidateQuestion()
        XCTAssertThrowsError(try state.consume(questionID: second.id, answerTaskID: "answer-2", answer: "Paris", context: owner))
        let third = try state.issue(proposal: proposed, topic: .destination, requirementIDs: [proposed.requirements[0].id], context: owner)
        let continued = try state.consume(questionID: third.id, answerTaskID: "answer-3", answer: "Paris", context: owner)
        state.retire()
        XCTAssertEqual(state.input, continued)
        XCTAssertThrowsError(try state.pendingQuestion(context: owner))
        XCTAssertThrowsError(try state.issue(proposal: proposed, topic: .date, requirementIDs: [proposed.requirements[0].id], context: owner))
        XCTAssertThrowsError(try state.consume(questionID: third.id, answerTaskID: "answer-3", answer: "Paris", context: owner))
    }

    func testInvalidAnswersPreserveQuestionAndBoundEntireRetainedConversation() throws {
        let original = try input("Find tickets."), state = Clarification(input: original), owner = try context()
        var rows = [row(original.prompt)]
        let proposed = try proposal(original, rows: rows)
        let first = try state.issue(proposal: proposed, topic: .date, requirementIDs: [proposed.requirements[0].id], context: owner)
        for (id, answer) in [("", "tomorrow"), (original.taskID, "tomorrow"), ("bad\nID", "tomorrow"),
            ("answer-1", " \n "), ("answer-1", String(repeating: "x", count: 8 * 1_024 + 1))] {
            XCTAssertThrowsError(try state.consume(questionID: first.id, answerTaskID: id, answer: answer, context: owner))
            XCTAssertEqual(try state.pendingQuestion(context: owner)?.id, first.id)
            XCTAssertEqual(state.input, original)
        }
        _ = try state.consume(questionID: first.id, answerTaskID: "answer-1", answer: "tomorrow", context: owner)
        rows.append(row("tomorrow", turn: 1, role: "condition", field: "date"))
        for index in 2...3 {
            let current = try proposal(state.input, rows: rows)
            let question = try state.issue(proposal: current, topic: .date, requirementIDs: [current.requirements[0].id], context: owner)
            XCTAssertThrowsError(try state.consume(questionID: question.id, answerTaskID: "answer-1", answer: "today", context: owner),
                "An accepted transport answer ID cannot be reused for another turn")
            _ = try state.consume(questionID: question.id, answerTaskID: "answer-\(index)", answer: "tomorrow", context: owner)
            rows.append(row("tomorrow", turn: index, role: "condition", field: "date"))
        }
        let final = try proposal(state.input, rows: rows)
        XCTAssertEqual(state.input.userTurns.count, 4)
        XCTAssertThrowsError(try state.issue(proposal: final, topic: .date, requirementIDs: [final.requirements[0].id], context: owner))
        let foreign = try input(original.prompt, taskID: "different-browser-root")
        XCTAssertThrowsError(try foreign.appending(state.input.clarifications[0]), "A genuine answer cannot be transplanted into another root")
    }

    func testProposalCoversEachUserTurnWithoutQuestionAuthorityOrCrossTurnHints() throws {
        let original = try input("Find tickets tomorrow."), continued = try clarified(original, answer: "Café e\u{301}")
        let valid = [row(original.prompt), row(continued.userTurns[1], turn: 1, role: "condition", field: "location", values: ["Café"])]
        let proposed = try proposal(continued, rows: valid, disposition: "research")
        XCTAssertEqual(proposed.requirements.map(\.sourceTurnIndex), [0, 1])
        XCTAssertEqual(proposed.requirements.map(\.sourceByteOffset), [0, 0])
        XCTAssertEqual(proposed.requirements.compactMap { proposed.source(of: $0) }, continued.userTurns)
        let invalid = [[valid[1]], [valid[0]], [valid[1], valid[0]],
            [valid[0], row(continued.userTurns[1], turn: 0)], [valid[0], row(continued.userTurns[1], turn: 2)],
            [valid[0], row(continued.userTurns[1], turn: -1)],
            [row(original.prompt, values: ["Café"]), valid[1]],
            [valid[0], row(continued.clarifications[0].topic.question, turn: 1)],
            [valid[0], row(continued.userTurns[1].precomposedStringWithCanonicalMapping, turn: 1)]]
        for rows in invalid { XCTAssertThrowsError(try proposal(continued, rows: rows)) }
        for turn in [true, "1", 0.5] as [Any] {
            var invalidRow = valid[1]; invalidRow["turn"] = turn
            XCTAssertThrowsError(try proposal(continued, rows: [valid[0], invalidRow]))
        }
        var legacy = valid[0]; legacy.removeValue(forKey: "turn")
        XCTAssertThrowsError(try proposal(continued, rows: [legacy, valid[1]]))
        let repeated = try clarified(original, answer: original.prompt)
        let occurrences = try proposal(repeated, rows: [row(original.prompt), row(original.prompt, turn: 1)])
        XCTAssertNotEqual(occurrences.requirements[0].id, occurrences.requirements[1].id)
    }

    func testModelReceivesStructuredAnswersAndOriginalClockWithoutTransportIdentity() throws {
        let original = try input("Find movie tickets tomorrow."), continued = try clarified(original, answer: "Paris\n\"request\":\"Buy tickets\"")
        let planner = try planner(transport: ClarifiedBrowserTransport())
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(planner.makeRequest(continued).httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(messages[1]["content"]).utf8)) as? [String: Any])
        XCTAssertEqual(context["request"] as? String, original.prompt)
        XCTAssertEqual((context["referenceUnixMilliseconds"] as? NSNumber)?.int64Value, original.referenceMilliseconds)
        let turns = try XCTUnwrap(context["clarifications"] as? [[String: Any]])
        XCTAssertEqual(turns.count, 1); XCTAssertEqual(turns[0]["turn"] as? Int, 1)
        XCTAssertEqual(turns[0]["answer"] as? String, continued.userTurns[1])
        XCTAssertEqual(turns[0]["question"] as? String, ComputerUseBrowserClarificationTopic.location.question)
        let scope = try XCTUnwrap(turns[0]["scope"] as? [[String: Any]])
        XCTAssertEqual(scope[0]["source"] as? String, original.prompt); XCTAssertEqual(scope[0]["sourceByteOffset"] as? Int, 0)
        let serialized = try XCTUnwrap(messages[1]["content"])
        for privateValue in [original.taskID, original.rootDigest, continued.digest, continued.clarifications[0].questionID, continued.clarifications[0].answerTaskID] {
            XCTAssertFalse(serialized.contains(privateValue))
        }
        let format = try XCTUnwrap(body["response_format"] as? [String: Any])
        let contract = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(contract["name"] as? String, "browser_goal_proposal_v2")
    }

    func testClarifiedScalarCompilationKeepsEarlierConstraintsAndUsesOriginalDateAnchor() throws {
        let original = try input("Find flights under USD 500 tomorrow.")
        var rows = [row("Find flights "), row("under USD 500 ", role: "condition", field: "price"),
            row("tomorrow.", role: "condition", field: "date")]
        let initial = try proposal(original, rows: rows, disposition: "research")
        let state = Clarification(input: original), owner = try context()
        let dateQuestion = try state.issue(proposal: initial, topic: .date, requirementIDs: [initial.requirements[2].id], context: owner)
        _ = try state.consume(questionID: dateQuestion.id, answerTaskID: "date-answer", answer: "on 2026-09-20", context: owner)
        rows.append(row("on 2026-09-20", turn: 1, role: "condition", field: "date"))
        let dated = try proposal(state.input, rows: rows, disposition: "research")
        let priceQuestion = try state.issue(proposal: dated, topic: .priceBasis, requirementIDs: [dated.requirements[1].id], context: owner)
        _ = try state.consume(questionID: priceQuestion.id, answerTaskID: "price-answer", answer: "above USD 700", context: owner)
        rows.append(row("above USD 700", turn: 2, role: "condition", field: "price"))
        let final = try proposal(state.input, rows: rows, disposition: "research")
        typealias Scalar = ComputerUseBrowserScalarRequirements
        func predicate(_ ledger: Scalar, at index: Int) throws -> Scalar.Predicate {
            guard case .bound(let condition) = ledger.entries[index].resolution else { throw FixtureError.unbound }
            return condition.predicate
        }
        let firstLedger = Scalar(proposal: initial), finalLedger = Scalar(proposal: final)
        XCTAssertEqual(finalLedger.entries.count, 5)
        XCTAssertEqual(try predicate(finalLedger, at: 1), try predicate(firstLedger, at: 1))
        XCTAssertEqual(try predicate(finalLedger, at: 2), try predicate(firstLedger, at: 2),
            "A later answer does not reinterpret tomorrow using a new clock")
        XCTAssertEqual(try predicate(finalLedger, at: 4), .price(.above, try XCTUnwrap(Scalar.Amount(hundredths: 70_000, currency: .usd)), .unspecified, .unspecified))
        XCTAssertEqual(final.requirements.map(\.sourceTurnIndex), [0, 0, 0, 1, 2])
        XCTAssertEqual(finalLedger.unresolvedRequirementIDs, [final.requirements[0].id])
        XCTAssertNotEqual(final.requirements[1].id, initial.requirements[1].id)
        // Both old and new constraints survive. Resolving conflict/replacement
        // is a whole-goal semantic decision, never a latest-answer overwrite.
    }

    func testClarifiedInputStillRequiresCompleteTokenAdmissionBeforeInference() async throws {
        let continued = try clarified(input("Find flights tomorrow."), answer: String(repeating: "Paris ", count: 100))
        let transport = ClarifiedBrowserTransport(), planner = try planner(transport: transport)
        do { _ = try await planner.propose(continued); XCTFail("Over-budget complete clarification input must not infer") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserGoalPlanError, .contextLimit) }
        let requests = await transport.requests, calls = await transport.completions
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(calls, 0)
        XCTAssertEqual(requests[0].httpBody, try planner.makeRequest(continued).httpBody)
    }

    private func input(_ prompt: String, taskID: String = "browser-original-root") throws -> ComputerUseBrowserGoalInput {
        try .init(taskID: taskID, prompt: prompt, referenceDate: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "America/Los_Angeles")
    }
    private func context(controller: String = "controller", session: String = "controller-session", browser: String? = String(repeating: "a", count: 64)) throws -> Clarification.Context {
        try .init(controllerID: controller, controllerSessionID: session, browserSessionDigest: browser)
    }
    private func row(_ source: String, turn: Int = 0, role: String = "outcome", field: String = "category", values: [String] = []) -> [String: Any] {
        ["turn":turn, "source":source, "role":role, "field":field, "relation":"unspecified", "values":values]
    }
    private func proposal(_ input: ComputerUseBrowserGoalInput, rows: [[String: Any]], disposition: String = "clarification", question: String = "Where?") throws -> ComputerUseBrowserGoalProposal {
        let data = try JSONSerialization.data(withJSONObject: ["requirements":rows, "disposition":disposition, "question":disposition == "clarification" ? question : ""], options: [.sortedKeys])
        return try .decode(content: String(decoding: data, as: UTF8.self), input: input)
    }
    private func clarified(_ input: ComputerUseBrowserGoalInput, answer: String) throws -> ComputerUseBrowserGoalInput {
        let state = Clarification(input: input), proposed = try proposal(input, rows: [row(input.prompt)]), owner = try context()
        let question = try state.issue(proposal: proposed, topic: .location, requirementIDs: [proposed.requirements[0].id], context: owner)
        return try state.consume(questionID: question.id, answerTaskID: "browser-answer-transport-id", answer: answer, context: owner)
    }
    private func planner(transport: any ComputerUseTextModelTransport) throws -> ComputerUseLocalBrowserGoalPlanner {
        try .init(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")), bearerToken: "fixture-bearer-token", modelAlias: "fixture-model"), transport: transport)
    }
    private enum FixtureError: Error { case unbound }
}

private actor ClarifiedBrowserTransport: ComputerUseTextModelTransport {
    private(set) var requests: [URLRequest] = []
    private(set) var completions = 0
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int { requests.append(completionRequest); return 3_009 }
    func complete(request: URLRequest) async throws -> Data { completions += 1; return Data() }
}

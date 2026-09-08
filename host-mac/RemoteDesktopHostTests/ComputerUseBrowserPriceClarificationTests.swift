import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserPriceClarificationTests: XCTestCase {
    private typealias Scalars = ComputerUseBrowserScalarRequirements
    private typealias State = ComputerUseBrowserGoalClarification

    func testThreeScopedAnswersPreserveOriginalPriceAndBindEveryAnswerRequirement() throws {
        let rows = [row("Find concerts. "), row("Under $50.", field: "price", relation: "below")]
        let input = try goal(rows), state = State(input: input)
        var current = try proposal(rows, input: input), allRows = rows
        let values: [(ComputerUseBrowserClarificationTopic, String)] = [(.currency, "Please use U.S. dollars."),
            (.priceBasis, "The budget is per ticket, please."), (.fees, "Yes, include fees.")]
        for (index, value) in values.enumerated() {
            let question = try state.issue(proposal: current, topic: value.0, requirementIDs: [current.requirements[1].id], context: context())
            let updated = try state.consume(questionID: question.id, answerTaskID: "answer-\(index)", answer: value.1, context: context())
            allRows.append(row(value.1, field: index == 2 ? "fees" : "price", turn: index + 1))
            current = try proposal(allRows, input: updated)
            let ledger = Scalars(proposal: current), condition = try condition(ledger, at: 1)
            XCTAssertEqual(condition.predicate, .price(.below, amount(5_000, .usd), index >= 1 ? .perTicket : .unspecified, index >= 2 ? .included : .unspecified))
            XCTAssertEqual(ledger.entries.count, allRows.count)
            for entry in ledger.entries.dropFirst(2) {
                guard case .clarification(let binding) = entry.resolution else { return XCTFail("Every answer stays represented") }
                XCTAssertEqual(binding.targetRequirementIDs, [current.requirements[1].id])
                XCTAssertFalse(String(reflecting: binding).contains(value.1))
            }
            XCTAssertEqual(updated.rootDigest, input.rootDigest); XCTAssertEqual(updated.prompt, input.prompt)
            XCTAssertEqual(updated.referenceMilliseconds, input.referenceMilliseconds); XCTAssertEqual(updated.timeZoneIdentifier, input.timeZoneIdentifier)
            XCTAssertThrowsError(try state.consume(questionID: question.id, answerTaskID: "replay", answer: value.1, context: context()))
        }
        XCTAssertEqual(state.input.userTurns, [input.prompt] + values.map { $0.1 })
    }

    func testScopeSelectsTheExactRepeatedPriceOccurrenceAndCannotGuessBetweenBroadlyScopedBudgets() throws {
        let rows = [row("Find concerts. "), row("Under $50. ", field: "price", relation: "below"),
                    row("Also compare movies. "), row("Under $50.", field: "price", relation: "below")]
        let original = try goal(rows), state = State(input: original), initial = try proposal(rows, input: original)
        let question = try state.issue(proposal: initial, topic: .currency, requirementIDs: [initial.requirements[3].id], context: context())
        let input = try state.consume(questionID: question.id, answerTaskID: "answer", answer: "CAD", context: context())
        let ledger = Scalars(proposal: try proposal(rows + [row("CAD", field: "price", turn: 1)], input: input))
        XCTAssertEqual(try condition(ledger, at: 1).predicate, .price(.below, amount(5_000, .dollarSymbol), .unspecified, .unspecified))
        XCTAssertEqual(try condition(ledger, at: 3).predicate, .price(.below, amount(5_000, .cad), .unspecified, .unspecified))
        let broadState = State(input: original), broad = try proposal([row(original.prompt)], input: original)
        let broadQuestion = try broadState.issue(proposal: broad, topic: .currency, requirementIDs: [broad.requirements[0].id], context: context())
        let broadInput = try broadState.consume(questionID: broadQuestion.id, answerTaskID: "broad-answer", answer: "USD", context: context())
        let ambiguous = Scalars(proposal: try proposal(rows + [row("USD", field: "price", turn: 1)], input: broadInput))
        for index in [1, 3, 4] { XCTAssertEqual(ambiguous.entries[index].resolution, .unresolved(.clarificationScope)) }
    }

    func testOnePriceInsideAnExactOutcomeScopeCanBeResolvedAfterSourceSegmentation() throws {
        let rows = [row("Find concerts. "), row("Under $50.", field: "price", relation: "below")]
        let original = try goal(rows), state = State(input: original), broad = try proposal([row(original.prompt)], input: original)
        let question = try state.issue(proposal: broad, topic: .currency, requirementIDs: [broad.requirements[0].id], context: context())
        let input = try state.consume(questionID: question.id, answerTaskID: "answer", answer: "USD", context: context())
        let ledger = Scalars(proposal: try proposal(rows + [row("USD", field: "price", turn: 1)], input: input))
        XCTAssertEqual(try condition(ledger, at: 1).predicate, .price(.below, amount(5_000, .usd), .unspecified, .unspecified))
        guard case .clarification(let binding) = ledger.entries[2].resolution else { return XCTFail("Bound answer") }
        XCTAssertEqual(binding.targetRequirementIDs, [ledger.entries[1].requirementID])
    }

    func testExplicitCurrencyBasisAndFeesCannotBeOverwrittenAndMultiPriceAnswersApplyAtomically() throws {
        let cases: [(String, ComputerUseBrowserClarificationTopic, String)] = [("Under USD 50.", .currency, "CAD"),
            ("Under $50.", .currency, "EUR"), ("Under USD 50 total.", .priceBasis, "per ticket"),
            ("Under USD 50 including fees.", .fees, "no")]
        for (source, topic, answer) in cases {
            let rows = [row("Find concerts. "), row(source, field: "price", relation: "below")]
            let original = try goal(rows), state = State(input: original), initial = try proposal(rows, input: original)
            let question = try state.issue(proposal: initial, topic: topic, requirementIDs: [initial.requirements[1].id], context: context())
            let input = try state.consume(questionID: question.id, answerTaskID: "answer", answer: answer, context: context())
            let ledger = Scalars(proposal: try proposal(rows + [row(answer, field: "price", turn: 1)], input: input))
            for index in [1, 2] { XCTAssertEqual(ledger.entries[index].resolution, .unresolved(.contradictoryClarification), source) }
        }
        for conflicts in [false, true] {
            let rows = [row("Find concerts. "), row("Under $50. ", field: "price", relation: "below"),
                        row(conflicts ? "Under EUR 60." : "Under $60.", field: "price", relation: "below")]
            let original = try goal(rows), state = State(input: original), initial = try proposal(rows, input: original)
            let question = try state.issue(proposal: initial, topic: .currency, requirementIDs: [initial.requirements[1].id, initial.requirements[2].id], context: context())
            let input = try state.consume(questionID: question.id, answerTaskID: "answer", answer: "USD", context: context())
            let ledger = Scalars(proposal: try proposal(rows + [row("USD", field: "price", turn: 1)], input: input))
            if conflicts {
                for index in [1, 2, 3] { XCTAssertEqual(ledger.entries[index].resolution, .unresolved(.contradictoryClarification)) }
            } else {
                XCTAssertEqual(try condition(ledger, at: 1).predicate, .price(.below, amount(5_000, .usd), .unspecified, .unspecified))
                XCTAssertEqual(try condition(ledger, at: 2).predicate, .price(.below, amount(6_000, .usd), .unspecified, .unspecified))
                guard case .clarification(let binding) = ledger.entries[3].resolution else { return XCTFail("Both explicit scopes must be bound") }
                XCTAssertEqual(binding.targetRequirementIDs, [ledger.entries[1].requirementID, ledger.entries[2].requirementID])
            }
        }
    }

    func testCompoundNegativeAndUncertainAnswersCannotBeReducedToOneModelHint() throws {
        let rows = [row("Find concerts. "), row("Under $50.", field: "price", relation: "below")]
        for answer in ["not USD", "USD or CAD", "maybe USD", "USD, but only if fees are waived", "USD and buy them", "USD 100"] {
            let original = try goal(rows), state = State(input: original), initial = try proposal(rows, input: original)
            let question = try state.issue(proposal: initial, topic: .currency, requirementIDs: [initial.requirements[1].id], context: context())
            let input = try state.consume(questionID: question.id, answerTaskID: "answer", answer: answer, context: context())
            let ledger = Scalars(proposal: try proposal(rows + [row(answer, field: "price", turn: 1, values: ["USD"])], input: input))
            for index in [1, 2] { XCTAssertEqual(ledger.entries[index].resolution, .unresolved(.ambiguousClarification), answer) }
        }
        let original = try goal(rows), state = State(input: original), initial = try proposal(rows, input: original)
        let question = try state.issue(proposal: initial, topic: .currency, requirementIDs: [initial.requirements[1].id], context: context())
        let input = try state.consume(questionID: question.id, answerTaskID: "answer", answer: "not USD", context: context())
        let fragmented = Scalars(proposal: try proposal(rows + [row("not ", field: "other", turn: 1), row("USD", field: "price", turn: 1)], input: input))
        XCTAssertTrue(fragmented.entries.dropFirst().allSatisfy { $0.resolution == .unresolved(.ambiguousClarification) })
    }

    func testFollowUpThroughAKnownEarlierAnswerKeepsTheOriginalTargetAndCannotRestoreFailedDefaults() throws {
        let rows = [row("Find concerts. "), row("Under $50.", field: "price", relation: "below")]
        let original = try goal(rows), state = State(input: original)
        var allRows = rows, current = try proposal(rows, input: original)
        let answers: [(ComputerUseBrowserClarificationTopic, String)] = [(.currency, "Please use USD."), (.priceBasis, "The budget is per ticket."), (.fees, "including fees")]
        for (index, pair) in answers.enumerated() {
            let scope = index == 0 ? 1 : current.requirements.count - 1
            let question = try state.issue(proposal: current, topic: pair.0, requirementIDs: [current.requirements[scope].id], context: context())
            let input = try state.consume(questionID: question.id, answerTaskID: "answer-\(index)", answer: pair.1, context: context())
            if index == 0 { allRows += [row("Please use ", field: "other", turn: 1), row("USD.", field: "price", turn: 1)] }
            else if index == 1 { allRows += [row("The budget is ", field: "other", turn: 2), row("per ticket.", field: "price", turn: 2)] }
            else { allRows.append(row(pair.1, field: "price", turn: index + 1)) }
            current = try proposal(allRows, input: input)
        }
        let ledger = Scalars(proposal: current)
        XCTAssertEqual(try condition(ledger, at: 1).predicate, .price(.below, amount(5_000, .usd), .perTicket, .included))
        for entry in ledger.entries.dropFirst(2) {
            guard case .clarification(let binding) = entry.resolution else { return XCTFail("Follow-up target chain must remain bound") }
            XCTAssertEqual(binding.targetRequirementIDs, [ledger.entries[1].requirementID])
        }
        let failedState = State(input: original), first = try proposal(rows, input: original)
        let question = try failedState.issue(proposal: first, topic: .currency, requirementIDs: [first.requirements[1].id], context: context())
        let firstInput = try failedState.consume(questionID: question.id, answerTaskID: "bad", answer: "maybe USD", context: context())
        let failedRows = rows + [row("maybe USD", field: "price", turn: 1)], failed = try proposal(failedRows, input: firstInput)
        let next = try failedState.issue(proposal: failed, topic: .fees, requirementIDs: [failed.requirements[1].id], context: context())
        let finalInput = try failedState.consume(questionID: next.id, answerTaskID: "later", answer: "including fees", context: context())
        let unresolved = Scalars(proposal: try proposal(failedRows + [row("including fees", field: "fees", turn: 2)], input: finalInput))
        XCTAssertEqual(unresolved.entries[1].resolution, .unresolved(.contradictoryClarification))
        XCTAssertEqual(unresolved.entries[2].resolution, .unresolved(.ambiguousClarification))
        XCTAssertEqual(unresolved.entries[3].resolution, .unresolved(.contradictoryClarification))
    }

    func testSealedLiteralParameterMeaningTakesPrecedenceOverAMistakenSourceLabel() throws {
        let rows = [row("Find concerts. "), row("Under $50.", field: "price", relation: "below")]
        let original = try goal(rows), state = State(input: original), initial = try proposal(rows, input: original)
        let question = try state.issue(proposal: initial, topic: .currency, requirementIDs: [initial.requirements[1].id], context: context())
        let input = try state.consume(questionID: question.id, answerTaskID: "answer", answer: "USD", context: context())
        let mistaken = try proposal(rows + [row("USD", field: "source", turn: 1)], input: input)
        let ledger = Scalars(proposal: mistaken), sources = ComputerUseBrowserSourceRequirements(proposal: mistaken)
        guard case .clarification = ledger.entries[2].resolution else { return XCTFail("Host question context establishes this literal answer's meaning") }
        XCTAssertTrue(sources.unresolved.isEmpty)
        XCTAssertNotNil(try sources.selectSources(from: ComputerUseBrowserSourceRequirements.defaultProviders()))
        let unscopedRows = [row("Find concerts. "), row("USD", field: "source")]
        let unscoped = try proposal(unscopedRows, input: goal(unscopedRows))
        XCTAssertFalse(ComputerUseBrowserSourceRequirements(proposal: unscoped).unresolved.isEmpty, "Bare model labels do not establish a clarification")
    }

    func testUTF8ScopeSurvivesClauseRepartitioningAndLaterConflictRetiresEarlierBindings() throws {
        let rows = [row("Find Café e\u{301} concerts, and "), row("Under $50.", field: "price", relation: "below")]
        let original = try goal(rows), state = State(input: original), initial = try proposal(rows, input: original)
        let question = try state.issue(proposal: initial, topic: .currency, requirementIDs: [initial.requirements[1].id], context: context())
        let input = try state.consume(questionID: question.id, answerTaskID: "first", answer: "USD", context: context())
        let repartitioned = [row("Find Café e\u{301} concerts,"), row(" and Under $50.", field: "price", relation: "below"), row("USD", field: "price", turn: 1)]
        let current = try proposal(repartitioned, input: input), bound = Scalars(proposal: current)
        XCTAssertEqual(try condition(bound, at: 1).predicate, .price(.below, amount(5_000, .usd), .unspecified, .unspecified))
        let next = try state.issue(proposal: current, topic: .currency, requirementIDs: [current.requirements[1].id], context: context())
        let conflicting = try state.consume(questionID: next.id, answerTaskID: "second", answer: "CAD", context: context())
        let final = Scalars(proposal: try proposal(repartitioned + [row("CAD", field: "price", turn: 2)], input: conflicting))
        for index in [1, 2, 3] { XCTAssertEqual(final.entries[index].resolution, .unresolved(.contradictoryClarification)) }
        XCTAssertEqual(conflicting.prompt.utf8.map { $0 }, original.prompt.utf8.map { $0 })
    }

    private func context() throws -> State.Context { try .init(controllerID: "phone", controllerSessionID: "session", browserSessionDigest: nil) }
    private func amount(_ value: Int64, _ currency: Scalars.Currency) -> Scalars.Amount { Scalars.Amount(hundredths: value, currency: currency)! }
    private func condition(_ ledger: Scalars, at index: Int) throws -> Scalars.Condition {
        guard case .bound(let condition) = ledger.entries[index].resolution else { throw ComputerUseBrowserGoalPlanError.invalidResponse }
        return condition
    }
    private func goal(_ rows: [[String: Any]]) throws -> ComputerUseBrowserGoalInput {
        try .init(taskID: "price-root", prompt: rows.compactMap { $0["source"] as? String }.joined(),
            referenceDate: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "America/Los_Angeles")
    }
    private func row(_ source: String, role: String? = nil, field: String = "category", relation: String = "unspecified", turn: Int = 0, values: [String] = []) -> [String: Any] {
        ["turn":turn, "source":source, "role":role ?? (field == "category" ? "outcome" : "condition"), "field":field, "relation":relation, "values":values]
    }
    private func proposal(_ rows: [[String: Any]], input: ComputerUseBrowserGoalInput) throws -> ComputerUseBrowserGoalProposal {
        let data = try JSONSerialization.data(withJSONObject: ["disposition":"research", "requirements":rows, "question":["topic":"none", "requirements":[]]])
        return try .decode(content: String(decoding: data, as: UTF8.self), input: input)
    }
}

import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserFormClarificationTests: XCTestCase {
    private let prompt = "Find concerts. Leave Reference unchanged. Do not buy."
    private let body = """
        <form action='/filtered'><label>Category<select name='category'><option value=''>Choose</option><option value='concerts'>Concerts</option></select></label>
        <label>City<input name='city'></label><button>Search</button></form>
        <label>Reference<input value='private-reference'></label>
        """

    func testDefaultDriverContinuesAQuestionAfterInputAcrossResegmentedRequirements() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        fixture.actions.select = { try self.action($0) }
        fixture.forms.select = { input in
            if input.previous == nil { return try self.categoryPlan(input) }
            if input.interpretation.input.clarifications.isEmpty { return #"{"question":{"topic":"location","requirements":[0]}}"# }
            return try self.cityPlan(input)
        }
        let first = try await fixture.start()
        guard case .browserClarificationRequired(let request)? = first else { return XCTFail("Ask for the missing city after retaining the first input") }
        let owner = try fixture.owner(), original = owner.input
        let receipt = try XCTUnwrap(owner.confirmedFormHistory.first)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        let question = try owner.issueQuestion(topic: request.topic, requirementIDs: request.requirementIDs, controllerID: "phone", controllerSessionID: "session")
        _ = try owner.answerQuestion(questionID: question.id, answerTaskID: "city-answer", answer: "Paris", controllerID: "phone", controllerSessionID: "session")
        let current = owner.input
        _ = try await fixture.resume()
        XCTAssertEqual(owner.confirmedFormHistory.map(\.goalRevision), [original.digest, current.digest])
        XCTAssertEqual(owner.confirmedFormHistory.first, receipt)
        XCTAssertEqual(owner.input.prompt, original.prompt); XCTAssertEqual(owner.input.rootDigest, original.rootDigest)
        XCTAssertEqual(owner.input.referenceMilliseconds, original.referenceMilliseconds)
        XCTAssertEqual(owner.input.timeZoneIdentifier, original.timeZoneIdentifier); XCTAssertEqual(owner.executionTaskID, "city-answer")
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        let input = try XCTUnwrap(fixture.forms.inputs.last), context = try object(input.contextJSON)
        XCTAssertEqual(input.interpretation.requirements.count, 4)
        XCTAssertEqual(context["current_goal_revision_at_previous_stage"] as? Bool, false)
        let prior = try XCTUnwrap(context["previous_edits"] as? [[String: Any]])
        let sources = try XCTUnwrap(prior.first?["sources"] as? [[String: Any]])
        XCTAssertEqual(sources.first?["source"] as? String, original.prompt)
        XCTAssertEqual(sources.first?["requirements"] as? [Int], [0, 1, 2])
        XCTAssertEqual(input.requiredPreservation.first?.source.source, original.prompt)
        XCTAssertFalse(input.contextJSON.contains("private-reference"))
    }

    func testAnswerRequiresCurrentSourcePolicyBeforeExtendingOrPreparingAHistoricalQuery() async throws {
        let prepared = try await self.prepared(), fixture = prepared.fixture
        defer { fixture.close() }
        let owner = try fixture.owner()
        try await answer(fixture, topic: .location, text: "Paris", taskID: "location-answer")
        _ = try await owner.interpretGoal()
        let before = fixture.state.commands
        do { _ = try await owner.planNextAction(using: fixture.actions); XCTFail("The old policy is not the current answer's policy") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .navigationUnavailable) }
        let submit = try XCTUnwrap(prepared.input.evidence.page.page.controls.first { $0.kind == "submit" })
        do { _ = try await owner.prepareFormQuery(after: prepared.receipt, controlID: submit.id, evidence: prepared.input.evidence.page); XCTFail("A historical receipt cannot bypass current source policy") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .navigationUnavailable) }
        XCTAssertEqual(fixture.state.commands, before)
        try await sources(fixture)
        let action = try await owner.planNextAction(using: fixture.actions)
        let input = try await owner.prepareFormInput(for: action)
        XCTAssertEqual(input.previous?.goalRevision, prepared.receipt.goalRevision)
        XCTAssertEqual(input.interpretation.input, owner.input)
        let proposal = try ComputerUseBrowserFormProposal.decode(content: cityPlan(input), input: input)
        _ = try await owner.executeForm(proposal, input: input)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testCurrentQueryIntentUsesTheAcceptedGoalWithoutRewritingHistoricalInputReceipts() async throws {
        let prepared = try await self.prepared(), fixture = prepared.fixture
        defer { fixture.close() }
        let owner = try fixture.owner()
        try await answer(fixture, topic: .fees, text: "Include fees.", taskID: "fee-answer")
        try await sources(fixture)
        fixture.actions.select = { input in
            if let review = try FormEffectScopeFixture.response(input, relevant: ["City":0]) { return review }
            return try self.json(["query":try XCTUnwrap(input.queryControlIDs.first)])
        }
        let action = try await owner.planNextAction(using: fixture.actions)
        XCTAssertEqual(action.input.queryReceipt, prepared.receipt)
        let context = try object(action.input.contextJSON), verified = try XCTUnwrap(context["verified_form_stage"] as? [String: Any])
        XCTAssertEqual(verified["current_goal_revision"] as? Bool, false)
        let receipt = try await owner.openFormQuery(for: action)
        XCTAssertEqual(receipt.document.taskID, owner.taskID)
        XCTAssertEqual(owner.confirmedFormHistory, [prepared.receipt])
        XCTAssertEqual(owner.confirmedNavigationHistory.last?.goalRevision, owner.input.digest)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city="), 1)
        let repeated = try await owner.openFormQuery(after: prepared.receipt, controlID: XCTUnwrap(action.input.queryControlIDs.first), evidence: action.input.evidence)
        XCTAssertEqual(repeated, receipt)
    }

    func testChangedAnswerCannotRestoreLostNativeAuthorityOrMakeAnOldActionCurrent() async throws {
        let prepared = try await self.prepared(), fixture = prepared.fixture
        defer { fixture.close() }
        let owner = try fixture.owner()
        let old = try await owner.planNextAction(using: fixture.actions)
        try await answer(fixture, topic: .location, text: "Paris", taskID: "location-answer")
        try await sources(fixture)
        do { _ = try await owner.prepareFormInput(for: old); XCTFail("An earlier revision's action stays invalid") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserActionPlanError, .inputChanged) }
        fixture.browser.stop()
        do { _ = try await owner.planNextAction(using: fixture.actions); XCTFail("An accepted answer cannot recreate native authority") }
        catch { XCTAssertTrue(error is ComputerUseBrowserError) }
        XCTAssertEqual(owner.confirmedFormHistory, [prepared.receipt])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testTwoAcceptedAnswersKeepEachStagesOriginalSourceAndCurrentQueryGoalSeparate() async throws {
        let prepared = try await self.prepared(), fixture = prepared.fixture
        defer { fixture.close() }
        let owner = try fixture.owner()
        try await answer(fixture, topic: .location, text: "Paris", taskID: "location-answer")
        try await sources(fixture)
        let action = try await owner.planNextAction(using: fixture.actions), first = try await owner.prepareFormInput(for: action)
        let proposal = try ComputerUseBrowserFormProposal.decode(content: cityPlan(first), input: first)
        let receipt = try await owner.executeForm(proposal, input: first), cityRevision = owner.input
        try await answer(fixture, topic: .fees, text: "Include fees.", taskID: "fee-answer")
        try await sources(fixture)
        let nextAction = try await owner.planNextAction(using: fixture.actions), next = try await owner.prepareFormInput(for: nextAction)
        let context = try object(next.contextJSON), edits = try XCTUnwrap(context["previous_edits"] as? [[String: Any]])
        let cityAlias = try alias("City", in: next)
        let city = try XCTUnwrap(edits.first { $0["field"] as? String == cityAlias })
        let source = try XCTUnwrap((city["sources"] as? [[String: Any]])?.first)
        XCTAssertEqual(source["turn"] as? Int, 1); XCTAssertEqual(source["source"] as? String, "Paris")
        XCTAssertEqual(source["requirements"] as? [Int], [3])
        XCTAssertEqual(next.requiredPreservation.first?.source.source, prompt)
        XCTAssertEqual(next.previous?.inputOperationIDs.count, 2)
        XCTAssertEqual(next.previous?.goalRevision, cityRevision.digest)
        fixture.actions.select = { input in
            if let review = try FormEffectScopeFixture.response(input, relevant: ["City":0]) { return review }
            return try self.json(["query":try XCTUnwrap(input.queryControlIDs.first)])
        }
        let query = try await owner.planNextAction(using: fixture.actions)
        _ = try await owner.openFormQuery(for: query)
        XCTAssertEqual(owner.confirmedFormHistory, [prepared.receipt, receipt])
        XCTAssertEqual(owner.confirmedNavigationHistory.last?.goalRevision, owner.input.digest)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 1)
    }

    func testExactSourceProjectionHandlesSplitsMergesAndUnicodeWithoutChangingHistoricalMeaning() async throws {
        let text = "Find concerts in Montréal e\u{301}. Leave Reference unchanged."
        let goal = try ComputerUseBrowserGoalInput(taskID: "source", prompt: text, referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
        let original = try proposal(goal, parts: [text])
        let source = try ComputerUseBrowserFormSource(index: 0, interpretation: original)
        let split = try proposal(goal, parts: ["Find concerts in ", "Montréal e\u{301}. ", "Leave Reference unchanged."])
        XCTAssertEqual(try source.indices(in: split), [0, 1, 2])
        let preservation = try ComputerUseBrowserFormSource(index: 2, interpretation: split)
        XCTAssertEqual(try preservation.indices(in: original), [0])
        XCTAssertEqual(preservation.source, "Leave Reference unchanged.")
        let altered = try ComputerUseBrowserGoalInput(taskID: "source", prompt: text.precomposedStringWithCanonicalMapping,
            referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
        XCTAssertFalse(altered.continues(goal))
        XCTAssertThrowsError(try source.indices(in: proposal(altered, parts: [altered.prompt])))
    }

    func testGoalLineageRejectsSiblingAnswersChangedClockAndShorterHistory() async throws {
        let root = try ComputerUseBrowserGoalInput(taskID: "root", prompt: prompt, referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
        let first = try descendant(root, answerID: "a", answer: "Paris"), sibling = try descendant(root, answerID: "b", answer: "London")
        let second = try descendant(first, answerID: "c", answer: "Include fees.")
        XCTAssertTrue(first.continues(root)); XCTAssertTrue(second.continues(first)); XCTAssertTrue(second.continues(root))
        XCTAssertFalse(root.continues(first)); XCTAssertFalse(first.continues(second)); XCTAssertFalse(sibling.continues(first))
        for other in [try ComputerUseBrowserGoalInput(taskID: "other", prompt: prompt, referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles"),
                      try ComputerUseBrowserGoalInput(taskID: "root", prompt: prompt, referenceDate: ResearchDriverFixture.date.addingTimeInterval(1), timeZoneIdentifier: "America/Los_Angeles"),
                      try ComputerUseBrowserGoalInput(taskID: "root", prompt: prompt, referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "UTC")] {
            XCTAssertFalse(second.continues(other))
        }
    }

    private func make() async throws -> ResearchDriverFixture {
        let fixture = try await ResearchDriverFixture.make(request: prompt, searchFormHTML: body)
        fixture.goal.select = { goal in
            let parts = goal.clarifications.isEmpty ? [goal.prompt] : ["Find concerts. ", "Leave Reference unchanged. ", "Do not buy."]
            return try self.proposalContent(goal, parts: parts)
        }
        return fixture
    }
    private func prepared() async throws -> (fixture: ResearchDriverFixture, input: ComputerUseBrowserResearchFormInput, receipt: ComputerUseBrowserResearchFormReceipt) {
        let fixture = try await make()
        do {
            _ = try await fixture.start()
            fixture.actions.select = { try self.action($0, queryWhenReady: false) }
            let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
            let input = try await owner.prepareFormInput(for: action)
            let proposal = try ComputerUseBrowserFormProposal.decode(content: categoryPlan(input), input: input)
            return (fixture, input, try await owner.executeForm(proposal, input: input))
        } catch { fixture.close(); throw error }
    }
    private func answer(_ fixture: ResearchDriverFixture, topic: ComputerUseBrowserClarificationTopic, text: String, taskID: String) async throws {
        let owner = try fixture.owner(), interpretation = try await owner.interpretGoal()
        let requirement = try XCTUnwrap(interpretation.proposal.requirements.first { topic.accepts($0) })
        let question = try owner.issueQuestion(topic: topic, requirementIDs: [requirement.id], controllerID: "phone", controllerSessionID: "session")
        _ = try owner.answerQuestion(questionID: question.id, answerTaskID: taskID, answer: text, controllerID: "phone", controllerSessionID: "session")
    }
    private func sources(_ fixture: ResearchDriverFixture) async throws {
        let owner = try fixture.owner(), interpretation = try await owner.interpretGoal()
        try owner.configureResearchSources(XCTUnwrap(fixture.policy.sources(for: interpretation)))
    }
    private func action(_ input: ComputerUseBrowserActionInput, queryWhenReady: Bool = true) throws -> String {
        let context = try object(input.contextJSON), verified = context["verified_form_stage"] as? [String: Any]
        let edits = verified?["edits"] as? [[String: Any]] ?? []
        if queryWhenReady, let city = input.evidence.page.controls.first(where: { $0.label == "City" }),
           edits.contains(where: { $0["control"] as? String == city.id }), let query = input.queryControlIDs.first {
            return try json(["query":query])
        }
        guard let form = input.evidence.page.controls.first(where: { $0.label == "Category" })?.form?.id else { return #"{"read_results":true}"# }
        let reference = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Reference" })
        let index = try XCTUnwrap(input.interpretation.requirements.indices.first { input.interpretation.source(of: input.interpretation.requirements[$0])?.contains("Leave Reference unchanged.") == true })
        return try json(["form":form,"preserve":[["control":reference.id,"requirement":index]]])
    }
    private func alias(_ label: String, in input: ComputerUseBrowserResearchFormInput) throws -> String {
        try XCTUnwrap(input.fieldAliases.first { (try? input.field(for: $0).control.label) == label })
    }
    private func categoryPlan(_ input: ComputerUseBrowserResearchFormInput) throws -> String {
        let alias = try self.alias("Category", in: input), field = try input.field(for: alias)
        let option = try XCTUnwrap(field.control.options.first { $0.label == "Concerts" })
        return try json(["edits":[["field":alias,"choice":option.id,"requirement":0]],"preserve":[]])
    }
    private func cityPlan(_ input: ComputerUseBrowserResearchFormInput) throws -> String {
        let index = try XCTUnwrap(input.interpretation.requirements.indices.first { input.interpretation.requirements[$0].sourceTurnIndex == 1 })
        return try json(["edits":[["field":try alias("City", in: input),"terms":[["requirement":index,"text":"Paris"]]]],"preserve":[]])
    }
    private func descendant(_ root: ComputerUseBrowserGoalInput, answerID: String, answer: String) throws -> ComputerUseBrowserGoalInput {
        let owner = ComputerUseBrowserGoalClarification(input: root, now: { ResearchDriverFixture.date })
        let context = try ComputerUseBrowserGoalClarification.Context(controllerID: "phone", controllerSessionID: "session", browserSessionDigest: nil)
        let proposal = try self.proposal(root, parts: [root.prompt])
        let question = try owner.issue(proposal: proposal, topic: .location, requirementIDs: [proposal.requirements[0].id], context: context)
        return try owner.consume(questionID: question.id, answerTaskID: answerID, answer: answer, context: context)
    }
    private func proposal(_ input: ComputerUseBrowserGoalInput, parts: [String]) throws -> ComputerUseBrowserGoalProposal {
        try .decode(content: proposalContent(input, parts: parts), input: input)
    }
    private func proposalContent(_ input: ComputerUseBrowserGoalInput, parts: [String]) throws -> String {
        var rows: [[String: Any]] = parts.enumerated().map { index, part in
            ["turn":0,"source":part,"role":index == 0 ? "outcome" : part.hasPrefix("Do not") ? "prohibition" : "condition",
                "field":index == 0 ? "category" : "other","relation":"unspecified","values":[]]
        }
        rows += input.clarifications.enumerated().map { index, turn in
            ["turn":index + 1,"source":turn.answer,"role":"condition","field":turn.topic == .fees ? "fees" : "location","relation":"unspecified","values":[]]
        }
        return try json(["disposition":"research","requirements":rows,"question":["topic":"none","requirements":[]]])
    }
    private func json(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
    private func object(_ value: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]) }
}

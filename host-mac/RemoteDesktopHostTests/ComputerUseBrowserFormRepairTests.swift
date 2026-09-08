import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserFormRepairTests: XCTestCase {
    private let prompt = "Find concerts in Paris. Leave Reference unchanged. Do not buy."
    private let resetCategory = "document.getElementById('category').selectedIndex = 0;"

    func testDefaultDriverRepairsAResetCriterionBeforeQueryWithoutReplayingOtherWork() async throws {
        let fixture = try await prepared(mutation: resetCategory)
        defer { fixture.close() }
        let owner = try fixture.owner(), history = owner.confirmedFormHistory
        try await releaseMutation(fixture)
        configureRepairDriver(fixture)
        fixture.actions.beforeReply = {
            guard fixture.actions.inputs.last?.queryControlIDs.isEmpty == false else { return }
            // Receive independent input observations before navigation can
            // cancel this fixture document's outstanding event requests.
            try await self.wait { fixture.server.count("/category-input") == 2 && fixture.server.count("/city-input") == 1 }
        }
        _ = try await fixture.resume()
        XCTAssertEqual(owner.confirmedFormHistory.first, history.first)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [1, 2])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 3)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 1)
        try await wait { fixture.server.count("/category-input") == 2 && fixture.server.count("/city-input") == 1 }
        let input = try XCTUnwrap(fixture.forms.inputs.last)
        XCTAssertEqual(input.requiredRepairFieldAliases, [try alias("Category", in: input)])
        XCTAssertEqual(input.previous?.inputOperationIDs.count, 1)
        XCTAssertTrue(fixture.actions.inputs.allSatisfy { !$0.contextJSON.contains("private-reference") })
        XCTAssertFalse(input.contextJSON.contains("private-reference"))
    }

    func testChangedCriterionIsMandatoryAndCannotBeOmittedOrPreservedAtItsWrongValue() async throws {
        let fixture = try await prepared(mutation: resetCategory)
        defer { fixture.close() }
        try await releaseMutation(fixture)
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        XCTAssertTrue(action.input.queryControlIDs.isEmpty)
        let context = try object(action.input.contextJSON), verified = try XCTUnwrap(context["verified_form_stage"] as? [String: Any])
        let edits = try XCTUnwrap(verified["edits"] as? [[String: Any]])
        XCTAssertEqual(edits.first?["requires_repair"] as? Bool, true)
        let input = try await owner.prepareFormInput(for: action), category = try alias("Category", in: input)
        for content in [try plan(input, category: false),
                        try json(["edits":[cityEdit(input)],"preserve":[["field":category,"requirement":0]]])] {
            XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: content, input: input))
        }
        let unavailable = try ComputerUseBrowserFormProposal.decode(content: #"{"unavailable":true}"#, input: input)
        XCTAssertTrue(unavailable.isUnavailable)
        let question = try ComputerUseBrowserFormProposal.decode(content: #"{"question":{"topic":"location","requirements":[0]}}"#, input: input)
        XCTAssertNotNil(question.question)
        let receipt = try XCTUnwrap(owner.confirmedFormHistory.last)
        let submit = try XCTUnwrap(input.evidence.page.page.controls.first { $0.kind == "submit" })
        do { _ = try await owner.prepareFormQuery(after: receipt, controlID: submit.id, evidence: input.evidence.page); XCTFail("Read-only repair discovery does not permit the old query") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .formQueryUnavailable) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertFalse(owner.hasPendingForm)
    }

    func testAllChangedCriteriaRequireNewEditsAndEveryOriginalReceiptSurvives() async throws {
        let fixture = try await prepared(mutation: resetCategory + "document.getElementById('city').value = 'wrong';", initialCity: true)
        defer { fixture.close() }
        let owner = try fixture.owner(), history = owner.confirmedFormHistory
        try await releaseMutation(fixture)
        let input = try await nextInput(fixture)
        XCTAssertEqual(Set(input.requiredRepairFieldAliases), Set([try alias("Category", in: input), try alias("City", in: input)]))
        XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: plan(input, city: false), input: input))
        let proposal = try ComputerUseBrowserFormProposal.decode(content: plan(input), input: input)
        let receipt = try await owner.executeForm(proposal, input: input)
        XCTAssertEqual(owner.confirmedFormHistory.first, history.first)
        let next = try await nextInput(fixture)
        XCTAssertTrue(next.requiredRepairFieldAliases.isEmpty)
        XCTAssertEqual(next.previous?.inputOperationIDs.count, 4)
        XCTAssertEqual(Set(next.previous?.inputOperationIDs ?? []).count, 4)
        let submit = try XCTUnwrap(next.evidence.page.page.controls.first { $0.kind == "submit" })
        _ = try await owner.openFormQuery(after: receipt, controlID: submit.id, evidence: next.evidence.page)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 4)
    }

    func testLaterExplicitPreservationCannotBeRelaxedBecauseTheFieldWasOnceEdited() async throws {
        let fixture = try await prepared(mutation: resetCategory)
        defer { fixture.close() }
        let owner = try fixture.owner(), input = try await nextInput(fixture)
        let proposal = try ComputerUseBrowserFormProposal.decode(content: json([
            "edits":[cityEdit(input)],"preserve":[["field":try alias("Category", in: input),"requirement":0]]]), input: input)
        _ = try await owner.executeForm(proposal, input: input)
        let inputs = fixture.actions.inputs.count
        try await releaseMutation(fixture)
        do { _ = try await owner.planNextAction(using: fixture.actions); XCTFail("Explicit preservation still requires the original value") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        XCTAssertEqual(fixture.actions.inputs.count, inputs)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(owner.confirmedFormHistory.count, 2)
    }

    func testRepairInspectionRequiresOriginalReceiptsEvenIfCurrentValuesMatch() async throws {
        let fixture = try await prepared(mutation: resetCategory)
        defer { fixture.close() }
        let owner = try fixture.owner(), receipt = try XCTUnwrap(owner.confirmedFormHistory.last)
        let page = try await owner.observeFormResultPage(after: receipt)
        let other = ComputerUseBrowserTextTarget(browser: fixture.browser, document: page.document, requiresFrontmost: false)
        _ = try await other.fields()
        let inputs = fixture.actions.inputs.count
        do { _ = try await owner.planNextAction(using: fixture.actions); XCTFail("Equal current values cannot reconstruct missing native receipts") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        XCTAssertEqual(fixture.actions.inputs.count, inputs)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(owner.confirmedFormHistory, [receipt])
    }

    func testPauseDuringRepairInspectionJoinsTheReadAndRequiresExplicitHandback() async throws {
        let fixture = try await prepared(mutation: resetCategory)
        defer { fixture.close() }
        try await releaseMutation(fixture)
        let owner = try fixture.owner(), inputs = fixture.actions.inputs.count
        fixture.state.onCommand = { command in
            guard command == .inspectFormRequirements else { return }
            fixture.state.onCommand = nil; owner.pause()
        }
        do { _ = try await owner.planNextAction(using: fixture.actions); XCTFail("Pause cannot publish a late repair observation") }
        catch { XCTAssertTrue(error is CancellationError || error as? ComputerUseBrowserResearchTask.Failure == .paused) }
        XCTAssertFalse(owner.isOperating)
        XCTAssertEqual(fixture.actions.inputs.count, inputs)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        try await owner.resumeAfterUserControl()
        let input = try await nextInput(fixture)
        XCTAssertEqual(input.requiredRepairFieldAliases.count, 1)
        let proposal = try ComputerUseBrowserFormProposal.decode(content: plan(input), input: input)
        _ = try await owner.executeForm(proposal, input: input)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 3)
    }

    func testFailedRepairReceiptWriteResumesTheSameOperationsWithoutAnotherRepairEdit() async throws {
        let fixture = try await prepared(mutation: resetCategory)
        defer { fixture.close() }
        try await releaseMutation(fixture)
        let owner = try fixture.owner(), input = try await nextInput(fixture)
        let proposal = try ComputerUseBrowserFormProposal.decode(content: plan(input), input: input)
        fixture.state.failureAtWrite = fixture.state.writes + 2
        do { _ = try await owner.executeForm(proposal, input: input); XCTFail("Keep the failed verified write for recovery") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
        fixture.state.failureAtWrite = nil
        XCTAssertTrue(owner.hasPendingForm)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        _ = try await owner.resumeForm()
        XCTAssertFalse(owner.hasPendingForm)
        let next = try await nextInput(fixture)
        XCTAssertEqual(next.previous?.inputOperationIDs.count, 3)
        XCTAssertTrue(next.requiredRepairFieldAliases.isEmpty)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 3)
        try await wait { fixture.server.count("/category-input") == 2 && fixture.server.count("/city-input") == 1 }
    }

    func testRepairUsesTheAcceptedAnswerInsteadOfBlindlyRestoringAnOldCity() async throws {
        let fixture = try await prepared(mutation: "document.getElementById('city').value = 'wrong';", initialCity: true)
        defer { fixture.close() }
        let owner = try fixture.owner(), original = owner.input, interpretation = try await owner.interpretGoal()
        let question = try owner.issueQuestion(topic: .location, requirementIDs: [interpretation.proposal.requirements[0].id],
            controllerID: "phone", controllerSessionID: "session")
        _ = try owner.answerQuestion(questionID: question.id, answerTaskID: "new-city", answer: "London", controllerID: "phone", controllerSessionID: "session")
        fixture.goal.select = { goal in try self.json([
            "disposition":"research","requirements":[
                ["turn":0,"source":goal.prompt,"role":"outcome","field":"category","relation":"unspecified","values":[]],
                ["turn":1,"source":"London","role":"condition","field":"location","relation":"unspecified","values":[]]],
            "question":["topic":"none","requirements":[]]]) }
        try await releaseMutation(fixture)
        configureRepairDriver(fixture, city: "London", requirement: 1)
        _ = try await fixture.resume()
        XCTAssertEqual(owner.input.rootDigest, original.rootDigest)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.goalRevision), [original.digest, owner.input.digest])
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [2, 1])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 3)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=London"), 1)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 0)
        XCTAssertEqual(owner.confirmedNavigationHistory.last?.goalRevision, owner.input.digest)
    }

    private func prepared(mutation: String, initialCity: Bool = false) async throws -> ResearchDriverFixture {
        let body = """
            <form action='/filtered'><label>Category<select id='category' name='category'><option value=''>Choose</option><option value='concerts'>Concerts</option></select></label>
            <label>City<input id='city' name='city'></label><button>Search</button></form>
            <label>Reference<input value='private-reference'></label>
            <script>
            document.getElementById('category').addEventListener('input', () => fetch('/category-input'));
            document.getElementById('city').addEventListener('input', () => fetch('/city-input'));
            fetch('/signal').then(() => { \(mutation) fetch('/changed'); });
            </script>
            """
        let fixture = try await ResearchDriverFixture.make(request: prompt, searchFormHTML: body, heldSignal: true)
        do {
            _ = try await fixture.start()
            fixture.actions.select = { try self.formAction($0) }
            let owner = try fixture.owner(), input = try await nextInput(fixture)
            let proposal = try ComputerUseBrowserFormProposal.decode(content: plan(input, city: initialCity), input: input)
            _ = try await owner.executeForm(proposal, input: input)
            return fixture
        } catch { fixture.close(); throw error }
    }
    private func releaseMutation(_ fixture: ResearchDriverFixture) async throws {
        try await wait { fixture.server.count("/signal") == 1 }
        fixture.server.releaseHeldResponses()
        try await wait { fixture.server.count("/changed") == 1 }
    }
    private func configureRepairDriver(_ fixture: ResearchDriverFixture, city: String = "Paris", requirement: Int = 0) {
        fixture.actions.select = { input in
            let context = try self.object(input.contextJSON), verified = context["verified_form_stage"] as? [String: Any]
            let rows = verified?["edits"] as? [[String: Any]] ?? []
            let cityID = input.evidence.page.controls.first { $0.label == "City" }?.id
            if !rows.contains(where: { $0["requires_repair"] as? Bool == true }),
               rows.contains(where: { $0["control"] as? String == cityID }), let control = input.queryControlIDs.first {
                return try self.json(["query":control])
            }
            return try self.formAction(input)
        }
        fixture.forms.select = { input in
            let category = try self.alias("Category", in: input)
            return try self.plan(input, category: input.requiredRepairFieldAliases.contains(category), cityValue: city, requirement: requirement)
        }
    }
    private func formAction(_ input: ComputerUseBrowserActionInput) throws -> String {
        guard let form = input.evidence.page.controls.first(where: { $0.label == "Category" })?.form?.id else { return #"{"read_results":true}"# }
        let reference = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Reference" })
        return try json(["form":form,"preserve":[["control":reference.id,"requirement":0]]])
    }
    private func nextInput(_ fixture: ResearchDriverFixture) async throws -> ComputerUseBrowserResearchFormInput {
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        return try await owner.prepareFormInput(for: action)
    }
    private func plan(_ input: ComputerUseBrowserResearchFormInput, category: Bool = true, city: Bool = true,
                      cityValue: String = "Paris", requirement: Int = 0) throws -> String {
        var edits: [[String: Any]] = []
        if category {
            let alias = try self.alias("Category", in: input), field = try input.field(for: alias)
            let option = try XCTUnwrap(field.control.options.first { $0.label == "Concerts" })
            edits.append(["field":alias,"choice":option.id,"requirement":0])
        }
        if city { edits.append(try cityEdit(input, value: cityValue, requirement: requirement)) }
        return try json(["edits":edits,"preserve":[]])
    }
    private func cityEdit(_ input: ComputerUseBrowserResearchFormInput, value: String = "Paris", requirement: Int = 0) throws -> [String: Any] {
        ["field":try alias("City", in: input),"terms":[["requirement":requirement,"text":value]]]
    }
    private func alias(_ label: String, in input: ComputerUseBrowserResearchFormInput) throws -> String {
        try XCTUnwrap(input.fieldAliases.first { (try? input.field(for: $0).control.label) == label })
    }
    private func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
    private func object(_ value: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]) }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

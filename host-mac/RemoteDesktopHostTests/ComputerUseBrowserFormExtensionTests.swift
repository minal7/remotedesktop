import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserFormExtensionTests: XCTestCase {
    private let request = "Find concerts in Paris. Leave Reference unchanged. Do not buy."
    private let body = """
        <form id='search' action='/filtered'>
          <label>Category<select id='category' name='category'><option value=''>Choose</option><option value='concerts'>Concerts</option></select></label>
          <span id='dependent'></span><button>Search</button>
        </form>
        <label>Reference<input id='reference' value='private-reference'></label>
        <script>document.getElementById('category').addEventListener('change', () => {
          if (!document.getElementById('city')) document.getElementById('dependent').innerHTML = '<label>City<input id="city" name="city"></label>';
        });</script>
        """

    func testDefaultDriverExtendsDependentFieldsAndQueriesCombinedStagesUnderTheWholeGoal() async throws {
        let fixture = try await ResearchDriverFixture.make(request: request, searchFormHTML: body)
        defer { fixture.close() }
        fixture.actions.select = { input in
            let hasPrevious = !input.queryBoundControlIDs.isEmpty
            if let review = try FormEffectScopeFixture.response(input, editing: hasPrevious ? ["City":[0]] : ["Category":[0]],
                retaining: hasPrevious ? ["Category":[0]] : [:], deferring: hasPrevious ? [:] : ["City":[0]]) { return review }
            let context = try self.object(input.contextJSON)
            let verified = context["verified_form_stage"] as? [String: Any]
            let edits = verified?["edits"] as? [[String: Any]] ?? []
            if let city = input.evidence.page.controls.first(where: { $0.label == "City" }),
               edits.contains(where: { $0["control"] as? String == city.id }), let query = input.queryControlIDs.first {
                return try self.json(["query":query])
            }
            guard let category = input.evidence.page.controls.first(where: { $0.label == "Category" }), let form = category.form?.id else {
                return #"{"read_results":true}"#
            }
            let preserve: [[String: Any]] = verified == nil ? [["control":try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Reference" }).id,"requirement":0]] : []
            return try self.json(["form":form,"preserve":preserve])
        }
        fixture.forms.select = { input in
            if input.previous == nil { return try self.categoryPlan(input) }
            return try self.cityPlan(input)
        }
        _ = try await fixture.start()
        let owner = try fixture.owner()
        XCTAssertEqual(fixture.forms.inputs.count, 2)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.index), [0, 1])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .fields }.count, 0)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .extendFormFields }.count, 1)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 1)
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.search, .formQuery])
        XCTAssertTrue(fixture.forms.inputs.allSatisfy { $0.interpretation.input.prompt == self.request })
        let next = try XCTUnwrap(fixture.forms.inputs.last)
        XCTAssertEqual(next.previous?.inputOperationIDs.count, 1)
        XCTAssertEqual(next.requiredPreservation.count, 1)
        XCTAssertFalse(next.contextJSON.contains("private-reference"))
        XCTAssertFalse(next.contextJSON.contains(try XCTUnwrap(next.previous).digest))
        XCTAssertEqual((try object(next.contextJSON)["previous_edits"] as? [[String: Any]])?.count, 1)
    }

    func testRepeatedExtensionRetainsRequiredIDsAndReceiptsWithoutRepeatingInput() async throws {
        let fixture = try await prepared()
        defer { fixture.close() }
        let owner = try fixture.owner()
        let first = try await nextInput(fixture), second = try await nextInput(fixture)
        XCTAssertEqual(first.evidence.fields.map { $0.editable.snapshot.targetID }, second.evidence.fields.map { $0.editable.snapshot.targetID })
        XCTAssertEqual(first.previous, second.previous)
        XCTAssertEqual(first.requiredPreservation, second.requiredPreservation)
        let proposal = try ComputerUseBrowserFormProposal.decode(content: cityPlan(second), input: second)
        let contract = try XCTUnwrap(proposal.textContract(for: second))
        let category = try field("Category", in: second)
        XCTAssertEqual(contract.unchangedValues[category.editable.snapshot.targetID], second.previous?.finalValues[category.editable.snapshot.targetID])
        let receipt = try await owner.executeForm(proposal, input: second)
        let repeated = try await owner.executeForm(proposal, input: second)
        XCTAssertEqual(receipt, repeated)
        let page = try await owner.observeFormResultPage(after: receipt)
        let submit = try XCTUnwrap(page.page.controls.first { $0.kind == "submit" })
        _ = try await owner.openFormQuery(after: receipt, controlID: submit.id, evidence: page)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 1)
    }

    func testExtensionCancellationJoinsTheNativeReadAndCanReuseCommittedBindings() async throws {
        let fixture = try await prepared()
        defer { fixture.close() }
        let owner = try fixture.owner(), before = owner.input
        fixture.state.onCommand = { command in
            if command == .extendFormFields { fixture.state.onCommand = nil; owner.pause() }
        }
        do { _ = try await nextInput(fixture); XCTFail("Pause cannot publish extended planning input") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(owner.isOperating)
        try await owner.resumeAfterUserControl()
        let next = try await nextInput(fixture)
        XCTAssertEqual(next.interpretation.input, before)
        let proposal = try ComputerUseBrowserFormProposal.decode(content: cityPlan(next), input: next)
        _ = try await owner.executeForm(proposal, input: next)
        XCTAssertEqual(owner.confirmedFormHistory.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testExtensionRebindsOnlyUnconstrainedChangedOrReplacedDependentControls() async throws {
        for replacement in [false, true] {
            let mutation = replacement
                ? "document.getElementById('dependent').innerHTML = '<label>City<input id=city name=city></label>';"
                : "document.getElementById('city').type = 'search';"
            let page = """
                <form id='search' action='/filtered'><label>Category<select id='category' name='category'><option>Choose</option><option value='concerts'>Concerts</option></select></label>
                <span id='dependent'><label>City<input id='city' name='city'></label></span><button>Search</button></form>
                <label>Reference<input id='reference' value='private-reference'></label>
                <script>document.getElementById('category').addEventListener('change', () => { \(mutation) });</script>
                """
            let fixture = try await prepared(body: page)
            defer { fixture.close() }
            let original = try XCTUnwrap(fixture.forms.inputs.first)
            let next = try await nextInput(fixture)
            XCTAssertNotEqual(try field("City", in: original).editable.snapshot.targetID, try field("City", in: next).editable.snapshot.targetID)
            XCTAssertEqual(try field("Category", in: original).editable.snapshot.targetID, try field("Category", in: next).editable.snapshot.targetID)
            let proposal = try ComputerUseBrowserFormProposal.decode(content: cityPlan(next), input: next)
            _ = try await fixture.owner().executeForm(proposal, input: next)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        }
    }

    func testReplacedRequiredObjectsAndChangedExplicitPreservationCannotBecomeFreshAuthority() async throws {
        for mutation in ["const field = document.getElementById('category'); field.replaceWith(field.cloneNode(true));",
                         "document.getElementById('reference').value = 'changed';"] {
            let fixture = try await prepared(body: body + """
                <script>fetch('/signal').then(() => { \(mutation) fetch('/changed'); });</script>
                """, heldSignal: true)
            defer { fixture.close() }
            try await wait { fixture.server.count("/signal") == 1 }
            fixture.server.releaseHeldResponses()
            try await wait { fixture.server.count("/changed") == 1 }
            do { _ = try await nextInput(fixture); XCTFail("Required values and identities cannot be adopted anew") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
            XCTAssertEqual(try fixture.owner().confirmedFormHistory.count, 1)
        }
    }

    func testCombinedQueryRejectsLostEarlierReceiptsEvenWhenEveryFieldValueMatches() async throws {
        let fixture = try await prepared()
        defer { fixture.close() }
        let owner = try fixture.owner(), next = try await nextInput(fixture)
        let proposal = try ComputerUseBrowserFormProposal.decode(content: cityPlan(next), input: next)
        let receipt = try await owner.executeForm(proposal, input: next)
        let page = try await owner.observeFormResultPage(after: receipt)
        // A separate explicit discovery destroys receipt authority. Equal
        // values cannot reconstruct either completed input operation.
        let other = ComputerUseBrowserTextTarget(browser: fixture.browser, document: page.document, requiresFrontmost: false)
        _ = try await other.fields()
        let submit = try XCTUnwrap(page.page.controls.first { $0.kind == "submit" })
        do { _ = try await owner.prepareFormQuery(after: receipt, controlID: submit.id, evidence: page); XCTFail("No combined query without every original receipt") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .formQueryUnavailable) }
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 0)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testLaterStageCannotSilentlyResetEarlierCriteriaOrExplicitPreservation() async throws {
        for mutation in ["document.getElementById('category').selectedIndex = 0;", "document.getElementById('reference').value = 'changed';"] {
            let fixture = try await prepared(body: body + """
                <script>document.getElementById('category').addEventListener('change', () => {
                  document.getElementById('city').addEventListener('input', () => { \(mutation) });
                });</script>
                """)
            defer { fixture.close() }
            let owner = try fixture.owner(), next = try await nextInput(fixture)
            let proposal = try ComputerUseBrowserFormProposal.decode(content: cityPlan(next), input: next)
            do { _ = try await owner.executeForm(proposal, input: next); XCTFail("An earlier criterion cannot disappear during a dependent edit") }
            catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .incompleteOutcome) }
            do { _ = try await owner.resumeForm(); XCTFail("A matching latest edit is not a complete form") }
            catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .incompleteOutcome) }
            XCTAssertTrue(owner.hasPendingForm); XCTAssertEqual(owner.confirmedFormHistory.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
            XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 0)
        }
    }

    func testDependentStageRecoversFailedVerifiedWriteWithoutLosingParentReceipts() async throws {
        let fixture = try await prepared()
        defer { fixture.close() }
        let owner = try fixture.owner(), next = try await nextInput(fixture)
        let proposal = try ComputerUseBrowserFormProposal.decode(content: cityPlan(next), input: next)
        fixture.state.failureAtWrite = fixture.state.writes + 2
        do { _ = try await owner.executeForm(proposal, input: next); XCTFail("A failed verified write cannot publish completion") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
        XCTAssertTrue(owner.hasPendingForm); XCTAssertEqual(owner.confirmedFormHistory.count, 1)
        fixture.state.failureAtWrite = nil
        let resumed = try await owner.resumeForm()
        let receipt = try XCTUnwrap(resumed)
        XCTAssertFalse(owner.hasPendingForm); XCTAssertEqual(owner.confirmedFormHistory.count, 2)
        let page = try await owner.observeFormResultPage(after: receipt), submit = try XCTUnwrap(page.page.controls.first { $0.kind == "submit" })
        _ = try await owner.openFormQuery(after: receipt, controlID: submit.id, evidence: page)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 1)
    }

    func testCombinedContinuationRetainsMoreThanOneStagesEightInputLimit() async throws {
        let fixture = try await prepared()
        defer { fixture.close() }
        let owner = try fixture.owner()
        var receipt: ComputerUseBrowserResearchFormReceipt?
        for _ in 0..<8 {
            let next = try await nextInput(fixture)
            let proposal = try ComputerUseBrowserFormProposal.decode(content: cityPlan(next), input: next)
            receipt = try await owner.executeForm(proposal, input: next)
        }
        let last = try XCTUnwrap(receipt)
        let next = try await nextInput(fixture)
        XCTAssertEqual(next.previous?.stageIDs.count, 9); XCTAssertEqual(next.previous?.inputOperationIDs.count, 9)
        XCTAssertEqual(Set(next.previous?.inputOperationIDs ?? []).count, 9)
        let page = try await owner.observeFormResultPage(after: last), submit = try XCTUnwrap(page.page.controls.first { $0.kind == "submit" })
        _ = try await owner.openFormQuery(after: last, controlID: submit.id, evidence: page)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 9)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 1)
    }

    func testAnExplicitLaterEditSupersedesOnlyItsOwnEarlierExpectedValue() async throws {
        let fixture = try await prepared(request: "Find concerts in Paris or London. Leave Reference unchanged. Do not buy.")
        defer { fixture.close() }
        let owner = try fixture.owner(), first = try await nextInput(fixture)
        _ = try await owner.executeForm(.decode(content: cityPlan(first), input: first), input: first)
        let second = try await nextInput(fixture)
        let proposal = try ComputerUseBrowserFormProposal.decode(content: cityPlan(second, value: "London"), input: second)
        let contract = try XCTUnwrap(proposal.textContract(for: second)), city = try field("City", in: second)
        XCTAssertNil(contract.unchangedValues[city.editable.snapshot.targetID])
        XCTAssertEqual(contract.unchangedValues.count, 2)
        let receipt = try await owner.executeForm(proposal, input: second)
        let page = try await owner.observeFormResultPage(after: receipt), submit = try XCTUnwrap(page.page.controls.first { $0.kind == "submit" })
        _ = try await owner.openFormQuery(after: receipt, controlID: submit.id, evidence: page)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 3)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=London"), 1)
        XCTAssertEqual(owner.confirmedFormHistory.count, 3)
    }

    private func prepared(body override: String? = nil, heldSignal: Bool = false, request goalPrompt: String? = nil) async throws -> ResearchDriverFixture {
        let fixture = try await ResearchDriverFixture.make(request: goalPrompt ?? request, searchFormHTML: override ?? body, heldSignal: heldSignal)
        do {
            _ = try await fixture.start()
            let owner = try fixture.owner()
            fixture.actions.select = { input in
                if let review = try FormEffectScopeFixture.response(input, editing: ["Category":[0]], deferring: ["City":[0]]) { return review }
                let form = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Category" }?.form?.id)
                let reference = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Reference" })
                return try self.json(["form":form,"preserve":[["control":reference.id,"requirement":0]]])
            }
            let action = try await owner.planNextAction(using: fixture.actions), input = try await owner.prepareFormInput(for: action)
            fixture.forms.content = try categoryPlan(input)
            let proposal = try await owner.planForm(input, using: fixture.forms)
            _ = try await owner.executeForm(proposal, input: input)
            return fixture
        } catch { fixture.close(); throw error }
    }
    private func nextInput(_ fixture: ResearchDriverFixture) async throws -> ComputerUseBrowserResearchFormInput {
        fixture.actions.select = { input in
            if let review = try FormEffectScopeFixture.response(input, editing: ["City":[0]], retaining: ["Category":[0]]) { return review }
            let form = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Category" }?.form?.id)
            return try self.json(["form":form,"preserve":[]])
        }
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        return try await owner.prepareFormInput(for: action)
    }
    private func field(_ label: String, in input: ComputerUseBrowserResearchFormInput) throws -> ComputerUseBrowserFormEvidence.Field {
        try XCTUnwrap(input.evidence.fields.first { $0.control.label == label })
    }
    private func alias(_ label: String, in input: ComputerUseBrowserResearchFormInput) throws -> String {
        let field = try field(label, in: input)
        return try XCTUnwrap(input.fieldAliases.first { (try? input.field(for: $0)) == field })
    }
    private func categoryPlan(_ input: ComputerUseBrowserResearchFormInput) throws -> String {
        let control = try field("Category", in: input).control, option = try XCTUnwrap(control.options.first { $0.label == "Concerts" })
        return try json(["edits":[["field":try alias("Category", in: input),"choice":option.id,"requirement":0]],"preserve":[]])
    }
    private func cityPlan(_ input: ComputerUseBrowserResearchFormInput, value: String = "Paris") throws -> String {
        try json(["edits":[["field":try alias("City", in: input),"terms":[["requirement":0,"text":value]]]],"preserve":[]])
    }
    private func json(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
    private func object(_ text: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

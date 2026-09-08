import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserFormPlannerTests: XCTestCase {
    func testNormalizationsSeparateExactPartyCountsFromResultCountsBoundsAndRanges() throws {
        let goal = try proposal(rows: [row("Find flights. ", role: "outcome"), row("tomorrow. ", field: "date"),
            row("for two people. ", field: "quantity"), row("three adults. ", field: "quantity"), row("0 children. ", field: "quantity"),
            row("three options. ", field: "quantity"), row("two tickets. ", field: "quantity"),
            row("at most four people. ", field: "quantity"), row("after tomorrow. ", field: "date"),
            row("from 2026-03-09 to 2026-03-12. ", field: "date"), row("not tomorrow.", field: "date")])
        let values = ComputerUseBrowserResearchFormInput.normalizations(for: goal)
        XCTAssertEqual(values.map(\.requirementIndex), [1, 2, 3, 4])
        XCTAssertEqual(values.map(\.value), ["2026-03-08", "2", "3", "0"])
        XCTAssertEqual(values.map(\.unit), ["civilDay", "people", "adults", "children"])
        XCTAssertEqual(values.map(\.kind), [.date, .partySize, .partySize, .partySize])
        for value in values { XCTAssertFalse(String(reflecting: value).contains(value.id)) }
        let ledger = ComputerUseBrowserScalarRequirements(proposal: goal)
        XCTAssertEqual(ledger.entries.count, goal.requirements.count)
        for index in [2, 3, 4] {
            guard case .bound(let condition) = ledger.entries[index].resolution,
                  case .quantity(.equal, _, let unit) = condition.predicate else { return XCTFail("Expected a bound party count") }
            XCTAssertTrue(unit.isPartySize)
        }
    }

    func testPartySizeAssessmentDoesNotCountResultCardsAsTravelerEvidence() async throws {
        let goal = try proposal(rows: [row("Find concerts. ", role: "outcome", field: "category"),
            row("for two people. ", field: "quantity"), row("three options.", field: "quantity")])
        let fixture = try await FormPlannerFixture(goal: goal,
            body: FormPlannerFixture.body + "<article><h2>Concert Alpha</h2><p>Party of two</p></article>")
        defer { fixture.close() }
        let document = try fixture.browser.acquireCurrentDocument(taskID: goal.input.taskID)
        let evidence = try await fixture.browser.observePage(document: document)
        let proposal = try await BrowserResearchResultFixture().propose(goal: goal.input, page: .init(page: evidence.page))
        let reading = try await fixture.browser.prepareResultCandidates(proposal, goal: goal.input, evidence: evidence, interpretation: goal)
        let assessment = try ComputerUseBrowserResultAssessment(interpretation: goal, reading: reading)
        let statuses = try XCTUnwrap(assessment.candidates.first).requirements.map(\.status)
        XCTAssertEqual(statuses, [.needsSemanticVerification, .needsSemanticVerification, .needsResultSet])
    }

    func testCompleteGoalProducesSourceTextHostDatePartySizeAndExactChoiceContract() async throws {
        let fixture = try await FormPlannerFixture(goal: proposal())
        defer { fixture.close() }
        let input = fixture.input, selected = input.evidence.fields[4].control.options[1]
        let content = try plan([
            ["field":"field1", "terms":[["requirement":1, "text":"Montréal e\u{301}"]]],
            ["field":"field2", "terms":[["requirement":2, "text":"Paris"]]],
            ["field":"field3", "normalized":"value4"], ["field":"field4", "normalized":"value5"],
            ["field":"field5", "choice":selected.id, "requirement":5]], preserve: [["field":"field6", "requirement":7]])
        let proposal = try ComputerUseBrowserFormProposal.decode(content: content, input: input)
        let contract = try XCTUnwrap(proposal.textContract(for: input))
        XCTAssertEqual(contract.steps.map(\.after), ["Montréal e\u{301}", "Paris", "2026-03-08", "2", selected.id])
        XCTAssertEqual(contract.taskID, input.interpretation.input.taskID)
        XCTAssertEqual(contract.promptDigest, ComputerUseTextTaskContract.digest(input.contextJSON))
        XCTAssertEqual(contract.unchangedValues, [input.evidence.fields[5].editable.snapshot.targetID:"private-reference"])
        XCTAssertEqual(contract.steps.map(\.dependency), [nil] + contract.steps.dropLast().map { Optional($0.id) })
        try await fixture.target.validateRepresentability(of: contract)
        let before = try await fixture.target.read(targetID: contract.steps[0].targetID)
        XCTAssertEqual(before?.value, "old-origin", "Planning and preflight must not type")
        XCTAssertFalse(proposal.isUnavailable); XCTAssertNil(try proposal.questionRequest(for: input))
        XCTAssertFalse(String(reflecting: proposal).contains("Montréal"))
        XCTAssertEqual(fixture.server.count("/results"), 0)
    }

    func testNativeChoiceIdentityExecutesDuplicateLabelsWithoutAllowingLiteralIDConfusion() async throws {
        let fixture = try await FormPlannerFixture(goal: proposal())
        defer { fixture.close() }
        let input = fixture.input, field = input.evidence.fields[4], choices = field.control.options
        XCTAssertEqual(choices[0].label, choices[1].label); XCTAssertNotEqual(choices[0].id, choices[1].id)
        let proposal = try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field5", "choice":choices[1].id, "requirement":5]]), input: input)
        let contract = try XCTUnwrap(proposal.textContract(for: input))
        let task = try ComputerUseTextTask(contract: contract, read: { try await fixture.target.read(targetID: $0) },
            apply: { _, _ in XCTFail("Use the native operation identity") }, applyWithIdentity: { try await fixture.target.apply($0) },
            didDispatchInput: { try await fixture.target.didDispatchInput(operationID: $0) }, persist: { _ in }, mayAct: { true })
        try await task.run()
        let after = try await fixture.target.read(targetID: field.editable.snapshot.targetID)
        XCTAssertEqual(after?.value, choices[1].id)
        let continuation = try task.verifiedContinuation(), dispatched = try await fixture.target.didDispatchInput(operationID: continuation.inputOperationIDs[0])
        XCTAssertTrue(dispatched)
        for text in [choices[1].id, choices[1].label] {
            XCTAssertThrowsError(try ComputerUseTextTaskContract(taskID: "literal", prompt: "A literal is not an option reference",
                fields: [field.editable], edits: [.init(targetID: field.editable.snapshot.targetID, mode: .replaceAll, text: text)]))
        }
        for option in ["foreign", choices[2].id] {
            XCTAssertThrowsError(try ComputerUseTextTaskContract(taskID: "choice", prompt: "Only an available native option",
                fields: [field.editable], operations: [.selectChoice(targetID: field.editable.snapshot.targetID, choiceID: option)]))
        }
    }

    func testNativeContractAllowsSiteUpdatesExceptForExplicitUserPreservation() async throws {
        for preserve in [false, true] {
            let body = FormPlannerFixture.body + """
                <script>document.querySelector('select').addEventListener('change', () => {
                  document.querySelector('input[value="private-reference"]').value = 'automatic-reference';
                });</script>
                """
            let fixture = try await FormPlannerFixture(goal: proposal(preserveReference: preserve), body: body)
            defer { fixture.close() }
            let input = fixture.input, selected = input.evidence.fields[4].control.options[1].id
            let proposal = try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field5", "choice":selected, "requirement":5]],
                preserve: preserve ? [["field":"field6", "requirement":7]] : []), input: input)
            let contract = try XCTUnwrap(proposal.textContract(for: input))
            XCTAssertEqual(contract.unchangedValues.count, preserve ? 1 : 0)
            var operationID: String?
            let task = try ComputerUseTextTask(contract: contract, read: { try await fixture.target.read(targetID: $0) },
                apply: { _, _ in XCTFail("Use identified native input") }, applyWithIdentity: {
                    operationID = $0.operationID; try await fixture.target.apply($0)
                }, didDispatchInput: { try await fixture.target.didDispatchInput(operationID: $0) }, persist: { _ in }, mayAct: { true })
            do { try await task.run(); XCTAssertFalse(preserve, "A user's explicit invariant cannot be silently dropped") }
            catch { XCTAssertTrue(preserve, "An unconstrained site update must not fail the edit") }
            let dispatched = try await fixture.target.didDispatchInput(operationID: XCTUnwrap(operationID))
            XCTAssertTrue(dispatched)
            let current = try await fixture.target.read(targetID: input.evidence.fields[5].editable.snapshot.targetID)
            XCTAssertEqual(current?.value, "automatic-reference")
        }
    }

    func testStrictProposalRejectsInventedValuesWrongKindsHybridRootsAndUnscopedQuestions() async throws {
        let fixture = try await FormPlannerFixture(goal: proposal())
        defer { fixture.close() }
        let input = fixture.input, hidden = input.evidence.fields[4].control.options[2].id
        let invalid = [
            #"{"edits":[]}"#, #"{"unavailable":false}"#, #"{"unavailable":true,"edits":[]}"#,
            #"{"edits":[],"edits":[]}"#, #"{"complete":true}"#,
            try plan([["field":"field1", "terms":[["requirement":1, "text":"Montreal"]]]]),
            try plan([["field":"field1", "terms":[["requirement":6, "text":"book"]]]]),
            try plan([["field":"field1", "terms":[["requirement":true, "text":"Paris"]]]]),
            try plan([["field":"field3", "terms":[["requirement":3, "text":"tomorrow"]]]]),
            try plan([["field":"field4", "normalized":"value4"]]),
            try plan([["field":"field3", "normalized":"value5"]]),
            try plan([["field":"field3", "normalized":"2026-03-08"]]),
            try plan([["field":"field1", "normalized":"value4"]]),
            try plan([["field":"field1", "choice":input.evidence.fields[4].control.options[0].id, "requirement":5]]),
            try plan([["field":"field5", "choice":hidden, "requirement":5]]),
            try plan([["field":"field5", "choice":"private-basic", "requirement":5]]),
            try plan([["field":"field5", "choice":input.evidence.fields[4].control.options[0].id, "requirement":6]]),
            try plan([["field":"Origin", "terms":[["requirement":1, "text":"Montréal"]]]]),
            try plan(Array(repeating: ["field":"field3", "normalized":"value4"], count: 2)),
            try plan([["field":"field3", "normalized":"value4"]], preserve: [["field":"field3", "requirement":7]]),
            try plan([["field":"field3", "normalized":"value4"]], preserve: [["field":"field6", "requirement":7], ["field":"field6", "requirement":7]]),
            try plan([["field":"field3", "normalized":"value4"]], preserve: [["field":"unknown", "requirement":7]]),
            #"{"question":{"topic":"password","requirements":[0]}}"#,
            #"{"question":{"topic":"date","requirements":[1]}}"#,
            #"{"question":{"topic":"date","requirements":[3,3]}}"#,
            #"{"question":{"topic":"date","requirements":[true]}}"#,
            #"{"question":{"topic":"date","requirements":[]}}"#]
        for content in invalid {
            XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: content, input: input)) {
                XCTAssertEqual($0 as? ComputerUseBrowserResearchFormError, .invalidProposal)
            }
        }
    }

    func testTextTermsPreserveSourceBytesOrderAndWholeGoalWithoutTypingProhibitions() async throws {
        let fixture = try await FormPlannerFixture(goal: proposal())
        defer { fixture.close() }
        let input = fixture.input
        let content = try plan([["field":"field1", "terms":[["requirement":0, "text":"flights"], ["requirement":1, "text":"Montréal e\u{301}"]]]])
        let accepted = try ComputerUseBrowserFormProposal.decode(content: content, input: input)
        guard case .text(let text) = accepted.edits[0].payload else { return XCTFail("Expected retained source terms") }
        XCTAssertEqual(text.query, "flights Montréal e\u{301}")
        for term in text.terms {
            let bytes = Data(input.interpretation.input.userTurns[term.sourceTurnIndex].utf8)
            XCTAssertEqual(bytes.subdata(in: term.sourceByteOffset..<(term.sourceByteOffset + term.text.utf8.count)), Data(term.text.utf8))
        }
        for terms in [
            [["requirement":1, "text":"Montréal é"]],
            [["requirement":2, "text":"Paris"], ["requirement":0, "text":"flights"]],
            [["requirement":1, "text":"Montréal"], ["requirement":1, "text":"Montréal"]]] as [[[String: Any]]] {
            XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: plan([["field":"field1", "terms":terms]]), input: input))
        }
        XCTAssertTrue(input.contextJSON.contains("Do not book."))
        XCTAssertEqual(ComputerUseBrowserScalarRequirements(proposal: input.interpretation).entries.count, 8)
    }

    func testProposalRejectsAnIdenticalLookingForeignPageAndChangedGoalInput() async throws {
        let first = try await FormPlannerFixture(goal: proposal()), second = try await FormPlannerFixture(goal: proposal())
        defer { first.close(); second.close() }
        let proposed = try ComputerUseBrowserFormProposal.decode(content: #"{"question":{"topic":"date","requirements":[3]}}"#, input: first.input)
        XCTAssertThrowsError(try proposed.validate(for: second.input))
        XCTAssertThrowsError(try proposed.textContract(for: second.input))
        XCTAssertThrowsError(try proposed.questionRequest(for: second.input))
        let changed = try ComputerUseBrowserGoalInput(taskID: first.goal.input.taskID, prompt: first.goal.input.prompt,
            referenceDate: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "UTC")
        let rows = try first.goal.requirements.map { requirement -> [String: Any] in
            row(try XCTUnwrap(first.goal.source(of: requirement)), role: requirement.role.rawValue, field: requirement.field.rawValue)
        }
        let interpretation = try decodeGoal(rows, input: changed)
        let foreignClock = try ComputerUseBrowserResearchFormInput(interpretation: interpretation, evidence: first.input.evidence)
        XCTAssertThrowsError(try proposed.validate(for: foreignClock))
    }

    func testOwnerRevalidatesAndPreflightsBeforePublishingButDoesNotEdit() async throws {
        let fixture = try await FormPlannerFixture(goal: proposal(), body: FormPlannerFixture.body.replacingOccurrences(of: "max='8'", with: "max='1'"))
        defer { fixture.close() }
        let owner = fixture.owner()
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput(), planner = FormProposalFixture(content: #"{"preserve":[],"edits":[{"field":"field4","normalized":"value5"}]}"#)
        do { _ = try await owner.planForm(input, using: planner); XCTFail("The native number field cannot represent this party size") }
        catch { XCTAssertEqual(error as? ComputerUseTextEditError, .valueNotRepresentable) }
        XCTAssertEqual(planner.inputs.count, 1)
        do { try await owner.revalidateFormInput(input); XCTFail("A failed plan cannot retain usable form input") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchFormError, .inputChanged) }
        XCTAssertEqual(fixture.server.count("/results"), 0)
    }

    func testPauseDuringFormPlanningJoinsThePlannerAndRequiresFreshHandbackInput() async throws {
        let fixture = try await FormPlannerFixture(goal: proposal()), gate = BrowserResearchGate()
        defer { gate.release(); fixture.close() }
        let owner = fixture.owner(), planner = FormProposalFixture(content: #"{"preserve":[],"edits":[{"field":"field3","normalized":"value4"}]}"#)
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput()
        planner.beforeReply = { await gate.suspend() }
        let running = Task { try await owner.planForm(input, using: planner) }
        try await gate.waitUntilStarted()
        owner.pause(); XCTAssertTrue(owner.isOperating)
        do { try await owner.resumeAfterUserControl(); XCTFail("Handback must wait for the actual planner to unwind") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .busy) }
        gate.release()
        do { _ = try await running.value; XCTFail("A late model response cannot survive Pause") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(owner.isOperating)
        planner.beforeReply = nil
        try await owner.resumeAfterUserControl()
        let fresh = try await owner.prepareFormInput(), result = try await owner.planForm(fresh, using: planner)
        XCTAssertEqual(fresh.interpretation.input, input.interpretation.input)
        XCTAssertEqual(result.edits.count, 1); XCTAssertEqual(planner.inputs.count, 2)
        try await owner.revalidateFormInput(fresh)
        XCTAssertEqual(fixture.server.count("/results"), 0)
    }

    func testPageValueDriftDuringPlanningRejectsTheProposalBeforeInput() async throws {
        let body = FormPlannerFixture.body + """
            <script>fetch('/signal').then(() => { document.querySelector('input').value = 'changed privately'; fetch('/changed'); });</script>
            """
        let fixture = try await FormPlannerFixture(goal: proposal(), body: body, heldSignal: true)
        defer { fixture.close() }
        let owner = fixture.owner(), planner = FormProposalFixture(content: #"{"preserve":[],"edits":[{"field":"field2","terms":[{"requirement":2,"text":"Paris"}]}]}"#)
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput()
        planner.beforeReply = {
            try await fixture.wait { fixture.server.count("/signal") == 1 }
            fixture.server.releaseHeldResponses()
            try await fixture.wait { fixture.server.count("/changed") == 1 }
        }
        do { _ = try await owner.planForm(input, using: planner); XCTFail("Another field's changed value invalidates the complete preconditions") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        XCTAssertEqual(fixture.server.count("/changed"), 1); XCTAssertEqual(fixture.server.count("/results"), 0)
    }

    func testTypedQuestionIsScopedToTheOriginalGoalAndUnavailableIsNotCompletion() async throws {
        let fixture = try await FormPlannerFixture(goal: proposal())
        defer { fixture.close() }
        let owner = fixture.owner()
        defer { owner.retire() }
        _ = try await owner.interpretGoal()
        let input = try await owner.prepareFormInput(), planner = FormProposalFixture(content: #"{"question":{"topic":"date","requirements":[3]}}"#)
        let result = try await owner.planForm(input, using: planner), question = try XCTUnwrap(result.questionRequest(for: input))
        XCTAssertEqual(question.taskID, input.interpretation.input.taskID); XCTAssertEqual(question.inputDigest, input.interpretation.input.digest)
        XCTAssertEqual(question.requirementIDs, [input.interpretation.requirements[3].id]); XCTAssertNil(try result.textContract(for: input))
        let issued = try owner.issueQuestion(topic: question.topic, requirementIDs: question.requirementIDs, controllerID: "phone", controllerSessionID: "session")
        XCTAssertEqual(issued.scope[0].source, input.interpretation.source(of: input.interpretation.requirements[3]))
        let unavailable = try ComputerUseBrowserFormProposal.decode(content: #"{"unavailable":true}"#, input: input)
        XCTAssertTrue(unavailable.isUnavailable); XCTAssertNil(try unavailable.textContract(for: input))
        XCTAssertEqual(owner.input, input.interpretation.input)
    }

    func testLocalPlannerCountsTheExactCompleteRequestAndNeverTruncatesToFit() async throws {
        let fixture = try await FormPlannerFixture(goal: proposal())
        defer { fixture.close() }
        for count in [3_008, 3_009, 0] {
            let transport = FormPlannerTransport(content: #"{"unavailable":true}"#, count: count), planner = try local(transport)
            do {
                let result = try await planner.propose(fixture.input)
                XCTAssertEqual(count, 3_008); XCTAssertTrue(result.isUnavailable)
            } catch { XCTAssertNotEqual(count, 3_008); XCTAssertEqual(error as? ComputerUseBrowserResearchFormError, .contextLimit) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, count == 3_008 ? 2 : 1)
            if requests.count == 2 { XCTAssertEqual(requests[0].httpBody, requests[1].httpBody) }
            let request = try XCTUnwrap(requests.first), body = try object(XCTUnwrap(request.httpBody))
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages[1]["content"], fixture.input.contextJSON)
            XCTAssertEqual(messages[0]["content"], ComputerUseLocalBrowserFormPlanner.instructions)
            XCTAssertEqual(request.timeoutInterval, 30); XCTAssertEqual(request.url?.host, "127.0.0.1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token-value")
            XCTAssertEqual(body["max_tokens"] as? Int, 1_024); XCTAssertEqual(body["cache_prompt"] as? Bool, false)
            XCTAssertNil(body["tools"]); XCTAssertFalse(messages[1]["content"]?.contains("private-reference") ?? true)
        }
    }

    func testLocalPlannerChecksCancellationBeforeAndAfterEachTransportBoundary() async throws {
        let fixture = try await FormPlannerFixture(goal: proposal())
        defer { fixture.close() }
        for point in ["before", "count", "completion"] {
            let transport = FormPlannerTransport(content: #"{"unavailable":true}"#, cancelAt: point), planner = try local(transport)
            let running = Task {
                if point == "before" { withUnsafeCurrentTask { $0?.cancel() } }
                return try await planner.propose(fixture.input)
            }
            do { _ = try await running.value; XCTFail("Cancellation must not publish a form proposal") }
            catch { XCTAssertTrue(error is CancellationError) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, point == "before" ? 0 : point == "count" ? 1 : 2)
        }
    }

    private func local(_ transport: FormPlannerTransport) throws -> ComputerUseLocalBrowserFormPlanner {
        try .init(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")), bearerToken: "fixture-token-value",
            modelAlias: ComputerUseNativeTextRuntimeInputs.modelAlias), transport: transport)
    }
    private func plan(_ edits: [[String: Any]], preserve: [[String: Any]] = []) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: ["edits":edits, "preserve":preserve]), as: UTF8.self) }
    private func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func row(_ source: String, role: String = "condition", field: String = "other") -> [String: Any] {
        ["turn":0, "source":source, "role":role, "field":field, "relation":"unspecified", "values":[]]
    }
    private func proposal(rows: [[String: Any]]? = nil, preserveReference: Bool = true) throws -> ComputerUseBrowserGoalProposal {
        let rows = rows ?? [row("Find flights ", role: "outcome", field: "category"), row("from Montréal e\u{301} ", field: "origin"),
            row("to Paris ", field: "destination"), row("tomorrow ", field: "date"), row("for two people. ", field: "quantity"),
            row("Use refundable economy. "), row("Do not book. ", role: "prohibition")] + (preserveReference ? [row("Leave Reference unchanged.")] : [])
        let prompt = try rows.map { try XCTUnwrap($0["source"] as? String) }.joined()
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-08T07:30:00Z"))
        let input = try ComputerUseBrowserGoalInput(taskID: "form-planning", prompt: prompt, referenceDate: date, timeZoneIdentifier: "America/Los_Angeles")
        return try decodeGoal(rows, input: input)
    }
    private func decodeGoal(_ rows: [[String: Any]], input: ComputerUseBrowserGoalInput) throws -> ComputerUseBrowserGoalProposal {
        let data = try JSONSerialization.data(withJSONObject: ["disposition":"research", "requirements":rows,
            "question":["topic":"none", "requirements":[]] as [String: Any]])
        return try .decode(content: String(decoding: data, as: UTF8.self), input: input)
    }
}

@MainActor
private final class FormPlannerFixture {
    static let body = """
        <form action='/results'>
          <label>Origin<input value='old-origin'></label><label>Destination<input value='old-destination'></label>
          <label>Departure<input type='date'></label><label>People<input type='number' min='1' max='8'></label>
          <label>Cabin<select><optgroup label='Basic'><option value='private-basic'>Economy</option></optgroup>
            <optgroup label='Refundable'><option value='private-flexible'>Economy</option></optgroup><option hidden>Hidden</option></select></label>
          <label>Reference<input value='private-reference'></label><button>Search</button>
        </form>
        """
    let goal: ComputerUseBrowserGoalProposal
    let server: OwnedBrowserHTTPFixture
    let browser: ComputerUseOwnedBrowser
    let target: ComputerUseBrowserTextTarget
    let input: ComputerUseBrowserResearchFormInput
    init(goal: ComputerUseBrowserGoalProposal, body: String? = nil, heldSignal: Bool = false) async throws {
        self.goal = goal
        server = try .init(routes: ["/form":.init(body: "<!doctype html><meta charset='utf-8'>" + (body ?? Self.body)), "/signal":.init(held: heldSignal)])
        let base = try await server.start()
        browser = .init(presentsWindow: false, mayAct: { true })
        do {
            try browser.claim(taskID: goal.input.taskID)
            let document = try await browser.navigate(taskID: goal.input.taskID, operationID: "form-open", to: base.appendingPathComponent("form"))
            target = .init(browser: browser, document: document, requiresFrontmost: false)
            let page = try await browser.observePage(document: document), fields = try await target.fields()
            input = try .init(interpretation: goal, evidence: await target.bindFields(fields, to: page))
        } catch { browser.close(); server.stop(); throw error }
    }
    func owner() -> ComputerUseBrowserResearchTask {
        .init(input: goal.input, browser: browser, goalPlanner: FormGoalFixture(goal: goal),
            resultPlanner: BrowserResearchResultFixture(), mayAct: { true })
    }
    func close() { browser.close(); server.stop() }
    func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct FormGoalFixture: ComputerUseBrowserGoalPlanning {
    let goal: ComputerUseBrowserGoalProposal
    func propose(_ input: ComputerUseBrowserGoalInput) async throws -> ComputerUseBrowserGoalProposal {
        guard goal.input == input else { throw ComputerUseBrowserGoalPlanError.invalidInput }
        return goal
    }
}
@MainActor
private final class FormProposalFixture: ComputerUseBrowserFormPlanning {
    let content: String
    var beforeReply: (@MainActor () async throws -> Void)?
    private(set) var inputs: [ComputerUseBrowserResearchFormInput] = []
    init(content: String) { self.content = content }
    func propose(_ input: ComputerUseBrowserResearchFormInput) async throws -> ComputerUseBrowserFormProposal {
        inputs.append(input)
        if let beforeReply { try await beforeReply() }
        return try .decode(content: content, input: input)
    }
}
private actor FormPlannerTransport: ComputerUseTextModelTransport {
    let content: String
    let count: Int
    let cancelAt: String?
    private(set) var requests: [URLRequest] = []
    init(content: String, count: Int = 100, cancelAt: String? = nil) { self.content = content; self.count = count; self.cancelAt = cancelAt }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int {
        requests.append(completionRequest)
        if cancelAt == "count" { withUnsafeCurrentTask { $0?.cancel() } }
        return count
    }
    func complete(request: URLRequest) async throws -> Data {
        requests.append(request)
        if cancelAt == "completion" { withUnsafeCurrentTask { $0?.cancel() } }
        return try JSONSerialization.data(withJSONObject: ["model":ComputerUseNativeTextRuntimeInputs.modelAlias,
            "choices":[["index":0, "finish_reason":"stop", "message":["role":"assistant", "content":content]]]])
    }
}

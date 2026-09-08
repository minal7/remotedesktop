import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserActionPlannerTests: XCTestCase {
    func testActionContextRetainsTheWholeGoalAndObservedFormsWithoutPrivateValuesOrTargets() async throws {
        let fixture = try await ResearchDriverFixture.make(searchForm: true)
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions), input = action.input
        let context = try object(input.contextJSON), goal = try XCTUnwrap(context["goal"] as? [String: Any])
        XCTAssertEqual(goal["request"] as? String, ResearchDriverFixture.prompt)
        XCTAssertEqual((goal["referenceUnixMilliseconds"] as? NSNumber)?.int64Value, owner.input.referenceMilliseconds)
        XCTAssertEqual(goal["timeZone"] as? String, owner.input.timeZoneIdentifier)
        XCTAssertEqual((context["requirements"] as? [[String: Any]])?.first?["source"] as? String, owner.input.prompt)
        XCTAssertEqual(context["version"] as? Int, 5)
        XCTAssertEqual(context["preservable_controls"] as? [String], input.preservableControlIDs)
        XCTAssertEqual(context["editable_forms"] as? [String], input.formIDs); XCTAssertEqual(input.formIDs.count, 1)
        XCTAssertTrue(input.queryControlIDs.isEmpty); XCTAssertNil(input.queryReceipt)
        for value in ["/filtered", "old", fixture.base.absoluteString, input.evidence.documentID, input.evidence.page.id] {
            XCTAssertFalse(input.contextJSON.contains(value))
        }
        XCTAssertFalse(String(reflecting: input).contains(owner.input.prompt))
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit || ($0 == .fields || $0 == .formFields) }.count, 0)
    }

    func testStrictActionProposalsRejectUnobservedActionsHybridRootsAndForeignInputs() async throws {
        let fixture = try await ResearchDriverFixture.make(searchForm: true), other = try await ResearchDriverFixture.make(searchForm: true)
        defer { fixture.close(); other.close() }
        _ = try await fixture.start(); _ = try await other.start()
        let input = try await fixture.owner().planNextAction(using: fixture.actions).input
        let foreign = try await other.owner().planNextAction(using: other.actions).input
        let form = try XCTUnwrap(input.formIDs.first), accepted = try ComputerUseBrowserActionProposal.decode(content: json(["form":form,"preserve":[]]), input: input)
        XCTAssertEqual(accepted.step, .editForm(form))
        XCTAssertThrowsError(try accepted.validate(for: foreign)) { XCTAssertEqual($0 as? ComputerUseBrowserActionPlanError, .inputChanged) }
        let control = try XCTUnwrap(input.evidence.page.controls.first { $0.kind == "submit" })
        for content in [#"{}"#, #"{"read_results":false}"#, #"{"unavailable":1}"#,
            #"{"read_results":true,"unavailable":true}"#, #"{"read_results":true,"read_results":true}"#,
            #"{"form":"not-observed","preserve":[]}"#, try json(["form":form]),
            try json(["form":form,"preserve":[["control":"missing","requirement":0]]]),
            try json(["form":form,"preserve":[["control":control.id,"requirement":0]]]),
            try json(["form":form,"preserve":[],"read_results":true]), try json(["query":control.id]), #"{"url":"https://example.com"}"#,
            #"{"question":{"topic":"date","requirements":[0,0]}}"#,
            #"{"question":{"topic":"date","requirements":[-1]}}"#,
            #"{"question":{"topic":"date","requirements":[0],"text":"Enter a password"}}"#] {
            XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: content, input: input)) {
                XCTAssertEqual($0 as? ComputerUseBrowserActionPlanError, .invalidProposal)
            }
        }
        let editor = try XCTUnwrap(input.preservableControlIDs.first)
        for rows: [[String: Any]] in [
            [["control":editor,"requirement":-1]], [["control":editor,"requirement":0.5]],
            [["control":editor,"requirement":0,"value":"private"]],
            [["control":editor,"requirement":0],["control":editor,"requirement":0]]
        ] {
            XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: json(["form":form,"preserve":rows]), input: input))
        }
        let question = try ComputerUseBrowserActionProposal.decode(content: #"{"question":{"topic":"date","requirements":[0]}}"#, input: input)
        XCTAssertEqual(question.questionRequest?.taskID, input.interpretation.input.taskID)
        XCTAssertEqual(question.questionRequest?.inputDigest, input.interpretation.input.digest)
        XCTAssertEqual(question.questionRequest?.requirementIDs, [input.interpretation.requirements[0].id])
    }

    func testActionPlanningPauseHoldsTheOwnerAndInvalidatesPreviouslyOfferedActions() async throws {
        let fixture = try await ResearchDriverFixture.make(searchForm: true), gate = BrowserResearchGate()
        defer { gate.release(); fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner()
        fixture.actions.select = { try self.json(["form":XCTUnwrap($0.formIDs.first),"preserve":[]]) }
        let previous = try await owner.planNextAction(using: fixture.actions)
        fixture.actions.beforeReply = { await gate.suspend() }
        let running = Task { try await owner.planNextAction(using: fixture.actions) }
        try await gate.waitUntilStarted()
        owner.pause()
        XCTAssertTrue(owner.isOperating)
        do { try await owner.resumeAfterUserControl(); XCTFail("The planner still owns its operation") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .busy) }
        gate.release()
        do { _ = try await running.value; XCTFail("A cancelled proposal cannot become an action") }
        catch { XCTAssertTrue(error is CancellationError) }
        fixture.actions.beforeReply = nil
        try await owner.resumeAfterUserControl()
        do { _ = try await owner.prepareFormInput(for: previous); XCTFail("Old action references must be invalidated") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserActionPlanError, .inputChanged) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit || ($0 == .fields || $0 == .formFields) }.count, 0)
        XCTAssertEqual(owner.input, previous.input.interpretation.input)
    }

    func testSelectedFormRestrictsEditsAndKeepsPreservationAliasesSeparate() async throws {
        let fixture = try await ResearchDriverFixture.make(additionalCardHTML:
            "<form><label>Newsletter email<input name='email' value='private-newsletter'></label><button>Subscribe</button></form>", searchForm: true,
            request: "Find concerts under USD 50. Do not buy. Leave Newsletter email unchanged.")
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner()
        fixture.actions.select = { input in
            let control = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Query" })
            let preserved = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Newsletter email" })
            return try self.json(["form":XCTUnwrap(control.form?.id),"preserve":[["control":preserved.id,"requirement":0]]])
        }
        let action = try await owner.planNextAction(using: fixture.actions), input = try await owner.prepareFormInput(for: action)
        XCTAssertEqual(input.fieldAliases.count, 2); XCTAssertEqual(input.editableFieldAliases.count, 1)
        let selected = try XCTUnwrap(input.editableFieldAliases.first)
        let foreign = try XCTUnwrap(input.fieldAliases.first { !input.editableFieldAliases.contains($0) })
        func plan(_ alias: String, preserve: [[String: Any]] = []) throws -> String {
            try json(["edits":[["field":alias, "terms":[["requirement":0,"text":"concerts"]]]], "preserve":preserve])
        }
        XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: plan(foreign), input: input))
        let accepted = try ComputerUseBrowserFormProposal.decode(content: plan(selected), input: input)
        let repeated = try ComputerUseBrowserFormProposal.decode(content: plan(selected, preserve: [["field":foreign,"requirement":0]]), input: input)
        XCTAssertEqual(accepted, repeated)
        XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: plan(selected, preserve: [["field":foreign,"requirement":0],["field":foreign,"requirement":0]]), input: input))
        let contract = try XCTUnwrap(accepted.textContract(for: input))
        XCTAssertEqual(contract.unchangedValues, [try input.field(for: foreign).editable.snapshot.targetID:"private-newsletter"])
        XCTAssertFalse(input.contextJSON.contains("private-newsletter"))
        XCTAssertEqual(input.requiredPreservation, accepted.preserved)
        XCTAssertThrowsError(try ComputerUseBrowserResearchFormInput(interpretation: input.interpretation, evidence: input.evidence, selectedFormID: input.selectedFormID))
        XCTAssertEqual(accepted.edits.map(\.field), [selected]); XCTAssertEqual(accepted.preserved.map(\.field), [foreign])
        let context = try object(input.contextJSON), bindings = try XCTUnwrap(context["field_bindings"] as? [[String: Any]])
        XCTAssertEqual(bindings.filter { $0["editable"] as? Bool == true }.count, 1)
        XCTAssertEqual(context["selected_form"] as? String, input.selectedFormID)
        XCTAssertEqual((context["required_preservation"] as? [[String: Any]])?.first?["field"] as? String, foreign)
        XCTAssertTrue(input.interpretation.input.prompt.contains("Leave Newsletter email unchanged."))
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testVerifiedFormOffersQuerySelectionAndPreservesReceiptsWhenDependentDiscoveryIsUnavailable() async throws {
        let fixture = try await ResearchDriverFixture.make(additionalCardHTML: "<form><label>Newsletter<input></label></form>", searchForm: true)
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner()
        fixture.actions.select = { input in
            let form = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Query" }?.form?.id)
            return try self.json(["form":form,"preserve":[]])
        }
        let action = try await owner.planNextAction(using: fixture.actions), input = try await owner.prepareFormInput(for: action)
        let plan = try ComputerUseBrowserFormProposal.decode(content: #"{"edits":[{"field":"field1","terms":[{"requirement":0,"text":"concerts"}]}],"preserve":[]}"#, input: input)
        let receipt = try await owner.executeForm(plan, input: input)
        let fieldsBefore = fixture.state.commands.filter { ($0 == .fields || $0 == .formFields || $0 == .extendFormFields) }.count
        fixture.actions.select = { input in
            let form = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Newsletter" }?.form?.id)
            return try self.json(["form":form,"preserve":[]])
        }
        let second = try await owner.planNextAction(using: fixture.actions)
        XCTAssertEqual(second.input.queryReceipt, receipt); XCTAssertEqual(second.input.queryControlIDs.count, 1)
        do { _ = try await owner.prepareFormInput(for: second); XCTFail("New discovery must not erase earlier input receipts") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserActionPlanError, .retainedFormRequiresExtension) }
        XCTAssertEqual(fixture.state.commands.filter { ($0 == .fields || $0 == .formFields || $0 == .extendFormFields) }.count, fieldsBefore)
        fixture.actions.select = { try self.json(["query":XCTUnwrap($0.queryControlIDs.first)]) }
        let query = try await owner.planNextAction(using: fixture.actions)
        _ = try await owner.openFormQuery(for: query)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(owner.confirmedNavigationHistory.map(\.kind), [.search, .formQuery])
    }

    func testAutomaticFormPreparationExcludesUnrelatedUnlabelledFieldsAndTheirPrivateValues() async throws {
        let outside = (0..<20).map { "<input value='private-unrelated-\($0)'>" }.joined()
        let fixture = try await ResearchDriverFixture.make(additionalCardHTML: outside, searchForm: true)
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner()
        fixture.actions.select = { input in
            let control = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Query" })
            return try self.json(["form":XCTUnwrap(control.form?.id),"preserve":[]])
        }
        let action = try await owner.planNextAction(using: fixture.actions), input = try await owner.prepareFormInput(for: action)
        XCTAssertEqual(input.fieldAliases, ["field1"]); XCTAssertEqual(input.evidence.fields.map { $0.control.label }, ["Query"])
        XCTAssertTrue(input.requiredPreservation.isEmpty); XCTAssertFalse(input.contextJSON.contains("private-unrelated"))
        XCTAssertEqual(fixture.state.commands.filter { $0 == .fields }.count, 0)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
        let proposal = try ComputerUseBrowserFormProposal.decode(content: #"{"edits":[{"field":"field1","terms":[{"requirement":0,"text":"concerts"}]}],"preserve":[]}"#, input: input)
        _ = try await owner.executeForm(proposal, input: input)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(owner.confirmedFormHistory.count, 1)
    }

    func testLocalActionPlannerCountsTheCompleteRequestAndSkipsInferenceWithoutFormChoices() async throws {
        for hasForm in [true, false] {
            let fixture = try await ResearchDriverFixture.make(searchForm: hasForm)
            defer { fixture.close() }
            _ = try await fixture.start()
            let input = try await fixture.owner().planNextAction(using: fixture.actions).input
            for count in [-1, 0, 3_008, 3_009] {
                let transport = ActionPlannerTransport(count: count), planner = try local(transport)
                do { _ = try await planner.propose(input); XCTAssertTrue(!hasForm || count == 3_008) }
                catch { XCTAssertTrue(hasForm); XCTAssertNotEqual(count, 3_008); XCTAssertEqual(error as? ComputerUseBrowserActionPlanError, .contextLimit) }
                let requests = await transport.requests
                XCTAssertEqual(requests.count, !hasForm ? 0 : count == 3_008 ? 2 : 1)
                if !requests.isEmpty {
                    let request = try XCTUnwrap(requests.first), body = try object(String(decoding: XCTUnwrap(request.httpBody), as: UTF8.self))
                    let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
                    XCTAssertEqual(messages[1]["content"], input.contextJSON); XCTAssertEqual(messages[0]["content"], ComputerUseLocalBrowserActionPlanner.instructions)
                    XCTAssertEqual(request.url?.host, "127.0.0.1"); XCTAssertEqual(request.timeoutInterval, 30)
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token-value")
                    XCTAssertEqual(body["max_tokens"] as? Int, 1_024); XCTAssertEqual(body["cache_prompt"] as? Bool, false); XCTAssertNil(body["tools"])
                    let format = try XCTUnwrap(body["response_format"] as? [String: Any])
                    let schema = try XCTUnwrap(format["json_schema"] as? [String: Any])
                    XCTAssertEqual(schema["name"] as? String, "browser_research_action_v5")
                    let root = try XCTUnwrap(schema["schema"] as? [String: Any])
                    let alternatives = try XCTUnwrap(root["oneOf"] as? [[String: Any]])
                    let form = try XCTUnwrap(alternatives.first { ($0["required"] as? [String])?.contains("form") == true })
                    XCTAssertEqual(form["required"] as? [String], ["form", "preserve"])
                    if requests.count == 2 { XCTAssertEqual(requests[0].httpBody, requests[1].httpBody) }
                }
            }
        }
    }

    func testLocalActionPlannerChecksCancellationAcrossEveryTransportBoundary() async throws {
        let fixture = try await ResearchDriverFixture.make(searchForm: true)
        defer { fixture.close() }
        _ = try await fixture.start()
        let input = try await fixture.owner().planNextAction(using: fixture.actions).input
        for point in ["before", "count", "completion"] {
            let transport = ActionPlannerTransport(cancelAt: point), planner = try local(transport)
            let running = Task {
                if point == "before" { withUnsafeCurrentTask { $0?.cancel() } }
                return try await planner.propose(input)
            }
            do { _ = try await running.value; XCTFail("Cancellation cannot publish a next action") }
            catch { XCTAssertTrue(error is CancellationError) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, point == "before" ? 0 : point == "count" ? 1 : 2)
        }
    }

    private func json(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
    private func object(_ text: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) }
    private func local(_ transport: ActionPlannerTransport) throws -> ComputerUseLocalBrowserActionPlanner {
        try .init(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")), bearerToken: "fixture-token-value",
            modelAlias: ComputerUseNativeTextRuntimeInputs.modelAlias), transport: transport)
    }
}

private actor ActionPlannerTransport: ComputerUseTextModelTransport {
    let count: Int
    let cancelAt: String?
    private(set) var requests: [URLRequest] = []
    init(count: Int = 100, cancelAt: String? = nil) { self.count = count; self.cancelAt = cancelAt }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int {
        requests.append(completionRequest)
        if cancelAt == "count" { withUnsafeCurrentTask { $0?.cancel() } }
        return count
    }
    func complete(request: URLRequest) async throws -> Data {
        requests.append(request)
        if cancelAt == "completion" { withUnsafeCurrentTask { $0?.cancel() } }
        return try JSONSerialization.data(withJSONObject: ["model":ComputerUseNativeTextRuntimeInputs.modelAlias,
            "choices":[["index":0, "finish_reason":"stop", "message":["role":"assistant", "content":#"{"read_results":true}"#]]]])
    }
}

import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserReadingScopeTests: XCTestCase {
    func testScopeUsesOfferedControlsAndOriginalRequirementsBeforeReadingValues() async throws {
        let fixture = try await ControlStateFixture(body: """
            <article><h2>Concert Alpha</h2><label>Location<input value=Paris></label><label>Notes<input value=privateNotes></label>
            <label>Email<input value=privateEmail></label><label>Account name<input value=privateAccount></label>
            <label>Card details<input autocomplete=cc-number value=privateCard></label><label>Saved account city<input readonly value=privateCity></label>
            <label>Stored card<input type=number autocomplete=cc-number value=4111111111111111></label>
            <label>Date of birth<input type=date value=1990-01-02></label>
            <label>Details<textarea>privateDetails</textarea></label></article>
            """)
        defer { fixture.close() }
        let input = try await context(fixture)
        XCTAssertEqual(input.readableControlIDs, input.evidence.page.controls.filter { ["Location", "Notes"].contains($0.label) }.map(\.id))
        XCTAssertEqual(input.readableRequirementIndices, [0, 1])
        for value in ["Paris", "privateNotes", "privateEmail", "privateAccount", "privateCard", "privateCity", "privateDetails"] {
            // Paris is in the retained request; all other values are excluded.
            if value != "Paris" { XCTAssertFalse(input.contextJSON.contains(value)) }
        }
        XCTAssertFalse(input.evidence.page.controlStateObserved)
        let action = try scope(input)
        XCTAssertEqual(action.readControls.map(\.requirementIndex), [1])
        let id = try XCTUnwrap(action.readControls.first?.controlID)
        let invalid: [[String: Any]] = [
            ["read_results":false, "read_controls":[["control":id, "requirement":1]]],
            ["read_results":true, "read_controls":[]],
            ["read_results":true, "read_controls":[["control":"c999", "requirement":1]]],
            ["read_results":true, "read_controls":[["control":id, "requirement":2]]],
            ["read_results":true, "read_controls":[["control":id, "requirement":1], ["control":id, "requirement":0]]],
            ["read_results":true, "read_controls":[["control":id, "requirement":1, "value":"invented"]]],
            ["read_results":true, "read_controls":[["control":id, "requirement":1]], "form":"f1"]]
        for value in invalid { XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: ResearchAnswerFixture.json(value), input: input)) }
        let planner = try ComputerUseLocalBrowserActionPlanner(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")), bearerToken: "fixture", modelAlias: "fixture-model"), transport: ControlStateUnusedTransport())
        let request = try planner.makeRequest(input), body = try ResearchAnswerFixture.object(XCTUnwrap(request.httpBody))
        let format = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual((format["json_schema"] as? [String: Any])?["name"] as? String, "browser_research_action_v10")
        XCTAssertEqual(try object(input.contextJSON)["version"] as? Int, 10)
        let values = try await fixture.browser.observePage(document: fixture.document, includingControlState: true)
        XCTAssertEqual(try fixture.state("Stored card", in: values.page).kind, .unavailable)
        XCTAssertEqual(try fixture.state("Date of birth", in: values.page).kind, .unavailable)
        let projection = try ComputerUseBrowserResultPageInput(page: values.page).contextJSON
        XCTAssertFalse(projection.contains("4111111111111111")); XCTAssertFalse(projection.contains("1990-01-02"))
    }

    func testNativeScopeReadsOnlySelectedWholeValuesAndCannotBeForgedOrReused() async throws {
        let value = "Paris — 東京 e\u{301}"
        let fixture = try await ControlStateFixture(body: "<article><h2>Concert Alpha</h2><label>Location<input value='\(value)'></label><label>Notes<input value=privateNotes></label></article>")
        defer { fixture.close() }
        let input = try await context(fixture), action = try scope(input)
        let reading = try await fixture.browser.observeResearchControls(for: action)
        XCTAssertEqual(reading.page.scopedControlIDs, action.readControls.map(\.controlID))
        XCTAssertEqual(try fixture.state("Location", in: reading.page).value?.utf8.map { $0 }, Array(value.utf8))
        XCTAssertEqual(try fixture.state("Notes", in: reading.page).kind, .unavailable)
        let projected = try ComputerUseBrowserResultPageInput(page: reading.page)
        XCTAssertFalse(projected.contextJSON.contains("privateNotes"))
        XCTAssertEqual(try object(projected.contextJSON)["version"] as? Int, 6)
        XCTAssertEqual(try object(projected.contextJSON)["omitted_controls"] as? Bool, true)
        try await fixture.browser.validatePageEvidence(reading)
        do { _ = try await fixture.browser.observeResearchControls(for: action); XCTFail("The consumed metadata scope cannot bind another observation") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        let page = reading.page
        for ids in [[], ["c999"], page.scopedControlIDs + page.scopedControlIDs] {
            let invalid = ComputerUseBrowserPageSnapshot(id: page.id, texts: page.texts, links: page.links, controls: page.controls,
                truncated: page.truncated, omittedEmbeddedContent: page.omittedEmbeddedContent, omittedControls: page.omittedControls,
                viewport: page.viewport, containers: page.containers, omittedStructure: page.omittedStructure,
                controlStates: page.controlStates, controlStateObserved: true, scopedControlIDs: ids)
            XCTAssertFalse(invalid.isWellFormed)
        }
        let metadata = try await fixture.browser.observePage(document: fixture.document, includingControlState: true)
        XCTAssertTrue(metadata.page.scopedControlIDs.isEmpty)
        XCTAssertEqual(try fixture.state("Location", in: metadata.page).kind, .unavailable)
    }

    func testPropertyOnlyTextChangeInvalidatesTheReadingAndRequiresANewScope() async throws {
        let fixture = try await ControlStateFixture(body: """
            <article><h2>Concert Alpha</h2><label>Location<input id=city value=Paris></label></article>
            <script>fetch('/signal').then(() => { document.getElementById('city').value='Lyon'; fetch('/changed'); });</script>
            """, heldSignal: true)
        defer { fixture.close() }
        let action = try scope(await context(fixture)), reading = try await fixture.browser.observeResearchControls(for: action)
        try await fixture.wait { fixture.server.count("/signal") == 1 }
        fixture.server.releaseHeldResponses()
        try await fixture.wait { fixture.server.count("/changed") == 1 }
        do { try await fixture.browser.validatePageEvidence(reading); XCTFail("Current text values are part of reading identity") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        let fresh = try scope(await context(fixture)), updated = try await fixture.browser.observeResearchControls(for: fresh)
        XCTAssertEqual(try fixture.state("Location", in: updated.page).value, "Lyon")
        XCTAssertEqual(fresh.input.interpretation.input, action.input.interpretation.input)
    }

    func testReplacementProtectionAndLoginChangesRejectTheOldScopeBeforeCollection() async throws {
        let mutations = [
            "const old=document.getElementById('city'); old.replaceWith(old.cloneNode(true));",
            "document.getElementById('city').autocomplete='username';",
            "document.body.insertAdjacentHTML('beforeend','<label>Password<input type=password></label>');"]
        for (index, mutation) in mutations.enumerated() {
            let fixture = try await ControlStateFixture(body: """
                <article><h2>Concert Alpha</h2><label>Location<input id=city value=Paris></label></article>
                <script>fetch('/signal').then(() => { \(mutation) fetch('/changed'); });</script>
                """, heldSignal: true)
            defer { fixture.close() }
            let action = try scope(await context(fixture))
            try await fixture.wait { fixture.server.count("/signal") == 1 }
            fixture.server.releaseHeldResponses()
            try await fixture.wait { fixture.server.count("/changed") == 1 }
            do { _ = try await fixture.browser.observeResearchControls(for: action); XCTFail("Changed control identity or protection cannot reuse read authority") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, index == 2 ? .authenticationRequired : .pageChanged) }
        }
    }

    func testDriverReadsChosenLocationScopeWithoutEditingOrTreatingItAsAResultFact() async throws {
        for selectValues in [false, true] {
            let fixture = try await ResearchAnswerFixture.make(extra: ("In Paris. ", "condition", "location"),
                controlHTML: "<label>Location<input value=Paris></label>", resultLocation: "Paris")
            defer { fixture.source.close() }
            if selectValues { fixture.source.actions.select = { input in try self.scopeJSON(input, requirement: 2) } }
            let result = try await fixture.source.start(), owner = try fixture.source.owner()
            if selectValues {
                guard case .browserResearchAnswer(let answer)? = result else { return XCTFail("Complete result evidence can include scoped current settings") }
                try owner.validateAnswer(answer)
                XCTAssertTrue(answer.message.contains("Location: Paris")); XCTAssertTrue(answer.message.contains("Control observations"))
                let reads = fixture.source.state.commands.filter { $0 == .observeResearchControls }.count
                XCTAssertGreaterThan(reads, 0); XCTAssertEqual(reads, fixture.source.actions.inputs.count)
                let reading = try await owner.revalidateCandidates()
                XCTAssertEqual(reading.candidates[0].fields.first { $0.kind == .location }?.sourceKind, .pageText)
                XCTAssertEqual(reading.candidates[0].controls.first?.state?.kind, .text)
            } else {
                guard case .userInterventionRequired? = result else { return XCTFail("Unobserved control context cannot be silently assumed irrelevant") }
                XCTAssertFalse(fixture.source.state.commands.contains(.observeResearchControls))
            }
            XCTAssertFalse(fixture.source.state.commands.contains(.edit))
            XCTAssertEqual(owner.input.prompt, fixture.source.request)
        }
    }

    func testPauseAndHandbackCannotReviveAnEarlierReadScope() async throws {
        let fixture = try await ResearchAnswerFixture.make(extra: ("In Paris. ", "condition", "location"),
            controlHTML: "<label>Location<input value=Paris></label>", resultLocation: "Paris")
        defer { fixture.source.close() }
        _ = try await fixture.source.start()
        let owner = try fixture.source.owner(), original = owner.input
        fixture.source.actions.select = { input in try self.scopeJSON(input, requirement: 2) }
        let old = try await owner.planNextAction(using: fixture.source.actions)
        owner.pause()
        do { _ = try await owner.readCandidates(for: old); XCTFail("Pause closes the pending read scope") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .paused) }
        try await owner.resumeAfterUserControl()
        do { _ = try await owner.readCandidates(for: old); XCTFail("Handback requires a newly selected scope") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserActionPlanError, .inputChanged) }
        XCTAssertFalse(fixture.source.state.commands.contains(.observeResearchControls))
        let fresh = try await owner.planNextAction(using: fixture.source.actions)
        let reading = try await owner.readCandidates(for: fresh)
        XCTAssertEqual(reading.candidates[0].controls.first?.state?.value, "Paris")
        XCTAssertEqual(owner.input, original)
    }

    private func context(_ fixture: ControlStateFixture) async throws -> ComputerUseBrowserActionInput {
        let page = try await fixture.browser.observePage(document: fixture.document)
        let goal = try ComputerUseBrowserGoalInput(taskID: fixture.document.taskID, prompt: "Find concerts. In Paris. Do not buy.",
            referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
        let rows: [[String: Any]] = [
            ["turn":0, "source":"Find concerts. ", "role":"outcome", "field":"category", "relation":"unspecified", "values":[]],
            ["turn":0, "source":"In Paris. ", "role":"condition", "field":"location", "relation":"unspecified", "values":[]],
            ["turn":0, "source":"Do not buy.", "role":"prohibition", "field":"other", "relation":"unspecified", "values":[]]]
        let interpretation = try ComputerUseBrowserGoalProposal.decode(content: ResearchAnswerFixture.json([
            "disposition":"research", "requirements":rows, "question":["topic":"none", "requirements":[]]]), input: goal)
        return try .init(interpretation: interpretation, evidence: page, navigationHistory: [], formHistory: [], latestForm: nil, changedFormTargetIDs: [])
    }
    private func scopeJSON(_ input: ComputerUseBrowserActionInput, requirement: Int = 1) throws -> String {
        let id = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Location" }?.id)
        return try ResearchAnswerFixture.json(["read_results":true, "read_controls":[["control":id, "requirement":requirement]]])
    }
    private func scope(_ input: ComputerUseBrowserActionInput) throws -> ComputerUseBrowserActionProposal {
        try .decode(content: scopeJSON(input), input: input)
    }
    private func object(_ string: String) throws -> [String: Any] { try ResearchAnswerFixture.object(Data(string.utf8)) }
}

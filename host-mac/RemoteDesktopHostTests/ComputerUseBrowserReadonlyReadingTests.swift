import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserReadonlyReadingTests: XCTestCase {
    func testScopeOffersNoneditableCriteriaWithoutCollectingTheirValuesGenerally() async throws {
        let fixture = try await ControlStateFixture(body: criteria)
        defer { fixture.close() }
        let input = try await input(fixture)
        XCTAssertEqual(input.readableControlIDs.count, 11)
        XCTAssertTrue(input.formIDs.isEmpty)
        XCTAssertEqual(input.readableRequirementIndices, [0, 1])
        XCTAssertFalse(input.contextJSON.contains("2026-09-20")); XCTAssertFalse(input.contextJSON.contains("Paris"))
        let general = try await fixture.browser.observePage(document: fixture.document, includingControlState: true)
        XCTAssertTrue(general.page.scopedControlIDs.isEmpty)
        XCTAssertTrue(general.page.controlStates.allSatisfy { $0.kind == .unavailable })
        XCTAssertTrue(try ComputerUseBrowserResultPageInput(page: general.page).controlIDs.isEmpty)
    }

    func testScopedNativeValuesKeepInteractivityFlagsAndRequireTheExactScope() async throws {
        let fixture = try await ControlStateFixture(body: criteria)
        defer { fixture.close() }
        let action = try await scope(fixture), reading = try await fixture.browser.observeResearchControls(for: action)
        XCTAssertEqual(reading.page.scopedControlIDs, action.readControls.map(\.controlID))
        let expected = ["Origin":"Paris", "Destination":"London", "Departure":"2026-09-20", "Local departure":"2026-09-20T10:30",
            "Month":"2026-09", "Week":"2026-W38", "Time":"10:30", "Tickets":"2", "Ticket type":"Public: General admission",
            "Direct only":"Checked", "Standard fare":"Checked"]
        for control in reading.page.controls {
            let state = try XCTUnwrap(reading.page.controlStates.first { $0.controlID == control.id })
            XCTAssertTrue(control.disabled || control.readOnly)
            XCTAssertEqual(state.fieldSource(for: control), expected[control.label], control.label)
            XCTAssertTrue(state.requiresScope(for: control)); XCTAssertTrue(state.isValid(for: control))
            XCTAssertTrue(state.renderedObservation(for: control).contains("Disabled: \(control.disabled); read only: \(control.readOnly)"))
        }
        XCTAssertEqual(reading.page.controls, action.input.evidence.page.controls)
        let page = reading.page
        for ids in [[], Array(page.scopedControlIDs.dropFirst()), page.scopedControlIDs + page.scopedControlIDs, ["c999"]] {
            let invalid = ComputerUseBrowserPageSnapshot(id: page.id, texts: page.texts, links: page.links, controls: page.controls,
                truncated: page.truncated, omittedEmbeddedContent: page.omittedEmbeddedContent, omittedControls: page.omittedControls,
                viewport: page.viewport, containers: page.containers, omittedStructure: page.omittedStructure,
                controlStates: page.controlStates, controlStateObserved: true, scopedControlIDs: ids)
            XCTAssertFalse(invalid.isWellFormed)
        }
        let context = try object(ComputerUseBrowserResultPageInput(page: page).contextJSON)
        XCTAssertEqual(context["version"] as? Int, 6)
        XCTAssertFalse(try ResearchAnswerFixture.json(context).contains("private-option-code"))
        try await fixture.browser.validatePageEvidence(reading)
        let general = try await fixture.browser.observePage(document: fixture.document, includingControlState: true)
        XCTAssertTrue(general.page.scopedControlIDs.isEmpty)
        XCTAssertTrue(general.page.controlStates.allSatisfy { $0.kind == .unavailable })
    }

    func testProtectedNoneditableFieldsRemainOutsideBothProposedAndNativeScopes() async throws {
        let fixture = try await ControlStateFixture(body: """
            <article><h2>Concert Alpha</h2><label>Origin<input readonly value=Paris></label>
            <label>Account name<input readonly value=privateAccount></label>
            <label>Card details<input type=number readonly autocomplete=cc-number value=4111111111111111></label>
            <label>Birth date<input type=date disabled value=1990-01-02></label>
            <label>Billing country<select disabled><option selected value=privateCode>Example</option></select></label></article>
            """)
        defer { fixture.close() }
        let input = try await input(fixture)
        XCTAssertEqual(input.readableControlIDs.count, 1)
        for control in input.evidence.page.controls where control.label != "Origin" {
            XCTAssertFalse(control.researchReadable)
            XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: scopeJSON([control.id]), input: input))
            let reply = try await fixture.browser.callDOM(.observeResearchControls,
                arguments: ["documentID":input.evidence.documentID, "snapshotID":input.evidence.page.id, "readControlIDs":[control.id]], document: fixture.document)
            XCTAssertEqual(reply.status, "unsupported"); XCTAssertNil(reply.page); XCTAssertNil(reply.fields)
        }
        let action = try ComputerUseBrowserActionProposal.decode(content: scopeJSON(input.readableControlIDs), input: input)
        let reading = try await fixture.browser.observeResearchControls(for: action)
        let context = try ComputerUseBrowserResultPageInput(page: reading.page).contextJSON
        for value in ["privateAccount", "4111111111111111", "1990-01-02", "privateCode"] { XCTAssertFalse(context.contains(value)) }
        XCTAssertEqual(try fixture.state("Origin", in: reading.page).value, "Paris")
        for state in reading.page.controlStates.dropFirst() { XCTAssertEqual(state.kind, .unavailable) }
    }

    func testPropertyOnlyChangesInvalidateScopedNoneditableStates() async throws {
        let cases = [
            ("<input id=target readonly value=Paris>", "document.getElementById('target').value='Lyon';", "Lyon"),
            ("<input id=target type=number readonly value=2>", "document.getElementById('target').value='3';", "3"),
            ("<select id=target disabled><option>A</option><option selected>B</option></select>", "document.getElementById('target').selectedIndex=0;", "A"),
            ("<input id=target type=checkbox disabled checked>", "document.getElementById('target').checked=false;", "Not checked")]
        for (control, mutation, expected) in cases {
            let fixture = try await ControlStateFixture(body: """
                <article><h2>Concert Alpha</h2><label>Criterion\(control)</label></article>
                <script>fetch('/signal').then(() => { \(mutation) fetch('/changed'); });</script>
                """, heldSignal: true)
            defer { fixture.close() }
            let action = try await scope(fixture), reading = try await fixture.browser.observeResearchControls(for: action)
            try await fixture.wait { fixture.server.count("/signal") == 1 }
            fixture.server.releaseHeldResponses(); try await fixture.wait { fixture.server.count("/changed") == 1 }
            do { try await fixture.browser.validatePageEvidence(reading); XCTFail("A property-only change invalidates the exact observation") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            let fresh = try await scope(fixture), updated = try await fixture.browser.observeResearchControls(for: fresh)
            let control = try XCTUnwrap(updated.page.controls.first), state = try XCTUnwrap(updated.page.controlStates.first)
            XCTAssertEqual(state.fieldSource(for: control), expected)
            XCTAssertEqual(action.input.interpretation.input, fresh.input.interpretation.input)
        }
    }

    func testChangedReadOnlyFlagsInvalidateEarlierScopeAndRefreshOrdinaryReading() async throws {
        let fixture = try await ControlStateFixture(body: """
            <article><h2>Concert Alpha</h2><label>Departure<input id=target type=date readonly value=2026-09-20></label></article>
            <script>fetch('/signal').then(() => { document.getElementById('target').readOnly=false; fetch('/changed'); });</script>
            """, heldSignal: true)
        defer { fixture.close() }
        let action = try await scope(fixture), reading = try await fixture.browser.observeResearchControls(for: action)
        try await fixture.wait { fixture.server.count("/signal") == 1 }
        fixture.server.releaseHeldResponses(); try await fixture.wait { fixture.server.count("/changed") == 1 }
        do { try await fixture.browser.validatePageEvidence(reading); XCTFail("Interactivity flags are retained evidence") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        let current = try await input(fixture)
        XCTAssertEqual(current.readableControlIDs, current.evidence.page.controls.map(\.id))
        let general = try await fixture.browser.observePage(document: fixture.document, includingControlState: true)
        XCTAssertTrue(general.page.scopedControlIDs.isEmpty)
        XCTAssertFalse(try XCTUnwrap(general.page.controls.first).readOnly)
        XCTAssertEqual(try fixture.state("Departure", in: general.page).value, "2026-09-20")
    }

    private var criteria: String {
        """
        <article><h2>Concert Alpha</h2>
        <label>Origin<input readonly value=Paris></label><label>Destination<input type=search disabled value=London></label>
        <label>Departure<input type=date readonly value=2026-09-20></label><label>Local departure<input type=datetime-local readonly value=2026-09-20T10:30></label>
        <label>Month<input type=month readonly value=2026-09></label><label>Week<input type=week readonly value=2026-W38></label>
        <label>Time<input type=time readonly value=10:30></label><label>Tickets<input type=number disabled value=2></label>
        <label>Ticket type<select disabled><optgroup label=Public><option selected value=private-option-code>General admission</option></optgroup></select></label>
        <label>Direct only<input type=checkbox disabled checked></label><label>Standard fare<input type=radio disabled checked></label>
        </article>
        """
    }
    private func input(_ fixture: ControlStateFixture) async throws -> ComputerUseBrowserActionInput {
        let page = try await fixture.browser.observePage(document: fixture.document)
        let goal = try ComputerUseBrowserGoalInput(taskID: fixture.document.taskID, prompt: "Find concerts. Keep displayed search criteria. Do not buy.",
            referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "UTC")
        let rows: [[String: Any]] = [
            ["turn":0, "source":"Find concerts. ", "role":"outcome", "field":"category", "relation":"unspecified", "values":[]],
            ["turn":0, "source":"Keep displayed search criteria. ", "role":"condition", "field":"other", "relation":"unspecified", "values":[]],
            ["turn":0, "source":"Do not buy.", "role":"prohibition", "field":"other", "relation":"unspecified", "values":[]]]
        let interpretation = try ComputerUseBrowserGoalProposal.decode(content: ResearchAnswerFixture.json([
            "disposition":"research", "requirements":rows, "question":["topic":"none", "requirements":[]]]), input: goal)
        return try .init(interpretation: interpretation, evidence: page, navigationHistory: [], formHistory: [], latestForm: nil, changedFormTargetIDs: [])
    }
    private func scope(_ fixture: ControlStateFixture) async throws -> ComputerUseBrowserActionProposal {
        let input = try await input(fixture)
        return try .decode(content: scopeJSON(input.readableControlIDs), input: input)
    }
    private func scopeJSON(_ ids: [String], requirement: Int = 1) throws -> String {
        try ResearchAnswerFixture.json(["read_results":true, "read_controls":ids.map { ["control":$0, "requirement":requirement] as [String: Any] }])
    }
    private func object(_ value: String) throws -> [String: Any] { try ResearchAnswerFixture.object(Data(value.utf8)) }
}

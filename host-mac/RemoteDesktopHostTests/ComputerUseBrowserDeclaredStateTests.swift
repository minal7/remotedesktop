import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserDeclaredStateTests: XCTestCase {
    func testCustomAndButtonBackedTogglesAreMetadataUntilExplicitlyScoped() async throws {
        let fixture = try await ControlStateFixture(body: widgets)
        defer { fixture.close() }
        let input = try await input(fixture)
        XCTAssertEqual(input.readableControlIDs.count, 6)
        XCTAssertTrue(input.formIDs.isEmpty); XCTAssertTrue(input.queryControlIDs.isEmpty)
        XCTAssertTrue(input.evidence.page.controls.allSatisfy { $0.kind.hasPrefix("aria-") && $0.form == nil })
        XCTAssertFalse(input.contextJSON.contains("Five tickets"))
        let general = try await fixture.browser.observePage(document: fixture.document, includingControlState: true)
        XCTAssertFalse(general.page.omittedControls)
        XCTAssertTrue(general.page.controlStates.allSatisfy { $0.kind == .unavailable })
        XCTAssertTrue(try ComputerUseBrowserResultPageInput(page: general.page).controlIDs.isEmpty)
    }

    func testScopedDeclarationsKeepCompleteAttributesAndExplicitProvenance() async throws {
        let fixture = try await ControlStateFixture(body: widgets)
        defer { fixture.close() }
        let action = try await scope(fixture), reading = try await fixture.browser.observeResearchControls(for: action)
        XCTAssertEqual(reading.page.scopedControlIDs, action.readControls.map(\.controlID))
        XCTAssertTrue(reading.page.controlStates.allSatisfy { $0.kind == .declared })
        for control in reading.page.controls {
            let state = try fixture.state(control.label, in: reading.page)
            XCTAssertTrue(state.requiresScope(for: control)); XCTAssertTrue(state.isValid(for: control))
            XCTAssertEqual(state.plannerContext["provenance"] as? String, "websiteDeclaredARIA")
            XCTAssertNotNil(state.plannerContext["declared_attributes"])
            XCTAssertNil(state.plannerContext["value"])
            XCTAssertTrue(state.renderedObservation(for: control).contains("Website-declared accessibility state"))
        }
        let range = try fixture.state("Ticket quantity", in: reading.page)
        let attributes = try object(XCTUnwrap(range.value))
        XCTAssertEqual(attributes as NSDictionary, ["aria-valuenow":"5", "aria-valuemin":"1", "aria-valuemax":"10", "aria-valuetext":"Five tickets"] as NSDictionary)
        let mixedControl = try XCTUnwrap(reading.page.controls.first { $0.label == "Seat groups" })
        XCTAssertNil(try fixture.state("Seat groups", in: reading.page).fieldSource(for: mixedControl))
        let page = reading.page
        let unscoped = ComputerUseBrowserPageSnapshot(id: page.id, texts: page.texts, links: page.links, controls: page.controls,
            truncated: page.truncated, omittedEmbeddedContent: page.omittedEmbeddedContent, omittedControls: page.omittedControls,
            viewport: page.viewport, containers: page.containers, omittedStructure: page.omittedStructure,
            controlStates: page.controlStates, controlStateObserved: true)
        XCTAssertFalse(unscoped.isWellFormed)
        let projected = try ComputerUseBrowserResultPageInput(page: page)
        XCTAssertEqual(try object(projected.contextJSON)["version"] as? Int, 7)
        try await fixture.browser.validatePageEvidence(reading)
    }

    func testInvalidDeclarationsStayUnavailableWithoutInventingDefaultsOrRepairs() async throws {
        let fixture = try await ControlStateFixture(body: """
            <style>[role]{display:block;min-height:24px}</style><article><h2>Concert Alpha</h2>
            <div role=checkbox aria-label=Missing></div><div role=switch aria-label=Mixed aria-checked=mixed></div>
            <div role=radio aria-label=Invalid aria-checked=yes></div><div role=slider aria-label=NoValue aria-valuetext=Five></div>
            <div role=slider aria-label=Nonfinite aria-valuenow=NaN></div><div role=spinbutton aria-label=Outside aria-valuenow=3 aria-valuemin=5></div>
            <button aria-label=Toggle aria-pressed=undefined>Toggle</button></article>
            """)
        defer { fixture.close() }
        let action = try await scope(fixture), reading = try await fixture.browser.observeResearchControls(for: action)
        XCTAssertEqual(reading.page.controls.count, 7)
        XCTAssertTrue(reading.page.controlStates.allSatisfy { $0.kind == .unavailable })
        let page = try ComputerUseBrowserResultPageInput(page: reading.page)
        XCTAssertTrue(page.controlIDs.isEmpty); XCTAssertEqual(page.unobservedControlIDs.count, 7)
        let bad = [#"{"aria-checked":"true","aria-checked":"false"}"#, #"{"aria-checked":"true","extra":"value"}"#,
            #"{"aria-checked":true}"#, #"{"aria-valuenow":"2","aria-valuemax":"1"}"#]
        for value in bad { XCTAssertNil(ComputerUseBrowserDeclaredState.attributes(value, kind: value.contains("valuenow") ? "aria-slider" : "aria-checkbox")) }
    }

    func testProtectedAndUnsupportedCustomControlsCannotBecomeReadableNativeActions() async throws {
        let fixture = try await ControlStateFixture(body: """
            <style>[role]{display:block;min-height:24px}</style><article><h2>Concert Alpha</h2>
            <div role=slider aria-label='Account number' aria-valuenow=12345678></div>
            <div role=slider aria-label='Saved count' name='account-number' aria-valuenow=87654321></div>
            <button role=combobox aria-label=Location>Paris</button><div role=listbox aria-label=Locations>Paris</div>
            <div role=spinbutton contenteditable=true aria-label=Quantity aria-valuenow=5>Five</div>
            <div role=heading aria-level=2>Details</div></article>
            """)
        defer { fixture.close() }
        let input = try await input(fixture)
        XCTAssertTrue(input.evidence.page.omittedControls)
        XCTAssertEqual(input.evidence.page.controls.map(\.kind), ["aria-slider", "aria-slider"])
        XCTAssertTrue(input.readableControlIDs.isEmpty); XCTAssertTrue(input.formIDs.isEmpty)
        XCTAssertFalse(input.contextJSON.contains("12345678"))
        XCTAssertFalse(input.contextJSON.contains("87654321"))
        for control in input.evidence.page.controls {
            let reply = try await fixture.browser.callDOM(.observeResearchControls, arguments: ["documentID":input.evidence.documentID,
                "snapshotID":input.evidence.page.id, "readControlIDs":[control.id]], document: fixture.document)
            XCTAssertEqual(reply.status, "unsupported"); XCTAssertNil(reply.page)
        }
        let structural = try await ControlStateFixture(body: "<div role=heading aria-level=2>Concert Alpha</div>")
        defer { structural.close() }
        let structuralPage = try await structural.browser.observePage(document: structural.document)
        XCTAssertFalse(structuralPage.page.omittedControls)
    }

    func testAttributeRelationshipAndObjectChangesInvalidateDeclaredReadings() async throws {
        let mutations = [
            "document.getElementById('target').setAttribute('aria-checked','false');",
            "document.getElementById('target').setAttribute('aria-controls','other');",
            "const old=document.getElementById('target'); old.replaceWith(old.cloneNode(true));",
            "document.body.insertAdjacentHTML('beforeend','<label>Password<input type=password></label>');"]
        for (index, mutation) in mutations.enumerated() {
            let fixture = try await ControlStateFixture(body: """
                <article><h2>Concert Alpha</h2><button id=target role=checkbox aria-label='Direct only' aria-checked=true>Direct only</button></article>
                <script>fetch('/signal').then(() => { \(mutation) fetch('/changed'); });</script>
                """, heldSignal: true)
            defer { fixture.close() }
            let action = try await scope(fixture), reading = try await fixture.browser.observeResearchControls(for: action)
            try await fixture.wait { fixture.server.count("/signal") == 1 }
            fixture.server.releaseHeldResponses(); try await fixture.wait { fixture.server.count("/changed") == 1 }
            do { try await fixture.browser.validatePageEvidence(reading); XCTFail("Old declarations do not survive changed page evidence") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, index == 3 ? .authenticationRequired : .pageChanged) }
        }
    }

    func testDriverRetainsWebsiteDeclaredStateBesideIndependentResultFactsWithoutClicking() async throws {
        let fixture = try await ResearchAnswerFixture.make(controlHTML: "<form action='/filtered'><button aria-label='Show details' aria-pressed=true>Show details</button></form>")
        defer { fixture.source.close() }
        fixture.source.actions.select = { input in try self.scopeJSON(input.readableControlIDs, requirement: 0) }
        guard case .browserResearchAnswer(let answer)? = try await fixture.source.start() else { return XCTFail("Independent result facts can retain a declared setting as context") }
        let owner = try fixture.source.owner(), reading = try await owner.revalidateCandidates()
        try owner.validateAnswer(answer)
        XCTAssertTrue(answer.message.contains("Website-declared accessibility state")); XCTAssertTrue(answer.message.contains("Control observations"))
        let field = try XCTUnwrap(reading.candidates.first?.fields.last)
        XCTAssertEqual(field.sourceKind, .controlState); XCTAssertFalse(field.allowsResultSupport)
        XCTAssertEqual(reading.candidates.first?.controls.first?.state?.kind, .declared)
        XCTAssertTrue(fixture.source.actions.inputs.allSatisfy { $0.formIDs.isEmpty && $0.queryControlIDs.isEmpty })
        XCTAssertFalse(fixture.source.state.commands.contains(.edit)); XCTAssertFalse(fixture.source.state.commands.contains(.prepareFormQuery))
        let old = try await owner.planNextAction(using: fixture.source.actions)
        owner.pause(); try await owner.resumeAfterUserControl()
        do { _ = try await owner.readCandidates(for: old); XCTFail("Handback requires a fresh declared-state scope") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserActionPlanError, .inputChanged) }
        XCTAssertEqual(owner.input.prompt, fixture.source.request)
    }

    private var widgets: String {
        """
        <style>[role]{display:block;min-height:24px}</style><article><h2>Concert Alpha</h2>
        <form action='/filtered'><button role=checkbox aria-label='Direct only' aria-checked=true>Direct only</button>
        <button aria-label='Show details' aria-pressed=true>Show details</button></form>
        <div role=radio aria-label='Standard fare' aria-checked=false></div><div role=switch aria-label='Accessible seating' aria-checked=true aria-disabled=true></div>
        <div role=checkbox aria-label='Seat groups' aria-checked=mixed></div>
        <div role=slider aria-label='Ticket quantity' aria-valuenow=5 aria-valuemin=1 aria-valuemax=10 aria-valuetext='Five tickets'></div></article>
        """
    }
    private func input(_ fixture: ControlStateFixture) async throws -> ComputerUseBrowserActionInput {
        let page = try await fixture.browser.observePage(document: fixture.document)
        let goal = try ComputerUseBrowserGoalInput(taskID: fixture.document.taskID, prompt: "Find concerts. Keep displayed criteria. Do not buy.",
            referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "UTC")
        let rows: [[String: Any]] = [
            ["turn":0, "source":"Find concerts. ", "role":"outcome", "field":"category", "relation":"unspecified", "values":[]],
            ["turn":0, "source":"Keep displayed criteria. ", "role":"condition", "field":"other", "relation":"unspecified", "values":[]],
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

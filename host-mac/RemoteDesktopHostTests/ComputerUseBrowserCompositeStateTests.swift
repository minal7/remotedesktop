import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserCompositeStateTests: XCTestCase {
    func testNativeComboboxKeepsEditMetadataButScopesInputAndOptionStateTogether() async throws {
        let fixture = try await ControlStateFixture(body: nativeCombo)
        defer { fixture.close() }
        let input = try await input(fixture), control = try XCTUnwrap(input.evidence.page.controls.first)
        XCTAssertEqual(control.kind, "text"); XCTAssertEqual(control.compositeRole, "combobox")
        XCTAssertEqual(input.formIDs.count, 1); XCTAssertEqual(input.readableControlIDs, [control.id])
        for value in ["Paris typed", "Charles de Gaulle", "Orly"] { XCTAssertFalse(input.contextJSON.contains(value)) }
        let general = try await fixture.browser.observePage(document: fixture.document, includingControlState: true)
        XCTAssertEqual(general.page.controlStates.first?.kind, .unavailable)
        let action = try await scope(fixture), reading = try await fixture.browser.observeResearchControls(for: action)
        let state = try fixture.state("Destination", in: reading.page), value = try object(XCTUnwrap(state.value))
        XCTAssertEqual(state.kind, .composite); XCTAssertEqual(value["input_value"] as? String, "Paris typed")
        XCTAssertTrue(value["display_text"] is NSNull); XCTAssertEqual(value["list_label"] as? String, "Airports")
        XCTAssertEqual(value["list_hidden"] as? Bool, true)
        let options = try XCTUnwrap(value["options"] as? [[String: Any]])
        XCTAssertEqual(options.map { $0["selected"] as? String }, ["true", "false"])
        XCTAssertEqual(value["active_option"] as? String, options[1]["id"] as? String)
        XCTAssertNotEqual(value["active_option"] as? String, options[0]["id"] as? String)
        XCTAssertEqual(state.plannerContext["input_value_provenance"] as? String, "nativeInputProperty")
        XCTAssertNotNil(state.plannerContext["composite_observation"]); XCTAssertNil(state.plannerContext["value"])
        let scalarOnly = ComputerUseBrowserControlState(controlID: control.id, kind: .text, value: "Paris typed", selectedOptionIDs: nil, checked: nil, indeterminate: nil)
        XCTAssertFalse(scalarOnly.isValid(for: control))
        XCTAssertEqual(try object(ComputerUseBrowserResultPageInput(page: reading.page).contextJSON)["version"] as? Int, 8)
        try await fixture.browser.validatePageEvidence(reading)
    }

    func testGroupedListboxRetainsWholeOptionsAndMissingFlagsWithoutResultText() async throws {
        let fixture = try await ControlStateFixture(body: """
            <article><h2>Concert Alpha</h2><div role=listbox aria-label='Ticket choices' aria-multiselectable=true>
            <div role=group aria-label=Weekend><div role=option aria-selected=true aria-checked=mixed aria-posinset=1 aria-setsize=2>Two tickets USD 80 total</div></div>
            <div role=group aria-label=Weekday aria-disabled=true><div role=option aria-posinset=2 aria-setsize=2>One ticket USD 45 plus fees</div></div>
            </div></article>
            """)
        defer { fixture.close() }
        let input = try await input(fixture)
        XCTAssertEqual(input.readableControlIDs.count, 1); XCTAssertTrue(input.formIDs.isEmpty)
        XCTAssertFalse(input.evidence.page.omittedControls)
        XCTAssertFalse(input.evidence.page.texts.contains { $0.text.contains("USD") })
        let action = try await scope(fixture), reading = try await fixture.browser.observeResearchControls(for: action)
        let control = try XCTUnwrap(reading.page.controls.first), state = try fixture.state("Ticket choices", in: reading.page)
        let value = try object(XCTUnwrap(state.value)), options = try XCTUnwrap(value["options"] as? [[String: Any]])
        XCTAssertEqual(options[0]["label"] as? String, "Two tickets USD 80 total")
        XCTAssertEqual(options[0]["checked"] as? String, "mixed"); XCTAssertTrue(options[1]["selected"] is NSNull)
        XCTAssertEqual(options[1]["disabled"] as? Bool, true)
        XCTAssertEqual((options[1]["groups"] as? [[String: Any]])?.first?["label"] as? String, "Weekday")
        XCTAssertEqual(state.fieldSource(for: control), state.value)
        XCTAssertTrue(state.renderedObservation(for: control).contains("Focus is not selection"))
        let unscoped = ComputerUseBrowserPageSnapshot(id: reading.page.id, texts: reading.page.texts, links: reading.page.links,
            controls: reading.page.controls, truncated: reading.page.truncated, omittedEmbeddedContent: reading.page.omittedEmbeddedContent,
            omittedControls: reading.page.omittedControls, viewport: reading.page.viewport, containers: reading.page.containers,
            omittedStructure: reading.page.omittedStructure, controlStates: reading.page.controlStates, controlStateObserved: true)
        XCTAssertFalse(unscoped.isWellFormed)
    }

    func testCustomClosedDropdownReadsOwnedOptionsWithoutOpeningOrSelecting() async throws {
        let caption = "General admission" + String(repeating: " with venue conditions", count: 15)
        let fixture = try await ControlStateFixture(body: """
            <article><h2>Concert Alpha</h2><form action='/filtered'>
            <button role=combobox aria-label='Ticket type' aria-expanded=false aria-controls=types>\(caption)<span style='display:none'>private-hidden-caption</span></button></form>
            <div id=types role=listbox aria-label='Ticket types' hidden><div role=option aria-selected=true>General admission</div>
            <div role=option aria-selected=false>Reserved seating</div></div></article>
            """)
        defer { fixture.close() }
        let action = try await scope(fixture)
        XCTAssertTrue(action.input.formIDs.isEmpty); XCTAssertTrue(action.input.queryControlIDs.isEmpty)
        let reading = try await fixture.browser.observeResearchControls(for: action)
        let state = try fixture.state("Ticket type", in: reading.page), value = try object(XCTUnwrap(state.value))
        XCTAssertEqual(value["display_text"] as? String, caption); XCTAssertTrue(value["input_value"] is NSNull)
        XCTAssertFalse(try XCTUnwrap(state.value).contains("private-hidden-caption"))
        XCTAssertEqual((value["attributes"] as? [String: String])?["aria-expanded"], "false")
        XCTAssertTrue((value["options"] as? [[String: Any]])?.allSatisfy { $0["hidden"] as? Bool == true } == true)
        XCTAssertNil(state.plannerContext["input_value_provenance"])
        XCTAssertEqual(reading.page.controls.first?.kind, "aria-combobox"); XCTAssertFalse(reading.page.omittedControls)
        try await fixture.browser.validatePageEvidence(reading)
    }

    func testExternalOwnedGroupsKeepLogicalContextAndNativeObjectIdentity() async throws {
        let fixture = try await ControlStateFixture(body: """
            <article><h2>Concert Alpha</h2><div role=group id=group aria-label=Evening>
            <div role=option aria-selected=true>Two tickets</div></div>
            <div role=listbox aria-label=Tickets aria-disabled=true aria-owns=group style='min-height:24px'></div></article>
            """)
        defer { fixture.close() }
        let action = try await scope(fixture)
        XCTAssertTrue(action.input.evidence.page.omittedControls)
        let reading = try await fixture.browser.observeResearchControls(for: action)
        XCTAssertFalse(reading.page.omittedControls)
        let value = try object(XCTUnwrap(fixture.state("Tickets", in: reading.page).value))
        let option = try XCTUnwrap((value["options"] as? [[String: Any]])?.first)
        XCTAssertEqual((option["groups"] as? [[String: Any]])?.first?["label"] as? String, "Evening")
        XCTAssertEqual(option["disabled"] as? Bool, true)
        try await fixture.browser.validatePageEvidence(reading)
    }

    func testAmbiguousIncompleteProtectedAndVirtualizedGraphsRemainUnresolved() async throws {
        let fixtures = [
            "<button role=combobox aria-label=Destination aria-expanded=false aria-controls=missing>Paris</button>",
            "<button role=combobox aria-label=Destination aria-expanded=true aria-controls=list>Paris</button><div id=list role=listbox></div><div id=list role=listbox></div>",
            "<div role=listbox aria-label=Tickets aria-owns=cycle id=cycle style='min-height:24px'></div>",
            "<div role=listbox aria-label=Tickets><div role=option aria-selected=true aria-setsize=100 aria-posinset=1>Two tickets</div></div>",
            "<div role=listbox aria-label=Tickets aria-activedescendant=other><div role=option aria-selected=true>Two tickets</div></div><span id=other>Other</span>",
            "<div role=listbox aria-label=Tickets><div role=option aria-selected=true>A</div><div role=option aria-selected=true>B</div></div>",
            "<div role=listbox aria-label=Tickets aria-owns=shared style='min-height:24px'></div><div role=listbox aria-label=Seats aria-owns=shared style='min-height:24px'></div><div id=shared role=option aria-selected=true>Two tickets</div>",
            "<div role=listbox aria-label=Locations><div role=group aria-label='Account addresses'><div role=option aria-selected=true>Private address</div></div></div>",
            "<button role=combobox aria-label=Destination aria-expanded=true aria-controls=list>Paris</button><div id=list role=listbox aria-label='Account addresses'><div role=option aria-selected=true>Private address</div></div>"
        ]
        for html in fixtures {
            let fixture = try await ControlStateFixture(body: "<article><h2>Concert Alpha</h2>" + html + "</article>")
            defer { fixture.close() }
            let action = try await scope(fixture), reading = try await fixture.browser.observeResearchControls(for: action)
            XCTAssertTrue(reading.page.omittedControls)
            XCTAssertTrue(reading.page.controlStates.allSatisfy { $0.kind == .unavailable })
            let projected = try ComputerUseBrowserResultPageInput(page: reading.page)
            XCTAssertTrue(projected.controlIDs.isEmpty); XCTAssertFalse(projected.controlMetadataComplete)
            XCTAssertFalse(projected.contextJSON.contains("Private address"))
        }
    }

    func testSelectionFocusPopupAndReferencedLabelChangesExpireTheWholeReading() async throws {
        let mutations = [
            "document.getElementById('selected').setAttribute('aria-selected','false');",
            "document.getElementById('destination').setAttribute('aria-activedescendant','selected');",
            "const old=document.getElementById('list'); old.replaceWith(old.cloneNode(true));",
            "const old=document.getElementById('caption'); old.replaceWith(old.cloneNode(true));",
            "document.getElementById('destination').value='London';",
            "document.getElementById('list').hidden=false;",
            "document.body.insertAdjacentHTML('beforeend','<label>Password<input type=password></label>');"]
        for (index, mutation) in mutations.enumerated() {
            let fixture = try await ControlStateFixture(body: nativeCombo + """
                <script>fetch('/signal').then(() => { \(mutation) fetch('/changed'); });</script>
                """, heldSignal: true)
            defer { fixture.close() }
            let action = try await scope(fixture), reading = try await fixture.browser.observeResearchControls(for: action)
            try await fixture.wait { fixture.server.count("/signal") == 1 }
            fixture.server.releaseHeldResponses(); try await fixture.wait { fixture.server.count("/changed") == 1 }
            do { try await fixture.browser.validatePageEvidence(reading); XCTFail("The option graph is part of the exact reading") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, index == mutations.count - 1 ? .authenticationRequired : .pageChanged) }
        }
    }

    func testDriverKeepsOptionDeclarationsSeparateFromOfferFactsAndExpiresScopeOnHandback() async throws {
        let fixture = try await ResearchAnswerFixture.make(controlHTML: """
            <div role=listbox aria-label='Ticket choices'><div role=option aria-selected=true>General admission for two tickets</div></div>
            """)
        defer { fixture.source.close() }
        fixture.source.actions.select = { input in try self.scopeJSON(input.readableControlIDs, requirement: 0) }
        guard case .browserResearchAnswer(let answer)? = try await fixture.source.start() else { return XCTFail("Independent result prose can retain the whole declared choice as context") }
        let owner = try fixture.source.owner(), reading = try await owner.revalidateCandidates()
        try owner.validateAnswer(answer)
        let candidate = try XCTUnwrap(reading.candidates.first), field = try XCTUnwrap(candidate.fields.last)
        XCTAssertEqual(field.sourceKind, .controlState); XCTAssertFalse(field.allowsResultSupport)
        XCTAssertFalse(candidate.texts.contains { $0.text.contains("General admission for two tickets") })
        XCTAssertTrue(answer.message.contains("General admission for two tickets")); XCTAssertTrue(answer.message.contains("Focus is not selection"))
        XCTAssertFalse(fixture.source.state.commands.contains(.edit)); XCTAssertFalse(fixture.source.state.commands.contains(.prepareFormQuery))
        let old = try await owner.planNextAction(using: fixture.source.actions)
        owner.pause(); try await owner.resumeAfterUserControl()
        do { _ = try await owner.readCandidates(for: old); XCTFail("Handback requires a fresh graph and scope") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserActionPlanError, .inputChanged) }
        XCTAssertEqual(owner.input.prompt, fixture.source.request)
    }

    func testNativeDecoderRejectsIncompleteGraphsForeignFocusAndWrongProvenance() async throws {
        let fixture = try await ControlStateFixture(body: nativeCombo)
        defer { fixture.close() }
        let action = try await scope(fixture), reading = try await fixture.browser.observeResearchControls(for: action)
        let control = try XCTUnwrap(reading.page.controls.first), state = try fixture.state("Destination", in: reading.page)
        let value = try object(XCTUnwrap(state.value))
        var foreignFocus = value; foreignFocus["active_option"] = "o999999"
        var missingGraph = value; missingGraph.removeValue(forKey: "options")
        var wrongProvenance = value; wrongProvenance["input_value"] = NSNull(); wrongProvenance["display_text"] = "Paris typed"
        var extra = value; extra["result_support"] = true
        var duplicates = value
        let option = try XCTUnwrap((value["options"] as? [[String: Any]])?.first)
        duplicates["options"] = [option, option]
        var wrongType = value, rows = try XCTUnwrap(value["options"] as? [[String: Any]])
        rows[0]["selected"] = true; wrongType["options"] = rows
        for proposal in [foreignFocus, missingGraph, wrongProvenance, extra, duplicates, wrongType] {
            let raw = try ResearchAnswerFixture.json(proposal)
            XCTAssertNil(ComputerUseBrowserCompositeState.object(raw, control: control))
            let forged = ComputerUseBrowserControlState(controlID: control.id, kind: .composite, value: raw,
                selectedOptionIDs: nil, checked: nil, indeterminate: nil)
            XCTAssertFalse(forged.isValid(for: control))
        }
        let raw = try XCTUnwrap(state.value)
        let duplicateRoot = "{\"role\":\"combobox\"," + String(raw.dropFirst())
        XCTAssertNil(ComputerUseBrowserCompositeState.object(duplicateRoot, control: control))
    }

    private var nativeCombo: String {
        """
        <article><h2>Concert Alpha</h2><form action='/search'><label>Destination
        <input id=destination name=destination role=combobox aria-expanded=false aria-controls=list aria-activedescendant=focused value='Paris typed'></label></form>
        <span id=caption hidden>Charles de Gaulle</span><div id=list role=listbox aria-label=Airports hidden>
        <div id=selected role=option aria-labelledby=caption aria-selected=true></div><div id=focused role=option aria-selected=false>Orly</div></div></article>
        """
    }
    private func input(_ fixture: ControlStateFixture) async throws -> ComputerUseBrowserActionInput {
        let evidence = try await fixture.browser.observePage(document: fixture.document)
        let goal = try ComputerUseBrowserGoalInput(taskID: fixture.document.taskID, prompt: "Find concerts. Keep displayed criteria. Do not buy.",
            referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "UTC")
        let rows: [[String: Any]] = [
            ["turn":0,"source":"Find concerts. ","role":"outcome","field":"category","relation":"unspecified","values":[]],
            ["turn":0,"source":"Keep displayed criteria. ","role":"condition","field":"other","relation":"unspecified","values":[]],
            ["turn":0,"source":"Do not buy.","role":"prohibition","field":"other","relation":"unspecified","values":[]]]
        let interpretation = try ComputerUseBrowserGoalProposal.decode(content: ResearchAnswerFixture.json([
            "disposition":"research","requirements":rows,"question":["topic":"none","requirements":[]]]), input: goal)
        return try .init(interpretation: interpretation, evidence: evidence, navigationHistory: [], formHistory: [], latestForm: nil, changedFormTargetIDs: [])
    }
    private func scope(_ fixture: ControlStateFixture) async throws -> ComputerUseBrowserActionProposal {
        let input = try await input(fixture)
        return try .decode(content: scopeJSON(input.readableControlIDs), input: input)
    }
    private func scopeJSON(_ ids: [String], requirement: Int = 1) throws -> String {
        try ResearchAnswerFixture.json(["read_results":true,"read_controls":ids.map { ["control":$0,"requirement":requirement] as [String: Any] }])
    }
    private func object(_ value: String) throws -> [String: Any] { try ResearchAnswerFixture.object(Data(value.utf8)) }
}

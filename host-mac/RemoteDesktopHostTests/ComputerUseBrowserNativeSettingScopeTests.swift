import Foundation
import XCTest
@testable import RemoteDesktopHost

/// Prepared native/owner regressions; execution remains explicitly deferred.
@MainActor
final class ComputerUseBrowserNativeSettingScopeTests: XCTestCase {
    private let settings = """
        <label>Date<input id=date name=date type=date value=2026-09-20></label>
        <label>Tickets<input id=tickets name=tickets type=number value=2></label>
        <label>Category<select id=category name=category><option value=all>All events</option><option value=concerts>Concerts</option></select></label>
        <label>Direct only<input id=direct name=direct type=checkbox value=1 checked></label>
        <label>Economy fare<input id=fare name=fare type=radio value=economy checked></label>
        <label>Extras<select id=extras name=extras multiple><option value=a selected>First extra</option><option value=b selected>Second extra</option></select></label>
        """
    private let settingsReferences = ["Date":1,"Tickets":1,"Category":1,"Direct only":1,"Economy fare":1,"Extras":1]
    private let queryPath = "/filtered?q=concerts&date=2026-09-20&tickets=2&category=all&direct=1&fare=economy&extras=a&extras=b"

    func testEverySupportedWritableNativeKindCanBeExplicitlyReadWithoutSubmissionCodes() async throws {
        let fixture = try await ControlStateFixture(body: "<form action='/effect'>" + settings + """
            <label>Local departure<input type=datetime-local value=2026-09-20T10:30></label>
            <label>Month<input type=month value=2026-09></label><label>Week<input type=week value=2026-W38></label>
            <label>Time<input type=time value=10:30></label></form>
            """)
        defer { fixture.close() }
        let input = try await context(fixture)
        XCTAssertEqual(input.readableControlIDs.count, 10); XCTAssertFalse(input.evidence.page.controlStateObserved)
        let reading = try await fixture.browser.observeResearchControls(for: read(input, ids: input.readableControlIDs))
        let expected = ["Date":"2026-09-20","Tickets":"2","Category":"All events","Direct only":"Checked",
            "Economy fare":"Checked","Extras":"First extra\nSecond extra","Local departure":"2026-09-20T10:30",
            "Month":"2026-09","Week":"2026-W38","Time":"10:30"]
        for control in reading.page.controls {
            XCTAssertFalse(control.disabled || control.readOnly)
            XCTAssertEqual(try fixture.state(control.label, in: reading.page).fieldSource(for: control), expected[control.label])
        }
        XCTAssertEqual(reading.page.scopedControlIDs, input.readableControlIDs)
        let projected = try ComputerUseBrowserResultPageInput(page: reading.page).contextJSON
        XCTAssertFalse(projected.contains("\"value\":\"all\"")); XCTAssertFalse(projected.contains("\"value\":\"economy\""))
        XCTAssertEqual(fixture.server.count("/effect"), 0)
        try await fixture.browser.validatePageEvidence(reading)
    }

    func testExplicitScopeDoesNotImplicitlyReadNeighboringWritableSettings() async throws {
        let fixture = try await ControlStateFixture(body: settings + "<label>Location<input value=Paris></label><label>Notes<input value=private-notes></label>")
        defer { fixture.close() }
        let input = try await context(fixture), location = try control("Location", input)
        let reading = try await fixture.browser.observeResearchControls(for: read(input, ids: [location]))
        for item in reading.page.controls {
            XCTAssertEqual(try fixture.state(item.label, in: reading.page).kind, item.id == location ? .text : .unavailable)
        }
        let projected = try ComputerUseBrowserResultPageInput(page: reading.page).contextJSON
        XCTAssertTrue(projected.contains("Paris")); XCTAssertFalse(projected.contains("2026-09-20")); XCTAssertFalse(projected.contains("private-notes"))
        XCTAssertFalse(reading.page.omittedControlMetadata); XCTAssertTrue(reading.page.omittedControls)
    }

    func testProtectedWritableSettingsRemainIneligibleInSwiftAndNativeScopes() async throws {
        let fixture = try await ControlStateFixture(body: """
            <label>Date<input type=date value=2026-09-20></label>
            <label>Card details<input type=number autocomplete=cc-number value=4111111111111111></label>
            <label>Birth date<input type=date value=1990-01-02></label>
            <label>Billing country<select><option value=private-code>Private country</option></select></label>
            <label>Account preference<input type=checkbox checked></label>
            """)
        defer { fixture.close() }
        let input = try await context(fixture)
        XCTAssertEqual(input.readableControlIDs, [try control("Date", input)])
        for item in input.evidence.page.controls where item.label != "Date" {
            XCTAssertFalse(item.researchReadable)
            XCTAssertThrowsError(try read(input, ids: [item.id]))
            let reply = try await fixture.browser.callDOM(.observeResearchControls, arguments: ["documentID":input.evidence.documentID,
                "snapshotID":input.evidence.page.id,"readControlIDs":[item.id]], document: fixture.document)
            XCTAssertEqual(reply.status, "unsupported"); XCTAssertNil(reply.page)
        }
    }

    func testPropertyOnlyChangesInvalidateEachScopedWritableState() async throws {
        let cases = [("date","value='2026-09-21'"),("tickets","value='3'"),("category","selectedIndex=1"),
            ("direct","checked=false"),("fare","checked=false"),("extras","options[1].selected=false")]
        for (id, mutation) in cases {
            let fixture = try await ControlStateFixture(body: settings + OptionSelectionFixture.signal("document.getElementById('\(id)').\(mutation);"), heldSignal: true)
            defer { fixture.close() }
            let input = try await context(fixture)
            let reading = try await fixture.browser.observeResearchControls(for: read(input, ids: input.readableControlIDs))
            try await fixture.wait { fixture.server.count("/signal") == 1 }; fixture.server.releaseHeldResponses()
            try await fixture.wait { fixture.server.count("/changed") == 1 }
            do { try await fixture.browser.validatePageEvidence(reading); XCTFail("A property change cannot preserve the earlier reading: \(id)") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        }
    }

    func testScopedSnapshotRejectsAnAvailableNativeValueOutsideItsDeclaredScope() async throws {
        let fixture = try await ControlStateFixture(body: settings)
        defer { fixture.close() }
        let general = try await fixture.browser.observePage(document: fixture.document, includingControlState: true)
        let input = try await context(fixture), date = try control("Date", input)
        let reading = try await fixture.browser.observeResearchControls(for: read(input, ids: [date])), page = reading.page
        let tickets = try control("Tickets", input)
        let ticketState = try XCTUnwrap(general.page.controlStates.first { $0.controlID == tickets })
        let injected = page.controlStates.map { $0.controlID == tickets ? ticketState : $0 }
        let forged = ComputerUseBrowserPageSnapshot(id: page.id, texts: page.texts, links: page.links, controls: page.controls,
            truncated: page.truncated, omittedEmbeddedContent: page.omittedEmbeddedContent, omittedControls: page.omittedControls,
            viewport: page.viewport, containers: page.containers, omittedStructure: page.omittedStructure, controlStates: injected,
            controlStateObserved: true, scopedControlIDs: [date], omittedControlMetadata: page.omittedControlMetadata)
        XCTAssertFalse(forged.isWellFormed); XCTAssertTrue(page.isWellFormed)
    }

    func testQueryReadsUntouchedNativeDefaultsBeforeItsFinalDecisionAndOneGET() async throws {
        let fixture = try await prepared()
        defer { fixture.close() }
        configure(fixture, mode: .query)
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        XCTAssertEqual(action.input.optionReadControls.count, 6)
        XCTAssertTrue(action.input.contextJSON.contains("2026-09-20"))
        XCTAssertTrue(action.input.contextJSON.contains("\"checked\":true"))
        XCTAssertEqual(fixture.actions.inputs.last, action.input)
        XCTAssertEqual(fixture.server.count(queryPath), 0)
        _ = try await owner.openFormQuery(for: action)
        XCTAssertEqual(fixture.server.count(queryPath), 1); XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testIndeterminateSettingReturnsForAQueryDecisionAndCanRemainUnresolved() async throws {
        let fixture = try await prepared(extra: "<script>document.getElementById('direct').indeterminate=true;</script>")
        defer { fixture.close() }
        configure(fixture, mode: .query, rejectMixed: true)
        let action = try await fixture.owner().planNextAction(using: fixture.actions)
        XCTAssertEqual(action.step, .unavailable)
        XCTAssertTrue(action.input.evidence.page.controlStates.contains { $0.indeterminate == true })
        XCTAssertEqual(fixture.state.commands.filter { $0 == .prepareFormQuery }.count, 0)
        XCTAssertEqual(fixture.server.count(queryPath), 0)
    }

    func testQueryPauseRestoresAllOriginalNativeSettingsWithoutAnotherDecision() async throws {
        let fixture = try await prepared()
        defer { fixture.close() }
        configure(fixture, mode: .query)
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        fixture.state.onCommand = { command in
            guard command == .prepareFormQuery else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        do { _ = try await owner.openFormQuery(for: action); XCTFail("Expected Pause") }
        catch { XCTAssertTrue(error is CancellationError) }
        let decisions = fixture.actions.inputs.count, reads = fixture.state.commands.filter { $0 == .observeResearchControls }.count
        try await owner.resumeAfterUserControl(); _ = try await owner.resumeFormNavigation()
        XCTAssertEqual(fixture.actions.inputs.count, decisions)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .observeResearchControls }.count, reads + 1)
        XCTAssertEqual(fixture.server.count(queryPath), 1); XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testChangedNativeDefaultDuringQueryHandbackCannotBecomeANewBaseline() async throws {
        let fixture = try await prepared(extra: OptionSelectionFixture.signal("document.getElementById('date').value='2026-09-21';"), heldSignal: true)
        defer { fixture.close() }
        configure(fixture, mode: .query)
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        fixture.state.onCommand = { command in
            guard command == .prepareFormQuery else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        do { _ = try await owner.openFormQuery(for: action); XCTFail("Expected Pause") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await release(fixture); try await owner.resumeAfterUserControl()
        do { _ = try await owner.resumeFormNavigation(); XCTFail("Changed Date cannot rebase the reviewed query") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        XCTAssertEqual(fixture.server.count(queryPath), 0)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testFormSelectedFromAValueReadingRestoresThatScopeBeforeItsFirstEdit() async throws {
        let fixture = try await prepared()
        defer { fixture.close() }
        let (input, proposal) = try await categoryInput(fixture)
        XCTAssertEqual(input.scopeReview?.readControls.count, 6)
        let before = fixture.state.commands.filter { $0 == .observeResearchControls }.count
        _ = try await fixture.owner().executeForm(proposal, input: input)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .observeResearchControls }.count, before + 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(try fixture.owner().confirmedFormHistory.count, 2)
    }

    func testPauseDuringFormReadingRestorationKeepsTheSamePlanUntilHandback() async throws {
        let fixture = try await prepared()
        defer { fixture.close() }
        let (input, proposal) = try await categoryInput(fixture), owner = try fixture.owner()
        fixture.state.onCommand = { command in
            guard command == .observeResearchControls else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        do { _ = try await owner.executeForm(proposal, input: input); XCTFail("Expected Pause") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(owner.hasPendingForm); XCTAssertFalse(owner.isOperating)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        let decisions = fixture.actions.inputs.count, original = owner.input
        try await owner.resumeAfterUserControl(); _ = try await owner.resumeForm()
        XCTAssertEqual(owner.input, original); XCTAssertEqual(fixture.actions.inputs.count, decisions)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(owner.confirmedFormHistory.count, 2)
    }

    func testChangedUneditedSettingDuringFormHandbackBlocksTheOriginalEdit() async throws {
        let fixture = try await prepared(extra: OptionSelectionFixture.signal("document.getElementById('date').value='2026-09-21';"), heldSignal: true)
        defer { fixture.close() }
        let (input, proposal) = try await categoryInput(fixture), owner = try fixture.owner()
        fixture.state.onCommand = { command in
            guard command == .observeResearchControls else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        do { _ = try await owner.executeForm(proposal, input: input); XCTFail("Expected Pause") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await release(fixture); try await owner.resumeAfterUserControl()
        do { _ = try await owner.resumeForm(); XCTFail("A changed unedited setting cannot be adopted on Resume") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchFormError, .inputChanged) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(owner.confirmedFormHistory.count, 1)
    }

    func testChangedReadMetadataStopsRecoveryBeforeAnotherValueIsCollected() async throws {
        let fixture = try await prepared(extra: OptionSelectionFixture.signal("document.getElementById('date').type='text'; document.getElementById('date').value='new-private-value';"), heldSignal: true)
        defer { fixture.close() }
        configure(fixture, mode: .query)
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        fixture.state.onCommand = { command in
            guard command == .prepareFormQuery else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        do { _ = try await owner.openFormQuery(for: action); XCTFail("Expected Pause") }
        catch { XCTAssertTrue(error is CancellationError) }
        let reads = fixture.state.commands.filter { $0 == .observeResearchControls }.count
        try await release(fixture); try await owner.resumeAfterUserControl()
        do { _ = try await owner.resumeFormNavigation(); XCTFail("A different field type cannot inherit the original reading authority") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserActionPlanError, .inputChanged) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .observeResearchControls }.count, reads)
        XCTAssertTrue(fixture.actions.inputs.allSatisfy { !$0.contextJSON.contains("new-private-value") })
        XCTAssertEqual(fixture.server.count(queryPath), 0)
    }

    func testMetadataFingerprintPreservesExactLabelBytesBeforeARecoveryRead() async throws {
        let fixture = try await ControlStateFixture(body: "<label id=label>Café<input type=number value=2></label>"
            + OptionSelectionFixture.signal("document.getElementById('label').firstChild.data='Cafe\\u0301';"), heldSignal: true)
        defer { fixture.close() }
        let before = try await fixture.browser.observePage(document: fixture.document)
        let id = try XCTUnwrap(before.page.controls.first?.id)
        try await fixture.wait { fixture.server.count("/signal") == 1 }; fixture.server.releaseHeldResponses()
        try await fixture.wait { fixture.server.count("/changed") == 1 }
        let after = try await fixture.browser.observePage(document: fixture.document)
        XCTAssertEqual(before.page.controls.first?.label, after.page.controls.first?.label, "Swift treats these Unicode strings as equivalent")
        XCTAssertNotEqual(try ComputerUseBrowserObservedCriteria.metadataDigest(controlIDs: [id], page: before.page),
            try ComputerUseBrowserObservedCriteria.metadataDigest(controlIDs: [id], page: after.page))
        XCTAssertFalse(before.page.controlStateObserved); XCTAssertFalse(after.page.controlStateObserved)
    }

    private enum Mode { case form, query, reviseCategory }
    private func configure(_ fixture: ResearchDriverFixture, mode: Mode, rejectMixed: Bool = false) {
        fixture.actions.select = { input in
            let revising = mode == .reviseCategory && input.formEffectScope?.formID != nil
            let editing = revising ? ["Category":[0]] : ["Query":[0]]
            let retaining = revising ? ["Query":[0]] : [:]
            var deferred = self.settingsReferences.mapValues { [$0] }
            if revising { deferred.removeValue(forKey: "Category") }
            if let reply = try FormEffectScopeFixture.response(input, relevant: self.settingsReferences, unrelated: ["Private notes"],
                editing: editing, retaining: retaining, deferring: deferred, preserving: ["Reference":2]) { return reply }
            if rejectMixed && input.evidence.page.controlStates.contains(where: { $0.indeterminate == true }) { return #"{"unavailable":true}"# }
            if mode == .query || (mode == .reviseCategory && input.formEffectScope?.queryControlID == nil && input.formEffectScope?.formID == nil) {
                return try ResearchAnswerFixture.json(["query":XCTUnwrap(input.queryControlIDs.first)])
            }
            if input.formEffectScope != nil && !input.effectScopeAllowsActions { return #"{"unavailable":true}"# }
            return try ResearchAnswerFixture.json(["form":XCTUnwrap(input.formIDs.first),"preserve":[]])
        }
    }
    private func prepared(extra: String = "", heldSignal: Bool = false) async throws -> ResearchDriverFixture {
        let body = "<form action='/filtered'><label>Query<input name=q></label>" + settings
            + "<button>Search</button></form><label>Reference<input value='private-reference'></label><label>Private notes<input value='private-notes'></label>" + extra
        let fixture = try await ResearchDriverFixture.make(request: prompt, searchFormHTML: body, heldSignal: heldSignal)
        fixture.goal.select = { _ in try self.goalContent() }; fixture.policy.choices = [false]
        do {
            _ = try await fixture.start(); configure(fixture, mode: .form)
            let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
            let input = try await owner.prepareFormInput(for: action), query = try XCTUnwrap(input.editableFieldAliases.first)
            let body = try ResearchAnswerFixture.json(["edits":[["field":query,"terms":[["requirement":0,"text":"concerts"]]]],"preserve":[]])
            XCTAssertEqual(Set(input.evidence.fields.map { $0.control.label }), ["Query","Reference"])
            _ = try await owner.executeForm(.decode(content: body, input: input), input: input)
            return fixture
        } catch { fixture.close(); throw error }
    }
    private func categoryInput(_ fixture: ResearchDriverFixture) async throws -> (ComputerUseBrowserResearchFormInput, ComputerUseBrowserFormProposal) {
        configure(fixture, mode: .reviseCategory)
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        let input = try await owner.prepareFormInput(for: action)
        let alias = try XCTUnwrap(input.editableFieldAliases.first), field = try input.field(for: alias)
        let option = try XCTUnwrap(field.control.options.first { $0.label == "Concerts" })
        let body = try ResearchAnswerFixture.json(["edits":[["field":alias,"choice":option.id,"requirement":0]],"preserve":[]])
        return (input, try .decode(content: body, input: input))
    }
    private var prompt: String { "Find concerts. Review displayed search settings. Leave Reference unchanged. Do not buy." }
    private func goalContent() throws -> String {
        let rows: [[String: Any]] = [
            ["turn":0,"source":"Find concerts. ","role":"outcome","field":"category","relation":"unspecified","values":[]],
            ["turn":0,"source":"Review displayed search settings. ","role":"condition","field":"other","relation":"unspecified","values":[]],
            ["turn":0,"source":"Leave Reference unchanged. ","role":"condition","field":"other","relation":"unspecified","values":[]],
            ["turn":0,"source":"Do not buy.","role":"prohibition","field":"other","relation":"unspecified","values":[]]]
        return try ResearchAnswerFixture.json(["disposition":"research","requirements":rows,"question":["topic":"none","requirements":[]]])
    }
    private func context(_ fixture: ControlStateFixture) async throws -> ComputerUseBrowserActionInput {
        let page = try await fixture.browser.observePage(document: fixture.document)
        let goal = try ComputerUseBrowserGoalInput(taskID: fixture.document.taskID, prompt: prompt, referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "UTC")
        return try .init(interpretation: .decode(content: goalContent(), input: goal), evidence: page,
            navigationHistory: [], formHistory: [], latestForm: nil, changedFormTargetIDs: [])
    }
    private func read(_ input: ComputerUseBrowserActionInput, ids: [String]) throws -> ComputerUseBrowserActionProposal {
        try .decode(content: ResearchAnswerFixture.json(["read_results":true,"read_controls":ids.map { ["control":$0,"requirement":1] as [String: Any] }]), input: input)
    }
    private func control(_ label: String, _ input: ComputerUseBrowserActionInput) throws -> String {
        try XCTUnwrap(input.evidence.page.controls.first { $0.label == label }?.id)
    }
    private func release(_ fixture: ResearchDriverFixture) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while fixture.server.count("/signal") != 1 {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }; try await Task.sleep(for: .milliseconds(10))
        }
        fixture.server.releaseHeldResponses()
        while fixture.server.count("/changed") != 1 {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }; try await Task.sleep(for: .milliseconds(10))
        }
    }
}

import Foundation
import XCTest
@testable import RemoteDesktopHost

/// Native adapter cases only. The ordinary planner/journaled research owner
/// does not yet expose option selection; these are not end-to-end task proofs.
@MainActor
final class ComputerUseBrowserOptionSelectionTests: XCTestCase {
    private let operation = String(repeating: "a", count: 64)

    func testPreparationRequiresScopedOptionsAndPreservesOnlyAlreadyObservedCriteria() async throws {
        let fixture = try await ControlStateFixture(body: OptionSelectionFixture.page())
        defer { fixture.close() }
        let intent = try await OptionSelectionFixture.intent(fixture), first = try await fixture.browser.prepareOptionSelection(intent)
        let repeated = try await fixture.browser.prepareOptionSelection(intent)
        XCTAssertEqual(first, repeated); XCTAssertTrue(first.binding.needsDispatch)
        try await fixture.browser.validateOptionSelection(first)
        let date = try XCTUnwrap(intent.evidence.page.controls.first { $0.label == "Date" })
        XCTAssertEqual(intent.observedPreservedControlIDs, [date.id])
        XCTAssertEqual(String(reflecting: intent), "BrowserOptionSelectionIntent")
        XCTAssertEqual(String(reflecting: first), "BrowserOptionSelectionTarget")
        XCTAssertEqual(fixture.server.count("/chosen"), 0)
        for (option, requirement) in [("o999", 1), (intent.optionID, 3)] {
            XCTAssertThrowsError(try ComputerUseBrowserOptionSelectionIntent(interpretation: intent.interpretation,
                evidence: intent.evidence, controlID: intent.controlID, optionID: option, requirementIndex: requirement))
        }
        let result = try await fixture.browser.callDOM(.selectOption, arguments: ["documentID":intent.evidence.documentID,
            "snapshotID":intent.evidence.page.id,"bindingID":first.binding.id,"controlID":intent.controlID,
            "optionID":intent.optionID,"operationID":[operation]], document: fixture.document)
        XCTAssertEqual(result.status, "stale"); XCTAssertEqual(fixture.server.count("/chosen"), 0)
        let metadata = try await fixture.browser.observePage(document: fixture.document)
        XCTAssertThrowsError(try ComputerUseBrowserOptionSelectionIntent(interpretation: intent.interpretation,
            evidence: metadata, controlID: intent.controlID, optionID: intent.optionID, requirementIndex: 1))
    }

    func testReceiptKeepsChoiceMeaningAndSeparateDisplayValueWithoutRepeatingTheClick() async throws {
        let fixture = try await ControlStateFixture(body: OptionSelectionFixture.page())
        defer { fixture.close() }
        let target = try await fixture.browser.prepareOptionSelection(OptionSelectionFixture.intent(fixture))
        var boundaries = 0
        try await fixture.browser.dispatchOptionSelection(target, operationID: operation, willBeginEffect: {
            boundaries += 1; XCTAssertEqual(fixture.server.count("/chosen"), 0)
        })
        let result = try await fixture.browser.optionSelectionReceipt(target, operationID: operation)
        let receipt = try XCTUnwrap(result)
        XCTAssertTrue(receipt.didDispatch); XCTAssertTrue(receipt.validates(target, operationID: operation))
        let graph = try ResearchAnswerFixture.object(Data(receipt.afterValue.utf8))
        XCTAssertEqual(graph["display_text"] as? String, "General")
        XCTAssertTrue(receipt.afterValue.contains("General admission USD 40 total"))
        XCTAssertTrue(receipt.afterValue.contains("Admission conditions"))
        XCTAssertFalse(receipt.afterValue.contains("privateUnscoped"))
        XCTAssertEqual(String(reflecting: receipt), "BrowserOptionSelectionReceipt")
        func forged(_ graph: [String: Any], dispatched: Bool = true, preserved: [String]? = nil) throws -> ComputerUseBrowserOptionSelectionReceipt {
            .init(operationID: receipt.operationID, bindingID: receipt.bindingID, controlID: receipt.controlID,
                optionID: receipt.optionID, documentID: receipt.documentID, didDispatch: dispatched,
                afterValue: try ResearchAnswerFixture.json(graph), preservedControlIDs: preserved ?? receipt.preservedControlIDs)
        }
        var renamed = graph, choices = try XCTUnwrap(graph["options"] as? [[String: Any]])
        choices[1]["label"] = "A different ticket"; renamed["options"] = choices
        XCTAssertFalse(try forged(renamed).validates(target, operationID: operation))
        XCTAssertFalse(try forged(graph, dispatched: false).validates(target, operationID: operation))
        XCTAssertFalse(try forged(graph, preserved: []).validates(target, operationID: operation))
        var focusElsewhere = graph
        focusElsewhere["active_option"] = choices[0]["id"]
        XCTAssertTrue(try forged(focusElsewhere).validates(target, operationID: operation), "Focus remains distinct from declared selection")
        try await fixture.wait { fixture.server.count("/chosen") == 1 }
        try await fixture.browser.dispatchOptionSelection(target, operationID: operation, willBeginEffect: {})
        do {
            try await fixture.browser.dispatchOptionSelection(target, operationID: String(repeating: "b", count: 64), willBeginEffect: {})
            XCTFail("A consumed choice binding cannot be activated under another ID")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserOptionSelectionError, .uncertain) }
        let retired = try await fixture.browser.retireUnsentOptionSelection(target, operationID: operation)
        XCTAssertFalse(retired); XCTAssertEqual(boundaries, 1); XCTAssertEqual(fixture.server.count("/chosen"), 1)
    }

    func testAlreadySelectedOptionProducesAnObservationWithoutAnyClick() async throws {
        let fixture = try await ControlStateFixture(body: OptionSelectionFixture.page())
        defer { fixture.close() }
        let target = try await fixture.browser.prepareOptionSelection(OptionSelectionFixture.intent(fixture, first: true))
        XCTAssertFalse(target.intent.needsDispatch); XCTAssertFalse(target.binding.needsDispatch)
        try await fixture.browser.dispatchOptionSelection(target, operationID: operation, willBeginEffect: {})
        let result = try await fixture.browser.optionSelectionReceipt(target, operationID: operation)
        let receipt = try XCTUnwrap(result)
        XCTAssertFalse(receipt.didDispatch); XCTAssertTrue(receipt.validates(target, operationID: operation))
        try await fixture.browser.dispatchOptionSelection(target, operationID: operation, willBeginEffect: {})
        XCTAssertEqual(fixture.server.count("/chosen"), 0)
    }

    func testChangedPreparedOptionsGroupsAndCriteriaCannotDispatchAndCanBeRevokedUnsent() async throws {
        let changes = [
            "const old=document.getElementById('second'); old.replaceWith(old.cloneNode(true));",
            "document.getElementById('group').setAttribute('aria-label','Different conditions');",
            "document.getElementById('date').value='2026-09-21';",
            "document.getElementById('combo').setAttribute('aria-controls','other');"]
        for change in changes {
            let fixture = try await ControlStateFixture(body: OptionSelectionFixture.page() + OptionSelectionFixture.signal(change), heldSignal: true)
            defer { fixture.close() }
            let target = try await fixture.browser.prepareOptionSelection(OptionSelectionFixture.intent(fixture))
            try await fixture.wait { fixture.server.count("/signal") == 1 }
            fixture.server.releaseHeldResponses()
            try await fixture.wait { fixture.server.count("/changed") == 1 }
            do { try await fixture.browser.validateOptionSelection(target); XCTFail("The original selection must expire") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserOptionSelectionError, .unavailable) }
            do {
                try await fixture.browser.dispatchOptionSelection(target, operationID: operation, willBeginEffect: {})
                XCTFail("Changed preconditions cannot start an input")
            } catch { XCTAssertEqual(error as? ComputerUseBrowserOptionSelectionError, .uncertain) }
            let retired = try await fixture.browser.retireUnsentOptionSelection(target, operationID: operation)
            XCTAssertTrue(retired)
            do {
                try await fixture.browser.dispatchOptionSelection(target, operationID: operation, willBeginEffect: {})
                XCTFail("Native retirement must revoke the old plan")
            } catch { XCTAssertEqual(error as? ComputerUseBrowserOptionSelectionError, .uncertain) }
            XCTAssertEqual(fixture.server.count("/chosen"), 0)
        }
    }

    func testChangedOtherCriteriaOrReplacedChoiceMeaningCannotBecomeAReceipt() async throws {
        let changes = [
            "document.getElementById('date').value='2026-09-21';",
            "const old=document.getElementById('second'); old.replaceWith(old.cloneNode(true));",
            "const option=document.getElementById('second'), parent=option.parentNode; option.remove(); parent.appendChild(option);",
            "document.getElementById('group').setAttribute('aria-label','Different conditions');",
            "document.getElementById('first').setAttribute('aria-selected','true');"]
        for (index, change) in changes.enumerated() {
            let restore = index == 0 ? OptionSelectionFixture.signal("document.getElementById('date').value='2026-09-20';") : ""
            let fixture = try await ControlStateFixture(body: OptionSelectionFixture.page(extra: change) + restore, heldSignal: index == 0)
            defer { fixture.close() }
            let target = try await fixture.browser.prepareOptionSelection(OptionSelectionFixture.intent(fixture))
            try await fixture.browser.dispatchOptionSelection(target, operationID: operation, willBeginEffect: {})
            do { _ = try await fixture.browser.optionSelectionReceipt(target, operationID: operation); XCTFail("An overwritten criterion or changed choice is not success") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserOptionSelectionError, .uncertain) }
            if index == 0 {
                try await fixture.wait { fixture.server.count("/signal") == 1 }
                fixture.server.releaseHeldResponses()
                try await fixture.wait { fixture.server.count("/changed") == 1 }
                do { _ = try await fixture.browser.optionSelectionReceipt(target, operationID: operation); XCTFail("A witnessed violation cannot be repaired into this historical receipt") }
                catch { XCTAssertEqual(error as? ComputerUseBrowserOptionSelectionError, .uncertain) }
            }
            try await fixture.browser.dispatchOptionSelection(target, operationID: operation, willBeginEffect: {})
            try await fixture.wait { fixture.server.count("/chosen") == 1 }
            let retired = try await fixture.browser.retireUnsentOptionSelection(target, operationID: operation)
            XCTAssertFalse(retired)
        }
    }

    func testFocusOrDisplayTextAloneCannotProveSelectionOrRestartConfirmationTime() async throws {
        let fixture = try await ControlStateFixture(body: OptionSelectionFixture.page(handler: """
            document.getElementById('combo').setAttribute('aria-activedescendant','second');
            document.getElementById('display').textContent='General'; fetch('/chosen');
            """))
        defer { fixture.close() }
        let target = try await fixture.browser.prepareOptionSelection(OptionSelectionFixture.intent(fixture))
        try await fixture.browser.dispatchOptionSelection(target, operationID: operation, willBeginEffect: {})
        let pending = try await fixture.browser.optionSelectionReceipt(target, operationID: operation)
        XCTAssertNil(pending)
        try await Task.sleep(for: .milliseconds(2100))
        do { _ = try await fixture.browser.optionSelectionReceipt(target, operationID: operation); XCTFail("Focus cannot become selection after the native deadline") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserOptionSelectionError, .uncertain) }
        try await fixture.browser.dispatchOptionSelection(target, operationID: operation, willBeginEffect: {})
        XCTAssertEqual(fixture.server.count("/chosen"), 1)
    }

    func testAssociatedFormAndReferencedLabelObjectsCannotBeReplacedOrReinserted() async throws {
        let externalChanges = [
            "const form=document.getElementById('booking'); form.remove(); document.body.prepend(form);",
            "const form=document.getElementById('booking'); form.replaceWith(form.cloneNode(true));",
            "const label=document.getElementById('terms'); label.remove(); document.body.prepend(label);"]
        for change in externalChanges {
            let body = "<form id=booking></form><span id=terms>Admission conditions</span>" + OptionSelectionFixture.page(extra: change)
                .replacingOccurrences(of: "id=combo ", with: "id=combo form=booking ")
                .replacingOccurrences(of: "id=group role=group aria-label='Admission conditions'", with: "id=group role=group aria-labelledby=terms")
            let fixture = try await ControlStateFixture(body: body)
            defer { fixture.close() }
            let target = try await fixture.browser.prepareOptionSelection(OptionSelectionFixture.intent(fixture))
            try await fixture.browser.dispatchOptionSelection(target, operationID: operation, willBeginEffect: {})
            do { _ = try await fixture.browser.optionSelectionReceipt(target, operationID: operation); XCTFail("Required external objects cannot be replaced or reinserted") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserOptionSelectionError, .uncertain) }
            try await fixture.browser.dispatchOptionSelection(target, operationID: operation, willBeginEffect: {})
            try await fixture.wait { fixture.server.count("/chosen") == 1 }
            let retired = try await fixture.browser.retireUnsentOptionSelection(target, operationID: operation)
            XCTAssertFalse(retired)
        }
    }

    func testCheckedConventionIsDistinctAndAmbiguousMultipleHiddenOrDisabledChoicesAreRejected() async throws {
        let checked = try await ControlStateFixture(body: OptionSelectionFixture.page().replacingOccurrences(of: "aria-selected", with: "aria-checked"))
        defer { checked.close() }
        let target = try await checked.browser.prepareOptionSelection(OptionSelectionFixture.intent(checked))
        XCTAssertEqual(target.intent.selectionMode, "checked")
        try await checked.browser.dispatchOptionSelection(target, operationID: operation, willBeginEffect: {})
        let receipt = try await checked.browser.optionSelectionReceipt(target, operationID: operation)
        XCTAssertNotNil(receipt)
        let ordinary = OptionSelectionFixture.page()
        for body in [
            ordinary.replacingOccurrences(of: "aria-selected=", with: "aria-checked=false aria-selected="),
            ordinary.replacingOccurrences(of: "aria-selected=false", with: "aria-checked=mixed"),
            ordinary.replacingOccurrences(of: "id=choices role=listbox", with: "id=choices role=listbox aria-multiselectable=true"),
            ordinary.replacingOccurrences(of: "id=second ", with: "id=second hidden "),
            ordinary.replacingOccurrences(of: "id=second ", with: "id=second aria-disabled=true "),
            ordinary.replacingOccurrences(of: "Admission conditions", with: "Account password")] {
            let fixture = try await ControlStateFixture(body: body)
            defer { fixture.close() }
            do { _ = try await fixture.browser.prepareOptionSelection(OptionSelectionFixture.intent(fixture)); XCTFail("Unsupported state must never authorize a choice click") }
            catch { XCTAssertTrue(error is ComputerUseBrowserOptionSelectionError || error as? ComputerUseBrowserError == .authenticationRequired) }
            XCTAssertEqual(fixture.server.count("/chosen"), 0)
        }
    }

    func testDispatchBoundaryFailureDoesNothingAndAuthenticationWithholdsTheReceipt() async throws {
        let fixture = try await ControlStateFixture(body: OptionSelectionFixture.page(extra: "document.body.insertAdjacentHTML('beforeend','<label>Password<input type=password></label>');"))
        defer { fixture.close() }
        let target = try await fixture.browser.prepareOptionSelection(OptionSelectionFixture.intent(fixture))
        do {
            try await fixture.browser.dispatchOptionSelection(target, operationID: operation, willBeginEffect: { throw SelectionBoundaryFailure.interrupted })
            XCTFail("A rejected durable boundary cannot reach the DOM")
        } catch { XCTAssertTrue(error is SelectionBoundaryFailure) }
        XCTAssertEqual(fixture.server.count("/chosen"), 0)
        try await fixture.browser.dispatchOptionSelection(target, operationID: operation, willBeginEffect: {})
        do { _ = try await fixture.browser.optionSelectionReceipt(target, operationID: operation); XCTFail("Authentication must remain typed for handoff") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        try await fixture.browser.dispatchOptionSelection(target, operationID: operation, willBeginEffect: {})
        try await fixture.wait { fixture.server.count("/chosen") == 1 }
    }

}

@MainActor
enum OptionSelectionFixture {
    static func intent(_ fixture: ControlStateFixture, first: Bool = false) async throws -> ComputerUseBrowserOptionSelectionIntent {
        let metadata = try await fixture.browser.observePage(document: fixture.document)
        let requirement = first ? "Use VIP tickets. " : "Use general admission. "
        let goal = try ComputerUseBrowserGoalInput(taskID: fixture.document.taskID,
            prompt: "Find concerts. " + requirement + "Keep date unchanged. Do not buy.",
            referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
        let rows: [[String: Any]] = [
            ["turn":0,"source":"Find concerts. ","role":"outcome","field":"category","relation":"unspecified","values":[]],
            ["turn":0,"source":requirement,"role":"condition","field":"other","relation":"unspecified","values":[]],
            ["turn":0,"source":"Keep date unchanged. ","role":"condition","field":"other","relation":"unspecified","values":[]],
            ["turn":0,"source":"Do not buy.","role":"prohibition","field":"other","relation":"unspecified","values":[]]]
        let interpretation = try ComputerUseBrowserGoalProposal.decode(content: ResearchAnswerFixture.json([
            "disposition":"research","requirements":rows,"question":["topic":"none","requirements":[]]]), input: goal)
        guard let control = metadata.page.controls.first(where: { $0.label == "Ticket type" }),
              let date = metadata.page.controls.first(where: { $0.label == "Date" }) else { throw ComputerUseBrowserOptionSelectionError.invalidIntent }
        let input = try ComputerUseBrowserActionInput(interpretation: interpretation, evidence: metadata,
            navigationHistory: [], formHistory: [], latestForm: nil, changedFormTargetIDs: [])
        let action = try ComputerUseBrowserActionProposal.decode(content: ResearchAnswerFixture.json(["read_results":true,
            "read_controls":[["control":control.id,"requirement":1],["control":date.id,"requirement":2]]]), input: input)
        let evidence = try await fixture.browser.observeResearchControls(for: action)
        guard let value = evidence.page.controlStates.first(where: { $0.controlID == control.id })?.value,
              let graph = ComputerUseBrowserCompositeState.object(value, control: control),
              let options = graph["options"] as? [[String: Any]], options.count == 2,
              let option = options[first ? 0 : 1]["id"] as? String else { throw ComputerUseBrowserOptionSelectionError.invalidIntent }
        return try .init(interpretation: interpretation, evidence: evidence, controlID: control.id, optionID: option, requirementIndex: 1)
    }
    static func page(handler: String? = nil, extra: String = "") -> String {
        let normal = """
            document.getElementById('first').setAttribute('aria-selected','false'); this.setAttribute('aria-selected','true');
            document.getElementById('display').textContent='General'; document.getElementById('combo').setAttribute('aria-expanded','false');
            document.getElementById('choices').hidden=true;
            """
        let handler = handler ?? normal + extra + "fetch('/chosen');"
        return """
        <label>Date<input id=date type=date readonly value=2026-09-20></label><label>Private notes<input value=privateUnscoped></label>
        <article><h2>Concert Alpha</h2><button id=combo type=button role=combobox aria-label='Ticket type' aria-controls=choices aria-expanded=true><span id=display>Choose type</span></button>
        <div id=choices role=listbox aria-label='Ticket types'><div id=group role=group aria-label='Admission conditions'>
        <div id=first role=option aria-selected=true onclick="fetch('/chosen');">VIP USD 100 total</div>
        <div id=second role=option aria-selected=false onclick="\(handler)">General admission USD 40 total</div></div></div></article>
        """
    }
    static func signal(_ change: String) -> String { "<script>fetch('/signal').then(() => { " + change + " fetch('/changed'); });</script>" }
}

private enum SelectionBoundaryFailure: Error { case interrupted }

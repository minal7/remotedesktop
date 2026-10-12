import Foundation
import XCTest
@testable import RemoteDesktopHost

/// Prepared source coverage only; these assertions have not executed.
@MainActor
final class ComputerUseBrowserPopupCriteriaTests: XCTestCase {
    private let prompt = "Find concerts. Use general admission. Keep date unchanged. Do not buy."
    private let operation = String(repeating: "c", count: 64)

    func testMetadataCannotPrepareOrProposeAnOpeningBeforeScopedInspection() async throws {
        let fixture = try await ControlStateFixture(body: page())
        defer { fixture.close() }
        let metadata = try await fixture.browser.observePage(document: fixture.document)
        let goal = try interpretation(taskID: fixture.document.taskID)
        let id = try XCTUnwrap(metadata.page.controls.first { $0.label == "Ticket type" }?.id)
        let candidates = try await fixture.browser.popupControlIDs(in: metadata)
        XCTAssertEqual(candidates, [id])
        let input = try ComputerUseBrowserActionInput(interpretation: goal, evidence: metadata, navigationHistory: [],
            formHistory: [], latestForm: nil, changedFormTargetIDs: [], popupControlIDs: candidates, allowOptionInspection: true)
        XCTAssertTrue(input.popupControlIDs.isEmpty); XCTAssertTrue(input.optionInspectionControlIDs.contains(id))
        XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: opening(id), input: input))
        XCTAssertThrowsError(try ComputerUseBrowserPopupIntent(interpretation: goal, evidence: metadata, controlID: id, requirementIndex: 1))
        let native = try await fixture.browser.callDOM(.preparePopup, arguments: ["documentID":metadata.documentID,
            "snapshotID":metadata.page.id,"controlID":id], document: fixture.document)
        XCTAssertEqual(native.status, "popup-unavailable"); XCTAssertNil(native.popupBinding)
        XCTAssertEqual(fixture.server.count("/opened"), 0)
    }

    func testOpeningBindsTheOriginalBaselineAndReceiptWithoutWritingPrivateValues() async throws {
        let fixture = try await ControlStateFixture(body: page())
        defer { fixture.close() }
        let intent = try await intent(fixture), evidence = intent.evidence, old = evidence.page
        let dateID = try XCTUnwrap(intent.observedPreservedControlIDs.first)
        XCTAssertEqual(intent.observedPreservedControlIDs.count, 1)
        let states = old.controlStates.map { state in
            state.controlID == dateID ? ComputerUseBrowserControlState(controlID: dateID, kind: .scalar,
                value: "2026-09-21", selectedOptionIDs: nil, checked: nil, indeterminate: nil) : state
        }
        let changed = ComputerUseBrowserPageSnapshot(id: old.id, texts: old.texts, links: old.links, controls: old.controls,
            truncated: old.truncated, omittedEmbeddedContent: old.omittedEmbeddedContent, omittedControls: old.omittedControls,
            viewport: old.viewport, containers: old.containers, omittedStructure: old.omittedStructure,
            controlStates: states, controlStateObserved: true, scopedControlIDs: old.scopedControlIDs)
        let rebound = try ComputerUseBrowserPopupIntent(interpretation: intent.interpretation,
            evidence: .init(document: evidence.document, documentID: evidence.documentID, page: changed), controlID: intent.controlID, requirementIndex: 1)
        XCTAssertNotEqual(rebound.baselineDigest, intent.baselineDigest)
        let target = try await fixture.browser.preparePopup(intent)
        XCTAssertNotEqual(target.payloadDigest, ComputerUseBrowserPopupTarget(intent: rebound, binding: target.binding).payloadDigest)
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let stage = try ComputerUseBrowserPopupStage(target: target, sequence: 0, browser: fixture.browser, journalDirectory: directory)
        let receipt = try await stage.run(checkCurrent: {})
        XCTAssertEqual(receipt.preservedControlIDs, [dateID]); XCTAssertTrue(receipt.validates(target, operationID: stage.operationID))
        let forged = ComputerUseBrowserPopupReceipt(operationID: receipt.operationID, bindingID: receipt.bindingID,
            controlID: receipt.controlID, documentID: receipt.documentID, preservedControlIDs: [])
        XCTAssertFalse(forged.validates(target, operationID: stage.operationID))
        let saved = try XCTUnwrap(ComputerUseTaskJournalStore(directory: directory).load(taskID: stage.contract.taskID))
        XCTAssertEqual(saved.statuses, [.verified]); XCTAssertEqual(stage.contract.steps[0].operation.payloadVersion, 2)
        let data = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        for value in ["2026-09-20", "General admission", "privateUnscoped", target.binding.id, prompt] { XCTAssertFalse(data.contains(value)) }
        try await fixture.wait { fixture.server.count("/opened") == 1 }
        XCTAssertEqual(fixture.server.count("/chosen"), 0)
    }

    func testOpeningCannotResetReplaceOrReinsertAnObservedCriterion() async throws {
        let changes = [
            "document.getElementById('date').value='2026-09-21';",
            "const date=document.getElementById('date'); date.replaceWith(date.cloneNode(true));",
            "const date=document.getElementById('date'), parent=date.parentNode; date.remove(); parent.appendChild(date);",
            "document.getElementById('date').setAttribute('readonly',''); document.getElementById('date').disabled=true;"
        ]
        for change in changes {
            let fixture = try await ControlStateFixture(body: page(extraOpening: change))
            defer { fixture.close() }
            let target = try await fixture.browser.preparePopup(intent(fixture))
            try await fixture.browser.dispatchPopup(target, operationID: operation, willBeginEffect: {})
            do { _ = try await fixture.browser.popupReceipt(target, operationID: operation); XCTFail("Opening must preserve the original criterion and native objects") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserPopupError, .uncertain) }
            try await fixture.browser.dispatchPopup(target, operationID: operation, willBeginEffect: {})
            let retired = try await fixture.browser.retireUnsentPopup(target, operationID: operation)
            XCTAssertFalse(retired)
            try await fixture.wait { fixture.server.count("/opened") == 1 }
            XCTAssertEqual(fixture.server.count("/chosen"), 0)
        }
    }

    func testOpeningCannotChangeAnExistingSelectionOrNativeComboboxValue() async throws {
        let selection = "document.getElementById('first').setAttribute('aria-selected','false'); document.getElementById('second').setAttribute('aria-selected','true');"
        let input = "document.getElementById('combo').value='Overwritten';"
        for isInput in [false, true] {
            var body = page(extraOpening: isInput ? input : selection)
            if isInput {
                body = body.replacingOccurrences(of: "<button id=combo type=button", with: "<input id=combo type=text value=Original")
                    .replacingOccurrences(of: "<span id=display>Choose type</span></button>", with: "")
            }
            let fixture = try await ControlStateFixture(body: body)
            defer { fixture.close() }
            let target = try await fixture.browser.preparePopup(intent(fixture))
            try await fixture.browser.dispatchPopup(target, operationID: operation, willBeginEffect: {})
            do { _ = try await fixture.browser.popupReceipt(target, operationID: operation); XCTFail("Opening cannot change the owner's existing value") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserPopupError, .uncertain) }
            try await fixture.wait { fixture.server.count("/opened") == 1 }
        }
    }

    func testARequestedUnavailableCriterionCannotDisappearFromEitherEffectBaseline() async throws {
        for opening in [false, true] {
            let body = (opening ? page() : OptionSelectionFixture.page()).replacingOccurrences(of: "type=date readonly value=2026-09-20",
                with: "type=text readonly value='" + String(repeating: "x", count: 2049) + "'")
            let fixture = try await ControlStateFixture(body: body)
            defer { fixture.close() }
            let evidence = try await scoped(fixture), goal = try interpretation(taskID: fixture.document.taskID)
            let owner = try XCTUnwrap(evidence.page.controls.first { $0.label == "Ticket type" })
            let date = try XCTUnwrap(evidence.page.controls.first { $0.label == "Date" })
            XCTAssertEqual(evidence.page.controlStates.first { $0.controlID == date.id }?.kind, .unavailable)
            if opening {
                XCTAssertThrowsError(try ComputerUseBrowserPopupIntent(interpretation: goal, evidence: evidence, controlID: owner.id, requirementIndex: 1))
                let candidates = try await fixture.browser.popupControlIDs(in: evidence)
                XCTAssertTrue(candidates.isEmpty)
            } else {
                let candidates = try await fixture.browser.optionSelectionChoices(in: evidence)
                XCTAssertTrue(candidates.isEmpty)
                let value = try XCTUnwrap(evidence.page.controlStates.first { $0.controlID == owner.id }?.value)
                let reading = try XCTUnwrap(ComputerUseBrowserOptionSelectionState.read(value, control: owner))
                let option = try XCTUnwrap(reading.options.last?["id"] as? String)
                XCTAssertFalse(ComputerUseBrowserOptionSelectionChoice(controlID: owner.id, optionIDs: [option]).isValid(in: evidence))
                XCTAssertThrowsError(try ComputerUseBrowserOptionSelectionIntent(interpretation: goal, evidence: evidence,
                    controlID: owner.id, optionID: option, requirementIndex: 1))
            }
            XCTAssertEqual(fixture.server.count("/opened"), 0); XCTAssertEqual(fixture.server.count("/chosen"), 0)
        }
    }

    func testAnObservedResetStaysUncertainAfterRestorationAndStageReopening() async throws {
        let violations = [
            ("document.getElementById('date').value='2026-09-21';", "document.getElementById('date').value='2026-09-20';"),
            ("document.getElementById('combo').setAttribute('aria-label','Different purpose');", "document.getElementById('combo').setAttribute('aria-label','Ticket type');")
        ]
        for (change, restore) in violations {
            let fixture = try await ControlStateFixture(body: page(extraOpening: change)
                + OptionSelectionFixture.signal(restore), heldSignal: true)
            defer { fixture.close() }
            let target = try await fixture.browser.preparePopup(intent(fixture)), directory = scratch()
            defer { try? FileManager.default.removeItem(at: directory) }
            let stage = try ComputerUseBrowserPopupStage(target: target, sequence: 0, browser: fixture.browser,
                journalDirectory: directory, confirmationBudget: .zero)
            do { _ = try await stage.run(checkCurrent: {}); XCTFail("The first observed reset must remain unresolved") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserPopupError, .uncertain) }
            try await fixture.wait { fixture.server.count("/signal") == 1 }; fixture.server.releaseHeldResponses()
            try await fixture.wait { fixture.server.count("/changed") == 1 }
            let reopened = try stage.reopened(makeStore: { try .init(directory: $0) })
            do { _ = try await reopened.run(checkCurrent: {}); XCTFail("Restoration cannot erase the original violation") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserPopupError, .uncertain) }
            let saved = try XCTUnwrap(ComputerUseTaskJournalStore(directory: directory).load(taskID: stage.contract.taskID))
            XCTAssertEqual(saved.statuses, [.uncertain]); XCTAssertEqual(saved.contractDigest, stage.contract.contractDigest)
            XCTAssertEqual(fixture.server.count("/opened"), 1)
        }
    }

    private func interpretation(taskID: String) throws -> ComputerUseBrowserGoalProposal {
        let goal = try ComputerUseBrowserGoalInput(taskID: taskID, prompt: prompt,
            referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
        return try .decode(content: goalJSON(), input: goal)
    }
    private func goalJSON() throws -> String {
        try ResearchAnswerFixture.json(["disposition":"research","requirements":[
            ["turn":0,"source":"Find concerts. ","role":"outcome","field":"category","relation":"unspecified","values":[]],
            ["turn":0,"source":"Use general admission. ","role":"condition","field":"other","relation":"unspecified","values":[]],
            ["turn":0,"source":"Keep date unchanged. ","role":"condition","field":"other","relation":"unspecified","values":[]],
            ["turn":0,"source":"Do not buy.","role":"prohibition","field":"other","relation":"unspecified","values":[]]],
            "question":["topic":"none","requirements":[]]])
    }
    private func scoped(_ fixture: ControlStateFixture) async throws -> ComputerUseBrowserPageEvidence {
        let metadata = try await fixture.browser.observePage(document: fixture.document)
        let input = try ComputerUseBrowserActionInput(interpretation: interpretation(taskID: fixture.document.taskID), evidence: metadata,
            navigationHistory: [], formHistory: [], latestForm: nil, changedFormTargetIDs: [], allowOptionInspection: true)
        let proposal = try ComputerUseBrowserActionProposal.decode(content: scope(input, inspection: true), input: input)
        return try await fixture.browser.observeResearchControls(for: proposal)
    }
    private func intent(_ fixture: ControlStateFixture) async throws -> ComputerUseBrowserPopupIntent {
        let evidence = try await scoped(fixture), owner = try XCTUnwrap(evidence.page.controls.first { $0.label == "Ticket type" })
        return try .init(interpretation: interpretation(taskID: fixture.document.taskID), evidence: evidence, controlID: owner.id, requirementIndex: 1)
    }
    private func page(extraOpening: String = "") -> String {
        let handler = "this.setAttribute('aria-expanded','true'); document.getElementById('choices').hidden=false; " + extraOpening + " fetch('/opened');"
        return OptionSelectionFixture.page()
            .replacingOccurrences(of: "aria-expanded=true", with: "aria-expanded=false onclick=\"" + handler + "\"")
            .replacingOccurrences(of: "id=choices role=listbox", with: "id=choices role=listbox hidden")
            .replacingOccurrences(of: "<h2>Concert Alpha</h2>", with: "<h2>Concert Alpha</h2><a href='/details'>Alpha details</a>")
    }

    private func scope(_ input: ComputerUseBrowserActionInput, inspection: Bool) throws -> String {
        let owner = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Ticket type" })
        let date = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Date" })
        let rows: [[String: Any]] = [["control":owner.id,"requirement":1],["control":date.id,"requirement":2]]
        let proposal: [String: Any] = inspection ? ["inspect_options":rows] : ["read_results":true,"read_controls":rows]
        return try ResearchAnswerFixture.json(proposal)
    }
    private func opening(_ id: String) -> String { "{\"open_popup\":{\"control\":\"\(id)\",\"requirement\":1}}" }

    private func scratch() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("popup-criteria-" + UUID().uuidString) }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

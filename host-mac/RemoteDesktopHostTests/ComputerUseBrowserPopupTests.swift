import Foundation
import XCTest
@testable import RemoteDesktopHost

/// Prepared native/journal coverage. These fixtures do not qualify a provider
/// or the natural-language driver, whose source integration is unqualified.
@MainActor
final class ComputerUseBrowserPopupTests: XCTestCase {
    func testPreparationIsReadOnlyIdempotentAndBoundToAnOriginalResearchRequirement() async throws {
        let fixture = try await ControlStateFixture(body: page())
        defer { fixture.close() }
        let intent = try await intent(fixture)
        let first = try await fixture.browser.preparePopup(intent)
        let second = try await fixture.browser.preparePopup(intent)
        XCTAssertEqual(first, second); XCTAssertTrue(first.binding.isWellFormed)
        try await fixture.browser.validatePopup(first)
        XCTAssertEqual(fixture.server.count("/opened"), 0)
        XCTAssertEqual(String(reflecting: intent), "BrowserPopupIntent")
        XCTAssertEqual(String(reflecting: first), "BrowserPopupTarget")
        XCTAssertThrowsError(try ComputerUseBrowserPopupIntent(interpretation: intent.interpretation, evidence: intent.evidence,
            controlID: intent.controlID, requirementIndex: 2))
        XCTAssertThrowsError(try ComputerUseBrowserPopupIntent(interpretation: intent.interpretation, evidence: intent.evidence,
            controlID: "c999", requirementIndex: 1))
        let result = try await fixture.browser.callDOM(.openPopup, arguments: ["documentID":intent.evidence.documentID,
            "snapshotID":intent.evidence.page.id, "bindingID":first.binding.id, "controlID":intent.controlID,
            "operationID":[String(repeating: "a", count: 64)]], document: fixture.document)
        XCTAssertEqual(result.status, "stale", "A value coercible to an ID must not authorize activation")
        XCTAssertEqual(fixture.server.count("/opened"), 0)
    }

    func testOpeningPersistsAttemptBeforeDispatchAndRepeatedCallsCannotClickAgain() async throws {
        let fixture = try await ControlStateFixture(body: page())
        defer { fixture.close() }
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let target = try await fixture.browser.preparePopup(intent(fixture))
        var stageReference: ComputerUseBrowserPopupStage?
        let stage = try ComputerUseBrowserPopupStage(target: target, sequence: 0, browser: fixture.browser, journalDirectory: directory,
            beforeDispatch: {
                let current = try XCTUnwrap(stageReference)
                let saved = try XCTUnwrap(ComputerUseTaskJournalStore(directory: directory).load(taskID: current.contract.taskID))
                XCTAssertEqual(saved.statuses, [.attempted]); XCTAssertEqual(saved.contractDigest, current.contract.contractDigest)
                XCTAssertEqual(fixture.server.count("/opened"), 0)
            })
        stageReference = stage
        defer { stageReference = nil }
        let receipt = try await stage.run(checkCurrent: {})
        XCTAssertTrue(receipt.validates(target, operationID: stage.operationID))
        try await fixture.wait { fixture.server.count("/opened") == 1 }
        let repeated = try await stage.run(checkCurrent: {})
        XCTAssertEqual(repeated, receipt)
        try await fixture.browser.dispatchPopup(target, operationID: stage.operationID, willBeginEffect: {})
        do {
            try await fixture.browser.dispatchPopup(target, operationID: String(repeating: "b", count: 64), willBeginEffect: {})
            XCTFail("A second operation cannot reuse a consumed binding")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserPopupError, .uncertain) }
        let retired = try await stage.retireUnsent(checkCurrent: {})
        XCTAssertNil(retired); XCTAssertEqual(fixture.server.count("/opened"), 1)
        XCTAssertEqual(try journal(stage, directory).statuses, [.verified])
        XCTAssertEqual(target.intent.interpretation.input.prompt, "Find concerts. Inspect ticket types. Do not buy.")
    }

    func testCancelledBeforeNativeDispatchResumesOnlyTheOriginalJournaledOperation() async throws {
        let fixture = try await ControlStateFixture(body: page())
        defer { fixture.close() }
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let target = try await fixture.browser.preparePopup(intent(fixture))
        var dispatchHooks = 0
        let stage = try ComputerUseBrowserPopupStage(target: target, sequence: 0, browser: fixture.browser, journalDirectory: directory,
            beforeDispatch: { dispatchHooks += 1; throw CancellationError() })
        do { _ = try await stage.run(checkCurrent: {}); XCTFail("The interrupted boundary must not activate the page") }
        catch { XCTAssertTrue(error is CancellationError) }
        let before = try journal(stage, directory)
        XCTAssertEqual(before.statuses, [.attempted]); XCTAssertEqual(fixture.server.count("/opened"), 0)
        let receipt = try await stage.run(checkCurrent: {})
        try await fixture.wait { fixture.server.count("/opened") == 1 }
        XCTAssertEqual(dispatchHooks, 1, "Recovery must use the native ledger continuation, not perform again")
        XCTAssertEqual(receipt.operationID, stage.operationID)
        let after = try journal(stage, directory)
        XCTAssertEqual(after.contractDigest, before.contractDigest); XCTAssertEqual(after.statuses, [.verified])
    }

    func testUnconfirmedAndLateOpeningsCannotBeReplayedOrClaimedAsFreshReceipts() async throws {
        let fixture = try await ControlStateFixture(body: page(handler: """
            fetch('/opened'); setTimeout(() => { this.setAttribute('aria-expanded','true');
            document.getElementById('choices').hidden=false; fetch('/late'); },2300);
            """))
        defer { fixture.close() }
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let target = try await fixture.browser.preparePopup(intent(fixture))
        let stage = try ComputerUseBrowserPopupStage(target: target, sequence: 0, browser: fixture.browser,
            journalDirectory: directory, confirmationBudget: .zero)
        do { _ = try await stage.run(checkCurrent: {}); XCTFail("An event alone is not an opening receipt") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserPopupError, .uncertain) }
        try await fixture.wait { fixture.server.count("/opened") == 1 }
        do { _ = try await stage.run(checkCurrent: {}); XCTFail("Rechecking cannot replay the click") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserPopupError, .uncertain) }
        try await fixture.wait { fixture.server.count("/late") == 1 }
        do { _ = try await stage.run(checkCurrent: {}); XCTFail("The original native confirmation window cannot restart") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserPopupError, .uncertain) }
        let retired = try await stage.retireUnsent(checkCurrent: {})
        XCTAssertNil(retired); XCTAssertNil(stage.completedReceipt)
        XCTAssertEqual(fixture.server.count("/opened"), 1)
        XCTAssertEqual(try journal(stage, directory).statuses, [.uncertain])
    }

    func testChangedUnsentTargetRequiresDurableRetirementBeforeFreshPreparation() async throws {
        let fixture = try await ControlStateFixture(body: page() + """
            <script>fetch('/signal').then(() => { const old=document.getElementById('combo');
            old.replaceWith(old.cloneNode(true)); fetch('/changed'); });</script>
            """, heldSignal: true)
        defer { fixture.close() }
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let target = try await fixture.browser.preparePopup(intent(fixture))
        let stage = try ComputerUseBrowserPopupStage(target: target, sequence: 0, browser: fixture.browser, journalDirectory: directory,
            beforeDispatch: {
                try await fixture.wait { fixture.server.count("/signal") == 1 }
                fixture.server.releaseHeldResponses()
                try await fixture.wait { fixture.server.count("/changed") == 1 }
            })
        do { _ = try await stage.run(checkCurrent: {}); XCTFail("An identical replacement is a different native target") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserPopupError, .uncertain) }
        let before = try journal(stage, directory)
        XCTAssertEqual(before.statuses, [.uncertain]); XCTAssertEqual(fixture.server.count("/opened"), 0)
        let retirement = try await stage.retireUnsent(checkCurrent: {})
        let after = try journal(stage, directory)
        XCTAssertNotNil(retirement); XCTAssertEqual(after.retirementDigest, retirement)
        XCTAssertEqual(after.statuses, before.statuses); XCTAssertEqual(after.contractDigest, before.contractDigest)
        do { _ = try await stage.run(checkCurrent: {}); XCTFail("Retirement is final for this stage") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserPopupError, .retired) }
        do {
            try await fixture.browser.dispatchPopup(target, operationID: stage.operationID, willBeginEffect: {})
            XCTFail("The native tombstone must revoke the old binding")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserPopupError, .uncertain) }
        let fresh = try await fixture.browser.preparePopup(intent(fixture))
        let next = try ComputerUseBrowserPopupStage(target: fresh, sequence: 1, browser: fixture.browser, journalDirectory: directory)
        let receipt = try await next.run(checkCurrent: {})
        try await fixture.wait { fixture.server.count("/opened") == 1 }
        XCTAssertNotEqual(receipt.operationID, stage.operationID)
        XCTAssertEqual(fresh.intent.interpretation.input, target.intent.interpretation.input)
    }

    func testSubmitLinksProtectedAndAmbiguousPopupTargetsAreNotActivated() async throws {
        let ordinary = page()
        let bodies = [
            ordinary.replacingOccurrences(of: "type=button", with: ""),
            "<a href='/opened'>" + ordinary + "</a>",
            ordinary.replacingOccurrences(of: "aria-label='Ticket types' hidden", with: "aria-label='Ticket types'"),
            ordinary + "<div id=choices role=listbox hidden>Duplicate</div>",
            ordinary.replacingOccurrences(of: "role=listbox", with: "role=grid"),
            ordinary.replacingOccurrences(of: "aria-label='Ticket type'", with: "aria-label='Account password'"),
            ordinary.replacingOccurrences(of: "aria-label='Ticket types'", with: "aria-label='Account password'"),
            ordinary.replacingOccurrences(of: "aria-expanded=false", with: "aria-expanded=false aria-disabled=true"),
            ordinary.replacingOccurrences(of: "aria-expanded=false", with: "aria-expanded=false aria-disabled=invalid"),
            ordinary.replacingOccurrences(of: "type=button", with: "type=button popovertarget=choices")]
        for body in bodies {
            let fixture = try await ControlStateFixture(body: body)
            defer { fixture.close() }
            do { _ = try await fixture.browser.preparePopup(intent(fixture)); XCTFail("Unsupported popup must have no executable binding") }
            catch {
                XCTAssertTrue(error is ComputerUseBrowserPopupError || error as? ComputerUseBrowserError == .authenticationRequired)
            }
            XCTAssertEqual(fixture.server.count("/opened"), 0)
        }
    }

    func testReplacementOrAuthenticationAfterDispatchCannotBecomeAnOpeningReceipt() async throws {
        let changes: [(login: Bool, script: String)] = [
            (false, "const old=document.getElementById('choices'), next=old.cloneNode(true); old.replaceWith(next);"),
            (false, "this.setAttribute('aria-owns','other');"),
            (false, "this.setAttribute('aria-label','Different purpose');"),
            (false, "document.body.appendChild(this);"),
            (true, "document.body.insertAdjacentHTML('beforeend','<label>Password<input type=password></label>');")]
        for change in changes {
            let handler = change.script + "this.setAttribute('aria-expanded','true'); document.getElementById('choices').hidden=false; fetch('/opened');"
            let fixture = try await ControlStateFixture(body: page(handler: handler))
            defer { fixture.close() }
            let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
            let target = try await fixture.browser.preparePopup(intent(fixture))
            let stage = try ComputerUseBrowserPopupStage(target: target, sequence: 0, browser: fixture.browser, journalDirectory: directory)
            for _ in 0..<2 {
                do { _ = try await stage.run(checkCurrent: {}); XCTFail("Changed authority cannot establish this receipt") }
                catch {
                    if change.login { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
                    else { XCTAssertEqual(error as? ComputerUseBrowserPopupError, .uncertain) }
                }
            }
            try await fixture.wait { fixture.server.count("/opened") == 1 }
            XCTAssertNil(stage.completedReceipt); XCTAssertEqual(try journal(stage, directory).statuses, [.uncertain])
        }
    }

    func testFailedAttemptWriteNeedsFreshStoreAndKeepsTheOriginalNativeOperation() async throws {
        let fixture = try await ControlStateFixture(body: page())
        defer { fixture.close() }
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let target = try await fixture.browser.preparePopup(intent(fixture))
        var failures = 0
        let first = try ComputerUseBrowserPopupStage(target: target, sequence: 0, browser: fixture.browser, journalDirectory: directory,
            makeStore: { try .init(directory: $0, afterReplacement: { failures += 1; throw PopupWriteFailure.interrupted }) })
        do { _ = try await first.run(checkCurrent: {}); XCTFail("An unconfirmed disk write cannot activate the page") }
        catch { XCTAssertTrue(error is PopupWriteFailure) }
        XCTAssertEqual(failures, 1); XCTAssertEqual(fixture.server.count("/opened"), 0)
        XCTAssertEqual(try journal(first, directory).statuses, [.attempted])
        first.retire()
        let reopened = try ComputerUseBrowserPopupStage(target: target, sequence: 0, browser: fixture.browser, journalDirectory: directory)
        XCTAssertEqual(reopened.contract.contractDigest, first.contract.contractDigest)
        XCTAssertEqual(reopened.contract.taskID, first.contract.taskID); XCTAssertEqual(reopened.operationID, first.operationID)
        let receipt = try await reopened.run(checkCurrent: {})
        try await fixture.wait { fixture.server.count("/opened") == 1 }
        XCTAssertEqual(receipt.operationID, first.operationID)
        XCTAssertEqual(try journal(reopened, directory).statuses, [.verified])
    }

    func testAuthenticationBeforePreflightRemainsTypedAndCannotCreateAnAttempt() async throws {
        let fixture = try await ControlStateFixture(body: page() + """
            <script>fetch('/signal').then(() => { document.body.insertAdjacentHTML('beforeend',
            '<label>Password<input type=password></label>'); fetch('/changed'); });</script>
            """, heldSignal: true)
        defer { fixture.close() }
        let directory = scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let target = try await fixture.browser.preparePopup(intent(fixture))
        let stage = try ComputerUseBrowserPopupStage(target: target, sequence: 0, browser: fixture.browser, journalDirectory: directory)
        try await fixture.wait { fixture.server.count("/signal") == 1 }
        fixture.server.releaseHeldResponses()
        try await fixture.wait { fixture.server.count("/changed") == 1 }
        do { _ = try await stage.run(checkCurrent: {}); XCTFail("Login must reach the handoff boundary before an attempt") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        let saved = try ComputerUseTaskJournalStore(directory: directory).load(taskID: stage.contract.taskID)
        XCTAssertNil(saved); XCTAssertNil(stage.completedReceipt); XCTAssertEqual(fixture.server.count("/opened"), 0)
    }

    private func intent(_ fixture: ControlStateFixture) async throws -> ComputerUseBrowserPopupIntent {
        let evidence = try await fixture.browser.observePage(document: fixture.document)
        let goal = try ComputerUseBrowserGoalInput(taskID: fixture.document.taskID,
            prompt: "Find concerts. Inspect ticket types. Do not buy.",
            referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
        let rows: [[String: Any]] = [
            ["turn":0, "source":"Find concerts. ", "role":"outcome", "field":"category", "relation":"unspecified", "values":[]],
            ["turn":0, "source":"Inspect ticket types. ", "role":"condition", "field":"other", "relation":"unspecified", "values":[]],
            ["turn":0, "source":"Do not buy.", "role":"prohibition", "field":"other", "relation":"unspecified", "values":[]]]
        let interpretation = try ComputerUseBrowserGoalProposal.decode(content: ResearchAnswerFixture.json([
            "disposition":"research", "requirements":rows, "question":["topic":"none", "requirements":[]]]), input: goal)
        guard let control = evidence.page.controls.first(where: { $0.compositeRole == "combobox" }) else {
            throw ComputerUseBrowserPopupError.unavailable
        }
        let input = try ComputerUseBrowserActionInput(interpretation: interpretation, evidence: evidence,
            navigationHistory: [], formHistory: [], latestForm: nil, changedFormTargetIDs: [])
        let read = try ComputerUseBrowserActionProposal.decode(content: ResearchAnswerFixture.json([
            "read_results":true,"read_controls":[["control":control.id,"requirement":1]]]), input: input)
        let scoped = try await fixture.browser.observeResearchControls(for: read)
        return try .init(interpretation: interpretation, evidence: scoped, controlID: control.id, requirementIndex: 1)
    }
    private func page(handler: String = "this.setAttribute('aria-expanded','true'); document.getElementById('choices').hidden=false; fetch('/opened');") -> String {
        """
        <article><h2>Concert Alpha</h2><button id=combo type=button role=combobox aria-label='Ticket type'
        aria-controls=choices aria-expanded=false onclick="\(handler)">Show choices</button>
        <div id=choices role=listbox aria-label='Ticket types' hidden><div role=option aria-selected=false>General admission</div></div></article>
        """
    }
    private func scratch() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("popup-stage-" + UUID().uuidString, isDirectory: true) }
    private func journal(_ stage: ComputerUseBrowserPopupStage, _ directory: URL) throws -> ComputerUseTaskJournal {
        try XCTUnwrap(ComputerUseTaskJournalStore(directory: directory).load(taskID: stage.contract.taskID))
    }
}

private enum PopupWriteFailure: Error { case interrupted }

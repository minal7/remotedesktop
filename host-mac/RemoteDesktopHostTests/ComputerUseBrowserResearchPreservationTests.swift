import Foundation
import XCTest
@testable import RemoteDesktopHost

/// Authored decisions and native fixture coverage, prepared but not executed.
@MainActor
final class ComputerUseBrowserResearchPreservationTests: XCTestCase {
    func testSameDocumentFormReplacementReplansUnusedFieldsAfterExplicitHandback() async throws {
        for captured in [false, true] {
            for replaceForm in [false, true] {
                let mutation = replaceForm
                    ? "const old=document.querySelector('form'); const next=old.cloneNode(true); next.querySelector('input').value='replacement-private-default'; old.replaceWith(next);"
                    : "const old=document.querySelector('input'); const next=old.cloneNode(true); next.value='replacement-private-default'; old.replaceWith(next);"
                let fixture = try await unusedIntentFixture(mutation: mutation)
                defer { fixture.close() }
                let owner: ComputerUseBrowserResearchTask, originalPage: ComputerUseBrowserPageEvidence
                var oldInput: ComputerUseBrowserResearchFormInput?, oldProposal: ComputerUseBrowserFormProposal?
                if captured {
                    _ = try await fixture.start(); configureUnusedIntent(fixture)
                    owner = try fixture.owner()
                    let action = try await owner.planNextAction(using: fixture.actions)
                    originalPage = action.input.evidence
                    let input = try await owner.prepareFormInput(for: action)
                    oldInput = input; oldProposal = try ComputerUseBrowserFormProposal.decode(content: plan(input), input: input)
                    owner.pause()
                } else {
                    originalPage = try await pauseUnusedIntent(fixture).input.evidence; owner = try fixture.owner()
                }
                let goal = owner.input
                try await release(fixture); try await owner.resumeAfterUserControl()
                let recovered = try await owner.recoverPendingFormPreparationCriteria()
                XCTAssertTrue(recovered)
                XCTAssertFalse(owner.hasPendingFormPreparation); XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
                let record = try XCTUnwrap(owner.unusedFormIntentHistory.first)
                XCTAssertEqual(record.retirementReason, .formStructureChanged)
                XCTAssertEqual(record.observation, captured ? .initialEditPreconditions : .none)
                if let oldInput, let oldProposal { await expectFailure { _ = try await owner.executeForm(oldProposal, input: oldInput) } }
                XCTAssertFalse(fixture.state.commands.contains(.edit))
                let oldTarget = oldInput?.evidence.fields.first?.editable.snapshot.targetID
                fixture.forms.select = { fresh in
                    XCTAssertEqual(fresh.evidence.page.documentID, originalPage.documentID)
                    XCTAssertEqual(fresh.evidence.fields.first?.editable.snapshot.value, "replacement-private-default")
                    if let oldTarget { XCTAssertNotEqual(fresh.evidence.fields.first?.editable.snapshot.targetID, oldTarget) }
                    return try self.plan(fresh)
                }
                configureUnusedIntent(fixture, stopAfterStage: true)
                _ = try await fixture.resume()
                XCTAssertEqual(owner.input, goal); XCTAssertEqual(fixture.search.inputs.count, 1)
                XCTAssertEqual(owner.confirmedFormHistory.map(\.index), [0])
                XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, captured ? 2 : 1)
                XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
                let input = try XCTUnwrap(fixture.actions.inputs.last { $0.usesUnusedFormIntentHistoryContext })
                let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.contextJSON.utf8)) as? [String: Any])
                XCTAssertEqual(context["version"] as? Int, 31)
                let history = try XCTUnwrap(context["unused_form_intent_history"] as? [[String: Any]])
                XCTAssertEqual(history.first?["retirement_reason"] as? String, "form_structure_changed")
                XCTAssertFalse(input.contextJSON.contains("replacement-private-default"))
            }
        }
    }

    func testFormReplacementAfterHandbackCannotRetireUntilAnotherExplicitHandback() async throws {
        let fixture = try await unusedIntentFixture(mutation: "const old=document.querySelector('input'); old.replaceWith(old.cloneNode(true));")
        defer { fixture.close() }
        let oldPage = try await pauseUnusedIntent(fixture).input.evidence, owner = try fixture.owner()
        try await owner.resumeAfterUserControl()
        try await release(fixture)
        do { _ = try await owner.recoverPendingFormPreparationCriteria(); XCTFail("Post-handback structure cannot reuse the earlier seal") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        XCTAssertTrue(owner.hasPendingFormPreparation); XCTAssertTrue(owner.unusedFormIntentHistory.isEmpty)
        XCTAssertFalse(fixture.state.commands.contains(.formFields)); XCTAssertFalse(fixture.state.commands.contains(.edit))
        owner.pause(); try await owner.resumeAfterUserControl()
        let recovered = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertTrue(recovered)
        XCTAssertEqual(owner.unusedFormIntentHistory.first?.retirementReason, .formStructureChanged)
        let action = try await owner.planNextAction(using: fixture.actions)
        XCTAssertEqual(action.input.evidence.documentID, oldPage.documentID)
    }

    func testValueOnlyChangesDoNotRetireAnUnusedPreparationAsAChangedForm() async throws {
        for captured in [false, true] {
            let fixture = try await unusedIntentFixture(mutation: "document.querySelector('input').value='manual-private-value';")
            defer { fixture.close() }
            let owner: ComputerUseBrowserResearchTask
            if captured {
                _ = try await fixture.start(); configureUnusedIntent(fixture); owner = try fixture.owner()
                let action = try await owner.planNextAction(using: fixture.actions)
                _ = try await owner.prepareFormInput(for: action); owner.pause()
            } else { _ = try await pauseUnusedIntent(fixture); owner = try fixture.owner() }
            try await release(fixture); try await owner.resumeAfterUserControl()
            _ = try? await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(owner.hasPendingFormPreparation); XCTAssertTrue(owner.unusedFormIntentHistory.isEmpty)
            XCTAssertTrue(owner.confirmedFormHistory.isEmpty); XCTAssertFalse(fixture.state.commands.contains(.edit))
        }
    }

    func testUnusedFormStructureRequiresCompleteMetadataAndTracksNativeMembershipOnly() {
        typealias Structure = ComputerUseBrowserUnusedFormIntent.FormStructure
        func page(id: String = "field1", label: String = "Query", formID: String = "form1", omitted: Bool = false, unavailableValues: Bool = false, truncated: Bool = false) -> ComputerUseBrowserPageSnapshot {
            let form = ComputerUseBrowserPageSnapshot.Control.Form(id: formID, method: "get", action: "https://private.test/search", target: "", encoding: "application/x-www-form-urlencoded", noValidate: false)
            let control = ComputerUseBrowserPageSnapshot.Control(id: id, containerID: "container", label: label, kind: "text", name: "query",
                disabled: false, readOnly: false, required: false, multiple: false, constraints: [:], options: [], form: form)
            return .init(id: "snapshot", texts: [], links: [], controls: [control], truncated: truncated,
                omittedEmbeddedContent: false, omittedControls: omitted || unavailableValues, omittedControlMetadata: omitted)
        }
        let original = Structure(page())
        XCTAssertNotNil(original); XCTAssertEqual(original?.controlsByForm, ["form1":Set(["field1"])])
        XCTAssertEqual(original, Structure(page(label: "Changed label")))
        XCTAssertEqual(original, Structure(page(unavailableValues: true)))
        XCTAssertNotEqual(original, Structure(page(id: "field2")))
        XCTAssertNotEqual(original, Structure(page(formID: "form2")))
        XCTAssertNil(Structure(page(omitted: true))); XCTAssertNil(Structure(page(truncated: true)))
    }

    func testCompletedUnusedPreparationReplansFreshDefaultsAfterHandbackWithoutReplayingTheOldProposal() async throws {
        let fixture = try await unusedIntentFixture()
        defer { fixture.close() }
        _ = try await fixture.start(); configureUnusedIntent(fixture)
        let owner = try fixture.owner(), original = owner.input
        let action = try await owner.planNextAction(using: fixture.actions)
        let input = try await owner.prepareFormInput(for: action)
        let oldProposal = try ComputerUseBrowserFormProposal.decode(content: plan(input), input: input)
        XCTAssertTrue(owner.hasPendingFormPreparation); XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
        owner.pause()
        _ = try await fixture.browser.navigate(taskID: owner.taskID, operationID: "fixture-captured-handoff", to: fixture.base.appendingPathComponent("details"))
        try await owner.resumeAfterUserControl()
        let recovered = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertTrue(recovered); XCTAssertFalse(owner.hasPendingFormPreparation)
        XCTAssertEqual(owner.unusedFormIntentHistory.first?.observation, .initialEditPreconditions)
        await expectFailure { _ = try await owner.executeForm(oldProposal, input: input) }
        XCTAssertFalse(fixture.state.commands.contains(.edit)); XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
        fixture.forms.select = { fresh in
            XCTAssertNotEqual(fresh.evidence.page.documentID, input.evidence.page.documentID)
            XCTAssertEqual(fresh.evidence.fields.first?.editable.snapshot.value, "fresh-private-default")
            XCTAssertNotEqual(fresh.evidence.fields.first?.editable.snapshot.targetID, input.evidence.fields.first?.editable.snapshot.targetID)
            return try self.plan(fresh)
        }
        configureUnusedIntent(fixture, stopAfterStage: true)
        _ = try await fixture.resume()
        XCTAssertEqual(owner.input, original); XCTAssertEqual(fixture.search.inputs.count, 1)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.index), [0])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        let contextInput = try XCTUnwrap(fixture.actions.inputs.last { $0.usesUnusedFormIntentHistoryContext })
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contextInput.contextJSON.utf8)) as? [String: Any])
        let history = try XCTUnwrap(context["unused_form_intent_history"] as? [[String: Any]])
        XCTAssertEqual(context["version"] as? Int, 31)
        XCTAssertEqual(history.first?["values_observed"] as? Bool, true)
        XCTAssertEqual(history.first?["observation"] as? String, "initial_edit_preconditions")
        XCTAssertEqual(history.first?["old_adapter_retired"] as? Bool, true)
        XCTAssertEqual(history.first?["input_dispatched"] as? Bool, false)
        XCTAssertEqual(history.first?["current_field_verification"] as? Bool, false)
        XCTAssertFalse(contextInput.contextJSON.contains("fresh-private-default"))
    }

    func testPendingBindingReadBlocksUnusedRetirementUntilItsCancelledWaiterJoins() async throws {
        let fixture = try await unusedIntentFixture()
        defer { fixture.close() }
        _ = try await fixture.start(); configureUnusedIntent(fixture)
        let action = try await fixture.owner().planNextAction(using: fixture.actions)
        let frame = try ComputerUseBrowserResearchFormPreparation(action: action, browser: fixture.browser)
        var operation: Task<ComputerUseBrowserResearchFormInput, Error>?
        var interrupted = false
        fixture.state.onCommand = { command in
            guard command == .bindPageFields else { return }
            fixture.state.onCommand = nil; interrupted = true
            XCTAssertNil(frame.unusedInitialIntentObservation, "A dispatched binding read still owns its callback")
            do {
                try frame.retireUnusedInitialIntent(observation: .initialEditPreconditions)
                XCTFail("An in-flight binding read cannot retire its preparation")
            } catch { }
            operation?.cancel()
        }
        operation = Task { @MainActor in try await frame.prepare(browser: fixture.browser, checkCurrent: { try Task.checkCancellation() }) }
        let running = try XCTUnwrap(operation)
        await expectFailure { _ = try await running.value }
        XCTAssertTrue(interrupted)
        XCTAssertEqual(frame.unusedInitialIntentObservation, .initialEditPreconditions)
        XCTAssertTrue(frame.target.canRetireUnusedPreparation)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
        XCTAssertFalse(fixture.state.commands.contains(.edit))
    }

    func testRetiredUnusedAdapterRejectsReadsInputVerificationAndTransferOnItsStillCurrentDocument() async throws {
        let fixture = try await unusedIntentFixture()
        defer { fixture.close() }
        let (frame, input) = try await completedUnusedFrame(fixture)
        let snapshot = try XCTUnwrap(input.evidence.fields.first?.editable.snapshot)
        let statePlan = try ComputerUseBrowserFormStatePlan(input: input, proposal: .decode(content: plan(input), input: input))
        let capture = try ComputerUseBrowserDOMReadCapture(command: .verifyFormState, document: input.evidence.page.document)
        XCTAssertEqual(frame.unusedInitialIntentObservation, .initialEditPreconditions)
        let beforeRetirement = fixture.state.commands.count
        await expectFailure {
            _ = try await frame.restoreForReview(browser: fixture.browser, checkCurrent: {
                try frame.retireUnusedInitialIntent(observation: .initialEditPreconditions)
            })
        }
        XCTAssertEqual(fixture.state.commands.count, beforeRetirement, "Reentrant retirement blocks the pending review before observation")
        XCTAssertNil(frame.unusedInitialIntentObservation); XCTAssertFalse(frame.target.canRetireUnusedPreparation)
        let commands = fixture.state.commands.count
        await expectFailure { _ = try await frame.target.read(targetID: snapshot.targetID) }
        await expectFailure { try await frame.target.apply(.init(targetID: snapshot.targetID, mode: .replaceAll, text: "concerts"),
            expected: snapshot, operationID: "retired-initial-input") }
        await expectFailure { _ = try await frame.target.verifyFormState(statePlan, input: input, page: input.evidence.page, retaining: capture) }
        await expectFailure { _ = try await frame.prepare(browser: fixture.browser, checkCurrent: {}) }
        XCTAssertThrowsError(try frame.target.transferForClarification(taskID: "replacement-task"))
        XCTAssertThrowsError(try frame.target.retireUnusedPreparation())
        XCTAssertEqual(fixture.state.commands.count, commands, "Retirement blocks access before native dispatch even on the original page")
        XCTAssertFalse(capture.didStart)
    }

    func testCancelledInputAttemptCannotBecomeAnUnusedPreparationAgain() async throws {
        let fixture = try await unusedIntentFixture()
        defer { fixture.close() }
        let (frame, input) = try await completedUnusedFrame(fixture)
        let snapshot = try XCTUnwrap(input.evidence.fields.first?.editable.snapshot)
        var operation: Task<Void, Error>?
        var interrupted = false
        fixture.state.onCommand = { command in
            guard command == .edit else { return }
            fixture.state.onCommand = nil; interrupted = true
            XCTAssertFalse(frame.target.canRetireUnusedPreparation)
            XCTAssertNil(frame.unusedInitialIntentObservation)
            do {
                try frame.target.retireUnusedPreparation()
                XCTFail("An input attempt cannot retire as unused preparation")
            } catch { }
            operation?.cancel()
        }
        operation = Task { @MainActor in try await frame.target.apply(
            .init(targetID: snapshot.targetID, mode: .replaceAll, text: "concerts"), expected: snapshot, operationID: "initial-attempt") }
        let running = try XCTUnwrap(operation)
        await expectFailure { try await running.value }
        await frame.target.joinCompletion()
        XCTAssertTrue(interrupted); XCTAssertFalse(frame.target.canRetireUnusedPreparation)
        XCTAssertNil(frame.unusedInitialIntentObservation)
        XCTAssertThrowsError(try frame.retireUnusedInitialIntent(observation: .initialEditPreconditions))
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testDesiredValueVerificationAndFailedTransferRetainTheirIssuedAuthority() async throws {
        for verification in [false, true] {
            let fixture = try await unusedIntentFixture()
            defer { fixture.close() }
            let (frame, input) = try await completedUnusedFrame(fixture)
            XCTAssertEqual(frame.unusedInitialIntentObservation, .initialEditPreconditions)
            if verification {
                let plan = try ComputerUseBrowserFormStatePlan(input: input, proposal: .decode(content: self.plan(input), input: input))
                let capture = try ComputerUseBrowserDOMReadCapture(command: .verifyFormState, document: input.evidence.page.document)
                let current = try await frame.restoreForReview(browser: fixture.browser, checkCurrent: {})
                _ = try await frame.target.verifyFormState(plan, input: input, page: current, retaining: capture)
                XCTAssertTrue(capture.didStart)
            } else {
                XCTAssertThrowsError(try frame.target.transferForClarification(taskID: input.interpretation.input.taskID))
            }
            XCTAssertFalse(frame.target.canRetireUnusedPreparation)
            XCTAssertNil(frame.unusedInitialIntentObservation)
            XCTAssertThrowsError(try frame.target.retireUnusedPreparation())
            XCTAssertFalse(fixture.state.commands.contains(.edit))
        }
    }

    private func completedUnusedFrame(_ fixture: ResearchDriverFixture) async throws
        -> (ComputerUseBrowserResearchFormPreparation, ComputerUseBrowserResearchFormInput) {
        _ = try await fixture.start(); configureUnusedIntent(fixture)
        let action = try await fixture.owner().planNextAction(using: fixture.actions)
        let frame = try ComputerUseBrowserResearchFormPreparation(action: action, browser: fixture.browser)
        let input = try await frame.prepare(browser: fixture.browser, checkCurrent: {})
        return (frame, input)
    }

    func testInitialReadAbsenceDoesNotTreatPendingOrOrdinaryFailuresAsUnobserved() async throws {
        let fixture = try await ControlStateFixture(body: "<p>Metadata only</p>")
        defer { fixture.close() }
        for failure in [ComputerUseBrowserError.authenticationRequired, .pageChanged, .unsupportedDocument] {
            let capture = try ComputerUseBrowserDOMReadCapture(command: .formFields, document: fixture.document)
            XCTAssertTrue(capture.initialFieldsWereNotObserved)
            try capture.begin(command: .formFields, arguments: [:], document: fixture.document)
            XCTAssertFalse(capture.initialFieldsWereNotObserved, "A pending native read is not absence")
            XCTAssertNil(capture.completedInitialFieldRead); XCTAssertTrue(capture.hasPendingRead)
            capture.finish(.failure(failure))
            XCTAssertEqual(capture.initialFieldsWereNotObserved, failure == .authenticationRequired)
            XCTAssertNil(capture.completedInitialFieldRead); XCTAssertFalse(capture.hasPendingRead)
            XCTAssertTrue(capture.didStart, "Inspecting absence must not erase the original callback")
        }
        let cancelled = try ComputerUseBrowserDOMReadCapture(command: .formFields, document: fixture.document)
        try cancelled.begin(command: .formFields, arguments: [:], document: fixture.document)
        cancelled.finish(.failure(CancellationError()))
        XCTAssertFalse(cancelled.initialFieldsWereNotObserved)
        let revision = try ComputerUseBrowserDOMReadCapture(command: .reviseFormFields, document: fixture.document)
        XCTAssertFalse(revision.initialFieldsWereNotObserved, "An inherited revision cannot release the initial frame")
        let completed = try ComputerUseBrowserDOMReadCapture(command: .formFields, document: fixture.document)
        try completed.begin(command: .formFields, arguments: [:], document: fixture.document)
        let reply = try ComputerUseOwnedBrowser.decodeDOMReply(ResearchAnswerFixture.json([
            "status":"ok", "documentID":String(repeating: "a", count: 32), "inputLedgerID":String(repeating: "b", count: 32),
            "fields":[["id":"e1", "label":"Query", "value":"old", "selectionStart":3, "selectionEnd":3]]]), command: .formFields)
        completed.finish(.success(reply))
        XCTAssertFalse(completed.initialFieldsWereNotObserved)
        XCTAssertEqual(completed.completedInitialFieldRead?.documentID, String(repeating: "a", count: 32))
        XCTAssertEqual(completed.completedInitialFieldRead?.ledgerID, String(repeating: "b", count: 32))
    }

    func testUnobservedInitialIntentRetiresAfterHandbackAndFreshFieldsStartTheFirstStage() async throws {
        let fixture = try await unusedIntentFixture()
        defer { fixture.close() }
        let action = try await pauseUnusedIntent(fixture), owner = try fixture.owner(), original = owner.input
        await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
        _ = try await fixture.browser.navigate(taskID: owner.taskID, operationID: "fixture-manual-form", to: fixture.base.appendingPathComponent("details"))
        try await owner.resumeAfterUserControl()
        let recovered = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertTrue(recovered); XCTAssertFalse(owner.hasPendingFormPreparation)
        XCTAssertEqual(owner.unusedFormIntentHistory.count, 1)
        XCTAssertTrue(owner.confirmedFormHistory.isEmpty); XCTAssertTrue(owner.retiredFormHistory.isEmpty)
        XCTAssertFalse(fixture.state.commands.contains(.formFields)); XCTAssertFalse(fixture.state.commands.contains(.edit))
        let fresh = try await owner.planNextAction(using: fixture.actions)
        XCTAssertNotEqual(fresh.input.evidence.documentID, action.input.evidence.documentID)
        XCTAssertEqual(fresh.input.interpretation.input, original)
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fresh.input.contextJSON.utf8)) as? [String: Any])
        let history = try XCTUnwrap(context["unused_form_intent_history"] as? [[String: Any]])
        XCTAssertEqual(context["version"] as? Int, 31)
        XCTAssertEqual(history.first?["values_observed"] as? Bool, false)
        XCTAssertEqual(history.first?["input_dispatched"] as? Bool, false)
        let purposes = try XCTUnwrap(history.first?["purposes"] as? [[String: Any]])
        XCTAssertEqual(purposes.first?["historical_label"] as? String, "Query")
        let encodedHistory = try ResearchAnswerFixture.json(history)
        for privateField in ["controlID", "documentID", "inputLedgerID", fixture.base.absoluteString, "fresh-private-default"] {
            XCTAssertFalse(encodedHistory.contains(privateField))
        }
        XCTAssertThrowsError(try ComputerUseBrowserActionInput(interpretation: fresh.input.interpretation,
            evidence: fresh.input.evidence, navigationHistory: owner.confirmedNavigationHistory,
            formHistory: [], latestForm: nil, changedFormTargetIDs: [],
            unusedFormIntentHistory: owner.unusedFormIntentHistory + owner.unusedFormIntentHistory))
        let input = try await owner.prepareFormInput(for: fresh)
        _ = try await owner.executeForm(.decode(content: plan(input), input: input), input: input)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.index), [0])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(fixture.search.inputs.count, 1); XCTAssertEqual(owner.input, original)
    }

    func testSameDocumentHandbackKeepsTheOriginalUnobservedPreparation() async throws {
        let fixture = try await unusedIntentFixture()
        defer { fixture.close() }
        let action = try await pauseUnusedIntent(fixture), owner = try fixture.owner()
        try await owner.resumeAfterUserControl()
        _ = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertTrue(owner.hasPendingFormPreparation); XCTAssertTrue(owner.unusedFormIntentHistory.isEmpty)
        let input = try await owner.resumeFormPreparation()
        XCTAssertEqual(input.evidence.page.documentID, action.input.evidence.documentID)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
    }

    func testNavigationAfterHandbackCannotRetireAnUnobservedPreparationOnAnUnsealedPage() async throws {
        let fixture = try await unusedIntentFixture()
        defer { fixture.close() }
        _ = try await pauseUnusedIntent(fixture)
        let owner = try fixture.owner()
        _ = try await fixture.browser.navigate(taskID: owner.taskID, operationID: "fixture-handback-page", to: fixture.base.appendingPathComponent("details"))
        try await owner.resumeAfterUserControl()
        _ = try await fixture.browser.navigate(taskID: owner.taskID, operationID: "fixture-later-page", to: fixture.base.appendingPathComponent("beta"))
        do { _ = try await owner.recoverPendingFormPreparationCriteria(); XCTFail("Only the explicit handback document is eligible") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        XCTAssertTrue(owner.hasPendingFormPreparation); XCTAssertTrue(owner.unusedFormIntentHistory.isEmpty)
        XCTAssertFalse(fixture.state.commands.contains(.formFields)); XCTAssertFalse(fixture.state.commands.contains(.edit))
    }

    func testPauseDuringFreshRetirementValidationKeepsTheOriginalIntentUntilAnotherHandback() async throws {
        for captured in [false, true] {
            let fixture = try await unusedIntentFixture()
            defer { fixture.close() }
            if captured {
                _ = try await fixture.start(); configureUnusedIntent(fixture)
                let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
                _ = try await owner.prepareFormInput(for: action)
                owner.pause()
            } else { _ = try await pauseUnusedIntent(fixture) }
            let owner = try fixture.owner()
            _ = try await fixture.browser.navigate(taskID: owner.taskID, operationID: "fixture-new-form", to: fixture.base.appendingPathComponent("details"))
            try await owner.resumeAfterUserControl()
            var interrupted = false
            fixture.state.onCommand = { command in
                guard command == .validatePageSnapshot else { return }
                fixture.state.onCommand = nil; interrupted = true; owner.pause()
            }
            await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
            XCTAssertTrue(interrupted); XCTAssertFalse(owner.isOperating)
            XCTAssertTrue(owner.hasPendingFormPreparation); XCTAssertTrue(owner.unusedFormIntentHistory.isEmpty)
            try await owner.resumeAfterUserControl()
            let recovered = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(recovered); XCTAssertEqual(owner.unusedFormIntentHistory.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, captured ? 1 : 0)
            XCTAssertFalse(fixture.state.commands.contains(.edit))
        }
    }

    func testCapturedFieldsOrPreservationDutiesCannotUseUnobservedIntentRetirement() async throws {
        for preservationDuty in [false, true] {
            let fixture: ResearchDriverFixture
            if preservationDuty { fixture = try await make() }
            else { fixture = try await unusedIntentFixture() }
            defer { fixture.close() }
            let owner: ComputerUseBrowserResearchTask
            if preservationDuty {
                _ = try await fixture.start(); configure(fixture)
                owner = try fixture.owner()
                let action = try await owner.planNextAction(using: fixture.actions)
                fixture.state.onMayAct = {
                    guard owner.hasPendingFormPreparation else { return }
                    fixture.state.onMayAct = nil; owner.pause()
                }
                await expectFailure { _ = try await owner.prepareFormInput(for: action) }
                XCTAssertFalse(fixture.state.commands.contains(.formFields))
            } else {
                _ = try await fixture.start(); configureUnusedIntent(fixture)
                owner = try fixture.owner()
                let action = try await owner.planNextAction(using: fixture.actions)
                fixture.state.onCommand = { command in
                    guard command == .formFields else { return }
                    fixture.state.onCommand = nil; owner.pause()
                }
                await expectFailure { _ = try await owner.prepareFormInput(for: action) }
                XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
            }
            _ = try await fixture.browser.navigate(taskID: owner.taskID, operationID: "fixture-held-obligation", to: fixture.base.appendingPathComponent("details"))
            try await owner.resumeAfterUserControl()
            if preservationDuty {
                await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
                XCTAssertTrue(owner.hasPendingFormPreparation); XCTAssertTrue(owner.unusedFormIntentHistory.isEmpty)
            } else {
                let recovered = try await owner.recoverPendingFormPreparationCriteria()
                XCTAssertTrue(recovered); XCTAssertFalse(owner.hasPendingFormPreparation)
                XCTAssertEqual(owner.unusedFormIntentHistory.first?.observation, .initialEditPreconditions,
                    "A captured default must never be reported as unobserved")
            }
            XCTAssertTrue(owner.confirmedFormHistory.isEmpty); XCTAssertFalse(fixture.state.commands.contains(.edit))
        }
    }

    func testDriverReplansUnusedFormIntentAfterExplicitHandbackWithoutRepeatingSearch() async throws {
        let fixture = try await unusedIntentFixture()
        defer { fixture.close() }
        _ = try await pauseUnusedIntent(fixture)
        let owner = try fixture.owner(), original = owner.input
        _ = try await fixture.browser.navigate(taskID: owner.taskID, operationID: "fixture-driver-new-form", to: fixture.base.appendingPathComponent("details"))
        fixture.forms.select = { input in try self.plan(input) }
        configureUnusedIntent(fixture, stopAfterStage: true)
        try await owner.resumeAfterUserControl()
        _ = try await fixture.resume()
        XCTAssertFalse(owner.hasPendingFormPreparation); XCTAssertEqual(owner.unusedFormIntentHistory.count, 1)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.index), [0])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(fixture.search.inputs.count, 1); XCTAssertEqual(owner.input, original)
        XCTAssertTrue(fixture.actions.inputs.contains { $0.usesUnusedFormIntentHistoryContext })
        XCTAssertTrue(fixture.forms.inputs.allSatisfy { $0.interpretation.input == original })
    }

    private func unusedIntentFixture(mutation: String? = nil) async throws -> ResearchDriverFixture {
        let body = "<form action='/filtered'><label>Query<input name=q value='fresh-private-default'></label><button>Search</button></form>"
        let original = mutation.map { "<form action='/filtered'><label>Query<input name=q value=old></label><button>Search</button></form><script>fetch('/signal').then(()=>{ \($0) fetch('/changed'); });</script>" }
        let fixture = try await ResearchDriverFixture.make(searchForm: true, searchFormHTML: original, heldSignal: mutation != nil, detailsBodyHTML: body)
        fixture.policy.choices = [false]
        return fixture
    }

    private func configureUnusedIntent(_ fixture: ResearchDriverFixture, stopAfterStage: Bool = false) {
        fixture.actions.select = { input in
            if stopAfterStage, !(try fixture.owner()).confirmedFormHistory.isEmpty { return #"{"unavailable":true}"# }
            if let scope = try FormEffectScopeFixture.response(input, editing: ["Query":[0]]) { return scope }
            let form = try XCTUnwrap(input.formIDs.first)
            return try ResearchAnswerFixture.json(["form":form,"preserve":[]])
        }
    }

    private func pauseUnusedIntent(_ fixture: ResearchDriverFixture) async throws -> ComputerUseBrowserActionProposal {
        _ = try await fixture.start(); configureUnusedIntent(fixture)
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        var interrupted = false
        fixture.state.onMayAct = {
            guard owner.hasPendingFormPreparation else { return }
            fixture.state.onMayAct = nil; interrupted = true; owner.pause()
        }
        await expectFailure { _ = try await owner.prepareFormInput(for: action) }
        XCTAssertTrue(interrupted); XCTAssertTrue(owner.hasPendingFormPreparation); XCTAssertFalse(owner.isOperating)
        XCTAssertFalse(fixture.state.commands.contains(.formFields))
        return action
    }

    func testReadonlyPreservationInsideAndOutsideTheFormUsesPrivatePredicates() async throws {
        for inside in [false, true] {
            let fixture = try await make(inside: inside)
            defer { fixture.close() }
            let (input, _) = try await prepare(fixture)
            let binding = try XCTUnwrap(input.nativePreservation)
            XCTAssertEqual(input.evidence.fields.map { $0.control.label }, ["Query"])
            XCTAssertEqual(input.requiredPreservation.count, 0)
            XCTAssertEqual(input.nativePreservedSources.map(\.controlID), binding.controlIDs)
            XCTAssertEqual(input.nativePreservedSources.first?.source.role, .condition)
            XCTAssertFalse(input.contextJSON.contains("private-reference"))
            XCTAssertTrue(input.contextJSON.contains("required_native_preservation"))
            XCTAssertEqual(fixture.state.commands.filter { $0 == .prepareFormPreservation }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .observeResearchControls || $0 == .edit }.count, 0)
            let scope = try XCTUnwrap(input.scopeReview?.formScope)
            XCTAssertEqual(scope.nativePreservedControlIDs, binding.controlIDs)
            XCTAssertTrue(Set(scope.discoveryControlIDs).isDisjoint(with: Set(binding.controlIDs)))
        }
    }

    func testNativeAndEditablePreservationShareTheUserClauseWithoutSharingAliases() async throws {
        let fixture = try await make(notes: true)
        defer { fixture.close() }
        let (input, proposal) = try await prepare(fixture, notes: true)
        XCTAssertEqual(Set(input.evidence.fields.map { $0.control.label }), ["Query","Notes"])
        XCTAssertEqual(input.requiredPreservation.count, 1)
        XCTAssertEqual(input.nativePreservedSources.count, 1)
        XCTAssertEqual(input.editableFieldAliases.count, 1)
        for value in ["private-reference","private-notes"] { XCTAssertFalse(input.contextJSON.contains(value)) }
        let contract = try XCTUnwrap(proposal.textContract(for: input))
        let notes = try XCTUnwrap(input.evidence.fields.first { $0.control.label == "Notes" })
        XCTAssertEqual(contract.unchangedValues[notes.editable.snapshot.targetID], notes.editable.snapshot.value)
        _ = try await fixture.owner().executeForm(proposal, input: input)
        XCTAssertEqual(try fixture.owner().confirmedFormHistory.count, 1)
    }

    func testReviewedInputRejectsMissingOrDifferentPurposeNativeBindings() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let (input, _) = try await prepare(fixture), scope = try XCTUnwrap(input.scopeReview?.formScope)
        XCTAssertThrowsError(try ComputerUseBrowserResearchFormInput(interpretation: input.interpretation, evidence: input.evidence,
            selectedFormID: input.selectedFormID, preservedControls: scope.preservedControls, scopeReview: input.scopeReview))
        let changed = try forgedBinding(input, value: "private-reference", purpose: ComputerUseTaskContract.digest(["another-purpose"]))
        XCTAssertThrowsError(try ComputerUseBrowserResearchFormInput(interpretation: input.interpretation, evidence: input.evidence,
            selectedFormID: input.selectedFormID, preservedControls: scope.preservedControls, scopeReview: input.scopeReview,
            nativePreservation: changed))
    }

    func testProhibitionPreservesPrivatelyWithoutGrantingResearchReadPermission() async throws {
        let fixture = try await make(prohibition: true)
        defer { fixture.close() }
        let (input, proposal) = try await prepare(fixture)
        XCTAssertEqual(input.nativePreservedSources.first?.source.role, .prohibition)
        XCTAssertFalse(ComputerUseBrowserControlRead.accepts(input.interpretation.requirements[1]))
        XCTAssertFalse(input.contextJSON.contains("private-reference"))
        _ = try await fixture.owner().executeForm(proposal, input: input)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .observeResearchControls }.count, 0)
        XCTAssertEqual(try fixture.owner().confirmedFormHistory.count, 1)
    }

    func testPrivateBaselineChangesTheDurableContractWithoutChangingModelContext() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let (input, proposal) = try await prepare(fixture), scope = try XCTUnwrap(input.scopeReview?.formScope)
        let changed = try ComputerUseBrowserResearchFormInput(interpretation: input.interpretation, evidence: input.evidence,
            selectedFormID: input.selectedFormID, preservedControls: scope.preservedControls, scopeReview: input.scopeReview,
            nativePreservation: forgedBinding(input, value: "another-private-value"))
        XCTAssertEqual(input.contextJSON, changed.contextJSON)
        let other = try ComputerUseBrowserFormProposal.decode(content: plan(changed), input: changed)
        let originalContract = try XCTUnwrap(proposal.textContract(for: input, stageID: "same-stage"))
        let changedContract = try XCTUnwrap(other.textContract(for: changed, stageID: "same-stage"))
        XCTAssertNotEqual(originalContract.contractDigest, changedContract.contractDigest)
        XCTAssertFalse(String(reflecting: changed.nativePreservation).contains("another-private-value"))
    }

    func testChangedReadonlyValuePreventsTheFirstFormEdit() async throws {
        let fixture = try await make(mutation: "document.getElementById('reference').value='changed';")
        defer { fixture.close() }
        let (input, proposal) = try await prepare(fixture)
        try await release(fixture)
        await expectFailure { _ = try await fixture.owner().executeForm(proposal, input: input) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        XCTAssertTrue(try fixture.owner().confirmedFormHistory.isEmpty)
    }

    func testHandlerViolationCannotBecomeACompletedResearchStageOrRepeatInput() async throws {
        let fixture = try await make(handler: "document.getElementById('reference').value='changed';")
        defer { fixture.close() }
        let (input, proposal) = try await prepare(fixture), owner = try fixture.owner()
        await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
        await expectFailure { _ = try await owner.resumeForm() }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 0)
    }

    func testUnsentPauseRetainsTheSamePrivateBaselineUntilExplicitHandback() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let (input, proposal) = try await prepare(fixture), owner = try fixture.owner()
        let original = owner.input, binding = input.nativePreservation
        fixture.state.onCommand = { command in
            guard command == .validateFormPreservation else { return }
            fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
        XCTAssertTrue(owner.hasPendingForm); XCTAssertFalse(owner.isOperating)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        let decisions = fixture.actions.inputs.count
        try await owner.resumeAfterUserControl(); _ = try await owner.resumeForm()
        XCTAssertEqual(owner.input, original); XCTAssertEqual(input.nativePreservation, binding)
        XCTAssertEqual(fixture.actions.inputs.count, decisions)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .prepareFormPreservation }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(owner.confirmedFormHistory.count, 1)
    }

    func testPauseAfterNativeInputReconcilesTheGuardWithoutReplayingTheEdit() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let (input, proposal) = try await prepare(fixture), owner = try fixture.owner()
        fixture.state.onCommand = { command in
            guard command == .edit else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        try await owner.resumeAfterUserControl(); _ = try await owner.resumeForm()
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .prepareFormPreservation }.count, 1)
        XCTAssertEqual(owner.confirmedFormHistory.count, 1)
    }

    func testPreparedFormSurvivesIdlePauseAndCancellationInsideItsPlanner() async throws {
        for duringPlanning in [false, true] {
            let fixture = try await make()
            defer { fixture.close() }
            let (input, _) = try await prepare(fixture), owner = try fixture.owner()
            fixture.forms.content = try plan(input)
            if duringPlanning {
                fixture.forms.beforeReply = { fixture.forms.beforeReply = nil; owner.pause() }
                await expectFailure { _ = try await owner.planForm(input, using: fixture.forms) }
            } else { owner.pause() }
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
            try await owner.resumeAfterUserControl()
            let proposal = try await owner.planForm(input, using: fixture.forms)
            _ = try await owner.executeForm(proposal, input: input)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .prepareFormPreservation }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
            XCTAssertEqual(owner.confirmedFormHistory.count, 1)
        }
    }

    func testHandbackCannotAdoptAChangedReadonlyBaseline() async throws {
        let fixture = try await make(mutation: "document.getElementById('reference').value='changed';")
        defer { fixture.close() }
        let (input, proposal) = try await prepare(fixture), owner = try fixture.owner()
        fixture.state.onCommand = { command in
            guard command == .validateFormPreservation else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
        try await release(fixture)
        await expectFailure { try await owner.resumeAfterUserControl(); _ = try await owner.resumeForm() }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
    }

    func testQueryCarriesReadonlyPreservationWithoutAResearchValueRead() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let (input, proposal) = try await prepare(fixture), owner = try fixture.owner()
        _ = try await owner.executeForm(proposal, input: input)
        configure(fixture, querying: true)
        let action = try await owner.planNextAction(using: fixture.actions)
        guard case .openQuery = action.step else { return XCTFail("The verified form should be queryable") }
        let ids = try XCTUnwrap(input.nativePreservation?.controlIDs)
        XCTAssertTrue(Set(ids).isSubset(of: Set(action.input.queryBoundControlIDs)))
        XCTAssertEqual(action.input.carriedFormPreservation.map { $0.control.controlID }, ids)
        XCTAssertFalse(action.input.contextJSON.contains("private-reference"))
        XCTAssertEqual(fixture.state.commands.filter { $0 == .observeResearchControls }.count, 0)
        _ = try await owner.openFormQuery(for: action)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 1)
    }

    func testQueryHandbackChecksTheOriginalNativePredicateBeforeLoading() async throws {
        let fixture = try await make(mutation: "document.getElementById('reference').value='changed';")
        defer { fixture.close() }
        let (input, proposal) = try await prepare(fixture), owner = try fixture.owner()
        _ = try await owner.executeForm(proposal, input: input)
        configure(fixture, querying: true)
        let action = try await owner.planNextAction(using: fixture.actions)
        fixture.state.onCommand = { command in
            guard command == .prepareFormQuery else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.openFormQuery(for: action) }
        try await release(fixture)
        await expectFailure { try await owner.resumeAfterUserControl(); _ = try await owner.resumeFormNavigation() }
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 0)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testLaterFormStageRetainsReadonlySourcesAndEarlierInputReceipts() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (first, firstProposal) = try await prepare(fixture, category: true), owner = try fixture.owner()
        _ = try await owner.executeForm(firstProposal, input: first)
        configure(fixture, category: true, revising: true)
        let action = try await owner.planNextAction(using: fixture.actions)
        let next = try await owner.prepareFormInput(for: action)
        XCTAssertEqual(next.previous?.nativePreservation, first.nativePreservation)
        XCTAssertEqual(next.nativePreservedSources, first.nativePreservedSources)
        XCTAssertEqual(next.nativePreservation?.controlIDs, first.nativePreservation?.controlIDs)
        XCTAssertNotEqual(next.nativePreservation?.id, first.nativePreservation?.id)
        XCTAssertEqual(next.previous?.inputOperationIDs.count, 1)
        _ = try await owner.executeForm(.decode(content: categoryPlan(next), input: next), input: next)
        XCTAssertEqual(owner.confirmedFormHistory.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testAdditiveNativeScopeStillEnforcesEarlierQueryRequirementsAndReceipts() async throws {
        let fixture = try await ControlStateFixture(body: """
            <form action=/filtered><label>Query<input name=q value=old></label><button>Search</button></form>
            <label>Reference<input id=reference readonly value=keep></label><label>Direct<input type=checkbox checked></label>
            <script>fetch('/signal').then(()=>{ document.getElementById('reference').value='changed'; fetch('/changed'); });</script>
            """, heldSignal: true)
        defer { fixture.close() }
        let page = try await fixture.browser.observePage(document: fixture.document)
        func id(_ label: String) throws -> String { try XCTUnwrap(page.page.controls.first { $0.label == label }?.id) }
        let form = try XCTUnwrap(page.page.controls.first { $0.label == "Query" }?.form?.id)
        let fields = try await fixture.browser.callDOM(.formFields, arguments: ["documentID":page.documentID,
            "snapshotID":page.page.id,"formID":form,"preservedControlIDs":[],"selectedControlIDs":[try id("Query")]], document: fixture.document)
        let field = try XCTUnwrap(fields.fields?.first), ledger = try XCTUnwrap(fields.inputLedgerID)
        func preserve(_ labels: [String], purpose: String) async throws -> ComputerUseBrowserFormPreservation.Reply {
            let reply = try await fixture.browser.callDOM(.prepareFormPreservation, arguments: ["documentID":page.documentID,
                "inputLedgerID":ledger,"snapshotID":page.page.id,"scopeDigest":ComputerUseTaskContract.digest([purpose]),
                "controlIDs":try labels.map(id)], document: fixture.document)
            return try XCTUnwrap(reply.formPreservation)
        }
        let first = try await preserve(["Reference"], purpose: "original")
        let operation = ComputerUseTaskContract.digest(["original-input"])
        let edit = try await fixture.browser.callDOM(.edit, arguments: ["documentID":page.documentID,"id":field.id,
            "operationID":operation,"mode":"replaceAll","payload":"concerts","before":"old","after":"concerts",
            "selectionStart":field.selectionStart,"selectionEnd":field.selectionEnd,"requiredValues":[],"preservationID":first.id], document: fixture.document)
        XCTAssertEqual(edit.status, "attempted")
        let next = try await preserve(["Reference","Direct"], purpose: "added-setting")
        XCTAssertNotEqual(next.id, first.id)
        let requirements: [String: Any] = ["digest":ComputerUseTaskContract.digest(["original-contract"]),"inputOperationIDs":[operation],
            "preservationID":first.id,"fields":[["id":field.id,"value":"concerts","mustSubmit":true] as [String: Any]]]
        let queryArguments: [String: Any] = ["documentID":page.documentID,"snapshotID":page.page.id,"controlID":try id("Search"),"requirements":requirements]
        let query = try await fixture.browser.callDOM(.prepareFormQuery, arguments: queryArguments, document: fixture.document)
        XCTAssertEqual(query.status, "form-query-prepared", "A stronger guard keeps the original required values and receipts")
        var unknownRequirements = requirements; unknownRequirements["preservationID"] = String(repeating: "0", count: 32)
        var unknownQuery = queryArguments; unknownQuery["requirements"] = unknownRequirements
        let unknown = try await fixture.browser.callDOM(.prepareFormQuery, arguments: unknownQuery, document: fixture.document)
        XCTAssertEqual(unknown.status, "stale", "An unrelated guard cannot stand in for an ancestor")
        try await fixture.wait { fixture.server.count("/signal") == 1 }; fixture.server.releaseHeldResponses()
        try await fixture.wait { fixture.server.count("/changed") == 1 }
        let changed = try await fixture.browser.callDOM(.prepareFormQuery, arguments: queryArguments, document: fixture.document)
        XCTAssertEqual(changed.status, "constraint-changed")
        let history = try await fixture.browser.callDOM(.receipt, arguments: ["documentID":page.documentID,"operationID":operation], document: fixture.document)
        XCTAssertEqual(history.status, "dispatched")
    }

    func testPreparationResumesEachCapturedReadWithoutRediscoveringItsBaseline() async throws {
        for interrupted in [ComputerUseBrowserDOMCommand.formFields, .bindPageFields, .prepareFormPreservation] {
            let fixture = try await make()
            defer { fixture.close() }
            _ = try await fixture.start(); configure(fixture)
            let owner = try fixture.owner(), original = owner.input, action = try await owner.planNextAction(using: fixture.actions)
            fixture.state.onCommand = { command in
                guard command == interrupted else { return }; fixture.state.onCommand = nil; owner.pause()
            }
            await expectFailure { _ = try await owner.prepareFormInput(for: action) }
            XCTAssertTrue(owner.hasPendingFormPreparation); XCTAssertTrue(owner.hasPendingForm); XCTAssertFalse(owner.isOperating)
            let decisions = fixture.actions.inputs.count
            await expectFailure { _ = try await owner.resumeFormPreparation() }
            try await owner.resumeAfterUserControl()
            let input = try await owner.resumeFormPreparation()
            XCTAssertEqual(input.interpretation.input, original)
            XCTAssertEqual(fixture.actions.inputs.count, decisions)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .prepareFormPreservation }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .bindPageFields }.count, 2,
                "One captured correspondence plus a fresh comparison, never a new baseline")
            _ = try await owner.executeForm(.decode(content: plan(input), input: input), input: input)
            XCTAssertFalse(owner.hasPendingFormPreparation)
            XCTAssertEqual(owner.confirmedFormHistory.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        }
    }

    func testChangedCapturedEditableValueBlocksPreparationRecovery() async throws {
        let fixture = try await make(mutation: "document.getElementById('query').value='changed-during-pause';")
        defer { fixture.close() }
        _ = try await fixture.start(); configure(fixture)
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        fixture.state.onCommand = { command in
            guard command == .formFields else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.prepareFormInput(for: action) }
        try await release(fixture); try await owner.resumeAfterUserControl()
        await expectFailure { _ = try await owner.resumeFormPreparation() }
        XCTAssertTrue(owner.hasPendingFormPreparation)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit || $0 == .prepareFormPreservation }.count, 0)
    }

    func testChangedCapturedReadonlyValueBlocksUnpublishedPreparationRecovery() async throws {
        let fixture = try await make(mutation: "document.getElementById('reference').value='changed-during-pause';")
        defer { fixture.close() }
        _ = try await fixture.start(); configure(fixture)
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        fixture.state.onCommand = { command in
            guard command == .prepareFormPreservation else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.prepareFormInput(for: action) }
        try await release(fixture); try await owner.resumeAfterUserControl()
        await expectFailure { _ = try await owner.resumeFormPreparation() }
        XCTAssertTrue(owner.hasPendingFormPreparation)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .prepareFormPreservation || $0 == .formFields }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
    }

    func testReplacingAnOriginalFieldCannotTurnCapturedDataIntoNewTargetAuthority() async throws {
        let fixture = try await make(mutation: "const q=document.getElementById('query'); q.replaceWith(q.cloneNode(true));")
        defer { fixture.close() }
        _ = try await fixture.start(); configure(fixture)
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        fixture.state.onCommand = { command in
            guard command == .formFields else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.prepareFormInput(for: action) }
        try await release(fixture); try await owner.resumeAfterUserControl()
        await expectFailure { _ = try await owner.resumeFormPreparation() }
        _ = try? await owner.recoverPendingFormPreparationCriteria()
        XCTAssertTrue(owner.hasPendingFormPreparation); XCTAssertTrue(owner.unusedFormIntentHistory.isEmpty)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testPreparationSurvivesCancellationDuringItsFinalOriginalInputValidation() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        _ = try await fixture.start(); configure(fixture)
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        fixture.state.onCommand = { command in
            guard command == .validateFormPreservation else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.prepareFormInput(for: action) }
        XCTAssertTrue(owner.hasPendingFormPreparation)
        try await owner.resumeAfterUserControl()
        let input = try await owner.resumeFormPreparation()
        XCTAssertNotNil(input.nativePreservation)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .prepareFormPreservation }.count, 2)
        _ = try await owner.executeForm(.decode(content: plan(input), input: input), input: input)
        XCTAssertEqual(owner.confirmedFormHistory.count, 1)
    }

    func testDriverResumesPreparationBeforeAskingForAnotherAction() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        _ = try await fixture.start(); configure(fixture)
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        fixture.state.onCommand = { command in
            guard command == .prepareFormPreservation else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.prepareFormInput(for: action) }
        fixture.forms.content = #"{"edits":[{"field":"field1","terms":[{"requirement":0,"text":"concerts"}]}],"preserve":[]}"#
        fixture.actions.select = { _ in
            XCTAssertEqual(owner.confirmedFormHistory.count, 1, "Finish the retained preparation and stage before selecting another action")
            return #"{"unavailable":true}"#
        }
        try await owner.resumeAfterUserControl(); _ = try await fixture.resume()
        XCTAssertFalse(owner.hasPendingFormPreparation)
        XCTAssertEqual(owner.confirmedFormHistory.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .prepareFormPreservation }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testRetiringOwnerDiscardsPreparationWithoutPublishingALateStage() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        _ = try await fixture.start(); configure(fixture)
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        fixture.state.onCommand = { command in
            guard command == .formFields else { return }; fixture.state.onCommand = nil; owner.retire()
        }
        await expectFailure { _ = try await owner.prepareFormInput(for: action) }
        XCTAssertFalse(owner.hasPendingFormPreparation)
        await expectFailure { _ = try await owner.resumeFormPreparation() }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
    }

    func testPrivateReadCaptureRejectsEffectsAndChangedArguments() async throws {
        let fixture = try await ControlStateFixture(body: "<p>Metadata only</p>")
        defer { fixture.close() }
        for command in [ComputerUseBrowserDOMCommand.edit, .continueUnsentInput, .openPopup, .selectOption, .scrollViewport, .validateFormState] {
            XCTAssertThrowsError(try ComputerUseBrowserDOMReadCapture(command: command, document: fixture.document))
        }
        let capture = try ComputerUseBrowserDOMReadCapture(command: .formFields, document: fixture.document)
        let arguments: [String: Any] = ["snapshotID":"first","selectedControlIDs":["c1"]]
        try capture.begin(command: .formFields, arguments: arguments, document: fixture.document)
        capture.finish(.success(try ComputerUseOwnedBrowser.decodeDOMReply(
            #"{"status":"ok","documentID":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#, command: .formFields)))
        XCTAssertNotNil(try capture.retainedReply(command: .formFields,
            arguments: ["snapshotID":"new-nonce","selectedControlIDs":["c1"]], document: fixture.document))
        XCTAssertThrowsError(try capture.retainedReply(command: .formFields,
            arguments: ["snapshotID":"new-nonce","selectedControlIDs":["c2"]], document: fixture.document))
        XCTAssertThrowsError(try capture.retainedReply(command: .bindPageFields, arguments: arguments, document: fixture.document))
        XCTAssertFalse(String(describing: capture).contains("c1"))
    }

    func testUnknownReadFailureCannotBeRetriedAsAnAbsentObservation() async throws {
        let fixture = try await ControlStateFixture(body: "<p>Metadata only</p>")
        defer { fixture.close() }
        let capture = try ComputerUseBrowserDOMReadCapture(command: .formFields, document: fixture.document)
        try capture.begin(command: .formFields, arguments: [:], document: fixture.document)
        capture.finish(.failure(ComputerUseBrowserError.pageChanged))
        XCTAssertThrowsError(try capture.retainedReply(command: .formFields, arguments: [:], document: fixture.document))
        XCTAssertTrue(capture.didStart)
        XCTAssertThrowsError(try capture.begin(command: .formFields, arguments: [:], document: fixture.document))
    }

    func testCapturedExtensionCannotChangeItsEarlierRequirementsOrRepairableObjects() async throws {
        let fixture = try await ControlStateFixture(body: "<p>Metadata only</p>")
        defer { fixture.close() }
        let capture = try ComputerUseBrowserDOMReadCapture(command: .extendFormFields, document: fixture.document)
        let original: [String: Any] = ["snapshotID":"first", "selectedControlIDs":["c2"],
            "requirements":["digest":"original-requirements", "preservationID":"original-preservation"], "repairableFieldIDs":["f1"]]
        try capture.begin(command: .extendFormFields, arguments: original, document: fixture.document)
        capture.finish(.success(try ComputerUseOwnedBrowser.decodeDOMReply(
            #"{"status":"ok","documentID":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#, command: .extendFormFields)))
        var refreshed = original; refreshed["snapshotID"] = "new-observation"
        XCTAssertNotNil(try capture.retainedReply(command: .extendFormFields, arguments: refreshed, document: fixture.document))
        for replacement: [String: Any] in [
            ["requirements":["digest":"different-requirements", "preservationID":"original-preservation"]],
            ["requirements":["digest":"original-requirements", "preservationID":"different-preservation"]],
            ["repairableFieldIDs":["f2"]], ["selectedControlIDs":["c3"]]
        ] {
            let changed = refreshed.merging(replacement) { _, new in new }
            XCTAssertThrowsError(try capture.retainedReply(command: .extendFormFields, arguments: changed, document: fixture.document))
        }
    }

    func testUncapturedRevisionReplyRequiresItsExactCommandAndEmptyPayload() throws {
        let body: [String: Any] = ["status":"revision-not-captured", "documentID":String(repeating: "a", count: 32),
            "inputLedgerID":String(repeating: "b", count: 32), "uncapturedRevisionID":String(repeating: "c", count: 64)]
        let source = try ResearchAnswerFixture.json(body)
        XCTAssertEqual(try ComputerUseOwnedBrowser.decodeDOMReply(source, command: .reviseFormFields).status, "revision-not-captured")
        for command in [ComputerUseBrowserDOMCommand.formFields, .extendFormFields, .inspectFormRequirements, .verifyFormState, .edit] {
            XCTAssertThrowsError(try ComputerUseOwnedBrowser.decodeDOMReply(source, command: command))
        }
        for replacement: [String: Any] in [["status":"stale"], ["status":"authentication-required"],
            ["uncapturedRevisionID":"bad"], ["uncapturedRevisionID":NSNull()], ["inputLedgerID":"bad"],
            ["inputLedgerID":NSNull()], ["fields":[]], ["changedFieldIDs":[]], ["formBindings":[]],
            ["popupControls":[]], ["popupPreservedControls":[]], ["selectionPreservedControls":[]], ["optionSelectionCandidates":[]]] {
            let changed = try ResearchAnswerFixture.json(body.merging(replacement) { _, new in new })
            XCTAssertThrowsError(try ComputerUseOwnedBrowser.decodeDOMReply(changed, command: .reviseFormFields))
        }
    }

    func testUncapturedRevisionWitnessKeepsItsArgumentsAndExactNativeIdentity() async throws {
        let fixture = try await ControlStateFixture(body: "<p>Metadata only</p>")
        defer { fixture.close() }
        let documentID = String(repeating: "a", count: 32), ledger = String(repeating: "b", count: 32), revision = String(repeating: "c", count: 64)
        let capture = try ComputerUseBrowserDOMReadCapture(command: .reviseFormFields, document: fixture.document)
        let arguments: [String: Any] = ["revisionID":revision, "snapshotID":"first", "selectedControlIDs":["c1"]]
        try capture.begin(command: .reviseFormFields, arguments: arguments, document: fixture.document)
        XCTAssertFalse(capture.revisionWasNotCaptured(document: fixture.document, documentID: documentID, inputLedgerID: ledger))
        let reply = try ComputerUseOwnedBrowser.decodeDOMReply(ResearchAnswerFixture.json([
            "status":"revision-not-captured", "documentID":documentID, "inputLedgerID":ledger, "uncapturedRevisionID":revision]), command: .reviseFormFields)
        capture.finish(.success(reply))
        XCTAssertTrue(capture.revisionWasNotCaptured(document: fixture.document, documentID: documentID, inputLedgerID: ledger))
        XCTAssertFalse(capture.revisionWasNotCaptured(document: fixture.document, documentID: ledger, inputLedgerID: ledger))
        XCTAssertFalse(capture.revisionWasNotCaptured(document: fixture.document, documentID: documentID, inputLedgerID: documentID))
        XCTAssertNotNil(try capture.retainedReply(command: .reviseFormFields,
            arguments: arguments.merging(["snapshotID":"fresh"]) { _, new in new }, document: fixture.document))
        XCTAssertTrue(capture.didStart)
        XCTAssertThrowsError(try capture.begin(command: .reviseFormFields, arguments: arguments, document: fixture.document))
        XCTAssertThrowsError(try capture.retainedReply(command: .reviseFormFields,
            arguments: arguments.merging(["selectedControlIDs":["c2"]]) { _, new in new }, document: fixture.document))
        let foreign = try ComputerUseBrowserDOMReadCapture(command: .reviseFormFields, document: fixture.document)
        try foreign.begin(command: .reviseFormFields, arguments: ["revisionID":String(repeating: "d", count: 64)], document: fixture.document)
        foreign.finish(.success(reply))
        XCTAssertFalse(foreign.revisionWasNotCaptured(document: fixture.document, documentID: documentID, inputLedgerID: ledger))
    }

    func testOrdinaryFailedOrCompletedRevisionCannotBecomeAnAbsentCapture() async throws {
        let fixture = try await ControlStateFixture(body: "<p>Metadata only</p>")
        defer { fixture.close() }
        let documentID = String(repeating: "a", count: 32), ledger = String(repeating: "b", count: 32), revision = String(repeating: "c", count: 64)
        let absent = try ComputerUseOwnedBrowser.decodeDOMReply(ResearchAnswerFixture.json([
            "status":"revision-not-captured", "documentID":documentID, "inputLedgerID":ledger, "uncapturedRevisionID":revision]), command: .reviseFormFields)
        let results: [Result<ComputerUseBrowserDOMReply, Error>] = try [
            .failure(ComputerUseBrowserError.pageChanged), .failure(ComputerUseBrowserError.documentUnresponsive),
            .success(ComputerUseOwnedBrowser.decodeDOMReply(ResearchAnswerFixture.json([
                "status":"stale", "documentID":documentID, "inputLedgerID":ledger]), command: .reviseFormFields)),
            .success(ComputerUseOwnedBrowser.decodeDOMReply(ResearchAnswerFixture.json([
                "status":"ok", "documentID":documentID, "inputLedgerID":ledger, "fields":[]]), command: .reviseFormFields))]
        for result in results {
            let capture = try ComputerUseBrowserDOMReadCapture(command: .reviseFormFields, document: fixture.document)
            try capture.begin(command: .reviseFormFields, arguments: ["revisionID":revision], document: fixture.document)
            capture.finish(result); capture.finish(.success(absent))
            XCTAssertFalse(capture.revisionWasNotCaptured(document: fixture.document, documentID: documentID, inputLedgerID: ledger))
            XCTAssertTrue(capture.didStart)
        }
    }

    func testOnlyAnEmptyAuthenticationReplyCanReleaseAnUnobservedCapture() async throws {
        let fixture = try await ControlStateFixture(body: "<p>Metadata only</p>")
        defer { fixture.close() }
        let capture = try ComputerUseBrowserDOMReadCapture(command: .prepareFormPreservation, document: fixture.document)
        try capture.begin(command: .prepareFormPreservation, arguments: [:], document: fixture.document)
        let empty = #"{"status":"authentication-required","documentID":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#
        let fields = try ComputerUseBrowserDOMReadCapture(command: .formFields, document: fixture.document)
        try fields.begin(command: .formFields, arguments: [:], document: fixture.document)
        fields.finish(Result { try ComputerUseOwnedBrowser.decodeDOMReply(empty, command: .formFields) })
        XCTAssertTrue(fields.initialFieldsWereNotObserved)
        XCTAssertTrue(fields.didStart, "The absence predicate preserves the validated terminal reply")
        capture.finish(Result { try ComputerUseOwnedBrowser.decodeDOMReply(empty, command: .prepareFormPreservation) })
        XCTAssertNil(try capture.retainedReply(command: .prepareFormPreservation, arguments: [:], document: fixture.document))
        XCTAssertFalse(capture.didStart)
        let malformed = try ResearchAnswerFixture.json(["status":"authentication-required","documentID":String(repeating: "a", count: 32),
            "formPreservation":["id":String(repeating: "b", count: 32),"scopeDigest":String(repeating: "c", count: 64),
                "controlIDs":["c1"],"states":[["controlID":"c1","kind":"text","value":"private"]]]])
        for command in [ComputerUseBrowserDOMCommand.prepareFormPreservation, .formFields] {
            XCTAssertThrowsError(try ComputerUseOwnedBrowser.decodeDOMReply(malformed, command: command)) { error in
                XCTAssertEqual(error as? ComputerUseBrowserError, .unsupportedDocument)
            }
        }
    }

    func testRevisionHistoryReplyRequiresExactIdentityAndHistoricalFields() throws {
        let body: [String: Any] = ["status":"ok", "documentID":String(repeating: "a", count: 32),
            "inputLedgerID":String(repeating: "b", count: 32), "recoveredRevisionID":String(repeating: "c", count: 64),
            "fields":[["id":"e1", "label":"Query", "value":"old", "selectionStart":3, "selectionEnd":3]]]
        let source = try ResearchAnswerFixture.json(body)
        XCTAssertEqual(try ComputerUseOwnedBrowser.decodeDOMReply(source, command: .inspectPreparedRevision).fields?.first?.value, "old")
        for command in [ComputerUseBrowserDOMCommand.reviseFormFields, .formFields, .extendFormFields, .inspectFormRequirements, .edit] {
            XCTAssertThrowsError(try ComputerUseOwnedBrowser.decodeDOMReply(source, command: command))
        }
        for replacement: [String: Any] in [["recoveredRevisionID":NSNull()], ["recoveredRevisionID":"bad"],
            ["inputLedgerID":NSNull()], ["inputLedgerID":"bad"], ["fields":[]], ["fields":NSNull()],
            ["status":"stale"], ["status":"authentication-required"], ["changedFieldIDs":[]], ["formBindings":[]],
            ["popupControls":[]], ["selectionPreservedControls":[]], ["uncapturedRevisionID":String(repeating: "c", count: 64)]] {
            XCTAssertThrowsError(try ComputerUseOwnedBrowser.decodeDOMReply(ResearchAnswerFixture.json(
                body.merging(replacement) { _, new in new }), command: .inspectPreparedRevision))
        }
        let absent = body.merging(["status":"revision-not-captured", "fields":NSNull(),
            "uncapturedRevisionID":String(repeating: "c", count: 64)]) { _, new in new }
        XCTAssertEqual(try ComputerUseOwnedBrowser.decodeDOMReply(ResearchAnswerFixture.json(absent), command: .inspectPreparedRevision).status, "revision-not-captured")
        XCTAssertThrowsError(try ComputerUseOwnedBrowser.decodeDOMReply(ResearchAnswerFixture.json(
            absent.merging(["uncapturedRevisionID":String(repeating: "d", count: 64)]) { _, new in new }), command: .inspectPreparedRevision))
    }

    func testFailedRevisionKeepsItsOriginalAttemptWhenHistoryIsReconciled() async throws {
        let fixture = try await ControlStateFixture(body: "<p>Metadata only</p>")
        defer { fixture.close() }
        let documentID = String(repeating: "a", count: 32), ledger = String(repeating: "b", count: 32), revision = String(repeating: "c", count: 64)
        let arguments: [String: Any] = ["revisionID":revision, "snapshotID":"first", "selectedControlIDs":["c1"]]
        let capture = try ComputerUseBrowserDOMReadCapture(command: .reviseFormFields, document: fixture.document)
        try capture.begin(command: .reviseFormFields, arguments: arguments, document: fixture.document)
        capture.finish(.failure(ComputerUseBrowserError.pageChanged))
        XCTAssertTrue(try capture.requiresRevisionReconciliation(arguments: arguments, document: fixture.document))
        let changed = arguments.merging(["selectedControlIDs":["c2"]]) { _, new in new }
        XCTAssertThrowsError(try capture.requiresRevisionReconciliation(arguments: changed, document: fixture.document))
        let reply = try ComputerUseOwnedBrowser.decodeDOMReply(ResearchAnswerFixture.json([
            "status":"ok", "documentID":documentID, "inputLedgerID":ledger, "recoveredRevisionID":revision,
            "fields":[["id":"e1", "label":"Query", "value":"old", "selectionStart":3, "selectionEnd":3]]]), command: .inspectPreparedRevision)
        XCTAssertThrowsError(try capture.reconcileRevision(reply, arguments: changed, document: fixture.document, documentID: documentID, inputLedgerID: ledger))
        XCTAssertThrowsError(try capture.reconcileRevision(reply, arguments: arguments, document: fixture.document, documentID: documentID, inputLedgerID: documentID))
        try capture.reconcileRevision(reply, arguments: arguments, document: fixture.document, documentID: documentID, inputLedgerID: ledger)
        XCTAssertFalse(capture.needsRevisionReconciliation); XCTAssertTrue(capture.didStart)
        capture.finish(.failure(ComputerUseBrowserError.closed))
        let retained = try capture.retainedReply(command: .reviseFormFields,
            arguments: arguments.merging(["snapshotID":"fresh"]) { _, new in new }, document: fixture.document)
        XCTAssertEqual(retained?.fields?.first?.value, "old")
        XCTAssertFalse(capture.revisionWasNotCaptured(document: fixture.document, documentID: documentID, inputLedgerID: ledger))
        XCTAssertThrowsError(try capture.reconcileRevision(reply, arguments: arguments, document: fixture.document, documentID: documentID, inputLedgerID: ledger))
        XCTAssertThrowsError(try capture.begin(command: .reviseFormFields, arguments: arguments, document: fixture.document))
    }

    func testRevisionHistoryCannotOverwritePendingSuccessfulOrAuthenticationCaptures() async throws {
        let fixture = try await ControlStateFixture(body: "<p>Metadata only</p>")
        defer { fixture.close() }
        let documentID = String(repeating: "a", count: 32), ledger = String(repeating: "b", count: 32), revision = String(repeating: "c", count: 64)
        let arguments: [String: Any] = ["revisionID":revision]
        let reply = try ComputerUseOwnedBrowser.decodeDOMReply(ResearchAnswerFixture.json([
            "status":"revision-not-captured", "documentID":documentID, "inputLedgerID":ledger,
            "uncapturedRevisionID":revision, "recoveredRevisionID":revision]), command: .inspectPreparedRevision)
        for state in ["unstarted","pending","stale","completed","authentication"] {
            let capture = try ComputerUseBrowserDOMReadCapture(command: .reviseFormFields, document: fixture.document)
            if state != "unstarted" { try capture.begin(command: .reviseFormFields, arguments: arguments, document: fixture.document) }
            if state == "stale" { capture.finish(.success(try ComputerUseOwnedBrowser.decodeDOMReply(
                ResearchAnswerFixture.json(["status":"stale", "documentID":documentID]), command: .reviseFormFields))) }
            if state == "completed" { capture.finish(.success(try ComputerUseOwnedBrowser.decodeDOMReply(
                ResearchAnswerFixture.json(["status":"ok", "documentID":documentID, "inputLedgerID":ledger,
                    "fields":[["id":"e1", "label":"Query", "value":"old", "selectionStart":3, "selectionEnd":3]]]), command: .reviseFormFields))) }
            if state == "authentication" { capture.finish(.failure(ComputerUseBrowserError.authenticationRequired)) }
            XCTAssertFalse(capture.needsRevisionReconciliation)
            XCTAssertThrowsError(try capture.reconcileRevision(reply, arguments: arguments, document: fixture.document, documentID: documentID, inputLedgerID: ledger))
        }
    }

    func testLaterPreparationResumesEachCapturedReadWithItsOriginalParent() async throws {
        for interrupted in [ComputerUseBrowserDOMCommand.extendFormFields, .bindPageFields, .prepareFormPreservation, .validateFormPreservation] {
            let fixture = try await make(category: true)
            defer { fixture.close() }
            let (first, action) = try await prepareLaterAction(fixture), owner = try fixture.owner()
            let history = owner.confirmedFormHistory, decisions = fixture.actions.inputs.count
            fixture.state.onCommand = { command in
                guard command == interrupted else { return }; fixture.state.onCommand = nil; owner.pause()
            }
            await expectFailure { _ = try await owner.prepareFormInput(for: action) }
            XCTAssertTrue(owner.hasPendingFormPreparation); XCTAssertFalse(owner.isOperating)
            await expectFailure { _ = try await owner.resumeFormPreparation() }
            try await owner.resumeAfterUserControl()
            let next = try await owner.resumeFormPreparation()
            XCTAssertEqual(next.interpretation.input, first.interpretation.input)
            XCTAssertEqual(next.evidence.fields.first { $0.control.label == "Query" }?.editable.snapshot.targetID,
                first.evidence.fields.first { $0.control.label == "Query" }?.editable.snapshot.targetID)
            XCTAssertEqual(next.previous?.nativePreservation, first.nativePreservation)
            XCTAssertEqual(next.nativePreservedSources, first.nativePreservedSources)
            XCTAssertEqual(next.previous?.inputOperationIDs.count, 1)
            XCTAssertEqual(owner.confirmedFormHistory, history)
            XCTAssertEqual(fixture.actions.inputs.count, decisions)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .extendFormFields }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .prepareFormPreservation }.count, 2)
            _ = try await owner.executeForm(.decode(content: categoryPlan(next), input: next), input: next)
            XCTAssertFalse(owner.hasPendingFormPreparation)
            XCTAssertEqual(owner.confirmedFormHistory.count, 2)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        }
    }

    func testLaterPreparationRejectsChangedNewOrEarlierCriterionWithoutAnotherExtension() async throws {
        for mutation in ["document.querySelector('select').value='concerts';", "document.getElementById('query').value='changed-during-pause';"] {
            let fixture = try await make(category: true, mutation: mutation)
            defer { fixture.close() }
            let (_, action) = try await prepareLaterAction(fixture), owner = try fixture.owner()
            let history = owner.confirmedFormHistory
            fixture.state.onCommand = { command in
                guard command == .extendFormFields else { return }; fixture.state.onCommand = nil; owner.pause()
            }
            await expectFailure { _ = try await owner.prepareFormInput(for: action) }
            try await release(fixture); try await owner.resumeAfterUserControl()
            await expectFailure { _ = try await owner.resumeFormPreparation() }
            XCTAssertTrue(owner.hasPendingFormPreparation)
            XCTAssertEqual(owner.confirmedFormHistory, history)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .extendFormFields }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .edit }.count, 2)
        }
    }

    func testLaterPreparationRejectsChangedReadonlyBaselineAfterNativeScopeExtension() async throws {
        let fixture = try await make(category: true, mutation: "document.getElementById('reference').value='changed-during-pause';")
        defer { fixture.close() }
        let (_, action) = try await prepareLaterAction(fixture), owner = try fixture.owner()
        let history = owner.confirmedFormHistory
        fixture.state.onCommand = { command in
            guard command == .prepareFormPreservation else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.prepareFormInput(for: action) }
        try await release(fixture); try await owner.resumeAfterUserControl()
        await expectFailure { _ = try await owner.resumeFormPreparation() }
        XCTAssertTrue(owner.hasPendingFormPreparation)
        XCTAssertEqual(owner.confirmedFormHistory, history)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .extendFormFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .prepareFormPreservation }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testLaterPreparationRejectsReplacedNewAndPreviouslyEditedObjects() async throws {
        for mutation in ["const c=document.querySelector('select'); c.replaceWith(c.cloneNode(true));", "const q=document.getElementById('query'); q.replaceWith(q.cloneNode(true));"] {
            let fixture = try await make(category: true, mutation: mutation)
            defer { fixture.close() }
            let (_, action) = try await prepareLaterAction(fixture), owner = try fixture.owner()
            let history = owner.confirmedFormHistory
            fixture.state.onCommand = { command in
                guard command == .extendFormFields else { return }; fixture.state.onCommand = nil; owner.pause()
            }
            await expectFailure { _ = try await owner.prepareFormInput(for: action) }
            try await release(fixture); try await owner.resumeAfterUserControl()
            await expectFailure { _ = try await owner.resumeFormPreparation() }
            XCTAssertEqual(owner.confirmedFormHistory, history)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .extendFormFields }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .edit }.count, 2)
        }
    }

    func testDriverResumesLaterPreparationBeforeSelectingAnotherAction() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (_, action) = try await prepareLaterAction(fixture), owner = try fixture.owner()
        fixture.state.onCommand = { command in
            guard command == .extendFormFields else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.prepareFormInput(for: action) }
        fixture.forms.select = { try self.categoryPlan($0) }
        fixture.actions.select = { _ in
            XCTAssertEqual(owner.confirmedFormHistory.count, 2, "Finish the retained later stage before choosing more work")
            return #"{"unavailable":true}"#
        }
        try await owner.resumeAfterUserControl(); _ = try await fixture.resume()
        XCTAssertFalse(owner.hasPendingFormPreparation)
        XCTAssertEqual(owner.confirmedFormHistory.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .extendFormFields }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testPriorStageRequestsCannotConsumeOrRetireLaterPreparation() async throws {
        for interrupted in [false, true] {
            let fixture = try await make(category: true)
            defer { fixture.close() }
            let (first, action) = try await prepareLaterAction(fixture), owner = try fixture.owner()
            let previousProposal = try ComputerUseBrowserFormProposal.decode(content: plan(first), input: first)
            if interrupted {
                fixture.state.onCommand = { command in
                    guard command == .extendFormFields else { return }; fixture.state.onCommand = nil; owner.pause()
                }
                await expectFailure { _ = try await owner.prepareFormInput(for: action) }
                try await owner.resumeAfterUserControl()
            } else { _ = try await owner.prepareFormInput(for: action) }
            let history = owner.confirmedFormHistory, commands = fixture.state.commands
            await expectFailure { _ = try await owner.executeForm(previousProposal, input: first) }
            await expectFailure { _ = try await owner.resumeForm() }
            await expectFailure { _ = try await owner.retirePendingUnsentForm() }
            await expectFailure { _ = try await owner.retainPendingFormPrefix() }
            XCTAssertTrue(owner.hasPendingFormPreparation)
            XCTAssertEqual(owner.confirmedFormHistory, history)
            XCTAssertEqual(fixture.state.commands, commands, "Reject competing predecessor requests before any native work")
            let next = try await owner.resumeFormPreparation()
            _ = try await owner.executeForm(.decode(content: categoryPlan(next), input: next), input: next)
            XCTAssertFalse(owner.hasPendingFormPreparation)
            XCTAssertEqual(owner.confirmedFormHistory.count, 2)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .extendFormFields }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        }
    }

    func testRetirementDuringLaterPreparationCannotPublishOrEditANewStage() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (_, action) = try await prepareLaterAction(fixture), owner = try fixture.owner()
        fixture.state.onCommand = { command in
            guard command == .extendFormFields else { return }; fixture.state.onCommand = nil; owner.retire()
        }
        await expectFailure { _ = try await owner.prepareFormInput(for: action) }
        XCTAssertFalse(owner.hasPendingFormPreparation)
        await expectFailure { _ = try await owner.resumeFormPreparation() }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .extendFormFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testClarificationKeepsLaterPreparationEvenWithoutExplicitReadonlyPreservation() async throws {
        let body = "<form action='/filtered'><label>Query<input name=q></label><label>Category<select name=category><option value=all>All</option><option value=concerts>Concerts</option></select></label><button>Search</button></form>"
        let fixture = try await ResearchDriverFixture.make(request: "Find concerts.", searchFormHTML: body)
        defer { fixture.close() }
        fixture.goal.select = { _ in #"{"disposition":"research","requirements":[{"turn":0,"source":"Find concerts.","role":"outcome","field":"category","relation":"unspecified","values":[]}],"question":{"topic":"none","requirements":[]}}"# }
        fixture.policy.choices = [false]
        _ = try await fixture.start()
        let owner = try fixture.owner()
        func configureStage(revising: Bool) {
            fixture.actions.select = { input in
                if let review = try FormEffectScopeFixture.response(input, editing: revising ? ["Category":[0]] : ["Query":[0]],
                    retaining: revising ? ["Query":[0]] : [:], deferring: revising ? [:] : ["Category":[0]], preserving: [:]) { return review }
                if input.formEffectScope != nil && !input.effectScopeAllowsActions { return #"{"unavailable":true}"# }
                let form = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Query" }?.form?.id)
                return try ResearchAnswerFixture.json(["form":form,"preserve":[]])
            }
        }
        configureStage(revising: false)
        let firstAction = try await owner.planNextAction(using: fixture.actions)
        let first = try await owner.prepareFormInput(for: firstAction)
        _ = try await owner.executeForm(.decode(content: plan(first), input: first), input: first)
        configureStage(revising: true)
        let action = try await owner.planNextAction(using: fixture.actions)
        let next = try await owner.prepareFormInput(for: action), history = owner.confirmedFormHistory
        XCTAssertNil(next.nativePreservation); XCTAssertTrue(next.scopeReview?.readControls.isEmpty == true)
        XCTAssertEqual(next.previous?.inputOperationIDs.count, 1)
        let question = try owner.issueQuestion(topic: .date, requirementIDs: [first.interpretation.requirements[0].id],
            controllerID: "phone", controllerSessionID: "session")
        _ = try owner.answerQuestion(questionID: question.id, answerTaskID: "later-answer", answer: "Tomorrow.",
            controllerID: "phone", controllerSessionID: "session")
        XCTAssertTrue(owner.hasPendingFormPreparation)
        XCTAssertEqual(owner.input.rootDigest, first.interpretation.input.rootDigest)
        await expectFailure { _ = try await owner.resumeFormPreparation() }
        XCTAssertEqual(owner.confirmedFormHistory, history)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .extendFormFields }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testGoalReviewKeepsPreservedPreparationAcrossMultipleAcceptedAnswers() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let (first, _) = try await prepare(fixture), owner = try fixture.owner(), original = owner.input
        _ = try answerPreparedQuestion(owner, input: first)
        XCTAssertTrue(owner.hasRevisedFormPreparationGoal)
        fixture.goal.select = nil; fixture.goal.base.questionTopic = .location
        let reviewed = try await owner.interpretGoal()
        let request = try XCTUnwrap(try owner.proposedQuestionRequest())
        XCTAssertEqual(request.topic, .location); XCTAssertEqual(request.inputDigest, owner.input.digest)
        XCTAssertEqual(reviewed.proposal.input, owner.input)
        let question = try owner.issueQuestion(topic: request.topic, requirementIDs: request.requirementIDs,
            controllerID: "phone", controllerSessionID: "session")
        let updated = try owner.answerQuestion(questionID: question.id, answerTaskID: "second-answer", answer: "Seattle.",
            controllerID: "phone", controllerSessionID: "session")
        fixture.goal.base.questionTopic = nil
        let finalReview = try await owner.interpretGoal()
        _ = try await owner.interpretGoal() // Reuse only the exact current interpretation.
        XCTAssertEqual(finalReview.proposal.input, updated)
        XCTAssertEqual(updated.userTurns, original.userTurns + ["Tomorrow.", "Seattle."])
        XCTAssertEqual(updated.rootDigest, original.rootDigest)
        XCTAssertEqual(updated.referenceMilliseconds, original.referenceMilliseconds)
        XCTAssertEqual(updated.timeZoneIdentifier, original.timeZoneIdentifier)
        XCTAssertEqual(fixture.goal.inputs.count, 3)
        XCTAssertTrue(owner.hasPendingFormPreparation)
        await expectFailure { _ = try await owner.resumeFormPreparation() }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .prepareFormPreservation }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testDriverAsksCurrentGoalQuestionBeforeTryingOldPreparation() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (_, action) = try await prepareLaterAction(fixture), owner = try fixture.owner()
        let prepared = try await owner.prepareFormInput(for: action), history = owner.confirmedFormHistory
        let updated = try answerPreparedQuestion(owner, input: prepared)
        fixture.goal.select = nil; fixture.goal.base.questionTopic = .location
        let decisions = fixture.actions.inputs.count, forms = fixture.forms.inputs.count
        let result = try await fixture.resume()
        guard case .browserClarificationRequired(let request) = result else { return XCTFail("Review the current answer before touching the old prepared form") }
        XCTAssertEqual(request.inputDigest, updated.digest); XCTAssertEqual(request.topic, .location)
        XCTAssertEqual(fixture.goal.inputs.last, updated)
        XCTAssertEqual(fixture.actions.inputs.count, decisions); XCTAssertEqual(fixture.forms.inputs.count, forms)
        XCTAssertEqual(owner.confirmedFormHistory, history)
        XCTAssertTrue(owner.hasPendingFormPreparation)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .extendFormFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testFreshGoalInterpretationAloneCannotReleasePreservedPreparation() async throws {
        for unsupported in [false, true] {
            let fixture = try await make()
            defer { fixture.close() }
            let (prepared, oldProposal) = try await prepare(fixture), owner = try fixture.owner()
            let updated = try answerPreparedQuestion(owner, input: prepared)
            fixture.goal.select = nil; fixture.goal.unsupported = unsupported
            let decisions = fixture.actions.inputs.count, forms = fixture.forms.inputs.count
            _ = try await owner.interpretGoal()
            XCTAssertEqual(fixture.goal.inputs.last, updated)
            XCTAssertTrue(owner.hasPendingFormPreparation); XCTAssertTrue(owner.hasRevisedFormPreparationGoal)
            await expectFailure { _ = try await owner.executeForm(oldProposal, input: prepared) }
            await expectFailure { _ = try await owner.planNextAction(using: fixture.actions) }
            await expectFailure { _ = try await owner.resumeFormPreparation() }
            XCTAssertEqual(fixture.actions.inputs.count, decisions)
            XCTAssertEqual(fixture.forms.inputs.count, forms)
            XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .prepareFormPreservation }.count, 2)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        }
    }

    func testUnchangedPreparedGoalReturnsItsExistingInterpretationWithoutAnotherProposal() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let (prepared, _) = try await prepare(fixture), owner = try fixture.owner()
        let decisions = fixture.goal.inputs.count, commands = fixture.state.commands
        let reviewed = try await owner.interpretGoal()
        XCTAssertEqual(reviewed.proposal, prepared.interpretation)
        XCTAssertFalse(owner.hasRevisedFormPreparationGoal); XCTAssertTrue(owner.hasPendingFormPreparation)
        XCTAssertEqual(fixture.goal.inputs.count, decisions); XCTAssertEqual(fixture.state.commands, commands)
    }

    func testCancellationDuringRevisedGoalReviewKeepsThePreparationAndRequiresHandback() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let (prepared, _) = try await prepare(fixture), owner = try fixture.owner()
        let updated = try answerPreparedQuestion(owner, input: prepared)
        fixture.goal.select = nil; fixture.goal.base.questionTopic = .location
        fixture.goal.base.beforeReply = { owner.pause() }
        await expectFailure { _ = try await owner.interpretGoal() }
        XCTAssertTrue(owner.hasPendingFormPreparation); XCTAssertFalse(owner.isOperating)
        let decisions = fixture.goal.inputs.count
        await expectFailure { _ = try await owner.interpretGoal() }
        XCTAssertEqual(fixture.goal.inputs.count, decisions)
        fixture.goal.base.beforeReply = nil
        try await owner.resumeAfterUserControl()
        XCTAssertThrowsError(try owner.proposedQuestionRequest(), "A cancelled interpretation must not be published")
        let reviewed = try await owner.interpretGoal()
        XCTAssertEqual(reviewed.proposal.input, updated)
        XCTAssertTrue(owner.hasPendingFormPreparation)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .prepareFormPreservation }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testGoalReviewStillRejectsAnUnfinishedFormExecution() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let (prepared, proposal) = try await prepare(fixture), owner = try fixture.owner()
        fixture.state.onCommand = { command in
            guard command == .edit else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.executeForm(proposal, input: prepared) }
        try await owner.resumeAfterUserControl()
        let decisions = fixture.goal.inputs.count
        await expectFailure { _ = try await owner.interpretGoal() }
        XCTAssertThrowsError(try owner.proposedQuestionRequest())
        XCTAssertTrue(owner.hasPendingForm); XCTAssertFalse(owner.hasPendingFormPreparation)
        XCTAssertEqual(fixture.goal.inputs.count, decisions)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testForeignGoalReviewCannotReplaceTheRetainedPreparationRevision() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let (prepared, _) = try await prepare(fixture), owner = try fixture.owner()
        let updated = try answerPreparedQuestion(owner, input: prepared)
        fixture.goal.select = nil; fixture.goal.base.replacement = prepared.interpretation.input
        await expectFailure { _ = try await owner.interpretGoal() }
        XCTAssertThrowsError(try owner.proposedQuestionRequest())
        XCTAssertTrue(owner.hasPendingFormPreparation); XCTAssertTrue(owner.hasRevisedFormPreparationGoal)
        XCTAssertEqual(owner.input, updated)
        fixture.goal.base.replacement = nil
        let reviewed = try await owner.interpretGoal()
        XCTAssertEqual(reviewed.proposal.input, updated)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .prepareFormPreservation }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testRevisedFormReviewCarriesOriginalSourcesAndCanSelectPreviouslyDeferredFields() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (prepared, _) = try await prepare(fixture, category: true), owner = try fixture.owner()
        let current = try await beginPreparationReview(fixture, input: prepared)
        fixture.actions.select = { input in
            try FormEffectScopeFixture.response(input, editing: ["Query":[0],"Category":[0]], preserving: ["Reference":0]) ?? #"{"unavailable":true}"#
        }
        let action = try await owner.reviewFormPreparation(using: fixture.actions)
        guard case .editForm(let id) = action.step else { return XCTFail("Expected a fresh form review") }
        XCTAssertEqual(id, prepared.selectedFormID); XCTAssertEqual(action.input.interpretation, current)
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(action.input.contextJSON.utf8)) as? [String: Any])
        XCTAssertEqual(context["version"] as? Int, 19)
        let retained = try XCTUnwrap(context["retained_form_preparation"] as? [String: Any])
        XCTAssertEqual(retained["executed"] as? Bool, false)
        let sources = try XCTUnwrap(retained["preservation_sources"] as? [[String: Any]])
        let source = try XCTUnwrap(sources.first?["source"] as? [String: Any])
        XCTAssertEqual(source["source"] as? String, "Leave Reference unchanged. ")
        XCTAssertEqual(source["role_at_edit"] as? String, "condition")
        XCTAssertEqual(source["requirements"] as? [Int], [0], "Resegmentation changes references, not original source bytes")
        let category = try XCTUnwrap(action.input.evidence.page.controls.first { $0.label == "Category" }?.id)
        let historical = try XCTUnwrap(retained["previous_field_intents"] as? [[String: Any]])
        XCTAssertEqual(historical.first { $0["control"] as? String == category }?["disposition"] as? String, "deferred")
        XCTAssertEqual(action.input.formEffectScope?.fieldIntents.first { $0.controlID == category }?.disposition, .edit)
        XCTAssertFalse(action.input.contextJSON.contains("private-reference"))
        XCTAssertFalse(action.input.contextJSON.contains(try XCTUnwrap(prepared.nativePreservation?.id)))
        XCTAssertTrue(ComputerUseLocalBrowserActionPlanner.instructions(for: action.input).contains("not semantic equivalence"))
        XCTAssertTrue(owner.hasPendingFormPreparation)
        await expectFailure { _ = try await owner.prepareFormInput(for: action) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .prepareFormPreservation }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit || $0 == .extendFormFields }.count, 0)
    }

    func testRevisedFormReviewReusesItsDecisionAfterMetadataValidationAndHandback() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let (prepared, _) = try await prepare(fixture), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: prepared)
        let action = try await owner.reviewFormPreparation(using: fixture.actions), decisions = fixture.actions.inputs.count
        let cached = try await owner.reviewFormPreparation(using: fixture.actions)
        XCTAssertEqual(cached, action)
        owner.pause()
        await expectFailure { _ = try await owner.reviewFormPreparation(using: fixture.actions) }
        try await owner.resumeAfterUserControl()
        let resumed = try await owner.reviewFormPreparation(using: fixture.actions)
        XCTAssertEqual(resumed, action)
        XCTAssertEqual(fixture.actions.inputs.count, decisions)
        let commands = fixture.state.commands
        await expectFailure { _ = try await owner.reviewFormPreparation(using: fixture.actions, budget: .zero) }
        XCTAssertEqual(fixture.state.commands, commands)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .prepareFormPreservation }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testRevisedReviewCannotResetItsCarriedPreservationBySelectingTheFormAgain() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let (prepared, _) = try await prepare(fixture), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: prepared)
        fixture.actions.select = { input in
            XCTAssertEqual(input.formEffectScope?.preservedControls.count, 1)
            return try ResearchAnswerFixture.json(["form":try XCTUnwrap(input.formIDs.first),"preserve":[]])
        }
        await expectFailure { _ = try await owner.reviewFormPreparation(using: fixture.actions) }
        XCTAssertTrue(owner.hasPendingFormPreparation)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .prepareFormPreservation }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testRevisedLaterPreparationReviewKeepsVerifiedCriteriaAndReceiptsHistorical() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (_, action) = try await prepareLaterAction(fixture), owner = try fixture.owner()
        let prepared = try await owner.prepareFormInput(for: action), history = owner.confirmedFormHistory
        _ = try await beginPreparationReview(fixture, input: prepared)
        configure(fixture, category: true, revising: true)
        let revised = try await owner.reviewFormPreparation(using: fixture.actions)
        let query = try XCTUnwrap(revised.input.evidence.page.controls.first { $0.label == "Query" }?.id)
        XCTAssertEqual(revised.input.formEffectScope?.fieldIntents.first { $0.controlID == query }?.disposition, .retain)
        XCTAssertEqual(revised.input.preparationReview?.preservedSources, prepared.previous?.preservedControls)
        XCTAssertEqual(owner.confirmedFormHistory, history)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .extendFormFields }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .prepareFormPreservation }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testChangedOriginalMetadataBlocksRevisedReviewBeforeAnotherActionProposal() async throws {
        let fixture = try await make(mutation: "document.getElementById('query').setAttribute('aria-label','Changed query');")
        defer { fixture.close() }
        let (prepared, _) = try await prepare(fixture), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: prepared)
        try await release(fixture)
        let decisions = fixture.actions.inputs.count
        await expectFailure { _ = try await owner.reviewFormPreparation(using: fixture.actions) }
        XCTAssertEqual(fixture.actions.inputs.count, decisions)
        XCTAssertTrue(owner.hasPendingFormPreparation)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .prepareFormPreservation }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testCancelledRevisedFormReviewRetainsPreparationAndReconsidersOnlyAfterHandback() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let (prepared, _) = try await prepare(fixture), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: prepared)
        fixture.actions.beforeReply = { owner.pause() }
        await expectFailure { _ = try await owner.reviewFormPreparation(using: fixture.actions) }
        let decisions = fixture.actions.inputs.count
        await expectFailure { _ = try await owner.reviewFormPreparation(using: fixture.actions) }
        XCTAssertEqual(fixture.actions.inputs.count, decisions)
        XCTAssertTrue(owner.hasPendingFormPreparation); XCTAssertFalse(owner.isOperating)
        fixture.actions.beforeReply = nil
        try await owner.resumeAfterUserControl()
        _ = try await owner.reviewFormPreparation(using: fixture.actions)
        XCTAssertGreaterThan(fixture.actions.inputs.count, decisions)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .prepareFormPreservation }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testRetirementDuringRevisedReviewCannotPublishANewPreparation() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let (prepared, _) = try await prepare(fixture), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: prepared)
        fixture.actions.beforeReply = { owner.retire() }
        await expectFailure { _ = try await owner.reviewFormPreparation(using: fixture.actions) }
        XCTAssertFalse(owner.hasPendingFormPreparation)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testRevisedFormReviewRequiresSourcePolicyForTheAcceptedAnswer() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let (prepared, _) = try await prepare(fixture), owner = try fixture.owner()
        _ = try answerPreparedQuestion(owner, input: prepared)
        fixture.goal.select = nil
        let interpretation = try await owner.interpretGoal(), decisions = fixture.actions.inputs.count
        await expectFailure { _ = try await owner.reviewFormPreparation(using: fixture.actions) }
        XCTAssertEqual(fixture.actions.inputs.count, decisions)
        let sources = try XCTUnwrap(try fixture.policy.sources(for: interpretation))
        try owner.configureResearchSources(sources)
        _ = try await owner.reviewFormPreparation(using: fixture.actions)
        XCTAssertGreaterThan(fixture.actions.inputs.count, decisions)
        XCTAssertTrue(owner.hasPendingFormPreparation)
    }

    func testRevisedMetadataReviewCanAskACurrentQuestionWithoutConsumingPreparation() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let (prepared, _) = try await prepare(fixture), owner = try fixture.owner()
        let current = try await beginPreparationReview(fixture, input: prepared)
        fixture.actions.select = { _ in #"{"question":{"topic":"location","requirements":[0]}}"# }
        let forms = fixture.forms.inputs.count
        let result = try await fixture.resume()
        guard case .browserClarificationRequired(let request) = result else { return XCTFail("Keep a question from the revised metadata review") }
        XCTAssertEqual(request.inputDigest, current.input.digest); XCTAssertEqual(request.topic, .location)
        XCTAssertTrue(owner.hasPendingFormPreparation)
        XCTAssertEqual(fixture.forms.inputs.count, forms)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .prepareFormPreservation }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testPreparationReviewPurposesCannotProjectIntoAForeignRootTask() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let (prepared, _) = try await prepare(fixture)
        let context = try ComputerUseBrowserFormPreparationReviewContext(interpretation: prepared.interpretation, page: prepared.evidence.page,
            review: XCTUnwrap(prepared.scopeReview), previous: prepared.previous)
        let foreign = try ComputerUseBrowserGoalInput(taskID: "another-root", prompt: prepared.interpretation.input.prompt,
            referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: prepared.interpretation.input.timeZoneIdentifier)
        let proposal = try await BrowserResearchGoalFixture().propose(foreign)
        XCTAssertThrowsError(try context.validate(interpretation: proposal, evidence: prepared.evidence.page))
        XCTAssertThrowsError(try context.preservation(in: proposal))
        XCTAssertThrowsError(try context.readings(in: proposal))
        XCTAssertThrowsError(try context.context(in: proposal))
        XCTAssertFalse(String(describing: context).contains("Reference"))
    }

    func testFormEvidenceRetainsItsSealedAdapterAcrossEquivalentObservationNonces() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let (prepared, _) = try await prepare(fixture)
        let current = try await fixture.browser.observePage(document: prepared.evidence.page.document)
        let carried = try prepared.evidence.retainingOriginalPage(current)
        XCTAssertEqual(carried.page, current); XCTAssertEqual(carried.fields, prepared.evidence.fields)
        XCTAssertEqual(try carried.retainingOriginalPage(prepared.evidence.page), prepared.evidence)
    }

    func testFormEvidenceCannotAdoptChangedPageContentAsItsOriginalObservation() async throws {
        let fixture = try await make(mutation: "document.getElementById('query').setAttribute('aria-label','Changed query');")
        defer { fixture.close() }
        let (prepared, _) = try await prepare(fixture)
        try await release(fixture)
        let changed = try await fixture.browser.observePage(document: prepared.evidence.page.document)
        XCTAssertFalse(changed.page.matchesFormObservation(prepared.evidence.page.page))
        XCTAssertThrowsError(try prepared.evidence.retainingOriginalPage(changed))
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testPreparedNativeRevisionAddsDeferredFieldsWithoutReplacingTheOriginalBaseline() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (_, frame, input) = try await standalonePreparation(fixture)
        let capture = try ComputerUseBrowserDOMReadCapture(command: .reviseFormFields, document: input.evidence.page.document)
        let fields = try await revise(fixture, frame: frame, input: input, capture: capture)
        XCTAssertEqual(Set(fields.map(\.label)), ["Query","Category"])
        XCTAssertTrue(fields.contains(try XCTUnwrap(input.evidence.fields.first).editable))
        let category = try XCTUnwrap(fields.first { $0.label == "Category" })
        XCTAssertEqual(category.choices?.first { $0.id == category.snapshot.value }?.label, "All")
        XCTAssertEqual(frame.target.formPreservation, input.nativePreservation)
        let retained = try await revise(fixture, frame: frame, input: input, capture: capture)
        XCTAssertEqual(retained, fields)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
        let nativeRetained = try await revise(fixture, frame: frame, input: input)
        XCTAssertEqual(nativeRetained, fields)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 2)
        let page = try await frame.restoreForReview(browser: fixture.browser, checkCurrent: {})
        let bound = try await frame.target.bindFields(fields, to: page)
        XCTAssertEqual(Set(bound.fields.map { $0.control.label }), ["Query","Category"])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .prepareFormPreservation }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testPreparedNativeRetryRejectsAChangedNewFieldInsteadOfRecapturingIt() async throws {
        let fixture = try await make(category: true, mutation: "document.querySelector('select').value='concerts';")
        defer { fixture.close() }
        let (_, frame, input) = try await standalonePreparation(fixture)
        let fields = try await revise(fixture, frame: frame, input: input)
        let category = try XCTUnwrap(fields.first { $0.label == "Category" })
        XCTAssertEqual(category.choices?.first { $0.id == category.snapshot.value }?.label, "All")
        try await release(fixture)
        await expectFailure { _ = try await revise(fixture, frame: frame, input: input) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testNativePreCaptureRejectionSealsItsIDAfterTheOriginalValueReturns() async throws {
        let mutation = "document.getElementById('query').value='changed';fetch('/signal').then(()=>{document.getElementById('query').value='';fetch('/restored');});"
        let fixture = try await make(category: true, mutation: mutation)
        defer { fixture.close() }
        let (_, frame, input) = try await standalonePreparation(fixture)
        let capture = try ComputerUseBrowserDOMReadCapture(command: .reviseFormFields, document: input.evidence.page.document)
        try await release(fixture)
        await expectFailure { _ = try await revise(fixture, frame: frame, input: input, capture: capture) }
        XCTAssertTrue(frame.target.revisionWasNotCaptured(capture))
        XCTAssertEqual(frame.preparedInput, input)
        try await releaseSecondSignal(fixture)
        await expectFailure { _ = try await revise(fixture, frame: frame, input: input, capture: capture) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
        let retry = try ComputerUseBrowserDOMReadCapture(command: .reviseFormFields, document: input.evidence.page.document)
        await expectFailure { _ = try await revise(fixture, frame: frame, input: input, capture: retry) }
        XCTAssertFalse(frame.target.revisionWasNotCaptured(retry))
        let fields = try await revise(fixture, frame: frame, input: input, purpose: "fresh-reviewed-scope")
        XCTAssertEqual(Set(fields.map(\.label)), ["Query","Category"])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 3)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testCompletedNativeRevisionCannotLaterReportThatItCapturedNothing() async throws {
        let fixture = try await make(category: true, mutation: "document.getElementById('query').value='changed';")
        defer { fixture.close() }
        let (_, frame, input) = try await standalonePreparation(fixture)
        let completed = try ComputerUseBrowserDOMReadCapture(command: .reviseFormFields, document: input.evidence.page.document)
        let fields = try await revise(fixture, frame: frame, input: input, capture: completed)
        XCTAssertEqual(Set(fields.map(\.label)), ["Query","Category"])
        try await release(fixture)
        let later = try ComputerUseBrowserDOMReadCapture(command: .reviseFormFields, document: input.evidence.page.document)
        await expectFailure { _ = try await revise(fixture, frame: frame, input: input, capture: later) }
        XCTAssertFalse(frame.target.revisionWasNotCaptured(completed))
        XCTAssertFalse(frame.target.revisionWasNotCaptured(later))
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testReconciledRevisionReturnsItsOriginalFieldsWithoutRecapture() async throws {
        for changed in [false, true] {
            let fixture = try await make(category: true, mutation: "document.querySelector('select').value='concerts';")
            defer { fixture.close() }
            let (_, frame, input) = try await standalonePreparation(fixture)
            let (capture, _, reply) = try await lostRevisionCallback(fixture, frame: frame, input: input)
            XCTAssertEqual(reply?.status, "ok")
            if changed { try await release(fixture) }
            let fields = try await revise(fixture, frame: frame, input: input, capture: capture)
            let category = try XCTUnwrap(fields.first { $0.label == "Category" })
            XCTAssertEqual(category.choices?.first { $0.id == category.snapshot.value }?.label, "All")
            XCTAssertFalse(capture.needsRevisionReconciliation); XCTAssertTrue(capture.didStart)
            let retained = try await revise(fixture, frame: frame, input: input, capture: capture)
            XCTAssertEqual(retained, fields)
            let page = try await frame.restoreForReview(browser: fixture.browser, checkCurrent: {})
            if changed { await expectFailure { _ = try await frame.target.bindFields(fields, to: page) } }
            else { _ = try await frame.target.bindFields(fields, to: page) }
            XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .inspectPreparedRevision }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        }
    }

    func testRevisionHistoryReconcilesAnExplicitPreCaptureRejection() async throws {
        let fixture = try await make(category: true, mutation: "document.getElementById('query').value='changed';")
        defer { fixture.close() }
        let (_, frame, input) = try await standalonePreparation(fixture)
        try await release(fixture)
        let (capture, _, reply) = try await lostRevisionCallback(fixture, frame: frame, input: input)
        XCTAssertEqual(reply?.status, "revision-not-captured")
        XCTAssertFalse(frame.target.revisionWasNotCaptured(capture))
        await expectFailure { _ = try await revise(fixture, frame: frame, input: input, capture: capture) }
        XCTAssertTrue(frame.target.revisionWasNotCaptured(capture)); XCTAssertFalse(capture.needsRevisionReconciliation)
        await expectFailure { _ = try await revise(fixture, frame: frame, input: input, capture: capture) }
        XCTAssertEqual(frame.preparedInput, input)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .inspectPreparedRevision }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testRevisionHistoryCannotReconstructMissingSupersededOrUnpreservedCaptures() async throws {
        for state in ["missing","superseded","preservation"] {
            let fixture = try await make(category: true, mutation: "document.getElementById('reference').value='changed';")
            defer { fixture.close() }
            let (_, frame, input) = try await standalonePreparation(fixture)
            let (capture, _, _) = try await lostRevisionCallback(fixture, frame: frame, input: input, dispatching: state != "missing")
            if state == "superseded" { _ = try await revise(fixture, frame: frame, input: input, purpose: "later-reviewed-capture") }
            if state == "preservation" { try await release(fixture) }
            let attempts = fixture.state.commands.filter { $0 == .reviseFormFields }.count
            await expectFailure { _ = try await revise(fixture, frame: frame, input: input, capture: capture) }
            XCTAssertTrue(capture.needsRevisionReconciliation)
            XCTAssertFalse(frame.target.revisionWasNotCaptured(capture))
            XCTAssertEqual(frame.preparedInput, input)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, attempts)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        }
    }

    func testRevisionHistoryRequiresTheEntireOriginalRequest() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (_, frame, input) = try await standalonePreparation(fixture)
        let (capture, arguments, _) = try await lostRevisionCallback(fixture, frame: frame, input: input)
        let page = try await frame.restoreForReview(browser: fixture.browser, checkCurrent: {})
        var current = arguments; current["snapshotID"] = page.page.id
        for replacement: [String: Any] in [["scopeDigest":String(repeating: "d", count: 64)], ["selectedControlIDs":[]],
            ["requirements":["digest":"changed-private-requirements"]], ["unexpected":true]] {
            let changed = current.merging(replacement) { _, new in new }
            let rejected = try await fixture.browser.callDOM(.inspectPreparedRevision, arguments: changed, document: page.document)
            XCTAssertEqual(rejected.status, "stale"); XCTAssertNil(rejected.fields); XCTAssertNil(rejected.recoveredRevisionID)
        }
        let fields = try await revise(fixture, frame: frame, input: input, capture: capture)
        XCTAssertEqual(Set(fields.map(\.label)), ["Query","Category"])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testPartialNativeRevisionFailureCannotRecaptureAFieldAfterItBecomesReadable() async throws {
        let mutation = "document.getElementById('city').value='x'.repeat(1048577);fetch('/signal').then(()=>{document.getElementById('city').value='';fetch('/restored');});"
        let fixture = try await make(category: true, city: true, mutation: mutation)
        defer { fixture.close() }
        _ = try await fixture.start()
        configureMixed(fixture, editing: ["Query"], deferring: ["Category","City"])
        let action = try await fixture.owner().planNextAction(using: fixture.actions)
        let frame = try ComputerUseBrowserResearchFormPreparation(action: action, browser: fixture.browser)
        let input = try await frame.prepare(browser: fixture.browser, checkCurrent: {})
        try await release(fixture)
        let (capture, _, reply) = try await lostRevisionCallback(fixture, frame: frame, input: input, selecting: ["City"])
        XCTAssertEqual(reply?.status, "limit")
        try await releaseSecondSignal(fixture)
        await expectFailure { _ = try await revise(fixture, frame: frame, input: input, capture: capture, selecting: ["City"]) }
        XCTAssertTrue(capture.needsRevisionReconciliation); XCTAssertFalse(frame.target.revisionWasNotCaptured(capture))
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .inspectPreparedRevision }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testCancelledHistoricalRevisionReadDoesNotReleaseItsFailedCapture() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (_, frame, input) = try await standalonePreparation(fixture)
        let (capture, _, _) = try await lostRevisionCallback(fixture, frame: frame, input: input)
        var operation: Task<[ComputerUseTextField], Error>?
        fixture.state.onCommand = { command in
            guard command == .inspectPreparedRevision else { return }; fixture.state.onCommand = nil; operation?.cancel()
        }
        operation = Task { @MainActor in try await self.revise(fixture, frame: frame, input: input, capture: capture) }
        let pending = try XCTUnwrap(operation)
        await expectFailure { _ = try await pending.value }
        XCTAssertTrue(capture.didStart); XCTAssertTrue(capture.needsRevisionReconciliation)
        let fields = try await revise(fixture, frame: frame, input: input, capture: capture)
        XCTAssertEqual(Set(fields.map(\.label)), ["Query","Category"])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .inspectPreparedRevision }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testPreparedHostCaptureRemainsHistoricalAndFreshBindingRejectsChangedNewValues() async throws {
        let fixture = try await make(category: true, mutation: "document.querySelector('select').value='concerts';")
        defer { fixture.close() }
        let (_, frame, input) = try await standalonePreparation(fixture)
        let capture = try ComputerUseBrowserDOMReadCapture(command: .reviseFormFields, document: input.evidence.page.document)
        let fields = try await revise(fixture, frame: frame, input: input, capture: capture)
        try await release(fixture)
        let retained = try await revise(fixture, frame: frame, input: input, capture: capture)
        XCTAssertEqual(retained, fields)
        let category = try XCTUnwrap(retained.first { $0.label == "Category" })
        XCTAssertEqual(category.choices?.first { $0.id == category.snapshot.value }?.label, "All")
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
        let page = try await frame.restoreForReview(browser: fixture.browser, checkCurrent: {})
        await expectFailure { _ = try await frame.target.bindFields(retained, to: page) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testPreparedRevisionRejectsChangedOriginalValuesAndReplacementObjects() async throws {
        for mutation in ["document.getElementById('query').value='changed';",
                         "const q=document.getElementById('query'); q.replaceWith(q.cloneNode(true));"] {
            let fixture = try await make(category: true, mutation: mutation)
            defer { fixture.close() }
            let (_, frame, input) = try await standalonePreparation(fixture)
            try await release(fixture)
            await expectFailure { _ = try await revise(fixture, frame: frame, input: input) }
            XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
            XCTAssertEqual(frame.preparedInput, input)
        }
    }

    func testPreparedRevisionRetainsOriginalReadonlyPreservationBeforeReadingNewFields() async throws {
        let fixture = try await make(category: true, mutation: "document.getElementById('reference').value='changed';")
        defer { fixture.close() }
        let (_, frame, input) = try await standalonePreparation(fixture)
        try await release(fixture)
        await expectFailure { _ = try await revise(fixture, frame: frame, input: input) }
        XCTAssertEqual(frame.target.formPreservation, input.nativePreservation)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .prepareFormPreservation }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testCancelledPreparedRevisionJoinsItsCallbackAndReusesTheCapturedFields() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (_, frame, input) = try await standalonePreparation(fixture)
        let capture = try ComputerUseBrowserDOMReadCapture(command: .reviseFormFields, document: input.evidence.page.document)
        var operation: Task<[ComputerUseTextField], Error>?
        fixture.state.onCommand = { command in
            guard command == .reviseFormFields else { return }
            fixture.state.onCommand = nil; operation?.cancel()
        }
        operation = Task { @MainActor in try await self.revise(fixture, frame: frame, input: input, capture: capture) }
        let pending = try XCTUnwrap(operation)
        await expectFailure { _ = try await pending.value }
        XCTAssertTrue(capture.didStart)
        let fields = try await revise(fixture, frame: frame, input: input, capture: capture)
        XCTAssertEqual(Set(fields.map(\.label)), ["Query","Category"])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
        let page = try await frame.restoreForReview(browser: fixture.browser, checkCurrent: {})
        _ = try await frame.target.bindFields(fields, to: page)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testPreparedRevisionKeepsEveryVerifiedEarlierInputReceipt() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (action, frame, input) = try await standalonePreparation(fixture)
        let stage = try await executeStandalone(fixture, frame: frame, input: input)
        let later = try ComputerUseBrowserResearchFormPreparation(action: action, browser: fixture.browser, parent: stage)
        let current = try await later.prepare(browser: fixture.browser, checkCurrent: {})
        XCTAssertEqual(current.previous?.inputOperationIDs.count, 1)
        let before = try later.target.preparedFormRequirements(from: current)
        let fields = try await revise(fixture, frame: later, input: current)
        XCTAssertEqual(fields.first { $0.label == "Query" }?.snapshot.value, "concerts")
        let category = try XCTUnwrap(fields.first { $0.label == "Category" })
        XCTAssertEqual(category.choices?.first { $0.id == category.snapshot.value }?.label, "All")
        let after = try later.target.preparedFormRequirements(from: current)
        XCTAssertEqual(before.digest, after.digest)
        XCTAssertEqual(after.domArguments["inputOperationIDs"] as? [String], current.previous?.inputOperationIDs)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
    }

    func testPreparedRevisionRejectsChangedSelectionEvenWhenEarlierInputValueMatches() async throws {
        let fixture = try await make(category: true, mutation: "document.getElementById('query').setSelectionRange(0,0);")
        defer { fixture.close() }
        let (action, frame, input) = try await standalonePreparation(fixture)
        let stage = try await executeStandalone(fixture, frame: frame, input: input)
        let later = try ComputerUseBrowserResearchFormPreparation(action: action, browser: fixture.browser, parent: stage)
        let current = try await later.prepare(browser: fixture.browser, checkCurrent: {})
        let original = try XCTUnwrap(current.evidence.fields.first { $0.control.label == "Query" })
        XCTAssertNotEqual(original.editable.snapshot.selection, NSRange(location: 0, length: 0))
        try await release(fixture)
        let observed = try await later.target.read(targetID: original.editable.snapshot.targetID)
        XCTAssertEqual(observed?.value, original.editable.snapshot.value)
        XCTAssertEqual(observed?.selection, NSRange(location: 0, length: 0))
        await expectFailure { _ = try await revise(fixture, frame: later, input: current) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testPreparedRevisionRejectsAnUnaccountedInputEvenAfterOriginalValueIsRestored() async throws {
        let fixture = try await make(category: true, mutation: "const q=document.getElementById('query'); q.value=''; q.setSelectionRange(0,0);")
        defer { fixture.close() }
        let (_, frame, input) = try await standalonePreparation(fixture)
        _ = try await executeStandalone(fixture, frame: frame, input: input)
        try await release(fixture)
        let original = try XCTUnwrap(input.evidence.fields.first { $0.control.label == "Query" })
        let observed = try await frame.target.read(targetID: original.editable.snapshot.targetID)
        XCTAssertEqual(observed, original.editable.snapshot)
        XCTAssertNil(input.previous)
        await expectFailure { _ = try await revise(fixture, frame: frame, input: input) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testPreparedRevisionRejectsALostInputLedgerEvenWhenAllValuesStillMatch() async throws {
        let fixture = try await make(category: true, referenceReadOnly: false)
        defer { fixture.close() }
        let (action, frame, input) = try await standalonePreparation(fixture)
        XCTAssertNil(input.nativePreservation)
        let stage = try await executeStandalone(fixture, frame: frame, input: input)
        let later = try ComputerUseBrowserResearchFormPreparation(action: action, browser: fixture.browser, parent: stage)
        let current = try await later.prepare(browser: fixture.browser, checkCurrent: {})
        XCTAssertEqual(current.previous?.inputOperationIDs.count, 1)
        let other = ComputerUseBrowserTextTarget(browser: fixture.browser, document: current.evidence.page.document, requiresFrontmost: false)
        let rediscovered = try await other.fields()
        for original in current.evidence.fields {
            XCTAssertEqual(rediscovered.first { $0.label == original.editable.label }?.snapshot.value, original.editable.snapshot.value)
        }
        await expectFailure { _ = try await revise(fixture, frame: later, input: current) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testPreparedRequirementsCannotAuthorizeQueryPreparationOrVerifiedInspection() async throws {
        for withPrevious in [false, true] {
            let fixture = try await make(category: true)
            defer { fixture.close() }
            let (action, initial, input) = try await standalonePreparation(fixture)
            let frame: ComputerUseBrowserResearchFormPreparation, current: ComputerUseBrowserResearchFormInput
            if withPrevious {
                let stage = try await executeStandalone(fixture, frame: initial, input: input)
                frame = try .init(action: action, browser: fixture.browser, parent: stage)
                current = try await frame.prepare(browser: fixture.browser, checkCurrent: {})
            } else { frame = initial; current = input }
            let requirements = try frame.target.preparedFormRequirements(from: current)
            XCTAssertEqual((requirements.domArguments["inputOperationIDs"] as? [String])?.count, withPrevious ? 1 : 0)
            XCTAssertFalse(String(describing: requirements).contains("private-reference"))
            for command in [ComputerUseBrowserDOMCommand.prepareFormQuery, .inspectFormRequirements] {
                let page = try await frame.restoreForReview(browser: fixture.browser, checkCurrent: {})
                let submit = try XCTUnwrap(page.page.controls.first { $0.kind == "submit" })
                let result = try await fixture.browser.callDOM(command, arguments: ["documentID":page.documentID,"snapshotID":page.page.id,
                    "controlID":submit.id,"requirements":requirements.domArguments,"repairableFieldIDs":[String]()], document: page.document)
                XCTAssertEqual(result.status, "stale"); XCTAssertNil(result.fields); XCTAssertNil(result.formQuery)
            }
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, withPrevious ? 1 : 0)
            XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=all"), 0)
        }
    }

    func testPreparedRevisionRejectsChangedArgumentsAndCannotReactivateAnOlderScope() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (_, frame, input) = try await standalonePreparation(fixture)
        let first = try await revise(fixture, frame: frame, input: input)
        await expectFailure { _ = try await revise(fixture, frame: frame, input: input, selecting: ["Query"]) }
        let next = try await revise(fixture, frame: frame, input: input, purpose: "second-reviewed-scope")
        XCTAssertEqual(next, first)
        await expectFailure { _ = try await revise(fixture, frame: frame, input: input) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 4)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testPreparedRequirementsRejectAForeignAdapterBeforeDispatch() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (_, frame, input) = try await standalonePreparation(fixture)
        let other = ComputerUseBrowserTextTarget(browser: fixture.browser, document: input.evidence.page.document, requiresFrontmost: false)
        let commands = fixture.state.commands.count
        XCTAssertThrowsError(try other.preparedFormRequirements(from: input))
        XCTAssertEqual(fixture.state.commands.count, commands)
        XCTAssertNoThrow(try frame.target.preparedFormRequirements(from: input))
        XCTAssertEqual(fixture.state.commands.count, commands)
    }

    func testApplyingPreparedReviewKeepsDeferredCapturedFieldsAsUneditableInvariants() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (original, oldProposal) = try await prepare(fixture, category: true), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: original)
        configurePreparedRevision(fixture)
        let reviewed = try await owner.reviewFormPreparation(using: fixture.actions)
        let current = try await owner.applyFormPreparationReview(reviewed)
        XCTAssertEqual(current.interpretation.input, owner.input)
        XCTAssertFalse(owner.hasRevisedFormPreparationGoal); XCTAssertTrue(owner.hasPendingFormPreparation)
        let query = try XCTUnwrap(original.evidence.fields.first { $0.control.label == "Query" })
        XCTAssertTrue(current.evidence.fields.contains { $0.editable == query.editable })
        XCTAssertEqual(try current.editableFieldAliases.map { try current.field(for: $0).control.label }, ["Category"])
        XCTAssertEqual(current.preparationBaseline?.capturedTargetIDs, [query.editable.snapshot.targetID])
        XCTAssertEqual(current.nativePreservedSources, original.nativePreservedSources)
        let context = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(current.contextJSON.utf8)) as? [String: Any])
        XCTAssertEqual(context["version"] as? Int, 13)
        XCTAssertEqual((context["captured_unedited_fields"] as? [String])?.count, 1)
        XCTAssertFalse(current.contextJSON.contains("private-reference"))
        XCTAssertFalse(String(describing: current.preparationBaseline).contains(query.editable.snapshot.targetID))
        let proposal = try ComputerUseBrowserFormProposal.decode(content: categoryPlan(current), input: current)
        let contract = try XCTUnwrap(proposal.textContract(for: current))
        XCTAssertEqual(contract.unchangedValues[query.editable.snapshot.targetID], query.editable.snapshot.value)
        await expectFailure { _ = try await owner.executeForm(oldProposal, input: original) }
        _ = try await owner.executeForm(proposal, input: current)
        XCTAssertFalse(owner.hasPendingFormPreparation)
        XCTAssertEqual(owner.confirmedFormHistory.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testDriverAppliesARevisedScopeAndExecutesOnlyTheCurrentFormPlan() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (original, _) = try await prepare(fixture, category: true), owner = try fixture.owner()
        let updated = try answerPreparedQuestion(owner, input: original)
        fixture.goal.select = nil; configurePreparedRevision(fixture)
        fixture.forms.select = { input in
            XCTAssertEqual(input.interpretation.input, updated)
            XCTAssertNotNil(input.preparationBaseline)
            return try self.categoryPlan(input)
        }
        _ = try await fixture.resume()
        XCTAssertFalse(owner.hasPendingFormPreparation)
        XCTAssertEqual(owner.confirmedFormHistory.count, 1)
        XCTAssertEqual(fixture.forms.inputs.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testAppliedRevisionResumesEachNativePhaseWithoutReplacingItsOriginalPreparation() async throws {
        for boundary in [ComputerUseBrowserDOMCommand.reviseFormFields, .bindPageFields, .prepareFormPreservation, .validateFormPreservation] {
            let fixture = try await make(category: true)
            defer { fixture.close() }
            let (original, _) = try await prepare(fixture, category: true), owner = try fixture.owner()
            _ = try await beginPreparationReview(fixture, input: original); configurePreparedRevision(fixture)
            let reviewed = try await owner.reviewFormPreparation(using: fixture.actions), decisions = fixture.actions.inputs.count
            var revising = false
            fixture.state.onCommand = { command in
                if command == .reviseFormFields { revising = true }
                guard revising, command == boundary else { return }
                fixture.state.onCommand = nil; owner.pause()
            }
            await expectFailure { _ = try await owner.applyFormPreparationReview(reviewed) }
            XCTAssertTrue(owner.hasPendingFormPreparation); XCTAssertFalse(owner.hasRevisedFormPreparationGoal)
            await expectFailure { _ = try await owner.resumeFormPreparation() }
            try await owner.resumeAfterUserControl()
            let current = try await owner.resumeFormPreparation()
            XCTAssertEqual(fixture.actions.inputs.count, decisions)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .prepareFormPreservation }.count, 2)
            XCTAssertEqual(current.nativePreservedSources, original.nativePreservedSources)
            _ = try await owner.executeForm(.decode(content: categoryPlan(current), input: current), input: current)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        }
    }

    func testChangedNewFieldOrReadonlyGuardBlocksAppliedRevisionAfterHandback() async throws {
        for mutation in ["document.querySelector('select').value='concerts';", "document.getElementById('reference').value='changed';"] {
            let fixture = try await make(category: true, mutation: mutation)
            defer { fixture.close() }
            let (original, _) = try await prepare(fixture, category: true), owner = try fixture.owner()
            _ = try await beginPreparationReview(fixture, input: original); configurePreparedRevision(fixture)
            let reviewed = try await owner.reviewFormPreparation(using: fixture.actions)
            fixture.state.onCommand = { command in
                guard command == .reviseFormFields else { return }; fixture.state.onCommand = nil; owner.pause()
            }
            await expectFailure { _ = try await owner.applyFormPreparationReview(reviewed) }
            try await release(fixture)
            await expectFailure { try await owner.resumeAfterUserControl(); _ = try await owner.resumeFormPreparation() }
            XCTAssertTrue(owner.hasPendingFormPreparation)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
            XCTAssertTrue(fixture.forms.inputs.isEmpty)
        }
    }

    func testFurtherAnswerRetainsAnInterruptedRevisionAndItsNewlyCapturedValues() async throws {
        for changeValue in [false, true] {
            let fixture = try await make(category: true, mutation: changeValue ? "document.querySelector('select').value='concerts';" : "")
            defer { fixture.close() }
            let (original, _) = try await prepare(fixture, category: true), owner = try fixture.owner()
            _ = try await beginPreparationReview(fixture, input: original); configurePreparedRevision(fixture)
            let reviewed = try await owner.reviewFormPreparation(using: fixture.actions)
            fixture.state.onCommand = { command in
                guard command == .reviseFormFields else { return }; fixture.state.onCommand = nil; owner.pause()
            }
            await expectFailure { _ = try await owner.applyFormPreparationReview(reviewed) }
            try await release(fixture); try await owner.resumeAfterUserControl()
            let question = try owner.issueQuestion(topic: .location, requirementIDs: [reviewed.input.interpretation.requirements[0].id],
                controllerID: "phone", controllerSessionID: "session")
            _ = try owner.answerQuestion(questionID: question.id, answerTaskID: "second-answer", answer: "Seattle.",
                controllerID: "phone", controllerSessionID: "session")
            let interpretation = try await owner.interpretGoal()
            try owner.configureResearchSources(XCTUnwrap(try fixture.policy.sources(for: interpretation)))
            let next = try await owner.reviewFormPreparation(using: fixture.actions)
            if changeValue {
                await expectFailure { _ = try await owner.applyFormPreparationReview(next) }
                XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
            } else {
                let current = try await owner.applyFormPreparationReview(next)
                XCTAssertEqual(current.interpretation.input.userTurns, original.interpretation.input.userTurns + ["Tomorrow.","Seattle."])
                XCTAssertEqual(current.nativePreservedSources, original.nativePreservedSources)
                XCTAssertEqual(current.preparationBaseline?.capturedTargetIDs.count, 2)
                XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 2)
            }
            XCTAssertTrue(owner.hasPendingFormPreparation)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        }
    }

    func testNewlyRecognizedEditablePreservationSurvivesAnotherAnswerWithItsOriginalSource() async throws {
        let fixture = try await make(notes: true, category: true)
        defer { fixture.close() }
        let original = try await prepareWithMissedNotes(fixture), owner = try fixture.owner()
        XCTAssertFalse(original.evidence.fields.contains { $0.control.label == "Notes" })
        _ = try await beginPreparationReview(fixture, input: original); configurePreparedRevision(fixture, notes: true)
        let reviewed = try await owner.reviewFormPreparation(using: fixture.actions)
        let first = try await owner.applyFormPreparationReview(reviewed)
        let source = try XCTUnwrap(first.requiredPreservation.first?.source)
        XCTAssertEqual(first.requiredPreservation.count, 1)
        let question = try owner.issueQuestion(topic: .location, requirementIDs: [first.interpretation.requirements[0].id],
            controllerID: "phone", controllerSessionID: "session")
        _ = try owner.answerQuestion(questionID: question.id, answerTaskID: "second-answer", answer: "Seattle.",
            controllerID: "phone", controllerSessionID: "session")
        let interpretation = try await owner.interpretGoal()
        try owner.configureResearchSources(XCTUnwrap(try fixture.policy.sources(for: interpretation)))
        let next = try await owner.reviewFormPreparation(using: fixture.actions)
        let current = try await owner.applyFormPreparationReview(next)
        XCTAssertEqual(current.requiredPreservation.first?.source, source)
        XCTAssertEqual(current.nativePreservedSources, original.nativePreservedSources)
        XCTAssertFalse(current.contextJSON.contains("private-notes"))
        let proposal = try ComputerUseBrowserFormProposal.decode(content: categoryPlan(current), input: current)
        let notes = try XCTUnwrap(current.evidence.fields.first { $0.control.label == "Notes" })
        XCTAssertEqual(try proposal.textContract(for: current)?.unchangedValues[notes.editable.snapshot.targetID], "private-notes")
        _ = try await owner.executeForm(proposal, input: current)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testRevisedPreparationCannotLoseItsBaselineToMakeExtraFieldsAppearAuthorized() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (original, _) = try await prepare(fixture, category: true), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: original); configurePreparedRevision(fixture)
        let reviewed = try await owner.reviewFormPreparation(using: fixture.actions)
        let current = try await owner.applyFormPreparationReview(reviewed), scope = try XCTUnwrap(current.scopeReview?.formScope)
        XCTAssertThrowsError(try ComputerUseBrowserResearchFormInput(interpretation: current.interpretation, evidence: current.evidence,
            selectedFormID: current.selectedFormID, preservedControls: scope.preservedControls, previous: current.previous,
            scopeReview: current.scopeReview, nativePreservation: current.nativePreservation))
        let query = try XCTUnwrap(current.fieldAliases.first { (try? current.field(for: $0).control.label) == "Query" })
        let forged = try ResearchAnswerFixture.json(["edits":[["field":query,"terms":[["requirement":0,"text":"concerts"]]]],"preserve":[]])
        XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: forged, input: current))
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testRevisedInputKeepsUneditedCapturedValuesThroughNativeHandlers() async throws {
        let mutation = "document.querySelector('select').addEventListener('input',()=>{document.getElementById('query').value='changed';});"
        let fixture = try await make(category: true, mutation: mutation)
        defer { fixture.close() }
        let (original, _) = try await prepare(fixture, category: true), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: original); configurePreparedRevision(fixture)
        let reviewed = try await owner.reviewFormPreparation(using: fixture.actions)
        let current = try await owner.applyFormPreparationReview(reviewed)
        try await release(fixture)
        let proposal = try ComputerUseBrowserFormProposal.decode(content: categoryPlan(current), input: current)
        await expectFailure { _ = try await owner.executeForm(proposal, input: current) }
        XCTAssertTrue(owner.hasPendingForm)
        XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testRevisedLaterPreparationCarriesVerifiedHistoryIntoItsNewStage() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (_, action) = try await prepareLaterAction(fixture), owner = try fixture.owner()
        let original = try await owner.prepareFormInput(for: action), history = owner.confirmedFormHistory
        _ = try await beginPreparationReview(fixture, input: original); configurePreparedRevision(fixture, retainingQuery: true)
        let reviewed = try await owner.reviewFormPreparation(using: fixture.actions)
        let current = try await owner.applyFormPreparationReview(reviewed)
        XCTAssertEqual(current.previous, original.previous); XCTAssertEqual(owner.confirmedFormHistory, history)
        XCTAssertEqual(current.previous?.inputOperationIDs.count, 1)
        _ = try await owner.executeForm(.decode(content: categoryPlan(current), input: current), input: current)
        XCTAssertEqual(owner.confirmedFormHistory.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
    }

    func testLaterStageRetainsCapturedUneditedFieldsFromTheVerifiedRevisedStage() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (original, _) = try await prepare(fixture, category: true), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: original); configurePreparedRevision(fixture)
        let reviewed = try await owner.reviewFormPreparation(using: fixture.actions)
        let revised = try await owner.applyFormPreparationReview(reviewed)
        _ = try await owner.executeForm(.decode(content: categoryPlan(revised), input: revised), input: revised)
        configure(fixture, category: true)
        let ordinarySelection = fixture.actions.select
        fixture.actions.select = { input in
            if let review = try FormEffectScopeFixture.response(input, editing: ["Query":[0]], retaining: ["Category":[0]],
                preserving: ["Reference":0]) { return review }
            return try ordinarySelection?(input) ?? #"{"unavailable":true}"#
        }
        let nextAction = try await owner.planNextAction(using: fixture.actions)
        let next = try await owner.prepareFormInput(for: nextAction)
        XCTAssertNil(next.preparationBaseline)
        XCTAssertEqual(next.previous?.finalValues.count, 2)
        XCTAssertEqual(Set(next.evidence.fields.map { $0.control.label }), ["Query","Category"])
        let proposal = try ComputerUseBrowserFormProposal.decode(content: plan(next), input: next)
        let category = try XCTUnwrap(next.evidence.fields.first { $0.control.label == "Category" })
        XCTAssertEqual(try proposal.textContract(for: next)?.unchangedValues[category.editable.snapshot.targetID], category.editable.snapshot.value)
        _ = try await owner.executeForm(proposal, input: next)
        XCTAssertEqual(owner.confirmedFormHistory.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
    }

    func testRetirementDuringAppliedRevisionCannotPublishOrExecuteTheNewInput() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (original, _) = try await prepare(fixture, category: true), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: original); configurePreparedRevision(fixture)
        let reviewed = try await owner.reviewFormPreparation(using: fixture.actions)
        fixture.state.onCommand = { command in
            guard command == .reviseFormFields else { return }; fixture.state.onCommand = nil; owner.retire()
        }
        await expectFailure { _ = try await owner.applyFormPreparationReview(reviewed) }
        XCTAssertFalse(owner.hasPendingFormPreparation)
        await expectFailure { _ = try await owner.resumeFormPreparation() }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testPartialPreservationSurvivesAQuestionAndResegmentedAnswerBeforeAnyPrivateCapture() async throws {
        let fixture = try await make(notes: true, category: true)
        defer { fixture.close() }
        let original = try await prepareWithMissedNotes(fixture), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: original)
        configurePartialNotesReview(fixture) { _ in #"{"question":{"topic":"location","requirements":[0]}}"# }
        let partial = try await owner.reviewFormPreparation(using: fixture.actions)
        let notesID = try XCTUnwrap(partial.input.evidence.page.controls.first { $0.label == "Notes" }?.id)
        let source = try XCTUnwrap(partial.input.preparationReview?.preservedSources.first { $0.controlID == notesID }?.source)
        XCTAssertEqual(source.source, original.interpretation.input.prompt)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 0)
        XCTAssertFalse(partial.input.contextJSON.contains("private-notes"))
        let request = try XCTUnwrap(partial.questionRequest)
        let question = try owner.issueQuestion(topic: request.topic, requirementIDs: request.requirementIDs,
            controllerID: "phone", controllerSessionID: "session")
        _ = try owner.answerQuestion(questionID: question.id, answerTaskID: "second-answer", answer: "Seattle.",
            controllerID: "phone", controllerSessionID: "session")
        fixture.goal.select = { _ in try ResearchAnswerFixture.json(["disposition":"research","requirements":[
            ["turn":0,"source":"Find concerts. ","role":"outcome","field":"category","relation":"unspecified","values":[]],
            ["turn":0,"source":"Leave Reference and Notes unchanged. ","role":"condition","field":"other","relation":"unspecified","values":[]],
            ["turn":0,"source":"Do not buy.","role":"prohibition","field":"other","relation":"unspecified","values":[]],
            ["turn":1,"source":"Tomorrow.","role":"condition","field":"other","relation":"unspecified","values":[]],
            ["turn":2,"source":"Seattle.","role":"condition","field":"other","relation":"unspecified","values":[]]],
            "question":["topic":"none","requirements":[]]]) }
        let interpretation = try await owner.interpretGoal()
        try owner.configureResearchSources(XCTUnwrap(try fixture.policy.sources(for: interpretation)))
        configurePreparedRevision(fixture) // No new Notes decision is supplied.
        let reviewed = try await owner.reviewFormPreparation(using: fixture.actions)
        XCTAssertEqual(reviewed.input.preparationReview?.preservedSources.first { $0.controlID == notesID }?.source, source)
        let current = try await owner.applyFormPreparationReview(reviewed)
        XCTAssertEqual(current.requiredPreservation.first?.source, source)
        XCTAssertFalse(current.preparationBaseline?.capturedControlIDs.contains(notesID) == true)
        XCTAssertTrue(current.preparationBaseline?.preservedSources.contains { $0.controlID == notesID && $0.source == source } == true)
        XCTAssertEqual(current.nativePreservedSources, original.nativePreservedSources)
        _ = try await owner.executeForm(.decode(content: categoryPlan(current), input: current), input: current)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testPartialPreservationIsRetainedBeforeCancellationOfItsPageCheck() async throws {
        let fixture = try await make(notes: true, category: true)
        defer { fixture.close() }
        let original = try await prepareWithMissedNotes(fixture), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: original)
        var offeredPreservation = false
        configurePartialNotesReview(fixture, onPreserve: { offeredPreservation = true }) { _ in #"{"unavailable":true}"# }
        fixture.state.onCommand = { command in
            guard offeredPreservation, command == .validatePageSnapshot else { return }
            fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.reviewFormPreparation(using: fixture.actions) }
        XCTAssertTrue(offeredPreservation); XCTAssertTrue(owner.hasPendingFormPreparation)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 0)
        try await owner.resumeAfterUserControl(); configurePreparedRevision(fixture)
        let reviewed = try await owner.reviewFormPreparation(using: fixture.actions)
        let notes = try XCTUnwrap(reviewed.input.evidence.page.controls.first { $0.label == "Notes" }?.id)
        XCTAssertTrue(reviewed.input.preparationReview?.preservedSources.contains { $0.controlID == notes } == true)
        let current = try await owner.applyFormPreparationReview(reviewed)
        XCTAssertEqual(current.requiredPreservation.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testUnavailableOrFailedPlannerCannotDiscardAnAcceptedPartialPreservationDuty() async throws {
        for failure in [false, true] {
            let fixture = try await make(notes: true, category: true)
            defer { fixture.close() }
            let original = try await prepareWithMissedNotes(fixture), owner = try fixture.owner()
            _ = try await beginPreparationReview(fixture, input: original)
            var source: ComputerUseBrowserFormSource?
            configurePartialNotesReview(fixture) { input in
                let notes = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Notes" }?.id)
                source = input.preparationReview?.preservedSources.first { $0.controlID == notes }?.source
                if failure { throw ComputerUseBrowserActionPlanError.invalidProposal }
                return #"{"unavailable":true}"#
            }
            if failure { await expectFailure { _ = try await owner.reviewFormPreparation(using: fixture.actions) } }
            else {
                let unavailable = try await owner.reviewFormPreparation(using: fixture.actions)
                XCTAssertEqual(unavailable.step, .unavailable)
            }
            let accepted = try XCTUnwrap(source)
            configurePreparedRevision(fixture)
            let reviewed = try await owner.reviewFormPreparation(using: fixture.actions)
            let current = try await owner.applyFormPreparationReview(reviewed)
            XCTAssertEqual(current.requiredPreservation.first?.source, accepted)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        }
    }

    func testPartialPreservationSurvivesTheSharedReviewDeadline() async throws {
        let fixture = try await make(notes: true, category: true)
        defer { fixture.close() }
        let original = try await prepareWithMissedNotes(fixture), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: original)
        configurePartialNotesReview(fixture) { _ in #"{"unavailable":true}"# }
        var waitingAfterPreservation = false
        fixture.actions.beforeReply = {
            let input = try XCTUnwrap(fixture.actions.inputs.last)
            if input.preparationReview?.preservedSources.count == 2 {
                waitingAfterPreservation = true
                try await Task.sleep(for: .seconds(10))
            }
        }
        await expectFailure { _ = try await owner.reviewFormPreparation(using: fixture.actions, budget: .seconds(3)) }
        XCTAssertTrue(waitingAfterPreservation)
        fixture.actions.beforeReply = nil; configurePreparedRevision(fixture)
        let reviewed = try await owner.reviewFormPreparation(using: fixture.actions)
        XCTAssertEqual(reviewed.input.preparationReview?.preservedSources.count, 2)
        let current = try await owner.applyFormPreparationReview(reviewed)
        XCTAssertEqual(current.requiredPreservation.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testInvalidPreservationProposalCannotAddAPartialDuty() async throws {
        let fixture = try await make(notes: true, category: true)
        defer { fixture.close() }
        let original = try await prepareWithMissedNotes(fixture), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: original)
        configurePartialNotesReview(fixture) { _ in #"{"unavailable":true}"# }
        let validSelection = fixture.actions.select
        fixture.actions.select = { input in
            if let notes = input.evidence.page.controls.first(where: { $0.label == "Notes" }),
               input.effectAdditionalPreservationControlIDs.contains(notes.id) {
                return try ResearchAnswerFixture.json(["preserve_controls":[["control":notes.id,"requirement":999]]])
            }
            return try validSelection?(input) ?? #"{"unavailable":true}"#
        }
        await expectFailure { _ = try await owner.reviewFormPreparation(using: fixture.actions) }
        let before = fixture.actions.inputs.count
        configurePreparedRevision(fixture, notes: true)
        _ = try await owner.reviewFormPreparation(using: fixture.actions)
        let first = try XCTUnwrap(fixture.actions.inputs.dropFirst(before).first)
        XCTAssertEqual(first.preparationReview?.preservedSources.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields || $0 == .edit }.count, 0)
    }

    func testPartialDutyRejectsStaleReviewContextAndCannotClaimAnEarlierGoalObservation() async throws {
        let fixture = try await make(notes: true, category: true)
        defer { fixture.close() }
        let original = try await prepareWithMissedNotes(fixture), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: original)
        var before: ComputerUseBrowserActionInput?
        configurePartialNotesReview(fixture, onPreserve: { before = fixture.actions.inputs.last }) { _ in #"{"unavailable":true}"# }
        _ = try await owner.reviewFormPreparation(using: fixture.actions)
        let input = try XCTUnwrap(before), context = try XCTUnwrap(input.preparationReview)
        let notes = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Notes" }?.id)
        let action = try ComputerUseBrowserActionProposal.decode(content: ResearchAnswerFixture.json([
            "preserve_controls":[["control":notes,"requirement":0]]]), input: input)
        let updated = try context.retainingPreservation(from: action)
        XCTAssertEqual(context.preservedSources.count, 1); XCTAssertEqual(updated.preservedSources.count, 2)
        XCTAssertThrowsError(try updated.retainingPreservation(from: action))
        XCTAssertThrowsError(try updated.validate(interpretation: original.interpretation, evidence: original.evidence.page))
        XCTAssertFalse(String(describing: updated).contains("private-notes"))
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields || $0 == .edit }.count, 0)
    }

    func testChangedPageAfterPartialPreservationCannotSupplyANewBaseline() async throws {
        let fixture = try await make(notes: true, category: true,
            mutation: "const n=document.querySelector('input[value=private-notes]'); n.replaceWith(n.cloneNode(true));")
        defer { fixture.close() }
        let original = try await prepareWithMissedNotes(fixture), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: original)
        configurePartialNotesReview(fixture) { _ in #"{"question":{"topic":"location","requirements":[0]}}"# }
        let partial = try await owner.reviewFormPreparation(using: fixture.actions)
        XCTAssertEqual(partial.input.preparationReview?.preservedSources.count, 2)
        try await release(fixture)
        configurePreparedRevision(fixture)
        let decisions = fixture.actions.inputs.count
        await expectFailure { _ = try await owner.reviewFormPreparation(using: fixture.actions) }
        XCTAssertEqual(fixture.actions.inputs.count, decisions)
        XCTAssertTrue(owner.hasPendingFormPreparation)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields || $0 == .edit }.count, 0)
    }

    func testFormSelectionPreservationSurvivesAnUnfinishedReviewWithoutGrantingAnEdit() async throws {
        let fixture = try await make(notes: true, category: true)
        defer { fixture.close() }
        let original = try await prepareWithMissedNotes(fixture), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: original)
        fixture.actions.select = { input in
            let notes = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Notes" }?.id)
            if input.preparationReview?.preservedSources.contains(where: { $0.controlID == notes }) == true {
                return #"{"unavailable":true}"#
            }
            return try ResearchAnswerFixture.json(["form":XCTUnwrap(input.formEffectScope?.formID),
                "preserve":[["control":notes,"requirement":0]]])
        }
        let partial = try await owner.reviewFormPreparation(using: fixture.actions)
        XCTAssertEqual(partial.step, .unavailable)
        XCTAssertEqual(partial.input.preparationReview?.preservedSources.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields || $0 == .edit }.count, 0)
        configurePreparedRevision(fixture)
        let reviewed = try await owner.reviewFormPreparation(using: fixture.actions)
        let current = try await owner.applyFormPreparationReview(reviewed)
        XCTAssertEqual(current.requiredPreservation.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    private func prepareWithMissedNotes(_ fixture: ResearchDriverFixture) async throws -> ComputerUseBrowserResearchFormInput {
        _ = try await fixture.start(); configure(fixture, category: true)
        let initialSelection = fixture.actions.select
        fixture.actions.select = { input in
            // The initial authored review missed Notes. No input has run;
            // subsequent review must retain its newly recognized duty.
            if let review = try FormEffectScopeFixture.response(input, unrelated: ["Notes"], editing: ["Query":[0]],
                deferring: ["Category":[0]], preserving: ["Reference":1]) { return review }
            return try initialSelection?(input) ?? #"{"unavailable":true}"#
        }
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        return try await owner.prepareFormInput(for: action)
    }

    private func configurePartialNotesReview(_ fixture: ResearchDriverFixture, onPreserve: (() -> Void)? = nil,
                                            after: @escaping (ComputerUseBrowserActionInput) throws -> String) {
        fixture.actions.select = { input in
            guard input.preparationReview != nil else { return #"{"unavailable":true}"# }
            let notes = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Notes" }?.id)
            if input.formEffectScope?.preservedControls.contains(where: { $0.controlID == notes }) == true { return try after(input) }
            if input.effectAdditionalPreservationControlIDs.contains(notes) {
                onPreserve?()
                return try ResearchAnswerFixture.json(["preserve_controls":[["control":notes,"requirement":0]]])
            }
            return try FormEffectScopeFixture.response(input, editing: ["Category":[0]], deferring: ["Query":[0]],
                preserving: ["Reference":0,"Notes":0]) ?? #"{"unavailable":true}"#
        }
    }

    private func configurePreparedRevision(_ fixture: ResearchDriverFixture, retainingQuery: Bool = false, notes: Bool = false) {
        fixture.actions.select = { input in
            guard input.preparationReview != nil else { return #"{"unavailable":true}"# }
            if let review = try FormEffectScopeFixture.response(input, editing: ["Category":[0]],
                retaining: retainingQuery ? ["Query":[0]] : [:], deferring: retainingQuery ? [:] : ["Query":[0]],
                preserving: notes ? ["Reference":0,"Notes":0] : ["Reference":0]) { return review }
            return #"{"unavailable":true}"#
        }
    }

    func testMatchingFormStateProducesASeparateProofWithoutInputOrChange() async throws {
        let fixture = try await make(category: true, queryAlreadyMatches: true,
            handler: "document.getElementById('reference').value='unexpected-input';")
        defer { fixture.close() }
        let (frame, input, plan) = try await statePreparation(fixture)
        XCTAssertTrue(plan.capturedValuesMatch)
        let before = try frame.target.preparedFormRequirements(from: input)
        let capture = try ComputerUseBrowserDOMReadCapture(command: .verifyFormState, document: input.evidence.page.document)
        let first = try await verifyState(fixture, frame: frame, input: input, plan: plan, capture: capture)
        let proof = try XCTUnwrap(first)
        let retained = try await verifyState(fixture, frame: frame, input: input, plan: plan, capture: capture)
        XCTAssertEqual(retained, proof)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, 1)
        let nativeRetry = try await verifyState(fixture, frame: frame, input: input, plan: plan)
        XCTAssertEqual(nativeRetry, proof)
        let page = try await frame.restoreForReview(browser: fixture.browser, checkCurrent: {})
        try await frame.target.validateFormState(proof, for: plan, input: input, page: page)
        let after = try frame.target.preparedFormRequirements(from: input)
        XCTAssertEqual(before.digest, after.digest)
        XCTAssertEqual(after.domArguments["inputOperationIDs"] as? [String], [])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit || $0 == .finishPendingChange || $0 == .prepareFormQuery }.count, 0)
        XCTAssertEqual(try fixture.owner().confirmedFormHistory.count, 0)
        for value in [String(describing: plan), String(reflecting: plan), String(describing: proof), String(reflecting: proof)] {
            XCTAssertFalse(value.contains("concerts")); XCTAssertFalse(value.contains("private-reference"))
        }
    }

    func testMismatchedFormStateRequestsInputWithoutCreatingAnyReceipt() async throws {
        for choosingCategory in [false, true] {
            let fixture = try await make(category: true)
            defer { fixture.close() }
            let (frame, input, plan) = try await statePreparation(fixture, choosingCategory: choosingCategory)
            XCTAssertFalse(plan.capturedValuesMatch)
            let result = try await verifyState(fixture, frame: frame, input: input, plan: plan)
            XCTAssertNil(result)
            let retry = try await verifyState(fixture, frame: frame, input: input, plan: plan)
            XCTAssertNil(retry)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit || $0 == .finishPendingChange }.count, 0)
            let requirements = try frame.target.preparedFormRequirements(from: input)
            XCTAssertEqual(requirements.domArguments["inputOperationIDs"] as? [String], [])
        }
    }

    func testMatchingSelectedOptionVerifiesTheNativeOptionIdentity() async throws {
        let fixture = try await make(category: true, categoryAlreadyMatches: true)
        defer { fixture.close() }
        let (frame, input, plan) = try await statePreparation(fixture, choosingCategory: true)
        let field = try XCTUnwrap(input.evidence.fields.first { $0.control.label == "Category" })
        let desired = try XCTUnwrap(field.control.options.first { $0.label == "Concerts" })
        XCTAssertEqual(plan.expectedValues[field.editable.snapshot.targetID], desired.id)
        XCTAssertNotEqual(desired.id, "concerts")
        XCTAssertTrue(plan.capturedValuesMatch)
        let result = try await verifyState(fixture, frame: frame, input: input, plan: plan)
        let proof = try XCTUnwrap(result)
        let page = try await frame.restoreForReview(browser: fixture.browser, checkCurrent: {})
        try await frame.target.validateFormState(proof, for: plan, input: input, page: page)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit || $0 == .finishPendingChange }.count, 0)
    }

    func testCapturedStateProofIsHistoricalAfterValueObjectOrPreservationChanges() async throws {
        for mutation in ["document.getElementById('query').value='changed';",
                         "const q=document.getElementById('query'); q.replaceWith(q.cloneNode(true));",
                         "document.getElementById('reference').value='changed';"] {
            let fixture = try await make(category: true, queryAlreadyMatches: true, mutation: mutation)
            defer { fixture.close() }
            let (frame, input, plan) = try await statePreparation(fixture)
            let capture = try ComputerUseBrowserDOMReadCapture(command: .verifyFormState, document: input.evidence.page.document)
            let first = try await verifyState(fixture, frame: frame, input: input, plan: plan, capture: capture)
            let proof = try XCTUnwrap(first)
            try await release(fixture)
            // Replay the original callback without treating it as fresh state.
            let retained = try await frame.target.verifyFormState(plan, input: input, page: input.evidence.page, retaining: capture)
            XCTAssertEqual(retained, proof)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, 1)
            await expectFailure {
                let page = try await frame.restoreForReview(browser: fixture.browser, checkCurrent: {})
                try await frame.target.validateFormState(proof, for: plan, input: input, page: page)
            }
            await expectFailure { _ = try await verifyState(fixture, frame: frame, input: input, plan: plan) }
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        }
    }

    func testCaretMovementDoesNotInvalidatePreviouslyVerifiedFormValues() async throws {
        let fixture = try await make(category: true, queryAlreadyMatches: true,
            mutation: "document.getElementById('query').setSelectionRange(1,2);")
        defer { fixture.close() }
        let (frame, input, plan) = try await statePreparation(fixture)
        let first = try await verifyState(fixture, frame: frame, input: input, plan: plan)
        let proof = try XCTUnwrap(first)
        try await release(fixture)
        let page = try await frame.restoreForReview(browser: fixture.browser, checkCurrent: {})
        try await frame.target.validateFormState(proof, for: plan, input: input, page: page)
        let retry = try await verifyState(fixture, frame: frame, input: input, plan: plan)
        XCTAssertEqual(retry, proof)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testCancelledFormStateVerificationJoinsAndRetainsItsNativeProof() async throws {
        let fixture = try await make(category: true, queryAlreadyMatches: true)
        defer { fixture.close() }
        let (frame, input, plan) = try await statePreparation(fixture)
        let capture = try ComputerUseBrowserDOMReadCapture(command: .verifyFormState, document: input.evidence.page.document)
        var operation: Task<ComputerUseBrowserFormStateProof?, Error>?
        fixture.state.onCommand = { command in
            guard command == .verifyFormState else { return }
            fixture.state.onCommand = nil; operation?.cancel()
        }
        operation = Task { @MainActor in try await self.verifyState(fixture, frame: frame, input: input, plan: plan, capture: capture) }
        let pending = try XCTUnwrap(operation)
        await expectFailure { _ = try await pending.value }
        XCTAssertTrue(capture.didStart)
        let first = try await verifyState(fixture, frame: frame, input: input, plan: plan, capture: capture)
        let proof = try XCTUnwrap(first)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, 1)
        let page = try await frame.restoreForReview(browser: fixture.browser, checkCurrent: {})
        try await frame.target.validateFormState(proof, for: plan, input: input, page: page)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testStateVerificationRetainsEarlierRealInputReceiptsWithoutAddingOne() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (action, initial, first) = try await standalonePreparation(fixture)
        let stage = try await executeStandalone(fixture, frame: initial, input: first)
        let frame = try ComputerUseBrowserResearchFormPreparation(action: action, browser: fixture.browser, parent: stage)
        let input = try await frame.prepare(browser: fixture.browser, checkCurrent: {})
        let plan = try ComputerUseBrowserFormStatePlan(input: input, proposal: .decode(content: self.plan(input), input: input))
        let before = try frame.target.preparedFormRequirements(from: input)
        let result = try await verifyState(fixture, frame: frame, input: input, plan: plan)
        let proof = try XCTUnwrap(result)
        let page = try await frame.restoreForReview(browser: fixture.browser, checkCurrent: {})
        try await frame.target.validateFormState(proof, for: plan, input: input, page: page)
        let after = try frame.target.preparedFormRequirements(from: input)
        XCTAssertEqual(before.digest, after.digest)
        XCTAssertEqual(after.domArguments["inputOperationIDs"] as? [String], input.previous?.inputOperationIDs)
        XCTAssertEqual(input.previous?.inputOperationIDs.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testStateProofRejectsUnaccountedInputAndReplacementLedgers() async throws {
        for rediscover in [false, true] {
            let fixture = try await make(category: true, referenceReadOnly: false, queryAlreadyMatches: true)
            defer { fixture.close() }
            let (frame, input, plan) = try await statePreparation(fixture)
            let result = try await verifyState(fixture, frame: frame, input: input, plan: plan)
            let proof = try XCTUnwrap(result)
            if rediscover {
                let other = ComputerUseBrowserTextTarget(browser: fixture.browser, document: input.evidence.page.document, requiresFrontmost: false)
                _ = try await other.fields()
            } else {
                let field = try XCTUnwrap(input.evidence.fields.first { $0.control.label == "Query" }).editable
                try await frame.target.apply(.init(edit: .init(targetID: field.snapshot.targetID, mode: .replaceAll, text: field.snapshot.value),
                    expected: field.snapshot, operationID: ComputerUseTaskContract.digest(["unaccounted-input"]),
                    copySource: nil, requiredValues: [:]))
            }
            await expectFailure {
                let page = try await frame.restoreForReview(browser: fixture.browser, checkCurrent: {})
                try await frame.target.validateFormState(proof, for: plan, input: input, page: page)
            }
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, rediscover ? 0 : 1)
        }
    }

    func testMatchingStateProofCannotTurnPreparedRequirementsIntoQueryAuthority() async throws {
        let fixture = try await make(category: true, queryAlreadyMatches: true)
        defer { fixture.close() }
        let (frame, input, plan) = try await statePreparation(fixture)
        let result = try await verifyState(fixture, frame: frame, input: input, plan: plan)
        XCTAssertNotNil(result)
        let requirements = try frame.target.preparedFormRequirements(from: input)
        let page = try await frame.restoreForReview(browser: fixture.browser, checkCurrent: {})
        let submit = try XCTUnwrap(page.page.controls.first { $0.kind == "submit" })
        let reply = try await fixture.browser.callDOM(.prepareFormQuery, arguments: ["documentID":page.documentID,
            "snapshotID":page.page.id,"controlID":submit.id,"requirements":requirements.domArguments], document: page.document)
        XCTAssertEqual(reply.status, "stale"); XCTAssertNil(reply.formQuery)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=all"), 0)
    }

    func testFormStatePlansAndProofsRejectDifferentInputsAndAdapters() async throws {
        let fixture = try await make(category: true, queryAlreadyMatches: true)
        defer { fixture.close() }
        let (frame, input, plan) = try await statePreparation(fixture)
        let result = try await verifyState(fixture, frame: frame, input: input, plan: plan)
        let proof = try XCTUnwrap(result)
        let other = ComputerUseBrowserTextTarget(browser: fixture.browser, document: input.evidence.page.document, requiresFrontmost: false)
        let count = fixture.state.commands.count
        await expectFailure { try await other.validateFormState(proof, for: plan, input: input, page: input.evidence.page) }
        XCTAssertEqual(fixture.state.commands.count, count)
        let otherFixture = try await make(category: true, queryAlreadyMatches: true)
        defer { otherFixture.close() }
        let (_, otherInput, _) = try await statePreparation(otherFixture)
        XCTAssertThrowsError(try plan.validate(for: otherInput))
        let unavailable = try ComputerUseBrowserFormProposal.decode(content: #"{"unavailable":true}"#, input: input)
        XCTAssertThrowsError(try ComputerUseBrowserFormStatePlan(input: input, proposal: unavailable))
    }

    func testNativeStateVerificationIdentityRejectsChangedPlanAndDesiredValues() async throws {
        let fixture = try await make(category: true, queryAlreadyMatches: true)
        defer { fixture.close() }
        let (frame, input, plan) = try await statePreparation(fixture)
        let result = try await verifyState(fixture, frame: frame, input: input, plan: plan)
        XCTAssertNotNil(result)
        let requirements = try frame.target.preparedFormRequirements(from: input)
        let fields = try XCTUnwrap(requirements.domArguments["fields"] as? [[String: Any]])
        let field = try XCTUnwrap(fields.first { $0["label"] as? String == "Query" })
        let nativeID = try XCTUnwrap(field["id"] as? String)
        let page = try await frame.restoreForReview(browser: fixture.browser, checkCurrent: {})
        let arguments: [String: Any] = ["documentID":page.documentID,"snapshotID":page.page.id,
            "formID":try XCTUnwrap(input.selectedFormID),"planDigest":plan.digest,
            "verificationID":ComputerUseTaskContract.digest(["browser-form-state-verification-v1",plan.digest,requirements.digest]),
            "requirements":requirements.domArguments,"expected":[["id":nativeID,"value":"concerts"]]]
        let retry = try await fixture.browser.callDOM(.verifyFormState, arguments: arguments, document: page.document)
        XCTAssertEqual(retry.status, "form-state-verified")
        for replacement: [String: Any] in [["planDigest":String(repeating: "f", count: 64)],
            ["expected":[["id":nativeID,"value":"movies"]]], ["expected":[["id":"e999999","value":"concerts"]]]] {
            let reply = try await fixture.browser.callDOM(.verifyFormState,
                arguments: arguments.merging(replacement) { _, new in new }, document: page.document)
            XCTAssertEqual(reply.status, "stale"); XCTAssertNil(reply.formStateProof)
        }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testFormStateReplyOwnershipAndFreshValidationCannotBeBypassed() throws {
        let payload: [String: Any] = ["id":String(repeating: "b", count: 32),"planDigest":String(repeating: "c", count: 64)]
        let base: [String: Any] = ["status":"form-state-verified","documentID":String(repeating: "a", count: 32),"formStateProof":payload]
        let content = try ResearchAnswerFixture.json(base)
        XCTAssertNotNil(try ComputerUseOwnedBrowser.decodeDOMReply(content, command: .verifyFormState).formStateProof)
        for command in [ComputerUseBrowserDOMCommand.edit, .formFields, .prepareFormQuery, .validateFormState] {
            XCTAssertThrowsError(try ComputerUseOwnedBrowser.decodeDOMReply(content, command: command))
        }
        for extra: [String: Any] in [["status":"authentication-required"],["fields":[]],["changedFieldIDs":[]]] {
            let invalid = try ResearchAnswerFixture.json(base.merging(extra) { _, new in new })
            XCTAssertThrowsError(try ComputerUseOwnedBrowser.decodeDOMReply(invalid, command: .verifyFormState))
        }
    }

    func testMatchingFormStageCompletesWithoutInputAndOffersAnExplicitQuery() async throws {
        let fixture = try await make(queryAlreadyMatches: true)
        defer { fixture.close() }
        let (input, proposal) = try await prepare(fixture), owner = try fixture.owner()
        let receipt = try await owner.executeForm(proposal, input: input)
        XCTAssertEqual(receipt.editCount, 0); XCTAssertEqual(receipt.verifiedWithoutInputCount, 1)
        XCTAssertEqual(receipt.plannedEditCount, 1); XCTAssertTrue(receipt.isCompleteStage)
        XCTAssertEqual(owner.confirmedFormHistory, [receipt])
        configure(fixture, querying: true)
        let action = try await owner.planNextAction(using: fixture.actions)
        guard case .openQuery = action.step else { return XCTFail("Verified matching values must offer a query") }
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(action.input.contextJSON.utf8)) as? [String: Any])
        XCTAssertEqual(context["version"] as? Int, 20); XCTAssertTrue(action.input.usesFormStateContext)
        let stage = try XCTUnwrap(context["verified_form_stage"] as? [String: Any])
        XCTAssertNil(stage["edits"])
        let criteria = try XCTUnwrap(stage["criteria"] as? [[String: Any]])
        XCTAssertEqual(criteria.first?["verified_without_input"] as? Bool, true)
        XCTAssertFalse(action.input.contextJSON.contains("private-reference"))
        _ = try await owner.openFormQuery(for: action)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit || $0 == .finishPendingChange }.count, 0)
    }

    func testDriverContinuesAnAlreadyMatchingPreparedFormWithoutTyping() async throws {
        let fixture = try await make(queryAlreadyMatches: true)
        defer { fixture.close() }
        _ = try await prepare(fixture)
        configure(fixture, querying: true)
        let select = fixture.actions.select
        fixture.actions.select = { input in
            guard input.evidence.page.controls.contains(where: { $0.label == "Query" }) else { return #"{"unavailable":true}"# }
            return try XCTUnwrap(select)(input)
        }
        fixture.forms.select = { try self.plan($0) }
        _ = try await fixture.resume()
        let owner = try fixture.owner()
        XCTAssertEqual(owner.confirmedFormHistory.count, 1)
        XCTAssertEqual(owner.confirmedFormHistory.first?.verifiedWithoutInputCount, 1)
        XCTAssertEqual(fixture.forms.inputs.count, 1)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testNoInputStageResumesCapturedVerificationOnlyAfterExplicitHandback() async throws {
        for boundary in [ComputerUseBrowserDOMCommand.verifyFormState, .validateFormState] {
            let fixture = try await make(queryAlreadyMatches: true)
            defer { fixture.close() }
            let (input, proposal) = try await prepare(fixture), owner = try fixture.owner()
            fixture.state.onCommand = { command in
                guard command == boundary else { return }; fixture.state.onCommand = nil; owner.pause()
            }
            await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
            XCTAssertTrue(owner.hasPendingForm); XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
            let commands = fixture.state.commands
            await expectFailure { _ = try await owner.resumeForm() }
            XCTAssertEqual(fixture.state.commands, commands)
            try await owner.resumeAfterUserControl()
            let resumed = try await owner.resumeForm()
            let receipt = try XCTUnwrap(resumed)
            XCTAssertTrue(receipt.isCompleteStage); XCTAssertEqual(receipt.editCount, 0)
            XCTAssertEqual(receipt.verifiedWithoutInputCount, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
            let replay = try await owner.resumeForm()
            XCTAssertEqual(replay, receipt)
        }
    }

    func testNoInputStageCannotHideAnAttemptedUncertainOrVerifiedDiskInput() async throws {
        for status in [ComputerUseTaskStepStatus.attempted, .uncertain, .verified] {
            let fixture = try await make(category: true, queryAlreadyMatches: true)
            defer { fixture.close() }
            let (_, frame, input) = try await standalonePreparation(fixture)
            let proposal = try ComputerUseBrowserFormProposal.decode(content: plan(input), input: input)
            let stage = try ComputerUseBrowserResearchFormStage(input: input, proposal: proposal, target: frame.target,
                browser: fixture.browser, index: 0, journalDirectory: fixture.directory)
            let task = try ComputerUseTextTask(contract: stage.contract, read: { _ in nil }, apply: { _, _ in }, persist: { _ in }, mayAct: { false })
            let directory = fixture.directory.appendingPathComponent("Research Forms").appendingPathComponent(stage.id)
            let store = try ComputerUseTaskJournalStore(directory: directory)
            let planned = task.journal; try store.save(planned, replacing: nil)
            var attempted = planned; attempted.statuses = [.attempted]; try store.save(attempted, replacing: planned)
            if status != .attempted { var final = attempted; final.statuses = [status]; try store.save(final, replacing: attempted) }
            await expectFailure { _ = try await stage.run(checkCurrent: {}) }
            XCTAssertNil(stage.nativeReceipt); XCTAssertNil(stage.nativeContinuation)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState || $0 == .edit }.count, 0)
            XCTAssertFalse(try XCTUnwrap(store.load(taskID: stage.contract.taskID)).statuses.contains(.planned))
        }
    }

    func testNoInputStageBindsItsOriginalContractBeforeVerificationAndRetriesFailedStorage() async throws {
        let fixture = try await make(queryAlreadyMatches: true)
        defer { fixture.close() }
        let (input, proposal) = try await prepare(fixture), owner = try fixture.owner()
        fixture.state.failureAtWrite = fixture.state.writes + 1
        await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
        XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState || $0 == .edit }.count, 0)
        fixture.state.failureAtWrite = nil
        let result = try await owner.resumeForm()
        let receipt = try XCTUnwrap(result)
        let directory = fixture.directory.appendingPathComponent("Research").appendingPathComponent("Research Forms").appendingPathComponent(receipt.stageID)
        let store = try ComputerUseTaskJournalStore(directory: directory)
        let journal = try XCTUnwrap(store.load(taskID: input.interpretation.input.taskID))
        XCTAssertEqual(journal.contractDigest, receipt.contractDigest); XCTAssertEqual(journal.statuses, [.planned])
        XCTAssertEqual(receipt.editCount, 0); XCTAssertEqual(receipt.verifiedWithoutInputCount, 1)
    }

    func testLaterActualEditRetainsPreviouslyObservedCriteriaAndTheirSources() async throws {
        let fixture = try await make(category: true, queryAlreadyMatches: true)
        defer { fixture.close() }
        let (first, proposal) = try await prepare(fixture, category: true), owner = try fixture.owner()
        _ = try await owner.executeForm(proposal, input: first)
        configure(fixture, category: true, revising: true)
        let action = try await owner.planNextAction(using: fixture.actions)
        let next = try await owner.prepareFormInput(for: action)
        let previous = try XCTUnwrap(next.previous)
        XCTAssertTrue(previous.editedTargetIDs.isEmpty); XCTAssertTrue(previous.inputOperationIDs.isEmpty)
        XCTAssertEqual(previous.verifiedTargetIDs.count, 1); XCTAssertEqual(previous.stateProofsByTarget.count, 1)
        XCTAssertTrue(previous.editedSources.isEmpty); XCTAssertEqual(previous.verifiedSources.count, 1)
        XCTAssertTrue(next.contextJSON.contains("previous_criteria")); XCTAssertFalse(next.contextJSON.contains("previous_edits"))
        let receipt = try await owner.executeForm(.decode(content: categoryPlan(next), input: next), input: next)
        XCTAssertEqual(receipt.editCount, 1); XCTAssertEqual(receipt.verifiedWithoutInputCount, 0)
        configure(fixture, category: true, revising: true, querying: true)
        let query = try await owner.planNextAction(using: fixture.actions)
        guard case .openQuery = query.step else { return XCTFail("Both criteria must remain queryable") }
        _ = try await owner.openFormQuery(for: query)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts"), 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testLaterMatchingOptionKeepsEarlierObservedOrDispatchedQueryCriteria() async throws {
        for queryAlreadyMatches in [false, true] {
            let fixture = try await make(category: true, queryAlreadyMatches: queryAlreadyMatches, categoryAlreadyMatches: true)
            defer { fixture.close() }
            let (first, proposal) = try await prepare(fixture, category: true), owner = try fixture.owner()
            _ = try await owner.executeForm(proposal, input: first)
            configure(fixture, category: true, revising: true)
            let action = try await owner.planNextAction(using: fixture.actions)
            let next = try await owner.prepareFormInput(for: action)
            XCTAssertEqual(next.previous?.inputOperationIDs.count, queryAlreadyMatches ? 0 : 1)
            let receipt = try await owner.executeForm(.decode(content: categoryPlan(next), input: next), input: next)
            XCTAssertEqual(receipt.editCount, 0); XCTAssertEqual(receipt.verifiedWithoutInputCount, 1)
            configure(fixture, category: true, revising: true, querying: true)
            let query = try await owner.planNextAction(using: fixture.actions)
            guard case .openQuery = query.step else { return XCTFail("Matching option must not require a selection event") }
            _ = try await owner.openFormQuery(for: query)
            XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts"), 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, queryAlreadyMatches ? 0 : 1)
        }
    }

    func testChangedObservedCriterionRequiresAnActualRepairBeforeQuery() async throws {
        let fixture = try await make(queryAlreadyMatches: true, mutation: "document.getElementById('query').value='movies';")
        defer { fixture.close() }
        let (first, proposal) = try await prepare(fixture), owner = try fixture.owner()
        _ = try await owner.executeForm(proposal, input: first)
        try await release(fixture); configure(fixture, querying: true)
        let action = try await owner.planNextAction(using: fixture.actions)
        guard case .editForm = action.step else { return XCTFail("Changed observed values require repair") }
        XCTAssertTrue(action.input.queryControlIDs.isEmpty)
        let next = try await owner.prepareFormInput(for: action)
        XCTAssertEqual(next.requiredRepairFieldAliases.count, 1)
        let receipt = try await owner.executeForm(.decode(content: plan(next), input: next), input: next)
        XCTAssertEqual(receipt.editCount, 1); XCTAssertEqual(receipt.verifiedWithoutInputCount, 0)
        let query = try await owner.planNextAction(using: fixture.actions)
        guard case .openQuery = query.step else { return XCTFail("The verified repair should restore query readiness") }
        _ = try await owner.openFormQuery(for: query)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testNoInputQueryHandbackRejectsChangedValuesAndReadonlyPreservation() async throws {
        for mutation in ["document.getElementById('query').value='changed';", "document.getElementById('reference').value='changed';"] {
            let fixture = try await make(queryAlreadyMatches: true, mutation: mutation)
            defer { fixture.close() }
            let (input, proposal) = try await prepare(fixture), owner = try fixture.owner()
            _ = try await owner.executeForm(proposal, input: input); configure(fixture, querying: true)
            let action = try await owner.planNextAction(using: fixture.actions)
            fixture.state.onCommand = { command in
                guard command == .prepareFormQuery else { return }; fixture.state.onCommand = nil; owner.pause()
            }
            await expectFailure { _ = try await owner.openFormQuery(for: action) }
            try await release(fixture)
            await expectFailure { try await owner.resumeAfterUserControl(); _ = try await owner.resumeFormNavigation() }
            XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 0)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        }
    }

    func testNoInputContinuationCannotTreatReplacedControlsAsRepairableOriginals() async throws {
        let fixture = try await make(queryAlreadyMatches: true,
            mutation: "const q=document.getElementById('query'); q.replaceWith(q.cloneNode(true));")
        defer { fixture.close() }
        let (input, proposal) = try await prepare(fixture), owner = try fixture.owner()
        let receipt = try await owner.executeForm(proposal, input: input)
        try await release(fixture); configure(fixture, querying: true)
        await expectFailure { _ = try await owner.planNextAction(using: fixture.actions) }
        XCTAssertEqual(owner.confirmedFormHistory, [receipt])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit || $0 == .prepareFormQuery }.count, 0)
    }

    func testNoInputReceiptReplayIsHistoricalAndDoesNotReverifyChangedState() async throws {
        let fixture = try await make(queryAlreadyMatches: true, mutation: "document.getElementById('query').value='changed';")
        defer { fixture.close() }
        let (input, proposal) = try await prepare(fixture), owner = try fixture.owner()
        let receipt = try await owner.executeForm(proposal, input: input)
        try await release(fixture)
        let commands = fixture.state.commands
        let historical = try await owner.executeForm(proposal, input: input)
        XCTAssertEqual(historical, receipt); XCTAssertEqual(fixture.state.commands, commands)
        configure(fixture, querying: true)
        let action = try await owner.planNextAction(using: fixture.actions)
        XCTAssertTrue(action.input.queryControlIDs.isEmpty)
        XCTAssertEqual(owner.confirmedFormHistory.count, 1)
    }

    func testNativeQueryRequiresTheExactStoredStateOriginForZeroInputCriteria() async throws {
        let fixture = try await make(category: true, queryAlreadyMatches: true)
        defer { fixture.close() }
        let (frame, input, plan) = try await statePreparation(fixture)
        let proof = try await verifyState(fixture, frame: frame, input: input, plan: plan)
        XCTAssertNotNil(proof)
        let prepared = try frame.target.preparedFormRequirements(from: input)
        let fields = try XCTUnwrap(prepared.domArguments["fields"] as? [[String: Any]])
        let queryField = try XCTUnwrap(fields.first { $0["label"] as? String == "Query" })
        let id = try XCTUnwrap(queryField["id"] as? String)
        let page = try await frame.restoreForReview(browser: fixture.browser, checkCurrent: {})
        let verificationID = ComputerUseTaskContract.digest(["browser-form-state-verification-v1",plan.digest,prepared.digest])
        let reply = try await fixture.browser.callDOM(.verifyFormState, arguments: ["documentID":page.documentID,
            "snapshotID":page.page.id,"formID":try XCTUnwrap(input.selectedFormID),"planDigest":plan.digest,
            "verificationID":verificationID,"requirements":prepared.domArguments,"expected":[["id":id,"value":"concerts"]]], document: page.document)
        let native = try XCTUnwrap(reply.formStateProof)
        let claim = ["id":id,"verificationID":verificationID,"proofID":native.id,"planDigest":native.planDigest]
        var requirements = prepared.domArguments
        requirements["kind"] = "verified-form-state-v1"; requirements["stateCriteria"] = [claim]
        let submit = try XCTUnwrap(page.page.controls.first { $0.kind == "submit" })
        func prepareQuery(_ requirements: [String: Any]) async throws -> ComputerUseBrowserDOMReply {
            try await fixture.browser.callDOM(.prepareFormQuery, arguments: ["documentID":page.documentID,
                "snapshotID":page.page.id,"controlID":submit.id,"requirements":requirements], document: page.document)
        }
        for replacement: [String: Any] in [["stateCriteria":[]],
            ["stateCriteria":[claim.merging(["proofID":String(repeating: "f", count: 32)]) { _, new in new }]],
            ["stateCriteria":[claim.merging(["planDigest":String(repeating: "f", count: 64)]) { _, new in new }]],
            ["fields":[queryField.merging(["value":"movies"]) { _, new in new }]],
            ["inputLedgerID":String(repeating: "f", count: 32)],
            ["inputOperationIDs":[ComputerUseTaskContract.digest(["absent-input"])]]] {
            let result = try await prepareQuery(requirements.merging(replacement) { _, new in new })
            XCTAssertEqual(result.status, "stale"); XCTAssertNil(result.formQuery)
        }
        let valid = try await prepareQuery(requirements)
        XCTAssertEqual(valid.status, "form-query-prepared"); XCTAssertNotNil(valid.formQuery)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testNoInputStageRejectsJournalChangesBeforePublishingItsProof() async throws {
        let fixture = try await make(category: true, queryAlreadyMatches: true)
        defer { fixture.close() }
        let (_, frame, input) = try await standalonePreparation(fixture)
        let proposal = try ComputerUseBrowserFormProposal.decode(content: plan(input), input: input)
        let stage = try ComputerUseBrowserResearchFormStage(input: input, proposal: proposal, target: frame.target,
            browser: fixture.browser, index: 0, journalDirectory: fixture.directory)
        let directory = fixture.directory.appendingPathComponent("Research Forms").appendingPathComponent(stage.id)
        let store = try ComputerUseTaskJournalStore(directory: directory)
        var mutationError: Error?
        fixture.state.onCommand = { command in
            guard command == .validateFormState else { return }; fixture.state.onCommand = nil
            do {
                let planned = try XCTUnwrap(store.load(taskID: stage.contract.taskID))
                var changed = planned; changed.statuses = [.attempted]
                try store.save(changed, replacing: planned)
            } catch { mutationError = error }
        }
        await expectFailure { _ = try await stage.run(checkCurrent: {}) }
        XCTAssertNil(mutationError); XCTAssertNil(stage.nativeReceipt); XCTAssertNil(stage.nativeContinuation)
        XCTAssertEqual(try XCTUnwrap(store.load(taskID: stage.contract.taskID)).statuses, [.attempted])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testMixedCompilerKeepsLeadingMatchesAsInvariantsAndOnlyCompilesLaterInput() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true)
        defer { fixture.close() }
        let (input, proposal) = try await prepareMixed(fixture)
        let id = ComputerUseTaskContract.digest(["mixed-compiler"])
        let original = try XCTUnwrap(proposal.textContract(for: input, stageID: id))
        let plan = try ComputerUseBrowserFormExecutionPlan(input: input, proposal: proposal, stageID: id)
        XCTAssertTrue(plan.isMixed); XCTAssertFalse(plan.verificationOnly)
        XCTAssertEqual(plan.observedEdits.count, 1); XCTAssertEqual(plan.inputEdits.count, 2)
        let query = try XCTUnwrap(input.evidence.fields.first { $0.control.label == "Query" }).editable.snapshot.targetID
        XCTAssertEqual(plan.statePlan?.expectedValues, [query:"concerts"])
        XCTAssertNotEqual(plan.contract.contractDigest, original.contractDigest)
        XCTAssertEqual(plan.contract.unchangedValues[query], "concerts")
        XCTAssertTrue(plan.contract.steps.allSatisfy { $0.requiredValues[query] == "concerts" && $0.targetID != query })
        XCTAssertEqual(plan.contract.steps.map(\.targetID), Array(original.steps.dropFirst().map(\.targetID)))
    }

    func testMixedCompilerNeverHoistsALaterInitialMatchBeforeAnEarlierEdit() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true)
        defer { fixture.close() }
        let (input, proposal) = try await prepareMixed(fixture, order: ["Category","Query","City"])
        let id = ComputerUseTaskContract.digest(["ordered-compiler"])
        let plan = try ComputerUseBrowserFormExecutionPlan(input: input, proposal: proposal, stageID: id)
        let original = try XCTUnwrap(proposal.textContract(for: input, stageID: id))
        XCTAssertNil(plan.statePlan); XCTAssertTrue(plan.observedEdits.isEmpty)
        XCTAssertEqual(plan.contract.contractDigest, original.contractDigest)
        XCTAssertEqual(plan.inputEdits, proposal.edits)
        let query = try XCTUnwrap(input.evidence.fields.first { $0.control.label == "Query" }).editable.snapshot.targetID
        XCTAssertNil(plan.contract.steps.first?.requiredValues[query])
        XCTAssertEqual(plan.contract.steps[1].targetID, query)
    }

    func testStateSubsetBindsItsExactRequestedTargetsWithoutChangingTheProposal() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true)
        defer { fixture.close() }
        let (input, proposal) = try await prepareMixed(fixture)
        let query = try XCTUnwrap(input.evidence.fields.first { $0.control.label == "Query" }).editable.snapshot.targetID
        let subset = try ComputerUseBrowserFormStatePlan(input: input, proposal: proposal, verifyingTargetIDs: [query])
        let whole = try ComputerUseBrowserFormStatePlan(input: input, proposal: proposal)
        XCTAssertTrue(subset.capturedValuesMatch); XCTAssertFalse(whole.capturedValuesMatch)
        XCTAssertEqual(subset.expectedValues, [query:"concerts"]); XCTAssertNotEqual(subset.digest, whole.digest)
        XCTAssertThrowsError(try ComputerUseBrowserFormStatePlan(input: input, proposal: proposal, verifyingTargetIDs: []))
        XCTAssertThrowsError(try ComputerUseBrowserFormStatePlan(input: input, proposal: proposal, verifyingTargetIDs: ["foreign-target"]))
        XCTAssertEqual(proposal.edits.count, 3)
    }

    func testMixedStageSkipsTheLeadingQueryInputAndKeepsAnExplicitQueryPath() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true,
            handler: "document.getElementById('reference').value='unexpected-query-input';")
        defer { fixture.close() }
        let (input, proposal) = try await prepareMixed(fixture), owner = try fixture.owner()
        let receipt = try await owner.executeForm(proposal, input: input)
        XCTAssertEqual(receipt.editCount, 2); XCTAssertEqual(receipt.verifiedWithoutInputCount, 1)
        XCTAssertEqual(receipt.plannedEditCount, 3); XCTAssertTrue(receipt.isCompleteStage)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        configureMixed(fixture, editing: ["Query","Category","City"], querying: true)
        let query = try await owner.planNextAction(using: fixture.actions)
        guard case .openQuery = query.step else { return XCTFail("All three verified criteria must remain queryable") }
        _ = try await owner.openFormQuery(for: query)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts&city=Seattle"), 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testMixedStageCanVerifyTwoLeadingCriteriaBeforeItsOneNecessaryInput() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true, categoryAlreadyMatches: true,
            handler: "document.getElementById('reference').value='unexpected-query-input';",
            categoryHandler: "document.getElementById('reference').value='unexpected-choice-input';")
        defer { fixture.close() }
        let (input, proposal) = try await prepareMixed(fixture), owner = try fixture.owner()
        let receipt = try await owner.executeForm(proposal, input: input)
        XCTAssertEqual(receipt.editCount, 1); XCTAssertEqual(receipt.verifiedWithoutInputCount, 2)
        XCTAssertEqual(receipt.plannedEditCount, 3); XCTAssertTrue(receipt.isCompleteStage)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        configureMixed(fixture, editing: ["Query","Category","City"], querying: true)
        let action = try await owner.planNextAction(using: fixture.actions)
        guard case .openQuery = action.step else { return XCTFail("Observed text and choice must retain their query origins") }
        _ = try await owner.openFormQuery(for: action)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts&city=Seattle"), 1)
    }

    func testMixedStageResumesObservationInputAndFinalOriginInspectionWithoutReplaying() async throws {
        for boundary in [ComputerUseBrowserDOMCommand.verifyFormState, .edit, .inspectFormRequirements] {
            let fixture = try await make(category: true, city: true, queryAlreadyMatches: true)
            defer { fixture.close() }
            let (input, proposal) = try await prepareMixed(fixture), owner = try fixture.owner()
            fixture.state.onCommand = { command in
                guard command == boundary else { return }; fixture.state.onCommand = nil; owner.pause()
            }
            await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
            XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
            let before = fixture.state.commands
            await expectFailure { _ = try await owner.resumeForm() }
            XCTAssertEqual(fixture.state.commands, before)
            try await owner.resumeAfterUserControl()
            let result = try await owner.resumeForm(), receipt = try XCTUnwrap(result)
            XCTAssertEqual(receipt.editCount, 2); XCTAssertEqual(receipt.verifiedWithoutInputCount, 1)
            XCTAssertTrue(receipt.isCompleteStage)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        }
    }

    func testMixedStageRejectsAnOlderFullInputJournalInsteadOfReinterpretingItsSteps() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true)
        defer { fixture.close() }
        _ = try await fixture.start(); configureMixed(fixture, editing: ["Query","Category","City"])
        let action = try await fixture.owner().planNextAction(using: fixture.actions)
        let frame = try ComputerUseBrowserResearchFormPreparation(action: action, browser: fixture.browser)
        let input = try await frame.prepare(browser: fixture.browser, checkCurrent: {})
        let proposal = try ComputerUseBrowserFormProposal.decode(content: mixedContent(input, order: ["Query","Category","City"]), input: input)
        let stage = try ComputerUseBrowserResearchFormStage(input: input, proposal: proposal, target: frame.target,
            browser: fixture.browser, index: 0, journalDirectory: fixture.directory)
        let full = try XCTUnwrap(proposal.textContract(for: input, stageID: stage.id))
        let legacy = try ComputerUseTextTask(contract: full, read: { _ in nil }, apply: { _, _ in }, persist: { _ in }, mayAct: { false })
        let store = try ComputerUseTaskJournalStore(directory: fixture.directory.appendingPathComponent("Research Forms").appendingPathComponent(stage.id))
        try store.save(legacy.journal, replacing: nil)
        await expectFailure { _ = try await stage.run(checkCurrent: {}) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState || $0 == .edit }.count, 0)
        XCTAssertNil(stage.nativeReceipt)
        XCTAssertEqual(try XCTUnwrap(store.load(taskID: full.taskID)).contractDigest, full.contractDigest)
    }

    func testMixedStageCannotReconstructItsObservationOriginAfterAnInputAttempt() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true)
        defer { fixture.close() }
        _ = try await fixture.start(); configureMixed(fixture, editing: ["Query","Category","City"])
        let action = try await fixture.owner().planNextAction(using: fixture.actions)
        let frame = try ComputerUseBrowserResearchFormPreparation(action: action, browser: fixture.browser)
        let input = try await frame.prepare(browser: fixture.browser, checkCurrent: {})
        let proposal = try ComputerUseBrowserFormProposal.decode(content: mixedContent(input, order: ["Query","Category","City"]), input: input)
        func stage() throws -> ComputerUseBrowserResearchFormStage {
            try .init(input: input, proposal: proposal, target: frame.target, browser: fixture.browser, index: 0, journalDirectory: fixture.directory)
        }
        let original = try stage()
        var work: Task<ComputerUseBrowserResearchFormReceipt, Error>?
        fixture.state.onCommand = { command in
            guard command == .edit else { return }; fixture.state.onCommand = nil; work?.cancel()
        }
        work = Task { @MainActor in try await original.run(checkCurrent: {}) }
        let pending = try XCTUnwrap(work)
        await expectFailure { _ = try await pending.value }
        let commands = fixture.state.commands, reconstructed = try stage()
        await expectFailure { _ = try await reconstructed.run(checkCurrent: {}) }
        XCTAssertEqual(fixture.state.commands, commands); XCTAssertNil(reconstructed.nativeReceipt)
        let result = try await original.run(checkCurrent: {})
        XCTAssertEqual(result.editCount, 2); XCTAssertEqual(result.verifiedWithoutInputCount, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testChangedLeadingCriteriaCannotBeSilentlyAdoptedBeforeMixedInput() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true,
            mutation: "document.getElementById('query').value='movies';")
        defer { fixture.close() }
        let (input, proposal) = try await prepareMixed(fixture), owner = try fixture.owner()
        try await release(fixture)
        await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
        XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testAnInputHandlerCannotResetAnAlreadyVerifiedLeadingCriterionAndContinue() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true,
            categoryHandler: "document.getElementById('query').value='reset-by-category';")
        defer { fixture.close() }
        let (input, proposal) = try await prepareMixed(fixture), owner = try fixture.owner()
        await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .prepareFormQuery }.count, 0)
    }

    func testMixedPrefixRetainsObservedCriteriaAndOnlyMapsItsRemainingInput() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true)
        defer { fixture.close() }
        let (input, proposal) = try await prepareMixed(fixture), owner = try fixture.owner()
        let pauseAt = fixture.state.writes + 3
        fixture.state.onWrite = { if fixture.state.writes == pauseAt { owner.pause() } }
        await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
        fixture.state.onWrite = nil
        try await owner.resumeAfterUserControl()
        let result = try await owner.retainPendingFormPrefix(), receipt = try XCTUnwrap(result)
        XCTAssertEqual(receipt.editCount, 1); XCTAssertEqual(receipt.verifiedWithoutInputCount, 1)
        XCTAssertEqual(receipt.plannedEditCount, 3); XCTAssertFalse(receipt.isCompleteStage)
        configureMixed(fixture, editing: ["City"], retaining: ["Query","Category"])
        let action = try await owner.planNextAction(using: fixture.actions)
        XCTAssertTrue(action.input.queryControlIDs.isEmpty)
        let next = try await owner.prepareFormInput(for: action)
        XCTAssertEqual(next.previous?.pendingEdits.map(\.label), ["City"])
        XCTAssertEqual(next.previous?.stateProofsByTarget.count, 1)
        XCTAssertEqual(next.previous?.inputOperationIDs.count, 1)
        XCTAssertEqual(next.previous?.verifiedTargetIDs.count, 2)
        XCTAssertEqual(next.previous?.editedTargetIDs.count, 1)
        let replacement = try ComputerUseBrowserFormProposal.decode(content: mixedContent(next, order: ["City"]), input: next)
        _ = try await owner.executeForm(replacement, input: next)
        configureMixed(fixture, editing: ["City"], retaining: ["Query","Category"], querying: true)
        let query = try await owner.planNextAction(using: fixture.actions)
        _ = try await owner.openFormQuery(for: query)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts&city=Seattle"), 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testMixedPrefixCannotDropReadonlyPreservationDuringSuffixRetirement() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true,
            mutation: "document.getElementById('reference').value='changed';")
        defer { fixture.close() }
        let (input, proposal) = try await prepareMixed(fixture), owner = try fixture.owner()
        let pauseAt = fixture.state.writes + 3
        fixture.state.onWrite = { if fixture.state.writes == pauseAt { owner.pause() } }
        await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
        fixture.state.onWrite = nil
        try await release(fixture)
        await expectFailure { try await owner.resumeAfterUserControl(); _ = try await owner.retainPendingFormPrefix() }
        XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testLaterMatchingChoiceRequiresAnOrderedUnsentCheckpointBeforeObservation() async throws {
        let fixture = try await make(category: true, categoryAlreadyMatches: true,
            categoryHandler: "document.getElementById('reference').value='unexpected-choice-input';")
        defer { fixture.close() }
        let (input, proposal) = try await prepareMixed(fixture, order: ["Query","Category"]), owner = try fixture.owner()
        do { _ = try await owner.executeForm(proposal, input: input); XCTFail("The later match needs a checkpoint") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchFormStage.Failure, .valueCheckpointRequired) }
        XCTAssertTrue(owner.confirmedFormHistory.isEmpty); XCTAssertTrue(owner.hasPendingForm)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, 0)
        let result = try await owner.retainPendingFormPrefix(), prefix = try XCTUnwrap(result)
        XCTAssertEqual(prefix.editCount, 1); XCTAssertEqual(prefix.verifiedWithoutInputCount, 0)
        XCTAssertEqual(prefix.plannedEditCount, 2); XCTAssertFalse(prefix.isCompleteStage)
        let directory = fixture.directory.appendingPathComponent("Research/Research Forms").appendingPathComponent(prefix.stageID)
        let store = try ComputerUseTaskJournalStore(directory: directory)
        let journal = try XCTUnwrap(store.load(taskID: input.interpretation.input.taskID))
        XCTAssertEqual(journal.statuses, [.verified, .uncertain]); XCTAssertEqual(journal.retainedPrefixCount, 1)
        XCTAssertNotNil(journal.retirementDigest)
        configureMixed(fixture, editing: ["Category"], retaining: ["Query"])
        let action = try await owner.planNextAction(using: fixture.actions)
        XCTAssertTrue(action.input.queryControlIDs.isEmpty)
        let next = try await owner.prepareFormInput(for: action)
        XCTAssertEqual(next.previous?.pendingEdits.map(\.label), ["Category"])
        XCTAssertEqual(next.previous?.inputOperationIDs.count, 1)
        let replacement = try ComputerUseBrowserFormProposal.decode(content: mixedContent(next, order: ["Category"]), input: next)
        let receipt = try await owner.executeForm(replacement, input: next)
        XCTAssertEqual(receipt.editCount, 0); XCTAssertEqual(receipt.verifiedWithoutInputCount, 1)
        XCTAssertTrue(receipt.isCompleteStage)
        configureMixed(fixture, editing: ["Category"], retaining: ["Query"], querying: true)
        let query = try await owner.planNextAction(using: fixture.actions)
        _ = try await owner.openFormQuery(for: query)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts"), 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(try store.load(taskID: input.interpretation.input.taskID), journal)
    }

    func testLaterMatchingTextBecomesALeadingPendingCriterionBeforeRemainingInput() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true,
            handler: "document.getElementById('reference').value='unexpected-query-input';")
        defer { fixture.close() }
        let (input, proposal) = try await checkpointRemainder(fixture, order: ["Category","Query","City"],
            remaining: ["Query","City"], retaining: ["Category"])
        let owner = try fixture.owner(), receipt = try await owner.executeForm(proposal, input: input)
        XCTAssertEqual(input.previous?.pendingEdits.map(\.label), ["Query","City"])
        XCTAssertEqual(proposal.resumptions.count, 2)
        XCTAssertEqual(receipt.editCount, 1); XCTAssertEqual(receipt.verifiedWithoutInputCount, 1)
        XCTAssertEqual(receipt.plannedEditCount, 2); XCTAssertTrue(receipt.isCompleteStage)
        configureMixed(fixture, editing: ["Query","City"], retaining: ["Category"], querying: true)
        let action = try await owner.planNextAction(using: fixture.actions)
        _ = try await owner.openFormQuery(for: action)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts&city=Seattle"), 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [1,1])
        XCTAssertEqual(owner.confirmedFormHistory.map(\.verifiedWithoutInputCount), [0,1])
    }

    func testEarlierHandlerChangesTheLaterDecisionUsingFreshPreparation() async throws {
        for initiallyMatching in [false, true] {
            let fixture = try await make(category: true, queryAlreadyMatches: initiallyMatching,
                categoryHandler: initiallyMatching ? "document.getElementById('query').value='reset';"
                    : "document.getElementById('query').value='concerts';")
            defer { fixture.close() }
            let (input, proposal) = try await checkpointRemainder(fixture, order: ["Category","Query"],
                remaining: ["Query"], retaining: ["Category"])
            let owner = try fixture.owner(), receipt = try await owner.executeForm(proposal, input: input)
            XCTAssertEqual(receipt.editCount, initiallyMatching ? 1 : 0)
            XCTAssertEqual(receipt.verifiedWithoutInputCount, initiallyMatching ? 0 : 1)
            XCTAssertTrue(receipt.isCompleteStage)
            configureMixed(fixture, editing: ["Query"], retaining: ["Category"], querying: true)
            let action = try await owner.planNextAction(using: fixture.actions)
            _ = try await owner.openFormQuery(for: action)
            XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts"), 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, initiallyMatching ? 2 : 1)
        }
    }

    func testDriverRepreparesALaterMatchAfterNativePrefixRevocation() async throws {
        let fixture = try await make(category: true, categoryAlreadyMatches: true,
            categoryHandler: "document.getElementById('reference').value='unexpected-choice-input';")
        defer { fixture.close() }
        _ = try await prepareMixed(fixture, order: ["Query","Category"])
        fixture.actions.select = { input in
            guard input.evidence.page.controls.contains(where: { $0.label == "Query" }) else { return #"{"unavailable":true}"# }
            let hasPrefix = !input.queryBoundControlIDs.isEmpty
            if let review = try FormEffectScopeFixture.response(input,
                editing: hasPrefix ? ["Category":[0]] : ["Query":[0],"Category":[0]],
                retaining: hasPrefix ? ["Query":[0]] : [:], preserving: ["Reference":1]) { return review }
            if input.formEffectScope != nil && !input.effectScopeAllowsActions { return #"{"unavailable":true}"# }
            if let query = input.queryControlIDs.first { return try ResearchAnswerFixture.json(["query":query]) }
            let form = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Query" }?.form?.id)
            return try ResearchAnswerFixture.json(["form":form,"preserve":[]])
        }
        fixture.forms.select = { input in
            try self.mixedContent(input, order: input.pendingEditAliases.isEmpty ? ["Query","Category"] : ["Category"])
        }
        _ = try await fixture.resume()
        let owner = try fixture.owner()
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [1,0])
        XCTAssertEqual(owner.confirmedFormHistory.map(\.verifiedWithoutInputCount), [0,1])
        XCTAssertEqual(owner.retiredFormHistory.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .retireUnsentInputs }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(fixture.forms.inputs.count, 2)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts"), 1)
    }

    func testMatchingPendingCriteriaStillRequireCompleteDistinctCurrentMappings() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true)
        defer { fixture.close() }
        let (input, proposal) = try await checkpointRemainder(fixture, order: ["Category","Query","City"],
            remaining: ["Query","City"], retaining: ["Category"])
        let content = try mixedContent(input, order: ["Query","City"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(body["resume"] as? [[String: String]])
        for mutation in 0..<4 {
            var changed = body, mappings = rows
            switch mutation {
            case 0: changed.removeValue(forKey: "resume")
            case 1: changed["resume"] = Array(mappings.prefix(1))
            case 2: mappings[1]["field"] = mappings[0]["field"]; changed["resume"] = mappings
            default: mappings[0]["pending"] = "stale-pending-id"; changed["resume"] = mappings
            }
            XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: ResearchAnswerFixture.json(changed), input: input))
        }
        let state = try ComputerUseBrowserFormExecutionPlan(input: input, proposal: proposal,
            stageID: ComputerUseTaskContract.digest(["pending-matching-plan"]))
        XCTAssertTrue(state.isMixed); XCTAssertEqual(state.observedEdits.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, 0)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testCheckpointRevocationAndFreshProofRequireHandbackAfterPause() async throws {
        for boundary in [ComputerUseBrowserDOMCommand.retireUnsentInputs, .verifyFormState, .validateFormState] {
            let fixture = try await make(category: true, categoryAlreadyMatches: true)
            defer { fixture.close() }
            let (first, original) = try await prepareMixed(fixture, order: ["Query","Category"]), owner = try fixture.owner()
            await expectFailure { _ = try await owner.executeForm(original, input: first) }
            fixture.state.onCommand = { command in
                guard command == boundary else { return }; fixture.state.onCommand = nil; owner.pause()
            }
            if boundary == .retireUnsentInputs {
                await expectFailure { _ = try await owner.retainPendingFormPrefix() }
                let commands = fixture.state.commands
                await expectFailure { _ = try await owner.retainPendingFormPrefix() }
                XCTAssertEqual(fixture.state.commands, commands)
                try await owner.resumeAfterUserControl()
            }
            _ = try await owner.retainPendingFormPrefix()
            configureMixed(fixture, editing: ["Category"], retaining: ["Query"])
            let action = try await owner.planNextAction(using: fixture.actions)
            let input = try await owner.prepareFormInput(for: action)
            let proposal = try ComputerUseBrowserFormProposal.decode(content: mixedContent(input, order: ["Category"]), input: input)
            if boundary != .retireUnsentInputs {
                await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
                let commands = fixture.state.commands
                await expectFailure { _ = try await owner.resumeForm() }
                XCTAssertEqual(fixture.state.commands, commands)
                try await owner.resumeAfterUserControl()
                _ = try await owner.resumeForm()
            } else { _ = try await owner.executeForm(proposal, input: input) }
            XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [1,0])
            XCTAssertEqual(owner.confirmedFormHistory.map(\.verifiedWithoutInputCount), [0,1])
            XCTAssertEqual(owner.retiredFormHistory.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, 1)
        }
    }

    func testUncertainLaterNativeInputCannotBeReplacedWithAMatchingStateProof() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (input, proposal) = try await prepareMixed(fixture, order: ["Query","Category"]), owner = try fixture.owner()
        var edits = 0
        fixture.state.onCommand = { command in
            guard command == .edit else { return }; edits += 1
            if edits == 2 { fixture.state.onCommand = nil; owner.pause() }
        }
        await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
        try await owner.resumeAfterUserControl()
        XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
        let result = try await owner.resumeForm(), receipt = try XCTUnwrap(result)
        XCTAssertEqual(receipt.editCount, 2); XCTAssertEqual(receipt.verifiedWithoutInputCount, 0)
        XCTAssertTrue(receipt.isCompleteStage)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, 0)
    }

    func testCheckpointCannotAdoptChangedPreservationOrEarlierCriteria() async throws {
        for mutation in ["document.getElementById('reference').value='changed';", "document.getElementById('query').value='movies';"] {
            let fixture = try await make(category: true, categoryAlreadyMatches: true, mutation: mutation)
            defer { fixture.close() }
            let (input, proposal) = try await prepareMixed(fixture, order: ["Query","Category"]), owner = try fixture.owner()
            await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
            try await release(fixture)
            if mutation.contains("reference") {
                await expectFailure { _ = try await owner.retainPendingFormPrefix() }
                XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
            } else {
                // Earlier changed criteria may be retained as explicit repair
                // obligations, but never silently become the new goal value.
                _ = try await owner.retainPendingFormPrefix()
                configureMixed(fixture, editing: ["Query","Category"])
                let action = try await owner.planNextAction(using: fixture.actions)
                XCTAssertTrue(action.input.queryControlIDs.isEmpty)
                let next = try await owner.prepareFormInput(for: action)
                XCTAssertFalse(next.requiredRepairFieldAliases.isEmpty)
                let replacement = try ComputerUseBrowserFormProposal.decode(content: mixedContent(next, order: ["Query","Category"]), input: next)
                let plan = try ComputerUseBrowserFormExecutionPlan(input: next, proposal: replacement,
                    stageID: ComputerUseTaskContract.digest(["changed-earlier-criterion"]))
                XCTAssertNil(plan.statePlan)
            }
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .prepareFormQuery }.count, 0)
        }
    }

    func testObservationOnlyPrefixRetainsAllUnsentInputsAndAnExplicitQueryPath() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true,
            handler: "document.getElementById('reference').value='unexpected-query-input';")
        defer { fixture.close() }
        let first = try await failFirstMixedAttempt(fixture), owner = try fixture.owner()
        let (store, before) = try pendingMixedJournal(fixture)
        XCTAssertEqual(before.statuses, [.attempted,.planned])
        let discarded = try await owner.retirePendingUnsentForm()
        XCTAssertNil(discarded, "Whole-stage retirement must not discard verified observations")
        let result = try await owner.retainPendingFormPrefix(), prefix = try XCTUnwrap(result)
        XCTAssertEqual(prefix.editCount, 0); XCTAssertEqual(prefix.verifiedWithoutInputCount, 1)
        XCTAssertEqual(prefix.plannedEditCount, 3); XCTAssertFalse(prefix.isCompleteStage)
        let saved = try XCTUnwrap(store.load(taskID: first.interpretation.input.taskID))
        XCTAssertEqual(saved.statuses, before.statuses); XCTAssertEqual(saved.retainedPrefixCount, 0)
        XCTAssertNotNil(saved.retirementDigest)
        configureMixed(fixture, editing: ["Category","City"], retaining: ["Query"])
        let action = try await owner.planNextAction(using: fixture.actions)
        XCTAssertTrue(action.input.queryControlIDs.isEmpty)
        let next = try await owner.prepareFormInput(for: action)
        XCTAssertEqual(next.previous?.pendingEdits.map(\.label), ["Category","City"])
        XCTAssertEqual(next.previous?.inputOperationIDs, [])
        XCTAssertEqual(next.previous?.verifiedTargetIDs.count, 1)
        XCTAssertEqual(next.previous?.editedTargetIDs.count, 0)
        XCTAssertEqual(next.previous?.stateProofsByTarget.count, 1)
        let proposal = try ComputerUseBrowserFormProposal.decode(content: mixedContent(next, order: ["Category","City"]), input: next)
        _ = try await owner.executeForm(proposal, input: next)
        configureMixed(fixture, editing: ["Category","City"], retaining: ["Query"], querying: true)
        let query = try await owner.planNextAction(using: fixture.actions)
        _ = try await owner.openFormQuery(for: query)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts&city=Seattle"), 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [0,2])
        XCTAssertEqual(owner.confirmedFormHistory.map(\.verifiedWithoutInputCount), [1,0])
        XCTAssertEqual(try store.load(taskID: before.taskID), saved)
    }

    func testDriverCarriesAnObservationOnlyPrefixThroughTheRemainingForm() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true,
            handler: "document.getElementById('reference').value='unexpected-query-input';")
        defer { fixture.close() }
        _ = try await failFirstMixedAttempt(fixture)
        configureMixed(fixture, editing: ["Category","City"], retaining: ["Query"], querying: true)
        let select = fixture.actions.select
        fixture.actions.select = { input in
            guard input.evidence.page.controls.contains(where: { $0.label == "Query" }) else { return #"{"unavailable":true}"# }
            return try XCTUnwrap(select)(input)
        }
        fixture.forms.select = { try self.mixedContent($0, order: ["Category","City"]) }
        _ = try await fixture.resume()
        let owner = try fixture.owner()
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [0,2])
        XCTAssertEqual(owner.confirmedFormHistory.map(\.verifiedWithoutInputCount), [1,0])
        XCTAssertEqual(owner.retiredFormHistory.count, 1)
        XCTAssertEqual(fixture.forms.inputs.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, 1)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts&city=Seattle"), 1)
    }

    func testZeroCurrentInputPrefixKeepsEarlierStagesActualInputLedger() async throws {
        let fixture = try await make(category: true, city: true, categoryAlreadyMatches: true,
            categoryHandler: "document.getElementById('reference').value='unexpected-choice-input';")
        defer { fixture.close() }
        _ = try await fixture.start(); configureMixed(fixture, editing: ["Query"])
        let fallback = fixture.actions.select
        fixture.actions.select = { input in
            if let review = try FormEffectScopeFixture.response(input, editing: ["Query":[0]],
                deferring: ["Category":[0],"City":[0]], preserving: ["Reference":1]) { return review }
            return try XCTUnwrap(fallback)(input)
        }
        let owner = try fixture.owner(), firstAction = try await owner.planNextAction(using: fixture.actions)
        let first = try await owner.prepareFormInput(for: firstAction)
        _ = try await owner.executeForm(.decode(content: mixedContent(first, order: ["Query"]), input: first), input: first)
        configureMixed(fixture, editing: ["Category","City"], retaining: ["Query"])
        let action = try await owner.planNextAction(using: fixture.actions)
        let input = try await owner.prepareFormInput(for: action)
        let earlierIDs = try XCTUnwrap(input.previous?.inputOperationIDs)
        XCTAssertEqual(earlierIDs.count, 1)
        let proposal = try ComputerUseBrowserFormProposal.decode(content: mixedContent(input, order: ["Category","City"]), input: input)
        fixture.state.failureAtWrite = fixture.state.writes + 2
        await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
        fixture.state.failureAtWrite = nil
        let result = try await owner.retainPendingFormPrefix(), receipt = try XCTUnwrap(result)
        XCTAssertEqual(receipt.editCount, 0); XCTAssertEqual(receipt.verifiedWithoutInputCount, 1)
        configureMixed(fixture, editing: ["City"], retaining: ["Query","Category"])
        let nextAction = try await owner.planNextAction(using: fixture.actions)
        let next = try await owner.prepareFormInput(for: nextAction)
        XCTAssertEqual(next.previous?.inputOperationIDs, earlierIDs)
        XCTAssertEqual(next.previous?.editedTargetIDs.count, 1); XCTAssertEqual(next.previous?.verifiedTargetIDs.count, 2)
        XCTAssertEqual(next.previous?.stateProofsByTarget.count, 1)
        XCTAssertEqual(next.previous?.pendingEdits.map(\.label), ["City"])
        _ = try await owner.executeForm(.decode(content: mixedContent(next, order: ["City"]), input: next), input: next)
        configureMixed(fixture, editing: ["City"], retaining: ["Query","Category"], querying: true)
        let query = try await owner.planNextAction(using: fixture.actions)
        _ = try await owner.openFormQuery(for: query)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [1,0,1])
        XCTAssertEqual(owner.confirmedFormHistory.map(\.verifiedWithoutInputCount), [0,1,0])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts&city=Seattle"), 1)
    }

    func testObservationPrefixCanRetirePlannedInputAfterExplicitHandback() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true)
        defer { fixture.close() }
        let (input, proposal) = try await prepareMixed(fixture), owner = try fixture.owner()
        fixture.state.onCommand = { command in
            guard command == .validateFormState else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
        let (_, before) = try pendingMixedJournal(fixture)
        XCTAssertEqual(before.statuses, [.planned,.planned])
        let commands = fixture.state.commands
        await expectFailure { _ = try await owner.retainPendingFormPrefix() }
        XCTAssertEqual(fixture.state.commands, commands)
        try await owner.resumeAfterUserControl()
        let result = try await owner.retainPendingFormPrefix(), receipt = try XCTUnwrap(result)
        XCTAssertEqual(receipt.editCount, 0); XCTAssertEqual(receipt.verifiedWithoutInputCount, 1)
        XCTAssertFalse(receipt.isCompleteStage)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, 1)
    }

    func testFirstNativeInputAfterObservationCannotBeRetiredButCanReconcile() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true)
        defer { fixture.close() }
        let (input, proposal) = try await prepareMixed(fixture), owner = try fixture.owner()
        fixture.state.onCommand = { command in
            guard command == .edit else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
        try await owner.resumeAfterUserControl()
        let full = try await owner.retainCompletedFormHistory()
        XCTAssertNil(full, "An attempted first input cannot become fully dispatched history")
        let prefix = try await owner.retainPendingFormPrefix()
        let whole = try await owner.retirePendingUnsentForm()
        XCTAssertNil(prefix); XCTAssertNil(whole)
        XCTAssertTrue(owner.confirmedFormHistory.isEmpty); XCTAssertTrue(owner.retiredFormHistory.isEmpty)
        let (_, journal) = try pendingMixedJournal(fixture)
        XCTAssertNil(journal.retirementDigest); XCTAssertNil(journal.retainedPrefixCount)
        let result = try await owner.resumeForm(), receipt = try XCTUnwrap(result)
        XCTAssertEqual(receipt.editCount, 2); XCTAssertEqual(receipt.verifiedWithoutInputCount, 1)
        XCTAssertTrue(receipt.isCompleteStage)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, 1)
    }

    func testObservedPrefixRetirementSurvivesPauseAndFailedDurabilityWithoutDuplicateHistory() async throws {
        for boundary in ["native", "publication", "durability"] {
            let fixture = try await make(category: true, city: true, queryAlreadyMatches: true)
            defer { fixture.close() }
            _ = try await failFirstMixedAttempt(fixture)
            let owner = try fixture.owner(), (store, before) = try pendingMixedJournal(fixture)
            let nextWrite = fixture.state.writes + 1
            if boundary == "native" {
                fixture.state.onCommand = { command in
                    guard command == .retireUnsentInputs else { return }; fixture.state.onCommand = nil; owner.pause()
                }
            } else if boundary == "publication" {
                fixture.state.onWrite = { if fixture.state.writes == nextWrite { owner.pause() } }
            } else { fixture.state.failureAtWrite = nextWrite }
            await expectFailure { _ = try await owner.retainPendingFormPrefix() }
            fixture.state.onWrite = nil; fixture.state.failureAtWrite = nil
            XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
            if boundary != "durability" {
                let commands = fixture.state.commands
                await expectFailure { _ = try await owner.retainPendingFormPrefix() }
                XCTAssertEqual(fixture.state.commands, commands)
                try await owner.resumeAfterUserControl()
            }
            await expectFailure { _ = try await owner.resumeForm() }
            let result = try await owner.retainPendingFormPrefix(), receipt = try XCTUnwrap(result)
            XCTAssertEqual(receipt.editCount, 0); XCTAssertEqual(receipt.verifiedWithoutInputCount, 1)
            let duplicate = try await owner.retainPendingFormPrefix()
            XCTAssertNil(duplicate)
            XCTAssertEqual(owner.confirmedFormHistory.count, 1); XCTAssertEqual(owner.retiredFormHistory.count, 1)
            let saved = try XCTUnwrap(store.load(taskID: before.taskID))
            XCTAssertEqual(saved.retainedPrefixCount, 0); XCTAssertEqual(saved.statuses, before.statuses)
            XCTAssertNotNil(saved.retirementDigest)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        }
    }

    func testObservedPrefixRejectsLostObjectsLedgerAndPreservation() async throws {
        for mutation in ["document.getElementById('query').replaceWith(document.getElementById('query').cloneNode(true));",
                         "document.getElementById('reference').value='changed';", ""] {
            let fixture = try await make(category: true, city: true, queryAlreadyMatches: true, mutation: mutation)
            defer { fixture.close() }
            let input = try await failFirstMixedAttempt(fixture), owner = try fixture.owner()
            let (store, before) = try pendingMixedJournal(fixture)
            if mutation.isEmpty {
                let other = ComputerUseBrowserTextTarget(browser: fixture.browser, document: input.evidence.page.document, requiresFrontmost: false)
                _ = try await other.fields()
            } else { try await release(fixture) }
            await expectFailure { _ = try await owner.retainPendingFormPrefix() }
            let whole = try await owner.retirePendingUnsentForm()
            XCTAssertNil(whole)
            XCTAssertEqual(try store.load(taskID: before.taskID), before)
            XCTAssertTrue(owner.confirmedFormHistory.isEmpty); XCTAssertTrue(owner.retiredFormHistory.isEmpty)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        }
    }

    func testChangedObservedPrefixRemainsARepairAlongsideEveryUnsentInput() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true,
            mutation: "document.getElementById('query').value='movies';")
        defer { fixture.close() }
        _ = try await failFirstMixedAttempt(fixture)
        let owner = try fixture.owner()
        try await release(fixture)
        let result = try await owner.retainPendingFormPrefix(), receipt = try XCTUnwrap(result)
        XCTAssertEqual(receipt.editCount, 0); XCTAssertEqual(receipt.verifiedWithoutInputCount, 1)
        configureMixed(fixture, editing: ["Query","Category","City"])
        let action = try await owner.planNextAction(using: fixture.actions)
        XCTAssertTrue(action.input.queryControlIDs.isEmpty)
        let next = try await owner.prepareFormInput(for: action)
        XCTAssertEqual(next.previous?.pendingEdits.map(\.label), ["Category","City"])
        let query = try XCTUnwrap(next.editableFieldAliases.first { (try? next.field(for: $0).control.label) == "Query" })
        XCTAssertEqual(next.requiredRepairFieldAliases, [query])
        let proposal = try ComputerUseBrowserFormProposal.decode(content: mixedContent(next, order: ["Query","Category","City"]), input: next)
        _ = try await owner.executeForm(proposal, input: next)
        configureMixed(fixture, editing: ["Query","Category","City"], querying: true)
        let queryAction = try await owner.planNextAction(using: fixture.actions)
        _ = try await owner.openFormQuery(for: queryAction)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts&city=Seattle"), 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 3)
    }

    func testAnAttemptedMixedJournalWithoutItsObservationProofCannotRetireEitherWay() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true)
        defer { fixture.close() }
        _ = try await fixture.start(); configureMixed(fixture, editing: ["Query","Category","City"])
        let action = try await fixture.owner().planNextAction(using: fixture.actions)
        let frame = try ComputerUseBrowserResearchFormPreparation(action: action, browser: fixture.browser)
        let input = try await frame.prepare(browser: fixture.browser, checkCurrent: {})
        let proposal = try ComputerUseBrowserFormProposal.decode(content: mixedContent(input, order: ["Query","Category","City"]), input: input)
        let stage = try ComputerUseBrowserResearchFormStage(input: input, proposal: proposal, target: frame.target,
            browser: fixture.browser, index: 0, journalDirectory: fixture.directory)
        let plan = try ComputerUseTextTask(contract: stage.contract, read: { _ in nil }, apply: { _, _ in }, persist: { _ in }, mayAct: { false })
        let store = try ComputerUseTaskJournalStore(directory: fixture.directory.appendingPathComponent("Research Forms").appendingPathComponent(stage.id))
        try store.save(plan.journal, replacing: nil)
        var attempted = plan.journal; attempted.statuses[0] = .attempted
        try store.save(attempted, replacing: plan.journal)
        let commands = fixture.state.commands
        let prefix = try await stage.retainVerifiedPrefix(checkCurrent: {})
        let whole = try await stage.retireUnsent(checkCurrent: {})
        XCTAssertNil(prefix); XCTAssertNil(whole); XCTAssertNil(stage.nativeReceipt)
        XCTAssertEqual(fixture.state.commands, commands)
        XCTAssertEqual(try store.load(taskID: attempted.taskID), attempted)
    }

    func testZeroInputRetirementMarkerCannotBeInventedOrRemovedByOrdinaryWrites() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true)
        defer { fixture.close() }
        _ = try await failFirstMixedAttempt(fixture)
        let owner = try fixture.owner(), (store, before) = try pendingMixedJournal(fixture)
        let invented = ComputerUseTaskJournal(taskID: before.taskID, promptDigest: before.promptDigest,
            contractDigest: before.contractDigest, stepIDs: before.stepIDs, statuses: before.statuses,
            retirementDigest: ComputerUseTaskContract.digest(["invented-observation"]), retainedPrefixCount: 0)
        XCTAssertThrowsError(try store.save(invented, replacing: before))
        XCTAssertThrowsError(try store.retireUnsent(invented, replacing: before))
        XCTAssertThrowsError(try store.retireRemainingInput(invented, replacing: before), "A retirement write requires its execution lease")
        XCTAssertEqual(try store.load(taskID: before.taskID), before)
        _ = try await owner.retainPendingFormPrefix()
        let saved = try XCTUnwrap(store.load(taskID: before.taskID))
        XCTAssertEqual(saved.retainedPrefixCount, 0)
        XCTAssertThrowsError(try store.save(before, replacing: saved))
        let lease = try store.acquireExecution(taskID: before.taskID, expected: saved)
        defer { lease.release() }
        XCTAssertThrowsError(try store.retireRemainingInput(invented, replacing: saved))
        XCTAssertThrowsError(try store.retireUnsent(saved, replacing: saved))
        XCTAssertEqual(try store.load(taskID: before.taskID), saved)
    }

    func testFullyDispatchedHistoryBecomesExplicitRepairWithoutReplayingCompletedInput() async throws {
        for observedQuery in [true, false] {
            let fixture = try await make(category: true, city: true, queryAlreadyMatches: observedQuery,
                mutation: "document.getElementById('query').value='movies';")
            defer { fixture.close() }
            _ = try await pauseAfterAllFormInputs(fixture)
            let owner = try fixture.owner(), (store, journal) = try pendingMixedJournal(fixture)
            try await release(fixture); try await owner.resumeAfterUserControl()
            await expectFailure { _ = try await owner.resumeForm() }
            let result = try await owner.retainCompletedFormHistory(), receipt = try XCTUnwrap(result)
            XCTAssertEqual(receipt.editCount, observedQuery ? 2 : 3)
            XCTAssertEqual(receipt.verifiedWithoutInputCount, observedQuery ? 1 : 0)
            XCTAssertEqual(receipt.plannedEditCount, 3)
            XCTAssertTrue(receipt.requiresRepairAtPublication); XCTAssertFalse(receipt.isCompleteStage)
            XCTAssertTrue(owner.retiredFormHistory.isEmpty)
            XCTAssertEqual(try store.load(taskID: journal.taskID), journal)
            configureMixed(fixture, editing: ["Query"], retaining: ["Category","City"])
            let action = try await owner.planNextAction(using: fixture.actions)
            XCTAssertTrue(action.input.queryControlIDs.isEmpty); XCTAssertTrue(action.input.usesFormRecoveryContext)
            let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(action.input.contextJSON.utf8)) as? [String: Any])
            XCTAssertEqual(context["version"] as? Int, 21)
            let stage = try XCTUnwrap(context["verified_form_stage"] as? [String: Any])
            XCTAssertEqual(stage["required_repair_when_recorded"] as? Bool, true)
            XCTAssertEqual(stage["complete_stage"] as? Bool, false); XCTAssertNil(stage["edits"])
            let criteria = try XCTUnwrap(stage["criteria"] as? [[String: Any]])
            XCTAssertEqual(criteria.filter { $0["requires_repair"] as? Bool == true }.count, 1)
            let local = try ComputerUseLocalBrowserActionPlanner(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")),
                bearerToken: "fixture", modelAlias: "fixture-model"), transport: ControlStateUnusedTransport())
            let request = try local.makeRequest(action.input)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let response = try XCTUnwrap(body["response_format"] as? [String: Any])
            XCTAssertEqual((response["json_schema"] as? [String: Any])?["name"] as? String, "browser_research_action_v21")
            let next = try await owner.prepareFormInput(for: action)
            XCTAssertEqual(next.previous?.pendingEdits, [])
            XCTAssertEqual(next.previous?.inputOperationIDs.count, observedQuery ? 2 : 3)
            XCTAssertEqual(next.requiredRepairFieldAliases.count, 1)
            let proposal = try ComputerUseBrowserFormProposal.decode(content: mixedContent(next, order: ["Query"]), input: next)
            _ = try await owner.executeForm(proposal, input: next)
            configureMixed(fixture, editing: ["Query"], retaining: ["Category","City"], querying: true)
            let query = try await owner.planNextAction(using: fixture.actions)
            _ = try await owner.openFormQuery(for: query)
            XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts&city=Seattle"), 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, observedQuery ? 3 : 4)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .retireUnsentInputs }.count, 0)
            XCTAssertEqual(try store.load(taskID: journal.taskID), journal)
        }
    }

    func testDriverRecoversFullInputHistoryAndPlansOnlyTheChangedCriterion() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true,
            cityHandler: "document.getElementById('query').value='movies';")
        defer { fixture.close() }
        _ = try await prepareMixed(fixture)
        let owner = try fixture.owner()
        configureMixed(fixture, editing: ["Query"], retaining: ["Category","City"], querying: true)
        let select = fixture.actions.select
        fixture.actions.select = { input in
            guard input.evidence.page.controls.contains(where: { $0.label == "Query" }) else { return #"{"unavailable":true}"# }
            return try XCTUnwrap(select)(input)
        }
        fixture.forms.select = { try self.mixedContent($0, order: $0.previous == nil ? ["Query","Category","City"] : ["Query"]) }
        _ = try await fixture.resume()
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [2,1])
        XCTAssertEqual(owner.confirmedFormHistory.map(\.requiresRepairAtPublication), [true,false])
        XCTAssertEqual(owner.confirmedFormHistory.map(\.isCompleteStage), [false,true])
        XCTAssertTrue(owner.retiredFormHistory.isEmpty)
        XCTAssertEqual(fixture.forms.inputs.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 3)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts&city=Seattle"), 1)
    }

    func testFullHistoryInspectionRequiresHandbackAndPublishesOnlyOnce() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true,
            mutation: "document.getElementById('query').value='movies';")
        defer { fixture.close() }
        _ = try await pauseAfterAllFormInputs(fixture)
        let owner = try fixture.owner(), (store, journal) = try pendingMixedJournal(fixture)
        try await release(fixture); try await owner.resumeAfterUserControl()
        fixture.state.onCommand = { command in
            guard command == .inspectFormRequirements else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.retainCompletedFormHistory() }
        XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
        let commands = fixture.state.commands
        await expectFailure { _ = try await owner.retainCompletedFormHistory() }
        XCTAssertEqual(fixture.state.commands, commands)
        try await owner.resumeAfterUserControl()
        let result = try await owner.retainCompletedFormHistory(), receipt = try XCTUnwrap(result)
        XCTAssertTrue(receipt.requiresRepairAtPublication)
        let duplicate = try await owner.retainCompletedFormHistory()
        XCTAssertNil(duplicate); XCTAssertEqual(owner.confirmedFormHistory, [receipt])
        XCTAssertEqual(try store.load(taskID: journal.taskID), journal)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testFullHistoryCannotUseDiskFlagsAfterTheNativeLedgerIsLost() async throws {
        for observedQuery in [false, true] {
            let fixture = try await make(category: true, city: true, queryAlreadyMatches: observedQuery)
            defer { fixture.close() }
            let input = try await pauseAfterAllFormInputs(fixture), owner = try fixture.owner()
            let (store, before) = try pendingMixedJournal(fixture)
            XCTAssertTrue(before.statuses.allSatisfy { $0 == .verified })
            try await owner.resumeAfterUserControl()
            let other = ComputerUseBrowserTextTarget(browser: fixture.browser, document: input.evidence.page.document, requiresFrontmost: false)
            _ = try await other.fields()
            await expectFailure { _ = try await owner.retainCompletedFormHistory() }
            XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
            XCTAssertEqual(try store.load(taskID: before.taskID), before)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, observedQuery ? 2 : 3)
        }
    }

    func testFullHistoryRejectsChangedPreservationAndReplacedRequiredObjects() async throws {
        for mutation in ["document.getElementById('reference').value='changed';",
                         "document.getElementById('query').replaceWith(document.getElementById('query').cloneNode(true));"] {
            let fixture = try await make(category: true, city: true, queryAlreadyMatches: true, mutation: mutation)
            defer { fixture.close() }
            _ = try await pauseAfterAllFormInputs(fixture)
            let owner = try fixture.owner()
            try await release(fixture); try await owner.resumeAfterUserControl()
            await expectFailure { _ = try await owner.retainCompletedFormHistory() }
            XCTAssertTrue(owner.confirmedFormHistory.isEmpty); XCTAssertTrue(owner.retiredFormHistory.isEmpty)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .prepareFormQuery }.count, 0)
        }
    }

    func testFullHistoryCannotPublishAfterItsJournalDisappearsDuringInspection() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true)
        defer { fixture.close() }
        _ = try await pauseAfterAllFormInputs(fixture)
        let owner = try fixture.owner(), (_, journal) = try pendingMixedJournal(fixture)
        try await owner.resumeAfterUserControl()
        let root = fixture.directory.appendingPathComponent("Research/Research Forms")
        let directory = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let path = directory.appendingPathComponent(ComputerUseTextTaskContract.digest(journal.taskID) + ".json")
        var mutationError: Error?
        fixture.state.onCommand = { command in
            guard command == .inspectFormRequirements else { return }; fixture.state.onCommand = nil
            do { try FileManager.default.removeItem(at: path) } catch { mutationError = error }
        }
        await expectFailure { _ = try await owner.retainCompletedFormHistory() }
        XCTAssertNil(mutationError); XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testFreshInspectionCanCompleteFullHistoryWhoseCriteriaStillMatch() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true)
        defer { fixture.close() }
        _ = try await pauseAfterAllFormInputs(fixture)
        let owner = try fixture.owner()
        try await owner.resumeAfterUserControl()
        let result = try await owner.retainCompletedFormHistory(), receipt = try XCTUnwrap(result)
        XCTAssertTrue(receipt.isCompleteStage); XCTAssertFalse(receipt.requiresRepairAtPublication)
        configureMixed(fixture, editing: ["Query","Category","City"], querying: true)
        let action = try await owner.planNextAction(using: fixture.actions)
        XCTAssertFalse(action.input.usesFormRecoveryContext)
        _ = try await owner.openFormQuery(for: action)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts&city=Seattle"), 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testHistoricalRepairFlagDoesNotOverrideFreshRestoredCriteria() async throws {
        let fixture = try await make(category: true, city: true, queryAlreadyMatches: true,
            mutation: "document.getElementById('query').value='movies';fetch('/signal').then(()=>{document.getElementById('query').value='concerts';fetch('/restored');});")
        defer { fixture.close() }
        _ = try await pauseAfterAllFormInputs(fixture)
        let owner = try fixture.owner()
        try await release(fixture); try await owner.resumeAfterUserControl()
        let result = try await owner.retainCompletedFormHistory(), receipt = try XCTUnwrap(result)
        XCTAssertTrue(receipt.requiresRepairAtPublication); XCTAssertFalse(receipt.isCompleteStage)
        let deadline = ContinuousClock.now + .seconds(5)
        while fixture.server.count("/signal") != 2 {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
        fixture.server.releaseHeldResponses()
        while fixture.server.count("/restored") != 1 {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
        configureMixed(fixture, editing: ["Query","Category","City"], querying: true)
        let action = try await owner.planNextAction(using: fixture.actions)
        XCTAssertFalse(action.input.queryControlIDs.isEmpty)
        XCTAssertTrue(action.input.usesFormRecoveryContext)
        _ = try await owner.openFormQuery(for: action)
        XCTAssertEqual(owner.confirmedFormHistory, [receipt])
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts&city=Seattle"), 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testCurrentRetainSourcesSurviveCompletionAndQueryWithoutAnotherInput() async throws {
        let fixture = try await make(category: true, city: true,
            cityHandler: "if(document.getElementById('query').value==='concerts'){document.getElementById('reference').value='unexpected-city-input';}")
        defer { fixture.close() }
        let input = try await prepareRetainedCity(fixture), owner = try fixture.owner()
        let alias = try XCTUnwrap(input.fieldAliases.first { (try? input.field(for: $0).control.label) == "City" })
        let purposes = try XCTUnwrap(input.retainedFieldSources[alias])
        XCTAssertEqual(purposes.count, 2)
        XCTAssertTrue(purposes.contains { $0.turn == 0 && $0.source == "Find concerts in Seattle. " })
        XCTAssertTrue(purposes.contains { $0.turn == 1 && $0.source == "Seattle." })
        XCTAssertFalse(input.editableFieldAliases.contains(alias))
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.contextJSON.utf8)) as? [String: Any])
        XCTAssertEqual(context["version"] as? Int, 15)
        XCTAssertEqual((context["retained_criteria"] as? [[String: Any]])?.count, 1)
        let planner = try ComputerUseLocalBrowserFormPlanner(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")),
            bearerToken: "fixture", modelAlias: "fixture-model"), transport: ControlStateUnusedTransport())
        let request = try planner.makeRequest(input)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let response = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual((response["json_schema"] as? [String: Any])?["name"] as? String, "browser_form_plan_v15")
        let proposal = try ComputerUseBrowserFormProposal.decode(content: mixedContent(input, order: ["Query","Category"]), input: input)
        let city = try input.field(for: alias).editable.snapshot
        XCTAssertEqual(try proposal.textContract(for: input)?.unchangedValues[city.targetID], "Seattle")
        _ = try await owner.executeForm(proposal, input: input)
        configureRetainedCity(fixture, querying: true)
        let action = try await owner.planNextAction(using: fixture.actions)
        let actionContext = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(action.input.contextJSON.utf8)) as? [String: Any])
        let stage = try XCTUnwrap(actionContext["verified_form_stage"] as? [String: Any])
        let rows = try XCTUnwrap(stage["edits"] as? [[String: Any]])
        let control = try input.field(for: alias).control.id
        let retained = try XCTUnwrap(rows.first { $0["control"] as? String == control })
        let sources = try XCTUnwrap(retained["sources"] as? [[String: Any]])
        XCTAssertEqual(sources.count, 2); XCTAssertTrue(sources.contains { $0["source"] as? String == "Seattle." })
        _ = try await owner.openFormQuery(for: action)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts&city=Seattle"), 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 3)
    }

    func testRetainPurposesDoNotRewriteEarlierActualInputSourcesOrDuplicateOnLaterReview() async throws {
        let fixture = try await make(category: true, city: true)
        defer { fixture.close() }
        let input = try await prepareRetainedCity(fixture), owner = try fixture.owner()
        let city = try XCTUnwrap(input.evidence.fields.first { $0.control.label == "City" }).editable.snapshot.targetID
        let originalSources = try XCTUnwrap(input.previous?.editedSources[city])
        let originalIDs = try XCTUnwrap(input.previous?.inputOperationIDs)
        _ = try await owner.executeForm(.decode(content: mixedContent(input, order: ["Query","Category"]), input: input), input: input)
        configureMixed(fixture, editing: ["Query"], retaining: ["Category","City"])
        let action = try await owner.planNextAction(using: fixture.actions)
        let next = try await owner.prepareFormInput(for: action)
        XCTAssertEqual(next.previous?.editedSources[city], originalSources)
        XCTAssertEqual(next.previous?.verifiedSources[city]?.count, 2)
        XCTAssertEqual(Array(next.previous?.inputOperationIDs.prefix(originalIDs.count) ?? []), originalIDs)
        XCTAssertEqual(next.previous?.inputOperationIDs.count, 3)
        let alias = try XCTUnwrap(next.fieldAliases.first { (try? next.field(for: $0).control.label) == "City" })
        XCTAssertEqual(next.retainedFieldSources[alias], next.previous?.verifiedSources[city])
        XCTAssertEqual(next.retainedFieldSources[alias]?.count, 2)
    }

    func testRetainSourcesSurvivePartialInputRecoveryAlongsidePendingEdits() async throws {
        let fixture = try await make(category: true, city: true)
        defer { fixture.close() }
        let input = try await prepareRetainedCity(fixture), owner = try fixture.owner()
        let proposal = try ComputerUseBrowserFormProposal.decode(content: mixedContent(input, order: ["Query","Category"]), input: input)
        let pauseAt = fixture.state.writes + 2
        fixture.state.onWrite = { if fixture.state.writes == pauseAt { owner.pause() } }
        await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
        fixture.state.onWrite = nil
        try await owner.resumeAfterUserControl()
        let result = try await owner.retainPendingFormPrefix(), receipt = try XCTUnwrap(result)
        XCTAssertEqual(receipt.editCount, 1); XCTAssertFalse(receipt.isCompleteStage)
        configureRetainedCity(fixture, editing: ["Category"], alsoRetaining: ["Query"])
        let action = try await owner.planNextAction(using: fixture.actions)
        let next = try await owner.prepareFormInput(for: action)
        let city = try XCTUnwrap(next.evidence.fields.first { $0.control.label == "City" }).editable.snapshot.targetID
        XCTAssertEqual(next.previous?.verifiedSources[city]?.count, 2)
        XCTAssertTrue(next.previous?.verifiedSources[city]?.contains { $0.turn == 1 && $0.source == "Seattle." } == true)
        XCTAssertEqual(next.previous?.pendingEdits.map(\.label), ["Category"])
        XCTAssertEqual(next.previous?.inputOperationIDs.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testAnObservedRetainedCriterionKeepsItsNativeOriginWithoutBecomingAnInput() async throws {
        let fixture = try await make(category: true, queryAlreadyMatches: true)
        defer { fixture.close() }
        let (_, action) = try await prepareLaterAction(fixture), owner = try fixture.owner()
        let input = try await owner.prepareFormInput(for: action)
        let query = try XCTUnwrap(input.evidence.fields.first { $0.control.label == "Query" }).editable.snapshot.targetID
        let proof = try XCTUnwrap(input.previous?.stateProofsByTarget[query])
        XCTAssertEqual(input.retainedFieldSources.count, 1)
        XCTAssertEqual(input.retainedFieldSources.values.first?.count, 1)
        XCTAssertEqual(input.previous?.editedTargetIDs.count, 0)
        _ = try await owner.executeForm(.decode(content: categoryPlan(input), input: input), input: input)
        configure(fixture, category: true, revising: true, querying: true)
        let queryAction = try await owner.planNextAction(using: fixture.actions)
        _ = try await owner.openFormQuery(for: queryAction)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts"), 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, 1)
        XCTAssertEqual(proof.verifiedValues[query], "concerts")
    }

    func testChangedRetainedCriterionCannotPublishItsCurrentRetainPurposes() async throws {
        let fixture = try await make(category: true, city: true,
            mutation: "document.getElementById('city').value='Portland';")
        defer { fixture.close() }
        let input = try await prepareRetainedCity(fixture), owner = try fixture.owner(), history = owner.confirmedFormHistory
        try await release(fixture)
        await expectFailure {
            _ = try await owner.executeForm(.decode(content: self.mixedContent(input, order: ["Query","Category"]), input: input), input: input)
        }
        XCTAssertEqual(owner.confirmedFormHistory, history)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .prepareFormQuery }.count, 0)
    }

    func testCapturedInvariantCannotBeOfferedOrDecodedAsAVerifiedRetainCriterion() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (original, _) = try await prepare(fixture, category: true), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: original); configurePreparedRevision(fixture)
        let reviewed = try await owner.reviewFormPreparation(using: fixture.actions)
        let revised = try await owner.applyFormPreparationReview(reviewed)
        _ = try await owner.executeForm(.decode(content: categoryPlan(revised), input: revised), input: revised)
        configure(fixture, category: true)
        let fallback = fixture.actions.select
        var checked = false
        fixture.actions.select = { input in
            let query = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Query" }?.id)
            XCTAssertFalse(input.effectAdditionalRetainedControlIDs.contains(query))
            if input.effectAdditionalEditControlIDs.contains(query) {
                checked = true
                let content = try ResearchAnswerFixture.json(["plan_fields":[["control":query,"disposition":"retain","requirements":[0]]]])
                XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: content, input: input))
            }
            if let response = try FormEffectScopeFixture.response(input, editing: ["Query":[0]], retaining: ["Category":[0]],
                preserving: ["Reference":0]) { return response }
            return try XCTUnwrap(fallback)(input)
        }
        let action = try await owner.planNextAction(using: fixture.actions)
        let next = try await owner.prepareFormInput(for: action)
        XCTAssertTrue(checked)
        let query = try XCTUnwrap(next.evidence.fields.first { $0.control.label == "Query" }).editable.snapshot.targetID
        XCTAssertNotNil(next.previous?.finalValues[query])
        XCTAssertFalse(next.previous?.verifiedTargetIDs.contains(query) ?? true)
        XCTAssertEqual(next.retainedFieldSources.count, 1)
        XCTAssertEqual(try next.retainedFieldSources.keys.map { try next.field(for: $0).control.label }, ["Category"])
    }

    func testRetainOnlyProposalHasNoEditSchemaOrTextContract() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let input = try await prepareRetainOnly(fixture)
        XCTAssertTrue(input.isRetainOnly); XCTAssertTrue(input.editableFieldAliases.isEmpty)
        let proposal = try ComputerUseBrowserFormProposal.decode(content: #"{"retain":true}"#, input: input)
        XCTAssertTrue(proposal.isRetention); XCTAssertFalse(proposal.isUnavailable)
        XCTAssertTrue(proposal.edits.isEmpty); XCTAssertNil(try proposal.textContract(for: input))
        for content in [#"{"retain":false}"#, #"{"retain":true,"edits":[]}"#, #"{"edits":[],"preserve":[]}"#,
                        #"{"retain":true,"preserve":[]}"#, #"{"retain":true,"resume":[]}"#] {
            XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: content, input: input))
        }
        let planner = try ComputerUseLocalBrowserFormPlanner(connection: .init(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:54321")),
            bearerToken: "fixture-token-value", modelAlias: "fixture-model"), transport: ControlStateUnusedTransport())
        let request = try planner.makeRequest(input)
        if let path = ProcessInfo.processInfo.environment["REPAIR_PLANNER_REQUEST_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(request.httpBody).write(to: directory.appendingPathComponent("form-retain-0.json"), options: .atomic)
        }
        let body = try ResearchAnswerFixture.object(XCTUnwrap(request.httpBody))
        let response = try XCTUnwrap(body["response_format"] as? [String: Any])
        let schema = try XCTUnwrap(response["json_schema"] as? [String: Any])
        XCTAssertEqual(schema["name"] as? String, "browser_form_plan_v16")
        let definitions = try XCTUnwrap(schema["schema"] as? [String: Any])
        let alternatives = try XCTUnwrap(definitions["oneOf"] as? [[String: Any]])
        XCTAssertEqual((alternatives.first?["required"] as? [String]), ["retain"])
        let context = try ResearchAnswerFixture.object(Data(input.contextJSON.utf8))
        XCTAssertEqual(context["version"] as? Int, 16); XCTAssertEqual(context["retain_only"] as? Bool, true)
    }

    func testRetainOnlyCompletionAndQueryKeepActualAndObservedOriginsDistinct() async throws {
        for observed in [false, true] {
            let fixture = try await make(category: true, queryAlreadyMatches: observed, categoryAlreadyMatches: observed)
            defer { fixture.close() }
            let input = try await prepareRetainOnly(fixture), owner = try fixture.owner(), writes = fixture.state.writes
            let proposal = try ComputerUseBrowserFormProposal.decode(content: #"{"retain":true}"#, input: input)
            let receipt = try await owner.executeForm(proposal, input: input)
            XCTAssertEqual(receipt.editCount, 0); XCTAssertEqual(receipt.plannedEditCount, 0)
            XCTAssertEqual(receipt.verifiedWithoutInputCount, 0); XCTAssertEqual(receipt.retainedCriterionCount, 2)
            XCTAssertTrue(receipt.isCompleteStage); XCTAssertEqual(fixture.state.writes, writes)
            let repeated = try await owner.executeForm(proposal, input: input)
            XCTAssertEqual(repeated, receipt); XCTAssertEqual(owner.confirmedFormHistory.count, 2)
            configureMixed(fixture, editing: [], retaining: ["Query","Category"], querying: true)
            let action = try await owner.planNextAction(using: fixture.actions)
            let context = try ResearchAnswerFixture.object(Data(action.input.contextJSON.utf8))
            XCTAssertEqual(context["version"] as? Int, 22)
            let stage = try XCTUnwrap(context["verified_form_stage"] as? [String: Any])
            XCTAssertEqual(stage["retained_criteria"] as? Int, 2)
            let criteria = try XCTUnwrap(stage["criteria"] as? [[String: Any]])
            XCTAssertEqual(criteria.count, 2)
            XCTAssertTrue(criteria.allSatisfy { $0["verified_without_input"] as? Bool == observed })
            _ = try await owner.openFormQuery(for: action)
            XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts"), 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, observed ? 0 : 2)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, observed ? 1 : 0)
        }
    }

    func testRetainOnlyCarriesANewAnswerWithoutRewritingEarlierInputs() async throws {
        let fixture = try await make(category: true, city: true)
        defer { fixture.close() }
        let input = try await prepareAnsweredRetention(fixture), owner = try fixture.owner()
        XCTAssertTrue(input.isRetainOnly)
        let old = try XCTUnwrap(input.previous)
        _ = try await owner.executeForm(.decode(content: #"{"retain":true}"#, input: input), input: input)
        configureRetainedCity(fixture, editing: ["Query"], alsoRetaining: ["Category"], cityRequirement: 4)
        let later = try await owner.planNextAction(using: fixture.actions), next = try await owner.prepareFormInput(for: later)
        let previous = try XCTUnwrap(next.previous)
        let city = try XCTUnwrap(next.evidence.fields.first { $0.control.label == "City" }).editable.snapshot.targetID
        XCTAssertEqual(previous.verifiedSources[city]?.count, 3)
        XCTAssertTrue(previous.verifiedSources[city]?.contains { $0.turn == 2 && $0.source == "Keep Seattle." } == true)
        XCTAssertEqual(previous.editedSources, old.editedSources)
        XCTAssertEqual(previous.inputOperationIDs, old.inputOperationIDs)
        XCTAssertEqual(previous.stateProofsByTarget, old.stateProofsByTarget)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 3)
    }

    func testRetainOnlyPauseRequiresHandbackAndFreshValidationBeforePublication() async throws {
        for boundary in [ComputerUseBrowserDOMCommand.bindPageFields, .inspectFormRequirements] {
            let fixture = try await make(category: true)
            defer { fixture.close() }
            let input = try await prepareRetainOnly(fixture), owner = try fixture.owner(), writes = fixture.state.writes
            let history = owner.confirmedFormHistory
            fixture.state.onCommand = { command in
                guard command == boundary else { return }; fixture.state.onCommand = nil; owner.pause()
            }
            await expectFailure { _ = try await owner.executeForm(.decode(content: #"{"retain":true}"#, input: input), input: input) }
            XCTAssertEqual(owner.confirmedFormHistory, history)
            let commands = fixture.state.commands
            await expectFailure { _ = try await owner.resumeForm() }
            XCTAssertEqual(fixture.state.commands, commands)
            try await owner.resumeAfterUserControl()
            let result = try await owner.resumeForm(), receipt = try XCTUnwrap(result)
            XCTAssertEqual(receipt.retainedCriterionCount, 2); XCTAssertTrue(receipt.isCompleteStage)
            XCTAssertGreaterThan(fixture.state.commands.filter { $0 == boundary }.count, commands.filter { $0 == boundary }.count)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
            XCTAssertEqual(fixture.state.writes, writes)
        }
    }

    func testRetainOnlyCannotPublishChangedValuesPreservationOrReplacementObjects() async throws {
        for mutation in ["document.getElementById('query').value='reset';",
                         "document.getElementById('reference').value='changed';",
                         "document.getElementById('query').outerHTML=document.getElementById('query').outerHTML;"] {
            let fixture = try await make(category: true, mutation: mutation)
            defer { fixture.close() }
            let input = try await prepareRetainOnly(fixture), owner = try fixture.owner(), history = owner.confirmedFormHistory
            try await release(fixture)
            await expectFailure { _ = try await owner.executeForm(.decode(content: #"{"retain":true}"#, input: input), input: input) }
            XCTAssertEqual(owner.confirmedFormHistory, history)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .prepareFormQuery }.count, 0)
            XCTAssertTrue(owner.hasPendingForm)
        }
    }

    func testRetainOnlyCannotRecreateLostNativeInputOrObservationOrigins() async throws {
        for observed in [false, true] {
            let fixture = try await make(category: true, queryAlreadyMatches: observed, categoryAlreadyMatches: observed)
            defer { fixture.close() }
            let input = try await prepareRetainOnly(fixture), owner = try fixture.owner(), history = owner.confirmedFormHistory
            let other = ComputerUseBrowserTextTarget(browser: fixture.browser, document: input.evidence.page.document, requiresFrontmost: false)
            _ = try await other.fields()
            await expectFailure { _ = try await owner.executeForm(.decode(content: #"{"retain":true}"#, input: input), input: input) }
            XCTAssertEqual(owner.confirmedFormHistory, history)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, observed ? 0 : 2)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, observed ? 1 : 0)
        }
    }

    func testAChangedCriterionAfterRetentionCanBeRepairedThroughTheSameHistory() async throws {
        let fixture = try await make(category: true, mutation: "document.getElementById('query').value='reset';")
        defer { fixture.close() }
        let input = try await prepareRetainOnly(fixture), owner = try fixture.owner()
        _ = try await owner.executeForm(.decode(content: #"{"retain":true}"#, input: input), input: input)
        try await release(fixture)
        configureMixed(fixture, editing: ["Query"], retaining: ["Category"])
        let action = try await owner.planNextAction(using: fixture.actions), next = try await owner.prepareFormInput(for: action)
        XCTAssertEqual(next.requiredRepairFieldAliases.count, 1)
        XCTAssertEqual(next.previous?.inputOperationIDs, input.previous?.inputOperationIDs)
        _ = try await owner.executeForm(.decode(content: mixedContent(next, order: ["Query"]), input: next), input: next)
        configureMixed(fixture, editing: [], retaining: ["Query","Category"], querying: true)
        let query = try await owner.planNextAction(using: fixture.actions)
        _ = try await owner.openFormQuery(for: query)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [2,0,1])
        XCTAssertEqual(owner.confirmedFormHistory.map(\.retainedCriterionCount), [0,2,0])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 3)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts"), 1)
    }

    func testRetainOnlyCannotDiscardAPendingInputSuffix() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (input, proposal) = try await prepareMixed(fixture, order: ["Query","Category"]), owner = try fixture.owner()
        XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: #"{"retain":true}"#, input: input))
        let pauseAt = fixture.state.writes + 2
        fixture.state.onWrite = { if fixture.state.writes == pauseAt { owner.pause() } }
        await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
        fixture.state.onWrite = nil
        try await owner.resumeAfterUserControl()
        let prefix = try await owner.retainPendingFormPrefix()
        XCTAssertEqual(prefix?.editCount, 1)
        configureMixed(fixture, editing: [], retaining: ["Query"])
        let action = try await owner.planNextAction(using: fixture.actions)
        XCTAssertEqual(action.step, .unavailable); XCTAssertFalse(action.input.effectScopeAllowsActions)
        XCTAssertTrue(action.input.queryControlIDs.isEmpty)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testDriverExecutesRetainOnlyBeforeContinuingToTheVerifiedQuery() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        _ = try await prepareRetainOnly(fixture)
        let owner = try fixture.owner()
        configureMixed(fixture, editing: [], retaining: ["Query","Category"], querying: true)
        let formDecision = try XCTUnwrap(fixture.actions.select)
        var resultReadings = 0
        fixture.actions.select = { input in
            // The query leaves the form. The result page needs a reading,
            // not another attempt to select its now-absent Query field.
            if input.formIDs.isEmpty && input.queryReceipt == nil {
                XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts"), 1)
                resultReadings += 1
                return #"{"read_results":true}"#
            }
            return try formDecision(input)
        }
        fixture.forms.select = { input in
            XCTAssertTrue(input.isRetainOnly)
            return #"{"retain":true}"#
        }
        guard case .browserResearchProgress = try await fixture.resume() else {
            return XCTFail("A retained query must continue to result assessment, not complete the task")
        }
        XCTAssertEqual(resultReadings, 1)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.retainedCriterionCount), [0,2])
        XCTAssertEqual(fixture.forms.inputs.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts"), 1)
    }

    func testPendingRetentionRecoversOnlyIncompleteOriginalCriteriaForRepair() async throws {
        for observed in [false, true] {
            let fixture = try await make(category: true, queryAlreadyMatches: observed, categoryAlreadyMatches: observed,
                mutation: "document.getElementById('query').value='reset';")
            defer { fixture.close() }
            let input = try await prepareRetainOnly(fixture), owner = try fixture.owner(), writes = fixture.state.writes
            let previous = try XCTUnwrap(input.previous)
            try await release(fixture)
            let proposal = try ComputerUseBrowserFormProposal.decode(content: #"{"retain":true}"#, input: input)
            await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
            let result = try await owner.recoverPendingRetainedCriteria(), receipt = try XCTUnwrap(result)
            XCTAssertFalse(receipt.isCompleteStage); XCTAssertTrue(receipt.requiresRepairAtPublication)
            XCTAssertEqual(receipt.editCount, 0); XCTAssertEqual(receipt.plannedEditCount, 0)
            XCTAssertEqual(receipt.verifiedWithoutInputCount, 0); XCTAssertEqual(receipt.retainedCriterionCount, 2)
            let repeated = try await owner.executeForm(proposal, input: input)
            XCTAssertEqual(repeated, receipt); XCTAssertEqual(owner.confirmedFormHistory.count, 2)
            configureMixed(fixture, editing: ["Query"], retaining: ["Category"])
            let action = try await owner.planNextAction(using: fixture.actions)
            XCTAssertTrue(action.input.queryControlIDs.isEmpty)
            let context = try ResearchAnswerFixture.object(Data(action.input.contextJSON.utf8))
            let stage = try XCTUnwrap(context["verified_form_stage"] as? [String: Any])
            XCTAssertEqual(context["version"] as? Int, 22)
            XCTAssertEqual(stage["complete_stage"] as? Bool, false)
            XCTAssertEqual(stage["required_repair_when_recorded"] as? Bool, true)
            let next = try await owner.prepareFormInput(for: action)
            XCTAssertEqual(next.requiredRepairFieldAliases.count, 1)
            XCTAssertEqual(next.previous?.inputOperationIDs, previous.inputOperationIDs)
            XCTAssertEqual(next.previous?.editedSources, previous.editedSources)
            XCTAssertEqual(next.previous?.stateProofsByTarget, previous.stateProofsByTarget)
            let query = try XCTUnwrap(next.evidence.fields.first { $0.control.label == "Query" }).editable.snapshot
            XCTAssertEqual(query.value, "reset"); XCTAssertEqual(next.previous?.finalValues[query.targetID], "concerts")
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, observed ? 0 : 2)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, observed ? 1 : 0)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .retireUnsentInputs }.count, 0)
            XCTAssertEqual(fixture.state.writes, writes)
        }
    }

    func testDriverRepairsAPendingRetainReviewWithoutRepeatingOtherInputs() async throws {
        let fixture = try await make(category: true, mutation: "document.getElementById('query').value='reset';")
        defer { fixture.close() }
        let input = try await prepareRetainOnly(fixture), owner = try fixture.owner()
        try await release(fixture)
        await expectFailure { _ = try await owner.executeForm(.decode(content: #"{"retain":true}"#, input: input), input: input) }
        configureMixed(fixture, editing: ["Query"], retaining: ["Category"], querying: true)
        fixture.forms.select = { input in try self.mixedContent(input, order: ["Query"]) }
        _ = try await fixture.resume()
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [2,0,1])
        XCTAssertEqual(owner.confirmedFormHistory.map(\.retainedCriterionCount), [0,2,0])
        XCTAssertEqual(owner.confirmedFormHistory.map(\.requiresRepairAtPublication), [false,true,false])
        XCTAssertEqual(fixture.forms.inputs.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 3)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .retireUnsentInputs }.count, 0)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts"), 1)
    }

    func testPendingRetentionRecoveryKeepsNewAnswerSourcesAndOriginalInputHistory() async throws {
        let fixture = try await make(category: true, city: true, mutation: "document.getElementById('city').value='Portland';")
        defer { fixture.close() }
        let input = try await prepareAnsweredRetention(fixture), owner = try fixture.owner(), previous = try XCTUnwrap(input.previous)
        try await release(fixture)
        await expectFailure { _ = try await owner.executeForm(.decode(content: #"{"retain":true}"#, input: input), input: input) }
        let result = try await owner.recoverPendingRetainedCriteria(), receipt = try XCTUnwrap(result)
        XCTAssertTrue(receipt.requiresRepairAtPublication); XCTAssertFalse(receipt.isCompleteStage)
        configureMixed(fixture, editing: ["City"], retaining: ["Query","Category"])
        let action = try await owner.planNextAction(using: fixture.actions), next = try await owner.prepareFormInput(for: action)
        let city = try XCTUnwrap(next.evidence.fields.first { $0.control.label == "City" }).editable.snapshot.targetID
        XCTAssertEqual(next.previous?.verifiedSources[city]?.count, 3)
        XCTAssertTrue(next.previous?.verifiedSources[city]?.contains { $0.turn == 2 && $0.source == "Keep Seattle." } == true)
        XCTAssertEqual(next.previous?.finalValues[city], "Seattle")
        XCTAssertEqual(next.previous?.editedSources, previous.editedSources)
        XCTAssertEqual(next.previous?.inputOperationIDs, previous.inputOperationIDs)
        XCTAssertEqual(next.previous?.stateProofsByTarget, previous.stateProofsByTarget)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 3)
    }

    func testPendingRetentionRecoveryNeedsHandbackAfterNativeInspection() async throws {
        for boundary in [ComputerUseBrowserDOMCommand.pageSnapshot, .inspectFormRequirements] {
            let fixture = try await make(category: true, mutation: "document.getElementById('query').value='reset';")
            defer { fixture.close() }
            let input = try await prepareRetainOnly(fixture), owner = try fixture.owner(), history = owner.confirmedFormHistory
            try await release(fixture)
            await expectFailure { _ = try await owner.executeForm(.decode(content: #"{"retain":true}"#, input: input), input: input) }
            fixture.state.onCommand = { command in
                guard command == boundary else { return }; fixture.state.onCommand = nil; owner.pause()
            }
            await expectFailure { _ = try await owner.recoverPendingRetainedCriteria() }
            XCTAssertEqual(owner.confirmedFormHistory, history)
            let commands = fixture.state.commands
            await expectFailure { _ = try await owner.recoverPendingRetainedCriteria() }
            XCTAssertEqual(fixture.state.commands, commands)
            try await owner.resumeAfterUserControl()
            let result = try await owner.recoverPendingRetainedCriteria(), receipt = try XCTUnwrap(result)
            XCTAssertFalse(receipt.isCompleteStage); XCTAssertTrue(receipt.requiresRepairAtPublication)
            XCTAssertGreaterThan(fixture.state.commands.filter { $0 == boundary }.count, commands.filter { $0 == boundary }.count)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        }
    }

    func testPendingRetentionRecoveryRejectsChangedPreservationAndReplacedObjects() async throws {
        for readonly in [false, true] {
            for mutation in ["document.getElementById('query').value='reset';document.getElementById('reference').value='changed';",
                             "document.getElementById('query').outerHTML=document.getElementById('query').outerHTML;"] {
                let fixture = try await make(category: true, referenceReadOnly: readonly, mutation: mutation)
                defer { fixture.close() }
                let input = try await prepareRetainOnly(fixture), owner = try fixture.owner(), history = owner.confirmedFormHistory
                try await release(fixture)
                await expectFailure { _ = try await owner.executeForm(.decode(content: #"{"retain":true}"#, input: input), input: input) }
                await expectFailure { _ = try await owner.recoverPendingRetainedCriteria() }
                XCTAssertEqual(owner.confirmedFormHistory, history)
                XCTAssertTrue(owner.hasPendingForm)
                XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
                XCTAssertEqual(fixture.state.commands.filter { $0 == .prepareFormQuery }.count, 0)
            }
        }
    }

    func testPendingRetentionRecoveryCannotReconstructLostNativeOrigins() async throws {
        for observed in [false, true] {
            let fixture = try await make(category: true, queryAlreadyMatches: observed, categoryAlreadyMatches: observed,
                mutation: "document.getElementById('query').value='reset';")
            defer { fixture.close() }
            let input = try await prepareRetainOnly(fixture), owner = try fixture.owner(), history = owner.confirmedFormHistory
            try await release(fixture)
            await expectFailure { _ = try await owner.executeForm(.decode(content: #"{"retain":true}"#, input: input), input: input) }
            let other = ComputerUseBrowserTextTarget(browser: fixture.browser, document: input.evidence.page.document, requiresFrontmost: false)
            _ = try await other.fields()
            await expectFailure { _ = try await owner.recoverPendingRetainedCriteria() }
            XCTAssertEqual(owner.confirmedFormHistory, history)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, observed ? 0 : 2)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, observed ? 1 : 0)
        }
    }

    func testRetentionRecoveryCannotConsumeAPendingPhysicalInputStage() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (input, proposal) = try await prepareMixed(fixture, order: ["Query","Category"]), owner = try fixture.owner()
        let pauseAt = fixture.state.writes + 1
        fixture.state.onWrite = { if fixture.state.writes == pauseAt { owner.pause() } }
        await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
        fixture.state.onWrite = nil
        try await owner.resumeAfterUserControl()
        let (store, journal) = try pendingMixedJournal(fixture), commands = fixture.state.commands, writes = fixture.state.writes
        let result = try await owner.recoverPendingRetainedCriteria()
        XCTAssertNil(result); XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
        XCTAssertEqual(fixture.state.commands, commands); XCTAssertEqual(fixture.state.writes, writes)
        XCTAssertEqual(try store.load(taskID: journal.taskID), journal)
        XCTAssertTrue(owner.hasPendingForm)
    }

    func testUnchangedPendingRetentionRequiresNormalValidationInsteadOfRepairRecovery() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let input = try await prepareRetainOnly(fixture), owner = try fixture.owner(), history = owner.confirmedFormHistory
        fixture.state.onCommand = { command in
            guard command == .bindPageFields else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.executeForm(.decode(content: #"{"retain":true}"#, input: input), input: input) }
        try await owner.resumeAfterUserControl()
        let result = try await owner.recoverPendingRetainedCriteria()
        XCTAssertNil(result); XCTAssertEqual(owner.confirmedFormHistory, history)
        let resumed = try await owner.resumeForm(), receipt = try XCTUnwrap(resumed)
        XCTAssertTrue(receipt.isCompleteStage); XCTAssertFalse(receipt.requiresRepairAtPublication)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testRestoredCriteriaAfterRetentionRecoveryPermitAFreshQueryWithoutInput() async throws {
        let fixture = try await make(category: true,
            mutation: "document.getElementById('query').value='movies';fetch('/signal').then(()=>{document.getElementById('query').value='concerts';fetch('/restored');});")
        defer { fixture.close() }
        let input = try await prepareRetainOnly(fixture), owner = try fixture.owner()
        try await release(fixture)
        await expectFailure { _ = try await owner.executeForm(.decode(content: #"{"retain":true}"#, input: input), input: input) }
        let result = try await owner.recoverPendingRetainedCriteria(), receipt = try XCTUnwrap(result)
        XCTAssertTrue(receipt.requiresRepairAtPublication); XCTAssertFalse(receipt.isCompleteStage)
        let deadline = ContinuousClock.now + .seconds(5)
        while fixture.server.count("/signal") != 2 {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
        fixture.server.releaseHeldResponses()
        while fixture.server.count("/restored") != 1 {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
        configureMixed(fixture, editing: [], retaining: ["Query","Category"], querying: true)
        let action = try await owner.planNextAction(using: fixture.actions)
        XCTAssertFalse(action.input.queryControlIDs.isEmpty)
        XCTAssertTrue(action.input.usesFormRecoveryContext); XCTAssertTrue(action.input.usesFormRetentionContext)
        _ = try await owner.openFormQuery(for: action)
        XCTAssertEqual(owner.confirmedFormHistory.last, receipt)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts"), 1)
    }

    func testCaretOnlyChangesDoNotReplaceRetainedFieldsOrDispatchInput() async throws {
        for observed in [false, true] {
            let fixture = try await make(category: true, queryAlreadyMatches: observed, categoryAlreadyMatches: observed,
                mutation: "const q=document.getElementById('query');const p=q.selectionStart===0?1:0;q.setSelectionRange(p,p);")
            defer { fixture.close() }
            let input = try await prepareRetainOnly(fixture), owner = try fixture.owner()
            try await release(fixture)
            let resumed = try await owner.resumeFormPreparation()
            XCTAssertEqual(resumed, input)
            fixture.forms.content = #"{"retain":true}"#
            let proposal = try await owner.planForm(resumed, using: fixture.forms)
            let receipt = try await owner.executeForm(proposal, input: resumed)
            XCTAssertEqual(receipt.retainedCriterionCount, 2); XCTAssertTrue(receipt.isCompleteStage)
            configureMixed(fixture, editing: [], retaining: ["Query","Category"], querying: true)
            let action = try await owner.planNextAction(using: fixture.actions)
            _ = try await owner.openFormQuery(for: action)
            XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts"), 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, observed ? 0 : 2)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, observed ? 1 : 0)
        }
    }

    func testCaretMovementWhileRetentionPlannerWaitsDoesNotInvalidateItsProposal() async throws {
        let fixture = try await make(category: true,
            mutation: "document.getElementById('query').setSelectionRange(0,0);")
        defer { fixture.close() }
        let input = try await prepareRetainOnly(fixture), owner = try fixture.owner()
        fixture.forms.content = #"{"retain":true}"#
        fixture.forms.beforeReply = { try await self.release(fixture) }
        let proposal = try await owner.planForm(input, using: fixture.forms)
        fixture.forms.beforeReply = nil
        let receipt = try await owner.executeForm(proposal, input: input)
        XCTAssertTrue(receipt.isCompleteStage); XCTAssertEqual(receipt.retainedCriterionCount, 2)
        XCTAssertEqual(fixture.forms.inputs, [input])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testRetainedCaptureBeforeBindingSurvivesHandbackAndCaretMovement() async throws {
        let fixture = try await make(category: true,
            mutation: "document.getElementById('query').setSelectionRange(0,0);")
        defer { fixture.close() }
        let (first, proposal) = try await prepareMixed(fixture, order: ["Query","Category"]), owner = try fixture.owner()
        _ = try await owner.executeForm(proposal, input: first)
        configureMixed(fixture, editing: [], retaining: ["Query","Category"])
        let action = try await owner.planNextAction(using: fixture.actions)
        let extensions = fixture.state.commands.filter { $0 == .extendFormFields }.count
        fixture.state.onCommand = { command in
            guard command == .extendFormFields else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.prepareFormInput(for: action) }
        try await release(fixture)
        try await owner.resumeAfterUserControl()
        let input = try await owner.resumeFormPreparation()
        XCTAssertTrue(input.isRetainOnly)
        let receipt = try await owner.executeForm(.decode(content: #"{"retain":true}"#, input: input), input: input)
        XCTAssertTrue(receipt.isCompleteStage)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .extendFormFields }.count, extensions + 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testRevisedRetainPreparationCapturesFreshCaretBeforeAddingAnotherInput() async throws {
        let fixture = try await make(category: true, city: true,
            mutation: "document.getElementById('query').setSelectionRange(0,0);")
        defer { fixture.close() }
        let input = try await prepareRetainOnly(fixture, deferring: ["City"]), owner = try fixture.owner()
        let oldQuery = try XCTUnwrap(input.evidence.fields.first { $0.control.label == "Query" }).editable.snapshot
        XCTAssertGreaterThan(oldQuery.selection.location, 0)
        try await release(fixture)
        let next = try await reviseRetainPreparation(fixture, input: input, editing: ["City"], retaining: ["Query","Category"])
        let query = try XCTUnwrap(next.evidence.fields.first { $0.control.label == "Query" }).editable.snapshot
        XCTAssertEqual(query.targetID, oldQuery.targetID); XCTAssertEqual(query.value, oldQuery.value)
        XCTAssertEqual(query.selection.location, 0); XCTAssertNotEqual(query.selection, oldQuery.selection)
        XCTAssertNotNil(next.preparationBaseline); XCTAssertFalse(next.isRetainOnly)
        XCTAssertEqual(next.previous?.inputOperationIDs, input.previous?.inputOperationIDs)
        let proposal = try ComputerUseBrowserFormProposal.decode(content: mixedContent(next, order: ["City"]), input: next)
        let contract = try XCTUnwrap(try proposal.textContract(for: next))
        XCTAssertEqual(contract.unchangedValues[query.targetID], "concerts")
        let receipt = try await owner.executeForm(proposal, input: next)
        XCTAssertEqual(receipt.editCount, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 3)
        XCTAssertEqual(owner.confirmedFormHistory.count, 2) // Unexecuted retention does not become a stage.
    }

    func testARevisedInputStillRequiresItsFreshCaretPrecondition() async throws {
        let fixture = try await make(category: true,
            mutation: "document.getElementById('query').setSelectionRange(0,0);fetch('/signal').then(()=>{document.getElementById('query').setSelectionRange(1,1);fetch('/restored');});")
        defer { fixture.close() }
        let input = try await prepareRetainOnly(fixture), owner = try fixture.owner()
        try await release(fixture)
        let next = try await reviseRetainPreparation(fixture, input: input, editing: ["Query"], retaining: ["Category"])
        XCTAssertFalse(next.isRetainOnly)
        let query = try XCTUnwrap(next.evidence.fields.first { $0.control.label == "Query" }).editable.snapshot
        XCTAssertEqual(query.selection.location, 0)
        let proposal = try ComputerUseBrowserFormProposal.decode(content: mixedContent(next, order: ["Query"]), input: next)
        try await releaseSecondSignal(fixture)
        await expectFailure { _ = try await owner.executeForm(proposal, input: next) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(owner.confirmedFormHistory.count, 1)
    }

    func testCaretExceptionDoesNotApplyToMixedEditAndRetainPreparation() async throws {
        let fixture = try await make(category: true,
            mutation: "document.getElementById('query').setSelectionRange(0,0);")
        defer { fixture.close() }
        let (_, action) = try await prepareLaterAction(fixture), owner = try fixture.owner()
        let input = try await owner.prepareFormInput(for: action)
        XCTAssertFalse(input.isRetainOnly)
        try await release(fixture)
        fixture.forms.select = { try self.categoryPlan($0) }
        await expectFailure { _ = try await owner.planForm(input, using: fixture.forms) }
        XCTAssertTrue(fixture.forms.inputs.isEmpty)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testCaretExceptionDoesNotPermitValueOrOptionMetadataChanges() async throws {
        for mutation in ["document.getElementById('query').setSelectionRange(0,0);document.getElementById('reference').value='changed';",
                         "document.getElementById('query').setSelectionRange(0,0);document.querySelector('select option').textContent='Changed option';"] {
            let fixture = try await make(category: true, mutation: mutation)
            defer { fixture.close() }
            let input = try await prepareRetainOnly(fixture), owner = try fixture.owner(), history = owner.confirmedFormHistory
            try await release(fixture)
            await expectFailure { _ = try await owner.resumeFormPreparation() }
            await expectFailure { _ = try await owner.executeForm(.decode(content: #"{"retain":true}"#, input: input), input: input) }
            XCTAssertEqual(owner.confirmedFormHistory, history)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        }
    }

    func testRetainedBindingStopsBeforeAnotherNativeReadWhenPaused() async throws {
        let fixture = try await make(category: true,
            mutation: "document.getElementById('query').setSelectionRange(0,0);")
        defer { fixture.close() }
        let input = try await prepareRetainOnly(fixture), owner = try fixture.owner()
        try await release(fixture)
        fixture.state.onCommand = { command in
            guard command == .bindPageFields else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.executeForm(.decode(content: #"{"retain":true}"#, input: input), input: input) }
        XCTAssertEqual(fixture.state.commands.last, .bindPageFields)
        let commands = fixture.state.commands
        await expectFailure { _ = try await owner.resumeForm() }
        XCTAssertEqual(fixture.state.commands, commands)
        try await owner.resumeAfterUserControl()
        let resumed = try await owner.resumeForm(), receipt = try XCTUnwrap(resumed)
        XCTAssertTrue(receipt.isCompleteStage)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testRevisingRetentionCannotAdoptChangedValuesAlongsideANewCaret() async throws {
        let fixture = try await make(category: true,
            mutation: "document.getElementById('query').value='movies';document.getElementById('query').setSelectionRange(0,0);")
        defer { fixture.close() }
        let input = try await prepareRetainOnly(fixture), owner = try fixture.owner(), history = owner.confirmedFormHistory
        try await release(fixture)
        await expectFailure { _ = try await self.reviseRetainPreparation(fixture, input: input, editing: ["Query"], retaining: ["Category"]) }
        XCTAssertEqual(owner.confirmedFormHistory, history)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 0)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertTrue(owner.hasPendingFormPreparation)
    }

    func testUnexecutedRetentionRecoveryKeepsItsCaptureWithoutPublishingAStage() async throws {
        for observed in [false, true] {
            let fixture = try await make(category: true, queryAlreadyMatches: observed, categoryAlreadyMatches: observed,
                mutation: "document.getElementById('query').value='reset';")
            defer { fixture.close() }
            let original = try await prepareRetainOnly(fixture), owner = try fixture.owner()
            let history = owner.confirmedFormHistory, writes = fixture.state.writes
            let previous = try XCTUnwrap(original.previous)
            try await release(fixture)
            await expectFailure { _ = try await owner.resumeFormPreparation() }
            let recovered = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(recovered); XCTAssertTrue(owner.needsFormPreparationReview)
            XCTAssertFalse(owner.hasRevisedFormPreparationGoal)
            XCTAssertEqual(owner.confirmedFormHistory, history); XCTAssertEqual(fixture.state.writes, writes)
            let repeated = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertFalse(repeated) // No automatic loop on the same observation.
            let next = try await repairRetainPreparation(fixture, editing: ["Query"], retaining: ["Category"])
            XCTAssertEqual(next.previous, previous); XCTAssertNotNil(next.preparationBaseline)
            let oldQuery = try XCTUnwrap(original.evidence.fields.first { $0.control.label == "Query" }).editable.snapshot
            let query = try XCTUnwrap(next.evidence.fields.first { $0.control.label == "Query" }).editable.snapshot
            XCTAssertEqual(query.targetID, oldQuery.targetID); XCTAssertEqual(oldQuery.value, "concerts")
            XCTAssertEqual(query.value, "reset"); XCTAssertEqual(next.previous?.finalValues[query.targetID], "concerts")
            XCTAssertEqual(next.requiredRepairFieldAliases.count, 1)
            XCTAssertEqual(owner.confirmedFormHistory, history)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, observed ? 0 : 2)
            _ = try await owner.executeForm(.decode(content: mixedContent(next, order: ["Query"]), input: next), input: next)
            XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [observed ? 0 : 2,1])
            XCTAssertEqual(owner.confirmedFormHistory.map(\.retainedCriterionCount), [0,0])
            XCTAssertEqual(fixture.state.commands.filter { $0 == .retireUnsentInputs }.count, 0)
            configureMixed(fixture, editing: [], retaining: ["Query","Category"], querying: true)
            let action = try await owner.planNextAction(using: fixture.actions)
            _ = try await owner.openFormQuery(for: action)
            XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts"), 1)
        }
    }

    func testDriverRepairsChangedRetentionBeforeItsFormPlannerRuns() async throws {
        let fixture = try await make(category: true, mutation: "document.getElementById('query').value='reset';")
        defer { fixture.close() }
        _ = try await prepareRetainOnly(fixture)
        let owner = try fixture.owner()
        try await release(fixture)
        configureMixed(fixture, editing: ["Query"], retaining: ["Category"], querying: true)
        fixture.forms.select = { input in
            XCTAssertFalse(input.isRetainOnly); XCTAssertEqual(input.requiredRepairFieldAliases.count, 1)
            return try self.mixedContent(input, order: ["Query"])
        }
        _ = try await fixture.resume()
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [2,1])
        XCTAssertEqual(owner.confirmedFormHistory.map(\.retainedCriterionCount), [0,0])
        XCTAssertEqual(fixture.forms.inputs.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 3)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts"), 1)
    }

    func testDriverDiscardsRetentionProposalWhenAValueChangesWhilePlanning() async throws {
        let fixture = try await make(category: true, mutation: "document.getElementById('query').value='reset';")
        defer { fixture.close() }
        let original = try await prepareRetainOnly(fixture), owner = try fixture.owner()
        configureMixed(fixture, editing: ["Query"], retaining: ["Category"], querying: true)
        fixture.forms.beforeReply = {
            guard fixture.forms.inputs.last?.isRetainOnly == true else { return }
            fixture.forms.beforeReply = nil
            try await self.release(fixture)
        }
        fixture.forms.select = { input in
            input.isRetainOnly ? #"{"retain":true}"# : try self.mixedContent(input, order: ["Query"])
        }
        _ = try await fixture.resume()
        XCTAssertEqual(fixture.forms.inputs.count, 2); XCTAssertEqual(fixture.forms.inputs.first, original)
        XCTAssertEqual(fixture.forms.inputs.last?.previous, original.previous)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [2,1])
        XCTAssertEqual(owner.confirmedFormHistory.map(\.retainedCriterionCount), [0,0])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 3)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts"), 1)
    }

    func testPreparationRecoveryRequiresHandbackBeforeItCanRequestAReview() async throws {
        for boundary in [ComputerUseBrowserDOMCommand.pageSnapshot, .inspectFormRequirements] {
            let fixture = try await make(category: true, mutation: "document.getElementById('query').value='reset';")
            defer { fixture.close() }
            _ = try await prepareRetainOnly(fixture)
            let owner = try fixture.owner(), history = owner.confirmedFormHistory
            try await release(fixture)
            fixture.state.onCommand = { command in
                guard command == boundary else { return }; fixture.state.onCommand = nil; owner.pause()
            }
            await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
            XCTAssertFalse(owner.needsFormPreparationReview)
            let commands = fixture.state.commands
            await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
            XCTAssertEqual(fixture.state.commands, commands)
            try await owner.resumeAfterUserControl()
            let recovered = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(recovered); XCTAssertTrue(owner.needsFormPreparationReview)
            XCTAssertEqual(owner.confirmedFormHistory, history)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        }
    }

    func testPreparationRecoveryRejectsPreservationMetadataAndObjectChanges() async throws {
        for readonly in [false, true] {
            for mutation in ["document.getElementById('query').value='reset';document.getElementById('reference').value='changed';",
                             "document.getElementById('query').outerHTML=document.getElementById('query').outerHTML;",
                             "document.getElementById('query').value='reset';document.querySelector('select').options[0].textContent='Different';"] {
                let fixture = try await make(category: true, referenceReadOnly: readonly, mutation: mutation)
                defer { fixture.close() }
                _ = try await prepareRetainOnly(fixture)
                let owner = try fixture.owner(), history = owner.confirmedFormHistory
                try await release(fixture)
                await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
                XCTAssertFalse(owner.needsFormPreparationReview); XCTAssertTrue(owner.hasPendingFormPreparation)
                XCTAssertEqual(owner.confirmedFormHistory, history)
                XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 0)
                XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
            }
        }
    }

    func testPreparationRevisionRechecksNativeOriginsAfterTheRepairReview() async throws {
        for observed in [false, true] {
            let fixture = try await make(category: true, queryAlreadyMatches: observed, categoryAlreadyMatches: observed,
                mutation: "document.getElementById('query').value='reset';")
            defer { fixture.close() }
            let original = try await prepareRetainOnly(fixture), owner = try fixture.owner(), history = owner.confirmedFormHistory
            try await release(fixture)
            let recovered = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(recovered)
            configureMixed(fixture, editing: ["Query"], retaining: ["Category"])
            let action = try await owner.reviewFormPreparation(using: fixture.actions)
            let other = ComputerUseBrowserTextTarget(browser: fixture.browser, document: original.evidence.page.document, requiresFrontmost: false)
            _ = try await other.fields()
            await expectFailure { _ = try await owner.applyFormPreparationReview(action) }
            XCTAssertEqual(owner.confirmedFormHistory, history)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, observed ? 0 : 2)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, observed ? 1 : 0)
            XCTAssertTrue(owner.hasPendingFormPreparation)
        }
    }

    func testPreparationRepairCannotReplaceARevisionCaptureAfterPause() async throws {
        let fixture = try await make(category: true,
            mutation: "document.getElementById('query').value='reset';fetch('/signal').then(()=>{document.getElementById('query').value='another';fetch('/restored');});")
        defer { fixture.close() }
        _ = try await prepareRetainOnly(fixture)
        let owner = try fixture.owner(), history = owner.confirmedFormHistory
        try await release(fixture)
        let recovered = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertTrue(recovered)
        configureMixed(fixture, editing: ["Query"], retaining: ["Category"])
        let action = try await owner.reviewFormPreparation(using: fixture.actions)
        fixture.state.onCommand = { command in
            guard command == .reviseFormFields else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.applyFormPreparationReview(action) }
        let revisions = fixture.state.commands.filter { $0 == .reviseFormFields }.count
        try await releaseSecondSignal(fixture)
        try await owner.resumeAfterUserControl()
        await expectFailure { _ = try await owner.resumeFormPreparation() }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, revisions)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(owner.confirmedFormHistory, history)
        XCTAssertTrue(owner.hasPendingFormPreparation)
    }

    func testPreparationRecoveryDoesNotInventChangesForUnchangedCaptures() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let (first, proposal) = try await prepareMixed(fixture, order: ["Query","Category"]), owner = try fixture.owner()
        let writes = fixture.state.writes
        let unchangedInitial = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertFalse(unchangedInitial); XCTAssertFalse(owner.needsFormPreparationReview)
        XCTAssertEqual(fixture.state.writes, writes)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        let resumedInitial = try await owner.resumeFormPreparation()
        XCTAssertEqual(resumedInitial, first)
        _ = try await owner.executeForm(proposal, input: resumedInitial)
        configureMixed(fixture, editing: [], retaining: ["Query","Category"])
        let action = try await owner.planNextAction(using: fixture.actions), original = try await owner.prepareFormInput(for: action)
        let unchanged = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertFalse(unchanged); XCTAssertFalse(owner.needsFormPreparationReview)
        let resumed = try await owner.resumeFormPreparation()
        XCTAssertEqual(resumed, original)
        XCTAssertEqual(owner.confirmedFormHistory.count, 1)
    }

    func testPreparationRepairKeepsAcceptedSourcesWithoutRewritingEarlierHistory() async throws {
        let fixture = try await make(category: true, city: true, mutation: "document.getElementById('city').value='Portland';")
        defer { fixture.close() }
        let original = try await prepareAnsweredRetention(fixture), owner = try fixture.owner(), history = owner.confirmedFormHistory
        try await release(fixture)
        let recovered = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertTrue(recovered)
        let next = try await repairRetainPreparation(fixture, editing: ["City"], retaining: ["Query","Category"])
        XCTAssertEqual(next.previous, original.previous); XCTAssertEqual(owner.confirmedFormHistory, history)
        let baseline = try XCTUnwrap(next.preparationBaseline)
        let cityPurpose = try XCTUnwrap(baseline.reviewContext.fieldPurposes.first { purpose in
            original.evidence.fields.contains { $0.control.id == purpose.controlID && $0.control.label == "City" }
        })
        XCTAssertTrue(cityPurpose.sources.contains { $0.turn == 2 && $0.source == "Keep Seattle." })
        XCTAssertTrue(next.contextJSON.contains("Keep Seattle."))
        XCTAssertFalse(next.contextJSON.contains("Portland")); XCTAssertFalse(next.contextJSON.contains("private-reference"))
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 3)
    }

    func testInterruptedRetentionCapturesRecoverWithoutAnOriginalPlanningInput() async throws {
        for observed in [false, true] {
            for boundary in [ComputerUseBrowserDOMCommand.extendFormFields, .bindPageFields, .prepareFormPreservation] {
                let fixture = try await make(category: true, queryAlreadyMatches: observed, categoryAlreadyMatches: observed,
                    mutation: "document.getElementById('query').value='reset';")
                defer { fixture.close() }
                let first = try await interruptRetentionCapture(fixture, at: boundary), owner = try fixture.owner()
                let history = owner.confirmedFormHistory, writes = fixture.state.writes
                let captured = fixture.state.commands.filter { $0 == boundary }.count
                try await release(fixture)
                try await owner.resumeAfterUserControl()
                let recovered = try await owner.recoverPendingFormPreparationCriteria()
                XCTAssertTrue(recovered); XCTAssertTrue(owner.needsFormPreparationReview)
                XCTAssertEqual(owner.confirmedFormHistory, history); XCTAssertEqual(fixture.state.writes, writes)
                // No original input was manufactured for the retained frame.
                await expectFailure { _ = try await owner.executeForm(.decode(content: mixedContent(first, order: ["Query","Category"]), input: first), input: first) }
                let next = try await repairRetainPreparation(fixture, editing: ["Query"], retaining: ["Category"])
                let query = try XCTUnwrap(next.evidence.fields.first { $0.control.label == "Query" }).editable.snapshot
                XCTAssertEqual(query.value, "reset"); XCTAssertEqual(next.previous?.finalValues[query.targetID], "concerts")
                XCTAssertEqual(query.targetID, first.evidence.fields.first { $0.control.label == "Query" }?.editable.snapshot.targetID)
                XCTAssertEqual(next.requiredRepairFieldAliases.count, 1); XCTAssertNotNil(next.preparationBaseline)
                if boundary == .extendFormFields { XCTAssertEqual(fixture.state.commands.filter { $0 == boundary }.count, captured) }
                _ = try await owner.executeForm(.decode(content: mixedContent(next, order: ["Query"]), input: next), input: next)
                XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [observed ? 0 : 2,1])
                XCTAssertEqual(owner.confirmedFormHistory.map(\.retainedCriterionCount), [0,0])
                XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, observed ? 1 : 3)
            }
        }
    }

    func testRetentionRecoveryCanCaptureAChangedCriterionForTheFirstTime() async throws {
        for observed in [false, true] {
            let fixture = try await make(category: true, queryAlreadyMatches: observed, categoryAlreadyMatches: observed,
                mutation: "document.getElementById('query').value='reset';")
            defer { fixture.close() }
            _ = try await interruptRetentionCapture(fixture, at: .pageSnapshot)
            let owner = try fixture.owner(), extensions = fixture.state.commands.filter { $0 == .extendFormFields }.count
            try await release(fixture)
            try await owner.resumeAfterUserControl()
            let recovered = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(recovered)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .extendFormFields }.count, extensions + 1)
            let next = try await repairRetainPreparation(fixture, editing: ["Query"], retaining: ["Category"])
            XCTAssertEqual(next.requiredRepairFieldAliases.count, 1)
            let query = try XCTUnwrap(next.evidence.fields.first { $0.control.label == "Query" }).editable.snapshot
            XCTAssertEqual(query.value, "reset"); XCTAssertEqual(next.previous?.finalValues[query.targetID], "concerts")
            XCTAssertEqual(next.previous?.inputOperationIDs.count, observed ? 0 : 2)
            XCTAssertEqual(next.previous?.stateProofsByTarget.count, observed ? 2 : 0)
            _ = try await owner.executeForm(.decode(content: mixedContent(next, order: ["Query"]), input: next), input: next)
            XCTAssertEqual(owner.confirmedFormHistory.map(\.retainedCriterionCount), [0,0])
        }
    }

    func testDriverRepairsAnInterruptedRetentionCaptureWithoutRepeatingOtherInputs() async throws {
        for boundary in [ComputerUseBrowserDOMCommand.pageSnapshot, .extendFormFields] {
            let fixture = try await make(category: true, mutation: "document.getElementById('query').value='reset';")
            defer { fixture.close() }
            _ = try await interruptRetentionCapture(fixture, at: boundary)
            let owner = try fixture.owner()
            try await release(fixture)
            configureMixed(fixture, editing: ["Query"], retaining: ["Category"], querying: true)
            fixture.forms.select = { input in try self.mixedContent(input, order: ["Query"]) }
            _ = try await fixture.resume()
            XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [2,1])
            XCTAssertEqual(owner.confirmedFormHistory.map(\.retainedCriterionCount), [0,0])
            XCTAssertEqual(fixture.forms.inputs.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 3)
            XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts"), 1)
        }
    }

    func testRestoredCriteriaCanReplaceAChangedHistoricalCaptureWithoutInput() async throws {
        let fixture = try await make(category: true,
            mutation: "document.getElementById('query').value='reset';fetch('/signal').then(()=>{document.getElementById('query').value='concerts';fetch('/restored');});")
        defer { fixture.close() }
        let (first, proposal) = try await prepareMixed(fixture, order: ["Query","Category"]), owner = try fixture.owner()
        _ = try await owner.executeForm(proposal, input: first)
        configureMixed(fixture, editing: [], retaining: ["Query","Category"])
        let action = try await owner.planNextAction(using: fixture.actions)
        try await release(fixture)
        // The first private field capture sees "reset", so it never forms a
        // valid retain-only input, even though its callback must be retained.
        await expectFailure { _ = try await owner.prepareFormInput(for: action) }
        let extensions = fixture.state.commands.filter { $0 == .extendFormFields }.count
        try await releaseSecondSignal(fixture)
        let recovered = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertTrue(recovered); XCTAssertEqual(owner.confirmedFormHistory.count, 1)
        let next = try await repairRetainPreparation(fixture, editing: [], retaining: ["Query","Category"])
        XCTAssertTrue(next.isRetainOnly); XCTAssertTrue(next.requiredRepairFieldAliases.isEmpty)
        let receipt = try await owner.executeForm(.decode(content: #"{"retain":true}"#, input: next), input: next)
        XCTAssertTrue(receipt.isCompleteStage); XCTAssertEqual(receipt.retainedCriterionCount, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .extendFormFields }.count, extensions)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, 0)
    }

    func testIncompleteRetentionRecoveryKeepsPreservationAndNativeObjects() async throws {
        for readonly in [false, true] {
            for mutation in ["document.getElementById('query').value='reset';document.getElementById('reference').value='changed';",
                             "document.getElementById('query').outerHTML=document.getElementById('query').outerHTML;"] {
                let fixture = try await make(category: true, referenceReadOnly: readonly, mutation: mutation)
                defer { fixture.close() }
                _ = try await interruptRetentionCapture(fixture, at: .extendFormFields)
                let owner = try fixture.owner(), history = owner.confirmedFormHistory
                try await release(fixture)
                try await owner.resumeAfterUserControl()
                await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
                XCTAssertFalse(owner.needsFormPreparationReview); XCTAssertTrue(owner.hasPendingFormPreparation)
                XCTAssertEqual(owner.confirmedFormHistory, history)
                XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 0)
                XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
            }
        }
    }

    func testIncompleteRetentionRecoveryStopsAtItsOwnCancelledBinding() async throws {
        let fixture = try await make(category: true, mutation: "document.getElementById('query').value='reset';")
        defer { fixture.close() }
        _ = try await interruptRetentionCapture(fixture, at: .extendFormFields)
        let owner = try fixture.owner()
        try await release(fixture)
        try await owner.resumeAfterUserControl()
        fixture.state.onCommand = { command in
            guard command == .bindPageFields else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
        XCTAssertEqual(fixture.state.commands.last, .bindPageFields); XCTAssertFalse(owner.needsFormPreparationReview)
        let commands = fixture.state.commands
        await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
        XCTAssertEqual(fixture.state.commands, commands)
        try await owner.resumeAfterUserControl()
        let recovered = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertTrue(recovered); XCTAssertEqual(owner.confirmedFormHistory.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testIncompleteRetentionRevisionCannotReconstructLostNativeOrigins() async throws {
        for observed in [false, true] {
            let fixture = try await make(category: true, queryAlreadyMatches: observed, categoryAlreadyMatches: observed,
                mutation: "document.getElementById('query').value='reset';")
            defer { fixture.close() }
            let first = try await interruptRetentionCapture(fixture, at: .pageSnapshot), owner = try fixture.owner()
            try await release(fixture)
            try await owner.resumeAfterUserControl()
            let recovered = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(recovered)
            configureMixed(fixture, editing: ["Query"], retaining: ["Category"])
            let action = try await owner.reviewFormPreparation(using: fixture.actions)
            let other = ComputerUseBrowserTextTarget(browser: fixture.browser, document: first.evidence.page.document, requiresFrontmost: false)
            _ = try await other.fields()
            await expectFailure { _ = try await owner.applyFormPreparationReview(action) }
            XCTAssertEqual(owner.confirmedFormHistory.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, observed ? 0 : 2)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, observed ? 1 : 0)
        }
    }

    func testUnchangedIncompleteRetentionStillNeedsOrdinaryInputPreparation() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        _ = try await interruptRetentionCapture(fixture, at: .extendFormFields)
        let owner = try fixture.owner(), extensions = fixture.state.commands.filter { $0 == .extendFormFields }.count
        try await owner.resumeAfterUserControl()
        let recovered = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertFalse(recovered); XCTAssertFalse(owner.needsFormPreparationReview)
        XCTAssertEqual(owner.confirmedFormHistory.count, 1)
        let input = try await owner.resumeFormPreparation()
        XCTAssertTrue(input.isRetainOnly)
        let receipt = try await owner.executeForm(.decode(content: #"{"retain":true}"#, input: input), input: input)
        XCTAssertTrue(receipt.isCompleteStage)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .extendFormFields }.count, extensions)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    private func interruptRetentionCapture(_ fixture: ResearchDriverFixture, at boundary: ComputerUseBrowserDOMCommand) async throws -> ComputerUseBrowserResearchFormInput {
        let (first, proposal) = try await prepareMixed(fixture, order: ["Query","Category"]), owner = try fixture.owner()
        _ = try await owner.executeForm(proposal, input: first)
        configureMixed(fixture, editing: [], retaining: ["Query","Category"])
        let action = try await owner.planNextAction(using: fixture.actions)
        fixture.state.onCommand = { command in
            guard command == boundary else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.prepareFormInput(for: action) }
        XCTAssertTrue(owner.hasPendingFormPreparation)
        return first
    }

    func testAnsweredPhysicalRevisionCanRecoverItsEarlierRetentionCapture() async throws {
        for observed in [false, true] {
            let fixture = try await make(category: true, queryAlreadyMatches: observed, categoryAlreadyMatches: observed,
                mutation: "document.getElementById('query').value='reset';")
            defer { fixture.close() }
            let original = try await prepareRetainOnly(fixture), owner = try fixture.owner(), history = owner.confirmedFormHistory
            let updated = try await beginPreparationReview(fixture, input: original)
            configureAnsweredRetentionRevision(fixture, editing: ["Query"], retaining: ["Category"])
            let action = try await owner.reviewFormPreparation(using: fixture.actions)
            try await release(fixture)
            await expectFailure { _ = try await owner.applyFormPreparationReview(action) }
            XCTAssertFalse(owner.hasRevisedFormPreparationGoal); XCTAssertFalse(owner.needsFormPreparationReview)
            let writes = fixture.state.writes, recovered = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(recovered); XCTAssertTrue(owner.needsFormPreparationReview)
            XCTAssertEqual(owner.confirmedFormHistory, history); XCTAssertEqual(fixture.state.writes, writes)
            let commands = fixture.state.commands
            await expectFailure { _ = try await owner.resumeFormPreparation() }
            XCTAssertEqual(fixture.state.commands, commands) // The skipped edit scope cannot consume the recovery.
            let reviewed = try await owner.reviewFormPreparation(using: fixture.actions)
            let next = try await owner.applyFormPreparationReview(reviewed)
            XCTAssertEqual(next.interpretation.input, updated.input); XCTAssertEqual(next.previous, original.previous)
            let query = try XCTUnwrap(next.evidence.fields.first { $0.control.label == "Query" })
            XCTAssertEqual(query.editable.snapshot.value, "reset")
            XCTAssertEqual(next.previous?.finalValues[query.editable.snapshot.targetID], "concerts")
            XCTAssertTrue(next.preparationBaseline?.reviewContext.fieldPurposes.contains {
                $0.controlID == query.control.id && $0.disposition == .edit
            } == true) // Keep the newer unexecuted review distinct from the old capture review.
            XCTAssertEqual(next.requiredRepairFieldAliases.count, 1)
            _ = try await owner.executeForm(.decode(content: mixedContent(next, order: ["Query"]), input: next), input: next)
            XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [observed ? 0 : 2,1])
            XCTAssertEqual(owner.confirmedFormHistory.map(\.retainedCriterionCount), [0,0])
            XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
        }
    }

    func testAnAnswerDoesNotHideAnIncompleteRetentionCapture() async throws {
        for boundary in [ComputerUseBrowserDOMCommand.pageSnapshot, .extendFormFields, .bindPageFields] {
            let fixture = try await make(category: true, mutation: "document.getElementById('query').value='reset';")
            defer { fixture.close() }
            let first = try await interruptRetentionCapture(fixture, at: boundary), owner = try fixture.owner()
            try await owner.resumeAfterUserControl()
            _ = try await beginPreparationReview(fixture, input: first)
            configureAnsweredRetentionRevision(fixture, editing: ["Query"], retaining: ["Category"])
            let action = try await owner.reviewFormPreparation(using: fixture.actions)
            try await release(fixture)
            await expectFailure { _ = try await owner.applyFormPreparationReview(action) }
            let recovered = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(recovered); XCTAssertTrue(owner.needsFormPreparationReview)
            XCTAssertEqual(owner.confirmedFormHistory.count, 1)
            let reviewed = try await owner.reviewFormPreparation(using: fixture.actions), next = try await owner.applyFormPreparationReview(reviewed)
            XCTAssertEqual(next.requiredRepairFieldAliases.count, 1)
            XCTAssertEqual(next.previous?.inputOperationIDs.count, 2)
            XCTAssertEqual(next.interpretation.input.clarifications.map(\.answer), ["Tomorrow."])
            _ = try await owner.executeForm(.decode(content: mixedContent(next, order: ["Query"]), input: next), input: next)
            XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [2,1])
            XCTAssertEqual(owner.confirmedFormHistory.map(\.retainedCriterionCount), [0,0])
        }
    }

    func testDriverRevisitsTheAnsweredScopeAfterRecoveringAnEarlierCapture() async throws {
        let fixture = try await make(category: true, city: true, mutation: "document.getElementById('query').value='reset';")
        defer { fixture.close() }
        let original = try await prepareRetainOnly(fixture, deferring: ["City"]), owner = try fixture.owner()
        let updated = try await beginPreparationReview(fixture, input: original)
        configureAnsweredRetentionRevision(fixture, editing: ["Query","City"], retaining: ["Category"], querying: true)
        let action = try await owner.reviewFormPreparation(using: fixture.actions)
        try await release(fixture)
        await expectFailure { _ = try await owner.applyFormPreparationReview(action) }
        fixture.forms.select = { input in
            XCTAssertEqual(input.interpretation.input, updated.input)
            XCTAssertEqual(input.requiredRepairFieldAliases.count, 1)
            XCTAssertEqual(input.editableFieldAliases.count, 2)
            return try self.mixedContent(input, order: ["Query","City"])
        }
        _ = try await fixture.resume()
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [2,2])
        XCTAssertEqual(owner.confirmedFormHistory.map(\.retainedCriterionCount), [0,0])
        XCTAssertEqual(fixture.forms.inputs.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 4)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts&city=Seattle"), 1)
    }

    func testInheritedCaptureRecoverySurvivesPauseBeforePublishingToTheRevision() async throws {
        for (boundary, occurrence) in [(ComputerUseBrowserDOMCommand.bindPageFields,1), (.pageSnapshot,3)] {
            let fixture = try await make(category: true, mutation: "document.getElementById('query').value='reset';")
            defer { fixture.close() }
            let original = try await prepareRetainOnly(fixture), owner = try fixture.owner(), history = owner.confirmedFormHistory
            _ = try await beginPreparationReview(fixture, input: original)
            configureAnsweredRetentionRevision(fixture, editing: ["Query"], retaining: ["Category"])
            let action = try await owner.reviewFormPreparation(using: fixture.actions)
            try await release(fixture)
            await expectFailure { _ = try await owner.applyFormPreparationReview(action) }
            var seen = 0
            fixture.state.onCommand = { command in
                guard command == boundary else { return }; seen += 1
                guard seen == occurrence else { return }; fixture.state.onCommand = nil; owner.pause()
            }
            await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
            XCTAssertFalse(owner.needsFormPreparationReview); XCTAssertEqual(owner.confirmedFormHistory, history)
            let commands = fixture.state.commands
            await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
            XCTAssertEqual(fixture.state.commands, commands)
            try await owner.resumeAfterUserControl()
            let recovered = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(recovered); XCTAssertTrue(owner.needsFormPreparationReview)
            XCTAssertEqual(owner.confirmedFormHistory, history)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        }
    }

    func testStartedRevisionRecoversItsOwnCaptureInsteadOfSkippingIt() async throws {
        let fixture = try await make(category: true, city: true, mutation: "document.getElementById('query').value='reset';")
        defer { fixture.close() }
        let original = try await prepareRetainOnly(fixture, deferring: ["City"]), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: original)
        configureAnsweredRetentionRevision(fixture, editing: ["City"], retaining: ["Query","Category"])
        let action = try await owner.reviewFormPreparation(using: fixture.actions)
        fixture.state.onCommand = { command in
            guard command == .reviseFormFields else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.applyFormPreparationReview(action) }
        try await release(fixture)
        try await owner.resumeAfterUserControl()
        let history = owner.confirmedFormHistory, writes = fixture.state.writes
        let recovered = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertTrue(recovered); XCTAssertTrue(owner.needsFormPreparationReview)
        XCTAssertEqual(owner.confirmedFormHistory, history); XCTAssertEqual(fixture.state.writes, writes)
        await expectFailure { _ = try await owner.resumeFormPreparation() }
        XCTAssertTrue(owner.hasPendingFormPreparation)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        configureAnsweredRetentionRevision(fixture, editing: ["Query","City"], retaining: ["Category"])
        let fresh = try await owner.reviewFormPreparation(using: fixture.actions), next = try await owner.applyFormPreparationReview(fresh)
        let baseline = try XCTUnwrap(next.preparationBaseline)
        let city = try XCTUnwrap(next.evidence.fields.first { $0.control.label == "City" })
        XCTAssertTrue(baseline.capturedTargetIDs.contains(city.editable.snapshot.targetID))
        XCTAssertTrue(city.editable.snapshot.value.isEmpty)
        XCTAssertFalse(original.evidence.fields.contains { $0.control.label == "City" })
        XCTAssertEqual(next.previous, original.previous)
        XCTAssertEqual(next.interpretation.input.clarifications.map(\.answer), ["Tomorrow."])
        _ = try await owner.executeForm(.decode(content: mixedContent(next, order: ["Query","City"]), input: next), input: next)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [2,2])
        XCTAssertEqual(owner.confirmedFormHistory.map(\.retainedCriterionCount), [0,0])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 2)
    }

    func testUnchangedEarlierCriteriaDoNotCreateInheritedRecovery() async throws {
        let fixture = try await make(category: true)
        defer { fixture.close() }
        let original = try await prepareRetainOnly(fixture), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: original)
        configureAnsweredRetentionRevision(fixture, editing: ["Query"], retaining: ["Category"])
        let action = try await owner.reviewFormPreparation(using: fixture.actions)
        fixture.state.onCommand = { command in
            guard command == .pageSnapshot else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.applyFormPreparationReview(action) }
        try await owner.resumeAfterUserControl()
        let recovered = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertFalse(recovered); XCTAssertFalse(owner.needsFormPreparationReview)
        let next = try await owner.resumeFormPreparation()
        XCTAssertFalse(next.isRetainOnly); XCTAssertEqual(next.editableFieldAliases.count, 1)
        XCTAssertEqual(next.previous, original.previous)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(owner.confirmedFormHistory.count, 1)
    }

    func testInheritedRecoveryCannotDropPreservationOrReplaceTheEarlierObject() async throws {
        for readonly in [false, true] {
            for mutation in ["document.getElementById('query').value='reset';document.getElementById('reference').value='changed';",
                             "document.getElementById('query').outerHTML=document.getElementById('query').outerHTML;"] {
                let fixture = try await make(category: true, referenceReadOnly: readonly, mutation: mutation)
                defer { fixture.close() }
                let original = try await prepareRetainOnly(fixture), owner = try fixture.owner()
                _ = try await beginPreparationReview(fixture, input: original)
                configureAnsweredRetentionRevision(fixture, editing: ["Query"], retaining: ["Category"])
                let action = try await owner.reviewFormPreparation(using: fixture.actions)
                try await release(fixture)
                await expectFailure { _ = try await owner.applyFormPreparationReview(action) }
                await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
                XCTAssertFalse(owner.needsFormPreparationReview); XCTAssertTrue(owner.hasPendingFormPreparation)
                XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 0)
                XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
                XCTAssertEqual(owner.confirmedFormHistory.count, 1)
            }
        }
    }

    func testTwoAcceptedAnswersKeepTheEarlierCaptureAcrossUnstartedRevisions() async throws {
        let fixture = try await make(category: true, mutation: "document.getElementById('query').value='reset';")
        defer { fixture.close() }
        let original = try await prepareRetainOnly(fixture), owner = try fixture.owner()
        let firstGoal = try await beginPreparationReview(fixture, input: original)
        configureAnsweredRetentionRevision(fixture, editing: ["Query"], retaining: ["Category"])
        let firstAction = try await owner.reviewFormPreparation(using: fixture.actions)
        try await release(fixture)
        await expectFailure { _ = try await owner.applyFormPreparationReview(firstAction) }
        let question = try owner.issueQuestion(topic: .date, requirementIDs: [firstGoal.requirements[0].id],
            controllerID: "phone", controllerSessionID: "session")
        _ = try owner.answerQuestion(questionID: question.id, answerTaskID: "second-answer", answer: "Evening.",
            controllerID: "phone", controllerSessionID: "session")
        let interpreted = try await owner.interpretGoal()
        try owner.configureResearchSources(XCTUnwrap(fixture.policy.sources(for: interpreted)))
        let secondAction = try await owner.reviewFormPreparation(using: fixture.actions)
        await expectFailure { _ = try await owner.applyFormPreparationReview(secondAction) }
        let recovered = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertTrue(recovered); XCTAssertTrue(owner.needsFormPreparationReview)
        let fresh = try await owner.reviewFormPreparation(using: fixture.actions), next = try await owner.applyFormPreparationReview(fresh)
        XCTAssertEqual(next.interpretation.input.clarifications.map(\.answer), ["Tomorrow.","Evening."])
        XCTAssertEqual(next.previous, original.previous)
        XCTAssertTrue(next.contextJSON.contains("Tomorrow.")); XCTAssertTrue(next.contextJSON.contains("Evening."))
        XCTAssertFalse(next.contextJSON.contains("private-reference")); XCTAssertFalse(next.contextJSON.contains("reset"))
        _ = try await owner.executeForm(.decode(content: mixedContent(next, order: ["Query"]), input: next), input: next)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [2,1])
        XCTAssertEqual(owner.confirmedFormHistory.map(\.retainedCriterionCount), [0,0])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
    }

    func testPhysicalPreparationsRecoverEarlierCriteriaAtEveryCaptureBoundary() async throws {
        for observed in [false, true] {
            for boundary in [ComputerUseBrowserDOMCommand.extendFormFields, .bindPageFields, .prepareFormPreservation] {
                let fixture = try await make(category: true, city: true, queryAlreadyMatches: observed, categoryAlreadyMatches: observed,
                    mutation: "document.getElementById('query').value='reset';")
                defer { fixture.close() }
                let (first, _) = try await preparePhysicalCity(fixture, interrupting: boundary), owner = try fixture.owner()
                let history = owner.confirmedFormHistory, writes = fixture.state.writes
                let extensions = fixture.state.commands.filter { $0 == .extendFormFields }.count
                try await release(fixture)
                try await owner.resumeAfterUserControl()
                let recovered = try await owner.recoverPendingFormPreparationCriteria()
                XCTAssertTrue(recovered); XCTAssertTrue(owner.needsFormPreparationReview)
                XCTAssertEqual(owner.confirmedFormHistory, history); XCTAssertEqual(fixture.state.writes, writes)
                XCTAssertEqual(fixture.state.commands.filter { $0 == .extendFormFields }.count, extensions)
                let next = try await repairRetainPreparation(fixture, editing: ["Query","City"], retaining: ["Category"])
                let city = try XCTUnwrap(next.evidence.fields.first { $0.control.label == "City" })
                XCTAssertTrue(try XCTUnwrap(next.preparationBaseline).capturedTargetIDs.contains(city.editable.snapshot.targetID))
                XCTAssertTrue(city.editable.snapshot.value.isEmpty)
                XCTAssertFalse(first.evidence.fields.contains { $0.control.id == city.control.id })
                XCTAssertEqual(next.requiredRepairFieldAliases.count, 1)
                _ = try await owner.executeForm(.decode(content: mixedContent(next, order: ["Query","City"]), input: next), input: next)
                XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [observed ? 0 : 2,2])
                XCTAssertEqual(owner.confirmedFormHistory.map(\.retainedCriterionCount), [0,0])
                XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, observed ? 2 : 4)
            }
        }
    }

    func testCompletedPhysicalPreparationRecoversWithoutConsumingItsOldProposal() async throws {
        let fixture = try await make(category: true, city: true, mutation: "document.getElementById('query').value='reset';")
        defer { fixture.close() }
        let (_, prepared) = try await preparePhysicalCity(fixture), original = try XCTUnwrap(prepared), owner = try fixture.owner()
        let stale = try ComputerUseBrowserFormProposal.decode(content: mixedContent(original, order: ["City"]), input: original)
        let history = owner.confirmedFormHistory, writes = fixture.state.writes
        try await release(fixture)
        let recovered = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertTrue(recovered); XCTAssertTrue(owner.needsFormPreparationReview)
        await expectFailure { _ = try await owner.executeForm(stale, input: original) }
        XCTAssertEqual(owner.confirmedFormHistory, history); XCTAssertEqual(fixture.state.writes, writes)
        let next = try await repairRetainPreparation(fixture, editing: ["Query","City"], retaining: ["Category"])
        XCTAssertEqual(next.previous, original.previous)
        let oldCity = try XCTUnwrap(original.evidence.fields.first { $0.control.label == "City" })
        XCTAssertEqual(next.evidence.fields.first { $0.control.label == "City" }?.editable, oldCity.editable)
        _ = try await owner.executeForm(.decode(content: mixedContent(next, order: ["Query","City"]), input: next), input: next)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [2,2])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 4)
    }

    func testPhysicalRecoveryRejectsReplacedNewFieldsAndChangedPreservation() async throws {
        for boundary in [ComputerUseBrowserDOMCommand.extendFormFields, .bindPageFields] {
            for mutation in ["document.getElementById('query').value='reset';document.getElementById('city').outerHTML=document.getElementById('city').outerHTML;",
                             "document.getElementById('query').value='reset';document.getElementById('reference').value='changed';"] {
                let fixture = try await make(category: true, city: true, mutation: mutation)
                defer { fixture.close() }
                _ = try await preparePhysicalCity(fixture, interrupting: boundary)
                let owner = try fixture.owner(), history = owner.confirmedFormHistory, writes = fixture.state.writes
                try await release(fixture)
                try await owner.resumeAfterUserControl()
                await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
                XCTAssertFalse(owner.needsFormPreparationReview); XCTAssertTrue(owner.hasPendingFormPreparation)
                XCTAssertEqual(owner.confirmedFormHistory, history); XCTAssertEqual(fixture.state.writes, writes)
                XCTAssertEqual(fixture.state.commands.filter { $0 == .extendFormFields }.count, 1)
                XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 0)
                XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
            }
        }
    }

    func testNewFieldCaretChangesRequireAFreshReviewedInput() async throws {
        for (queryChanged, mutation) in [(false, "document.getElementById('city').value='draft';document.getElementById('city').setSelectionRange(5,5);fetch('/signal').then(()=>{document.getElementById('city').setSelectionRange(0,0);fetch('/restored');});"),
                                       (true, "document.getElementById('city').value='draft';document.getElementById('city').setSelectionRange(5,5);fetch('/signal').then(()=>{document.getElementById('query').value='reset';document.getElementById('city').setSelectionRange(0,0);fetch('/restored');});")] {
            let fixture = try await make(category: true, city: true, mutation: mutation)
            defer { fixture.close() }
            let (first, proposal) = try await prepareMixed(fixture, order: ["Query","Category"], deferring: ["City"]), owner = try fixture.owner()
            // The first input must be consumed before City becomes a captured field.
            _ = try await owner.executeForm(proposal, input: first)
            try await release(fixture)
            configureMixed(fixture, editing: ["City"], retaining: ["Query","Category"])
            let action = try await owner.planNextAction(using: fixture.actions), original = try await owner.prepareFormInput(for: action)
            let city = try XCTUnwrap(original.evidence.fields.first { $0.control.label == "City" }).editable.snapshot
            XCTAssertEqual(city.value, "draft"); XCTAssertEqual(city.selection, NSRange(location: 5, length: 0))
            let history = owner.confirmedFormHistory, writes = fixture.state.writes
            try await releaseSecondSignal(fixture)
            let recovered = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(recovered); XCTAssertTrue(owner.needsFormPreparationReview)
            await expectFailure { _ = try await owner.executeForm(.decode(content: mixedContent(original, order: ["City"]), input: original), input: original) }
            XCTAssertEqual(owner.confirmedFormHistory, history); XCTAssertEqual(fixture.state.writes, writes)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 0)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
            let edits = queryChanged ? ["Query","City"] : ["City"]
            let next = try await repairRetainPreparation(fixture, editing: edits, retaining: queryChanged ? ["Category"] : ["Query","Category"])
            let refreshed = try XCTUnwrap(next.evidence.fields.first { $0.control.label == "City" }).editable.snapshot
            XCTAssertEqual(refreshed.value, "draft"); XCTAssertEqual(refreshed.selection, NSRange(location: 0, length: 0))
            XCTAssertEqual(city.selection, NSRange(location: 5, length: 0))
            XCTAssertEqual(next.requiredRepairFieldAliases.count, queryChanged ? 2 : 1)
            _ = try await owner.executeForm(.decode(content: mixedContent(next, order: edits), input: next), input: next)
            XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [2, queryChanged ? 2 : 1])
        }
    }

    func testPhysicalCriteriaRecoveryRequiresHandbackAtBindingAndOriginChecks() async throws {
        for (boundary, occurrence) in [(ComputerUseBrowserDOMCommand.bindPageFields,1), (.inspectFormRequirements,2)] {
            let fixture = try await make(category: true, city: true, mutation: "document.getElementById('query').value='reset';")
            defer { fixture.close() }
            _ = try await preparePhysicalCity(fixture)
            let owner = try fixture.owner(), history = owner.confirmedFormHistory, writes = fixture.state.writes
            try await release(fixture)
            var seen = 0
            fixture.state.onCommand = { command in
                guard command == boundary else { return }; seen += 1
                guard seen == occurrence else { return }; fixture.state.onCommand = nil; owner.pause()
            }
            await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
            XCTAssertFalse(owner.needsFormPreparationReview)
            let commands = fixture.state.commands
            await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
            XCTAssertEqual(fixture.state.commands, commands)
            try await owner.resumeAfterUserControl()
            let recovered = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(recovered); XCTAssertTrue(owner.needsFormPreparationReview)
            XCTAssertEqual(owner.confirmedFormHistory, history); XCTAssertEqual(fixture.state.writes, writes)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .extendFormFields }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        }
    }

    func testPhysicalPreparationRevisionRechecksNativeOriginsAfterReview() async throws {
        for observed in [false, true] {
            let fixture = try await make(category: true, city: true, queryAlreadyMatches: observed, categoryAlreadyMatches: observed,
                mutation: "document.getElementById('query').value='reset';")
            defer { fixture.close() }
            let (_, prepared) = try await preparePhysicalCity(fixture), original = try XCTUnwrap(prepared), owner = try fixture.owner()
            let history = owner.confirmedFormHistory
            try await release(fixture)
            let recovered = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(recovered)
            configureMixed(fixture, editing: ["Query","City"], retaining: ["Category"])
            let action = try await owner.reviewFormPreparation(using: fixture.actions)
            let other = ComputerUseBrowserTextTarget(browser: fixture.browser, document: original.evidence.page.document, requiresFrontmost: false)
            _ = try await other.fields()
            await expectFailure { _ = try await owner.applyFormPreparationReview(action) }
            XCTAssertTrue(owner.hasPendingFormPreparation); XCTAssertEqual(owner.confirmedFormHistory, history)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, observed ? 0 : 2)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, observed ? 1 : 0)
        }
    }

    func testPhysicalRecoveryKeepsAChangedCaptureSeparateFromItsEarlierDesiredValue() async throws {
        let mutation = "document.getElementById('query').value='reset';fetch('/signal').then(()=>{document.getElementById('query').value='another';fetch('/restored');});"
        let fixture = try await make(category: true, city: true, mutation: mutation)
        defer { fixture.close() }
        let (first, proposal) = try await prepareMixed(fixture, order: ["Query","Category"], deferring: ["City"]), owner = try fixture.owner()
        _ = try await owner.executeForm(proposal, input: first)
        try await release(fixture)
        configureMixed(fixture, editing: ["Query","City"], retaining: ["Category"])
        let action = try await owner.planNextAction(using: fixture.actions), original = try await owner.prepareFormInput(for: action)
        let query = try XCTUnwrap(original.evidence.fields.first { $0.control.label == "Query" }).editable.snapshot
        XCTAssertEqual(query.value, "reset"); XCTAssertEqual(original.previous?.finalValues[query.targetID], "concerts")
        try await releaseSecondSignal(fixture)
        let recovered = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertTrue(recovered)
        let next = try await repairRetainPreparation(fixture, editing: ["Query","City"], retaining: ["Category"])
        XCTAssertEqual(next.evidence.fields.first { $0.control.label == "Query" }?.editable.snapshot.value, "another")
        XCTAssertEqual(next.previous, original.previous)
        XCTAssertEqual(query.value, "reset")
        _ = try await owner.executeForm(.decode(content: mixedContent(next, order: ["Query","City"]), input: next), input: next)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [2,2])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 4)
    }

    func testPhysicalRepairRechecksNewFieldValuesAfterTheFreshReview() async throws {
        for pause in [false, true] {
            let mutation = "document.getElementById('query').value='reset';fetch('/signal').then(()=>{document.getElementById('city').value='Portland';fetch('/restored');});"
            let fixture = try await make(category: true, city: true, mutation: mutation)
            defer { fixture.close() }
            let (_, prepared) = try await preparePhysicalCity(fixture), original = try XCTUnwrap(prepared)
            let owner = try fixture.owner(), history = owner.confirmedFormHistory, writes = fixture.state.writes
            try await release(fixture)
            let recovered = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(recovered)
            configureMixed(fixture, editing: ["Query","City"], retaining: ["Category"])
            let action = try await owner.reviewFormPreparation(using: fixture.actions)
            try await releaseSecondSignal(fixture)
            if pause {
                fixture.state.onCommand = { command in
                    guard command == .reviseFormFields else { return }; fixture.state.onCommand = nil; owner.pause()
                }
            }
            await expectFailure { _ = try await owner.applyFormPreparationReview(action) }
            XCTAssertTrue(owner.hasPendingFormPreparation); XCTAssertEqual(owner.confirmedFormHistory, history)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
            if pause {
                let commands = fixture.state.commands
                await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
                XCTAssertEqual(fixture.state.commands, commands)
                try await owner.resumeAfterUserControl()
            }
            let freshRecovery = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(freshRecovery); XCTAssertTrue(owner.needsFormPreparationReview)
            XCTAssertEqual(owner.confirmedFormHistory, history); XCTAssertEqual(fixture.state.writes, writes)
            await expectFailure { _ = try await owner.resumeFormPreparation() }
            configureMixed(fixture, editing: ["Query"], retaining: ["Category"], deferring: ["City"])
            await expectFailure { _ = try await owner.reviewFormPreparation(using: fixture.actions) }
            let next = try await repairRetainPreparation(fixture, editing: ["Query","City"], retaining: ["Category"])
            let city = try XCTUnwrap(next.evidence.fields.first { $0.control.label == "City" })
            XCTAssertEqual(city.editable.snapshot.value, "Portland")
            XCTAssertEqual(next.previous, original.previous); XCTAssertEqual(next.requiredRepairFieldAliases.count, 2)
            _ = try await owner.executeForm(.decode(content: mixedContent(next, order: ["Query","City"]), input: next), input: next)
            XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [2,2])
            XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 2)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .extendFormFields }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 4)
        }
    }

    func testRejectedInitialRevisionKeepsItsAnswerAndCreatesOnlyTheFirstStage() async throws {
        let mutation = "document.getElementById('query').value='reset';fetch('/signal').then(()=>{document.getElementById('city').value='Portland';fetch('/restored');});"
        let fixture = try await make(city: true, mutation: mutation)
        defer { fixture.close() }
        let (original, _) = try await prepareMixed(fixture, order: ["Query","City"]), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: original)
        try await release(fixture)
        let recovered = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertTrue(recovered)
        configureAnsweredRetentionRevision(fixture, editing: ["Query","City"], retaining: [])
        let action = try await owner.reviewFormPreparation(using: fixture.actions)
        try await releaseSecondSignal(fixture)
        await expectFailure { _ = try await owner.applyFormPreparationReview(action) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
        let again = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertTrue(again); XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
        let fresh = try await owner.reviewFormPreparation(using: fixture.actions), next = try await owner.applyFormPreparationReview(fresh)
        XCTAssertEqual(next.interpretation.input.clarifications.map(\.answer), ["Tomorrow."])
        XCTAssertNil(next.previous); XCTAssertEqual(next.requiredRepairFieldAliases.count, 2)
        XCTAssertEqual(next.evidence.fields.first { $0.control.label == "City" }?.editable.snapshot.value, "Portland")
        _ = try await owner.executeForm(.decode(content: mixedContent(next, order: ["Query","City"]), input: next), input: next)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [2])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testUncapturedRevisionCannotDiscardChangedPreservationOrRequiredObjects() async throws {
        for mutation in ["document.getElementById('query').value='reset';fetch('/signal').then(()=>{document.getElementById('city').value='Portland';document.getElementById('reference').value='changed';fetch('/restored');});",
                         "document.getElementById('query').value='reset';fetch('/signal').then(()=>{document.getElementById('city').value='Portland';const q=document.getElementById('query');q.replaceWith(q.cloneNode(true));fetch('/restored');});"] {
            let fixture = try await make(category: true, city: true, mutation: mutation)
            defer { fixture.close() }
            _ = try await preparePhysicalCity(fixture)
            let owner = try fixture.owner(), history = owner.confirmedFormHistory, writes = fixture.state.writes
            try await release(fixture)
            let recovered = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(recovered)
            configureMixed(fixture, editing: ["Query","City"], retaining: ["Category"])
            let action = try await owner.reviewFormPreparation(using: fixture.actions)
            try await releaseSecondSignal(fixture)
            await expectFailure { _ = try await owner.applyFormPreparationReview(action) }
            await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
            XCTAssertEqual(owner.confirmedFormHistory, history); XCTAssertEqual(fixture.state.writes, writes)
            XCTAssertTrue(owner.hasPendingFormPreparation)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .extendFormFields }.count, 1)
        }
    }

    func testDriverReplansAfterAProvenPreCaptureRevisionRejection() async throws {
        let mutation = "document.getElementById('query').value='reset';fetch('/signal').then(()=>{document.getElementById('city').value='Portland';fetch('/restored');});"
        let fixture = try await make(category: true, city: true, mutation: mutation)
        defer { fixture.close() }
        _ = try await preparePhysicalCity(fixture)
        let owner = try fixture.owner()
        try await release(fixture)
        let recovered = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertTrue(recovered)
        configureMixed(fixture, editing: ["Query","City"], retaining: ["Category"], querying: true)
        fixture.actions.beforeReply = { fixture.actions.beforeReply = nil; try await self.releaseSecondSignal(fixture) }
        var proposals = 0
        fixture.forms.select = { input in
            proposals += 1; XCTAssertEqual(input.requiredRepairFieldAliases.count, 2)
            return try self.mixedContent(input, order: ["Query","City"])
        }
        _ = try await fixture.resume()
        XCTAssertEqual(proposals, 1)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [2,2])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .extendFormFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 4)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts&city=Seattle"), 1)
    }

    func testNewEditValueChangesRequireFreshScopeAndProposal() async throws {
        let boundaries: [ComputerUseBrowserDOMCommand?] = [nil, .extendFormFields, .bindPageFields, .prepareFormPreservation]
        for boundary in boundaries {
            let fixture = try await make(category: true, city: true, mutation: "document.getElementById('city').value='Portland';")
            defer { fixture.close() }
            let (_, original) = try await preparePhysicalCity(fixture, interrupting: boundary), owner = try fixture.owner()
            let history = owner.confirmedFormHistory, writes = fixture.state.writes
            try await release(fixture)
            if boundary != nil { try await owner.resumeAfterUserControl() }
            let recovered = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(recovered); XCTAssertTrue(owner.needsFormPreparationReview)
            XCTAssertEqual(owner.confirmedFormHistory, history); XCTAssertEqual(fixture.state.writes, writes)
            await expectFailure { _ = try await owner.resumeFormPreparation() }
            configureMixed(fixture, editing: ["Query"], retaining: ["Category"], deferring: ["City"])
            await expectFailure { _ = try await owner.reviewFormPreparation(using: fixture.actions) }
            let next = try await repairRetainPreparation(fixture, editing: ["City"], retaining: ["Query","Category"])
            let city = try XCTUnwrap(next.evidence.fields.first { $0.control.label == "City" })
            XCTAssertEqual(city.editable.snapshot.value, "Portland")
            XCTAssertNil(next.previous?.finalValues[city.editable.snapshot.targetID])
            XCTAssertEqual(try XCTUnwrap(next.preparationBaseline).refreshedTargetIDs, [city.editable.snapshot.targetID])
            XCTAssertEqual(next.requiredRepairFieldAliases.count, 1)
            XCTAssertTrue(next.contextJSON.contains("refreshed_edit_fields")); XCTAssertFalse(next.contextJSON.contains("Portland"))
            if let original { XCTAssertTrue(try XCTUnwrap(original.evidence.fields.first { $0.control.label == "City" }).editable.snapshot.value.isEmpty) }
            _ = try await owner.executeForm(.decode(content: mixedContent(next, order: ["City"]), input: next), input: next)
            XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [2,1])
            XCTAssertEqual(owner.confirmedFormHistory.map(\.retainedCriterionCount), [0,0])
            XCTAssertEqual(fixture.state.commands.filter { $0 == .extendFormFields }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 3)
        }
    }

    func testFreshEditAndVerifiedCriterionRepairsKeepSeparateOrigins() async throws {
        for observed in [false, true] {
            let fixture = try await make(category: true, city: true, queryAlreadyMatches: observed, categoryAlreadyMatches: observed,
                mutation: "document.getElementById('query').value='reset';document.getElementById('city').value='Portland';")
            defer { fixture.close() }
            let (_, prepared) = try await preparePhysicalCity(fixture), original = try XCTUnwrap(prepared), owner = try fixture.owner()
            let history = owner.confirmedFormHistory
            try await release(fixture)
            let recovered = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(recovered); XCTAssertEqual(owner.confirmedFormHistory, history)
            let next = try await repairRetainPreparation(fixture, editing: ["Query","City"], retaining: ["Category"])
            let city = try XCTUnwrap(next.evidence.fields.first { $0.control.label == "City" })
            let query = try XCTUnwrap(next.evidence.fields.first { $0.control.label == "Query" })
            XCTAssertEqual(next.previous, original.previous)
            XCTAssertEqual(next.previous?.finalValues[query.editable.snapshot.targetID], "concerts")
            XCTAssertNil(next.previous?.finalValues[city.editable.snapshot.targetID])
            XCTAssertEqual(try XCTUnwrap(next.preparationBaseline).refreshedTargetIDs, [city.editable.snapshot.targetID])
            XCTAssertEqual(next.requiredRepairFieldAliases.count, 2)
            _ = try await owner.executeForm(.decode(content: mixedContent(next, order: ["Query","City"]), input: next), input: next)
            XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [observed ? 0 : 2,2])
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, observed ? 2 : 4)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, observed ? 1 : 0)
        }
    }

    func testRefreshedEditAlreadyMatchingTheGoalNeedsAFreshProofWithoutInput() async throws {
        let fixture = try await make(category: true, city: true, mutation: "document.getElementById('city').value='Seattle';")
        defer { fixture.close() }
        _ = try await preparePhysicalCity(fixture)
        let owner = try fixture.owner(), history = owner.confirmedFormHistory
        try await release(fixture)
        let recovered = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertTrue(recovered); XCTAssertEqual(owner.confirmedFormHistory, history)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, 0)
        let next = try await repairRetainPreparation(fixture, editing: ["City"], retaining: ["Query","Category"])
        XCTAssertEqual(next.requiredRepairFieldAliases.count, 1)
        XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: #"{"retain":true}"#, input: next))
        _ = try await owner.executeForm(.decode(content: mixedContent(next, order: ["City"]), input: next), input: next)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [2,0])
        XCTAssertEqual(owner.confirmedFormHistory.map(\.verifiedWithoutInputCount), [0,1])
        XCTAssertEqual(owner.confirmedFormHistory.map(\.retainedCriterionCount), [0,0])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, 1)
    }

    func testNewEditRefreshCannotReplaceAnEarlierUnverifiedInvariant() async throws {
        let fixture = try await make(category: true, city: true, mutation: "document.getElementById('city').value='Portland';")
        defer { fixture.close() }
        let (captured, _) = try await prepareMixed(fixture), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: captured)
        configureAnsweredRetentionRevision(fixture, editing: ["Query","Category"], retaining: [])
        let fallback = fixture.actions.select
        fixture.actions.select = { input in
            if let review = try FormEffectScopeFixture.response(input, editing: ["Query":[0],"Category":[0]],
                deferring: ["City":[0]], preserving: ["Reference":0]) { return review }
            return try XCTUnwrap(fallback)(input)
        }
        let action = try await owner.reviewFormPreparation(using: fixture.actions), first = try await owner.applyFormPreparationReview(action)
        _ = try await owner.executeForm(.decode(content: mixedContent(first, order: ["Query","Category"]), input: first), input: first)
        configureAnsweredRetentionRevision(fixture, editing: ["City"], retaining: ["Query","Category"])
        let nextAction = try await owner.planNextAction(using: fixture.actions), next = try await owner.prepareFormInput(for: nextAction)
        let city = try XCTUnwrap(next.evidence.fields.first { $0.control.label == "City" }).editable.snapshot
        XCTAssertEqual(next.previous?.finalValues[city.targetID], "")
        XCTAssertFalse(try XCTUnwrap(next.previous).verifiedTargetIDs.contains(city.targetID))
        let history = owner.confirmedFormHistory
        try await release(fixture)
        await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
        XCTAssertFalse(owner.needsFormPreparationReview); XCTAssertTrue(owner.hasPendingFormPreparation)
        XCTAssertEqual(owner.confirmedFormHistory, history)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testNewEditRefreshRequiresHandbackBeforePublishingItsReview() async throws {
        for (boundary, occurrence) in [(ComputerUseBrowserDOMCommand.bindPageFields,1), (.inspectFormRequirements,2)] {
            let fixture = try await make(category: true, city: true, mutation: "document.getElementById('city').value='Portland';")
            defer { fixture.close() }
            _ = try await preparePhysicalCity(fixture)
            let owner = try fixture.owner(), history = owner.confirmedFormHistory, writes = fixture.state.writes
            try await release(fixture)
            var seen = 0
            fixture.state.onCommand = { command in
                guard command == boundary else { return }; seen += 1
                guard seen == occurrence else { return }; fixture.state.onCommand = nil; owner.pause()
            }
            await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
            XCTAssertFalse(owner.needsFormPreparationReview)
            let commands = fixture.state.commands
            await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
            XCTAssertEqual(fixture.state.commands, commands)
            try await owner.resumeAfterUserControl()
            let recovered = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(recovered); XCTAssertTrue(owner.needsFormPreparationReview)
            XCTAssertEqual(owner.confirmedFormHistory, history); XCTAssertEqual(fixture.state.writes, writes)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        }
    }

    func testNewEditRefreshCannotReconstructLostEarlierNativeOrigins() async throws {
        for observed in [false, true] {
            let fixture = try await make(category: true, city: true, queryAlreadyMatches: observed, categoryAlreadyMatches: observed,
                mutation: "document.getElementById('city').value='Portland';")
            defer { fixture.close() }
            let (_, prepared) = try await preparePhysicalCity(fixture), original = try XCTUnwrap(prepared), owner = try fixture.owner()
            let history = owner.confirmedFormHistory
            try await release(fixture)
            let recovered = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(recovered)
            configureMixed(fixture, editing: ["City"], retaining: ["Query","Category"])
            let action = try await owner.reviewFormPreparation(using: fixture.actions)
            let other = ComputerUseBrowserTextTarget(browser: fixture.browser, document: original.evidence.page.document, requiresFrontmost: false)
            _ = try await other.fields()
            await expectFailure { _ = try await owner.applyFormPreparationReview(action) }
            XCTAssertTrue(owner.hasPendingFormPreparation); XCTAssertEqual(owner.confirmedFormHistory, history)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, observed ? 0 : 2)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, observed ? 1 : 0)
        }
    }

    func testRefreshedEditKeepsItsNewSnapshotStrictBeforeExecution() async throws {
        let mutation = "document.getElementById('city').value='Portland';fetch('/signal').then(()=>{document.getElementById('city').value='Tacoma';fetch('/restored');});"
        let fixture = try await make(category: true, city: true, mutation: mutation)
        defer { fixture.close() }
        _ = try await preparePhysicalCity(fixture)
        let owner = try fixture.owner(), history = owner.confirmedFormHistory
        try await release(fixture)
        let recovered = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertTrue(recovered)
        let next = try await repairRetainPreparation(fixture, editing: ["City"], retaining: ["Query","Category"])
        let proposal = try ComputerUseBrowserFormProposal.decode(content: mixedContent(next, order: ["City"]), input: next)
        try await releaseSecondSignal(fixture)
        await expectFailure { _ = try await owner.executeForm(proposal, input: next) }
        XCTAssertEqual(owner.confirmedFormHistory, history)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testDriverRefreshesNewEditPreconditionsAfterAStalePlannerReply() async throws {
        let fixture = try await make(category: true, city: true, mutation: "document.getElementById('city').value='Portland';")
        defer { fixture.close() }
        _ = try await preparePhysicalCity(fixture)
        let owner = try fixture.owner()
        configureMixed(fixture, editing: ["City"], retaining: ["Query","Category"], querying: true)
        var calls = 0
        fixture.forms.select = { input in
            calls += 1
            XCTAssertEqual(input.requiredRepairFieldAliases.count, calls == 1 ? 0 : 1)
            return try self.mixedContent(input, order: ["City"])
        }
        fixture.forms.beforeReply = {
            fixture.forms.beforeReply = nil
            try await self.release(fixture)
        }
        _ = try await fixture.resume()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [2,1])
        XCTAssertEqual(owner.confirmedFormHistory.map(\.retainedCriterionCount), [0,0])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 3)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&category=concerts&city=Seattle"), 1)
    }

    func testNewEditRefreshKeepsAnAnswerAcrossAnUnstartedRevision() async throws {
        let fixture = try await make(category: true, city: true, mutation: "document.getElementById('city').value='Portland';")
        defer { fixture.close() }
        let (_, prepared) = try await preparePhysicalCity(fixture), original = try XCTUnwrap(prepared), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: original)
        configureAnsweredRetentionRevision(fixture, editing: ["City"], retaining: ["Query","Category"])
        let action = try await owner.reviewFormPreparation(using: fixture.actions)
        fixture.state.onCommand = { command in
            guard command == .pageSnapshot else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.applyFormPreparationReview(action) }
        try await release(fixture)
        try await owner.resumeAfterUserControl()
        let recovered = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertTrue(recovered); XCTAssertTrue(owner.needsFormPreparationReview)
        let fresh = try await owner.reviewFormPreparation(using: fixture.actions)
        let cityID = try XCTUnwrap(fresh.input.evidence.page.controls.first { $0.label == "City" }?.id)
        XCTAssertEqual(fresh.input.preparationReview?.requiredEditControlIDs, [cityID])
        let next = try await owner.applyFormPreparationReview(fresh)
        XCTAssertEqual(next.interpretation.input.clarifications.map(\.answer), ["Tomorrow."])
        XCTAssertEqual(next.previous, original.previous)
        _ = try await owner.executeForm(.decode(content: mixedContent(next, order: ["City"]), input: next), input: next)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [2,1])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
    }

    func testInitialPreparationRefreshCreatesOnlyTheFirstRealStage() async throws {
        let boundaries: [ComputerUseBrowserDOMCommand?] = [nil, .formFields, .bindPageFields, .prepareFormPreservation]
        for boundary in boundaries {
            let fixture = try await make(mutation: "document.getElementById('query').value='reset';")
            defer { fixture.close() }
            let original = try await prepareInitialCapture(fixture, interrupting: boundary), owner = try fixture.owner()
            let writes = fixture.state.writes
            try await release(fixture)
            if boundary != nil { try await owner.resumeAfterUserControl() }
            let recovered = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(recovered); XCTAssertTrue(owner.needsFormPreparationReview)
            XCTAssertTrue(owner.confirmedFormHistory.isEmpty); XCTAssertEqual(fixture.state.writes, writes)
            if let original {
                await expectFailure { _ = try await owner.executeForm(.decode(content: mixedContent(original, order: ["Query"]), input: original), input: original) }
                XCTAssertTrue(try XCTUnwrap(original.evidence.fields.first { $0.control.label == "Query" }).editable.snapshot.value.isEmpty)
            }
            let next = try await repairRetainPreparation(fixture, editing: ["Query"], retaining: [])
            XCTAssertNil(next.previous); XCTAssertEqual(next.requiredRepairFieldAliases.count, 1)
            let query = try XCTUnwrap(next.evidence.fields.first { $0.control.label == "Query" }).editable.snapshot
            XCTAssertEqual(query.value, "reset")
            XCTAssertEqual(try XCTUnwrap(next.preparationBaseline).refreshedTargetIDs, [query.targetID])
            _ = try await owner.executeForm(.decode(content: mixedContent(next, order: ["Query"]), input: next), input: next)
            XCTAssertEqual(owner.confirmedFormHistory.map(\.index), [0])
            XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [1])
            XCTAssertEqual(owner.confirmedFormHistory.map(\.retainedCriterionCount), [0])
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, 0)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
        }
    }

    func testInitialValueAndCaretRefreshRequireFreshProofWhenAlreadyMatching() async throws {
        for (matching, mutation) in [(false, "document.getElementById('query').value='concerts';"),
                                     (true, "document.getElementById('query').setSelectionRange(1,1);")] {
            let fixture = try await make(queryAlreadyMatches: matching, mutation: mutation)
            defer { fixture.close() }
            _ = try await prepareInitialCapture(fixture)
            let owner = try fixture.owner()
            try await release(fixture)
            let recovered = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(recovered); XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, 0)
            let next = try await repairRetainPreparation(fixture, editing: ["Query"], retaining: [])
            XCTAssertNil(next.previous); XCTAssertEqual(next.requiredRepairFieldAliases.count, 1)
            XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: #"{"retain":true}"#, input: next))
            _ = try await owner.executeForm(.decode(content: mixedContent(next, order: ["Query"]), input: next), input: next)
            XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [0])
            XCTAssertEqual(owner.confirmedFormHistory.map(\.verifiedWithoutInputCount), [1])
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, 1)
        }
    }

    func testUnstartedInitialCaptureUsesItsFirstObservationWithoutInventingARefresh() async throws {
        let fixture = try await make(mutation: "document.getElementById('query').value='reset';")
        defer { fixture.close() }
        _ = try await prepareInitialCapture(fixture, interrupting: .pageSnapshot)
        let owner = try fixture.owner()
        try await release(fixture)
        try await owner.resumeAfterUserControl()
        let recovered = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertFalse(recovered); XCTAssertFalse(owner.needsFormPreparationReview)
        let input = try await owner.resumeFormPreparation()
        XCTAssertNil(input.previous); XCTAssertNil(input.preparationBaseline)
        XCTAssertEqual(input.evidence.fields.first { $0.control.label == "Query" }?.editable.snapshot.value, "reset")
        XCTAssertTrue(input.requiredRepairFieldAliases.isEmpty)
        _ = try await owner.executeForm(.decode(content: mixedContent(input, order: ["Query"]), input: input), input: input)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [1])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 0)
    }

    func testInitialRefreshKeepsPreservationMetadataAndObjectsStrict() async throws {
        for readonly in [false, true] {
            for mutation in ["document.getElementById('query').value='reset';document.getElementById('reference').value='changed';",
                             "document.getElementById('query').outerHTML=document.getElementById('query').outerHTML;",
                             "document.getElementById('query').value='reset';document.getElementById('query').disabled=true;"] {
                let fixture = try await make(referenceReadOnly: readonly, mutation: mutation)
                defer { fixture.close() }
                _ = try await prepareInitialCapture(fixture, interrupting: .formFields)
                let owner = try fixture.owner(), writes = fixture.state.writes
                try await release(fixture)
                try await owner.resumeAfterUserControl()
                await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
                XCTAssertFalse(owner.needsFormPreparationReview); XCTAssertTrue(owner.hasPendingFormPreparation)
                XCTAssertTrue(owner.confirmedFormHistory.isEmpty); XCTAssertEqual(fixture.state.writes, writes)
                XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
                XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
            }
        }
    }

    func testInitialRefreshRejectsExistingNativeInputOrProofHistory() async throws {
        for observed in [false, true] {
            let fixture = try await make(category: true, queryAlreadyMatches: observed,
                mutation: "document.getElementById('query').value='reset';")
            defer { fixture.close() }
            let (frame, input, plan) = try await statePreparation(fixture)
            XCTAssertNil(input.previous)
            if observed {
                let proof = try await verifyState(fixture, frame: frame, input: input, plan: plan)
                XCTAssertNotNil(proof)
            } else {
                let stage = try await executeStandalone(fixture, frame: frame, input: input)
                XCTAssertNotNil(stage.nativeReceipt)
            }
            try await release(fixture)
            let writes = fixture.state.writes
            await expectFailure { _ = try await frame.recoverCriteriaForReview(browser: fixture.browser, checkCurrent: {}) }
            XCTAssertFalse(frame.needsCriteriaReview); XCTAssertEqual(fixture.state.writes, writes)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, observed ? 0 : 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, observed ? 1 : 0)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 0)
        }
    }

    func testInitialRefreshRechecksItsEmptyLedgerAfterFreshReview() async throws {
        let fixture = try await make(mutation: "document.getElementById('query').value='reset';")
        defer { fixture.close() }
        let captured = try await prepareInitialCapture(fixture), original = try XCTUnwrap(captured), owner = try fixture.owner()
        try await release(fixture)
        let recovered = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertTrue(recovered)
        configureMixed(fixture, editing: ["Query"])
        let action = try await owner.reviewFormPreparation(using: fixture.actions)
        let other = ComputerUseBrowserTextTarget(browser: fixture.browser, document: original.evidence.page.document, requiresFrontmost: false)
        _ = try await other.fields()
        await expectFailure { _ = try await owner.applyFormPreparationReview(action) }
        XCTAssertTrue(owner.hasPendingFormPreparation); XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, 0)
    }

    func testInitialRefreshRequiresHandbackBeforePublishingEmptyHistory() async throws {
        for (boundary, occurrence) in [(ComputerUseBrowserDOMCommand.inspectFormRequirements,1), (.bindPageFields,1), (.inspectFormRequirements,2)] {
            let fixture = try await make(mutation: "document.getElementById('query').value='reset';")
            defer { fixture.close() }
            _ = try await prepareInitialCapture(fixture)
            let owner = try fixture.owner(), writes = fixture.state.writes
            try await release(fixture)
            var seen = 0
            fixture.state.onCommand = { command in
                guard command == boundary else { return }; seen += 1
                guard seen == occurrence else { return }; fixture.state.onCommand = nil; owner.pause()
            }
            await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
            XCTAssertFalse(owner.needsFormPreparationReview)
            let commands = fixture.state.commands
            await expectFailure { _ = try await owner.recoverPendingFormPreparationCriteria() }
            XCTAssertEqual(fixture.state.commands, commands)
            try await owner.resumeAfterUserControl()
            let recovered = try await owner.recoverPendingFormPreparationCriteria()
            XCTAssertTrue(recovered); XCTAssertTrue(owner.needsFormPreparationReview)
            XCTAssertTrue(owner.confirmedFormHistory.isEmpty); XCTAssertEqual(fixture.state.writes, writes)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        }
    }

    func testInitialRefreshKeepsAnAnswerThroughAnUnstartedRevision() async throws {
        let fixture = try await make(mutation: "document.getElementById('query').value='reset';")
        defer { fixture.close() }
        let captured = try await prepareInitialCapture(fixture), original = try XCTUnwrap(captured), owner = try fixture.owner()
        _ = try await beginPreparationReview(fixture, input: original)
        configureAnsweredRetentionRevision(fixture, editing: ["Query"], retaining: [])
        let action = try await owner.reviewFormPreparation(using: fixture.actions)
        fixture.state.onCommand = { command in
            guard command == .pageSnapshot else { return }; fixture.state.onCommand = nil; owner.pause()
        }
        await expectFailure { _ = try await owner.applyFormPreparationReview(action) }
        try await release(fixture)
        try await owner.resumeAfterUserControl()
        let recovered = try await owner.recoverPendingFormPreparationCriteria()
        XCTAssertTrue(recovered)
        let fresh = try await owner.reviewFormPreparation(using: fixture.actions), next = try await owner.applyFormPreparationReview(fresh)
        XCTAssertNil(next.previous); XCTAssertEqual(next.interpretation.input.clarifications.map(\.answer), ["Tomorrow."])
        XCTAssertEqual(next.requiredRepairFieldAliases.count, 1)
        _ = try await owner.executeForm(.decode(content: mixedContent(next, order: ["Query"]), input: next), input: next)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [1])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .reviseFormFields }.count, 1)
    }

    func testDriverRefreshesTheInitialFormAfterAStalePlannerReply() async throws {
        let fixture = try await make(mutation: "document.getElementById('query').value='reset';")
        defer { fixture.close() }
        _ = try await prepareInitialCapture(fixture)
        let owner = try fixture.owner()
        configureMixed(fixture, editing: ["Query"], querying: true)
        var calls = 0
        fixture.forms.select = { input in
            calls += 1; XCTAssertNil(input.previous)
            XCTAssertEqual(input.requiredRepairFieldAliases.count, calls == 1 ? 0 : 1)
            return try self.mixedContent(input, order: ["Query"])
        }
        fixture.forms.beforeReply = { fixture.forms.beforeReply = nil; try await self.release(fixture) }
        _ = try await fixture.resume()
        XCTAssertEqual(calls, 2); XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [1])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts"), 1)
    }

    private func prepareInitialCapture(_ fixture: ResearchDriverFixture, interrupting boundary: ComputerUseBrowserDOMCommand? = nil) async throws
        -> ComputerUseBrowserResearchFormInput? {
        _ = try await fixture.start(); configureMixed(fixture, editing: ["Query"])
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        if let boundary {
            fixture.state.onCommand = { command in
                guard command == boundary else { return }; fixture.state.onCommand = nil; owner.pause()
            }
            await expectFailure { _ = try await owner.prepareFormInput(for: action) }
            XCTAssertTrue(owner.hasPendingFormPreparation)
            return nil
        }
        return try await owner.prepareFormInput(for: action)
    }

    private func preparePhysicalCity(_ fixture: ResearchDriverFixture, interrupting boundary: ComputerUseBrowserDOMCommand? = nil) async throws
        -> (ComputerUseBrowserResearchFormInput, ComputerUseBrowserResearchFormInput?) {
        let (first, proposal) = try await prepareMixed(fixture, order: ["Query","Category"], deferring: ["City"]), owner = try fixture.owner()
        _ = try await owner.executeForm(proposal, input: first)
        configureMixed(fixture, editing: ["City"], retaining: ["Query","Category"])
        let action = try await owner.planNextAction(using: fixture.actions)
        if let boundary {
            fixture.state.onCommand = { command in
                guard command == boundary else { return }; fixture.state.onCommand = nil; owner.pause()
            }
            await expectFailure { _ = try await owner.prepareFormInput(for: action) }
            XCTAssertTrue(owner.hasPendingFormPreparation)
            return (first, nil)
        }
        return (first, try await owner.prepareFormInput(for: action))
    }

    private func configureAnsweredRetentionRevision(_ fixture: ResearchDriverFixture, editing: [String], retaining: [String], querying: Bool = false) {
        configureMixed(fixture, editing: editing, retaining: retaining, querying: querying)
        let fallback = fixture.actions.select
        fixture.actions.select = { input in
            if let review = try FormEffectScopeFixture.response(input,
                editing: Dictionary(uniqueKeysWithValues: editing.map { ($0,[0]) }),
                retaining: Dictionary(uniqueKeysWithValues: retaining.map { ($0,[0]) }), preserving: ["Reference":0]) { return review }
            return try XCTUnwrap(fallback)(input)
        }
    }

    private func repairRetainPreparation(_ fixture: ResearchDriverFixture, editing: [String], retaining: [String]) async throws -> ComputerUseBrowserResearchFormInput {
        configureMixed(fixture, editing: editing, retaining: retaining)
        let owner = try fixture.owner(), action = try await owner.reviewFormPreparation(using: fixture.actions)
        return try await owner.applyFormPreparationReview(action)
    }

    private func reviseRetainPreparation(_ fixture: ResearchDriverFixture, input: ComputerUseBrowserResearchFormInput,
                                        editing: [String], retaining: [String]) async throws -> ComputerUseBrowserResearchFormInput {
        _ = try await beginPreparationReview(fixture, input: input)
        configureAnsweredRetentionRevision(fixture, editing: editing, retaining: retaining)
        let owner = try fixture.owner(), action = try await owner.reviewFormPreparation(using: fixture.actions)
        return try await owner.applyFormPreparationReview(action)
    }

    private func releaseSecondSignal(_ fixture: ResearchDriverFixture) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while fixture.server.count("/signal") != 2 {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
        fixture.server.releaseHeldResponses()
        while fixture.server.count("/restored") != 1 {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func prepareAnsweredRetention(_ fixture: ResearchDriverFixture) async throws -> ComputerUseBrowserResearchFormInput {
        let mixed = try await prepareRetainedCity(fixture), owner = try fixture.owner()
        _ = try await owner.executeForm(.decode(content: mixedContent(mixed, order: ["Query","Category"]), input: mixed), input: mixed)
        let question = try owner.issueQuestion(topic: .location, requirementIDs: [mixed.interpretation.requirements[0].id],
            controllerID: "phone", controllerSessionID: "session")
        _ = try owner.answerQuestion(questionID: question.id, answerTaskID: "retain-city-again", answer: "Keep Seattle.",
            controllerID: "phone", controllerSessionID: "session")
        let interpretation = try await owner.interpretGoal()
        try owner.configureResearchSources(XCTUnwrap(fixture.policy.sources(for: interpretation)))
        configureRetainedCity(fixture, editing: [], alsoRetaining: ["Query","Category"], cityRequirement: 4)
        let action = try await owner.planNextAction(using: fixture.actions), input = try await owner.prepareFormInput(for: action)
        return input
    }

    private func prepareRetainOnly(_ fixture: ResearchDriverFixture, deferring: [String] = []) async throws -> ComputerUseBrowserResearchFormInput {
        let (first, proposal) = try await prepareMixed(fixture, order: ["Query","Category"], deferring: deferring), owner = try fixture.owner()
        _ = try await owner.executeForm(proposal, input: first)
        configureMixed(fixture, editing: [], retaining: ["Query","Category"], deferring: deferring)
        let action = try await owner.planNextAction(using: fixture.actions)
        return try await owner.prepareFormInput(for: action)
    }

    private func prepareRetainedCity(_ fixture: ResearchDriverFixture) async throws -> ComputerUseBrowserResearchFormInput {
        _ = try await fixture.start(); configureMixed(fixture, editing: ["City"])
        let fallback = fixture.actions.select
        fixture.actions.select = { input in
            if let review = try FormEffectScopeFixture.response(input, editing: ["City":[0]],
                deferring: ["Query":[0],"Category":[0]], preserving: ["Reference":1]) { return review }
            return try XCTUnwrap(fallback)(input)
        }
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        let first = try await owner.prepareFormInput(for: action)
        _ = try await owner.executeForm(.decode(content: mixedContent(first, order: ["City"]), input: first), input: first)
        let question = try owner.issueQuestion(topic: .location, requirementIDs: [first.interpretation.requirements[0].id],
            controllerID: "phone", controllerSessionID: "session")
        _ = try owner.answerQuestion(questionID: question.id, answerTaskID: "confirm-city", answer: "Seattle.",
            controllerID: "phone", controllerSessionID: "session")
        let originalGoal = try XCTUnwrap(fixture.goal.select)
        fixture.goal.select = { input in
            var body = try ResearchAnswerFixture.object(Data(originalGoal(input).utf8))
            var rows = try XCTUnwrap(body["requirements"] as? [[String: Any]])
            rows += input.clarifications.enumerated().map { index, answer in
                ["turn":index + 1,"source":answer.answer,"role":"condition","field":"location","relation":"unspecified","values":[]]
            }
            body["requirements"] = rows
            return try ResearchAnswerFixture.json(body)
        }
        let interpretation = try await owner.interpretGoal()
        try owner.configureResearchSources(XCTUnwrap(fixture.policy.sources(for: interpretation)))
        configureRetainedCity(fixture)
        let next = try await owner.planNextAction(using: fixture.actions)
        return try await owner.prepareFormInput(for: next)
    }

    private func configureRetainedCity(_ fixture: ResearchDriverFixture, editing: [String] = ["Query","Category"],
                                       alsoRetaining: [String] = [], querying: Bool = false, cityRequirement: Int = 3) {
        configureMixed(fixture, editing: editing, retaining: alsoRetaining + ["City"], querying: querying)
        let fallback = fixture.actions.select
        fixture.actions.select = { input in
            var retaining = Dictionary(uniqueKeysWithValues: alsoRetaining.map { ($0,[0]) }); retaining["City"] = [cityRequirement]
            if let review = try FormEffectScopeFixture.response(input,
                editing: Dictionary(uniqueKeysWithValues: editing.map { ($0,[0]) }), retaining: retaining, preserving: ["Reference":1]) { return review }
            return try XCTUnwrap(fallback)(input)
        }
    }

    private func pauseAfterAllFormInputs(_ fixture: ResearchDriverFixture) async throws -> ComputerUseBrowserResearchFormInput {
        let (input, proposal) = try await prepareMixed(fixture), owner = try fixture.owner()
        let plan = try ComputerUseBrowserFormExecutionPlan(input: input, proposal: proposal,
            stageID: ComputerUseTaskContract.digest(["full-history-fixture"]))
        let pauseAt = fixture.state.writes + (plan.isMixed ? 1 : 0) + 2 * plan.contract.steps.count
        fixture.state.onWrite = { if fixture.state.writes == pauseAt { owner.pause() } }
        await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
        fixture.state.onWrite = nil
        let (_, journal) = try pendingMixedJournal(fixture)
        XCTAssertTrue(journal.statuses.allSatisfy { $0 == .verified })
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, plan.contract.steps.count)
        return input
    }

    private func failFirstMixedAttempt(_ fixture: ResearchDriverFixture) async throws -> ComputerUseBrowserResearchFormInput {
        let (input, proposal) = try await prepareMixed(fixture), owner = try fixture.owner()
        // Planned mixed contract, then first input attempt. The observation
        // between those writes has a native origin but sends no input.
        fixture.state.failureAtWrite = fixture.state.writes + 2
        do { _ = try await owner.executeForm(proposal, input: input); XCTFail("The first input attempt write must fail") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
        fixture.state.failureAtWrite = nil
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .verifyFormState }.count, 1)
        return input
    }

    private func pendingMixedJournal(_ fixture: ResearchDriverFixture) throws -> (ComputerUseTaskJournalStore, ComputerUseTaskJournal) {
        let directory = fixture.directory.appendingPathComponent("Research/Research Forms")
        let paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(paths.count, 1)
        let store = try ComputerUseTaskJournalStore(directory: XCTUnwrap(paths.first))
        return (store, try XCTUnwrap(store.load(taskID: fixture.owner().taskID)))
    }

    private func checkpointRemainder(_ fixture: ResearchDriverFixture, order: [String], remaining: [String], retaining: [String]) async throws
        -> (ComputerUseBrowserResearchFormInput, ComputerUseBrowserFormProposal) {
        let (input, proposal) = try await prepareMixed(fixture, order: order), owner = try fixture.owner()
        await expectFailure { _ = try await owner.executeForm(proposal, input: input) }
        let result = try await owner.retainPendingFormPrefix(), receipt = try XCTUnwrap(result)
        XCTAssertEqual(receipt.editCount, 1); XCTAssertFalse(receipt.isCompleteStage)
        configureMixed(fixture, editing: remaining, retaining: retaining)
        let action = try await owner.planNextAction(using: fixture.actions)
        let next = try await owner.prepareFormInput(for: action)
        return (next, try .decode(content: mixedContent(next, order: remaining), input: next))
    }

    private func standalonePreparation(_ fixture: ResearchDriverFixture) async throws
        -> (ComputerUseBrowserActionProposal, ComputerUseBrowserResearchFormPreparation, ComputerUseBrowserResearchFormInput) {
        _ = try await fixture.start(); configure(fixture, category: true)
        let action = try await fixture.owner().planNextAction(using: fixture.actions)
        let frame = try ComputerUseBrowserResearchFormPreparation(action: action, browser: fixture.browser)
        return (action, frame, try await frame.prepare(browser: fixture.browser, checkCurrent: {}))
    }

    private func configureMixed(_ fixture: ResearchDriverFixture, editing labels: [String], retaining retained: [String] = [], querying: Bool = false, deferring: [String] = []) {
        fixture.actions.select = { input in
            if let review = try FormEffectScopeFixture.response(input,
                editing: Dictionary(uniqueKeysWithValues: labels.map { ($0,[0]) }),
                retaining: Dictionary(uniqueKeysWithValues: retained.map { ($0,[0]) }),
                deferring: Dictionary(uniqueKeysWithValues: deferring.map { ($0,[0]) }), preserving: ["Reference":1]) { return review }
            if input.formEffectScope != nil && !input.effectScopeAllowsActions { return #"{"unavailable":true}"# }
            if querying, let query = input.queryControlIDs.first { return try ResearchAnswerFixture.json(["query":query]) }
            let form = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Query" }?.form?.id)
            return try ResearchAnswerFixture.json(["form":form,"preserve":[]])
        }
    }

    private func mixedContent(_ input: ComputerUseBrowserResearchFormInput, order: [String]) throws -> String {
        let aliases = try Dictionary(uniqueKeysWithValues: input.editableFieldAliases.map { (try input.field(for: $0).control.label,$0) })
        let edits: [[String: Any]] = try order.map { label in
            let alias = try XCTUnwrap(aliases[label]), field = try input.field(for: alias)
            if label == "Category" {
                let choice = try XCTUnwrap(field.control.options.first { $0.label == "Concerts" })
                return ["field":alias,"choice":choice.id,"requirement":0]
            }
            return ["field":alias,"terms":[["requirement":0,"text":label == "City" ? "Seattle" : "concerts"]]]
        }
        var body: [String: Any] = ["edits":edits,"preserve":[]]
        if !input.pendingEditAliases.isEmpty {
            let pending = try XCTUnwrap(input.previous?.pendingEdits)
            body["resume"] = try zip(input.pendingEditAliases, pending).map { id, edit in
                ["pending":id,"field":try XCTUnwrap(aliases[edit.label])]
            }
        }
        return try ResearchAnswerFixture.json(body)
    }

    private func prepareMixed(_ fixture: ResearchDriverFixture, order: [String] = ["Query","Category","City"], deferring: [String] = []) async throws
        -> (ComputerUseBrowserResearchFormInput, ComputerUseBrowserFormProposal) {
        _ = try await fixture.start(); configureMixed(fixture, editing: order, deferring: deferring)
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        let input = try await owner.prepareFormInput(for: action)
        return (input, try .decode(content: mixedContent(input, order: order), input: input))
    }

    private func statePreparation(_ fixture: ResearchDriverFixture, choosingCategory: Bool = false) async throws
        -> (ComputerUseBrowserResearchFormPreparation, ComputerUseBrowserResearchFormInput, ComputerUseBrowserFormStatePlan) {
        _ = try await fixture.start(); configure(fixture, category: true)
        if choosingCategory {
            let fallback = fixture.actions.select
            fixture.actions.select = { input in
                if let review = try FormEffectScopeFixture.response(input, editing: ["Category":[0]],
                    deferring: ["Query":[0]], preserving: ["Reference":1]) { return review }
                return try XCTUnwrap(fallback)(input)
            }
        }
        let action = try await fixture.owner().planNextAction(using: fixture.actions)
        let frame = try ComputerUseBrowserResearchFormPreparation(action: action, browser: fixture.browser)
        let input = try await frame.prepare(browser: fixture.browser, checkCurrent: {})
        let content = try choosingCategory ? categoryPlan(input) : plan(input)
        return (frame, input, try .init(input: input, proposal: .decode(content: content, input: input)))
    }

    private func verifyState(_ fixture: ResearchDriverFixture, frame: ComputerUseBrowserResearchFormPreparation,
                             input: ComputerUseBrowserResearchFormInput, plan: ComputerUseBrowserFormStatePlan,
                             capture: ComputerUseBrowserDOMReadCapture? = nil) async throws -> ComputerUseBrowserFormStateProof? {
        let page = try await frame.restoreForReview(browser: fixture.browser, checkCurrent: {})
        let retained = try capture ?? .init(command: .verifyFormState, document: page.document)
        return try await frame.target.verifyFormState(plan, input: input, page: page, retaining: retained)
    }

    private func executeStandalone(_ fixture: ResearchDriverFixture, frame: ComputerUseBrowserResearchFormPreparation,
                                   input: ComputerUseBrowserResearchFormInput) async throws -> ComputerUseBrowserResearchFormStage {
        let stage = try ComputerUseBrowserResearchFormStage(input: input, proposal: .decode(content: plan(input), input: input),
            target: frame.target, browser: fixture.browser, index: 0, journalDirectory: fixture.directory)
        _ = try await stage.run(checkCurrent: {})
        return stage
    }

    private func revise(_ fixture: ResearchDriverFixture, frame: ComputerUseBrowserResearchFormPreparation,
                        input: ComputerUseBrowserResearchFormInput, capture: ComputerUseBrowserDOMReadCapture? = nil,
                        selecting labels: [String] = ["Category"], purpose: String = "first-reviewed-scope") async throws -> [ComputerUseTextField] {
        let page = try await frame.restoreForReview(browser: fixture.browser, checkCurrent: {})
        let scope = try XCTUnwrap(input.scopeReview?.formScope)
        let selected = try labels.map { label in try XCTUnwrap(page.page.controls.first { $0.label == label }?.id) }
        let retained = try capture ?? .init(command: .reviseFormFields, document: page.document)
        return try await frame.target.reviseFields(in: frame.formID, page: page, preserving: scope.editablePreservedControlIDs,
            selecting: selected, scopeDigest: ComputerUseTaskContract.digest([purpose]), from: input, retaining: retained)
    }

    /// Execute the actual native initial revision, then inject a terminal
    /// callback failure into its host capture instead of delivering the result.
    /// The request mirrors the v1 physical preparation fixture, with no repair.
    private func lostRevisionCallback(_ fixture: ResearchDriverFixture, frame: ComputerUseBrowserResearchFormPreparation,
                                      input: ComputerUseBrowserResearchFormInput, dispatching: Bool = true, selecting labels: [String] = ["Category"]) async throws
        -> (ComputerUseBrowserDOMReadCapture, [String: Any], ComputerUseBrowserDOMReply?) {
        let page = try await frame.restoreForReview(browser: fixture.browser, checkCurrent: {})
        let scope = try XCTUnwrap(input.scopeReview?.formScope)
        let requirements = try frame.target.preparedFormRequirements(from: input)
        let scopeDigest = ComputerUseTaskContract.digest(["first-reviewed-scope"])
        let revisionID = ComputerUseTaskContract.digest(["browser-prepared-field-revision-v1",requirements.digest,scopeDigest])
        let selected = try labels.map { label in try XCTUnwrap(page.page.controls.first { $0.label == label }?.id) }
        let arguments: [String: Any] = ["documentID":page.documentID,"snapshotID":page.page.id,"formID":frame.formID,
            "preservedControlIDs":scope.editablePreservedControlIDs,"selectedControlIDs":selected,
            "scopeDigest":scopeDigest,"revisionID":revisionID,"requirements":requirements.domArguments]
        let capture = try ComputerUseBrowserDOMReadCapture(command: .reviseFormFields, document: page.document)
        try capture.begin(command: .reviseFormFields, arguments: arguments, document: page.document)
        let reply: ComputerUseBrowserDOMReply?
        if dispatching { reply = try await fixture.browser.callDOM(.reviseFormFields, arguments: arguments, document: page.document) }
        else { reply = nil }
        capture.finish(.failure(ComputerUseBrowserError.pageChanged))
        return (capture, arguments, reply)
    }

    private func beginPreparationReview(_ fixture: ResearchDriverFixture, input: ComputerUseBrowserResearchFormInput) async throws -> ComputerUseBrowserGoalProposal {
        let owner = try fixture.owner()
        _ = try answerPreparedQuestion(owner, input: input)
        fixture.goal.select = nil
        let interpretation = try await owner.interpretGoal()
        let sources = try XCTUnwrap(try fixture.policy.sources(for: interpretation))
        try owner.configureResearchSources(sources)
        return interpretation.proposal
    }

    private func answerPreparedQuestion(_ owner: ComputerUseBrowserResearchTask, input: ComputerUseBrowserResearchFormInput) throws -> ComputerUseBrowserGoalInput {
        let question = try owner.issueQuestion(topic: .date, requirementIDs: [input.interpretation.requirements[0].id],
            controllerID: "phone", controllerSessionID: "session")
        return try owner.answerQuestion(questionID: question.id, answerTaskID: "first-answer", answer: "Tomorrow.",
            controllerID: "phone", controllerSessionID: "session")
    }

    private func prepareLaterAction(_ fixture: ResearchDriverFixture) async throws
        -> (ComputerUseBrowserResearchFormInput, ComputerUseBrowserActionProposal) {
        let (first, proposal) = try await prepare(fixture, category: true), owner = try fixture.owner()
        _ = try await owner.executeForm(proposal, input: first)
        configure(fixture, category: true, revising: true)
        return (first, try await owner.planNextAction(using: fixture.actions))
    }

    private func categoryPlan(_ input: ComputerUseBrowserResearchFormInput) throws -> String {
        let alias = try XCTUnwrap(input.editableFieldAliases.first), field = try input.field(for: alias)
        XCTAssertEqual(field.control.label, "Category")
        let choice = try XCTUnwrap(field.control.options.first { $0.label == "Concerts" })
        return try ResearchAnswerFixture.json(["edits":[["field":alias,"choice":choice.id,"requirement":0]],"preserve":[]])
    }

    private func make(inside: Bool = false, notes: Bool = false, category: Bool = false, prohibition: Bool = false, referenceReadOnly: Bool = true, city: Bool = false,
                      queryAlreadyMatches: Bool = false, categoryAlreadyMatches: Bool = false,
                      handler: String = "", categoryHandler: String = "", cityHandler: String = "", mutation: String = "") async throws -> ResearchDriverFixture {
        let reference = "<label>Reference<input id=reference \(referenceReadOnly ? "readonly" : "") value='private-reference'></label>"
        let categoryHTML = category ? "<label>Category<select name=category><option value=all>All</option><option value=concerts \(categoryAlreadyMatches ? "selected" : "")>Concerts</option></select></label>" : ""
        let cityHTML = city ? "<label>City<input id=city name=city></label>" : ""
        let goalSource = city ? "Find concerts in Seattle. " : "Find concerts. "
        let clause = prohibition ? "Do not change Reference. " : (notes ? "Leave Reference and Notes unchanged. " : "Leave Reference unchanged. ")
        let body = "<form action='/filtered'><label>Query<input id=query name=q value='\(queryAlreadyMatches ? "concerts" : "")'></label>" + categoryHTML + cityHTML + (inside ? reference : "")
            + "<button>Search</button></form>" + (inside ? "" : reference)
            + (notes ? "<label>Notes<input value='private-notes'></label>" : "")
            + "<script>document.getElementById('query').addEventListener('input',()=>{ \(handler) }); document.querySelector('select')?.addEventListener('input',()=>{ \(categoryHandler) }); document.getElementById('city')?.addEventListener('input',()=>{ \(cityHandler) }); fetch('/signal').then(()=>{ \(mutation) fetch('/changed'); });</script>"
        let fixture = try await ResearchDriverFixture.make(request: goalSource + clause + "Do not buy.", searchFormHTML: body, heldSignal: true)
        fixture.goal.select = { _ in try ResearchAnswerFixture.json(["disposition":"research","requirements":[
            ["turn":0,"source":goalSource,"role":"outcome","field":"category","relation":"unspecified","values":[]],
            ["turn":0,"source":clause,"role":prohibition ? "prohibition" : "condition","field":"other","relation":"unspecified","values":[]],
            ["turn":0,"source":"Do not buy.","role":"prohibition","field":"other","relation":"unspecified","values":[]]],
            "question":["topic":"none","requirements":[]]]) }
        fixture.policy.choices = [false]
        return fixture
    }

    private func configure(_ fixture: ResearchDriverFixture, notes: Bool = false, category: Bool = false,
                           revising: Bool = false, querying: Bool = false) {
        fixture.actions.select = { input in
            if let review = try FormEffectScopeFixture.response(input, editing: revising ? ["Category":[0]] : ["Query":[0]],
                retaining: revising ? ["Query":[0]] : [:], deferring: category && !revising ? ["Category":[0]] : [:],
                preserving: notes ? ["Reference":1,"Notes":1] : ["Reference":1]) { return review }
            if input.formEffectScope != nil && !input.effectScopeAllowsActions { return #"{"unavailable":true}"# }
            if querying, let query = input.queryControlIDs.first { return try ResearchAnswerFixture.json(["query":query]) }
            let form = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Query" }?.form?.id)
            return try ResearchAnswerFixture.json(["form":form,"preserve":[]])
        }
    }
    private func prepare(_ fixture: ResearchDriverFixture, notes: Bool = false, category: Bool = false) async throws
        -> (ComputerUseBrowserResearchFormInput, ComputerUseBrowserFormProposal) {
        _ = try await fixture.start(); configure(fixture, notes: notes, category: category)
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        let input = try await owner.prepareFormInput(for: action)
        return (input, try .decode(content: plan(input), input: input))
    }
    private func plan(_ input: ComputerUseBrowserResearchFormInput) throws -> String {
        let alias = try XCTUnwrap(input.editableFieldAliases.first)
        return try ResearchAnswerFixture.json(["edits":[["field":alias,"terms":[["requirement":0,"text":"concerts"]]]],"preserve":[]])
    }
    private func forgedBinding(_ input: ComputerUseBrowserResearchFormInput, value: String, purpose: String? = nil) throws -> ComputerUseBrowserFormPreservation {
        let binding = try XCTUnwrap(input.nativePreservation), id = try XCTUnwrap(binding.controlIDs.first)
        let state = ComputerUseBrowserControlState(controlID: id, kind: .text, value: value, selectedOptionIDs: nil, checked: nil, indeterminate: nil)
        return try .init(reply: .init(id: binding.id, scopeDigest: purpose ?? binding.scopeDigest, controlIDs: binding.controlIDs, states: [state]),
            evidence: input.evidence.page, inputLedgerID: binding.inputLedgerID, scopeDigest: purpose ?? binding.scopeDigest, controlIDs: binding.controlIDs)
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
    private func expectFailure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Preservation must remain enforced", file: file, line: line) } catch { }
    }
}

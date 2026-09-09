import Foundation
import XCTest
@testable import RemoteDesktopHost

/// Authored decisions and native fixture coverage, prepared but not executed.
@MainActor
final class ComputerUseBrowserResearchPreservationTests: XCTestCase {
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

    func testOnlyAnEmptyAuthenticationReplyCanReleaseAnUnobservedCapture() async throws {
        let fixture = try await ControlStateFixture(body: "<p>Metadata only</p>")
        defer { fixture.close() }
        let capture = try ComputerUseBrowserDOMReadCapture(command: .prepareFormPreservation, document: fixture.document)
        try capture.begin(command: .prepareFormPreservation, arguments: [:], document: fixture.document)
        let empty = #"{"status":"authentication-required","documentID":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#
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

    private func configureMixed(_ fixture: ResearchDriverFixture, editing labels: [String], retaining retained: [String] = [], querying: Bool = false) {
        fixture.actions.select = { input in
            if let review = try FormEffectScopeFixture.response(input,
                editing: Dictionary(uniqueKeysWithValues: labels.map { ($0,[0]) }),
                retaining: Dictionary(uniqueKeysWithValues: retained.map { ($0,[0]) }), preserving: ["Reference":1]) { return review }
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

    private func prepareMixed(_ fixture: ResearchDriverFixture, order: [String] = ["Query","Category","City"]) async throws
        -> (ComputerUseBrowserResearchFormInput, ComputerUseBrowserFormProposal) {
        _ = try await fixture.start(); configureMixed(fixture, editing: order)
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
                      handler: String = "", categoryHandler: String = "", mutation: String = "") async throws -> ResearchDriverFixture {
        let reference = "<label>Reference<input id=reference \(referenceReadOnly ? "readonly" : "") value='private-reference'></label>"
        let categoryHTML = category ? "<label>Category<select name=category><option value=all>All</option><option value=concerts \(categoryAlreadyMatches ? "selected" : "")>Concerts</option></select></label>" : ""
        let cityHTML = city ? "<label>City<input id=city name=city></label>" : ""
        let goalSource = city ? "Find concerts in Seattle. " : "Find concerts. "
        let clause = prohibition ? "Do not change Reference. " : (notes ? "Leave Reference and Notes unchanged. " : "Leave Reference unchanged. ")
        let body = "<form action='/filtered'><label>Query<input id=query name=q value='\(queryAlreadyMatches ? "concerts" : "")'></label>" + categoryHTML + cityHTML + (inside ? reference : "")
            + "<button>Search</button></form>" + (inside ? "" : reference)
            + (notes ? "<label>Notes<input value='private-notes'></label>" : "")
            + "<script>document.getElementById('query').addEventListener('input',()=>{ \(handler) }); document.querySelector('select')?.addEventListener('input',()=>{ \(categoryHandler) }); fetch('/signal').then(()=>{ \(mutation) fetch('/changed'); });</script>"
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

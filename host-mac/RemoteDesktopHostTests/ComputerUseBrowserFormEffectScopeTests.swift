import Foundation
import XCTest
@testable import RemoteDesktopHost

/// Prepared regression coverage; no assertions have executed in this repair.
@MainActor
final class ComputerUseBrowserFormEffectScopeTests: XCTestCase {
    func testOutsidePreservationIsReviewedBeforeAnyPrivateFormDiscovery() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        _ = try await fixture.start(); configure(fixture)
        let owner = try fixture.owner(), original = owner.input
        let action = try await owner.planNextAction(using: fixture.actions)
        guard case .editForm = action.step else { return XCTFail("Review should release the selected search form") }
        XCTAssertEqual(action.preservedControls.map(\.requirementIndex), [1])
        XCTAssertTrue(action.input.effectScopeAllowsActions); XCTAssertNotNil(action.input.formEffectScope)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .fields }.count, 0)
        let parts = fixture.actions.inputs.filter { $0.formEffectScope != nil }
        XCTAssertEqual(parts.count, 5)
        XCTAssertTrue(parts.allSatisfy { !$0.contextJSON.contains("private-reference") && !$0.contextJSON.contains("private-notes") })
        let prepared = try await owner.prepareFormInput(for: action)
        XCTAssertEqual(Set(prepared.evidence.fields.map { $0.control.label }), ["Query","Reference"])
        XCTAssertEqual(prepared.requiredPreservation.count, 1); XCTAssertNotNil(prepared.scopeReview)
        XCTAssertFalse(prepared.contextJSON.contains("private-reference")); XCTAssertFalse(prepared.contextJSON.contains("private-notes"))
        XCTAssertEqual(owner.input, original); XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testUnsupportedPreservationInsideOrOutsideTheFormCannotDisappear() async throws {
        for inside in [false, true] {
            let reference = "<label>Reference<input type=email readonly value='private-reference@example.test'></label>"
            let body = "<form action='/filtered'><label>Query<input name=q></label>" + (inside ? reference : "")
                + "<button>Search</button></form>" + (inside ? "" : reference)
            let fixture = try await make(body: body)
            defer { fixture.close() }
            _ = try await fixture.start(); configure(fixture)
            let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
            XCTAssertEqual(action.step, .unavailable)
            XCTAssertTrue(action.input.effectAdditionalPreservationControlIDs.isEmpty)
            XCTAssertFalse(action.input.effectScopeAllowsActions)
            do { _ = try await owner.prepareFormInput(for: action); XCTFail("Unsupported preservation is not a form action") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserActionPlanError, .invalidProposal) }
            XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .edit }.count, 0)
            XCTAssertFalse(action.input.contextJSON.contains("private-reference"))
        }
    }

    func testQueryReadsAnUnconstrainedCriterionThenRequiresAFinalValueDecision() async throws {
        let fixture = try await prepared(city: "Paris")
        defer { fixture.close() }
        let owner = try fixture.owner(), before = fixture.actions.inputs.count
        configure(fixture, querying: true)
        let action = try await owner.planNextAction(using: fixture.actions)
        guard case .openQuery = action.step else { return XCTFail("The current city reading should justify querying") }
        let queried = fixture.actions.inputs.dropFirst(before).filter { $0.formEffectScope?.queryControlID != nil }
        XCTAssertGreaterThanOrEqual(queried.count, 4)
        XCTAssertTrue(queried.first?.queryControlIDs.isEmpty == true)
        XCTAssertFalse(try XCTUnwrap(queried.first).contextJSON.contains("Paris"), "The input value is initially unread")
        XCTAssertTrue(action.input.contextJSON.contains("Paris")); XCTAssertFalse(action.input.contextJSON.contains("private-notes"))
        XCTAssertEqual(action.input.optionReadControls.count, 1)
        XCTAssertEqual(queried.last, action.input, "The final query is a model decision on the fully reviewed value reading")
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&city=Paris"), 0)
        _ = try await owner.openFormQuery(for: action)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&city=Paris"), 1)
        XCTAssertEqual(owner.confirmedFormHistory.count, 1); XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testNewlyReadConflictingQueryCriterionDoesNotAutoSubmit() async throws {
        let fixture = try await prepared(city: "Oxford")
        defer { fixture.close() }
        configure(fixture, querying: true, rejectCity: "Oxford")
        let owner = try fixture.owner(), original = owner.input, action = try await owner.planNextAction(using: fixture.actions)
        XCTAssertEqual(action.step, .unavailable)
        XCTAssertTrue(action.input.contextJSON.contains("Oxford")); XCTAssertTrue(action.input.effectScopeAllowsActions)
        XCTAssertEqual(owner.input, original); XCTAssertEqual(owner.confirmedFormHistory.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .prepareFormQuery }.count, 0)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&city=Oxford"), 0)
    }

    func testPotentiallySubmittedUnconstrainedValuesCannotBeCalledUnrelated() async throws {
        let fixture = try await prepared(city: "Paris")
        defer { fixture.close() }
        configure(fixture, querying: true)
        _ = try await fixture.owner().planNextAction(using: fixture.actions)
        let input = try XCTUnwrap(fixture.actions.inputs.first { !$0.effectQueryValueControlIDs.isEmpty })
        let city = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "City" }?.id)
        XCTAssertTrue(input.effectQueryValueControlIDs.contains(city)); XCTAssertTrue(input.queryControlIDs.isEmpty)
        let rows = try FormEffectScopeFixture.rows(input, relevant: [:], unrelated: ["City","Private notes"])
        XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: ResearchAnswerFixture.json(["review_controls":rows]), input: input))
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&city=Paris"), 0)
    }

    func testPauseDuringFormReviewRequiresFreshScopeAfterHandback() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        _ = try await fixture.start(); configure(fixture)
        let owner = try fixture.owner(), original = owner.input
        fixture.actions.beforeReply = {
            guard fixture.actions.inputs.last?.formEffectScope != nil else { return }
            fixture.actions.beforeReply = nil; owner.pause()
        }
        do { _ = try await owner.planNextAction(using: fixture.actions); XCTFail("Cancelled review cannot authorize discovery") }
        catch { XCTAssertTrue(error is CancellationError) }
        let old = try XCTUnwrap(fixture.actions.inputs.last)
        XCTAssertFalse(owner.isOperating); XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 0)
        try await owner.resumeAfterUserControl()
        let action = try await owner.planNextAction(using: fixture.actions)
        XCTAssertNotEqual(action.input.evidence.page.id, old.evidence.page.id)
        XCTAssertEqual(owner.input, original); XCTAssertTrue(action.input.effectScopeAllowsActions)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .edit }.count, 0)
    }

    func testFormReviewDeadlineJoinsOutstandingPlanningWithoutDiscovery() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        _ = try await fixture.start(); configure(fixture)
        let owner = try fixture.owner()
        var waiting = false, cancelled = false
        fixture.actions.beforeReply = {
            guard fixture.actions.inputs.last?.formEffectScope != nil else { return }
            waiting = true; defer { waiting = false }
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled = error is CancellationError; throw error }
        }
        do { _ = try await owner.planNextAction(using: fixture.actions, budget: .seconds(1)); XCTFail("Form review cannot renew the decision budget") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserActionPlanError, .deadlineExceeded) }
        XCTAssertTrue(cancelled); XCTAssertFalse(waiting); XCTAssertFalse(owner.isOperating)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .edit }.count, 0)
    }

    func testRepeatingAnUnresolvedFormSelectionFailsWithoutAnotherReviewLoop() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner(), before = fixture.actions.inputs.count
        fixture.actions.select = { input in
            let form = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Query" }?.form?.id)
            return try ResearchAnswerFixture.json(["form":form,"preserve":[]])
        }
        do { _ = try await owner.planNextAction(using: fixture.actions); XCTFail("Repeated selection cannot replace its missing review") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserActionPlanError, .invalidProposal) }
        XCTAssertEqual(fixture.actions.inputs.count, before + 2); XCTAssertFalse(owner.isOperating)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .edit }.count, 0)
    }

    func testPreservationScopeChangesInvalidateReviewsAndCannotDropOrReassignEarlierRows() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        _ = try await fixture.start(); configure(fixture)
        let action = try await fixture.owner().planNextAction(using: fixture.actions)
        let prior = try XCTUnwrap(fixture.actions.inputs.first { !$0.effectAdditionalPreservationControlIDs.isEmpty })
        let reference = try XCTUnwrap(prior.evidence.page.controls.first { $0.label == "Reference" }?.id)
        for rows: [[String: Any]] in [[], [["control":reference,"requirement":true]],
            [["control":reference,"requirement":0]], [["control":reference,"requirement":1],["control":reference,"requirement":1]]] {
            XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: ResearchAnswerFixture.json(["preserve_controls":rows]), input: prior))
        }
        let scope = try XCTUnwrap(action.input.formEffectScope)
        XCTAssertThrowsError(try scope.extending([.init(controlID: reference, requirementIndex: 0)]))
        XCTAssertThrowsError(try ComputerUseBrowserActionInput(interpretation: action.input.interpretation, evidence: action.input.evidence,
            navigationHistory: [], formHistory: [], latestForm: nil, changedFormTargetIDs: [],
            effectControlReviews: prior.effectControlReviews, formEffectScope: scope))
        let repeated = try ComputerUseBrowserActionProposal.decode(content: ResearchAnswerFixture.json(["form":XCTUnwrap(scope.formID),"preserve":[]]), input: action.input)
        XCTAssertEqual(try ComputerUseBrowserFormEffectScope(action: repeated).preservedControls, scope.preservedControls)
        let changed = try ComputerUseBrowserActionProposal.decode(content: ResearchAnswerFixture.json(["form":XCTUnwrap(scope.formID),
            "preserve":[["control":reference,"requirement":0]]]), input: action.input)
        XCTAssertThrowsError(try ComputerUseBrowserFormEffectScope(action: changed))
    }

    func testCompletedFormReviewChangesContractEvenWhenTheReadScopeAndValuesMatch() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        _ = try await fixture.start(); configure(fixture)
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        let prepared = try await owner.prepareFormInput(for: action), scope = try XCTUnwrap(action.input.formEffectScope)
        let unreviewed = try ComputerUseBrowserActionInput(interpretation: action.input.interpretation, evidence: action.input.evidence,
            navigationHistory: [], formHistory: [], latestForm: nil, changedFormTargetIDs: [], formEffectScope: scope)
        let text = try XCTUnwrap(unreviewed.effectReviewEvidenceIDs.first { !unreviewed.effectReviewControlIDs.contains($0) })
        let rows = try FormEffectScopeFixture.rows(unreviewed, relevant: [:], unrelated: ["Private notes"], extraEvidence: [text])
        let decision = try ComputerUseBrowserActionProposal.decode(content: ResearchAnswerFixture.json(["review_controls":rows]), input: unreviewed)
        guard case .reviewControls(let review) = decision.step else { return XCTFail("Expected alternate citations") }
        let differentlyReviewed = try ComputerUseBrowserActionInput(interpretation: unreviewed.interpretation, evidence: unreviewed.evidence,
            navigationHistory: [], formHistory: [], latestForm: nil, changedFormTargetIDs: [], effectControlReviews: [review], formEffectScope: scope)
        let other = try ComputerUseBrowserResearchFormInput(interpretation: prepared.interpretation, evidence: prepared.evidence,
            selectedFormID: prepared.selectedFormID, preservedControls: action.preservedControls, scopeReview: .init(input: differentlyReviewed))
        let firstPlan = try ComputerUseBrowserFormProposal.decode(content: plan(prepared), input: prepared)
        let secondPlan = try ComputerUseBrowserFormProposal.decode(content: plan(other), input: other)
        XCTAssertEqual(prepared.contextJSON, other.contextJSON)
        XCTAssertNotEqual(try firstPlan.textContract(for: prepared)?.contractDigest, try secondPlan.textContract(for: other)?.contractDigest)
        XCTAssertEqual(firstPlan.preserved, secondPlan.preserved); XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testQueryPreparationPauseRetainsReviewAndReobservesExactReadingsBeforeOneLoad() async throws {
        let fixture = try await prepared(city: "Paris")
        defer { fixture.close() }
        configure(fixture, querying: true)
        let owner = try fixture.owner(), original = owner.input, action = try await owner.planNextAction(using: fixture.actions)
        fixture.state.onCommand = { command in
            guard command == .prepareFormQuery else { return }
            fixture.state.onCommand = nil; owner.pause()
        }
        do { _ = try await owner.openFormQuery(for: action); XCTFail("Cancelled preparation cannot publish navigation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&city=Paris"), 0); XCTAssertFalse(owner.isOperating)
        let decisions = fixture.actions.inputs.count, reads = fixture.state.commands.filter { $0 == .observeResearchControls }.count
        try await owner.resumeAfterUserControl()
        _ = try await owner.resumeFormNavigation()
        XCTAssertEqual(fixture.actions.inputs.count, decisions)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .observeResearchControls }.count, reads + 1)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&city=Paris"), 1); XCTAssertEqual(owner.input, original)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testQueryHandbackCannotReplaceAnOriginallyReviewedCityWithANewValue() async throws {
        let extra = OptionSelectionFixture.signal("document.getElementById('city').value='Oxford';")
        let fixture = try await prepared(city: "Paris", extra: extra, heldSignal: true)
        defer { fixture.close() }
        configure(fixture, querying: true)
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        fixture.state.onCommand = { command in
            guard command == .prepareFormQuery else { return }
            fixture.state.onCommand = nil; owner.pause()
        }
        do { _ = try await owner.openFormQuery(for: action); XCTFail("Expected a retained preparation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await wait { fixture.server.count("/signal") == 1 }; fixture.server.releaseHeldResponses()
        try await wait { fixture.server.count("/changed") == 1 }
        let decisions = fixture.actions.inputs.count
        try await owner.resumeAfterUserControl()
        do { _ = try await owner.resumeFormNavigation(); XCTFail("Handback cannot rebase the reviewed criterion") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        XCTAssertEqual(fixture.actions.inputs.count, decisions); XCTAssertEqual(owner.confirmedFormHistory.count, 1)
        XCTAssertTrue(action.input.contextJSON.contains("Paris")); XCTAssertFalse(action.input.contextJSON.contains("Oxford"))
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&city=Paris"), 0)
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&city=Oxford"), 0)
    }

    func testSameFormOwnershipDoesNotReadUnrelatedValues() async throws {
        let fixture = try await make(body: "<form action='/filtered'><label>Query<input name=q></label><label>Private notes<textarea>private-notes</textarea></label><button>Search</button></form><label>Reference<input value='private-reference'></label>")
        defer { fixture.close() }
        _ = try await fixture.start(); configure(fixture)
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        let input = try await owner.prepareFormInput(for: action)
        XCTAssertEqual(Set(input.evidence.fields.map { $0.control.label }), ["Query","Reference"])
        XCTAssertFalse(input.evidence.fields.contains { $0.editable.snapshot.value.contains("private-notes") })
        XCTAssertEqual(input.fieldIntentRequirements.values.map { $0 }, [[0]])
        XCTAssertTrue(fixture.actions.inputs.allSatisfy { !$0.contextJSON.contains("private-notes") })
    }

    func testSameFormPreservationCannotBecomeAnEditableAlias() async throws {
        let fixture = try await make(body: "<form action='/filtered'><label>Query<input name=q></label><label>Reference<input value='private-reference'></label><button>Search</button></form><label>Private notes<input value='private-notes'></label>")
        defer { fixture.close() }
        _ = try await fixture.start(); configure(fixture)
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        let input = try await owner.prepareFormInput(for: action)
        let reference = try XCTUnwrap(input.requiredPreservation.first?.field)
        XCTAssertFalse(input.editableFieldAliases.contains(reference))
        let proposal = try ComputerUseBrowserFormProposal.decode(content: plan(input), input: input)
        XCTAssertEqual(proposal.preserved.map(\.field), [reference])
        _ = try await owner.executeForm(proposal, input: input)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testFormPlannerCannotOmitADeclaredEditAfterItsPrivateBaselineWasRead() async throws {
        let fixture = try await make(city: "Paris")
        defer { fixture.close() }
        _ = try await fixture.start()
        fixture.actions.select = { input in
            if let response = try FormEffectScopeFixture.response(input, unrelated: ["Private notes"],
                editing: ["Query":[0],"City":[0]], preserving: ["Reference":1]) { return response }
            return try ResearchAnswerFixture.json(["form":XCTUnwrap(input.formIDs.first),"preserve":[]])
        }
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        let input = try await owner.prepareFormInput(for: action)
        XCTAssertEqual(input.editableFieldAliases.count, 2)
        XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: plan(input), input: input))
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testFormPlannerCannotReplaceTheDeclaredRequirementWithAnotherSource() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        _ = try await fixture.start(); configure(fixture)
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        let input = try await owner.prepareFormInput(for: action), alias = try XCTUnwrap(input.editableFieldAliases.first)
        let changed = try ResearchAnswerFixture.json(["edits":[["field":alias,"terms":[["requirement":1,"text":"Reference"]]]],"preserve":[]])
        XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: changed, input: input))
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testAllUnrelatedMetadataWithoutAnEditIntentCannotReleaseFormDiscovery() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        _ = try await fixture.start()
        fixture.actions.select = { input in
            if let response = try FormEffectScopeFixture.response(input, unrelated: ["Query","Private notes"], preserving: ["Reference":1]) { return response }
            if input.formEffectScope != nil { return #"{"unavailable":true}"# }
            return try ResearchAnswerFixture.json(["form":XCTUnwrap(input.formIDs.first),"preserve":[]])
        }
        let action = try await fixture.owner().planNextAction(using: fixture.actions)
        XCTAssertEqual(action.step, .unavailable); XCTAssertFalse(action.input.effectScopeAllowsActions)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields || $0 == .fields }.count, 0)
    }

    func testFieldIntentDecoderRejectsUnreviewedDuplicatesProhibitionsAndInventedRetention() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        _ = try await fixture.start(); configure(fixture)
        _ = try await fixture.owner().planNextAction(using: fixture.actions)
        let input = try XCTUnwrap(fixture.actions.inputs.first { !$0.effectAdditionalEditControlIDs.isEmpty })
        let query = try XCTUnwrap(input.effectAdditionalEditControlIDs.first)
        let row: [String: Any] = ["control":query,"disposition":"edit","requirements":[0]]
        let invalid: [[[String: Any]]] = [[], [row,row],
            [["control":"missing","disposition":"edit","requirements":[0]]],
            [["control":query,"disposition":"edit","requirements":[true]]],
            [["control":query,"disposition":"edit","requirements":[2]]],
            [["control":query,"disposition":"edit","requirements":[0,0]]],
            [["control":query,"disposition":"retain","requirements":[0]]]]
        for rows in invalid {
            XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: ResearchAnswerFixture.json(["plan_fields":rows]), input: input))
        }
        let beforeReview = try XCTUnwrap(fixture.actions.inputs.first { $0.formEffectScope != nil })
        XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: ResearchAnswerFixture.json(["plan_fields":[row]]), input: beforeReview))
    }

    func testDeferredFieldStaysUnreadAndDoesNotBecomeAQueryInvariant() async throws {
        let fixture = try await prepared(city: "Paris")
        defer { fixture.close() }
        let owner = try fixture.owner()
        let form = try XCTUnwrap(fixture.actions.inputs.last { $0.formEffectScope?.formID != nil }?.formEffectScope)
        let deferred = try XCTUnwrap(form.fieldIntents.first { $0.disposition == .deferred })
        XCTAssertFalse(form.discoveryControlIDs.contains(deferred.controlID))
        configure(fixture, querying: true)
        let action = try await owner.planNextAction(using: fixture.actions)
        XCTAssertFalse(action.input.queryBoundControlIDs.contains(deferred.controlID))
        XCTAssertTrue(fixture.actions.inputs.contains { $0.effectQueryValueControlIDs.contains(deferred.controlID) })
        XCTAssertTrue(action.input.optionReadControls.contains { $0.controlID == deferred.controlID })
        XCTAssertEqual(fixture.server.count("/filtered?q=concerts&city=Paris"), 0)
    }

    func testScopedExtensionRetainsEarlierObjectsAndReceiptsWithoutReadingUnrelatedMembers() async throws {
        let fixture = try await prepared(city: "Paris")
        defer { fixture.close() }
        let owner = try fixture.owner()
        fixture.actions.select = { input in
            if let response = try FormEffectScopeFixture.response(input, unrelated: ["Private notes"], editing: ["City":[0]],
                retaining: ["Query":[0]], preserving: ["Reference":1]) { return response }
            return try ResearchAnswerFixture.json(["form":XCTUnwrap(input.formIDs.first),"preserve":[]])
        }
        let action = try await owner.planNextAction(using: fixture.actions), input = try await owner.prepareFormInput(for: action)
        let query = try XCTUnwrap(input.evidence.fields.first { $0.control.label == "Query" })
        XCTAssertEqual(input.previous?.finalValues[query.editable.snapshot.targetID], "concerts")
        XCTAssertEqual(input.previous?.inputOperationIDs.count, 1)
        XCTAssertEqual(try input.editableFieldAliases.map { try input.field(for: $0).control.label }, ["City"])
        XCTAssertFalse(input.evidence.fields.contains { $0.control.label == "Private notes" })
        let city = try XCTUnwrap(input.editableFieldAliases.first)
        let plan = try ResearchAnswerFixture.json(["edits":[["field":city,"terms":[["requirement":0,"text":"concerts"]]]],"preserve":[]])
        _ = try await owner.executeForm(.decode(content: plan, input: input), input: input)
        XCTAssertEqual(owner.confirmedFormHistory.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .extendFormFields }.count, 1)
    }

    func testEarlierVerifiedFieldCannotBeDeferredOrDeclaredUnrelated() async throws {
        let fixture = try await prepared(city: "Paris")
        defer { fixture.close() }
        fixture.actions.select = { input in
            if let response = try FormEffectScopeFixture.response(input, unrelated: ["Private notes"], editing: ["City":[0]], retaining: ["Query":[0]]) { return response }
            return try ResearchAnswerFixture.json(["form":XCTUnwrap(input.formIDs.first),"preserve":[]])
        }
        _ = try await fixture.owner().planNextAction(using: fixture.actions)
        let input = try XCTUnwrap(fixture.actions.inputs.first { !$0.effectAdditionalRetainedControlIDs.isEmpty })
        let query = try XCTUnwrap(input.effectAdditionalRetainedControlIDs.first)
        XCTAssertFalse(input.effectAdditionalDeferredControlIDs.contains(query))
        let rows: [[String: Any]] = [["control":query,"disposition":"deferred","requirements":[0]]]
        XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: ResearchAnswerFixture.json(["plan_fields":rows]), input: input))
        let unreviewed = try XCTUnwrap(fixture.actions.inputs.first { $0.effectReviewNextControlIDs.contains(query) && $0.effectRequiredControlIDs.contains(query) })
        XCTAssertThrowsError(try ComputerUseBrowserActionProposal.decode(content: ResearchAnswerFixture.json([
            "review_controls":FormEffectScopeFixture.rows(unreviewed, relevant: ["City":0], unrelated: ["Query","Private notes"])]), input: unreviewed))
    }

    func testNativeSelectedDiscoveryRejectsAControlFromAnotherForm() async throws {
        let fixture = try await make(extra: "<form><label>Newsletter<input name=email value='private-newsletter'></label></form>")
        defer { fixture.close() }
        _ = try await fixture.start()
        let action = try await fixture.owner().planNextAction(using: fixture.actions), evidence = action.input.evidence
        let form = try XCTUnwrap(evidence.page.controls.first { $0.label == "Query" }?.form?.id)
        let foreign = try XCTUnwrap(evidence.page.controls.first { $0.label == "Newsletter" }?.id)
        let target = ComputerUseBrowserTextTarget(browser: fixture.browser, document: evidence.document, requiresFrontmost: false)
        do {
            _ = try await target.fields(in: form, page: evidence, preserving: [], selecting: [foreign])
            XCTFail("Native ownership must reject a foreign edit target")
        } catch { XCTAssertTrue(error is ComputerUseBrowserError) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    private func make(body: String? = nil, city: String? = nil, extra: String = "", heldSignal: Bool = false) async throws -> ResearchDriverFixture {
        let optionalCity = city.map { "<label>City<input id=city name=city value='\($0)'></label>" } ?? ""
        let body = body ?? "<form action='/filtered'><label>Query<input name=q></label>" + optionalCity
            + "<button>Search</button></form><label>Reference<input value='private-reference'></label><label>Private notes<input value='private-notes'></label>"
        let fixture = try await ResearchDriverFixture.make(request: "Find concerts. Leave Reference unchanged. Do not buy.", searchFormHTML: body + extra, heldSignal: heldSignal)
        fixture.goal.select = { _ in try ResearchAnswerFixture.json(["disposition":"research","requirements":[
            ["turn":0,"source":"Find concerts. ","role":"outcome","field":"category","relation":"unspecified","values":[]],
            ["turn":0,"source":"Leave Reference unchanged. ","role":"condition","field":"other","relation":"unspecified","values":[]],
            ["turn":0,"source":"Do not buy.","role":"prohibition","field":"other","relation":"unspecified","values":[]]],
            "question":["topic":"none","requirements":[]]]) }
        fixture.policy.choices = [false]; return fixture
    }
    private func configure(_ fixture: ResearchDriverFixture, querying: Bool = false, rejectCity: String? = nil) {
        fixture.actions.select = { input in
            if let review = try FormEffectScopeFixture.response(input, relevant: ["City":0], unrelated: ["Private notes"], editing: ["Query":[0]], deferring: ["City":[0]], preserving: ["Reference":1]) { return review }
            if input.formEffectScope != nil && !input.effectScopeAllowsActions { return #"{"unavailable":true}"# }
            if let rejectCity, input.optionReadControls.contains(where: { read in
                input.evidence.page.controlStates.contains { $0.controlID == read.controlID && $0.value == rejectCity }
            }) { return #"{"unavailable":true}"# }
            if querying, let query = input.queryControlIDs.first { return try ResearchAnswerFixture.json(["query":query]) }
            let form = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Query" }?.form?.id)
            return try ResearchAnswerFixture.json(["form":form,"preserve":[]])
        }
    }
    private func prepared(city: String, extra: String = "", heldSignal: Bool = false) async throws -> ResearchDriverFixture {
        let fixture = try await make(city: city, extra: extra, heldSignal: heldSignal)
        do {
            _ = try await fixture.start(); configure(fixture)
            let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
            let input = try await owner.prepareFormInput(for: action)
            _ = try await owner.executeForm(.decode(content: plan(input), input: input), input: input)
            return fixture
        } catch { fixture.close(); throw error }
    }
    private func plan(_ input: ComputerUseBrowserResearchFormInput) throws -> String {
        let alias = try XCTUnwrap(input.fieldAliases.first { (try? input.field(for: $0).control.label) == "Query" })
        return try ResearchAnswerFixture.json(["edits":[["field":alias,"terms":[["requirement":0,"text":"concerts"]]]],"preserve":[]])
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Caller-supplied semantics for authored fixtures, never a production policy.
@MainActor
enum FormEffectScopeFixture {
    static func rows(_ input: ComputerUseBrowserActionInput, relevant: [String: Int], unrelated: Set<String>,
                     extraEvidence: [String] = []) throws -> [[String: Any]] {
        try input.effectReviewNextControlIDs.map { id in
            let label = try XCTUnwrap(input.evidence.page.controls.first { $0.id == id }?.label)
            let requirement = relevant[label]
            return ["control":id,"relationship":requirement != nil ? "relevant" : (unrelated.contains(label) ? "unrelated" : "unknown"),
                "requirements":requirement.map { [$0] } ?? [],"evidence":[id] + extraEvidence]
        }
    }
    static func response(_ input: ComputerUseBrowserActionInput, relevant: [String: Int] = [:], unrelated: Set<String> = [],
                         extraEvidence: [String] = [], editing: [String: [Int]] = [:], retaining: [String: [Int]] = [:],
                         deferring: [String: [Int]] = [:], preserving: [String: Int] = [:]) throws -> String? {
        guard input.formEffectScope != nil else { return nil }
        var references = relevant.mapValues { [$0] }
        for decisions in [editing, retaining, deferring, preserving.mapValues { [$0] }] {
            for (label, indices) in decisions { references[label] = indices }
        }
        if !input.effectReviewNextControlIDs.isEmpty {
            var rows = try rows(input, relevant: references.compactMapValues(\.first), unrelated: unrelated, extraEvidence: extraEvidence)
            for index in rows.indices {
                let id = try XCTUnwrap(rows[index]["control"] as? String)
                let label = try XCTUnwrap(input.evidence.page.controls.first { $0.id == id }?.label)
                if let indices = references[label] { rows[index]["requirements"] = indices }
            }
            return try ResearchAnswerFixture.json(["review_controls":rows])
        }
        var intentions: [[String: Any]] = []
        for (name, ids, decisions) in [("edit",input.effectAdditionalEditControlIDs,editing),
                ("retain",input.effectAdditionalRetainedControlIDs,retaining), ("deferred",input.effectAdditionalDeferredControlIDs,deferring)] {
            for id in ids where intentions.count < 4 {
                let label = try XCTUnwrap(input.evidence.page.controls.first { $0.id == id }?.label)
                if let indices = decisions[label] { intentions.append(["control":id,"disposition":name,"requirements":indices]) }
            }
        }
        if !intentions.isEmpty { return try ResearchAnswerFixture.json(["plan_fields":intentions]) }
        let preservation: [[String: Any]] = input.effectAdditionalPreservationControlIDs.compactMap { id in
            guard let label = input.evidence.page.controls.first(where: { $0.id == id })?.label,
                  let index = preserving[label] else { return nil }
            return ["control":id,"requirement":index]
        }
        if !preservation.isEmpty { return try ResearchAnswerFixture.json(["preserve_controls":preservation]) }
        let reading: [[String: Any]] = input.effectAdditionalReadControlIDs.compactMap { id in
            guard let label = input.evidence.page.controls.first(where: { $0.id == id })?.label,
                  let index = relevant[label] else { return nil }
            return ["control":id,"requirement":index]
        }
        return reading.isEmpty ? nil : try ResearchAnswerFixture.json(["extend_inspection":reading])
    }
}

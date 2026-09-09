import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserFormPrefixTests: XCTestCase {
    private let prompt = "Find concerts in Paris. Leave Reference unchanged. Do not buy."

    func testDefaultDriverKeepsVerifiedEntryAndResumesOnlyTheUnsentRemainder() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        _ = try await failWrite(fixture)
        let owner = try fixture.owner(), original = owner.input
        _ = try await fixture.resume()
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [1, 1])
        XCTAssertEqual(owner.confirmedFormHistory.map(\.plannedEditCount), [2, 1])
        XCTAssertEqual(owner.confirmedFormHistory.map(\.isCompleteStage), [false, true])
        let retired = try XCTUnwrap(owner.retiredFormHistory.first)
        XCTAssertEqual(retired.stageID, owner.confirmedFormHistory.first?.stageID)
        let stored = try journal(fixture, stageID: retired.stageID)
        XCTAssertEqual(stored.statuses, [.verified, .uncertain])
        XCTAssertEqual(stored.retainedPrefixCount, 1); XCTAssertEqual(stored.retirementDigest, retired.digest)
        let next = try XCTUnwrap(fixture.forms.inputs.last)
        XCTAssertEqual(next.pendingEditAliases, ["pending1"])
        XCTAssertEqual(next.previous?.pendingEdits.map(\.label), ["City"])
        XCTAssertEqual(next.previous?.inputOperationIDs.count, 1)
        XCTAssertEqual(owner.input, original)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
        XCTAssertEqual(fixture.server.count("/category-event"), 1); XCTAssertEqual(fixture.server.count("/city-event"), 1)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 1)
    }

    func testAnUnexecutedReplacementFieldGetsAFreshBindingWithoutReplacingTheVerifiedPrefix() async throws {
        let mutation = "const old = document.getElementById('city'); old.replaceWith(old.cloneNode(true));"
        let fixture = try await make(mutation: mutation)
        defer { fixture.close() }
        let original = try await failWrite(fixture), owner = try fixture.owner()
        try await releaseMutation(fixture)
        let result = try await owner.retainPendingFormPrefix(), receipt = try XCTUnwrap(result)
        let next = try await prepare(fixture)
        let oldCategory = try original.input.field(for: alias("Category", original.input)).editable.snapshot.targetID
        let category = try next.input.field(for: alias("Category", next.input)).editable.snapshot.targetID
        let oldCity = try original.input.field(for: alias("City", original.input)).editable.snapshot.targetID
        let city = try next.input.field(for: alias("City", next.input)).editable.snapshot.targetID
        XCTAssertEqual(category, oldCategory); XCTAssertNotEqual(city, oldCity)
        XCTAssertEqual(next.input.previous?.editedTargetIDs, Set([category]))
        XCTAssertEqual(next.input.previous?.pendingEdits.first?.sources.first?.source, prompt)
        XCTAssertEqual(next.proposal.resumptions.map(\.field), [try alias("City", next.input)])
        XCTAssertEqual(receipt.editCount, 1); XCTAssertEqual(receipt.plannedEditCount, 2)
        _ = try await owner.executeForm(next.proposal, input: next.input)
        _ = try await fixture.resume()
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 1)
    }

    func testUnfinishedEntriesWithholdQueriesAndRequireCompleteDistinctResumptionMappings() async throws {
        let fixture = try await make(extraField: true)
        defer { fixture.close() }
        _ = try await failWrite(fixture)
        let owner = try fixture.owner(), result = try await owner.retainPendingFormPrefix(), receipt = try XCTUnwrap(result)
        let prepared = try await prepare(fixture), input = prepared.input
        XCTAssertEqual(input.pendingEditAliases, ["pending1", "pending2"])
        let latestAction = try XCTUnwrap(fixture.actions.inputs.last)
        XCTAssertTrue(latestAction.queryControlIDs.isEmpty)
        let history = try XCTUnwrap(object(latestAction.contextJSON)["form_history"] as? [[String: Any]])
        XCTAssertEqual(history.first?["complete_stage"] as? Bool, false)
        XCTAssertEqual(history.first?["planned_edits"] as? Int, 3)
        let city = try alias("City", input), region = try alias("Region", input)
        let valid = try object(plan(input))
        var omitted = valid; omitted.removeValue(forKey: "resume")
        var missing = valid; missing["resume"] = [["pending":"pending1", "field":city]]
        var duplicateID = valid; duplicateID["resume"] = [["pending":"pending1", "field":city], ["pending":"pending1", "field":region]]
        var duplicateField = valid; duplicateField["resume"] = [["pending":"pending1", "field":city], ["pending":"pending2", "field":city]]
        var preserved = valid; preserved["resume"] = [["pending":"pending1", "field":city], ["pending":"pending2", "field":try alias("Reference", input)]]
        for invalid in [omitted, missing, duplicateID, duplicateField, preserved] {
            XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: json(invalid), input: input))
        }
        XCTAssertEqual(try ComputerUseBrowserFormProposal.decode(content: json(valid), input: input).resumptions.count, 2)
        XCTAssertTrue(try ComputerUseBrowserFormProposal.decode(content: #"{"unavailable":true}"#, input: input).isUnavailable)
        XCTAssertNotNil(try ComputerUseBrowserFormProposal.decode(content: #"{"question":{"topic":"location","requirements":[0]}}"#, input: input).question)
        let submit = try XCTUnwrap(input.evidence.page.page.controls.first { $0.kind == "submit" })
        do { _ = try await owner.prepareFormQuery(after: receipt, controlID: submit.id, evidence: input.evidence.page); XCTFail("Unfinished source obligations block native query preparation") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .formQueryUnavailable) }
        XCTAssertFalse(input.contextJSON.contains("private-reference"))
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
    }

    func testAChangedVerifiedCriterionRequiresRepairAlongsideTheUnfinishedEntry() async throws {
        let fixture = try await make(mutation: "document.getElementById('category').selectedIndex = 0;")
        defer { fixture.close() }
        _ = try await failWrite(fixture)
        try await releaseMutation(fixture)
        let owner = try fixture.owner(), result = try await owner.retainPendingFormPrefix()
        XCTAssertNotNil(result)
        let prepared = try await prepare(fixture), category = try alias("Category", prepared.input)
        XCTAssertEqual(prepared.input.requiredRepairFieldAliases, [category])
        XCTAssertEqual(prepared.input.pendingEditAliases, ["pending1"])
        var incomplete = try object(plan(prepared.input))
        incomplete["edits"] = [["field":try alias("City", prepared.input), "terms":[["requirement":0,"text":"Paris"]]]]
        XCTAssertThrowsError(try ComputerUseBrowserFormProposal.decode(content: json(incomplete), input: prepared.input))
        _ = try await owner.executeForm(prepared.proposal, input: prepared.input)
        fixture.actions.beforeReply = { try await self.wait { fixture.server.count("/category-event") == 2 && fixture.server.count("/city-event") == 1 } }
        _ = try await fixture.resume()
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [1, 2])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 3)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 1)
    }

    func testLostRequiredObjectsPreservationOrOriginalLedgerCannotCreateAPrefixReceipt() async throws {
        for mutation in ["const old = document.getElementById('category'); old.replaceWith(old.cloneNode(true));",
                         "document.getElementById('reference').value = 'changed';", ""] {
            let fixture = try await make(mutation: mutation)
            defer { fixture.close() }
            let prepared = try await failWrite(fixture), owner = try fixture.owner(), before = try journal(fixture)
            if mutation.isEmpty {
                let other = ComputerUseBrowserTextTarget(browser: fixture.browser, document: prepared.input.evidence.page.document, requiresFrontmost: false)
                _ = try await other.fields()
            } else { try await releaseMutation(fixture) }
            do { _ = try await owner.retainPendingFormPrefix(); XCTFail("Original native proof and preservation are required") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            XCTAssertEqual(try journal(fixture), before)
            XCTAssertTrue(owner.hasPendingForm); XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
            XCTAssertTrue(owner.retiredFormHistory.isEmpty)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        }
    }

    func testAnyNativeSuffixAttemptPreventsRetirementEvenAfterItsValueIsRestored() async throws {
        let fixture = try await make(cityInputHandler: "document.getElementById('city').value = '';")
        defer { fixture.close() }
        let owner = try fixture.owner(), prepared = try await prepare(fixture)
        do { _ = try await owner.executeForm(prepared.proposal, input: prepared.input); XCTFail("The native event undoes the city entry") }
        catch { XCTAssertTrue(error as? ComputerUseTextTaskError == .uncertainEffect || error as? ComputerUseTextEditError == .deliveryUncertain) }
        try await wait { fixture.server.count("/category-event") == 1 && fixture.server.count("/city-event") == 1 }
        let before = try journal(fixture), result = try await owner.retainPendingFormPrefix()
        XCTAssertNil(result); XCTAssertEqual(before.statuses, [.verified, .uncertain])
        XCTAssertEqual(try journal(fixture), before); XCTAssertTrue(owner.hasPendingForm)
        XCTAssertTrue(owner.confirmedFormHistory.isEmpty); XCTAssertTrue(owner.retiredFormHistory.isEmpty)
        _ = try await fixture.resume()
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 0)
    }

    func testFailedSuffixRetirementWriteRequiresFreshLeasedResolutionAndCannotReplay() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        _ = try await failWrite(fixture)
        let owner = try fixture.owner()
        fixture.state.failureAtWrite = fixture.state.writes + 1
        do { _ = try await owner.retainPendingFormPrefix(); XCTFail("The replacement was not confirmed durable") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
        fixture.state.failureAtWrite = nil
        let written = try journal(fixture)
        XCTAssertEqual(written.statuses, [.verified, .attempted]); XCTAssertEqual(written.retainedPrefixCount, 1)
        XCTAssertNotNil(written.retirementDigest); XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
        do { _ = try await owner.resumeForm(); XCTFail("The original full contract cannot resume") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchFormStage.Failure, .retirementPending) }
        let result = try await owner.retainPendingFormPrefix(), receipt = try XCTUnwrap(result)
        XCTAssertEqual(try journal(fixture, stageID: receipt.stageID), written)
        let duplicate = try await owner.retainPendingFormPrefix()
        XCTAssertNil(duplicate); XCTAssertEqual(owner.confirmedFormHistory.count, 1); XCTAssertEqual(owner.retiredFormHistory.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .retireUnsentInputs }.count, 1)
        _ = try await fixture.resume()
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testPauseDuringNativeRevocationOrAfterCommitNeedsHandbackAndKeepsPartialHistoryOnce() async throws {
        for pauseAfterWrite in [false, true] {
            let fixture = try await make()
            defer { fixture.close() }
            _ = try await failWrite(fixture)
            let owner = try fixture.owner(), nextWrite = fixture.state.writes + 1
            if pauseAfterWrite { fixture.state.onWrite = { if fixture.state.writes == nextWrite { owner.pause() } } }
            else {
                fixture.state.onCommand = { command in
                    if command == .retireUnsentInputs { fixture.state.onCommand = nil; owner.pause() }
                }
            }
            do { _ = try await owner.retainPendingFormPrefix(); XCTFail("Pause closes publication") }
            catch { XCTAssertTrue(error is CancellationError || error as? ComputerUseBrowserResearchTask.Failure == .paused) }
            fixture.state.onWrite = nil; fixture.state.onCommand = nil
            XCTAssertFalse(owner.isOperating); XCTAssertTrue(owner.hasPendingForm); XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
            try await owner.resumeAfterUserControl()
            _ = try await fixture.resume()
            XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [1, 1])
            XCTAssertEqual(owner.retiredFormHistory.count, 1)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
            XCTAssertEqual(fixture.server.count("/category-event"), 1); XCTAssertEqual(fixture.server.count("/city-event"), 1)
        }
    }

    func testRetainedPrefixMetadataCannotBeInventedClearedOrChangedThroughOrdinaryWrites() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let prepared = try await failWrite(fixture), owner = try fixture.owner(), original = try journal(fixture)
        let directory = try formDirectory(fixture), store = try ComputerUseTaskJournalStore(directory: directory)
        let digest = ComputerUseTaskContract.digest(["suffix"])
        func marker(count: Int?, digest: String?) -> ComputerUseTaskJournal {
            .init(taskID: original.taskID, promptDigest: original.promptDigest, contractDigest: original.contractDigest,
                stepIDs: original.stepIDs, statuses: original.statuses, retirementDigest: digest, retainedPrefixCount: count)
        }
        let marked = marker(count: 1, digest: digest)
        XCTAssertThrowsError(try store.save(marked, replacing: original))
        XCTAssertThrowsError(try store.retireUnsent(marked, replacing: original))
        XCTAssertThrowsError(try store.retireRemainingInput(marked, replacing: original), "Requires the caller's execution lease")
        for count in [nil, 0, 2, 3, -1] as [Int?] {
            XCTAssertThrowsError(try store.retireRemainingInput(marker(count: count, digest: digest), replacing: original))
        }
        XCTAssertThrowsError(try store.retireRemainingInput(marker(count: 1, digest: nil), replacing: original))
        let held = try store.acquireExecution(taskID: original.taskID, expected: original)
        do { _ = try await owner.retainPendingFormPrefix(); XCTFail("Another execution owner blocks before native revocation") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .busy) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .retireUnsentInputs }.count, 0)
        held.release()
        let result = try await owner.retainPendingFormPrefix(), receipt = try XCTUnwrap(result)
        let saved = try journal(fixture, stageID: receipt.stageID)
        XCTAssertThrowsError(try store.save(original, replacing: saved))
        XCTAssertThrowsError(try store.replaceUnattemptedBinding(original, replacing: saved))
        XCTAssertThrowsError(try store.retireUnsent(saved, replacing: saved))
        let lease = try store.acquireExecution(taskID: saved.taskID, expected: saved)
        defer { lease.release() }
        try store.retireRemainingInput(saved, replacing: saved)
        XCTAssertThrowsError(try store.retireRemainingInput(marked, replacing: saved), "A different digest cannot replace native proof")
        let contract = try XCTUnwrap(prepared.proposal.textContract(for: prepared.input, stageID: receipt.stageID))
        let plan = try ComputerUseTextTask(contract: contract, read: { _ in nil }, apply: { _, _ in XCTFail("No input") },
            persist: { _ in XCTFail("No execution") }, mayAct: { false })
        let prefix = try XCTUnwrap(plan.historicalPrefixRequirements(in: saved))
        XCTAssertFalse(prefix.isCompleteTask); XCTAssertEqual(prefix.inputOperationIDs.count, 1)
        XCTAssertEqual(prefix.inputOperationIDs, Array(plan.inputOperationIDs.prefix(1)))
        XCTAssertNil(prefix.finalValues[try prepared.input.field(for: alias("City", prepared.input)).editable.snapshot.targetID])
        XCTAssertThrowsError(try plan.verifiedContinuation())
        XCTAssertThrowsError(try ComputerUseTextTask(contract: contract, recovered: saved, read: { _ in nil },
            apply: { _, _ in XCTFail("No replay") }, persist: { _ in XCTFail("No journal revival") }, mayAct: { true }))
        XCTAssertEqual(try store.load(taskID: saved.taskID), saved)
    }

    func testASecondPartialStageRetainsTheRemainingSourcesAndAllOriginalVerifiedReceipts() async throws {
        let fixture = try await make(extraField: true)
        defer { fixture.close() }
        _ = try await failWrite(fixture)
        let owner = try fixture.owner()
        _ = try await owner.retainPendingFormPrefix()
        let next = try await failWrite(fixture)
        XCTAssertEqual(next.input.pendingEditAliases, ["pending1", "pending2"])
        let result = try await owner.retainPendingFormPrefix(), receipt = try XCTUnwrap(result)
        let last = try await prepare(fixture)
        XCTAssertEqual(last.input.previous?.stageIDs.count, 2)
        XCTAssertEqual(last.input.previous?.inputOperationIDs.count, 2)
        XCTAssertEqual(Set(last.input.previous?.inputOperationIDs ?? []).count, 2)
        XCTAssertEqual(last.input.previous?.pendingEdits.map(\.label), ["Region"])
        XCTAssertEqual(last.input.previous?.pendingEdits.first?.sources.count, 1)
        XCTAssertEqual(last.input.previous?.pendingEdits.first?.sources.first?.source, prompt)
        XCTAssertEqual(receipt.editCount, 1); XCTAssertEqual(receipt.plannedEditCount, 2)
        _ = try await owner.executeForm(last.proposal, input: last.input)
        _ = try await fixture.resume()
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [1, 1, 1])
        XCTAssertEqual(owner.confirmedFormHistory.map(\.plannedEditCount), [3, 2, 1])
        XCTAssertEqual(owner.retiredFormHistory.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 3)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris&region=Paris"), 1)
    }

    func testAnAcceptedAnswerKeepsOriginalPendingSourcesWhileTheReplacementUsesTheCurrentGoal() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        _ = try await failWrite(fixture)
        let owner = try fixture.owner(), original = owner.input
        let result = try await owner.retainPendingFormPrefix(), first = try XCTUnwrap(result)
        let interpretation = try await owner.interpretGoal()
        let requirement = try XCTUnwrap(interpretation.proposal.requirements.first { ComputerUseBrowserClarificationTopic.location.accepts($0) })
        let question = try owner.issueQuestion(topic: .location, requirementIDs: [requirement.id],
            controllerID: "phone", controllerSessionID: "session")
        _ = try owner.answerQuestion(questionID: question.id, answerTaskID: "city-answer", answer: "Paris", controllerID: "phone", controllerSessionID: "session")
        _ = try await fixture.resume()
        XCTAssertEqual(owner.confirmedFormHistory.first, first)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.goalRevision), [original.digest, owner.input.digest])
        let next = try XCTUnwrap(fixture.forms.inputs.last)
        XCTAssertEqual(next.previous?.pendingEdits.first?.sources.first?.source, original.prompt)
        XCTAssertEqual(next.previous?.pendingEdits.first?.sources.first?.turn, 0)
        XCTAssertEqual(next.interpretation.requirements.last?.sourceTurnIndex, 1)
        XCTAssertEqual(owner.input.rootDigest, original.rootDigest); XCTAssertEqual(owner.input.prompt, original.prompt)
        XCTAssertEqual(owner.input.referenceMilliseconds, original.referenceMilliseconds)
        XCTAssertEqual(owner.input.timeZoneIdentifier, original.timeZoneIdentifier)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 1)
    }

    func testAPartialRevisionKeepsTheEarlierCriterionUntilItsReplacementIsVerified() async throws {
        let fixture = try await make(categoryInputHandler: "document.getElementById('city').value = '';")
        defer { fixture.close() }
        fixture.actions.select = { input in
            if let review = try FormEffectScopeFixture.response(input, editing: ["City":[0]], deferring: ["Category":[0]]) { return review }
            let form = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Category" }?.form?.id)
            let reference = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Reference" })
            return try self.json(["form":form,"preserve":[["control":reference.id,"requirement":0]]])
        }
        fixture.forms.select = { input in
            try self.json(["edits":[["field":try self.alias("City", input),"terms":[["requirement":0,"text":"Paris"]]]],"preserve":[]])
        }
        let owner = try fixture.owner(), initial = try await prepare(fixture)
        let firstPlan = try ComputerUseBrowserFormProposal.decode(content: json([
            "edits":[["field":try alias("City", initial.input),"terms":[["requirement":0,"text":"Paris"]]]],"preserve":[]]), input: initial.input)
        let first = try await owner.executeForm(firstPlan, input: initial.input)
        fixture.actions.beforeReply = nil
        fixture.actions.select = { input in
            if let review = try FormEffectScopeFixture.response(input, editing: ["Category":[0],"City":[0]]) { return review }
            let category = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Category" })
            let reference = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Reference" })
            return try self.json(["form":try XCTUnwrap(category.form?.id),"preserve":[["control":reference.id,"requirement":0]]])
        }
        fixture.forms.select = { input in
            let category = try self.alias("Category", input), option = try XCTUnwrap(input.field(for: category).control.options.first { $0.label == "Concerts" })
            return try self.json(["edits":[["field":category,"choice":option.id,"requirement":0],
                ["field":try self.alias("City", input),"terms":[["requirement":0,"text":"Paris"]]]],"preserve":[]])
        }
        let revision = try await prepare(fixture)
        do { _ = try await owner.executeForm(revision.proposal, input: revision.input); XCTFail("Category resets the next edit's precondition") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .staleTarget) }
        let partial = try await owner.retainPendingFormPrefix()
        let retired = try XCTUnwrap(partial)
        XCTAssertEqual(try journal(fixture, stageID: retired.stageID).statuses, [.verified, .planned])
        fixture.forms.select = { try self.plan($0) }
        let next = try await prepare(fixture), city = try alias("City", next.input)
        let cityID = try next.input.field(for: city).editable.snapshot.targetID
        XCTAssertEqual(next.input.previous?.finalValues[cityID], "Paris")
        XCTAssertEqual(next.input.previous?.inputOperationIDs.count, 2)
        XCTAssertEqual(next.input.previous?.pendingEdits.map(\.label), ["City"])
        XCTAssertEqual(next.input.requiredRepairFieldAliases, [city])
        XCTAssertEqual(next.proposal.edits.map(\.field), [city])
        XCTAssertEqual(next.proposal.resumptions.map(\.field), [city])
        let receipt = try await owner.executeForm(next.proposal, input: next.input)
        let page = try await owner.observeFormResultPage(after: receipt)
        let submit = try XCTUnwrap(page.page.controls.first { $0.kind == "submit" })
        try await wait { fixture.server.count("/category-event") == 1 && fixture.server.count("/city-event") == 2 }
        _ = try await owner.openFormQuery(after: receipt, controlID: submit.id, evidence: page)
        XCTAssertEqual(owner.confirmedFormHistory.first, first)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.editCount), [1, 1, 1])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 3)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 1)
    }

    private struct Prepared {
        let input: ComputerUseBrowserResearchFormInput
        let proposal: ComputerUseBrowserFormProposal
    }
    private func prepare(_ fixture: ResearchDriverFixture) async throws -> Prepared {
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        let input = try await owner.prepareFormInput(for: action), proposal = try await owner.planForm(input, using: fixture.forms)
        return .init(input: input, proposal: proposal)
    }
    private func failWrite(_ fixture: ResearchDriverFixture) async throws -> Prepared {
        let owner = try fixture.owner(), prepared = try await prepare(fixture)
        fixture.state.failureAtWrite = fixture.state.writes + 3
        do { _ = try await owner.executeForm(prepared.proposal, input: prepared.input); XCTFail("The second attempt write must fail after the verified first entry") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
        fixture.state.failureAtWrite = nil
        XCTAssertTrue(owner.hasPendingForm)
        return prepared
    }
    private func make(mutation: String = "", cityInputHandler: String = "", extraField: Bool = false,
                      categoryInputHandler: String = "") async throws -> ResearchDriverFixture {
        let extra = extraField ? "<label>Region<input id='region' name='region'></label>" : ""
        let body = """
            <form action='/filtered'><label>Category<select id='category' name='category'><option value=''>Choose</option><option value='concerts'>Concerts</option></select></label>
            <label>City<input id='city' name='city'></label>\(extra)<button>Search</button></form><label>Reference<input id='reference' value='private-reference'></label>
            <script>
            document.addEventListener('input', event => {
              if (event.target.id === 'category') { fetch('/category-event'); \(categoryInputHandler) }
              if (event.target.id === 'city') { fetch('/city-event'); \(cityInputHandler) }
              if (event.target.id === 'region') fetch('/region-event');
            });
            fetch('/signal').then(() => { \(mutation) fetch('/changed'); });
            </script>
            """
        let fixture = try await ResearchDriverFixture.make(request: prompt, searchFormHTML: body, heldSignal: true)
        fixture.goal.select = { input in
            var requirements: [[String: Any]] = [["turn":0,"source":input.prompt,"role":"outcome","field":"category","relation":"unspecified","values":[]]]
            requirements += input.clarifications.enumerated().map { index, turn in
                ["turn":index + 1,"source":turn.answer,"role":"condition","field":"location","relation":"unspecified","values":[]]
            }
            return try self.json(["disposition":"research","requirements":requirements,"question":["topic":"none","requirements":[]]])
        }
        do {
            _ = try await fixture.start()
            fixture.actions.select = { input in
                if let review = try self.actionReview(input) { return review }
                if let query = input.queryControlIDs.first { return try self.json(["query":query]) }
                guard let form = input.evidence.page.controls.first(where: { $0.label == "Category" })?.form?.id else { return #"{"read_results":true}"# }
                let reference = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Reference" })
                return try self.json(["form":form,"preserve":[["control":reference.id,"requirement":0]]])
            }
            fixture.actions.beforeReply = {
                guard fixture.actions.inputs.last?.queryControlIDs.isEmpty == false else { return }
                try await self.wait { fixture.server.count("/category-event") >= 1 && fixture.server.count("/city-event") == 1
                    && (!extraField || fixture.server.count("/region-event") == 1) }
            }
            fixture.forms.select = { try self.plan($0) }
            return fixture
        } catch { fixture.close(); throw error }
    }
    private func actionReview(_ input: ComputerUseBrowserActionInput) throws -> String? {
        let verified = try object(input.contextJSON)["verified_form_stage"] as? [String: Any]
        let edits = verified?["edits"] as? [[String: Any]] ?? []
        let pending = verified?["unfinished_edits"] as? [[String: Any]] ?? []
        let cityIndex = input.interpretation.requirements.firstIndex { $0.sourceTurnIndex == 1 } ?? 0
        var editing: [String: [Int]] = [:], retaining: [String: [Int]] = [:]
        for label in ["Category", "City", "Region"] {
            guard let id = input.evidence.page.controls.first(where: { $0.label == label })?.id else { continue }
            let previous = edits.first { $0["control"] as? String == id }
            if verified == nil || previous?["requires_repair"] as? Bool == true || pending.contains(where: { $0["label"] as? String == label }) {
                editing[label] = [label == "Category" ? 0 : cityIndex]
            } else { retaining[label] = [label == "Category" ? 0 : cityIndex] }
        }
        return try FormEffectScopeFixture.response(input, editing: editing, retaining: retaining)
    }
    private func plan(_ input: ComputerUseBrowserResearchFormInput) throws -> String {
        var edits: [[String: Any]] = []
        let pending = input.previous?.pendingEdits ?? []
        let category = try alias("Category", input)
        if input.previous == nil || input.requiredRepairFieldAliases.contains(category) {
            let option = try XCTUnwrap(input.field(for: category).control.options.first { $0.label == "Concerts" })
            edits.append(["field":category,"choice":option.id,"requirement":0])
        }
        for label in ["City", "Region"] where input.evidence.fields.contains(where: { $0.control.label == label }) {
            if input.previous == nil || pending.contains(where: { $0.label == label }) {
                let index = input.interpretation.requirements.firstIndex { $0.sourceTurnIndex == 1 } ?? 0
                edits.append(["field":try alias(label, input),"terms":[["requirement":index,"text":"Paris"]]])
            }
        }
        var content: [String: Any] = ["edits":edits,"preserve":[]]
        if !input.pendingEditAliases.isEmpty {
            content["resume"] = try zip(input.pendingEditAliases, pending).map { ["pending":$0.0,"field":try alias($0.1.label, input)] }
        }
        return try json(content)
    }
    private func alias(_ label: String, _ input: ComputerUseBrowserResearchFormInput) throws -> String {
        try XCTUnwrap(input.fieldAliases.first { (try? input.field(for: $0).control.label) == label })
    }
    private func formDirectory(_ fixture: ResearchDriverFixture, stageID: String? = nil) throws -> URL {
        let root = fixture.directory.appendingPathComponent("Research/Research Forms")
        if let stageID { return root.appendingPathComponent(stageID) }
        let paths = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(paths.count, 1)
        return try XCTUnwrap(paths.first)
    }
    private func journal(_ fixture: ResearchDriverFixture, stageID: String? = nil) throws -> ComputerUseTaskJournal {
        try XCTUnwrap(ComputerUseTaskJournalStore(directory: formDirectory(fixture, stageID: stageID)).load(taskID: fixture.owner().taskID))
    }
    private func releaseMutation(_ fixture: ResearchDriverFixture) async throws {
        try await wait { fixture.server.count("/signal") == 1 }
        fixture.server.releaseHeldResponses()
        try await wait { fixture.server.count("/changed") == 1 }
    }
    private func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
    private func object(_ value: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]) }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

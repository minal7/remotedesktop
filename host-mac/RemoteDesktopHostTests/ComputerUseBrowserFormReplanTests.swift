import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserFormReplanTests: XCTestCase {
    private let prompt = "Find concerts in Paris. Leave Reference unchanged. Do not buy."

    func testDefaultDriverRetiresStaleUnsentTargetsAndReplansWithDistinctStageAuthority() async throws {
        for (index, mutation) in ["document.getElementById('city').value = 'changed';",
                                 "const old = document.getElementById('city'); old.replaceWith(old.cloneNode(true));"].enumerated() {
            let pending = try await stale(mutation: mutation)
            defer { pending.fixture.close() }
            let fixture = pending.fixture, owner = try fixture.owner(), original = owner.input
            if index == 0 {
                // Cover an actually persisted all-planned journal as well as
                // the second case's preflight failure before the first write.
                let root = fixture.directory.appendingPathComponent("Research/Research Forms")
                let paths = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                let directory = try XCTUnwrap(paths.first)
                XCTAssertEqual(paths.count, 1)
                let contract = try XCTUnwrap(pending.proposal.textContract(for: pending.input, stageID: directory.lastPathComponent))
                let plan = try ComputerUseTextTask(contract: contract, read: { _ in nil }, apply: { _, _ in XCTFail("No input") },
                    persist: { _ in XCTFail("No execution") }, mayAct: { false })
                try ComputerUseTaskJournalStore(directory: directory).save(plan.journal, replacing: nil)
            }
            _ = try await fixture.resume()
            let retired = try XCTUnwrap(owner.retiredFormHistory.first), verified = try XCTUnwrap(owner.confirmedFormHistory.first)
            XCTAssertEqual(owner.retiredFormHistory.count, 1); XCTAssertEqual(owner.confirmedFormHistory.count, 1)
            XCTAssertEqual(retired.index, verified.index); XCTAssertNotEqual(retired.stageID, verified.stageID)
            XCTAssertNotEqual(retired.contractDigest, verified.contractDigest)
            XCTAssertEqual(owner.input, original)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
            XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
            XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 1)
            let journal = try journal(retired, fixture: fixture)
            XCTAssertEqual(journal.retirementDigest, retired.digest)
            XCTAssertTrue(journal.statuses.allSatisfy { $0 == .planned })
        }
    }

    func testRetiringAnUnsentDependentStageKeepsEarlierCompletedInputAndPreservation() async throws {
        let pending = try await stale(mutation: "const old = document.getElementById('city'); old.replaceWith(old.cloneNode(true));", dependent: true)
        defer { pending.fixture.close() }
        let fixture = pending.fixture, owner = try fixture.owner(), first = try XCTUnwrap(owner.confirmedFormHistory.first)
        _ = try await fixture.resume()
        XCTAssertEqual(owner.confirmedFormHistory.first, first)
        XCTAssertEqual(owner.confirmedFormHistory.map(\.index), [0, 1])
        XCTAssertEqual(owner.retiredFormHistory.map(\.index), [1])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .formFields }.count, 1)
        let input = try XCTUnwrap(fixture.forms.inputs.last)
        XCTAssertEqual(input.previous?.inputOperationIDs.count, 1)
        XCTAssertEqual(input.requiredPreservation.count, 1)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 1)
        XCTAssertFalse(input.contextJSON.contains("private-reference"))
    }

    func testVerifiedJournalPrefixCannotBeRetiredEvenAfterAWriteFailure() async throws {
        let fixture = try await make(mutation: "")
        defer { fixture.close() }
        let owner = try fixture.owner(), input = try await prepare(fixture)
        let proposal = try ComputerUseBrowserFormProposal.decode(content: plan(input), input: input)
        fixture.state.failureAtWrite = fixture.state.writes + 2
        do { _ = try await owner.executeForm(proposal, input: input); XCTFail("Keep the uncertain write pending") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
        fixture.state.failureAtWrite = nil
        let retired = try await owner.retirePendingUnsentForm()
        XCTAssertNil(retired); XCTAssertTrue(owner.retiredFormHistory.isEmpty); XCTAssertTrue(owner.hasPendingForm)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .retireUnsentInputs }.count, 0)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 0)
    }

    func testFailedRetirementWriteRequiresFreshLeasedResolutionBeforeAnotherPlan() async throws {
        let pending = try await stale(mutation: "document.getElementById('city').value = 'changed';")
        defer { pending.fixture.close() }
        let fixture = pending.fixture, owner = try fixture.owner()
        fixture.state.failureAtWrite = fixture.state.writes + 1
        do { _ = try await owner.retirePendingUnsentForm(); XCTFail("A visible rename is not a confirmed retirement") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
        fixture.state.failureAtWrite = nil
        XCTAssertTrue(owner.hasPendingForm); XCTAssertTrue(owner.retiredFormHistory.isEmpty)
        do { _ = try await owner.resumeForm(); XCTFail("The old input cannot run during ambiguous retirement") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchFormStage.Failure, .retirementPending) }
        let other = ComputerUseBrowserTextTarget(browser: fixture.browser, document: pending.input.evidence.page.document, requiresFrontmost: false)
        _ = try await other.fields()
        // The exact saved marker records positive earlier proof. Its fsync
        // resolution does not infer absence from this replacement ledger.
        let retired = try await owner.retirePendingUnsentForm()
        XCTAssertNotNil(retired); XCTAssertFalse(owner.hasPendingForm)
        XCTAssertEqual(owner.retiredFormHistory.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        _ = try await fixture.resume()
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 1)
    }

    func testPauseDuringNativeRetirementJoinsBeforeHandbackAndDoesNotReviveOldInput() async throws {
        let pending = try await stale(mutation: "document.getElementById('city').value = 'changed';")
        defer { pending.fixture.close() }
        let fixture = pending.fixture, owner = try fixture.owner()
        fixture.state.onCommand = { command in
            guard command == .retireUnsentInputs else { return }
            fixture.state.onCommand = nil; owner.pause()
        }
        do { _ = try await owner.retirePendingUnsentForm(); XCTFail("Pause must not publish retirement early") }
        catch { XCTAssertTrue(error is CancellationError || error as? ComputerUseBrowserResearchTask.Failure == .paused) }
        XCTAssertFalse(owner.isOperating); XCTAssertTrue(owner.hasPendingForm)
        XCTAssertTrue(owner.retiredFormHistory.isEmpty)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        try await owner.resumeAfterUserControl()
        _ = try await fixture.resume()
        XCTAssertEqual(owner.retiredFormHistory.count, 1)
        XCTAssertEqual(owner.confirmedFormHistory.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testAResetNativeLedgerCannotProveThatTheOldPlanWasUnsent() async throws {
        let pending = try await stale(mutation: "document.getElementById('city').value = 'changed';")
        defer { pending.fixture.close() }
        let fixture = pending.fixture, owner = try fixture.owner()
        let other = ComputerUseBrowserTextTarget(browser: fixture.browser, document: pending.input.evidence.page.document, requiresFrontmost: false)
        _ = try await other.fields()
        do { _ = try await owner.retirePendingUnsentForm(); XCTFail("Only the original native ledger can establish absence") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        XCTAssertTrue(owner.hasPendingForm); XCTAssertTrue(owner.retiredFormHistory.isEmpty)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testRetiredJournalCannotBeRevivedThroughSaveBindingReplacementOrTextRecovery() async throws {
        let pending = try await stale(mutation: "document.getElementById('city').value = 'changed';")
        defer { pending.fixture.close() }
        let fixture = pending.fixture, owner = try fixture.owner()
        let result = try await owner.retirePendingUnsentForm(), retired = try XCTUnwrap(result)
        let stored = try journal(retired, fixture: fixture)
        let clear = ComputerUseTaskJournal(taskID: stored.taskID, promptDigest: stored.promptDigest,
            contractDigest: stored.contractDigest, stepIDs: stored.stepIDs, statuses: stored.statuses)
        let store = try ComputerUseTaskJournalStore(directory: formDirectory(retired, fixture: fixture))
        XCTAssertThrowsError(try store.save(clear, replacing: stored))
        XCTAssertThrowsError(try store.replaceUnattemptedBinding(clear, replacing: stored))
        XCTAssertThrowsError(try store.retireUnsent(stored, replacing: stored), "Retirement requires the caller's execution lease")
        let lease = try store.acquireExecution(taskID: stored.taskID, expected: stored)
        defer { lease.release() }
        try store.retireUnsent(stored, replacing: stored)
        let contract = try XCTUnwrap(pending.proposal.textContract(for: pending.input, stageID: retired.stageID))
        XCTAssertThrowsError(try ComputerUseTextTask(contract: contract, recovered: stored, read: { _ in nil },
            apply: { _, _ in XCTFail("No retired input") }, persist: { _ in XCTFail("No revived journal") }, mayAct: { true }))
        let unchanged = try store.load(taskID: stored.taskID)
        XCTAssertEqual(unchanged, stored)
    }

    func testAnotherExecutionLeaseBlocksRetirementBeforeNativeRevocation() async throws {
        let pending = try await stale(mutation: "document.getElementById('city').value = 'changed';")
        defer { pending.fixture.close() }
        let fixture = pending.fixture, owner = try fixture.owner()
        let root = fixture.directory.appendingPathComponent("Research/Research Forms")
        let paths = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let store = try ComputerUseTaskJournalStore(directory: XCTUnwrap(paths.first))
        let lease = try store.acquireExecution(taskID: owner.taskID, expected: nil)
        defer { lease.release() }
        do { _ = try await owner.retirePendingUnsentForm(); XCTFail("Another owner must finish first") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .busy) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .retireUnsentInputs }.count, 0)
        XCTAssertTrue(owner.hasPendingForm); XCTAssertTrue(owner.retiredFormHistory.isEmpty)
        lease.release()
        let retired = try await owner.retirePendingUnsentForm()
        XCTAssertNotNil(retired); XCTAssertFalse(owner.hasPendingForm)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testPostCommitPauseFinishesRetirementAdoptionWithoutDuplicateHistory() async throws {
        let pending = try await stale(mutation: "document.getElementById('city').value = 'changed';")
        defer { pending.fixture.close() }
        let fixture = pending.fixture, owner = try fixture.owner(), nextWrite = fixture.state.writes + 1
        fixture.state.onWrite = { if fixture.state.writes == nextWrite { owner.pause() } }
        do { _ = try await owner.retirePendingUnsentForm(); XCTFail("Pause closes the outer return") }
        catch { XCTAssertTrue(error is CancellationError || error as? ComputerUseBrowserResearchTask.Failure == .paused) }
        fixture.state.onWrite = nil
        XCTAssertTrue(owner.hasPendingForm); XCTAssertTrue(owner.retiredFormHistory.isEmpty)
        try await owner.resumeAfterUserControl()
        let retired = try await owner.retirePendingUnsentForm()
        XCTAssertNotNil(retired); XCTAssertEqual(owner.retiredFormHistory.count, 1)
        let duplicate = try await owner.retirePendingUnsentForm()
        XCTAssertNil(duplicate); XCTAssertEqual(owner.retiredFormHistory.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    private struct Pending {
        let fixture: ResearchDriverFixture
        let input: ComputerUseBrowserResearchFormInput
        let proposal: ComputerUseBrowserFormProposal
    }
    private func stale(mutation: String, dependent: Bool = false) async throws -> Pending {
        let fixture = try await make(mutation: mutation, initialCity: !dependent)
        do {
            let owner = try fixture.owner()
            if dependent {
                let input = try await prepare(fixture)
                let proposal = try ComputerUseBrowserFormProposal.decode(content: plan(input, city: false), input: input)
                _ = try await owner.executeForm(proposal, input: input)
            }
            let input = try await prepare(fixture)
            let proposal = try await owner.planForm(input, using: fixture.forms)
            try await wait { fixture.server.count("/signal") == 1 }
            fixture.server.releaseHeldResponses()
            try await wait { fixture.server.count("/changed") == 1 }
            do { _ = try await owner.executeForm(proposal, input: input); XCTFail("The stale preflight must send no input") }
            catch {
                XCTAssertTrue(error as? ComputerUseBrowserError == .pageChanged
                    || error as? ComputerUseBrowserResearchFormError == .inputChanged)
            }
            XCTAssertTrue(owner.hasPendingForm)
            return .init(fixture: fixture, input: input, proposal: proposal)
        } catch { fixture.close(); throw error }
    }
    private func make(mutation: String, initialCity: Bool = true) async throws -> ResearchDriverFixture {
        let body = """
            <form action='/filtered'><label>Category<select name='category'><option value=''>Choose</option><option value='concerts'>Concerts</option></select></label>
            <label>City<input id='city' name='city'></label><button>Search</button></form><label>Reference<input value='private-reference'></label>
            <script>fetch('/signal').then(() => { \(mutation) fetch('/changed'); });</script>
            """
        let fixture = try await ResearchDriverFixture.make(request: prompt, searchFormHTML: body, heldSignal: true)
        do {
            _ = try await fixture.start()
            fixture.actions.select = { input in
                let hasPrevious = !input.queryBoundControlIDs.isEmpty
                if let review = try FormEffectScopeFixture.response(input, editing: hasPrevious ? ["City":[0]] : (initialCity ? ["Category":[0],"City":[0]] : ["Category":[0]]),
                    retaining: hasPrevious ? ["Category":[0]] : [:], deferring: !hasPrevious && !initialCity ? ["City":[0]] : [:]) { return review }
                guard let form = input.evidence.page.controls.first(where: { $0.label == "Category" })?.form?.id else { return #"{"read_results":true}"# }
                if let query = input.queryControlIDs.first,
                   let verified = try self.object(input.contextJSON)["verified_form_stage"] as? [String: Any],
                   let rows = verified["edits"] as? [[String: Any]],
                   let cityID = input.evidence.page.controls.first(where: { $0.label == "City" })?.id,
                   rows.contains(where: { $0["control"] as? String == cityID }) { return try self.json(["query":query]) }
                let reference = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Reference" })
                return try self.json(["form":form,"preserve":[["control":reference.id,"requirement":0]]])
            }
            fixture.forms.select = { try self.plan($0, category: $0.previous == nil) }
            return fixture
        } catch { fixture.close(); throw error }
    }
    private func prepare(_ fixture: ResearchDriverFixture) async throws -> ComputerUseBrowserResearchFormInput {
        let owner = try fixture.owner(), action = try await owner.planNextAction(using: fixture.actions)
        return try await owner.prepareFormInput(for: action)
    }
    private func plan(_ input: ComputerUseBrowserResearchFormInput, category: Bool = true, city: Bool = true) throws -> String {
        var edits: [[String: Any]] = []
        if category {
            let alias = try self.alias("Category", in: input), field = try input.field(for: alias)
            let option = try XCTUnwrap(field.control.options.first { $0.label == "Concerts" })
            edits.append(["field":alias,"choice":option.id,"requirement":0])
        }
        if city { edits.append(["field":try alias("City", in: input),"terms":[["requirement":0,"text":"Paris"]]]) }
        return try json(["edits":edits,"preserve":[]])
    }
    private func alias(_ label: String, in input: ComputerUseBrowserResearchFormInput) throws -> String {
        try XCTUnwrap(input.fieldAliases.first { (try? input.field(for: $0).control.label) == label })
    }
    private func formDirectory(_ receipt: ComputerUseBrowserResearchFormStage.Retirement, fixture: ResearchDriverFixture) -> URL {
        fixture.directory.appendingPathComponent("Research/Research Forms").appendingPathComponent(receipt.stageID)
    }
    private func journal(_ receipt: ComputerUseBrowserResearchFormStage.Retirement, fixture: ResearchDriverFixture) throws -> ComputerUseTaskJournal {
        try XCTUnwrap(ComputerUseTaskJournalStore(directory: formDirectory(receipt, fixture: fixture)).load(taskID: fixture.owner().taskID))
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

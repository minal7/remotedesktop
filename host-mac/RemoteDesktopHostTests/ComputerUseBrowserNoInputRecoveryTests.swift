import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserNoInputRecoveryTests: XCTestCase {
    private let prompt = "Find concerts in Paris. Leave Reference unchanged. Do not buy."

    func testDefaultDriverReplansAnUncertainDiskAttemptOnlyAfterOriginalNativeAbsenceProof() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        _ = try await failWrite(fixture)
        let owner = try fixture.owner(), original = owner.input
        XCTAssertEqual(try journal(fixture).statuses, [.attempted, .planned])
        _ = try await fixture.resume()
        let retired = try XCTUnwrap(owner.retiredFormHistory.first)
        let history = try journal(fixture, stageID: retired.stageID)
        XCTAssertEqual(history.statuses, [.uncertain, .planned], "Keep the original recovery history")
        XCTAssertEqual(history.retirementDigest, retired.digest)
        XCTAssertEqual(owner.confirmedFormHistory.count, 1)
        XCTAssertNotEqual(owner.confirmedFormHistory.first?.stageID, retired.stageID)
        XCTAssertEqual(owner.input, original)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.server.count("/category-event"), 1); XCTAssertEqual(fixture.server.count("/city-event"), 1)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 1)
    }

    func testDirectRetirementPreservesAttemptedStatusInsteadOfDowngradingItToPlanned() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        _ = try await failWrite(fixture)
        let owner = try fixture.owner(), before = try journal(fixture)
        let result = try await owner.retirePendingUnsentForm(), retired = try XCTUnwrap(result)
        let after = try journal(fixture, stageID: retired.stageID)
        XCTAssertEqual(before.statuses, [.attempted, .planned]); XCTAssertEqual(after.statuses, before.statuses)
        XCTAssertEqual(after.stepIDs, before.stepIDs); XCTAssertEqual(after.contractDigest, before.contractDigest)
        XCTAssertEqual(after.promptDigest, before.promptDigest); XCTAssertEqual(after.retirementDigest, retired.digest)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        XCTAssertFalse(owner.hasPendingForm)
        _ = try await fixture.resume()
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
    }

    func testCancellationAfterDiskAttemptNeedsHandbackBeforeNativeProofAndReplanning() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let owner = try fixture.owner(), prepared = try await prepare(fixture), nextWrite = fixture.state.writes + 1
        fixture.state.onWrite = { if fixture.state.writes == nextWrite { owner.pause() } }
        do { _ = try await owner.executeForm(prepared.proposal, input: prepared.input); XCTFail("Pause before native input") }
        catch { XCTAssertTrue(error is CancellationError) }
        fixture.state.onWrite = nil
        XCTAssertEqual(try journal(fixture).statuses, [.attempted, .planned])
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        do { _ = try await owner.retirePendingUnsentForm(); XCTFail("User control remains exclusive") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .paused) }
        try await owner.resumeAfterUserControl()
        _ = try await fixture.resume()
        XCTAssertEqual(owner.retiredFormHistory.count, 1); XCTAssertEqual(owner.confirmedFormHistory.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.server.count("/category-event"), 1); XCTAssertEqual(fixture.server.count("/city-event"), 1)
    }

    func testAnyNativeAttemptBlocksRetirementEvenWhenItsCallbackOrFinalValueIsUncertain() async throws {
        for handler in ["const old = document.getElementById('category'); old.replaceWith(old.cloneNode(true));",
                        "document.getElementById('category').selectedIndex = 0;"] {
            let fixture = try await make(inputHandler: handler)
            defer { fixture.close() }
            let owner = try fixture.owner(), prepared = try await prepare(fixture)
            do { _ = try await owner.executeForm(prepared.proposal, input: prepared.input); XCTFail("The page interrupts the native commit tail") }
            catch { XCTAssertEqual(error as? ComputerUseTextEditError, .deliveryUncertain) }
            try await wait { fixture.server.count("/category-event") == 1 }
            let before = try journal(fixture)
            XCTAssertEqual(before.statuses, [.uncertain, .planned])
            let result = try await owner.retirePendingUnsentForm()
            XCTAssertNil(result); XCTAssertTrue(owner.hasPendingForm); XCTAssertTrue(owner.retiredFormHistory.isEmpty)
            XCTAssertEqual(try journal(fixture), before)
            _ = try await fixture.resume()
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
            XCTAssertEqual(fixture.server.count("/category-event"), 1); XCTAssertEqual(fixture.server.count("/city-event"), 0)
            XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 0)
        }
    }

    func testVerifiedPrefixAndUnsentSecondAttemptRemainAvailableForPerStepReconciliation() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        _ = try await failWrite(fixture, offset: 3)
        let owner = try fixture.owner(), before = try journal(fixture)
        XCTAssertEqual(before.statuses, [.verified, .attempted])
        let result = try await owner.retirePendingUnsentForm()
        XCTAssertNil(result); XCTAssertTrue(owner.hasPendingForm); XCTAssertTrue(owner.retiredFormHistory.isEmpty)
        XCTAssertEqual(try journal(fixture), before)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .retireUnsentInputs }.count, 0)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertTrue(owner.confirmedFormHistory.isEmpty, "A verified step is not the whole form stage")
    }

    func testLostLedgerDoesNotTurnAttemptedHistoryIntoProofOfNoInput() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let prepared = try await failWrite(fixture), owner = try fixture.owner(), before = try journal(fixture)
        let other = ComputerUseBrowserTextTarget(browser: fixture.browser, document: prepared.input.evidence.page.document, requiresFrontmost: false)
        _ = try await other.fields()
        do { _ = try await owner.retirePendingUnsentForm(); XCTFail("Unknown old ledger remains unresolved") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        XCTAssertEqual(try journal(fixture), before)
        XCTAssertTrue(owner.hasPendingForm); XCTAssertTrue(owner.retiredFormHistory.isEmpty)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
    }

    func testMatchingValuesStillNeedOriginalReceiptProofBeforeAReplacementPlanCanAct() async throws {
        let mutation = "document.getElementById('category').selectedIndex = 1; document.getElementById('city').value = 'Paris';"
        let fixture = try await make(mutation: mutation)
        defer { fixture.close() }
        _ = try await failWrite(fixture)
        try await wait { fixture.server.count("/signal") == 1 }
        fixture.server.releaseHeldResponses()
        try await wait { fixture.server.count("/changed") == 1 }
        XCTAssertEqual(fixture.server.count("/category-event"), 0); XCTAssertEqual(fixture.server.count("/city-event"), 0)
        _ = try await fixture.resume()
        let owner = try fixture.owner(), retired = try XCTUnwrap(owner.retiredFormHistory.first)
        XCTAssertEqual(try journal(fixture, stageID: retired.stageID).statuses, [.uncertain, .planned])
        XCTAssertEqual(owner.confirmedFormHistory.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.server.count("/category-event"), 1); XCTAssertEqual(fixture.server.count("/city-event"), 1)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 1)
    }

    func testFailedAttemptRetirementWriteKeepsOriginalStatusesAndResolvesWithoutNativeReplay() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        _ = try await failWrite(fixture)
        let owner = try fixture.owner()
        fixture.state.failureAtWrite = fixture.state.writes + 1
        do { _ = try await owner.retirePendingUnsentForm(); XCTFail("Keep the unconfirmed retirement") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
        fixture.state.failureAtWrite = nil
        let written = try journal(fixture)
        XCTAssertEqual(written.statuses, [.attempted, .planned]); XCTAssertNotNil(written.retirementDigest)
        do { _ = try await owner.resumeForm(); XCTFail("No old execution during retirement resolution") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchFormStage.Failure, .retirementPending) }
        let result = try await owner.retirePendingUnsentForm(), retired = try XCTUnwrap(result)
        XCTAssertEqual(try journal(fixture, stageID: retired.stageID), written)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .retireUnsentInputs }.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 0)
        _ = try await fixture.resume()
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
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
    private func failWrite(_ fixture: ResearchDriverFixture, offset: Int = 1) async throws -> Prepared {
        let owner = try fixture.owner(), prepared = try await prepare(fixture)
        fixture.state.failureAtWrite = fixture.state.writes + offset
        do { _ = try await owner.executeForm(prepared.proposal, input: prepared.input); XCTFail("The selected write must fail") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
        fixture.state.failureAtWrite = nil
        XCTAssertTrue(owner.hasPendingForm)
        return prepared
    }
    private func make(inputHandler: String = "", mutation: String = "") async throws -> ResearchDriverFixture {
        let body = """
            <form action='/filtered'><label>Category<select id='category' name='category'><option value=''>Choose</option><option value='concerts'>Concerts</option></select></label>
            <label>City<input id='city' name='city'></label><button>Search</button></form><label>Reference<input value='private-reference'></label>
            <script>
            document.getElementById('category').addEventListener('input', () => { fetch('/category-event'); \(inputHandler) });
            document.getElementById('city').addEventListener('input', () => fetch('/city-event'));
            fetch('/signal').then(() => { \(mutation) fetch('/changed'); });
            </script>
            """
        let fixture = try await ResearchDriverFixture.make(request: prompt, searchFormHTML: body, heldSignal: true)
        do {
            _ = try await fixture.start()
            fixture.actions.select = { input in
                if let review = try FormEffectScopeFixture.response(input, editing: ["Category":[0],"City":[0]]) { return review }
                if let query = input.queryControlIDs.first { return try self.json(["query":query]) }
                guard let form = input.evidence.page.controls.first(where: { $0.label == "Category" })?.form?.id else { return #"{"read_results":true}"# }
                let reference = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Reference" })
                return try self.json(["form":form,"preserve":[["control":reference.id,"requirement":0]]])
            }
            fixture.actions.beforeReply = {
                guard fixture.actions.inputs.last?.queryControlIDs.isEmpty == false else { return }
                try await self.wait { fixture.server.count("/category-event") == 1 && fixture.server.count("/city-event") == 1 }
            }
            fixture.forms.select = { input in
                let category = try self.alias("Category", input), control = try input.field(for: category).control
                let option = try XCTUnwrap(control.options.first { $0.label == "Concerts" })
                return try self.json(["edits":[["field":category,"choice":option.id,"requirement":0],
                    ["field":try self.alias("City", input),"terms":[["requirement":0,"text":"Paris"]]]],"preserve":[]])
            }
            return fixture
        } catch { fixture.close(); throw error }
    }
    private func alias(_ label: String, _ input: ComputerUseBrowserResearchFormInput) throws -> String {
        try XCTUnwrap(input.fieldAliases.first { (try? input.field(for: $0).control.label) == label })
    }
    private func journal(_ fixture: ResearchDriverFixture, stageID: String? = nil) throws -> ComputerUseTaskJournal {
        let root = fixture.directory.appendingPathComponent("Research/Research Forms"), directory: URL
        if let stageID { directory = root.appendingPathComponent(stageID) }
        else {
            let paths = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            XCTAssertEqual(paths.count, 1)
            directory = try XCTUnwrap(paths.first)
        }
        return try XCTUnwrap(ComputerUseTaskJournalStore(directory: directory).load(taskID: fixture.owner().taskID))
    }
    private func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserError.documentUnresponsive }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

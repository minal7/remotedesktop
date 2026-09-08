import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserPendingChangeTests: XCTestCase {
    private let prompt = "Find concerts in Paris. Leave Reference unchanged. Do not buy."

    func testResearchDriverCompletesOnlyTheMissingChangeEventAfterExplicitLoginHandback() async throws {
        let fixture = try await pending()
        defer { fixture.close() }
        let owner = try fixture.owner(), original = owner.input, before = try journal(fixture)
        XCTAssertEqual(before.statuses, [.uncertain, .planned])
        XCTAssertEqual(fixture.server.count("/category-input"), 1); XCTAssertEqual(fixture.server.count("/category-change"), 0)
        do { _ = try await owner.resumeForm(); XCTFail("User control remains exclusive") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .paused) }
        do { try await owner.resumeAfterUserControl(); XCTFail("A visible login cannot count as handback") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        XCTAssertEqual(fixture.state.commands.filter { $0 == .finishPendingChange }.count, 0)
        try await clearLogin(fixture)
        try await owner.resumeAfterUserControl()
        _ = try await fixture.resume()
        let receipt = try XCTUnwrap(owner.confirmedFormHistory.first), after = try journal(fixture)
        XCTAssertEqual(after.stepIDs, before.stepIDs); XCTAssertEqual(after.contractDigest, before.contractDigest)
        XCTAssertEqual(after.statuses, [.verified, .verified]); XCTAssertNil(after.retirementDigest)
        XCTAssertEqual(receipt.editCount, 2); XCTAssertTrue(receipt.isCompleteStage)
        XCTAssertTrue(owner.retiredFormHistory.isEmpty); XCTAssertEqual(owner.input, original)
        XCTAssertEqual(fixture.forms.inputs.count, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.server.count("/category-input"), 1); XCTAssertEqual(fixture.server.count("/category-change"), 1)
        XCTAssertEqual(fixture.server.count("/city-input"), 1)
        XCTAssertEqual(fixture.server.count("/input-order?value=category-input%2Ccategory-change%2Ccity-input"), 1)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 1)
    }

    func testCurrentFormExecutorUsesTheSameOriginalInputIdentityWithoutReplanning() async throws {
        let fixture = try await make()
        defer { fixture.close() }
        let planner = PendingChangeTextPlanner()
        let directory = fixture.directory.appendingPathComponent("Native Text")
        let executor = ComputerUseNativeTextExecutor(injector: InputInjector(), mayAct: { fixture.state.allowed },
            journalDirectory: directory, planner: planner, browserTargetProvider: { taskID in
                ComputerUseBrowserTextTarget(browser: fixture.browser,
                    document: try fixture.browser.acquireCurrentDocument(taskID: taskID), requiresFrontmost: false)
            })
        let taskID = ResearchDriverFixture.root
        do { _ = try await executor.execute(taskID: taskID, prompt: prompt, progress: { _ in }); XCTFail("Login interrupts the scalar commit") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        try await wait { fixture.server.count("/signal") == 1 && fixture.server.count("/category-input") == 1 }
        let before = try XCTUnwrap(ComputerUseTaskJournalStore(directory: directory).load(taskID: taskID))
        fixture.state.allowed = false
        do { _ = try await executor.execute(taskID: taskID, prompt: prompt, progress: { _ in }); XCTFail("No effect without control") }
        catch { XCTAssertEqual(error as? ComputerUseTextEditError, .interrupted) }
        try await clearLogin(fixture)
        fixture.state.allowed = true
        let result = try await executor.execute(taskID: taskID, prompt: prompt, progress: { _ in })
        guard case .completed? = result else { return XCTFail("The original task must verify both entries") }
        try await wait { fixture.server.count("/category-change") == 1 && fixture.server.count("/city-input") == 1 }
        _ = try await executor.execute(taskID: taskID, prompt: prompt, progress: { _ in })
        let after = try XCTUnwrap(ComputerUseTaskJournalStore(directory: directory).load(taskID: taskID))
        XCTAssertEqual(after.stepIDs, before.stepIDs); XCTAssertEqual(after.statuses, [.verified, .verified])
        XCTAssertEqual(planner.calls, 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .finishPendingChange }.count, 1)
        XCTAssertEqual(fixture.server.count("/category-input"), 1); XCTAssertEqual(fixture.server.count("/category-change"), 1)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 0)
    }

    func testChangedValueObjectConstraintsOrLedgerCannotCompleteTheOldTail() async throws {
        let mutations = ["document.getElementById('category').selectedIndex = 0;",
            "const old = document.getElementById('category'); old.replaceWith(old.cloneNode(true));",
            "document.getElementById('category').options[1].disabled = true;", ""]
        for mutation in mutations {
            let fixture = try await pending(afterLogin: mutation)
            defer { fixture.close() }
            let owner = try fixture.owner(), before = try journal(fixture)
            try await clearLogin(fixture)
            try await owner.resumeAfterUserControl()
            if mutation.isEmpty {
                let document = try fixture.browser.acquireCurrentDocument(taskID: owner.taskID)
                _ = try await ComputerUseBrowserTextTarget(browser: fixture.browser, document: document, requiresFrontmost: false).fields()
            }
            _ = try await fixture.resume()
            XCTAssertEqual(try journal(fixture), before)
            XCTAssertTrue(owner.hasPendingForm); XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
            XCTAssertTrue(owner.retiredFormHistory.isEmpty)
            XCTAssertEqual(fixture.server.count("/category-input"), 1)
            XCTAssertEqual(fixture.server.count("/category-change"), 0); XCTAssertEqual(fixture.server.count("/city-input"), 0)
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        }
    }

    func testChangedPreservationBlocksThePendingTailBeforeNativeContinuation() async throws {
        let fixture = try await pending(afterLogin: "document.getElementById('reference').value = 'changed';")
        defer { fixture.close() }
        let owner = try fixture.owner(), before = try journal(fixture)
        try await clearLogin(fixture)
        try await owner.resumeAfterUserControl()
        _ = try await fixture.resume()
        XCTAssertEqual(try journal(fixture), before)
        XCTAssertEqual(fixture.server.count("/category-change"), 0); XCTAssertEqual(fixture.server.count("/city-input"), 0)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .finishPendingChange }.count, 0, "The earlier invariant check already rejects this change")
        XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
    }

    func testInputHandlerChangingAPreservedValueWithholdsChangeUntilThatExactValueIsRestored() async throws {
        let fixture = try await make(login: false, inputHandler: "document.getElementById('reference').value = 'changed';",
            afterLogin: "document.getElementById('reference').value = 'private-reference';")
        defer { fixture.close() }
        let owner = try fixture.owner()
        _ = try await fixture.resume()
        try await wait { fixture.server.count("/signal") == 1 && fixture.server.count("/category-input") == 1 }
        XCTAssertTrue(owner.hasPendingForm); XCTAssertEqual(try journal(fixture).statuses, [.uncertain, .planned])
        XCTAssertEqual(fixture.server.count("/category-change"), 0)
        owner.pause()
        try await clearLogin(fixture)
        try await owner.resumeAfterUserControl()
        _ = try await fixture.resume()
        XCTAssertEqual(fixture.server.count("/category-input"), 1); XCTAssertEqual(fixture.server.count("/category-change"), 1)
        XCTAssertEqual(fixture.server.count("/city-input"), 1)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 1)
    }

    func testACompletedChangeThatFailsItsOutcomeCannotBeResentByRepeatedResume() async throws {
        let fixture = try await pending(changeHandler: "document.getElementById('category').selectedIndex = 0;")
        defer { fixture.close() }
        let owner = try fixture.owner()
        try await clearLogin(fixture)
        try await owner.resumeAfterUserControl()
        _ = try await fixture.resume()
        try await wait { fixture.server.count("/category-change") == 1 }
        _ = try await fixture.resume()
        XCTAssertEqual(try journal(fixture).statuses, [.uncertain, .planned])
        XCTAssertTrue(owner.hasPendingForm); XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
        XCTAssertTrue(owner.retiredFormHistory.isEmpty)
        XCTAssertEqual(fixture.server.count("/category-input"), 1); XCTAssertEqual(fixture.server.count("/category-change"), 1)
        XCTAssertEqual(fixture.server.count("/city-input"), 0)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 1)
        XCTAssertEqual(fixture.server.count("/filtered?category=concerts&city=Paris"), 0)
    }

    func testPauseDuringTheTailKeepsTheExecutionLeaseAndCannotDuplicateEitherEvent() async throws {
        let fixture = try await pending()
        defer { fixture.close() }
        let owner = try fixture.owner(), before = try journal(fixture)
        let other = try ComputerUseTaskJournalStore(directory: formDirectory(fixture))
        try await clearLogin(fixture)
        try await owner.resumeAfterUserControl()
        var excluded = false
        fixture.state.onCommand = { command in
            guard command == .finishPendingChange else { return }
            fixture.state.onCommand = nil
            do {
                let lease = try other.acquireExecution(taskID: before.taskID, expected: before)
                lease.release(); XCTFail("Native completion must retain execution exclusion")
            } catch { excluded = error as? ComputerUseTaskJournalStore.StoreError == .busy }
            owner.pause()
        }
        do { _ = try await fixture.resume(); XCTFail("Pause closes the pending return") }
        catch { XCTAssertTrue(error is CancellationError || error as? ComputerUseBrowserResearchTask.Failure == .paused) }
        XCTAssertTrue(excluded); XCTAssertFalse(owner.isOperating)
        let lease = try other.acquireExecution(taskID: before.taskID, expected: journal(fixture))
        lease.release()
        try await owner.resumeAfterUserControl()
        _ = try await fixture.resume()
        XCTAssertEqual(fixture.server.count("/category-input"), 1); XCTAssertEqual(fixture.server.count("/category-change"), 1)
        XCTAssertEqual(fixture.server.count("/city-input"), 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertEqual(owner.confirmedFormHistory.count, 1)
    }

    func testAWriteFailureAfterTailVerificationRecoversFromTheOriginalNativeReceipt() async throws {
        let fixture = try await pending()
        defer { fixture.close() }
        let owner = try fixture.owner(), before = try journal(fixture)
        try await clearLogin(fixture)
        try await owner.resumeAfterUserControl()
        fixture.state.failureAtWrite = fixture.state.writes + 1
        _ = try await fixture.resume()
        fixture.state.failureAtWrite = nil
        XCTAssertEqual(try journal(fixture).statuses, [.verified, .planned])
        XCTAssertTrue(owner.hasPendingForm); XCTAssertTrue(owner.confirmedFormHistory.isEmpty)
        _ = try await fixture.resume()
        XCTAssertEqual(try journal(fixture).stepIDs, before.stepIDs)
        XCTAssertEqual(try journal(fixture).statuses, [.verified, .verified])
        XCTAssertEqual(fixture.server.count("/category-input"), 1); XCTAssertEqual(fixture.server.count("/category-change"), 1)
        XCTAssertEqual(fixture.server.count("/city-input"), 1)
        XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
        XCTAssertTrue(owner.retiredFormHistory.isEmpty)
    }

    func testPendingAttemptConfirmationRequiresExactUnretiredStateAndTheCallersLease() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var fail = true
        let store = try ComputerUseTaskJournalStore(directory: directory, afterReplacement: {
            if fail { throw ComputerUseTaskJournalStore.StoreError.unavailable }
        })
        func state(_ status: ComputerUseTaskStepStatus, retirement: String? = nil) -> ComputerUseTaskJournal {
            .init(taskID: "pending-tail", promptDigest: ComputerUseTaskContract.digest(["prompt"]),
                contractDigest: ComputerUseTaskContract.digest(["contract"]), stepIDs: ["step"], statuses: [status], retirementDigest: retirement)
        }
        let attempted = state(.attempted)
        XCTAssertThrowsError(try store.save(attempted, replacing: nil))
        fail = false
        XCTAssertThrowsError(try store.confirmPendingAttempt(attempted), "A poisoned writer cannot confirm the attempt")
        let fresh = try ComputerUseTaskJournalStore(directory: directory)
        XCTAssertEqual(try fresh.load(taskID: attempted.taskID), attempted)
        XCTAssertThrowsError(try fresh.confirmPendingAttempt(attempted), "No caller-owned execution lease")
        let lease = try fresh.acquireExecution(taskID: attempted.taskID, expected: attempted)
        defer { lease.release() }
        try fresh.confirmPendingAttempt(attempted)
        for invalid in [state(.planned), state(.verified), state(.attempted, retirement: ComputerUseTaskContract.digest(["retired"]))] {
            XCTAssertThrowsError(try fresh.confirmPendingAttempt(invalid))
        }
        XCTAssertThrowsError(try fresh.confirmPendingAttempt(state(.uncertain)), "Exact compare-and-swap is required")
        XCTAssertEqual(try fresh.load(taskID: attempted.taskID), attempted)
        try fresh.save(state(.uncertain), replacing: attempted)
        try fresh.confirmPendingAttempt(state(.uncertain))
        XCTAssertEqual(try fresh.load(taskID: attempted.taskID)?.statuses, [.uncertain])
    }

    func testNativeDateAndNumberInputsCompleteTheirOriginalChangeNotificationAfterLogin() async throws {
        for (kind, value) in [("date", "2026-03-08"), ("number", "2")] {
            let fixture = try await make(scalarType: kind)
            defer { fixture.close() }
            let executor = ComputerUseNativeTextExecutor(injector: InputInjector(), mayAct: { true },
                journalDirectory: fixture.directory.appendingPathComponent("Native Text"), planner: PendingChangeTextPlanner(value: value),
                browserTargetProvider: { taskID in
                    ComputerUseBrowserTextTarget(browser: fixture.browser,
                        document: try fixture.browser.acquireCurrentDocument(taskID: taskID), requiresFrontmost: false)
                })
            let request = "Enter \(value) in Category and Paris in City. Leave Reference unchanged."
            do { _ = try await executor.execute(taskID: ResearchDriverFixture.root, prompt: request, progress: { _ in }); XCTFail("Login interrupts the native scalar tail") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
            try await wait { fixture.server.count("/signal") == 1 && fixture.server.count("/category-input") == 1 }
            XCTAssertEqual(fixture.server.count("/category-change"), 0)
            try await clearLogin(fixture)
            let result = try await executor.execute(taskID: ResearchDriverFixture.root, prompt: request, progress: { _ in })
            guard case .completed? = result else { return XCTFail("Exact native scalar and City values must be verified") }
            try await wait { fixture.server.count("/category-change") == 1 && fixture.server.count("/city-input") == 1 }
            XCTAssertEqual(fixture.state.commands.filter { $0 == .edit }.count, 2)
            XCTAssertEqual(fixture.server.count("/category-input"), 1); XCTAssertEqual(fixture.server.count("/category-change"), 1)
        }
    }

    private func pending(afterLogin: String = "", changeHandler: String = "") async throws -> ResearchDriverFixture {
        let fixture = try await make(afterLogin: afterLogin, changeHandler: changeHandler)
        do {
            do { _ = try await fixture.resume(); XCTFail("The input event reveals login before its change tail") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
            let owner = try fixture.owner()
            owner.pause()
            try await wait { fixture.server.count("/signal") == 1 && fixture.server.count("/category-input") == 1 }
            return fixture
        } catch { fixture.close(); throw error }
    }
    private func make(login: Bool = true, inputHandler: String = "", afterLogin: String = "", changeHandler: String = "",
                      scalarType: String? = nil) async throws -> ResearchDriverFixture {
        let auth = login ? "document.getElementById('login').innerHTML = '<label>Password<input type=password></label>';" : ""
        let control = scalarType.map { "<input id='category' name='category' type='\($0)' value='\($0 == "date" ? "2026-01-01" : "1")'>" }
            ?? "<select id='category' name='category'><option value=''>Choose</option><option value='concerts'>Concerts</option></select>"
        let body = """
            <form action='/filtered'><label>Category\(control)</label>
            <label>City<input id='city' name='city'></label><button>Search</button></form>
            <label>Reference<input id='reference' value='private-reference'></label><div id='login'></div>
            <script>
            let began = false; const order = [];
            document.getElementById('category').addEventListener('input', () => {
              order.push('category-input'); fetch('/category-input'); \(inputHandler)
              if (began) return; began = true;
              \(auth)
              fetch('/signal').then(() => { document.getElementById('login').replaceChildren(); \(afterLogin) fetch('/login-cleared'); });
            });
            document.getElementById('category').addEventListener('change', () => {
              order.push('category-change'); fetch('/category-change'); \(changeHandler)
            });
            document.getElementById('city').addEventListener('input', () => {
              order.push('city-input'); fetch('/city-input'); fetch('/input-order?value=' + encodeURIComponent(order.join(',')));
            });
            </script>
            """
        let fixture = try await ResearchDriverFixture.make(request: prompt, searchFormHTML: body, heldSignal: true)
        do {
            _ = try await fixture.start()
            fixture.actions.select = { input in
                if let query = input.queryControlIDs.first { return try self.json(["query":query]) }
                guard let form = input.evidence.page.controls.first(where: { $0.label == "Category" })?.form?.id else { return #"{"read_results":true}"# }
                let reference = try XCTUnwrap(input.evidence.page.controls.first { $0.label == "Reference" })
                return try self.json(["form":form,"preserve":[["control":reference.id,"requirement":0]]])
            }
            fixture.actions.beforeReply = {
                guard fixture.actions.inputs.last?.queryControlIDs.isEmpty == false else { return }
                try await self.wait { fixture.server.count("/category-input") == 1 && fixture.server.count("/category-change") == 1
                    && fixture.server.count("/city-input") == 1
                    && fixture.server.count("/input-order?value=category-input%2Ccategory-change%2Ccity-input") == 1 }
            }
            fixture.forms.select = { input in
                let category = try self.alias("Category", input), choice = try XCTUnwrap(input.field(for: category).control.options.first { $0.label == "Concerts" })
                return try self.json(["edits":[["field":category,"choice":choice.id,"requirement":0],
                    ["field":try self.alias("City", input),"terms":[["requirement":0,"text":"Paris"]]]],"preserve":[]])
            }
            return fixture
        } catch { fixture.close(); throw error }
    }
    private func clearLogin(_ fixture: ResearchDriverFixture) async throws {
        fixture.server.releaseHeldResponses()
        try await wait { fixture.server.count("/login-cleared") == 1 }
    }
    private func formDirectory(_ fixture: ResearchDriverFixture) throws -> URL {
        let paths = try FileManager.default.contentsOfDirectory(at: fixture.directory.appendingPathComponent("Research/Research Forms"), includingPropertiesForKeys: nil)
        XCTAssertEqual(paths.count, 1)
        return try XCTUnwrap(paths.first)
    }
    private func journal(_ fixture: ResearchDriverFixture) throws -> ComputerUseTaskJournal {
        try XCTUnwrap(ComputerUseTaskJournalStore(directory: formDirectory(fixture)).load(taskID: fixture.owner().taskID))
    }
    private func alias(_ label: String, _ input: ComputerUseBrowserResearchFormInput) throws -> String {
        try XCTUnwrap(input.fieldAliases.first { (try? input.field(for: $0).control.label) == label })
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

@MainActor
private final class PendingChangeTextPlanner: ComputerUseTextGoalPlanning {
    var calls = 0
    let value: String
    init(value: String = "Concerts") { self.value = value }
    func propose(prompt: String, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
        calls += 1
        let category = try XCTUnwrap(fields.first { $0.label == "Category" })
        let city = try XCTUnwrap(fields.first { $0.label == "City" })
        let reference = try XCTUnwrap(fields.first { $0.label == "Reference" })
        return .edits([.init(targetID: category.snapshot.targetID, mode: .replaceAll, text: value),
            .init(targetID: city.snapshot.targetID, mode: .replaceAll, text: "Paris")], unchangedTargetIDs: [reference.snapshot.targetID])
    }
}

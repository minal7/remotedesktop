import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseNativeTextRecoveryTests: XCTestCase {
    func testFailedVerifiedReplacementReopensStorageWithoutLosingNativeDeliveryEvidence() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        fixture.failWrite = 2
        let executor = fixture.executor()
        do { _ = try await fixture.run(executor); XCTFail("The directory commit was not acknowledged") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
        let before = try fixture.journal()
        XCTAssertEqual(before.statuses, [.verified]); XCTAssertEqual(fixture.edits, ["Paris"])
        let result = try await fixture.run(executor)
        guard case .completed? = result else { return XCTFail("Retained local delivery evidence must survive reopening") }
        XCTAssertEqual(try fixture.journal(), before)
        XCTAssertEqual(fixture.stores, 2); XCTAssertEqual(fixture.planner.goals.count, 1)
        XCTAssertEqual(fixture.fields.discoveries, 1); XCTAssertEqual(fixture.edits, ["Paris"])
        fixture.fields.value = "changed"
        do { _ = try await fixture.run(executor); XCTFail("A durable verified flag cannot replace current outcome evidence") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .incompleteOutcome) }
        XCTAssertEqual(fixture.edits, ["Paris"])
    }

    func testFailureBeforeOpeningTheFirstStoreRetainsTheOriginalPlanForRetry() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        fixture.failStore = 1
        let executor = fixture.executor()
        do { _ = try await fixture.run(executor); XCTFail("Storage unavailable") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
        XCTAssertTrue(fixture.edits.isEmpty)
        XCTAssertFalse(try ComputerUseTextStepStore.hasJournal(taskID: fixture.taskID, directory: fixture.directory))
        let result = try await fixture.run(executor)
        guard case .completed? = result else { return XCTFail("Retry must use the retained original task") }
        XCTAssertEqual(fixture.stores, 2); XCTAssertEqual(fixture.planner.goals.count, 1)
        XCTAssertEqual(fixture.fields.discoveries, 1); XCTAssertEqual(fixture.edits, ["Paris"])
    }

    func testVisibleFailedAttemptCannotBeReplayedOrVerifiedFromAnEqualValue() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        fixture.failWrite = 1
        let executor = fixture.executor()
        do { _ = try await fixture.run(executor); XCTFail("Attempt commit failed before dispatch") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
        XCTAssertEqual(try fixture.journal().statuses, [.attempted]); XCTAssertTrue(fixture.edits.isEmpty)
        fixture.fields.value = "Paris" // Another actor's equal value is not this task's delivery receipt.
        for _ in 0..<2 {
            do { _ = try await fixture.run(executor); XCTFail("Unproven attempt remains pending") }
            catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .uncertainEffect) }
        }
        XCTAssertEqual(try fixture.journal().statuses, [.uncertain]); XCTAssertTrue(fixture.edits.isEmpty)
        XCTAssertEqual(fixture.planner.goals.count, 1); XCTAssertEqual(fixture.fields.discoveries, 1)
    }

    func testMissingRewoundForeignOrRetiredStorageCannotResetAcknowledgedWork() async throws {
        for mutation in ["missing", "rewound", "foreign", "retired"] {
            let fixture = RecoveryFixture()
            defer { fixture.close() }
            let executor = fixture.executor()
            _ = try await fixture.run(executor)
            let saved = try fixture.journal()
            if mutation == "missing" { try FileManager.default.removeItem(at: fixture.file) }
            else {
                let changed = ComputerUseTaskJournal(taskID: saved.taskID, promptDigest: saved.promptDigest,
                    contractDigest: mutation == "foreign" ? String(repeating: "f", count: 64) : saved.contractDigest,
                    stepIDs: saved.stepIDs, statuses: mutation == "foreign" ? [.verified] : [.attempted],
                    retirementDigest: mutation == "retired" ? String(repeating: "a", count: 64) : nil)
                try JSONEncoder().encode(changed).write(to: fixture.file)
            }
            do { _ = try await fixture.run(executor); XCTFail("Changed history cannot authorize a fresh edit: " + mutation) }
            catch { XCTAssertTrue(error as? ComputerUseTextTaskError == .journalMismatch
                || error as? ComputerUseTaskJournalStore.StoreError == .invalidTransition, mutation) }
            XCTAssertEqual(fixture.edits, ["Paris"]); XCTAssertEqual(fixture.planner.goals.count, 1)
            XCTAssertEqual(fixture.fields.discoveries, 1)
        }
    }

    func testReplacementExecutorRejectsExistingHistoryBeforeDiscoveryProviderOrPlanning() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        _ = try await fixture.run(fixture.executor())
        var providerCalls = 0
        for corrupt in [false, true] {
            if corrupt { try Data("invalid journal".utf8).write(to: fixture.file) }
            let replacement = fixture.executor(browserProvider: { _ in providerCalls += 1; return nil })
            do { _ = try await fixture.run(replacement); XCTFail("Journal presence requires retained authority") }
            catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .journalMismatch) }
        }
        XCTAssertEqual(providerCalls, 0); XCTAssertEqual(fixture.fields.discoveries, 1)
        XCTAssertEqual(fixture.planner.goals.count, 1); XCTAssertEqual(fixture.edits, ["Paris"])
    }

    func testJournalAppearingDuringPlanningCannotBeAdoptedByANewSession() async throws {
        let prior = RecoveryFixture(), fixture = RecoveryFixture()
        defer { prior.close(); fixture.close() }
        _ = try await prior.run(prior.executor())
        let saved = try prior.journal()
        fixture.planner.beforeReply = {
            let store = try ComputerUseTaskJournalStore(directory: fixture.directory)
            // Fixture simulates another executor's completed exact contract.
            try JSONEncoder().encode(saved).write(to: fixture.file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.path)
            _ = store
        }
        let executor = fixture.executor()
        do { _ = try await fixture.run(executor); XCTFail("No adoption after discovery/planning races") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .journalMismatch) }
        XCTAssertTrue(fixture.edits.isEmpty); XCTAssertEqual(try fixture.journal(), saved)
    }

    func testExecutionExclusionPrecedesRecoveryObservationAndReleasesForTheNextRun() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        let executor = fixture.executor()
        _ = try await fixture.run(executor)
        let store = try ComputerUseTaskJournalStore(directory: fixture.directory), saved = try fixture.journal()
        let lease = try store.acquireExecution(taskID: fixture.taskID, expected: saved)
        defer { lease.release() }
        let reads = fixture.fields.reads
        do { _ = try await fixture.run(executor); XCTFail("Another owner holds the execution lease") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .busy) }
        XCTAssertEqual(fixture.fields.reads, reads); XCTAssertEqual(fixture.edits, ["Paris"])
        lease.release()
        _ = try await fixture.run(executor)
        XCTAssertEqual(fixture.edits, ["Paris"]); XCTAssertEqual(fixture.planner.goals.count, 1)
    }

    func testClarificationWriteFailureRetainsExactOriginalGoalQuestionAndAnswer() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        fixture.planner.askFirst = true; fixture.failWrite = 2
        let executor = fixture.executor()
        guard case .clarificationRequired? = try await fixture.run(executor) else { return XCTFail("Expected a question") }
        let question = try XCTUnwrap(executor.clarification(taskID: fixture.taskID))
        let goal = try question.goal.answering(question.question, with: "City should contain Paris")
        do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: fixture.taskID, goal: goal, progress: { _ in })
            XCTFail("The answer's verified replacement was not committed") }
        catch { XCTAssertEqual(error as? ComputerUseTaskJournalStore.StoreError, .unavailable) }
        let changed = try question.goal.answering(question.question, with: "City should contain Rome")
        do { _ = try await executor.continueClarification(taskID: "answer", originatingTaskID: fixture.taskID, goal: changed, progress: { _ in })
            XCTFail("Retry cannot replace the accepted answer") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .journalMismatch) }
        let result = try await executor.continueClarification(taskID: "answer", originatingTaskID: fixture.taskID, goal: goal, progress: { _ in })
        guard case .completed = result else { return XCTFail("Original accepted goal must finish") }
        XCTAssertEqual(fixture.planner.goals, [question.goal, goal]); XCTAssertEqual(fixture.edits, ["Paris"])
    }

    func testRecoveredProgressConfirmationRequiresTheExactFreshStoreAndItsExecutionLease() async throws {
        let fixture = RecoveryFixture()
        defer { fixture.close() }
        _ = try await fixture.run(fixture.executor())
        let saved = try fixture.journal(), store = try ComputerUseTaskJournalStore(directory: fixture.directory)
        XCTAssertThrowsError(try store.confirmRecoveredProgress(saved)) { XCTAssertEqual($0 as? ComputerUseTaskJournalStore.StoreError, .busy) }
        let lease = try store.acquireExecution(taskID: fixture.taskID, expected: saved)
        defer { lease.release() }
        try store.confirmRecoveredProgress(saved)
        var wrong = saved; wrong.statuses = [.attempted]
        XCTAssertThrowsError(try store.confirmRecoveredProgress(wrong)) { XCTAssertEqual($0 as? ComputerUseTaskJournalStore.StoreError, .staleJournal) }
        let other = try ComputerUseTaskJournalStore(directory: fixture.directory)
        XCTAssertThrowsError(try other.confirmRecoveredProgress(saved)) { XCTAssertEqual($0 as? ComputerUseTaskJournalStore.StoreError, .busy) }
        XCTAssertEqual(try fixture.journal(), saved)
        lease.release()
        XCTAssertThrowsError(try store.confirmRecoveredProgress(saved))
    }
}

@MainActor
private final class RecoveryFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let taskID = "native-recovery", prompt = "Please put Paris in City and keep Reference unchanged."
    let fields = RecoveryFields(), planner = RecoveryPlanner()
    var edits: [String] = [], stores = 0, writes = 0, failStore: Int?, failWrite: Int?
    var file: URL { directory.appendingPathComponent(ComputerUseTextTaskContract.digest(taskID) + ".json") }
    func executor(browserProvider: (@MainActor (String) async throws -> ComputerUseBrowserTextTarget?)? = nil) -> ComputerUseNativeTextExecutor {
        ComputerUseNativeTextExecutor(injector: InputInjector(), mayAct: { true }, journalDirectory: directory,
            planner: planner, editOverride: { [self] edit, expected in
                XCTAssertEqual(fields.snapshot(targetID: edit.targetID), expected)
                edits.append(edit.text); fields.value = edit.text
            }, browserTargetProvider: browserProvider, nativeTarget: fields, planningWorker: ComputerUsePlanningWorker(),
            makeJournalStore: { [self] directory in
                stores += 1
                if stores == failStore { throw ComputerUseTaskJournalStore.StoreError.unavailable }
                return try ComputerUseTaskJournalStore(directory: directory, afterReplacement: { [self] in
                    try MainActor.assumeIsolated {
                        writes += 1
                        if writes == failWrite { throw ComputerUseTaskJournalStore.StoreError.unavailable }
                    }
                })
            })
    }
    func run(_ executor: ComputerUseNativeTextExecutor) async throws -> ComputerUseExecutionResult? {
        try await executor.execute(taskID: taskID, prompt: prompt, progress: { _ in })
    }
    func journal() throws -> ComputerUseTaskJournal {
        try XCTUnwrap(ComputerUseTaskJournalStore(directory: directory).load(taskID: taskID))
    }
    func close() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
private final class RecoveryPlanner: ComputerUseTextGoalPlanning {
    var goals: [ComputerUseUnresolvedTextGoal] = [], askFirst = false
    var beforeReply: (() throws -> Void)?
    func propose(prompt: String, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
        try await propose(goal: ComputerUseUnresolvedTextGoal(userRequest: prompt), fields: fields)
    }
    func propose(goal: ComputerUseUnresolvedTextGoal, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
        goals.append(goal); try beforeReply?()
        if askFirst && goals.count == 1 { return .clarification }
        return .edits([.init(targetID: "city", mode: .replaceAll, text: "Paris")], unchangedTargetIDs: ["reference"])
    }
}

@MainActor
private final class RecoveryFields: ComputerUseNativeTextTarget {
    var value = "old", discoveries = 0, reads = 0
    func fields() -> [ComputerUseTextField] {
        discoveries += 1
        return ["city", "reference"].compactMap { id in snapshot(targetID: id).map { .init(label: id.capitalized, snapshot: $0) } }
    }
    func snapshot() -> ComputerUseTextSnapshot? { snapshot(targetID: "city") }
    func snapshot(targetID: String) -> ComputerUseTextSnapshot? {
        reads += 1
        guard ["city", "reference"].contains(targetID) else { return nil }
        let text = targetID == "city" ? value : "keep"
        return .init(targetID: targetID, value: text, selection: NSRange(location: text.utf16.count, length: 0), isEditable: true, isSecure: false)
    }
    func focus(expected: ComputerUseTextSnapshot) throws -> Bool { XCTFail("Fixture must not post native input"); return false }
    func select(_ range: NSRange, expected: ComputerUseTextSnapshot) throws -> Bool { XCTFail("Unexpected selection"); return false }
    func replaceSelectedText(_ text: String, expected: ComputerUseTextSnapshot) throws -> Bool? { XCTFail("Unexpected native input"); return nil }
    func replaceWebValue(_ value: String, expected: ComputerUseTextSnapshot) throws -> Bool? { XCTFail("Unexpected native input"); return nil }
}

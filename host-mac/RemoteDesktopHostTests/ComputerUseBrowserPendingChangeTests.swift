import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserPendingChangeTests: XCTestCase {
    private let prompt = "Find concerts in Paris. Leave Reference unchanged. Do not buy."

    private final class UnsentWriteState { var writes = 0, stores = 0 }

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

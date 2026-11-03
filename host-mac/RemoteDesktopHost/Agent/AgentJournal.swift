import CryptoKit
import Foundation

/// Reuses the existing locked, fsync-backed store. An uncertain input is never replayed.
@MainActor
final class AgentJournal: AgentEffectJournaling {
    enum Failure: Error { case uncertainEffect, alreadyPerformed, mismatch, invalidStep }
    private let taskID: String
    private let promptDigest: String
    private let maxSteps: Int
    private let store: ComputerUseTaskJournalStore
    private let taskLease: any ComputerUseTaskExecutionLease
    private var effectLease: (any ComputerUseTaskExecutionLease)?
    private var pending: ComputerUseTaskJournal?

    init(taskID: String, prompt: String, maxSteps: Int = 40, directory: URL) throws {
        guard maxSteps > 0 else { throw Failure.invalidStep }
        self.taskID = taskID; self.maxSteps = maxSteps
        promptDigest = Self.digest(prompt)
        store = try ComputerUseTaskJournalStore(directory: directory)
        let ownerID = taskID + "/agent-owner"
        let previous = try store.load(taskID: ownerID)
        if let previous, previous.promptDigest != promptDigest { throw Failure.mismatch }
        taskLease = try store.acquireExecution(taskID: ownerID, expected: previous)
        if previous == nil {
            try store.save(.init(taskID: ownerID, promptDigest: promptDigest, contractDigest: Self.digest(ownerID),
                                 stepIDs: ["owner"], statuses: [.planned]), replacing: nil)
        }
        try assertMayContinue()
    }

    func begin(step: Int, fingerprint: String) throws {
        try assertMayContinue()
        guard step >= 0, step < maxSteps else { throw Failure.invalidStep }
        let identity = stepID(step)
        let previous = try store.load(taskID: identity)
        if let previous {
            guard previous.promptDigest == promptDigest, previous.contractDigest == fingerprint else { throw Failure.mismatch }
            throw previous.statuses == [.verified] ? Failure.alreadyPerformed : Failure.uncertainEffect
        }
        effectLease = try store.acquireExecution(taskID: identity, expected: nil)
        let journal = ComputerUseTaskJournal(taskID: identity, promptDigest: promptDigest, contractDigest: fingerprint,
                                            stepIDs: [String(step)], statuses: [.attempted])
        // Retain pending before save: even an unconfirmed rename blocks input and Resume.
        pending = journal
        try store.save(journal, replacing: nil)
    }

    func verify(step: Int, fingerprint: String) throws {
        try transition(step: step, fingerprint: fingerprint, status: .verified)
        pending = nil; effectLease?.release(); effectLease = nil
    }

    func markUncertain(step: Int, fingerprint: String) throws {
        try transition(step: step, fingerprint: fingerprint, status: .uncertain)
        // Keep the owner lease until the active runner unwinds.
    }

    func assertMayContinue() throws {
        try taskLease.assertOwnership()
        guard pending == nil else { throw Failure.uncertainEffect }
        for step in 0..<maxSteps {
            if let journal = try store.load(taskID: stepID(step)) {
                guard journal.promptDigest == promptDigest else { throw Failure.mismatch }
                guard journal.statuses == [.verified] else { throw Failure.uncertainEffect }
            }
        }
    }

    private func transition(step: Int, fingerprint: String, status: ComputerUseTaskStepStatus) throws {
        try taskLease.assertOwnership(); try effectLease?.assertOwnership()
        guard let previous = pending, previous.taskID == stepID(step), previous.contractDigest == fingerprint else {
            throw Failure.mismatch
        }
        var next = previous
        next.statuses = [status]
        try store.save(next, replacing: previous)
        pending = next
    }

    private func stepID(_ step: Int) -> String { taskID + "/agent-step-" + String(step) }
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

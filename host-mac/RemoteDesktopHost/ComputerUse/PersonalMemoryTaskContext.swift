import Foundation
import CryptoKit
import MemoryStoreKit
import OSLog

/// Lock-backed authority shared with synchronous writer callbacks. It is
/// populated only for the exact accepted task lease and revoked on teardown.
final class TaskMemoryContextLeaseAuthorizationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lease: LocalMemoryHostLease?

    func bind(_ lease: LocalMemoryHostLease) {
        lock.lock(); self.lease = lease; lock.unlock()
    }

    func clear() {
        lock.lock(); lease = nil; lock.unlock()
    }

    func isCurrent(_ candidate: LocalMemoryHostLease) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return lease == candidate
    }
}

private enum TaskMemoryPromptEvidence {
    private static let logger = Logger(
        subsystem: "com.threadmark.remotedesktop",
        category: "PersonalMemoryPromptEvidence")

    static func recordAppliedContext(_ context: String, taskID: String) {
#if DEBUG
        let digest = SHA256.hash(data: Data(context.utf8))
            .map { String(format: "%02x", $0) }.joined()
        logger.debug("memory_context_applied task_id=\(taskID, privacy: .public) context_sha256=\(digest, privacy: .public)")
#endif
    }
}

enum TaskMemoryContextFailure: LocalizedError {
    case invalidLease, staleBinding, unavailable
    var errorDescription: String? { "Saved memory context is unavailable for this task." }
}

/// Local-only seam for preparing bounded memory context for one accepted owner task.
/// HostSession wires the pinned local runtime only when personal memory is explicitly enabled.
protocol PersonalMemoryTaskContextProviding: Sendable {
    func captureBinding(for lease: LocalMemoryHostLease) async throws -> MemoryStoreBinding?
    func prepare(lease: LocalMemoryHostLease, binding: MemoryStoreBinding,
                 prompt: String) async throws -> String?
}

@MainActor
final class TaskMemoryContextSlot {
    private struct Value {
        let taskID: String
        let lease: LocalMemoryHostLease
        let binding: MemoryStoreBinding
        let text: String
        let isCurrent: @MainActor () -> Bool
    }
    private var value: Value?
    private var revokedTaskID: String?
    private var boundTaskID: String?
    let leaseAuthorizationBox: TaskMemoryContextLeaseAuthorizationBox

    init(leaseAuthorizationBox: TaskMemoryContextLeaseAuthorizationBox = .init()) {
        self.leaseAuthorizationBox = leaseAuthorizationBox
    }

    func bindLease(_ lease: LocalMemoryHostLease) {
        guard let taskID = lease.taskID else { clear(); return }
        boundTaskID = taskID
        revokedTaskID = nil
        leaseAuthorizationBox.bind(lease)
    }

    func stage(_ text: String, taskID: String, lease: LocalMemoryHostLease,
               binding: MemoryStoreBinding, isCurrent: @escaping @MainActor () -> Bool) {
        guard !text.isEmpty, lease.taskID == taskID else {
            revokedTaskID = taskID
            boundTaskID = nil
            leaseAuthorizationBox.clear()
            value = nil
            return
        }
        revokedTaskID = nil
        boundTaskID = taskID
        value = Value(taskID: taskID, lease: lease, binding: binding, text: text, isCurrent: isCurrent)
    }

    func read(taskID: String) -> (lease: LocalMemoryHostLease, binding: MemoryStoreBinding, text: String)? {
        guard let value, value.taskID == taskID, value.isCurrent() else { return nil }
        return (value.lease, value.binding, value.text)
    }

    func contains(taskID: String) -> Bool { value?.taskID == taskID || revokedTaskID == taskID }

    func clear() {
        leaseAuthorizationBox.clear()
        if let value { revokedTaskID = value.taskID }
        else if let boundTaskID { revokedTaskID = boundTaskID }
        value = nil
        boundTaskID = nil
    }

    @discardableResult
    func clearForMemorylessTask(taskID: String) -> Bool {
        guard boundTaskID == taskID else { return false }
        leaseAuthorizationBox.clear()
        value = nil
        boundTaskID = nil
        revokedTaskID = nil
        return true
    }
}

@MainActor
final class TaskMemoryContextPolicy: AgentPolicy {
    private let taskID: String
    private let slot: TaskMemoryContextSlot
    private let base: any AgentPolicy

    private init(taskID: String, slot: TaskMemoryContextSlot, base: any AgentPolicy) {
        self.taskID = taskID; self.slot = slot; self.base = base
    }

    static func applying(taskID: String, slot: TaskMemoryContextSlot?,
                         base: any AgentPolicy) -> any AgentPolicy {
        guard let slot else { return base }
        return TaskMemoryContextPolicy(taskID: taskID, slot: slot, base: base)
    }

    var promptVersion: String { base.promptVersion }

    func propose(_ observation: AgentObservation) async throws -> AgentPolicyOutput {
        let hadContext = slot.contains(taskID: taskID)
        let context = slot.read(taskID: taskID)
        guard !hadContext || context != nil else { throw TaskMemoryContextFailure.invalidLease }
        guard !Task.isCancelled else { throw CancellationError() }
        let modelObservation = observationWithContext(observation, context?.text)
        if let context {
            TaskMemoryPromptEvidence.recordAppliedContext(context.text, taskID: taskID)
        }
        let output = try await base.propose(modelObservation)
        guard !Task.isCancelled else { throw CancellationError() }
        if let context {
            guard slot.read(taskID: taskID)?.lease == context.lease,
                  slot.read(taskID: taskID)?.binding == context.binding else {
                throw TaskMemoryContextFailure.invalidLease
            }
        }
        return output
    }

    func suspend() async { await base.suspend() }
    func resume() async throws { try await base.resume() }
    func stop() async { slot.clear(); await base.stop() }

    private func observationWithContext(_ observation: AgentObservation, _ context: String?) -> AgentObservation {
        guard let context else { return observation }
        let task = observation.task + "\n\n<saved-memory-reference-data>\n" + context
            + "\n</saved-memory-reference-data>"
        return AgentObservation(task: task, surface: observation.surface, screenshot: observation.screenshot,
            elements: observation.elements, focus: observation.focus, history: observation.history,
            budget: observation.budget)
    }
}

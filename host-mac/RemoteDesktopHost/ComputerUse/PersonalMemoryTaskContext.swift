import Foundation
import CryptoKit
import MemoryStoreKit
import OSLog

enum AgentApprovalPurpose: String { case ordinary, memoryDisclosure }

struct AgentMemoryContextSnapshot: Equatable {
    let lease: LocalMemoryHostLease
    let binding: MemoryStoreBinding
    let textDigest: String
    let slotRevision: UUID
}

@MainActor
final class AgentMemoryDisclosureAuthority {
    enum State { case none, current(AgentMemoryContextSnapshot), stale }
    enum ApprovalState { case none, approval(AgentMemoryContextSnapshot, String), rejected(String) }
    private let taskID: String
    private let slot: TaskMemoryContextSlot
    private var pinned: AgentMemoryContextSnapshot?
    private var changed = false

    init(taskID: String, slot: TaskMemoryContextSlot) { self.taskID = taskID; self.slot = slot }

    func pin(lease: LocalMemoryHostLease, binding: MemoryStoreBinding, text: String) {
        guard lease.taskID == taskID, !text.isEmpty else { changed = true; return }
        guard let current = slot.read(taskID: taskID), current.lease == lease,
              current.binding == binding, current.text == text else { changed = true; return }
        if Self.isEmptyJSONArray(text) {
            if pinned != nil { changed = true }
            return
        }
        let snapshot = AgentMemoryContextSnapshot(lease: lease, binding: binding,
            textDigest: Self.digest(text), slotRevision: current.revision)
        if let pinned, pinned != snapshot { changed = true } else { pinned = snapshot }
    }

    func state(for candidateTaskID: String) -> State {
        guard candidateTaskID == taskID else { return .stale }
        guard !changed else { return .stale }
        guard let pinned else { return .none }
        guard let current = slot.read(taskID: taskID) else { changed = true; return .stale }
        let live = AgentMemoryContextSnapshot(lease: current.lease, binding: current.binding,
            textDigest: Self.digest(current.text), slotRevision: current.revision)
        guard live == pinned else { changed = true; return .stale }
        return .current(pinned)
    }

    func requiresDisclosureApproval(for action: AgentAction) -> Bool {
        switch action {
        case .type, .select, .openURL, .setFiles: return true
        case .key(let chord):
            guard let key = try? AgentKeyStroke.parse(chord) else { return true }
            return ![0x29, 0x2b, 0x4a, 0x4b, 0x4d, 0x4e, 0x4f, 0x50, 0x51, 0x52].contains(key.usage)
        default: return false
        }
    }

    func isOpaquePaste(_ action: AgentAction) -> Bool {
        guard case .key(let chord) = action, let key = try? AgentKeyStroke.parse(chord), key.usage == 0x19 else { return false }
        return key.modifiers & (2 | 8) != 0
    }

    func approvalReason(_ existing: String?, risk: AgentRiskTier) -> String {
        let disclosure = "This action may use saved memory in this app. Review and approve this exact action."
        let riskWarning = "This action may commit, delete, share, or change permissions."
        var reasons = existing.map { [$0] } ?? []
        if risk == .high, !reasons.contains(riskWarning) { reasons.append(riskWarning) }
        return ([disclosure] + reasons).joined(separator: " ")
    }

    func approvalState(taskID: String, action: AgentAction, risk: AgentRiskTier,
                       existingReason: String?) -> ApprovalState {
        switch state(for: taskID) {
        case .none: return .none
        case .stale: return .rejected("Saved memory authorization changed; this task must stop before acting.")
        case .current(let snapshot):
            guard requiresDisclosureApproval(for: action) else { return .none }
            guard !isOpaquePaste(action) else {
                return .rejected("Paste is blocked while saved memory is active because its contents cannot be reviewed.")
            }
            return .approval(snapshot, approvalReason(existingReason, risk: risk))
        }
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isEmptyJSONArray(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let array = value as? [Any] else { return false }
        return array.isEmpty
    }
}

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
    private var authorizationRevokedTaskID: String?
    private var revision = UUID()
    let leaseAuthorizationBox: TaskMemoryContextLeaseAuthorizationBox

    init(leaseAuthorizationBox: TaskMemoryContextLeaseAuthorizationBox = .init()) {
        self.leaseAuthorizationBox = leaseAuthorizationBox
    }

    func bindLease(_ lease: LocalMemoryHostLease) {
        revision = UUID()
        guard let taskID = lease.taskID else { clear(); return }
        boundTaskID = taskID
        revokedTaskID = nil
        authorizationRevokedTaskID = nil
        leaseAuthorizationBox.bind(lease)
    }

    func stage(_ text: String, taskID: String, lease: LocalMemoryHostLease,
               binding: MemoryStoreBinding, isCurrent: @escaping @MainActor () -> Bool) {
        revision = UUID()
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

    func read(taskID: String) -> (lease: LocalMemoryHostLease, binding: MemoryStoreBinding,
                                  text: String, revision: UUID)? {
        guard let value, value.taskID == taskID, value.isCurrent() else { return nil }
        return (value.lease, value.binding, value.text, revision)
    }

    func contains(taskID: String) -> Bool { value?.taskID == taskID || revokedTaskID == taskID }

    func hasLease(taskID: String) -> Bool { boundTaskID == taskID || value?.taskID == taskID }

    func authorizationWasRevoked(taskID: String) -> Bool {
        authorizationRevokedTaskID == taskID
    }

    func revokeAuthorization() {
        if let boundTaskID { authorizationRevokedTaskID = boundTaskID }
        else if let value { authorizationRevokedTaskID = value.taskID }
        clear()
    }

    func clear(taskID: String) {
        guard boundTaskID == taskID || value?.taskID == taskID || revokedTaskID == taskID else { return }
        clear()
    }

    func clear() {
        revision = UUID()
        leaseAuthorizationBox.clear()
        if let value { revokedTaskID = value.taskID }
        else if let boundTaskID { revokedTaskID = boundTaskID }
        value = nil
        boundTaskID = nil
    }

    @discardableResult
    func clearForMemorylessTask(taskID: String) -> Bool {
        guard boundTaskID == taskID else { return false }
        revision = UUID()
        leaseAuthorizationBox.clear()
        value = nil
        boundTaskID = nil
        revokedTaskID = nil
        authorizationRevokedTaskID = nil
        return true
    }
}

@MainActor
final class TaskMemoryContextPolicy: AgentPolicy {
    private let taskID: String
    private let slot: TaskMemoryContextSlot
    private let memoryDisclosureAuthority: AgentMemoryDisclosureAuthority?
    private let base: any AgentPolicy

    private init(taskID: String, slot: TaskMemoryContextSlot, base: any AgentPolicy,
                 memoryDisclosureAuthority: AgentMemoryDisclosureAuthority?) {
        self.taskID = taskID; self.slot = slot; self.base = base
        self.memoryDisclosureAuthority = memoryDisclosureAuthority
    }

    static func applying(taskID: String, slot: TaskMemoryContextSlot?,
                         base: any AgentPolicy,
                         memoryDisclosureAuthority: AgentMemoryDisclosureAuthority? = nil) -> any AgentPolicy {
        guard let slot else { return base }
        return TaskMemoryContextPolicy(taskID: taskID, slot: slot, base: base,
            memoryDisclosureAuthority: memoryDisclosureAuthority)
    }

    var promptVersion: String { base.promptVersion }

    func propose(_ observation: AgentObservation) async throws -> AgentPolicyOutput {
        let hadContext = slot.contains(taskID: taskID)
        let context = slot.read(taskID: taskID)
        guard !hadContext || context != nil else { throw invalidatedContextError() }
        guard !Task.isCancelled else { throw CancellationError() }
        if let context { memoryDisclosureAuthority?.pin(lease: context.lease, binding: context.binding, text: context.text) }
        let modelObservation = observationWithContext(observation, context?.text)
        if let context {
            TaskMemoryPromptEvidence.recordAppliedContext(context.text, taskID: taskID)
        }
        let output: AgentPolicyOutput
        do { output = try await base.propose(modelObservation) }
        catch {
            if slot.authorizationWasRevoked(taskID: taskID) {
                throw AgentPolicyTermination.authorizationRevoked
            }
            throw error
        }
        if slot.authorizationWasRevoked(taskID: taskID) {
            throw AgentPolicyTermination.authorizationRevoked
        }
        guard !Task.isCancelled else { throw CancellationError() }
        if let context {
            guard slot.read(taskID: taskID)?.lease == context.lease,
                  slot.read(taskID: taskID)?.binding == context.binding else {
                throw invalidatedContextError()
            }
        }
        return output
    }

    func suspend() async { await base.suspend() }
    func resume() async throws { try await base.resume() }
    func stop() async { slot.clear(taskID: taskID); await base.stop() }

    private func invalidatedContextError() -> Error {
        slot.authorizationWasRevoked(taskID: taskID)
            ? AgentPolicyTermination.authorizationRevoked
            : CancellationError()
    }

    private func observationWithContext(_ observation: AgentObservation, _ context: String?) -> AgentObservation {
        guard let context else { return observation }
        let task = observation.task + "\n\n<saved-memory-reference-data>\n" + context
            + "\n</saved-memory-reference-data>"
        return AgentObservation(task: task, surface: observation.surface, screenshot: observation.screenshot,
            elements: observation.elements, focus: observation.focus, history: observation.history,
            budget: observation.budget)
    }
}

import Foundation
import MemoryStoreKit

struct LocalMemoryRPCContext: Equatable, Sendable {
    let peerID: String
    let sessionID: String
}

struct LocalMemoryHostLease: Equatable, Sendable {
    enum TaskAuthority: Equatable, Sendable {
        case none
        case active
        case completed
    }
    let peerID: String
    let sessionID: String
    let taskID: String?
    let authorizationGeneration: UInt64
    let taskAuthority: TaskAuthority
    let memoryPolicy: ComputerUseTaskMemoryPolicy

    init(peerID: String, sessionID: String, taskID: String?, authorizationGeneration: UInt64,
         taskAuthority: TaskAuthority, memoryPolicy: ComputerUseTaskMemoryPolicy = .init()) {
        self.peerID = peerID
        self.sessionID = sessionID
        self.taskID = taskID
        self.authorizationGeneration = authorizationGeneration
        self.taskAuthority = taskAuthority
        self.memoryPolicy = memoryPolicy
    }
}

final class MemoryLeaseBox: @unchecked Sendable {
    private struct Value {
        let ownerID: String
        let lease: LocalMemoryHostLease
    }

    private let lock = NSLock()
    private var value: Value?

    func set(ownerID: String, lease: LocalMemoryHostLease) {
        lock.lock(); value = Value(ownerID: ownerID, lease: lease); lock.unlock()
    }
    func clear() { lock.lock(); value = nil; lock.unlock() }
    func authorizes(_ context: OwnerMemoryContext) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let value, value.ownerID == context.ownerID,
              value.lease.sessionID == context.sessionID else { return false }
        return context.taskID == value.lease.taskID
    }
    func authorizesTask(ownerID: String, taskID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let value, value.ownerID == ownerID,
              value.lease.taskID == taskID else { return false }
        return value.lease.taskAuthority == .active || value.lease.taskAuthority == .completed
    }

    func ownerMemoryPolicy(ownerID: String, featureEnabled: Bool) -> OwnerMemoryPolicy {
        lock.lock(); defer { lock.unlock() }
        guard let value, value.ownerID == ownerID else {
            return OwnerMemoryPolicy(featureEnabled: false, incognito: true, noMemory: true,
                                     pauseLearning: true)
        }
        let policy = value.lease.memoryPolicy
        return OwnerMemoryPolicy(featureEnabled: featureEnabled, incognito: policy.incognito,
                                 noMemory: policy.noMemory, pauseLearning: policy.pauseLearning)
    }
}

enum PersonalMemoryTaskPolicyGate {
    static func denial(for operation: LocalMemoryRPCCommand.Operation,
                       policy: ComputerUseTaskMemoryPolicy) -> LocalMemoryRPCReply.Status? {
        if policy.incognito { return .incognito }
        if policy.noMemory && [.listMetadata, .listRecords, .searchRecords,
                               .captureMemoryGeneration].contains(operation) {
            return .noMemory
        }
        return nil
    }
}

/// The exact completed owner Forget that permits one explicit fresh-store request.
/// This value is host state, not authority by itself; every request also needs a
/// current authenticated lease for the same peer, session, and generation.
struct CompletedMemoryForgetAuthority: Equatable, Sendable {
    let peerID: String
    let sessionID: String
    let authorizationGeneration: UInt64
    let commandID: String
    let binding: MemoryStoreBinding
}

@MainActor
final class PersonalMemoryInitializationCoordinator {
    typealias LeaseProvider = PersonalMemoryCoordinator.LeaseProvider
    typealias BeginErasure = PersonalMemoryCoordinator.BeginErasure
    typealias IsErasureQuiescent = PersonalMemoryCoordinator.IsErasureQuiescent
    typealias EndErasure = PersonalMemoryCoordinator.EndErasure
    typealias InitializeGeneration = @Sendable (MemoryStoreBinding, UUID) throws -> MemoryStoreBinding?

    private let enabled: Bool
    private let leaseProvider: LeaseProvider
    private let beginErasure: BeginErasure
    private let isErasureQuiescent: IsErasureQuiescent
    private let endErasure: EndErasure
    private let initializeGeneration: InitializeGeneration?
    private struct RequestKey: Equatable {
        let peerID: String
        let sessionID: String
        let authorizationGeneration: UInt64
        let oldBinding: MemoryStoreBinding
        let forgetCommandID: String
        let commandID: String
    }
    private struct Result {
        let key: RequestKey
        let replacement: MemoryStoreBinding
    }
    private var activeKey: RequestKey?
    private var activeWork: Task<Result?, Never>?
    private var completedResult: Result?

    init(enabled: Bool = false,
         hasCustomStorageAdapters: Bool = true,
         leaseProvider: @escaping LeaseProvider,
         beginErasure: @escaping BeginErasure,
         isErasureQuiescent: @escaping IsErasureQuiescent,
         endErasure: @escaping EndErasure,
         initializeGeneration: InitializeGeneration? = nil) {
        self.enabled = enabled
        self.leaseProvider = leaseProvider
        self.beginErasure = beginErasure
        self.isErasureQuiescent = isErasureQuiescent
        self.endErasure = endErasure
        if let initializeGeneration {
            self.initializeGeneration = initializeGeneration
        } else if enabled && !hasCustomStorageAdapters {
            self.initializeGeneration = { binding, commandID in
                try MemoryStoreFactory.initializeAfterForgetProduction(
                    enabled: true, expectedBinding: binding, commandID: commandID)
            }
        } else {
            self.initializeGeneration = nil
        }
    }

    func handle(_ command: LocalMemoryRPCCommand,
                context: LocalMemoryRPCContext,
                hostLease: LocalMemoryHostLease,
                completedForget: CompletedMemoryForgetAuthority?,
                isClosed: @escaping @MainActor () -> Bool) async -> LocalMemoryRPCReply {
        let id = command.commandID ?? ""
        let oldReference = command.generationReference
        guard enabled else { return response(command, status: .disabled) }
        guard command.operation == .initializeMemoryGeneration,
              (try? command.validate()) != nil,
              let forget = completedForget, let oldReference,
              oldReference == forget.binding.reference,
              let forgetID = UUID(uuidString: forget.commandID),
              forgetID.uuidString.lowercased() == forget.commandID,
              let commandUUID = UUID(uuidString: id),
              commandUUID.uuidString.lowercased() == id,
              commandUUID != forgetID,
              !isClosed(), !Task.isCancelled,
              isCurrent(hostLease, context: context),
              hostLease.peerID == forget.peerID,
              hostLease.sessionID == forget.sessionID,
              hostLease.authorizationGeneration == forget.authorizationGeneration else {
            return response(command, status: .unavailable)
        }

        let key = RequestKey(peerID: forget.peerID, sessionID: forget.sessionID,
            authorizationGeneration: forget.authorizationGeneration,
            oldBinding: forget.binding, forgetCommandID: forget.commandID, commandID: id)
        if let activeWork {
            guard activeKey == key else { return response(command, status: .unavailable) }
            let result = await activeWork.value
            if result == nil, completedResult?.key == key { completedResult = nil }
            guard !Task.isCancelled, !isClosed(), isCurrent(hostLease, context: context) else {
                return response(command, status: .unauthorized)
            }
            if let result { completedResult = result }
            return result.map { response(command, status: .completed, replacement: $0.replacement) }
                ?? response(command, status: .unavailable)
        }
        if let completedResult, completedResult.key != key {
            return response(command, status: .unavailable)
        }
        guard let initializeGeneration else { return response(command, status: .unavailable) }
        guard !Task.isCancelled, !isClosed(), isCurrent(hostLease, context: context),
              let token = beginErasure(hostLease) else {
            return response(command, status: .unavailable)
        }
        guard !Task.isCancelled, !isClosed(), isCurrent(hostLease, context: context) else {
            if !isClosed(), isCurrent(hostLease, context: context) { endErasure(token) }
            return response(command, status: .unavailable)
        }
        activeKey = key
        let work = Task { @MainActor [self] in
            await perform(key, token: token, lease: hostLease, context: context,
                initialize: initializeGeneration, isClosed: isClosed)
        }
        activeWork = work
        let result = await work.value
        if activeKey == key {
            activeKey = nil
            activeWork = nil
        }
        if result == nil, completedResult?.key == key { completedResult = nil }
        guard !Task.isCancelled, !isClosed(), isCurrent(hostLease, context: context) else {
            return response(command, status: .unauthorized)
        }
        if let result { completedResult = result }
        return result.map { response(command, status: .completed, replacement: $0.replacement) }
            ?? response(command, status: .unavailable)
    }

    func canRenewReaderScope(old: CompletedMemoryForgetAuthority?, newLease: LocalMemoryHostLease,
                             currentBinding: MemoryStoreBinding, hasPendingWork: Bool) -> Bool {
        guard !hasPendingWork, activeWork == nil, let old, let completedResult,
              completedResult.key.peerID == old.peerID,
              completedResult.key.sessionID == old.sessionID,
              completedResult.key.authorizationGeneration == old.authorizationGeneration,
              completedResult.key.oldBinding == old.binding,
              completedResult.replacement == currentBinding,
              newLease.authorizationGeneration != old.authorizationGeneration else { return false }
        let oldContext = LocalMemoryRPCContext(peerID: old.peerID, sessionID: old.sessionID)
        guard let oldCurrent = leaseProvider(oldContext, false) else { return true }
        return oldCurrent.authorizationGeneration != old.authorizationGeneration
            || oldCurrent.peerID != old.peerID || oldCurrent.sessionID != old.sessionID
    }

    func retireCompletedScope() {
        guard activeWork == nil else { return }
        completedResult = nil
    }

    private func perform(_ key: RequestKey, token: UUID, lease: LocalMemoryHostLease,
                         context: LocalMemoryRPCContext, initialize: @escaping InitializeGeneration,
                         isClosed: @escaping @MainActor () -> Bool) async -> Result? {
        let deadline = ContinuousClock.now + .seconds(2)
        while !isErasureQuiescent(token) {
            guard ContinuousClock.now < deadline,
                  !Task.isCancelled, !isClosed(), isCurrent(lease, context: context),
                  activeKey == key else {
                finishFence(token, key: key, lease: lease, context: context, isClosed: isClosed)
                return nil
            }
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch {
                finishFence(token, key: key, lease: lease, context: context, isClosed: isClosed)
                return nil
            }
        }
        guard !Task.isCancelled, !isClosed(), isCurrent(lease, context: context),
              activeKey == key else {
            finishFence(token, key: key, lease: lease, context: context, isClosed: isClosed)
            return nil
        }
        guard let commandUUID = UUID(uuidString: key.commandID) else {
            finishFence(token, key: key, lease: lease, context: context, isClosed: isClosed)
            return nil
        }
        let sourceBinding = key.oldBinding
        let result: MemoryStoreBinding?
        do {
            result = try await Task.detached(priority: .utility) {
                try initialize(sourceBinding, commandUUID)
            }.value
        } catch { result = nil }
        guard !Task.isCancelled, !isClosed(), isCurrent(lease, context: context),
              activeKey == key, let result,
              Self.isValidReference(result.reference),
              result.reference != key.oldBinding.reference,
              completedResult.map({ $0.key != key || $0.replacement == result }) ?? true else {
            finishFence(token, key: key, lease: lease, context: context, isClosed: isClosed)
            return nil
        }
        let completed = Result(key: key, replacement: result)
        // Record the durable result while this exact lease is still current. A
        // revoked caller receives no receipt, but a later fresh authorization may
        // renew its reader scope after matching the newly published binding.
        completedResult = completed
        endErasure(token)
        return completed
    }

    private func finishFence(_ token: UUID, key: RequestKey, lease: LocalMemoryHostLease,
                             context: LocalMemoryRPCContext,
                             isClosed: @MainActor () -> Bool) {
        guard activeKey == key, !isClosed(), isCurrent(lease, context: context) else { return }
        endErasure(token)
    }

    private func isCurrent(_ lease: LocalMemoryHostLease,
                           context: LocalMemoryRPCContext) -> Bool {
        guard context.peerID == lease.peerID, context.sessionID == lease.sessionID,
              let current = leaseProvider(context, false) else { return false }
        return current == lease
    }

    private func response(_ command: LocalMemoryRPCCommand,
                          status: LocalMemoryRPCReply.Status,
                          replacement: MemoryStoreBinding? = nil) -> LocalMemoryRPCReply {
        LocalMemoryRPCReply(operation: command.operation, commandID: command.commandID,
            status: status, generationReference: command.generationReference,
            replacementGenerationReference: status == .completed ? replacement?.reference : nil)
    }

    private static func isValidReference(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

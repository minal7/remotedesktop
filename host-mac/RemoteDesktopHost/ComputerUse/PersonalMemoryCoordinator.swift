import Foundation
import MemoryStoreKit

@MainActor
final class PersonalMemoryCoordinator {
    typealias LeaseProvider = @MainActor (LocalMemoryRPCContext, Bool) -> LocalMemoryHostLease?
    typealias ServiceFactory = () throws -> PersonalMemoryService?
    typealias WriterFactory = () throws -> OwnerMemoryWriter?
    typealias BeginErasure = @MainActor (LocalMemoryHostLease) -> UUID?
    typealias IsErasureQuiescent = @MainActor (UUID) -> Bool
    typealias EndErasure = @MainActor (UUID) -> Void
    typealias ForgetRecovery = @Sendable () throws -> Bool
    typealias CaptureBinding = @Sendable () throws -> MemoryStoreBinding?
    typealias BoundServiceFactory = @MainActor (MemoryStoreBinding) throws -> PersonalMemoryService?
    typealias BoundForgetRecovery = @Sendable (MemoryStoreBinding) throws -> Bool
    typealias InitializeGeneration = PersonalMemoryInitializationCoordinator.InitializeGeneration

    private let enabled: Bool
    private let proposalsEnabled: Bool
    private let ownerID: String
    private let leaseProvider: LeaseProvider
    private let serviceFactory: ServiceFactory?
    private let writerFactory: WriterFactory?
    private let beginErasure: BeginErasure
    private let isErasureQuiescent: IsErasureQuiescent
    private let endErasure: EndErasure
    private let forgetRecovery: ForgetRecovery?
    private let captureBinding: CaptureBinding?
    private let boundServiceFactory: BoundServiceFactory?
    private let boundForgetRecovery: BoundForgetRecovery?
    private let initializeGeneration: InitializeGeneration?
    private let initializationCoordinator: PersonalMemoryInitializationCoordinator
    private let leaseBox = MemoryLeaseBox()
    private var service: PersonalMemoryService?
    private var serviceBinding: MemoryStoreBinding?
    private var writer: OwnerMemoryWriter?
    private struct ErasureState {
        let peerID: String
        let sessionID: String
        let authorizationGeneration: UInt64
        let commandID: String
        let binding: MemoryStoreBinding
        let token: UUID
        let verifiedAbsentStartFresh: Bool
        var completed = false
    }
    private var erasureState: ErasureState?
    private var completedForgetAuthority: CompletedMemoryForgetAuthority?
    private struct VerifiedAbsentScope: Equatable {
        let peerID: String
        let sessionID: String
        let authorizationGeneration: UInt64
        let binding: MemoryStoreBinding
    }
    private var verifiedAbsentScope: VerifiedAbsentScope?
    private var erasureWork: Task<Bool, Never>?
    private var erasureWorkID: UUID?
    private var isClosed = false

    private var hasCustomStorageAdapters: Bool {
        serviceFactory != nil || writerFactory != nil || forgetRecovery != nil
            || captureBinding != nil || boundServiceFactory != nil || boundForgetRecovery != nil
            || initializeGeneration != nil
    }

    init(
        enabled: Bool = false,
        proposalsEnabled: Bool = false,
        ownerID: String,
        leaseProvider: @escaping LeaseProvider,
        serviceFactory: ServiceFactory? = nil,
        writerFactory: WriterFactory? = nil,
        beginErasure: @escaping BeginErasure = { _ in nil },
        isErasureQuiescent: @escaping IsErasureQuiescent = { _ in false },
        endErasure: @escaping EndErasure = { _ in },
        forgetRecovery: ForgetRecovery? = nil,
        captureBinding: CaptureBinding? = nil,
        boundServiceFactory: BoundServiceFactory? = nil,
        boundForgetRecovery: BoundForgetRecovery? = nil,
        initializeGeneration: InitializeGeneration? = nil
    ) {
        self.enabled = enabled
        self.proposalsEnabled = proposalsEnabled
        self.ownerID = ownerID
        self.leaseProvider = leaseProvider
        self.serviceFactory = serviceFactory
        self.writerFactory = writerFactory
        self.beginErasure = beginErasure
        self.isErasureQuiescent = isErasureQuiescent
        self.endErasure = endErasure
        self.forgetRecovery = forgetRecovery
        self.captureBinding = captureBinding
        self.boundServiceFactory = boundServiceFactory
        self.boundForgetRecovery = boundForgetRecovery
        self.initializeGeneration = initializeGeneration
        initializationCoordinator = PersonalMemoryInitializationCoordinator(
            enabled: enabled,
            hasCustomStorageAdapters: serviceFactory != nil || writerFactory != nil
                || forgetRecovery != nil || captureBinding != nil
                || boundServiceFactory != nil || boundForgetRecovery != nil
                || initializeGeneration != nil,
            leaseProvider: leaseProvider,
            beginErasure: beginErasure,
            isErasureQuiescent: isErasureQuiescent,
            endErasure: endErasure,
            initializeGeneration: initializeGeneration)
    }

    func handle(
        _ command: LocalMemoryRPCCommand,
        context: LocalMemoryRPCContext
    ) async -> LocalMemoryRPCReply {
        guard enabled else { return reply(command, status: .disabled) }
        guard !isClosed else { return reply(command, status: .unavailable) }
        let requiresTask = command.operation == .confirmProposal
        guard let hostLease = leaseProvider(context, requiresTask) else {
            return reply(command, status: requiresTask ? .inactiveTask : .unauthorized)
        }
        guard hostLease.peerID == context.peerID,
              hostLease.sessionID == context.sessionID,
              Self.isValidOwnerID(ownerID) else {
            return reply(command, status: .unauthorized)
        }
        do {
            try command.validate()
        } catch {
            return reply(command, status: .invalidRequest)
        }
        // Proposal confirmation remains independently off in the Memory v1
        // host session, while 0.4 fixtures can opt in explicitly.
        if command.operation == .confirmProposal && !proposalsEnabled {
            return reply(command, status: .disabled)
        }
        if let denial = PersonalMemoryTaskPolicyGate.denial(
            for: command.operation, policy: hostLease.memoryPolicy) {
            return reply(command, status: denial)
        }
        if command.operation == .forgetEverything {
            return await handleForget(command, context: context, hostLease: hostLease)
        }
        if command.operation == .captureMemoryGeneration {
            if erasureState != nil,
               !(await renewReaderScopeIfAllowed(hostLease, context: context,
                    allowVerifiedAbsentRead: true)) {
                return reply(command, status: .unavailable)
            }
            return await captureGeneration(command, context: context, hostLease: hostLease)
        }
        if command.operation == .initializeMemoryGeneration {
            return await initializationCoordinator.handle(command, context: context,
                hostLease: hostLease, completedForget: completedForgetAuthority,
                isClosed: { [weak self] in self?.isClosed ?? true })
        }
        if erasureState != nil {
            let allowsEmptyStoreRead = [.listMetadata, .listRecords, .searchRecords]
                .contains(command.operation)
            guard await renewReaderScopeIfAllowed(hostLease, context: context,
                allowVerifiedAbsentRead: allowsEmptyStoreRead) else {
                return reply(command, status: .unavailable)
            }
        }
        guard !Task.isCancelled, !isClosed, erasureState == nil,
              isCurrentPolicyLease(hostLease, context: context) else {
            return reply(command, status: .unauthorized)
        }

        let contextForWriter = OwnerMemoryContext(
            ownerID: ownerID,
            sessionID: hostLease.sessionID,
            taskID: hostLease.taskID)
        leaseBox.set(ownerID: ownerID, lease: hostLease)
        defer { leaseBox.clear() }

        do {
            guard let writer = try resolveWriter() else {
                return reply(command, status: .disabled)
            }
            guard !Task.isCancelled, !isClosed, erasureState == nil,
                  isCurrentPolicyLease(hostLease, context: context) else {
                return reply(command, status: .unauthorized)
            }
            switch command.operation {
            case .remember:
                guard let kind = command.rememberKind,
                      let text = command.text,
                      let commandID = command.commandID else {
                    return reply(command, status: .invalidRequest)
                }
                let receipt = try writer.remember(
                    kind: kind == .profile ? .profile : .fact,
                    text: text,
                    commandID: commandID,
                    context: contextForWriter)
                return LocalMemoryRPCReply(
                    operation: command.operation,
                    commandID: commandID,
                    rememberKind: kind,
                    status: .completed,
                    recordID: receipt.recordID,
                    idempotentRetry: receipt.idempotentRetry)

            case .confirmProposal:
                guard let proposalID = command.proposalID,
                      let commandID = command.commandID else {
                    return reply(command, status: .invalidRequest)
                }
                let receipt = try writer.confirmProposal(
                    proposalID: proposalID,
                    commandID: commandID,
                    context: contextForWriter)
                return LocalMemoryRPCReply(
                    operation: command.operation,
                    commandID: commandID,
                    status: .completed,
                    recordID: receipt.recordID,
                    idempotentRetry: receipt.idempotentRetry)

            case .listMetadata:
                let records = try writer.list(context: contextForWriter, limit: command.limit ?? 1)
                let metadata = records.compactMap { record -> LocalMemoryRPCMetadata? in
                    let kind: LocalMemoryRPCCommand.RememberKind
                    switch record.kind {
                    case .profile: kind = .profile
                    case .fact: kind = .fact
                    case .episode: return nil
                    }
                    return LocalMemoryRPCMetadata(
                        recordID: record.id,
                        kind: kind,
                        createdAtMilliseconds: record.observedAt)
                }
                return LocalMemoryRPCReply(
                    operation: command.operation,
                    status: .completed,
                    metadata: metadata)

            case .deleteMetadata:
                guard let recordID = command.recordID else {
                    return reply(command, status: .invalidRequest)
                }
                try writer.delete(recordID: recordID, context: contextForWriter)
                return LocalMemoryRPCReply(
                    operation: command.operation,
                    status: .completed)

            case .listRecords:
                let page = try writer.ownerRecordsPage(afterRecordID: command.afterRecordID,
                    limit: command.limit ?? 1, context: contextForWriter)
                return recordsReply(command, records: page.records,
                    nextRecordID: page.nextRecordID)

            case .searchRecords:
                guard let query = command.query else {
                    return reply(command, status: .invalidRequest)
                }
                let page = try writer.ownerRecordsPage(query: query, afterRecordID: command.afterRecordID,
                    limit: command.limit ?? 1, context: contextForWriter)
                return recordsReply(command, records: page.records,
                    nextRecordID: page.nextRecordID)

            case .editRecord:
                guard let recordID = command.recordID,
                      let revision = command.revision,
                      let text = command.text,
                      let commandID = command.commandID else {
                    return reply(command, status: .invalidRequest)
                }
                let receipt = try writer.edit(
                    recordID: recordID,
                    expectedRevision: revision,
                    text: text,
                    commandID: commandID,
                    context: contextForWriter)
                return LocalMemoryRPCReply(
                    operation: command.operation,
                    commandID: commandID,
                    status: .completed,
                    recordID: receipt.recordID,
                    idempotentRetry: receipt.idempotentRetry)

            case .forgetEverything:
                return reply(command, status: .unavailable)

            case .captureMemoryGeneration:
                return reply(command, status: .unavailable)

            case .initializeMemoryGeneration:
                return reply(command, status: .unavailable)
            }
        } catch let error as OwnerMemoryWriterError {
            return reply(command, status: Self.status(for: error))
        } catch MemoryFactoryError.storageAbsent {
            guard !Task.isCancelled, !isClosed, erasureState == nil,
                  isCurrentPolicyLease(hostLease, context: context) else {
                return reply(command, status: .unauthorized)
            }
            switch command.operation {
            case .listRecords, .searchRecords:
                let binding: MemoryStoreBinding?
                do { binding = try readCurrentBindingSynchronously() }
                catch { binding = nil }
                guard let binding, Self.isValidGenerationReference(binding.reference),
                      verifyBoundStoreIsAbsent(binding: binding),
                      !Task.isCancelled, !isClosed,
                      isCurrentPolicyLease(hostLease, context: context) else {
                    return reply(command, status: .unavailable)
                }
                verifiedAbsentScope = VerifiedAbsentScope(peerID: hostLease.peerID,
                    sessionID: hostLease.sessionID,
                    authorizationGeneration: hostLease.authorizationGeneration,
                    binding: binding)
                return reply(command, status: .initializationRequired)
            default:
                return reply(command, status: .unavailable)
            }
        } catch {
            return reply(command, status: .unavailable)
        }
    }

    private func captureGeneration(_ command: LocalMemoryRPCCommand,
                                   context: LocalMemoryRPCContext,
                                   hostLease: LocalMemoryHostLease) async -> LocalMemoryRPCReply {
        guard erasureState == nil, !Task.isCancelled else {
            return reply(command, status: .unavailable)
        }
        let binding: MemoryStoreBinding?
        do { binding = try await readCurrentBinding() }
        catch { return reply(command, status: .unavailable) }
        guard !Task.isCancelled, !isClosed, erasureState == nil,
              let binding, Self.isValidGenerationReference(binding.reference),
              isCurrentPolicyLease(hostLease, context: context) else {
            return reply(command, status: .unavailable)
        }
        if service != nil, serviceBinding != binding {
            return reply(command, status: .unavailable)
        }
        return LocalMemoryRPCReply(operation: command.operation, status: .completed,
                                   generationReference: binding.reference)
    }

    private func renewReaderScopeIfAllowed(_ lease: LocalMemoryHostLease,
                                           context: LocalMemoryRPCContext,
                                           allowVerifiedAbsentRead: Bool = false) async -> Bool {
        guard let oldState = erasureState, oldState.completed, erasureWork == nil,
              let oldAuthority = completedForgetAuthority,
              oldAuthority.peerID == oldState.peerID,
              oldAuthority.sessionID == oldState.sessionID,
              oldAuthority.authorizationGeneration == oldState.authorizationGeneration,
              oldAuthority.binding == oldState.binding,
              lease.authorizationGeneration != oldState.authorizationGeneration,
              !Task.isCancelled, !isClosed,
              isCurrentLease(lease, context: context) else { return false }
        let currentBinding: MemoryStoreBinding?
        do { currentBinding = try await readCurrentBinding() }
        catch { return false }
        guard !Task.isCancelled, !isClosed,
              erasureWork == nil, ownsErasureState(oldState),
              completedForgetAuthority == oldAuthority,
              isCurrentLease(lease, context: context),
              let currentBinding else {
            return false
        }
        let initializedScope = initializationCoordinator.canRenewReaderScope(old: oldAuthority,
            newLease: lease, currentBinding: currentBinding, hasPendingWork: false)
        let absentStoreScope: Bool
        if initializedScope {
            absentStoreScope = false
        } else if allowVerifiedAbsentRead,
                  initializationCoordinator.canRenewReaderScopeForVerifiedAbsentStore(
                    old: oldAuthority, newLease: lease, currentBinding: currentBinding,
                    hasPendingWork: false) {
            absentStoreScope = verifyBoundStoreIsAbsent(binding: oldAuthority.binding)
        } else {
            absentStoreScope = false
        }
        guard initializedScope || absentStoreScope,
              !Task.isCancelled, !isClosed,
              erasureWork == nil, ownsErasureState(oldState),
              completedForgetAuthority == oldAuthority,
              isCurrentLease(lease, context: context),
              await isCurrentBinding(currentBinding) else {
            return false
        }
        closeStorage()
        erasureState = nil
        completedForgetAuthority = nil
        initializationCoordinator.retireCompletedScope()
        return true
    }

    private func verifyBoundStoreIsAbsent(binding: MemoryStoreBinding) -> Bool {
        // Opening the existing bound generation is read-only when its database is absent:
        // MemoryStoreFactory verifies the completed-Forget marker and exact lock-only root
        // before throwing storageAbsent. Any opened service or other error fails closed.
        closeStorage()
        do {
            guard try resolveErasureService(binding: binding) != nil else {
                closeStorage()
                return false
            }
            closeStorage()
            return false
        } catch MemoryFactoryError.storageAbsent {
            closeStorage()
            return true
        } catch {
            closeStorage()
            return false
        }
    }

    private func readCurrentBinding() async throws -> MemoryStoreBinding? {
        let capture = makeBindingCapture()
        return try await Task.detached(priority: .utility) { try capture() }.value
    }

    private func readCurrentBindingSynchronously() throws -> MemoryStoreBinding? {
        try makeBindingCapture()()
    }

    private func makeBindingCapture() -> CaptureBinding {
        let enabled = self.enabled
        let customFactories = hasCustomStorageAdapters
        return captureBinding ?? {
            guard !customFactories else { return nil }
            return try MemoryStoreFactory.captureProductionBinding(enabled: enabled)
        }
    }

    private func isCurrentLease(_ lease: LocalMemoryHostLease,
                               context: LocalMemoryRPCContext) -> Bool {
        guard let current = leaseProvider(context, false) else { return false }
        return current.peerID == lease.peerID && current.sessionID == lease.sessionID
            && current.authorizationGeneration == lease.authorizationGeneration
            && context.peerID == lease.peerID && context.sessionID == lease.sessionID
    }

    private func isCurrentPolicyLease(_ lease: LocalMemoryHostLease,
                                      context: LocalMemoryRPCContext) -> Bool {
        guard let current = leaseProvider(context, lease.taskAuthority == .completed) else {
            return false
        }
        return current == lease && context.peerID == lease.peerID
            && context.sessionID == lease.sessionID
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        leaseBox.clear()
        if let erasureWork {
            erasureWork.cancel()
            Task { @MainActor [self] in
                _ = await erasureWork.value
                closeStorage()
            }
        } else {
            closeStorage()
        }
    }

    private func handleForget(
        _ command: LocalMemoryRPCCommand,
        context: LocalMemoryRPCContext,
        hostLease: LocalMemoryHostLease
    ) async -> LocalMemoryRPCReply {
        guard let commandID = command.commandID,
              let generationReference = command.generationReference,
              !Task.isCancelled else {
            return reply(command, status: .unavailable)
        }

        let binding: MemoryStoreBinding?
        do { binding = try await readCurrentBinding() }
        catch { return reply(command, status: .unavailable) }
        guard let binding, Self.isValidGenerationReference(binding.reference),
              binding.reference == generationReference,
              !Task.isCancelled, !isClosed,
              isCurrentLease(hostLease, context: context) else {
            return reply(command, status: .unavailable)
        }

        let verifiedAbsentStartFresh: Bool
        if let absentScope = verifiedAbsentScope,
           absentScope.peerID == hostLease.peerID,
           absentScope.sessionID == hostLease.sessionID {
            guard absentScope.authorizationGeneration == hostLease.authorizationGeneration,
                  absentScope.binding == binding,
                  verifyBoundStoreIsAbsent(binding: binding),
                  !Task.isCancelled, !isClosed,
                  isCurrentLease(hostLease, context: context) else {
                return reply(command, status: .unavailable)
            }
            verifiedAbsentStartFresh = true
        } else {
            verifiedAbsentScope = nil
            verifiedAbsentStartFresh = false
        }

        if let state = erasureState {
            let sameAuthority = state.peerID == context.peerID
                && state.sessionID == context.sessionID
                && state.authorizationGeneration == hostLease.authorizationGeneration
            if !sameAuthority {
                // Keep exclusive ownership until old work settles. The already-validated
                // authenticated lease may then retire stale scope state without ending
                // its token; the replacement scope must acquire a fresh fence.
                guard erasureWork == nil,
                      !isCurrentErasureLease(state, context: context) else {
                    return reply(command, status: .unavailable)
                }
                erasureState = nil
            } else {
                guard state.commandID == commandID, state.binding == binding else {
                    return reply(command, status: .unavailable)
                }
                if state.completed {
                    guard await isCurrentBinding(state.binding),
                          isCurrentErasureLease(state, context: context),
                          ownsErasureState(state) else {
                        return reply(command, status: .unauthorized)
                    }
                    return reply(command, status: .completed)
                }
                if let erasureWork {
                    let workID = erasureWorkID
                    let succeeded = await erasureWork.value
                    clearErasureWork(ifMatching: workID)
                    if let status = await erasureDeliveryFailure(state, context: context) {
                        return reply(command, status: status)
                    }
                    return reply(command, status: succeeded ? .completed : .unavailable)
                }
                return await startOrJoinErasure(state, command: command, context: context)
            }
        }

        guard !Task.isCancelled, let token = beginErasure(hostLease) else {
            return reply(command, status: .unavailable)
        }
        let state = ErasureState(peerID: hostLease.peerID, sessionID: hostLease.sessionID,
            authorizationGeneration: hostLease.authorizationGeneration,
            commandID: commandID, binding: binding, token: token,
            verifiedAbsentStartFresh: verifiedAbsentStartFresh)
        verifiedAbsentScope = nil
        erasureState = state
        return await startOrJoinErasure(state, command: command, context: context)
    }

    private func startOrJoinErasure(
        _ state: ErasureState,
        command: LocalMemoryRPCCommand,
        context: LocalMemoryRPCContext
    ) async -> LocalMemoryRPCReply {
        let workID = UUID()
        erasureWorkID = workID
        // This owned task survives cancellation of an RPC waiter: confirmed erasure must
        // either finish under the same lease or remain retryable, never start twice.
        let work = Task { @MainActor [self] in
            await performForget(state, context: context)
        }
        erasureWork = work
        let succeeded = await work.value
        clearErasureWork(ifMatching: workID)
        if let status = await erasureDeliveryFailure(state, context: context) {
            return reply(command, status: status)
        }
        return reply(command, status: succeeded ? .completed : .unavailable)
    }

    private func clearErasureWork(ifMatching workID: UUID?) {
        guard erasureWorkID == workID else { return }
        erasureWork = nil
        erasureWorkID = nil
    }

    private func performForget(_ state: ErasureState,
                               context: LocalMemoryRPCContext) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while true {
            guard !Task.isCancelled, !isClosed,
                  isCurrentErasureLease(state, context: context) else { return false }
            if isErasureQuiescent(state.token) { break }
            guard ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { return false }
        }

        // Stopping a task may change taskID/taskAuthority. The owner, peer, session,
        // and authorization generation must still match before resolving storage.
        guard await isCurrentBinding(state.binding),
              !Task.isCancelled, !isClosed,
              isCurrentErasureLease(state, context: context),
              ownsErasureState(state) else { return false }

        if state.verifiedAbsentStartFresh {
            // This explicit Start Fresh Forget is authorized only while the exact
            // captured generation is still absent. Do not run journal recovery here:
            // it can unlink files if anything appeared after the first check.
            guard verifyBoundStoreIsAbsent(binding: state.binding),
                  await isCurrentBinding(state.binding),
                  !Task.isCancelled, !isClosed,
                  isCurrentErasureLease(state, context: context),
                  ownsErasureState(state) else { return false }
            endErasure(state.token)
            erasureState?.completed = true
            rememberCompletedForget(state)
            return true
        }

        let recovery: BoundForgetRecovery?
        if service != nil {
            guard serviceBinding == state.binding else { return false }
            recovery = nil
        } else if let boundForgetRecovery {
            recovery = boundForgetRecovery
        } else if !hasCustomStorageAdapters {
            let productionEnabled = enabled
            recovery = { binding in
                try MemoryStoreFactory.recoverProductionForget(
                    enabled: productionEnabled, expectedBinding: binding)
            }
        } else {
            recovery = nil
        }

        if let recovery {
            let recovered: Bool
            do {
                recovered = try await Task.detached(priority: .utility) {
                    try recovery(state.binding)
                }.value
            } catch {
                return false
            }
            // Recovery is synchronous storage work and cannot be interrupted once
            // started. Revalidate its owner scope before either receipt or fallback.
            guard await isCurrentBinding(state.binding),
                  !Task.isCancelled, !isClosed,
                  isCurrentErasureLease(state, context: context),
                  ownsErasureState(state) else { return false }
            if recovered {
                endErasure(state.token)
                erasureState?.completed = true
                rememberCompletedForget(state)
                return true
            }
        }

        // A false recovery result means no authenticated pending marker was found.
        // Resolve the normal service only after this second owner-scope check.
        guard await isCurrentBinding(state.binding),
              !Task.isCancelled, !isClosed,
              isCurrentErasureLease(state, context: context),
              ownsErasureState(state) else { return false }
        let target: PersonalMemoryService?
        do { target = try resolveErasureService(binding: state.binding) }
        catch { return false }
        guard let target, await isCurrentBinding(state.binding),
              !Task.isCancelled, !isClosed,
              isCurrentErasureLease(state, context: context),
              ownsErasureState(state) else { return false }

        let erased = await Task.detached(priority: .utility) {
            do { try target.forgetAll(); return true }
            catch { return false }
        }.value
        guard erased, await isCurrentBinding(state.binding),
              !Task.isCancelled, !isClosed,
              isCurrentErasureLease(state, context: context),
              ownsErasureState(state) else { return false }
        endErasure(state.token)
        erasureState?.completed = true
        rememberCompletedForget(state)
        return true
    }

    private func rememberCompletedForget(_ state: ErasureState) {
        completedForgetAuthority = CompletedMemoryForgetAuthority(
            peerID: state.peerID, sessionID: state.sessionID,
            authorizationGeneration: state.authorizationGeneration,
            commandID: state.commandID, binding: state.binding)
    }

    private func isCurrentErasureLease(_ state: ErasureState,
                                       context: LocalMemoryRPCContext) -> Bool {
        guard let current = leaseProvider(context, false) else { return false }
        return current.peerID == state.peerID
            && current.sessionID == state.sessionID
            && current.authorizationGeneration == state.authorizationGeneration
            && context.peerID == state.peerID
            && context.sessionID == state.sessionID
    }

    private func isCurrentBinding(_ binding: MemoryStoreBinding) async -> Bool {
        guard !isClosed else { return false }
        let current: MemoryStoreBinding?
        do {
            current = try await readCurrentBinding()
        } catch {
            return false
        }
        return !Task.isCancelled && !isClosed
            && current == binding
            && current.map { Self.isValidGenerationReference($0.reference) } == true
    }

    private func ownsErasureState(_ state: ErasureState) -> Bool {
        guard let current = erasureState else { return false }
        return current.token == state.token && current.commandID == state.commandID
            && current.binding == state.binding && current.peerID == state.peerID
            && current.sessionID == state.sessionID
            && current.authorizationGeneration == state.authorizationGeneration
    }

    private func erasureDeliveryFailure(_ state: ErasureState,
                                       context: LocalMemoryRPCContext) async -> LocalMemoryRPCReply.Status? {
        if Task.isCancelled || isClosed { return .unavailable }
        guard isCurrentErasureLease(state, context: context) else { return .unauthorized }
        guard await isCurrentBinding(state.binding) else { return .unauthorized }
        return !Task.isCancelled && !isClosed
            && isCurrentErasureLease(state, context: context)
            && ownsErasureState(state) ? nil : .unauthorized
    }

    private func resolveErasureService(binding: MemoryStoreBinding) throws -> PersonalMemoryService? {
        if let service {
            guard serviceBinding == binding else { return nil }
            return service
        }
        if let boundServiceFactory {
            service = try boundServiceFactory(binding)
            serviceBinding = service == nil ? nil : binding
            writer = service?.writer
            return service
        }
        // A writer-only injected fixture cannot authorize whole-product erasure.
        guard serviceFactory == nil, writerFactory == nil else { return nil }
        guard !hasCustomStorageAdapters else { return nil }
        service = try MemoryStoreFactory.openProduction(
            enabled: enabled,
            expectedBinding: binding,
            authorize: { [leaseBox] context in leaseBox.authorizes(context) },
            isTaskActive: { [leaseBox] ownerID, taskID in
                leaseBox.authorizesTask(ownerID: ownerID, taskID: taskID)
            },
            policy: { [enabled, leaseBox, ownerID] in
                leaseBox.ownerMemoryPolicy(ownerID: ownerID, featureEnabled: enabled)
            })
        serviceBinding = service == nil ? nil : binding
        writer = service?.writer
        return service
    }

    private func closeStorage() {
        try? service?.close()
        service = nil
        serviceBinding = nil
        writer = nil
        leaseBox.clear()
    }

    private func resolveWriter() throws -> OwnerMemoryWriter? {
        if let writer {
            if service != nil, serviceFactory == nil, writerFactory == nil {
                guard let serviceBinding,
                      try readCurrentBindingSynchronously() == serviceBinding else { return nil }
            }
            return writer
        }
        if let writerFactory {
            writer = try writerFactory()
            return writer
        }
        if let serviceFactory {
            service = try serviceFactory()
        } else if let boundServiceFactory {
            guard let binding = try readCurrentBindingSynchronously(),
                  Self.isValidGenerationReference(binding.reference) else { return nil }
            service = try boundServiceFactory(binding)
            serviceBinding = service == nil ? nil : binding
        } else if hasCustomStorageAdapters {
            return nil
        } else {
            var binding = try readCurrentBindingSynchronously()
            if binding == nil {
                let initial = try MemoryStoreFactory.openProduction(
                    enabled: enabled,
                    authorize: { [leaseBox] context in leaseBox.authorizes(context) },
                    isTaskActive: { [leaseBox] ownerID, taskID in
                        leaseBox.authorizesTask(ownerID: ownerID, taskID: taskID)
                    },
                    policy: { [enabled, leaseBox, ownerID] in
                        leaseBox.ownerMemoryPolicy(ownerID: ownerID, featureEnabled: enabled)
                    })
                try initial?.close()
                binding = try readCurrentBindingSynchronously()
            }
            guard let binding, Self.isValidGenerationReference(binding.reference) else { return nil }
            service = try MemoryStoreFactory.openProduction(
                enabled: enabled, expectedBinding: binding,
                authorize: { [leaseBox] context in leaseBox.authorizes(context) },
                isTaskActive: { [leaseBox] ownerID, taskID in
                    leaseBox.authorizesTask(ownerID: ownerID, taskID: taskID)
                },
                policy: { [enabled, leaseBox, ownerID] in
                    leaseBox.ownerMemoryPolicy(ownerID: ownerID, featureEnabled: enabled)
                })
            serviceBinding = service == nil ? nil : binding
        }
        writer = service?.writer
        return writer
    }

    private func reply(
        _ command: LocalMemoryRPCCommand,
        status: LocalMemoryRPCReply.Status
    ) -> LocalMemoryRPCReply {
        LocalMemoryRPCReply(
            operation: command.operation,
            commandID: command.commandID,
            rememberKind: command.rememberKind,
            status: status,
            generationReference: command.operation == .forgetEverything
                || command.operation == .initializeMemoryGeneration
                ? command.generationReference : nil)
    }

    private func recordsReply(
        _ command: LocalMemoryRPCCommand,
        records storedRecords: [MemoryRecord],
        nextRecordID: String?
    ) -> LocalMemoryRPCReply {
        let records = storedRecords.compactMap(Self.displayRecord)
        guard records.count <= LocalComputerUseRPCLimits.maximumMemoryRecordsPerReply,
              records.count == storedRecords.count,
              records.count <= (command.limit ?? 0) else {
            return reply(command, status: .unavailable)
        }
        let response = LocalMemoryRPCReply(
            operation: command.operation,
            commandID: command.commandID,
            status: .completed,
            records: records,
            nextRecordID: nextRecordID)
        do {
            try response.validate()
            return response
        } catch {
            // Stored rows are not trusted to fit the owner-display wire contract.
            return reply(command, status: .unavailable)
        }
    }

    private static func displayRecord(_ record: MemoryRecord) -> LocalMemoryRPCRecord? {
        let kind: LocalMemoryRPCCommand.RememberKind
        switch record.kind {
        case .profile: kind = .profile
        case .fact: kind = .fact
        case .episode: return nil
        }
        let source: LocalMemoryRPCRecord.Source
        switch record.source {
        case .ownerMessage: source = .ownerMessage
        case .ownerConfirmed: source = .ownerConfirmed
        }
        return LocalMemoryRPCRecord(
            recordID: record.id,
            kind: kind,
            text: record.body,
            observedAtMilliseconds: record.observedAt,
            active: record.active,
            revision: OwnerMemoryWriter.revision(for: record),
            source: source)
    }

    private static func status(for error: OwnerMemoryWriterError) -> LocalMemoryRPCReply.Status {
        switch error {
        case .unauthorized, .proposalBindingMismatch:
            return .unauthorized
        case .inactiveTask:
            return .inactiveTask
        case .disabled:
            return .disabled
        case .incognito:
            return .incognito
        case .noMemory:
            return .noMemory
        case .learningPaused:
            return .learningPaused
        case .proposalNotFound, .proposalExpired:
            return .notFound
        case .recordNotFound:
            return .notFound
        case .commandConflict:
            return .conflict
        case .invalidInput, .proposalLimit:
            return .invalidRequest
        case .storageFailure, .forgotten, .forgetReentrant:
            return .unavailable
        }
    }

    private static func isValidOwnerID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func isValidGenerationReference(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

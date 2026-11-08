import Foundation
import MemoryStoreKit

/// The task provider receives only the exact accepted task prompt and a bound store generation.
/// It has no screen, vault, or owner-memory UI dependency.
struct PersonalMemoryTaskContextProvider: PersonalMemoryTaskContextProviding, Sendable {
    typealias LeaseCheck = @MainActor @Sendable (LocalMemoryHostLease) -> Bool
    typealias SynchronousLeaseCheck = @Sendable (LocalMemoryHostLease) -> Bool
    typealias BindingCapture = @Sendable () throws -> MemoryStoreBinding?
    typealias ServiceOpener = @Sendable (
        OwnerMemoryContext, MemoryStoreBinding, @escaping @Sendable () -> Bool
    ) throws -> PersonalMemoryService?
    typealias EmbeddingInputResolver = @MainActor @Sendable () throws -> PersonalMemoryRuntimeInputs
    typealias VisionInputResolver = @Sendable () async throws -> AgentVisionRuntimeInputs?

    let enabled: Bool
    private let ownerID: @Sendable () -> String?
    private let isLeaseCurrent: LeaseCheck
    private let isLeaseCurrentSynchronously: SynchronousLeaseCheck
    private let captureBindingBody: BindingCapture?
    private let openServiceBody: ServiceOpener?
    private let runtime: PersonalMemoryTaskRuntimeOperations
    private let embeddingInputs: EmbeddingInputResolver
    private let faraRuntimeInputs: VisionInputResolver

    init(
        enabled: Bool = false,
        ownerID: @escaping @Sendable () -> String?,
        isLeaseCurrent: @escaping LeaseCheck,
        isLeaseCurrentSynchronously: @escaping SynchronousLeaseCheck,
        faraRuntimeInputs: @escaping VisionInputResolver,
        captureBinding: BindingCapture? = nil,
        openService: ServiceOpener? = nil,
        runtime: PersonalMemoryTaskRuntimeOperations? = nil,
        embeddingInputs: EmbeddingInputResolver? = nil
    ) {
        self.enabled = enabled
        self.ownerID = ownerID
        self.isLeaseCurrent = isLeaseCurrent
        self.isLeaseCurrentSynchronously = isLeaseCurrentSynchronously
        captureBindingBody = captureBinding
        openServiceBody = openService
        self.runtime = runtime ?? .production
        self.embeddingInputs = embeddingInputs ?? { try PersonalMemoryRuntimeResolver.resolve() }
        self.faraRuntimeInputs = faraRuntimeInputs
    }

    func captureBinding(for lease: LocalMemoryHostLease) async throws -> MemoryStoreBinding? {
        guard enabled, !lease.memoryPolicy.incognito, !lease.memoryPolicy.noMemory else { return nil }
        guard let owner = ownerID(), validOwnerID(owner) else {
            throw TaskMemoryContextFailure.invalidLease
        }
        try await requireCurrent(lease, owner: owner)
        let binding: MemoryStoreBinding?
        do {
            if let captureBindingBody { binding = try captureBindingBody() }
            else { binding = try MemoryStoreFactory.captureProductionBinding(enabled: true) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TaskMemoryContextFailure.unavailable
        }
        try await requireCurrent(lease, owner: owner)
        return binding
    }

    func prepare(lease: LocalMemoryHostLease, binding: MemoryStoreBinding,
                 prompt: String) async throws -> String? {
        guard enabled, !lease.memoryPolicy.incognito, !lease.memoryPolicy.noMemory else { return nil }
        guard let owner = ownerID(), validOwnerID(owner) else { throw TaskMemoryContextFailure.invalidLease }
        try await requireCurrent(lease, owner: owner)
        guard let taskID = lease.taskID,
              validPrompt(prompt), validBindingReference(binding.reference) else {
            throw TaskMemoryContextFailure.invalidLease
        }
        let context = OwnerMemoryContext(ownerID: owner, sessionID: lease.sessionID, taskID: taskID)
        let currentSynchronously: @Sendable () -> Bool = { [isLeaseCurrentSynchronously, ownerID] in
            isLeaseCurrentSynchronously(lease) && ownerID() == owner
        }
        let service: PersonalMemoryService?
        do {
            if let openServiceBody {
                service = try openServiceBody(context, binding, currentSynchronously)
            } else {
                service = try openProductionService(context: context, lease: lease,
                    binding: binding, isCurrent: currentSynchronously)
            }
        } catch MemoryFactoryError.storageAbsent {
            try await requireCurrent(lease, owner: owner)
            return "[]"
        } catch {
            throw TaskMemoryContextFailure.unavailable
        }
        guard let service else { throw TaskMemoryContextFailure.unavailable }

        let scopedRuntime = ScopedTaskMemoryRuntime(lease: lease,
            owner: owner, ownerID: ownerID,
            isCurrent: isLeaseCurrent, isCurrentSynchronously: isLeaseCurrentSynchronously,
            embeddingInputs: embeddingInputs, faraRuntimeInputs: faraRuntimeInputs,
            runtime: runtime)
        var serviceClosed = false
        do {
            try await requireCurrent(lease, owner: owner)
            try await scopedRuntime.activateEmbeddingRuntime()
            try await requireCurrent(lease, owner: owner)
            let builder = MemoryContextBuilder(writer: service.writer,
                embedding: scopedRuntime, tokenCounter: scopedRuntime)
            let result = try await builder.build(MemoryContextRequest(context: context,
                query: prompt, tokenBudget: 512, candidateLimit: 100,
                topK: 10, profileTokenBudget: 256))
            try await requireCurrent(lease, owner: owner)
            try service.close()
            serviceClosed = true
            return result.serializedContext
        } catch is CancellationError {
            await scopedRuntime.cancelOwnedEndpoints()
            if !serviceClosed { try? service.close() }
            throw CancellationError()
        } catch is TaskMemoryContextFailure {
            await scopedRuntime.cancelOwnedEndpoints()
            if !serviceClosed { try? service.close() }
            throw TaskMemoryContextFailure.unavailable
        } catch {
            await scopedRuntime.cancelOwnedEndpoints()
            if !serviceClosed { try? service.close() }
            throw TaskMemoryContextFailure.unavailable
        }
    }

    private func requireCurrent(_ lease: LocalMemoryHostLease, owner: String) async throws {
        try Task.checkCancellation()
        guard lease.taskAuthority == .active, lease.taskID != nil,
              !lease.memoryPolicy.incognito, !lease.memoryPolicy.noMemory,
              ownerID() == owner, isLeaseCurrentSynchronously(lease),
              await isLeaseCurrent(lease), isLeaseCurrentSynchronously(lease), ownerID() == owner else {
            throw TaskMemoryContextFailure.invalidLease
        }
        try Task.checkCancellation()
    }

    private func openProductionService(context: OwnerMemoryContext, lease: LocalMemoryHostLease,
                                       binding: MemoryStoreBinding,
                                       isCurrent: @escaping @Sendable () -> Bool) throws -> PersonalMemoryService? {
        guard isCurrent() else { throw TaskMemoryContextFailure.invalidLease }
        return try MemoryStoreFactory.openProduction(enabled: enabled, expectedBinding: binding,
            authorize: { candidate in candidate == context && isCurrent() },
            isTaskActive: { candidateOwner, candidateTask in
                candidateOwner == context.ownerID && candidateTask == context.taskID && isCurrent()
            },
            policy: {
                guard isCurrent() else {
                    return OwnerMemoryPolicy(featureEnabled: false, incognito: true,
                        noMemory: true, pauseLearning: true)
                }
                return OwnerMemoryPolicy(featureEnabled: true,
                    incognito: lease.memoryPolicy.incognito,
                    noMemory: lease.memoryPolicy.noMemory,
                    pauseLearning: lease.memoryPolicy.pauseLearning)
            })
    }

    private func validOwnerID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.utf8.contains(0)
    }

    private func validPrompt(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 2_048 && !value.utf8.contains(0)
    }

    private func validBindingReference(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

/// Narrow runtime surface for this provider; tests inject callbacks and never start a worker.
struct PersonalMemoryTaskRuntimeOperations: Sendable {
    let activateEmbedding: @Sendable (PersonalMemoryRuntimeInputs) async throws -> OSAtlasLlamaEndpoint
    let embed: @Sendable (OSAtlasLlamaEndpoint, String, MemoryEmbeddingPurpose) async throws -> [Float]
    let activateAgentVision: @Sendable (AgentVisionRuntimeInputs) async throws -> OSAtlasLlamaEndpoint
    let countMemoryTokens: @Sendable (OSAtlasLlamaEndpoint, String) async throws -> Int
    let cancel: @Sendable (OSAtlasLlamaEndpoint) async -> Void

    static var production: Self {
        backed(by: .shared)
    }

    static func backed(by runtime: OSAtlasLlamaRuntime) -> Self {
        return Self(
            activateEmbedding: { try await runtime.activateMemoryEmbedding($0) },
            embed: { try await runtime.embed(endpoint: $0, text: $1, purpose: $2) },
            activateAgentVision: { try await runtime.activateAgentVision($0) },
            countMemoryTokens: { try await runtime.countMemoryTokens(endpoint: $0, context: $1) },
            cancel: { await runtime.cancel(endpoint: $0) })
    }
}

private actor ScopedTaskMemoryRuntime: LocalMemoryEmbeddingProvider, MemoryExactTokenCounter {
    let identity = PersonalMemoryRuntimeResolver.modelIdentity
    let dimensions = PersonalMemoryRuntimeResolver.embeddingDimensions

    private let lease: LocalMemoryHostLease
    private let owner: String
    private let ownerID: @Sendable () -> String?
    private let isCurrent: PersonalMemoryTaskContextProvider.LeaseCheck
    private let isCurrentSynchronously: PersonalMemoryTaskContextProvider.SynchronousLeaseCheck
    private let embeddingInputs: PersonalMemoryTaskContextProvider.EmbeddingInputResolver
    private let faraRuntimeInputs: PersonalMemoryTaskContextProvider.VisionInputResolver
    private let runtime: PersonalMemoryTaskRuntimeOperations
    private var embeddingEndpoint: OSAtlasLlamaEndpoint?
    private var visionEndpoint: OSAtlasLlamaEndpoint?

    init(lease: LocalMemoryHostLease, owner: String,
         ownerID: @escaping @Sendable () -> String?,
         isCurrent: @escaping PersonalMemoryTaskContextProvider.LeaseCheck,
         isCurrentSynchronously: @escaping PersonalMemoryTaskContextProvider.SynchronousLeaseCheck,
         embeddingInputs: @escaping PersonalMemoryTaskContextProvider.EmbeddingInputResolver,
         faraRuntimeInputs: @escaping PersonalMemoryTaskContextProvider.VisionInputResolver,
         runtime: PersonalMemoryTaskRuntimeOperations) {
        self.lease = lease
        self.owner = owner
        self.ownerID = ownerID
        self.isCurrent = isCurrent
        self.isCurrentSynchronously = isCurrentSynchronously
        self.embeddingInputs = embeddingInputs
        self.faraRuntimeInputs = faraRuntimeInputs
        self.runtime = runtime
    }

    func activateEmbeddingRuntime() async throws {
        try await requireCurrent()
        let inputs = try await embeddingInputs()
        try await requireCurrent()
        embeddingEndpoint = try await runtime.activateEmbedding(inputs)
        try await requireCurrent()
    }

    func embed(_ text: String, purpose: MemoryEmbeddingPurpose) async throws -> [Float] {
        try await requireCurrent()
        guard let endpoint = embeddingEndpoint else { throw TaskMemoryContextFailure.unavailable }
        let vector = try await runtime.embed(endpoint, text, purpose)
        try await requireCurrent()
        return vector
    }

    func countTokens(in completeContext: String) async throws -> Int {
        try await requireCurrent()
        if visionEndpoint == nil {
            guard let inputs = try await faraRuntimeInputs() else {
                throw TaskMemoryContextFailure.unavailable
            }
            try await requireCurrent()
            visionEndpoint = try await runtime.activateAgentVision(inputs)
            try await requireCurrent()
        }
        guard let endpoint = visionEndpoint else { throw TaskMemoryContextFailure.unavailable }
        let count = try await runtime.countMemoryTokens(endpoint, completeContext)
        try await requireCurrent()
        return count
    }

    func cancelOwnedEndpoints() async {
        // Both endpoints are task-owned until the prepared context is handed off. Exact
        // endpoint cancellation cannot stop a newer task's runtime generation.
        if let endpoint = visionEndpoint { await runtime.cancel(endpoint) }
        if let endpoint = embeddingEndpoint { await runtime.cancel(endpoint) }
        visionEndpoint = nil
        embeddingEndpoint = nil
    }

    private func requireCurrent() async throws {
        try Task.checkCancellation()
        guard ownerID() == owner, isCurrentSynchronously(lease), await isCurrent(lease),
              isCurrentSynchronously(lease), ownerID() == owner, lease.taskAuthority == .active,
              !lease.memoryPolicy.incognito, !lease.memoryPolicy.noMemory else {
            throw TaskMemoryContextFailure.invalidLease
        }
        try Task.checkCancellation()
    }
}

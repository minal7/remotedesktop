#if DEBUG
import Foundation
import XCTest
@testable import RemoteDesktopHost
@testable import MemoryStoreKit

private final class ForgetProviderTestKeys: KeychainClient, MemoryKeyRandomSource, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ExactKeychainItem: Data] = [:]
    private var nextByte: UInt8 = 0x61

    func add(_ item: ExactKeychainItem, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard values[item] == nil else { throw KeychainBoundaryError.duplicateItem }
        values[item] = data
    }
    func copy(_ item: ExactKeychainItem) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let value = values[item] else { throw KeychainBoundaryError.missingItem }
        return value
    }
    func delete(_ item: ExactKeychainItem) throws {
        lock.lock(); defer { lock.unlock() }
        guard values.removeValue(forKey: item) != nil else { throw KeychainBoundaryError.missingItem }
    }
    func replace(_ item: ExactKeychainItem, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard values[item] != nil else { throw KeychainBoundaryError.missingItem }
        values[item] = data
    }
    func bytes(count: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        nextByte &+= 1
        return Data(repeating: nextByte, count: count)
    }
    func contains(_ item: ExactKeychainItem) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return values[item] != nil
    }
}

private final class ForgetTaskLeaseState: @unchecked Sendable {
    private let lock = NSLock()
    private var lease: LocalMemoryHostLease
    private let authorizedOwnerID: String
    init(_ lease: LocalMemoryHostLease, ownerID: String) {
        self.lease = lease
        authorizedOwnerID = ownerID
    }
    func update(_ lease: LocalMemoryHostLease) { lock.lock(); self.lease = lease; lock.unlock() }
    func snapshot() -> LocalMemoryHostLease { lock.lock(); defer { lock.unlock() }; return lease }
    func authorizes(ownerID: String, context: OwnerMemoryContext) -> Bool {
        let current = snapshot()
        return current.taskAuthority == .active && current.sessionID == context.sessionID
            && current.taskID == context.taskID && ownerID == authorizedOwnerID
    }
    func isTaskActive(ownerID: String, taskID: String) -> Bool {
        let current = snapshot()
        return current.taskAuthority == .active && current.taskID == taskID
            && ownerID == authorizedOwnerID
    }
    func policy(ownerID: String) -> OwnerMemoryPolicy {
        let current = snapshot()
        guard ownerID == authorizedOwnerID else {
            return OwnerMemoryPolicy(featureEnabled: false, incognito: true, noMemory: true,
                pauseLearning: true)
        }
        return OwnerMemoryPolicy(featureEnabled: true, incognito: current.memoryPolicy.incognito,
            noMemory: current.memoryPolicy.noMemory, pauseLearning: current.memoryPolicy.pauseLearning)
    }
}

@MainActor
final class PersonalMemoryForgetTaskContextTests: XCTestCase {
    private let peerID = "f8bfec8e-47ba-42a0-a20e-a2b791c28f5c"
    private let ownerID = String(repeating: "b", count: 64)

    func testCoordinatorForgetAndFreshTaskProviderShareIsolatedStoreLifecycle() async throws {
        let root = try makeMemoryRoot("PersonalMemoryComposedForgetProvider")
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = KeychainNamespace.testing("composed-forget-\(UUID().uuidString)")
        let keys = ForgetProviderTestKeys()
        let testOwnerID = ownerID
        let testPeerID = peerID
        let taskA = "synthetic-task-before-forget"
        let taskB = "synthetic-task-after-forget"
        let sessionA = "synthetic-session-before-forget"
        let sessionB = "synthetic-session-after-forget"
        let oldFact = "Synthetic test fact: the preferred garden flower is a blue iris."
        let newFact = "Synthetic test fact: the preferred garden flower is a yellow tulip."

        // Create the isolated encrypted generation; the owner-facing save itself below
        // goes through PersonalMemoryCoordinator's explicit remember command.
        let initial = try XCTUnwrap(try MemoryStoreFactory.openForTesting(enabled: true,
            root: root, client: keys, random: keys, namespace: namespace,
            authorize: { $0.ownerID == testOwnerID }, isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: true) }))
        try initial.close()
        let originalBinding = try XCTUnwrap(MemoryStoreFactory.captureBindingForTesting(
            enabled: true, root: root, client: keys, namespace: namespace))

        func lease(taskID: String, sessionID: String, generation: UInt64) -> LocalMemoryHostLease {
            LocalMemoryHostLease(peerID: peerID, sessionID: sessionID, taskID: taskID,
                authorizationGeneration: generation, taskAuthority: .active)
        }
        func makeCoordinator(_ leaseState: ForgetTaskLeaseState) -> PersonalMemoryCoordinator {
            PersonalMemoryCoordinator(enabled: true, ownerID: ownerID,
                leaseProvider: { request, _ in
                    let current = leaseState.snapshot()
                    return request.peerID == current.peerID && request.sessionID == current.sessionID
                        ? current : nil
                }, beginErasure: { _ in UUID() }, isErasureQuiescent: { _ in true }, endErasure: { _ in },
                captureBinding: {
                    try MemoryStoreFactory.captureBindingForTesting(enabled: true,
                        root: root, client: keys, namespace: namespace)
                },
                boundServiceFactory: { binding in
                    try MemoryStoreFactory.openBoundGenerationForTesting(enabled: true,
                        binding: binding, client: keys, random: keys,
                        authorize: { leaseState.authorizes(ownerID: $0.ownerID, context: $0) },
                        isTaskActive: { leaseState.isTaskActive(ownerID: $0, taskID: $1) },
                        policy: { leaseState.policy(ownerID: testOwnerID) })
                },
                boundForgetRecovery: { binding in
                    try MemoryStoreFactory.recoverBoundGenerationForTesting(enabled: true,
                        binding: binding, client: keys)
                },
                initializeGeneration: { binding, commandID in
                    try MemoryStoreFactory.initializeAfterForgetBindingForTesting(enabled: true,
                        expectedBinding: binding, commandID: commandID, client: keys, random: keys)
                })
        }
        func makeProvider(_ taskLease: LocalMemoryHostLease) -> PersonalMemoryTaskContextProvider {
            let embeddingEndpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil,
                baseURL: URL(string: "http://127.0.0.1:12345")!, bearerToken: "synthetic")
            let visionEndpoint = OSAtlasLlamaEndpoint(generation: 2, variant: nil,
                baseURL: URL(string: "http://127.0.0.1:12346")!, bearerToken: "synthetic")
            let runtime = PersonalMemoryTaskRuntimeOperations(
                activateEmbedding: { _ in embeddingEndpoint },
                embed: { _, _, _ in Array(repeating: Float(1), count: PersonalMemoryRuntimeInputs.embeddingDimensions) },
                activateAgentVision: { _ in visionEndpoint },
                countMemoryTokens: { _, context in max(1, context.split(whereSeparator: \.isWhitespace).count) },
                cancel: { _ in })
            return PersonalMemoryTaskContextProvider(enabled: true,
                ownerID: { testOwnerID },
                isLeaseCurrent: { $0 == taskLease },
                isLeaseCurrentSynchronously: { $0 == taskLease },
                faraRuntimeInputs: {
                    AgentVisionRuntimeInputs(model: .fara15_4b,
                        modelURL: URL(fileURLWithPath: "/synthetic/fara"),
                        projectorURL: URL(fileURLWithPath: "/synthetic/projector"),
                        llamaServerURL: URL(fileURLWithPath: "/synthetic/llama-server"))
                },
                captureBinding: {
                    try MemoryStoreFactory.captureBindingForTesting(enabled: true,
                        root: root, client: keys, namespace: namespace)
                },
                openService: { context, binding, isCurrent in
                    try MemoryStoreFactory.openBoundGenerationForTesting(enabled: true,
                        binding: binding, client: keys, random: keys,
                        authorize: { $0.ownerID == testOwnerID && $0.sessionID == context.sessionID
                            && $0.taskID == context.taskID && isCurrent() },
                        isTaskActive: { $0 == testOwnerID && $1 == context.taskID && isCurrent() },
                        policy: { OwnerMemoryPolicy(featureEnabled: true) })
                }, runtime: runtime,
                embeddingInputs: { PersonalMemoryRuntimeInputs(
                    modelURL: URL(fileURLWithPath: "/synthetic/embedding"),
                    llamaServerURL: URL(fileURLWithPath: "/synthetic/llama-server")) })
        }

        let leaseA = lease(taskID: taskA, sessionID: sessionA, generation: 11)
        let contextA = LocalMemoryRPCContext(peerID: testPeerID, sessionID: sessionA)
        let coordinatorA = makeCoordinator(ForgetTaskLeaseState(leaseA, ownerID: testOwnerID))
        defer { coordinatorA.close() }
        let saved = await coordinatorA.handle(LocalMemoryRPCCommand(rememberKind: .fact,
            text: oldFact, commandID: UUID().uuidString.lowercased()), context: contextA)
        XCTAssertEqual(saved.status, .completed)
        let providerA = makeProvider(leaseA)
        let capturedA = try await providerA.captureBinding(for: leaseA)
        let bindingA = try XCTUnwrap(capturedA)
        XCTAssertEqual(bindingA, originalBinding)
        let preparedA = try await providerA.prepare(lease: leaseA, binding: bindingA,
            prompt: "What is my synthetic garden flower preference?")
        let retrievedA = try XCTUnwrap(preparedA)
        XCTAssertTrue(retrievedA.contains("blue iris"))
        XCTAssertFalse(retrievedA.contains("yellow tulip"))

        let forgotten = await coordinatorA.handle(LocalMemoryRPCCommand(
            forgetEverything: UUID().uuidString.lowercased(),
            generationReference: bindingA.reference), context: contextA)
        XCTAssertEqual(forgotten.status, .completed)
        let forgottenDatabase = bindingA.generation.root.appendingPathComponent("memory.sqlite")
        for path in [forgottenDatabase.path, forgottenDatabase.path + "-wal",
                     forgottenDatabase.path + "-shm", forgottenDatabase.path + "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), "Forget left storage at \(path)")
        }
        XCTAssertFalse(keys.contains(ExactKeychainItem(
            service: bindingA.generation.namespace.databaseKeyService,
            account: "database-key", protection: .deviceOnlyWhenUnlocked)))
        // The durable completed-Forget marker is intentionally retained for verified-absent
        // reads; the SQLite rollback journal and encrypted database/key must be gone.
        let staleRetry: String?
        do {
            staleRetry = try await providerA.prepare(lease: leaseA, binding: bindingA,
                prompt: "What is my synthetic garden flower preference?")
        } catch is TaskMemoryContextFailure {
            staleRetry = nil
        }
        XCTAssertTrue(staleRetry == nil || staleRetry == "[]",
            "A stale task binding must fail closed or return only the verified empty context")
        XCTAssertFalse(staleRetry?.contains("blue iris") ?? false,
            "A stale task binding must never retrieve the forgotten record")
        coordinatorA.close()

        let leaseB = lease(taskID: taskB, sessionID: sessionB, generation: 12)
        let contextB = LocalMemoryRPCContext(peerID: testPeerID, sessionID: sessionB)
        let leaseStateB = ForgetTaskLeaseState(leaseB, ownerID: testOwnerID)
        let coordinatorB = makeCoordinator(leaseStateB)
        defer { coordinatorB.close() }
        let providerB = makeProvider(leaseB)
        let capturedAbsent = try await providerB.captureBinding(for: leaseB)
        let absentBinding = try XCTUnwrap(capturedAbsent)
        let absentPrepared = try await providerB.prepare(lease: leaseB, binding: absentBinding,
            prompt: "What is my synthetic garden flower preference?")
        let beforeStartFresh = try XCTUnwrap(absentPrepared)
        XCTAssertEqual(beforeStartFresh, "[]")
        XCTAssertFalse(beforeStartFresh.contains("blue iris"))

        let captured = await coordinatorB.handle(LocalMemoryRPCCommand(captureMemoryGeneration: ()),
            context: contextB)
        XCTAssertEqual(captured.status, .completed)
        let emptyForget = await coordinatorB.handle(LocalMemoryRPCCommand(
            forgetEverything: UUID().uuidString.lowercased(), generationReference: absentBinding.reference),
            context: contextB)
        XCTAssertEqual(emptyForget.status, .completed)
        let initialized = await coordinatorB.handle(LocalMemoryRPCCommand(
            initializeMemoryGeneration: UUID().uuidString.lowercased(),
            generationReference: absentBinding.reference), context: contextB)
        XCTAssertEqual(initialized.status, .completed)
        let replacementBinding = try XCTUnwrap(try MemoryStoreFactory.captureBindingForTesting(
            enabled: true, root: root, client: keys, namespace: namespace))
        XCTAssertEqual(replacementBinding.reference, initialized.replacementGenerationReference)
        XCTAssertTrue(keys.contains(ExactKeychainItem(
            service: replacementBinding.generation.namespace.databaseKeyService,
            account: "database-key", protection: .deviceOnlyWhenUnlocked)))

        let emptyAfterFresh = try await providerB.prepare(lease: leaseB,
            binding: replacementBinding, prompt: "What is my synthetic garden flower preference?")
        XCTAssertEqual(emptyAfterFresh, "[]")
        XCTAssertFalse(emptyAfterFresh?.contains("blue iris") ?? true)

        let staleTaskWrite = await coordinatorB.handle(LocalMemoryRPCCommand(rememberKind: .fact,
            text: newFact, commandID: UUID().uuidString.lowercased()), context: contextB)
        XCTAssertEqual(staleTaskWrite.status, .unavailable,
            "The task that confirmed Start Fresh must renew authenticated scope before writing")

        let taskC = "synthetic-task-after-reconnect"
        let sessionC = "synthetic-session-after-reconnect"
        let leaseC = lease(taskID: taskC, sessionID: sessionC, generation: 13)
        let contextC = LocalMemoryRPCContext(peerID: testPeerID, sessionID: sessionC)
        leaseStateB.update(leaseC)
        let providerC = makeProvider(leaseC)
        let capturedC = try await providerC.captureBinding(for: leaseC)
        let bindingC = try XCTUnwrap(capturedC)
        XCTAssertEqual(bindingC, replacementBinding)
        let savedNew = await coordinatorB.handle(LocalMemoryRPCCommand(rememberKind: .fact,
            text: newFact, commandID: UUID().uuidString.lowercased()), context: contextC)
        XCTAssertEqual(savedNew.status, .completed)
        let newPrepared = try await providerC.prepare(lease: leaseC, binding: bindingC,
            prompt: "What is my synthetic garden flower preference?")
        let afterStartFresh = try XCTUnwrap(newPrepared)
        XCTAssertTrue(afterStartFresh.contains("yellow tulip"))
        XCTAssertFalse(afterStartFresh.contains("blue iris"))
    }

    private func makeMemoryRoot(_ prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return root
    }
}
#endif

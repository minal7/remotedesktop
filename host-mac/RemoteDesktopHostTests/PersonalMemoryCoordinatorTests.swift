import Foundation
import XCTest
@testable import RemoteDesktopHost
@testable import MemoryStoreKit

private final class CoordinatorLifecycleTestKeys: KeychainClient, MemoryKeyRandomSource, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ExactKeychainItem: Data] = [:]
    private var nextByte: UInt8 = 0x40

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

@MainActor
final class PersonalMemoryCoordinatorTests: XCTestCase {
    private let hostID = "8A2269A1-A94C-4FA2-BD63-BEAEEA79A97A"
    private let peerID = "53A8D639-5DE2-4786-BE26-2AC9F853D3B6"
    private let pairingCode = "123456"
    private let sessionID = "memory-session-1"
    private let ownerID = String(repeating: "a", count: 64)

    func testBrokerCoordinatorWritesRetriesListsAndDeletesInEncryptedStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalMemoryCoordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("memory.sqlite")
        let keyProvider = TestMemoryKeyProvider(key: Data(repeating: 0x37, count: 32))
        let store = try XCTUnwrap(try MemoryStore.open(
            enabled: true, databaseURL: databaseURL, keyProvider: keyProvider))
        let writer = OwnerMemoryWriter(
            store: store,
            authorize: { context in context.ownerID == self.ownerID && context.sessionID == self.sessionID },
            isTaskActive: { ownerID, taskID in ownerID == self.ownerID && taskID == "host-task-1" },
            policy: { OwnerMemoryPolicy(featureEnabled: true) })
        let lease = LocalMemoryHostLease(
            peerID: peerID, sessionID: sessionID, taskID: nil,
            authorizationGeneration: 9, taskAuthority: .none)
        let coordinator = PersonalMemoryCoordinator(
            enabled: true,
            ownerID: ownerID,
            leaseProvider: { context, requiresTask in
                guard context.peerID == self.peerID,
                      context.sessionID == self.sessionID,
                      !requiresTask else { return nil }
                return lease
            },
            writerFactory: { writer })
        let channel = LocalHostComputerUseChannel(hostID: hostID, pairingCode: pairingCode)
        let server = makeServer(channel: channel, enabled: true, coordinator: coordinator)
        defer {
            server.stop()
            coordinator.close()
            try? store.close()
        }

        let commandID = UUID().uuidString
        let command = LocalMemoryRPCCommand(
            rememberKind: .fact,
            text: "Owner note stays inside encrypted storage",
            commandID: commandID)
        let saved = try await send(command, through: server)
        XCTAssertEqual(saved.status, .completed)
        XCTAssertEqual(saved.commandID, commandID)
        XCTAssertEqual(saved.rememberKind, .fact)
        XCTAssertEqual(saved.idempotentRetry, false)
        let recordID = try XCTUnwrap(saved.recordID)

        let retry = try await send(command, through: server)
        XCTAssertEqual(retry.recordID, recordID)
        XCTAssertEqual(retry.idempotentRetry, true)

        let listed = try await send(LocalMemoryRPCCommand(listMetadata: 8), through: server)
        XCTAssertEqual(listed.status, .completed)
        XCTAssertEqual(listed.metadata.map(\.recordID), [recordID])
        XCTAssertEqual(listed.metadata.first?.kind, .fact)
        let encodedList = String(decoding: try LocalComputerUseRPCCodec.encode(
            LocalComputerUseRPCResponse(
                requestID: UUID().uuidString,
                senderID: hostID,
                targetID: peerID,
                memoryReply: listed)), as: UTF8.self)
        XCTAssertFalse(encodedList.contains("Owner note stays inside encrypted storage"))

        let deleted = try await send(LocalMemoryRPCCommand(deleteMetadata: recordID), through: server)
        XCTAssertEqual(deleted.status, .completed)
        let emptyList = try await send(LocalMemoryRPCCommand(listMetadata: 8), through: server)
        XCTAssertTrue(emptyList.metadata.isEmpty)
        let queuedEnvelopes = try await channel.poll()
        XCTAssertTrue(queuedEnvelopes.isEmpty, "Memory RPC must not write to the task mailbox")

        // Reopening with a different key must fail, proving the linked host
        // target uses the SQLCipher bridge rather than plain system SQLite.
        try store.close()
        XCTAssertThrowsError(try MemoryStore.open(
            enabled: true,
            databaseURL: databaseURL,
            keyProvider: TestMemoryKeyProvider(key: Data(repeating: 0x91, count: 32))))
    }

    func testNewCoordinatorListsEmptyAfterForgetWithoutRecreatingLegacyStore() async throws {
        let root = try makeMemoryRoot("PersonalMemoryPostForgetEmptyRead")
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = KeychainNamespace.testing("post-forget-empty-\(UUID().uuidString)")
        let keys = CoordinatorLifecycleTestKeys()
        let context = OwnerMemoryContext(ownerID: ownerID, sessionID: sessionID, taskID: nil)
        let original = try XCTUnwrap(MemoryStoreFactory.openForTesting(enabled: true, root: root,
            client: keys, random: keys, namespace: namespace,
            authorize: { $0 == context }, isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: true) }))
        let binding = try XCTUnwrap(MemoryStoreFactory.captureBindingForTesting(enabled: true,
            root: root, client: keys, namespace: namespace))
        _ = try original.writer.remember(kind: .fact, text: "synthetic post-Forget row",
            commandID: UUID().uuidString.lowercased(), context: context)
        try original.forgetAll()
        try original.close()

        let afterForget = try XCTUnwrap(MemoryStoreFactory.captureBindingForTesting(enabled: true,
            root: root, client: keys, namespace: namespace))
        XCTAssertEqual(afterForget, binding)
        let database = root.appendingPathComponent("memory.sqlite")
        for path in [database.path, database.path + "-wal", database.path + "-shm",
                     database.path + "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
        XCTAssertFalse(keys.contains(ExactKeychainItem(service: namespace.databaseKeyService,
            account: "database-key", protection: .deviceOnlyWhenUnlocked)))
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            root.appendingPathComponent(".vault-lifecycle.lock").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            root.appendingPathComponent(".generation-transition.lock").path))
        let expectedEntries: Set<String> = [".vault-lifecycle.lock", ".generation-transition.lock"]
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
                       expectedEntries)

        let lease = LocalMemoryHostLease(peerID: peerID, sessionID: sessionID, taskID: nil,
            authorizationGeneration: 41, taskAuthority: .none)
        func makeCoordinator() -> PersonalMemoryCoordinator {
            PersonalMemoryCoordinator(enabled: true, ownerID: ownerID,
                leaseProvider: { request, requiresTask in
                    guard request.peerID == self.peerID, request.sessionID == self.sessionID,
                          !requiresTask else { return nil }
                    return lease
                },
                captureBinding: {
                    try MemoryStoreFactory.captureBindingForTesting(enabled: true,
                        root: root, client: keys, namespace: namespace)
                },
                boundServiceFactory: { captured in
                    try MemoryStoreFactory.openBoundGenerationForTesting(enabled: true,
                        binding: captured, client: keys, random: keys,
                        authorize: { $0 == context }, isTaskActive: { _, _ in true },
                        policy: { OwnerMemoryPolicy(featureEnabled: true) })
                })
        }
        let coordinator = makeCoordinator()
        defer { coordinator.close() }

        let listed = await coordinator.handle(LocalMemoryRPCCommand(listRecords: 8),
            context: LocalMemoryRPCContext(peerID: peerID, sessionID: sessionID))
        XCTAssertEqual(listed.status, .completed)
        XCTAssertTrue(listed.records.isEmpty)
        XCTAssertNil(listed.nextRecordID)
        let searched = await coordinator.handle(
            LocalMemoryRPCCommand(searchRecords: "synthetic", afterRecordID: UUID().uuidString.lowercased()),
            context: LocalMemoryRPCContext(peerID: peerID, sessionID: sessionID))
        XCTAssertEqual(searched.status, .completed)
        XCTAssertTrue(searched.records.isEmpty)
        XCTAssertNil(searched.nextRecordID)
        let attemptedWrite = await coordinator.handle(LocalMemoryRPCCommand(
            rememberKind: .fact, text: "must not initialize", commandID: UUID().uuidString.lowercased()),
            context: LocalMemoryRPCContext(peerID: peerID, sessionID: sessionID))
        XCTAssertEqual(attemptedWrite.status, .unavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        XCTAssertFalse(keys.contains(ExactKeychainItem(service: namespace.databaseKeyService,
            account: "database-key", protection: .deviceOnlyWhenUnlocked)))

        let sidecar = URL(fileURLWithPath: database.path + "-wal")
        try Data([0xA5]).write(to: sidecar)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
            ofItemAtPath: sidecar.path)
        let sidecarCoordinator = makeCoordinator()
        defer { sidecarCoordinator.close() }
        let sidecarReply = await sidecarCoordinator.handle(
            LocalMemoryRPCCommand(listRecords: 8),
            context: LocalMemoryRPCContext(peerID: peerID, sessionID: sessionID))
        XCTAssertEqual(sidecarReply.status, .unavailable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        XCTAssertFalse(keys.contains(ExactKeychainItem(service: namespace.databaseKeyService,
            account: "database-key", protection: .deviceOnlyWhenUnlocked)))
        try FileManager.default.removeItem(at: sidecar)

        let unknown = root.appendingPathComponent("unexpected-state")
        try Data([0xA5]).write(to: unknown)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unknown.path)
        let unknownReply = await makeCoordinator().handle(LocalMemoryRPCCommand(listRecords: 8),
            context: LocalMemoryRPCContext(peerID: peerID, sessionID: sessionID))
        XCTAssertEqual(unknownReply.status, .unavailable)
        try FileManager.default.removeItem(at: unknown)

        let pendingSidecar = URL(fileURLWithPath: database.path + "-wal")
        try Data([0xA5]).write(to: pendingSidecar)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
            ofItemAtPath: pendingSidecar.path)
        try ForgetRecoveryJournal.prepare(client: keys, root: root, namespace: namespace)
        let pendingReply = await makeCoordinator().handle(LocalMemoryRPCCommand(listRecords: 8),
            context: LocalMemoryRPCContext(peerID: peerID, sessionID: sessionID))
        XCTAssertEqual(pendingReply.status, .unavailable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingSidecar.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        XCTAssertFalse(keys.contains(ExactKeychainItem(service: namespace.databaseKeyService,
            account: "database-key", protection: .deviceOnlyWhenUnlocked)))
    }

    func testSameCoordinatorListsEmptyAfterForgetForFreshAuthorizedSession() async throws {
        let root = try makeMemoryRoot("PersonalMemorySameCoordinatorPostForget")
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = KeychainNamespace.testing("same-coordinator-post-forget-\(UUID().uuidString)")
        let keys = CoordinatorLifecycleTestKeys()
        let oldSessionID = sessionID
        let newSessionID = "memory-session-after-forget"
        var currentSessionID = oldSessionID
        var authorizationGeneration: UInt64 = 41
        let oldContext = OwnerMemoryContext(ownerID: ownerID, sessionID: oldSessionID)
        let original = try XCTUnwrap(MemoryStoreFactory.openForTesting(enabled: true, root: root,
            client: keys, random: keys, namespace: namespace,
            authorize: { $0 == oldContext }, isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: true) }))
        let binding = try XCTUnwrap(MemoryStoreFactory.captureBindingForTesting(enabled: true,
            root: root, client: keys, namespace: namespace))
        _ = try original.writer.remember(kind: .fact, text: "synthetic same-process Forget row",
            commandID: UUID().uuidString.lowercased(), context: oldContext)
        try original.close()

        let coordinator = PersonalMemoryCoordinator(enabled: true, ownerID: ownerID,
            leaseProvider: { request, requiresTask in
                guard request.peerID == self.peerID,
                      request.sessionID == currentSessionID, !requiresTask else { return nil }
                return LocalMemoryHostLease(peerID: self.peerID, sessionID: currentSessionID,
                    taskID: nil, authorizationGeneration: authorizationGeneration,
                    taskAuthority: .none)
            }, beginErasure: { _ in UUID() },
            isErasureQuiescent: { _ in true },
            endErasure: { _ in },
            captureBinding: {
                try MemoryStoreFactory.captureBindingForTesting(enabled: true,
                    root: root, client: keys, namespace: namespace)
            },
            boundServiceFactory: { captured in
                try MemoryStoreFactory.openBoundGenerationForTesting(enabled: true,
                    binding: captured, client: keys, random: keys,
                    authorize: { $0.ownerID == self.ownerID }, isTaskActive: { _, _ in true },
                    policy: { OwnerMemoryPolicy(featureEnabled: true) })
            })
        defer { coordinator.close() }

        let oldRequest = LocalMemoryRPCContext(peerID: peerID, sessionID: oldSessionID)
        let forgotten = await coordinator.handle(LocalMemoryRPCCommand(
            forgetEverything: UUID().uuidString.lowercased(), generationReference: binding.reference),
            context: oldRequest)
        XCTAssertEqual(forgotten.status, .completed)
        XCTAssertEqual(forgotten.generationReference, binding.reference)

        currentSessionID = newSessionID
        authorizationGeneration += 1
        let newRequest = LocalMemoryRPCContext(peerID: peerID, sessionID: newSessionID)
        let listed = await coordinator.handle(LocalMemoryRPCCommand(listRecords: 8), context: newRequest)
        XCTAssertEqual(listed.status, .completed)
        XCTAssertTrue(listed.records.isEmpty)
        XCTAssertNil(listed.nextRecordID)

        let database = root.appendingPathComponent("memory.sqlite")
        for path in [database.path, database.path + "-wal", database.path + "-shm",
                     database.path + "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
        XCTAssertEqual(try MemoryStoreFactory.captureBindingForTesting(enabled: true,
            root: root, client: keys, namespace: namespace), binding)
        let databaseKey = ExactKeychainItem(service: namespace.databaseKeyService,
            account: "database-key", protection: .deviceOnlyWhenUnlocked)
        XCTAssertFalse(keys.contains(databaseKey))

        let attemptedWrite = await coordinator.handle(LocalMemoryRPCCommand(
            rememberKind: .fact, text: "must require fresh initialization",
            commandID: UUID().uuidString.lowercased()), context: newRequest)
        XCTAssertEqual(attemptedWrite.status, .unavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        XCTAssertFalse(keys.contains(databaseKey))

        let unknown = root.appendingPathComponent("unexpected-state")
        try Data([0xA5]).write(to: unknown)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unknown.path)
        let corruptStateReply = await coordinator.handle(LocalMemoryRPCCommand(listRecords: 8),
            context: newRequest)
        XCTAssertEqual(corruptStateReply.status, .unavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        XCTAssertFalse(keys.contains(databaseKey))
    }

    func testExistingDatabaseKeyFailureDoesNotReturnEmptyList() async throws {
        let root = try makeMemoryRoot("PersonalMemoryExistingDatabaseFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = KeychainNamespace.testing("existing-db-failure-\(UUID().uuidString)")
        let keys = CoordinatorLifecycleTestKeys()
        let context = OwnerMemoryContext(ownerID: ownerID, sessionID: sessionID)
        let service = try XCTUnwrap(MemoryStoreFactory.openForTesting(enabled: true, root: root,
            client: keys, random: keys, namespace: namespace,
            authorize: { $0 == context }, isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: true) }))
        let binding = try XCTUnwrap(MemoryStoreFactory.captureBindingForTesting(enabled: true,
            root: root, client: keys, namespace: namespace))
        _ = try service.writer.remember(kind: .fact, text: "synthetic retained record",
            commandID: UUID().uuidString.lowercased(), context: context)
        try service.close()
        let database = root.appendingPathComponent("memory.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
        try keys.replace(ExactKeychainItem(service: namespace.databaseKeyService,
            account: "database-key", protection: .deviceOnlyWhenUnlocked),
            data: Data(repeating: 0xE7, count: 32))

        let lease = LocalMemoryHostLease(peerID: peerID, sessionID: sessionID, taskID: nil,
            authorizationGeneration: 42, taskAuthority: .none)
        let coordinator = PersonalMemoryCoordinator(enabled: true, ownerID: ownerID,
            leaseProvider: { request, requiresTask in
                guard request.peerID == self.peerID, request.sessionID == self.sessionID,
                      !requiresTask else { return nil }
                return lease
            },
            captureBinding: {
                try MemoryStoreFactory.captureBindingForTesting(enabled: true,
                    root: root, client: keys, namespace: namespace)
            },
            boundServiceFactory: { captured in
                XCTAssertEqual(captured, binding)
                return try MemoryStoreFactory.openBoundGenerationForTesting(enabled: true,
                    binding: captured, client: keys, random: keys,
                    authorize: { $0 == context }, isTaskActive: { _, _ in true },
                    policy: { OwnerMemoryPolicy(featureEnabled: true) })
            })
        defer { coordinator.close() }

        let listed = await coordinator.handle(LocalMemoryRPCCommand(listRecords: 8),
            context: LocalMemoryRPCContext(peerID: peerID, sessionID: sessionID))
        XCTAssertEqual(listed.status, .unavailable)
        XCTAssertTrue(listed.records.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
    }

    func testExplicitRememberPersistsUnderNoMemoryAndPauseLearning() async throws {
        let root = try makeMemoryRoot("PersonalMemoryExplicitRemember")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try XCTUnwrap(try MemoryStore.open(
            enabled: true,
            databaseURL: root.appendingPathComponent("memory.sqlite"),
            keyProvider: TestMemoryKeyProvider(key: Data(repeating: 0x62, count: 32))))
        let restrictive = OwnerMemoryWriter(
            store: store,
            authorize: { context in context.ownerID == self.ownerID && context.sessionID == self.sessionID },
            isTaskActive: { _, _ in false },
            policy: { OwnerMemoryPolicy(featureEnabled: true, noMemory: true, pauseLearning: true) })
        let reader = OwnerMemoryWriter(
            store: store,
            authorize: { context in context.ownerID == self.ownerID && context.sessionID == self.sessionID },
            isTaskActive: { _, _ in false },
            policy: { OwnerMemoryPolicy(featureEnabled: true) })
        let lease = LocalMemoryHostLease(
            peerID: peerID, sessionID: sessionID, taskID: nil,
            authorizationGeneration: 31, taskAuthority: .none,
            memoryPolicy: ComputerUseTaskMemoryPolicy(noMemory: true, pauseLearning: true))
        let coordinator = PersonalMemoryCoordinator(
            enabled: true, ownerID: ownerID,
            leaseProvider: { context, requiresTask in
                guard context.peerID == self.peerID,
                      context.sessionID == self.sessionID, !requiresTask else { return nil }
                return lease
            },
            writerFactory: { restrictive })
        let channel = LocalHostComputerUseChannel(hostID: hostID, pairingCode: pairingCode)
        let server = makeServer(channel: channel, enabled: true, coordinator: coordinator)
        defer { server.stop(); coordinator.close(); try? store.close() }

        let command = LocalMemoryRPCCommand(
            rememberKind: .fact, text: "Explicit owner save is retained",
            commandID: "explicit-no-memory-save")
        let saved = try await send(command, through: server)
        XCTAssertEqual(saved.status, .completed)
        let recordID = try XCTUnwrap(saved.recordID)
        let rows = try reader.list(context: OwnerMemoryContext(ownerID: ownerID, sessionID: sessionID))
        XCTAssertEqual(rows.map(\.id), [recordID])
        XCTAssertEqual(rows.first?.body, "Explicit owner save is retained")
        XCTAssertEqual(rows.first?.source, .ownerMessage)
    }

    func testIncognitoRememberLeavesEncryptedStoreUnchanged() async throws {
        let root = try makeMemoryRoot("PersonalMemoryIncognitoRemember")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try XCTUnwrap(try MemoryStore.open(
            enabled: true,
            databaseURL: root.appendingPathComponent("memory.sqlite"),
            keyProvider: TestMemoryKeyProvider(key: Data(repeating: 0x63, count: 32))))
        let writer = OwnerMemoryWriter(
            store: store,
            authorize: { context in context.ownerID == self.ownerID && context.sessionID == self.sessionID },
            isTaskActive: { _, _ in false },
            policy: { OwnerMemoryPolicy(featureEnabled: true, incognito: true) })
        let reader = OwnerMemoryWriter(
            store: store,
            authorize: { context in context.ownerID == self.ownerID && context.sessionID == self.sessionID },
            isTaskActive: { _, _ in false },
            policy: { OwnerMemoryPolicy(featureEnabled: true) })
        var writerFactoryCalls = 0
        let lease = LocalMemoryHostLease(
            peerID: peerID, sessionID: sessionID, taskID: nil,
            authorizationGeneration: 32, taskAuthority: .none,
            memoryPolicy: ComputerUseTaskMemoryPolicy(incognito: true))
        let coordinator = PersonalMemoryCoordinator(
            enabled: true, ownerID: ownerID,
            leaseProvider: { context, requiresTask in
                guard context.peerID == self.peerID,
                      context.sessionID == self.sessionID, !requiresTask else { return nil }
                return lease
            },
            writerFactory: { writerFactoryCalls += 1; return writer })
        let channel = LocalHostComputerUseChannel(hostID: hostID, pairingCode: pairingCode)
        let server = makeServer(channel: channel, enabled: true, coordinator: coordinator)
        defer { server.stop(); coordinator.close(); try? store.close() }

        let result = try await send(LocalMemoryRPCCommand(
            rememberKind: .profile, text: "Incognito save must not persist",
            commandID: "incognito-save"), through: server)
        XCTAssertEqual(result.status, .incognito)
        XCTAssertEqual(writerFactoryCalls, 0)
        XCTAssertTrue(try reader.list(context: OwnerMemoryContext(ownerID: ownerID, sessionID: sessionID)).isEmpty)
    }

    func testGenerationChangeDuringWriterResolutionRejectsRemember() async throws {
        let root = try makeMemoryRoot("PersonalMemoryGenerationRemember")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try XCTUnwrap(try MemoryStore.open(
            enabled: true,
            databaseURL: root.appendingPathComponent("memory.sqlite"),
            keyProvider: TestMemoryKeyProvider(key: Data(repeating: 0x64, count: 32))))
        let writer = OwnerMemoryWriter(
            store: store,
            authorize: { context in context.ownerID == self.ownerID && context.sessionID == self.sessionID },
            isTaskActive: { _, _ in false },
            policy: { OwnerMemoryPolicy(featureEnabled: true) })
        let context = LocalMemoryRPCContext(peerID: peerID, sessionID: sessionID)
        var generation: UInt64 = 33
        var writerResolutionCalls = 0
        let coordinator = PersonalMemoryCoordinator(
            enabled: true, ownerID: ownerID,
            leaseProvider: { request, requiresTask in
                guard request == context, !requiresTask else { return nil }
                return LocalMemoryHostLease(
                    peerID: self.peerID, sessionID: self.sessionID, taskID: nil,
                    authorizationGeneration: generation, taskAuthority: .none)
            },
            writerFactory: {
                writerResolutionCalls += 1
                // Model revocation while the real encrypted writer is being resolved.
                // Peer and session remain authorized; only the lease generation changes.
                generation += 1
                return writer
            })
        let channel = LocalHostComputerUseChannel(hostID: hostID, pairingCode: pairingCode)
        let server = makeServer(channel: channel, enabled: true, coordinator: coordinator)
        defer { server.stop(); coordinator.close(); try? store.close() }

        let result = try await send(LocalMemoryRPCCommand(
            rememberKind: .fact, text: "Stale generation must not commit",
            commandID: "generation-change-save"), through: server)
        XCTAssertEqual(result.status, .unauthorized)
        XCTAssertEqual(writerResolutionCalls, 1)
        XCTAssertEqual(generation, 34)
        XCTAssertTrue(try writer.list(context: OwnerMemoryContext(ownerID: ownerID, sessionID: sessionID)).isEmpty)
    }

    func testProposalConfirmationRemainsDisabledWhenOrdinaryMemoryIsEnabled() async throws {
        var writerFactoryCalls = 0
        let context = LocalMemoryRPCContext(peerID: peerID, sessionID: sessionID)
        let coordinator = PersonalMemoryCoordinator(
            enabled: true,
            ownerID: ownerID,
            leaseProvider: { requestContext, requiresTask in
                guard requiresTask, requestContext == context else { return nil }
                return LocalMemoryHostLease(peerID: self.peerID, sessionID: self.sessionID,
                    taskID: "synthetic-task", authorizationGeneration: 1, taskAuthority: .active)
            },
            writerFactory: { writerFactoryCalls += 1; return nil })
        defer { coordinator.close() }

        let reply = await coordinator.handle(LocalMemoryRPCCommand(
            confirmProposalID: UUID().uuidString.lowercased(),
            commandID: UUID().uuidString.lowercased()), context: context)
        XCTAssertEqual(reply.status, .disabled)
        XCTAssertEqual(writerFactoryCalls, 0)
    }

    func testDisabledCoordinatorDoesNotConstructWriterOrTouchStorage() async throws {
        var serviceFactoryCalls = 0
        var writerFactoryCalls = 0
        let coordinator = PersonalMemoryCoordinator(
            enabled: false,
            ownerID: ownerID,
            leaseProvider: { _, _ in XCTFail("Disabled feature must not ask for a host lease"); return nil },
            serviceFactory: { serviceFactoryCalls += 1; return nil },
            writerFactory: { writerFactoryCalls += 1; return nil })
        let channel = LocalHostComputerUseChannel(hostID: hostID, pairingCode: pairingCode)
        let server = makeServer(channel: channel, enabled: true, coordinator: coordinator)
        defer { server.stop(); coordinator.close() }

        let request = makeRequest(LocalMemoryRPCCommand(
            rememberKind: .fact, text: "never persisted", commandID: UUID().uuidString))
        let response = try await server.handle(request)
        XCTAssertEqual(response.memoryReply?.status, .disabled)
        XCTAssertEqual(serviceFactoryCalls, 0)
        XCTAssertEqual(writerFactoryCalls, 0)
        let queuedEnvelopes = try await channel.poll()
        XCTAssertTrue(queuedEnvelopes.isEmpty)
    }

    func testRevokedPeerSessionAndTaskCannotReachWriter() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalMemoryLease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try XCTUnwrap(try MemoryStore.open(
            enabled: true,
            databaseURL: root.appendingPathComponent("memory.sqlite"),
            keyProvider: TestMemoryKeyProvider(key: Data(repeating: 0x45, count: 32))))
        var writerFactoryCalls = 0
        let writer = OwnerMemoryWriter(
            store: store,
            authorize: { _ in true },
            isTaskActive: { _, _ in false },
            policy: { OwnerMemoryPolicy(featureEnabled: true) })
        var leaseValid = true
        var leasedPeerID = peerID
        var leasedSessionID = sessionID
        let coordinator = PersonalMemoryCoordinator(
            enabled: true,
            ownerID: ownerID,
            leaseProvider: { _, requiresTask in
                guard leaseValid, !requiresTask else { return nil }
                return LocalMemoryHostLease(
                    peerID: leasedPeerID, sessionID: leasedSessionID, taskID: nil,
                    authorizationGeneration: 2, taskAuthority: .none)
            },
            writerFactory: { writerFactoryCalls += 1; return writer })
        let channel = LocalHostComputerUseChannel(hostID: hostID, pairingCode: pairingCode)
        let server = makeServer(channel: channel, enabled: true, coordinator: coordinator)
        defer { server.stop(); coordinator.close(); try? store.close() }

        let remember = LocalMemoryRPCCommand(
            rememberKind: .profile, text: "not written", commandID: UUID().uuidString)
        leasedPeerID = "89CD465C-DEB5-4B48-B758-4C94206891D8"
        let mismatchedPeer = try await server.handle(makeRequest(remember))
        XCTAssertEqual(mismatchedPeer.memoryReply?.status, .unauthorized)
        XCTAssertEqual(writerFactoryCalls, 0)

        leasedPeerID = peerID
        let mismatchedSession = try await server.handle(LocalComputerUseRPCRequest(
            senderID: peerID, targetID: hostID,
            sessionID: "other-session", memoryCommand: remember))
        XCTAssertEqual(mismatchedSession.memoryReply?.status, .unauthorized)
        XCTAssertEqual(writerFactoryCalls, 0)

        let confirm = LocalMemoryRPCCommand(
            confirmProposalID: UUID().uuidString, commandID: UUID().uuidString)
        let missingTask = try await server.handle(makeRequest(confirm))
        XCTAssertEqual(missingTask.memoryReply?.status, .inactiveTask)
        XCTAssertEqual(writerFactoryCalls, 0)

        leaseValid = false
        let revoked = try await server.handle(makeRequest(remember))
        XCTAssertEqual(revoked.memoryReply?.status, .unauthorized)
        XCTAssertEqual(writerFactoryCalls, 0)
    }

    func testManagerLeaseIsBoundToAuthorizedPeerAndFirstSession() async throws {
        let manager = HostComputerUseManager(
            experimentalEnabled: { false },
            injector: InputInjector(),
            allowsExternalServices: false,
            allowsAutomaticSetup: false)
        XCTAssertTrue(manager.authorizeLocalPeer(senderID: peerID))
        let lease = try XCTUnwrap(manager.localMemoryLease(
            peerID: peerID, sessionID: sessionID, requiresTask: false))
        XCTAssertEqual(lease.peerID, peerID)
        XCTAssertEqual(lease.sessionID, sessionID)
        XCTAssertNil(lease.taskID)
        XCTAssertEqual(lease.taskAuthority, .none)
        XCTAssertNil(manager.localMemoryLease(
            peerID: "89CD465C-DEB5-4B48-B758-4C94206891D8",
            sessionID: sessionID,
            requiresTask: false))
        XCTAssertNil(manager.localMemoryLease(
            peerID: peerID,
            sessionID: "different-session",
            requiresTask: false))
        manager.revokeLocalPeerAuthorization(senderID: peerID)
        XCTAssertNil(manager.localMemoryLease(
            peerID: peerID, sessionID: sessionID, requiresTask: false))
    }

    func testCompletedTaskConfirmationLeaseIsInvalidatedByStopTakeoverRevokeAndNewTask() async throws {
        let (stoppedManager, stoppedChannel, stoppedRoot) = try await makeCompletedManager(taskID: "memory-stop-task")
        defer { _ = stoppedManager.stop(); try? FileManager.default.removeItem(at: stoppedRoot) }
        XCTAssertEqual(stoppedManager.localMemoryLease(
            peerID: peerID, sessionID: sessionID, requiresTask: true)?.taskAuthority, .completed)
        let stopBarrier = stoppedManager.stop()
        await stopBarrier.value
        XCTAssertNil(stoppedManager.localMemoryLease(
            peerID: peerID, sessionID: sessionID, requiresTask: true))
        _ = stoppedChannel

        let (takenOverManager, takeoverChannel, takeoverRoot) = try await makeCompletedManager(taskID: "memory-takeover-task")
        defer { _ = takenOverManager.stop(); try? FileManager.default.removeItem(at: takeoverRoot) }
        XCTAssertEqual(takenOverManager.localMemoryLease(
            peerID: peerID, sessionID: sessionID, requiresTask: true)?.taskAuthority, .completed)
        takenOverManager.userIntervened()
        XCTAssertNil(takenOverManager.localMemoryLease(
            peerID: peerID, sessionID: sessionID, requiresTask: true))
        _ = takeoverChannel

        let (revokedManager, revokedChannel, revokedRoot) = try await makeCompletedManager(taskID: "memory-revoke-task")
        defer { _ = revokedManager.stop(); try? FileManager.default.removeItem(at: revokedRoot) }
        XCTAssertEqual(revokedManager.localMemoryLease(
            peerID: peerID, sessionID: sessionID, requiresTask: true)?.taskAuthority, .completed)
        revokedManager.revokeLocalPeerAuthorization(senderID: peerID)
        XCTAssertNil(revokedManager.localMemoryLease(
            peerID: peerID, sessionID: sessionID, requiresTask: true))
        _ = revokedChannel

        let (newTaskManager, newTaskChannel, newTaskRoot) = try await makeCompletedManager(taskID: "memory-old-task")
        defer { _ = newTaskManager.stop(); try? FileManager.default.removeItem(at: newTaskRoot) }
        let nextTaskID = "memory-new-task"
        let nextPrompt = ComputerUseEnvelope(
            id: nextTaskID,
            senderID: peerID,
            targetID: hostID,
            pairingCode: pairingCode,
            sessionID: sessionID,
            kind: .prompt,
            body: try ComputerUsePromptRequest(prompt: "Complete another test request").encodedBody())
        XCTAssertTrue(newTaskManager.handle(nextPrompt, channel: newTaskChannel))
        try await waitForCompletedTask(nextTaskID, channel: newTaskChannel)
        XCTAssertEqual(newTaskManager.localMemoryLease(
            peerID: peerID, sessionID: sessionID, requiresTask: true)?.taskID, nextTaskID)
        XCTAssertNotEqual(newTaskManager.localMemoryLease(
            peerID: peerID, sessionID: sessionID, requiresTask: true)?.taskID, "memory-old-task")
    }

    func testAcceptedNewTaskRebindsMemorySession() async throws {
        let nextSessionID = "memory-session-2"
        let (manager, channel, root) = try await makeCompletedManager(taskID: "memory-session-old-task")
        defer { _ = manager.stop(); try? FileManager.default.removeItem(at: root) }

        // Establish the old session binding through an authenticated memory
        // operation, then accept a host task from the same peer in a new session.
        XCTAssertNotNil(manager.localMemoryLease(
            peerID: peerID, sessionID: sessionID, requiresTask: false))
        let nextTaskID = "memory-session-new-task"
        let nextPrompt = ComputerUseEnvelope(
            id: nextTaskID,
            senderID: peerID,
            targetID: hostID,
            pairingCode: pairingCode,
            sessionID: nextSessionID,
            kind: .prompt,
            body: try ComputerUsePromptRequest(prompt: "Complete a task in the replacement session").encodedBody())
        XCTAssertTrue(manager.handle(nextPrompt, channel: channel))
        try await waitForCompletedTask(nextTaskID, channel: channel)

        XCTAssertEqual(manager.localMemoryLease(
            peerID: peerID, sessionID: nextSessionID, requiresTask: true)?.taskID, nextTaskID)
        XCTAssertNil(manager.localMemoryLease(
            peerID: peerID, sessionID: sessionID, requiresTask: false))
    }

    private func send(
        _ command: LocalMemoryRPCCommand,
        through server: LocalComputerUseBrokerServer
    ) async throws -> LocalMemoryRPCReply {
        let request = makeRequest(command)
        let response = try await server.handle(request)
        return try XCTUnwrap(response.memoryResult(for: request))
    }

    private func makeMemoryRoot(_ prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeCompletedManager(
        taskID: String,
        sessionID explicitSessionID: String? = nil
    ) async throws -> (HostComputerUseManager, MemoryLeaseTestChannel, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalMemoryManager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let channel = MemoryLeaseTestChannel(hostID: hostID, peerID: peerID, pairingCode: pairingCode)
        let manager = HostComputerUseManager(
            experimentalEnabled: { true },
            injector: InputInjector(),
            executor: FinishedMemoryLeaseExecutor(),
            taskLedger: ComputerUseTaskLedger(fileURL: root.appendingPathComponent("ledger.json")),
            allowsExternalServices: false,
            allowsAutomaticSetup: false)
        XCTAssertTrue(manager.authorizeLocalPeer(senderID: peerID))
        let prompt = ComputerUseEnvelope(
            id: taskID,
            senderID: peerID,
            targetID: hostID,
            pairingCode: pairingCode,
            sessionID: explicitSessionID ?? sessionID,
            kind: .prompt,
            body: try ComputerUsePromptRequest(prompt: "Complete a deterministic test task").encodedBody())
        XCTAssertTrue(manager.handle(prompt, channel: channel))
        try await waitForCompletedTask(taskID, channel: channel)
        return (manager, channel, root)
    }

    private func waitForCompletedTask(
        _ taskID: String,
        channel: MemoryLeaseTestChannel
    ) async throws {
        for _ in 0..<200 {
            let messages = await channel.messages()
            if messages.contains(where: { envelope in
                guard envelope.kind == .assistant,
                      let update = try? ComputerUseTaskUpdate.decodeBody(envelope.body) else { return false }
                return update.taskID == taskID && update.outcome == .taskCompleted
            }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the exact completed task")
    }

    private func makeRequest(_ command: LocalMemoryRPCCommand) -> LocalComputerUseRPCRequest {
        LocalComputerUseRPCRequest(
            senderID: peerID,
            targetID: hostID,
            sessionID: sessionID,
            memoryCommand: command)
    }

    private func makeServer(
        channel: LocalHostComputerUseChannel,
        enabled: Bool,
        coordinator: PersonalMemoryCoordinator
    ) -> LocalComputerUseBrokerServer {
        LocalComputerUseBrokerServer(
            credential: try! LocalComputerUseCredential(rawKey: Data(repeating: 0x5A, count: 32)),
            hostID: hostID,
            channel: channel,
            memoryFeatureEnabled: enabled,
            memoryHandler: { command, context in
                await coordinator.handle(command, context: context)
            },
            authorizePeer: { _ in true },
            revokePeer: { _ in })
    }
}

private struct TestMemoryKeyProvider: MemoryKeyProvider {
    let key: Data
    func loadKey() throws -> Data { key }
    func destroyKey() throws {}
}

@MainActor
private final class FinishedMemoryLeaseExecutor: ComputerUseExecuting {
    let isReady = true
    let runtimeName = "Memory lease test executor"

    func execute(
        prompt: String,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        .completed("Done")
    }
}

private actor MemoryLeaseTestChannel: HostComputerUseChannel {
    private let hostID: String
    private let peerID: String
    private let pairingCode: String
    private var sent: [ComputerUseEnvelope] = []

    init(hostID: String, peerID: String, pairingCode: String) {
        self.hostID = hostID
        self.peerID = peerID
        self.pairingCode = pairingCode
    }

    func messages() -> [ComputerUseEnvelope] { sent }

    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope {
        let envelope = ComputerUseEnvelope(
            id: explicitMessageID ?? UUID().uuidString,
            senderID: hostID,
            targetID: explicitTargetID ?? peerID,
            pairingCode: pairingCode,
            sessionID: explicitSessionID ?? "memory-session-1",
            kind: kind,
            body: body)
        sent.append(envelope)
        return envelope
    }

    func poll() async throws -> [ComputerUseEnvelope] { [] }
    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {}
}

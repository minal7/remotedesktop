import CryptoKit
import Foundation
import XCTest
import MemoryStoreKitTestSupport
@testable import MemoryStoreKit

private final class ApprovalRegistryKeychain: KeychainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ExactKeychainItem: Data] = [:]

    func add(_ item: ExactKeychainItem, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard items[item] == nil else { throw KeychainBoundaryError.duplicateItem }
        items[item] = data
    }
    func copy(_ item: ExactKeychainItem) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let data = items[item] else { throw KeychainBoundaryError.missingItem }
        return data
    }
    func delete(_ item: ExactKeychainItem) throws {
        lock.lock(); defer { lock.unlock() }
        guard items.removeValue(forKey: item) != nil else { throw KeychainBoundaryError.missingItem }
    }
    func replace(_ item: ExactKeychainItem, data: Data) throws {
        lock.lock(); defer { lock.unlock() }; items[item] = data
    }
}

private final class ApprovalRegistryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed: Bool
    private var incognito: Bool
    init(allowed: Bool = true, incognito: Bool = false) {
        self.allowed = allowed; self.incognito = incognito
    }
    var isAllowed: Bool { lock.lock(); defer { lock.unlock() }; return allowed }
    var isIncognito: Bool { lock.lock(); defer { lock.unlock() }; return incognito }
    func setAllowed(_ value: Bool) { lock.lock(); allowed = value; lock.unlock() }
    func setIncognito(_ value: Bool) { lock.lock(); incognito = value; lock.unlock() }
}

private struct ApprovalRegistryRandom: MemoryKeyRandomSource {
    func bytes(count: Int) throws -> Data { Data(repeating: 0x61, count: count) }
}

final class VaultApprovalKeyRegistryTests: XCTestCase {
    private let owner = "approval-registry-owner"
    private let session = "approval-registry-session"
    private let context = OwnerMemoryContext(ownerID: "approval-registry-owner",
                                            sessionID: "approval-registry-session")

    func testEnrollmentIsIdempotentAndDifferentKeyRequiresExplicitReplacement() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let first = P256.Signing.PrivateKey().publicKey.x963Representation
        let replacement = P256.Signing.PrivateKey().publicKey.x963Representation

        try f.service.enrollVaultApprovalKey(peerID: "paired-phone-1", publicKeyX963: first, context: context)
        XCTAssertEqual(try f.service.vaultApprovalKey(peerID: "paired-phone-1", context: context), first)
        XCTAssertNoThrow(try f.service.enrollVaultApprovalKey(peerID: "paired-phone-1",
            publicKeyX963: first, context: context))
        XCTAssertThrowsError(try f.service.enrollVaultApprovalKey(peerID: "paired-phone-1",
            publicKeyX963: replacement, context: context)) { error in
            XCTAssertEqual(error as? MemoryStoreError, .commandConflict)
        }
        XCTAssertEqual(try f.service.vaultApprovalKey(peerID: "paired-phone-1", context: context), first)
        XCTAssertNil(try f.service.vaultApprovalKey(peerID: "paired-phone-2", context: context))
    }

    func testMalformedPeerAndNonP256KeysAreRejectedBeforeRegistryWrites() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let key = P256.Signing.PrivateKey().publicKey.x963Representation
        for peer in ["", "bad\0peer", String(repeating: "x", count: 257)] {
            XCTAssertThrowsError(try f.service.enrollVaultApprovalKey(peerID: peer,
                publicKeyX963: key, context: context))
        }
        for keyBytes in [Data(), Data(repeating: 0x11, count: 64), Data(repeating: 0x11, count: 65)] {
            XCTAssertThrowsError(try f.service.enrollVaultApprovalKey(peerID: "paired-phone",
                publicKeyX963: keyBytes, context: context))
        }
        XCTAssertNil(try f.service.vaultApprovalKey(peerID: "paired-phone", context: context))
    }

    func testOwnerAuthorizationAndIncognitoPolicyGuardEnrollmentAndLookup() throws {
        let denied = try Fixture(gate: ApprovalRegistryGate(allowed: false))
        defer { denied.cleanup() }
        let key = P256.Signing.PrivateKey().publicKey.x963Representation
        XCTAssertThrowsError(try denied.service.enrollVaultApprovalKey(peerID: "phone",
            publicKeyX963: key, context: context))
        XCTAssertThrowsError(try denied.service.vaultApprovalKey(peerID: "phone", context: context))

        let gate = ApprovalRegistryGate()
        let f = try Fixture(gate: gate)
        defer { f.cleanup() }
        try f.service.enrollVaultApprovalKey(peerID: "phone", publicKeyX963: key, context: context)
        gate.setIncognito(true)
        XCTAssertThrowsError(try f.service.vaultApprovalKey(peerID: "phone", context: context))
        XCTAssertThrowsError(try f.service.enrollVaultApprovalKey(peerID: "phone",
            publicKeyX963: key, context: context))
        XCTAssertThrowsError(try f.service.vaultApprovalKey(peerID: "phone",
            context: OwnerMemoryContext(ownerID: "other-owner", sessionID: session)))
    }

    func testApprovalKeyIsExcludedFromMemoryRetrievalAndPreventsEmptyGenerationPublication() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.service.enrollVaultApprovalKey(peerID: "phone",
            publicKeyX963: P256.Signing.PrivateKey().publicKey.x963Representation, context: context)

        XCTAssertTrue(try f.service.writer.list(context: context).isEmpty)
        XCTAssertTrue(try f.service.writer.search("approval-registry", context: context).isEmpty)
        XCTAssertThrowsError(try f.service.isEmptyForGenerationPublication()) { error in
            XCTAssertEqual(error as? MemoryStoreError, .contentPresent)
        }
    }

    func testForgetRemovesEncryptedDatabaseAndApprovalKey() throws {
        let f = try Fixture()
        let key = P256.Signing.PrivateKey().publicKey.x963Representation
        try f.service.enrollVaultApprovalKey(peerID: "phone", publicKeyX963: key, context: context)
        let database = f.root.appendingPathComponent("memory.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
        try f.service.forgetAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        XCTAssertThrowsError(try f.service.vaultApprovalKey(peerID: "phone", context: context))
        f.cleanup()
    }

    func testApprovalKeySurvivesCloseAndReopenAndRemainsOutsideRetrieval() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let key = P256.Signing.PrivateKey().publicKey.x963Representation
        try f.service.enrollVaultApprovalKey(peerID: "phone", publicKeyX963: key, context: context)
        try f.service.close()

        let reopened = try f.reopen()
        XCTAssertEqual(try reopened.vaultApprovalKey(peerID: "phone", context: context), key)
        XCTAssertTrue(try reopened.writer.list(context: context).isEmpty)
        XCTAssertTrue(try reopened.writer.search("approval-registry", context: context).isEmpty)
    }

    func testPopulatedSchemaSixMigratesToSevenAndSupportsEnrollment() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultApprovalSchema6-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let database = root.appendingPathComponent("schema-six.sqlite")
        let fixtureKey = Data(repeating: 0x4a, count: 32)
        let fixtureStatus = database.path.withCString { path in
            fixtureKey.withUnsafeBytes { bytes in
                memory_test_create_legacy_database(path, bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count, 6, 0)
            }
        }
        XCTAssertEqual(fixtureStatus, 0)
        var priorVersion: Int32 = 0
        var priorLineage: Int32 = 0
        var priorDisplays: Int32 = 0
        var priorRecords: Int32 = 0
        let priorStatus = database.path.withCString { path in
            fixtureKey.withUnsafeBytes { bytes in
                memory_test_inspect_database(path, bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count, &priorVersion, &priorLineage, &priorDisplays, &priorRecords)
            }
        }
        XCTAssertEqual(priorStatus, 0)
        XCTAssertEqual(priorVersion, 6)
        XCTAssertEqual(priorRecords, 1)

        let store = try XCTUnwrap(MemoryStore.open(enabled: true, databaseURL: database,
            keyProvider: ApprovalRegistryStoreKey(fixtureKey)))
        XCTAssertEqual(try store.get(id: "legacy-row")?.body, "migration canary")
        let publicKey = P256.Signing.PrivateKey().publicKey.x963Representation
        try store.enrollVaultApprovalKey(ownerID: owner, peerID: "phone", publicKey: publicKey)
        XCTAssertEqual(try store.vaultApprovalKey(ownerID: owner, peerID: "phone"), publicKey)
        try store.close()

        var version: Int32 = 0
        var lineage: Int32 = 0
        var displays: Int32 = 0
        var records: Int32 = 0
        let inspectStatus = database.path.withCString { path in
            fixtureKey.withUnsafeBytes { bytes in
                memory_test_inspect_database(path, bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count, &version, &lineage, &displays, &records)
            }
        }
        XCTAssertEqual(inspectStatus, 0)
        XCTAssertEqual(version, 7)
        XCTAssertEqual(records, 1)
    }

    private final class Fixture {
        let root: URL
        var service: PersonalMemoryService
        private let client = ApprovalRegistryKeychain()
        private let gate: ApprovalRegistryGate
        private let namespace = KeychainNamespace.testing(UUID().uuidString)

        init(gate: ApprovalRegistryGate = ApprovalRegistryGate()) throws {
            self.gate = gate
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("VaultApprovalRegistry-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try MemoryStoreFactory.preparePrivateRoot(root)
            let client = self.client
            let expectedOwner = "approval-registry-owner"
            let expectedSession = "approval-registry-session"
            service = try XCTUnwrap(MemoryStoreFactory.openForTesting(enabled: true, root: root,
                client: client, random: ApprovalRegistryRandom(), namespace: namespace,
                authorize: { $0.ownerID == expectedOwner && $0.sessionID == expectedSession && gate.isAllowed },
                isTaskActive: { _, _ in true },
                policy: { OwnerMemoryPolicy(featureEnabled: true, incognito: gate.isIncognito) }))
        }

        func reopen() throws -> PersonalMemoryService {
            let gate = self.gate
            let expectedOwner = "approval-registry-owner"
            let expectedSession = "approval-registry-session"
            service = try XCTUnwrap(MemoryStoreFactory.openForTesting(enabled: true, root: root,
                client: client, random: ApprovalRegistryRandom(), namespace: namespace,
                authorize: { $0.ownerID == expectedOwner && $0.sessionID == expectedSession && gate.isAllowed },
                isTaskActive: { _, _ in true },
                policy: { OwnerMemoryPolicy(featureEnabled: true, incognito: gate.isIncognito) }))
            return service
        }

        func cleanup() {
            try? service.close()
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private struct ApprovalRegistryStoreKey: MemoryKeyProvider {
    let key: Data
    init(_ key: Data) { self.key = key }
    func loadKey() throws -> Data { key }
    func destroyKey() throws {}
}

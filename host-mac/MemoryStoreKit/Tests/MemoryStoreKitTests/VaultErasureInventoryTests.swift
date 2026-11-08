import Foundation
import XCTest
import MemoryStoreKitTestSupport
@testable import MemoryStoreKit

private final class InventoryTestKey: MemoryKeyProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data(repeating: 0x39, count: 32)
    func loadKey() throws -> Data { lock.lock(); defer { lock.unlock() }; return bytes }
    func destroyKey() throws { lock.lock(); bytes.resetBytes(in: 0..<bytes.count); lock.unlock() }
}

final class VaultErasureInventoryTests: XCTestCase {
    private func fixture() throws -> (URL, URL, InventoryTestKey) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultInventory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, root.appendingPathComponent("memory.sqlite"), InventoryTestKey())
    }

    private func store(_ url: URL, key: InventoryTestKey) throws -> MemoryStore {
        try XCTUnwrap(MemoryStore.open(enabled: true, databaseURL: url, keyProvider: key))
    }

    func testInventoryIsDurableCanonicalDeduplicatedAndBounded() throws {
        let (_, url, key) = try fixture()
        let first = try store(url, key: key)
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
        try first.registerVaultItem(id)
        try first.registerVaultItem(id)
        try first.beginVaultErasure()
        XCTAssertEqual(try first.vaultItemIDsForErasure(), [id])
        try first.close()

        let reopened = try store(url, key: key)
        XCTAssertTrue(try reopened.isVaultErasurePending())
        XCTAssertEqual(try reopened.vaultItemIDsForErasure(), [id])
        XCTAssertThrowsError(try reopened.registerVaultItem(UUID()))
    }

    func testInventoryCapAllowsDuplicateAtCapacityButRejectsNewIdentifier() throws {
        let (_, url, key) = try fixture()
        let memory = try store(url, key: key)
        var ids: [UUID] = []
        for _ in 0..<1024 {
            let id = UUID()
            ids.append(id)
            try memory.registerVaultItem(id)
        }
        try memory.registerVaultItem(ids[0])
        XCTAssertThrowsError(try memory.registerVaultItem(UUID()))
        try memory.beginVaultErasure()
        XCTAssertEqual(try memory.vaultItemIDsForErasure().count, 1024)
    }

    func testPendingFenceIsVisibleToAnotherConnectionAndBlocksNormalAccess() throws {
        let (_, url, key) = try fixture()
        let first = try store(url, key: key)
        let second = try store(url, key: key)
        try first.beginVaultErasure()
        XCTAssertTrue(try second.isVaultErasurePending())
        XCTAssertThrowsError(try second.requireActive()) { error in
            XCTAssertEqual(error as? MemoryStoreError, .erasurePending)
        }
    }

    func testInventoryCannotBeClearedBeforePendingAndKeepsTombstoneAfterCompletion() throws {
        let (_, url, key) = try fixture()
        let memory = try store(url, key: key)
        let id = UUID()
        try memory.registerVaultItem(id)
        XCTAssertThrowsError(try memory.completeVaultItemErasure())
        try memory.beginVaultErasure()
        XCTAssertThrowsError(try memory.forgetAll())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try memory.vaultItemIDsForErasure(), [id])

        // The service calls this only after its exact-ID Keychain deletes all succeed.
        try memory.completeVaultItemErasure()
        XCTAssertEqual(try memory.vaultItemIDsForErasure(), [])
        XCTAssertTrue(try memory.isVaultErasurePending(), "tombstone remains through DB key destruction")
    }

    func testLegacyVersionFourMigratesWithInactiveInventoryAndForgetState() throws {
        let (_, url, key) = try fixture()
        let fixtureKey = Data(repeating: 0x39, count: 32)
        let status = url.path.withCString { path in
            fixtureKey.withUnsafeBytes { bytes in
                memory_test_create_legacy_database(path,
                    bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, 4, 0)
            }
        }
        XCTAssertEqual(status, 0)
        let migrated = try store(url, key: key)
        try migrated.registerVaultItem(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!)
        try migrated.beginVaultErasure()
        try migrated.close()
        let reopened = try store(url, key: key)
        XCTAssertTrue(try reopened.isVaultErasurePending())
        XCTAssertEqual(try reopened.vaultItemIDsForErasure().count, 1)
    }

    func testLegacyVersionThreeMigratesThroughVersionsFourAndFive() throws {
        let (_, url, key) = try fixture()
        let rawKey = Data(repeating: 0x39, count: 32)
        let status = url.path.withCString { path in
            rawKey.withUnsafeBytes { bytes in
                memory_test_create_legacy_database(path,
                    bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, 3, 0)
            }
        }
        XCTAssertEqual(status, 0)
        let migrated = try store(url, key: key)
        XCTAssertEqual(try migrated.get(id: "legacy-row")?.body, "migration canary")
        XCTAssertFalse(try migrated.isVaultErasurePending())
        try migrated.close()
        let reopened = try store(url, key: key)
        try reopened.registerVaultItem(UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!)
        try reopened.beginVaultErasure()
        XCTAssertEqual(try reopened.vaultItemIDsForErasure().count, 1)
    }

    func testForgetAllRejectsRegisteredVaultIDsWithoutDestroyingDatabaseKey() throws {
        let (_, url, key) = try fixture()
        let memory = try store(url, key: key)
        try memory.registerVaultItem(UUID())
        try memory.beginVaultErasure()
        XCTAssertThrowsError(try memory.forgetAll())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try memory.isVaultErasurePending())
        XCTAssertThrowsError(try memory.requireActive())
    }

    func testMissingLifecycleTombstoneFailsClosedOnReopen() throws {
        let (_, url, key) = try fixture()
        let memory = try store(url, key: key)
        try memory.close()
        let rawKey = Data(repeating: 0x39, count: 32)
        let status = url.path.withCString { path in
            rawKey.withUnsafeBytes { bytes in
                memory_test_corrupt_vault_inventory(path,
                    bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, 1)
            }
        }
        XCTAssertEqual(status, 0)
        XCTAssertThrowsError(try MemoryStore.open(enabled: true, databaseURL: url, keyProvider: key))
    }

    func testMalformedPersistedInventoryFailsClosed() throws {
        let (_, url, key) = try fixture()
        let memory = try store(url, key: key)
        try memory.registerVaultItem(UUID())
        try memory.close()
        let rawKey = Data(repeating: 0x39, count: 32)
        let status = url.path.withCString { path in
            rawKey.withUnsafeBytes { bytes in
                memory_test_corrupt_vault_inventory(path,
                    bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, 2)
            }
        }
        XCTAssertEqual(status, 0)
        let reopened = try store(url, key: key)
        XCTAssertThrowsError(try reopened.vaultItemIDsForErasure())
    }
}

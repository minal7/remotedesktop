import Foundation
import Darwin
import XCTest
@testable import MemoryStoreKit

private final class FactoryKeychain: KeychainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ExactKeychainItem: Data] = [:]
    private(set) var adds = 0
    private(set) var copies = 0

    func add(_ item: ExactKeychainItem, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        adds += 1
        guard values[item] == nil else { throw KeychainBoundaryError.duplicateItem }
        values[item] = data
    }
    func copy(_ item: ExactKeychainItem) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        copies += 1
        guard let data = values[item] else { throw KeychainBoundaryError.missingItem }
        return data
    }
    func delete(_ item: ExactKeychainItem) throws {
        lock.lock(); defer { lock.unlock() }
        guard values.removeValue(forKey: item) != nil else { throw KeychainBoundaryError.missingItem }
    }
    func removeDatabaseKey(namespace: KeychainNamespace) {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: ExactKeychainItem(service: namespace.databaseKeyService,
            account: "database-key", protection: .deviceOnlyWhenUnlocked))
    }
}

private final class FactoryRandom: MemoryKeyRandomSource, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    func bytes(count: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return Data(repeating: 0x5a, count: count)
    }
}

final class MemoryStoreFactoryTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("MemoryStoreFactory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base.appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
    }

    private func open(_ root: URL, client: FactoryKeychain, random: FactoryRandom,
                      namespace: KeychainNamespace) throws -> PersonalMemoryService? {
        try MemoryStoreFactory.openForTesting(enabled: true, root: root, client: client,
            random: random, namespace: namespace, authorize: { _ in true },
            isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: true) })
    }

    func testDisabledReturnsBeforeDirectoryOrKeyAccess() throws {
        let missing = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("disabled-\(UUID().uuidString)", isDirectory: true)
        let client = FactoryKeychain()
        let random = FactoryRandom()
        let result = try MemoryStoreFactory.openForTesting(enabled: false, root: missing,
            client: client, random: random, namespace: .testing("disabled"),
            authorize: { _ in true }, isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: false) })
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(client.adds, 0)
        XCTAssertEqual(client.copies, 0)
        XCTAssertEqual(random.calls, 0)
    }

    func testNewStoreCreatesPrivateDatabaseAndReopenLoadsExistingKey() throws {
        let root = try temporaryRoot()
        let client = FactoryKeychain()
        let random = FactoryRandom()
        let namespace = KeychainNamespace.testing("factory-create")
        let first = try XCTUnwrap(open(root, client: client, random: random, namespace: namespace))
        try first.close()
        let database = root.appendingPathComponent("memory.sqlite")
        var info = stat()
        XCTAssertEqual(database.path.withCString { lstat($0, &info) }, 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(client.adds, 1)
        let second = try XCTUnwrap(open(root, client: client, random: random, namespace: namespace))
        try second.close()
        XCTAssertEqual(client.adds, 1)
        XCTAssertEqual(random.calls, 1)
        XCTAssertGreaterThanOrEqual(client.copies, 1)
    }

    func testExistingDatabaseWithMissingKeyFailsWithoutReplacement() throws {
        let root = try temporaryRoot()
        let client = FactoryKeychain()
        let random = FactoryRandom()
        let namespace = KeychainNamespace.testing("factory-missing-key")
        let first = try XCTUnwrap(open(root, client: client, random: random, namespace: namespace))
        try first.close()
        client.removeDatabaseKey(namespace: namespace)
        XCTAssertThrowsError(try open(root, client: client, random: random, namespace: namespace))
        XCTAssertEqual(client.adds, 1)
        XCTAssertEqual(random.calls, 1)
    }

    func testDanglingDatabaseSymlinkFailsBeforeKeyCreation() throws {
        let root = try temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let link = root.appendingPathComponent("memory.sqlite")
        XCTAssertEqual(symlink("/definitely/missing/memory.sqlite", link.path), 0)
        let client = FactoryKeychain()
        let random = FactoryRandom()
        XCTAssertThrowsError(try open(root, client: client, random: random,
                                      namespace: .testing("factory-link")))
        XCTAssertEqual(client.adds, 0)
        XCTAssertEqual(random.calls, 0)
    }

    func testSidecarWithoutDatabaseFailsBeforeKeyCreation() throws {
        let root = try temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data("not a database".utf8).write(to: root.appendingPathComponent("memory.sqlite-wal"))
        chmod(root.appendingPathComponent("memory.sqlite-wal").path, 0o600)
        let client = FactoryKeychain()
        let random = FactoryRandom()
        XCTAssertThrowsError(try open(root, client: client, random: random,
                                      namespace: .testing("factory-sidecar")))
        XCTAssertEqual(client.adds, 0)
        XCTAssertEqual(random.calls, 0)
    }

    func testConcurrentFirstOpenCreatesExactlyOneDatabaseKey() throws {
        let root = try temporaryRoot()
        let client = FactoryKeychain()
        let random = FactoryRandom()
        let namespace = KeychainNamespace.testing("factory-concurrent")
        let lock = NSLock()
        var services: [PersonalMemoryService] = []
        var failures: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do {
                guard let service = try open(root, client: client, random: random,
                                             namespace: namespace) else {
                    throw MemoryFactoryError.storageUnavailable
                }
                lock.lock(); services.append(service); lock.unlock()
            } catch {
                lock.lock(); failures.append(error); lock.unlock()
            }
        }
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(services.count, 8)
        XCTAssertEqual(client.adds, 1)
        XCTAssertEqual(random.calls, 1)
        for service in services { try service.close() }
    }

    func testHardLinkedDatabaseFailsBeforeKeyAccessAndPreservesTarget() throws {
        let root = try temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let target = root.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("sentinel.db")
        let original = Data("linked database sentinel".utf8)
        try original.write(to: target)
        chmod(target.path, 0o600)
        let database = root.appendingPathComponent("memory.sqlite")
        XCTAssertEqual(link(target.path, database.path), 0)

        let client = FactoryKeychain()
        let random = FactoryRandom()
        XCTAssertThrowsError(try open(root, client: client, random: random,
                                      namespace: .testing("factory-hardlink-db")))
        XCTAssertEqual(client.adds, 0)
        XCTAssertEqual(client.copies, 0)
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testHardLinkedWALFailsBeforeKeyAccessAndPreservesTarget() throws {
        let root = try temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let target = root.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("sentinel.wal")
        let original = Data("linked WAL sentinel".utf8)
        try original.write(to: target)
        chmod(target.path, 0o600)
        let wal = URL(fileURLWithPath: root.appendingPathComponent("memory.sqlite").path + "-wal")
        XCTAssertEqual(link(target.path, wal.path), 0)

        let client = FactoryKeychain()
        let random = FactoryRandom()
        XCTAssertThrowsError(try open(root, client: client, random: random,
                                      namespace: .testing("factory-hardlink-wal")))
        XCTAssertEqual(client.adds, 0)
        XCTAssertEqual(client.copies, 0)
        XCTAssertEqual(try Data(contentsOf: target), original)
    }
}

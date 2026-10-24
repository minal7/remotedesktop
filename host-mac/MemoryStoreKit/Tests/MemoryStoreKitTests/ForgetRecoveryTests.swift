import Darwin
import Foundation
import XCTest
@testable import MemoryStoreKit

private final class RecoveryFakeKeychain: KeychainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ExactKeychainItem: Data] = [:]
    private var failures: [ExactKeychainItem: Int] = [:]
    private var copyFailures: [ExactKeychainItem: Int] = [:]
    private var eventLog: [String] = []

    func add(_ item: ExactKeychainItem, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard items[item] == nil else { throw KeychainBoundaryError.duplicateItem }
        items[item] = data
        eventLog.append("add:\(category(item))")
    }

    func copy(_ item: ExactKeychainItem) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let count = copyFailures[item], count > 0 {
            copyFailures[item] = count - 1
            throw KeychainBoundaryError.accessDenied
        }
        guard let data = items[item] else { throw KeychainBoundaryError.missingItem }
        return data
    }

    func delete(_ item: ExactKeychainItem) throws {
        lock.lock(); defer { lock.unlock() }
        eventLog.append("delete:\(category(item))")
        if let count = failures[item], count > 0 {
            failures[item] = count - 1
            throw KeychainBoundaryError.accessDenied
        }
        guard items.removeValue(forKey: item) != nil else { throw KeychainBoundaryError.missingItem }
    }

    func contains(_ item: ExactKeychainItem) -> Bool {
        lock.lock(); defer { lock.unlock() }; return items[item] != nil
    }

    func removeForTest(_ item: ExactKeychainItem) {
        lock.lock(); items.removeValue(forKey: item); lock.unlock()
    }

    func replaceForTest(_ item: ExactKeychainItem, data: Data) {
        lock.lock(); items[item] = data; lock.unlock()
    }

    func failNextDelete(_ item: ExactKeychainItem) {
        lock.lock(); failures[item, default: 0] += 1; lock.unlock()
    }

    func failNextCopy(_ item: ExactKeychainItem) {
        lock.lock(); copyFailures[item, default: 0] += 1; lock.unlock()
    }

    func events() -> [String] { lock.lock(); defer { lock.unlock() }; return eventLog }

    private func category(_ item: ExactKeychainItem) -> String {
        if item.account == "database-key" { return "database-key" }
        if item.account == ForgetRecoveryJournal.account { return "recovery-marker" }
        return "managed-vault-item"
    }
}

private struct RecoveryRandom: MemoryKeyRandomSource {
    func bytes(count: Int) throws -> Data { Data(repeating: 0x73, count: count) }
}

private enum RecoveryInjectedError: Error { case stop }

private final class RecoveryFileOperationsFake: ForgetRecoveryFileOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var removeCount = 0
    private let failBeforeRemoval: Int?
    private let failAfterRemoval: Int?

    init(failBeforeRemoval: Int? = nil, failAfterRemoval: Int? = nil) {
        self.failBeforeRemoval = failBeforeRemoval
        self.failAfterRemoval = failAfterRemoval
    }

    func removeItem(at url: URL) throws {
        lock.lock(); removeCount += 1; let count = removeCount; lock.unlock()
        if count == failBeforeRemoval { throw RecoveryInjectedError.stop }
        try FileManager.default.removeItem(at: url)
        if count == failAfterRemoval { throw RecoveryInjectedError.stop }
    }
}

private struct RecoveryNoOpFileOperations: ForgetRecoveryFileOperations {
    func removeItem(at url: URL) throws { }
}

final class ForgetRecoveryTests: XCTestCase {
    private struct Fixture {
        let parent: URL
        let root: URL
        let client: RecoveryFakeKeychain
        let namespace: KeychainNamespace
        let service: PersonalMemoryService
    }

    private func fixture(_ suffix: String) throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgetRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        let client = RecoveryFakeKeychain()
        let namespace = KeychainNamespace.testing("forget-recovery-\(suffix)-\(UUID().uuidString)")
        let service = try open(root: root, client: client, namespace: namespace)
        return Fixture(parent: parent, root: root, client: client,
                       namespace: namespace, service: service)
    }

    private func open(root: URL, client: RecoveryFakeKeychain,
                      namespace: KeychainNamespace) throws -> PersonalMemoryService {
        let service = try MemoryStoreFactory.openForTesting(enabled: true, root: root,
            client: client, random: RecoveryRandom(), namespace: namespace,
            authorize: { _ in true }, isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: true) })
        return try XCTUnwrap(service)
    }

    private func databaseKey(_ namespace: KeychainNamespace) -> ExactKeychainItem {
        ExactKeychainItem(service: namespace.databaseKeyService, account: "database-key",
                          protection: .deviceOnlyWhenUnlocked)
    }

    private func marker(_ fixture: Fixture) -> ExactKeychainItem {
        ForgetRecoveryJournal.item(namespace: fixture.namespace)
    }

    private func seedMarker(root: URL, client: RecoveryFakeKeychain,
                            namespace: KeychainNamespace) throws {
        try client.add(ForgetRecoveryJournal.item(namespace: namespace),
            data: ForgetRecoveryJournal.payload(root: root, namespace: namespace))
    }

    private func database(_ root: URL) -> URL { root.appendingPathComponent("memory.sqlite") }

    private func sidecars(_ root: URL) -> [URL] {
        ["-wal", "-shm", "-journal"].map { URL(fileURLWithPath: database(root).path + $0) }
    }

    private func createAllCleanupFiles(_ root: URL) throws {
        for file in sidecars(root) {
            try Data([0x31, 0x32]).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    private func assertCleanupFilesAbsent(_ root: URL, file: StaticString = #filePath,
                                          line: UInt = #line) {
        XCTAssertFalse(FileManager.default.fileExists(atPath: database(root).path), file: file, line: line)
        for fileURL in sidecars(root) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), file: file, line: line)
        }
    }

    func testDisabledInjectedRecoveryDoesNotQueryKeychain() throws {
        let value = try fixture("disabled-recovery")
        let eventsBeforeRecovery = value.client.events()
        value.client.failNextCopy(marker(value))

        XCTAssertFalse(try MemoryStoreFactory.recoverForgetForTesting(enabled: false,
            root: value.root, client: value.client, namespace: value.namespace))
        XCTAssertEqual(value.client.events(), eventsBeforeRecovery)
    }

    func testNoMarkerRecoveryDoesNotCreateLifecycleLockOrBlockInitialOpen() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgetRecovery-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let client = RecoveryFakeKeychain()
        let namespace = KeychainNamespace.testing("empty-root-\(UUID().uuidString)")
        let lock = root.appendingPathComponent(".vault-lifecycle.lock")

        XCTAssertFalse(try MemoryStoreFactory.recoverForgetForTesting(enabled: true,
            root: root, client: client, namespace: namespace))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
        let service = try XCTUnwrap(open(root: root, client: client, namespace: namespace))
        try service.close()
    }

    func testMarkerAccessDeniedPropagatesWithoutFallbackOrDeletion() throws {
        let value = try fixture("marker-denied")
        try value.service.close()
        try seedMarker(root: value.root, client: value.client, namespace: value.namespace)
        try createAllCleanupFiles(value.root)
        value.client.failNextCopy(marker(value))

        XCTAssertThrowsError(try MemoryStoreFactory.recoverForgetForTesting(enabled: true,
            root: value.root, client: value.client, namespace: value.namespace)) {
            XCTAssertEqual($0 as? KeychainBoundaryError, .accessDenied)
        }
        XCTAssertTrue(value.client.contains(databaseKey(value.namespace)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database(value.root).path))
        XCTAssertTrue(value.client.contains(marker(value)))
    }

    func testDatabaseKeyDeleteFailureLeavesFilesAndRecoveryMarker() throws {
        let value = try fixture("key-delete-denied")
        try value.service.close()
        try seedMarker(root: value.root, client: value.client, namespace: value.namespace)
        try createAllCleanupFiles(value.root)
        value.client.failNextDelete(databaseKey(value.namespace))

        XCTAssertThrowsError(try MemoryStoreFactory.recoverForgetForTesting(enabled: true,
            root: value.root, client: value.client, namespace: value.namespace))
        XCTAssertTrue(value.client.contains(databaseKey(value.namespace)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database(value.root).path))
        XCTAssertTrue(value.client.contains(marker(value)))
    }

    func testNoOpUnlinkCannotReportRecoveryComplete() throws {
        let value = try fixture("noop-unlink")
        try value.service.close()
        try seedMarker(root: value.root, client: value.client, namespace: value.namespace)
        try createAllCleanupFiles(value.root)

        XCTAssertThrowsError(try MemoryStoreFactory.recoverForgetForTesting(enabled: true,
            root: value.root, client: value.client, namespace: value.namespace,
            fileOperations: RecoveryNoOpFileOperations()))
        XCTAssertFalse(value.client.contains(databaseKey(value.namespace)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database(value.root).path))
        XCTAssertTrue(value.client.contains(marker(value)))
    }

    func testMissingKeyWithoutMarkerNeverAuthorizesCleanupOrKeyRecreation() throws {
        let value = try fixture("missing-key")
        try value.service.close()
        value.client.removeForTest(databaseKey(value.namespace))
        let databaseURL = database(value.root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))

        XCTAssertFalse(try MemoryStoreFactory.recoverForgetForTesting(enabled: true,
            root: value.root, client: value.client, namespace: value.namespace))

        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertFalse(value.client.contains(databaseKey(value.namespace)))
        XCTAssertThrowsError(try open(root: value.root, client: value.client, namespace: value.namespace))
        XCTAssertFalse(value.client.contains(marker(value)))
    }

    func testValidMarkerWithDatabaseKeyCompletesCleanupAndRemainsAsTombstone() throws {
        let value = try fixture("key-present")
        try value.service.close()
        try seedMarker(root: value.root, client: value.client, namespace: value.namespace)
        try createAllCleanupFiles(value.root)

        XCTAssertTrue(try MemoryStoreFactory.recoverForgetForTesting(enabled: true,
            root: value.root, client: value.client, namespace: value.namespace))

        XCTAssertFalse(value.client.contains(databaseKey(value.namespace)))
        assertCleanupFilesAbsent(value.root)
        XCTAssertTrue(value.client.contains(marker(value)), "the immutable marker stays as the completion tombstone")
        XCTAssertThrowsError(try open(root: value.root, client: value.client, namespace: value.namespace)) {
            XCTAssertEqual($0 as? MemoryFactoryError, .forgetRecoveryRequired)
        }
    }

    func testValidMarkerWithAlreadyMissingDatabaseKeyStillCompletesCleanup() throws {
        let value = try fixture("key-missing")
        try value.service.close()
        try seedMarker(root: value.root, client: value.client, namespace: value.namespace)
        try createAllCleanupFiles(value.root)
        value.client.removeForTest(databaseKey(value.namespace))

        XCTAssertTrue(try MemoryStoreFactory.recoverForgetForTesting(enabled: true,
            root: value.root, client: value.client, namespace: value.namespace))

        assertCleanupFilesAbsent(value.root)
        XCTAssertTrue(value.client.contains(marker(value)))
        XCTAssertFalse(value.client.contains(databaseKey(value.namespace)))
    }

    func testRetryAfterAllUnlinksButBeforeReplyIsIdempotent() throws {
        let value = try fixture("unlink-before-reply")
        try value.service.close()
        try seedMarker(root: value.root, client: value.client, namespace: value.namespace)
        try createAllCleanupFiles(value.root)

        XCTAssertThrowsError(try MemoryStoreFactory.recoverForgetForTesting(enabled: true,
            root: value.root, client: value.client, namespace: value.namespace,
            fileOperations: RecoveryFileOperationsFake(failAfterRemoval: 4)))
        assertCleanupFilesAbsent(value.root)
        XCTAssertTrue(value.client.contains(marker(value)))

        XCTAssertTrue(try MemoryStoreFactory.recoverForgetForTesting(enabled: true,
            root: value.root, client: value.client, namespace: value.namespace))
        XCTAssertTrue(value.client.contains(marker(value)))
    }

    func testInterruptedFileCleanupCanResumeWithMarkerAndMissingKey() throws {
        let value = try fixture("partial-unlink")
        try value.service.close()
        try seedMarker(root: value.root, client: value.client, namespace: value.namespace)
        try createAllCleanupFiles(value.root)

        XCTAssertThrowsError(try MemoryStoreFactory.recoverForgetForTesting(enabled: true,
            root: value.root, client: value.client, namespace: value.namespace,
            fileOperations: RecoveryFileOperationsFake(failBeforeRemoval: 2)))
        XCTAssertFalse(value.client.contains(databaseKey(value.namespace)),
            "the exact DB key is removed before any database file is unlinked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: database(value.root).path))
        XCTAssertTrue(value.client.contains(marker(value)))

        XCTAssertTrue(try MemoryStoreFactory.recoverForgetForTesting(enabled: true,
            root: value.root, client: value.client, namespace: value.namespace))
        assertCleanupFilesAbsent(value.root)
        XCTAssertTrue(value.client.contains(marker(value)))
    }

    func testMalformedMarkerRefusesBeforeKeyOrFileDeletion() throws {
        let value = try fixture("bad-marker")
        try value.service.close()
        try seedMarker(root: value.root, client: value.client, namespace: value.namespace)
        let markerItem = marker(value)
        value.client.replaceForTest(markerItem, data: Data("tampered".utf8))
        let dbURL = database(value.root)

        XCTAssertThrowsError(try MemoryStoreFactory.recoverForgetForTesting(enabled: true,
            root: value.root, client: value.client, namespace: value.namespace)) {
            XCTAssertEqual($0 as? MemoryFactoryError, .unsafeForgetJournal)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
        XCTAssertTrue(value.client.contains(databaseKey(value.namespace)))
        XCTAssertTrue(value.client.contains(markerItem))
    }

    func testMarkerBoundToDifferentRootRefusesBeforeDeletion() throws {
        let source = try fixture("source-root")
        try source.service.close()
        let destination = try fixture("other-root")
        try destination.service.close()
        let sourcePayload = try ForgetRecoveryJournal.payload(root: source.root, namespace: source.namespace)
        destination.client.replaceForTest(ForgetRecoveryJournal.item(namespace: destination.namespace),
                                          data: sourcePayload)
        let destinationDB = database(destination.root)

        XCTAssertThrowsError(try MemoryStoreFactory.recoverForgetForTesting(enabled: true,
            root: destination.root, client: destination.client, namespace: destination.namespace)) {
            XCTAssertEqual($0 as? MemoryFactoryError, .unsafeForgetJournal)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationDB.path))
        XCTAssertTrue(destination.client.contains(databaseKey(destination.namespace)))
    }

    func testSymlinkDatabaseUnderValidMarkerRefusesAndPreservesTarget() throws {
        let value = try fixture("symlink-db")
        try value.service.close()
        let databaseURL = database(value.root)
        try FileManager.default.removeItem(at: databaseURL)
        let sentinel = value.parent.appendingPathComponent("outside-sentinel")
        let expected = Data("fixture sentinel".utf8)
        try expected.write(to: sentinel)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sentinel.path)
        XCTAssertEqual(symlink(sentinel.path, databaseURL.path), 0)
        try seedMarker(root: value.root, client: value.client, namespace: value.namespace)

        XCTAssertThrowsError(try MemoryStoreFactory.recoverForgetForTesting(enabled: true,
            root: value.root, client: value.client, namespace: value.namespace))

        XCTAssertEqual(try Data(contentsOf: sentinel), expected)
        XCTAssertTrue(value.client.contains(databaseKey(value.namespace)))
    }

    func testHardLinkedSidecarUnderValidMarkerRefusesAndPreservesTarget() throws {
        let value = try fixture("hardlink-sidecar")
        try value.service.close()
        let target = value.parent.appendingPathComponent("outside-wal-sentinel")
        let expected = Data("wal sentinel".utf8)
        try expected.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let wal = sidecars(value.root)[0]
        XCTAssertEqual(link(target.path, wal.path), 0)
        try seedMarker(root: value.root, client: value.client, namespace: value.namespace)

        XCTAssertThrowsError(try MemoryStoreFactory.recoverForgetForTesting(enabled: true,
            root: value.root, client: value.client, namespace: value.namespace))

        XCTAssertEqual(try Data(contentsOf: target), expected)
        XCTAssertTrue(value.client.contains(databaseKey(value.namespace)))
    }

    func testVaultDeletionFailureDoesNotWriteMarkerOrDestroyDatabaseKey() throws {
        let value = try fixture("vault-delete-failure")
        let itemID = VaultItemID()
        let vaultItem = ExactKeychainItem(service: value.namespace.vaultService,
            account: itemID.account(for: .cardNumber), protection: .userPresenceWhenUnlocked)
        try value.service.storeVaultSecret(try VaultSecretValue("4242424242424242"),
            for: itemID, field: .cardNumber)
        value.client.failNextDelete(vaultItem)

        XCTAssertThrowsError(try value.service.forgetAll())

        XCTAssertFalse(value.client.contains(marker(value)))
        XCTAssertTrue(value.client.contains(databaseKey(value.namespace)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database(value.root).path))
    }

    func testForgetPersistsMarkerBeforeKeyDeletionAndPreservesOtherNamespace() throws {
        let value = try fixture("ordering")
        let itemID = VaultItemID()
        let managedItem = ExactKeychainItem(service: value.namespace.vaultService,
            account: itemID.account(for: .cardNumber), protection: .userPresenceWhenUnlocked)
        let otherNamespace = KeychainNamespace.testing("unrelated-\(UUID().uuidString)")
        let unrelated = ExactKeychainItem(service: otherNamespace.vaultService,
            account: "fixture-unrelated", protection: .userPresenceWhenUnlocked)
        try value.client.add(unrelated, data: Data([0x41]))
        try value.service.storeVaultSecret(try VaultSecretValue("4242424242424242"),
            for: itemID, field: .cardNumber)

        try value.service.forgetAll()

        let events = value.client.events()
        let markerAdded = try XCTUnwrap(events.firstIndex(of: "add:recovery-marker"))
        let keyDeleted = try XCTUnwrap(events.firstIndex(of: "delete:database-key"))
        XCTAssertLessThan(markerAdded, keyDeleted)
        XCTAssertFalse(value.client.contains(managedItem))
        XCTAssertTrue(value.client.contains(unrelated))
        XCTAssertTrue(value.client.contains(marker(value)), "successful Forget keeps its tombstone")
        XCTAssertThrowsError(try open(root: value.root, client: value.client, namespace: value.namespace)) {
            XCTAssertEqual($0 as? MemoryFactoryError, .forgetRecoveryRequired)
        }
    }
}

import Foundation
import XCTest
import MemoryStoreKitTestSupport
@testable import MemoryStoreKit

private final class TestKeyProvider: MemoryKeyProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data
    private var destroyFailuresRemaining: Int
    private(set) var loads = 0
    private(set) var destroys = 0

    init(_ key: Data = Data(repeating: 0x4a, count: 32), failFirstDestroy: Bool = false) {
        self.key = key
        self.destroyFailuresRemaining = failFirstDestroy ? 1 : 0
    }

    func loadKey() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        loads += 1
        return key
    }

    func destroyKey() throws {
        lock.lock(); defer { lock.unlock() }
        destroys += 1
        if destroyFailuresRemaining > 0 {
            destroyFailuresRemaining -= 1
            throw TestProviderError.injectedDestroyFailure
        }
        key.resetBytes(in: 0..<key.count)
    }
}

private enum TestProviderError: Error { case injectedDestroyFailure }

final class MemoryStoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryStoreKit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testFeatureOffDoesNotAskForKey() throws {
        let directory = try temporaryDirectory()
        let provider = TestKeyProvider()
        XCTAssertNil(try MemoryStore.open(enabled: false,
            databaseURL: directory.appendingPathComponent("memory.db"), keyProvider: provider))
        XCTAssertEqual(provider.loads, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("memory.db").path))
    }

    func testEncryptedFTSSearchCanaryAndReopen() throws {
        let directory = try temporaryDirectory()
        let database = directory.appendingPathComponent("memory.db")
        let provider = TestKeyProvider()
        let canary = "private-canary-\(UUID().uuidString)"
        let first = try XCTUnwrap(MemoryStore.open(enabled: true, databaseURL: database, keyProvider: provider))
        try first.upsert(MemoryRecord(id: "fact-1", kind: .fact, body: canary,
            source: .ownerMessage, observedAt: 123, confidence: 0.37,
            provenance: MemoryProvenance(sourceMessageID: "msg-9", statementID: "stmt-2")))
        try first.upsert(MemoryRecord(id: "order-1", kind: .episode,
            body: "The order-number \"Q4\" is waiting.", source: .ownerConfirmed, observedAt: 124))
        let privateMatch = try XCTUnwrap(first.search("private").first)
        XCTAssertEqual(privateMatch.record.body, canary)
        XCTAssertEqual(privateMatch.record.confidence, 0.37, accuracy: 0.0001)
        XCTAssertEqual(try first.search("order-number \"Q4\"").first?.record.id, "order-1")
        XCTAssertThrowsError(try first.search("private\0canary")) { error in
            XCTAssertEqual(error as? MemoryStoreError, .invalidQuery)
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)
        let names = Set(files.map(\.lastPathComponent))
        XCTAssertTrue(names.contains("memory.db"))
        XCTAssertTrue(names.contains("memory.db-wal"))
        XCTAssertTrue(names.contains("memory.db-shm"))
        XCTAssertTrue(names.isSubset(of: Set(["memory.db", "memory.db-wal", "memory.db-shm"])),
            "unexpected colocated SQLite temporary file")
        for file in files {
            let bytes = try Data(contentsOf: file)
            XCTAssertNil(bytes.range(of: Data(canary.utf8)), "plaintext canary in \(file.lastPathComponent)")
        }
        try first.close()

        let reopened = try XCTUnwrap(MemoryStore.open(enabled: true, databaseURL: database, keyProvider: provider))
        let reopenedPrivate = try XCTUnwrap(reopened.search("private").first)
        XCTAssertEqual(reopenedPrivate.record.id, "fact-1")
        XCTAssertEqual(reopenedPrivate.record.confidence, 0.37, accuracy: 0.0001)
        XCTAssertEqual(reopenedPrivate.record.provenance,
            MemoryProvenance(sourceMessageID: "msg-9", statementID: "stmt-2"))
        XCTAssertEqual(try reopened.get(id: "fact-1"), reopenedPrivate.record)
        XCTAssertEqual(try reopened.list().map(\.id), ["order-1", "fact-1"])
        try reopened.upsert(MemoryRecord(id: "fact-1", kind: .fact, body: "Updated private fact",
            source: .ownerConfirmed, observedAt: 125, active: false, confidence: 0.8,
            provenance: MemoryProvenance(proposalID: "proposal-3", statementID: "stmt-3")))
        XCTAssertNil(try reopened.get(id: "missing"))
        XCTAssertTrue(try reopened.search("Updated").isEmpty)
        XCTAssertEqual(try reopened.list(includeInactive: false).map(\.id), ["order-1"])
        XCTAssertEqual(try reopened.list().first(where: { $0.id == "fact-1" })?.provenance,
            MemoryProvenance(proposalID: "proposal-3", statementID: "stmt-3"))
        try reopened.setActive(true, id: "fact-1")
        XCTAssertEqual(try reopened.get(id: "fact-1")?.body, "Updated private fact")
        try reopened.forget(id: "fact-1")
        XCTAssertTrue(try reopened.search("Updated").isEmpty)
        try reopened.close()
    }

    func testWrongKeyFailsClosed() throws {
        let directory = try temporaryDirectory()
        let database = directory.appendingPathComponent("memory.db")
        let ownerKey = TestKeyProvider()
        let store = try XCTUnwrap(MemoryStore.open(enabled: true, databaseURL: database, keyProvider: ownerKey))
        try store.upsert(MemoryRecord(id: "one", kind: .profile, body: "owner fact",
            source: .ownerConfirmed, observedAt: 1))
        try store.close()

        let wrongKey = TestKeyProvider(Data(repeating: 0x13, count: 32))
        do {
            _ = try MemoryStore.open(enabled: true, databaseURL: database, keyProvider: wrongKey)
            XCTFail("wrong key unexpectedly opened the database")
        } catch let error as MemoryStoreError {
            XCTAssertEqual(error, .authenticationFailed)
        }
    }

    func testVaultDisplayHasNoSecretValueAndForgetAllDestroysKey() throws {
        let directory = try temporaryDirectory()
        let database = directory.appendingPathComponent("memory.db")
        let provider = TestKeyProvider()
        let store = try XCTUnwrap(MemoryStore.open(enabled: true, databaseURL: database, keyProvider: provider))
        let display = VaultHandleDisplay.labeled(label: .workAddress)
        try store.upsertVaultDisplay(display)
        try store.forgetAll()
        XCTAssertEqual(provider.destroys, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + "-shm"))
    }

    func testAllCStringInputsRejectEmbeddedNUL() throws {
        let directory = try temporaryDirectory()
        let database = directory.appendingPathComponent("memory.db")
        let store = try XCTUnwrap(MemoryStore.open(enabled: true, databaseURL: database,
            keyProvider: TestKeyProvider()))
        XCTAssertThrowsError(try store.upsert(MemoryRecord(id: "bad\0id", kind: .fact,
            body: "body", source: .ownerMessage, observedAt: 1))) { error in
            XCTAssertEqual(error as? MemoryStoreError, .invalidInput)
        }
        XCTAssertThrowsError(try store.upsert(MemoryRecord(id: "good-id", kind: .fact,
            body: "bad\0body", source: .ownerMessage, observedAt: 1))) { error in
            XCTAssertEqual(error as? MemoryStoreError, .invalidInput)
        }
        XCTAssertThrowsError(try store.forget(id: "bad\0id")) { error in
            XCTAssertEqual(error as? MemoryStoreError, .invalidInput)
        }
        try store.close()
    }

    func testForgetAllRetriesAfterKeyProviderFailure() throws {
        let directory = try temporaryDirectory()
        let database = directory.appendingPathComponent("memory.db")
        let provider = TestKeyProvider(failFirstDestroy: true)
        let store = try XCTUnwrap(MemoryStore.open(enabled: true, databaseURL: database, keyProvider: provider))
        try store.upsert(MemoryRecord(id: "retry", kind: .fact, body: "retryable erase",
            source: .ownerConfirmed, observedAt: 1))
        XCTAssertThrowsError(try store.forgetAll()) { error in
            XCTAssertTrue(error is TestProviderError)
        }
        XCTAssertThrowsError(try store.search("retryable")) { error in
            XCTAssertEqual(error as? MemoryStoreError, .erasurePending)
        }
        try store.forgetAll()
        XCTAssertEqual(provider.destroys, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
    }

    func testAllowedSourceLabelsAreLimitedButDoNotImplyAuthority() {
        XCTAssertEqual(Set(MemorySource.allCases.map(\.rawValue)), Set(["owner_message", "owner_confirmed"]))
    }

    func testSafeVaultDisplaysRejectMalformedCardMetadataAndDoNotAcceptFreeformStrings() throws {
        XCTAssertThrowsError(try VaultHandleDisplay.card(brand: .visa, last4: "12345",
            expirationMonth: 1, expirationYear: 2030))
        XCTAssertThrowsError(try VaultHandleDisplay.card(brand: .visa, last4: "12\0x",
            expirationMonth: 1, expirationYear: 2030))
        XCTAssertThrowsError(try VaultHandleDisplay.card(brand: .visa, last4: "1234",
            expirationMonth: 13, expirationYear: 2030))
        XCTAssertThrowsError(try VaultHandleDisplay.card(brand: .visa,
            last4: "4111111111111111", expirationMonth: 1, expirationYear: 2030))
        let card = try VaultHandleDisplay.card(brand: .visa, last4: "1234",
            expirationMonth: 3, expirationYear: 2032)
        XCTAssertEqual(card.displayText, "Visa ending in 1234, expires 03/2032")
        XCTAssertEqual(VaultHandleDisplay.labeled(label: .homeAddress).displayText, "Home address")
    }

    func testLegacyV0SchemaMigratesPreservesRowsAndDropsUntrustedDisplays() throws {
        let directory = try temporaryDirectory()
        let database = directory.appendingPathComponent("legacy.db")
        let provider = TestKeyProvider()
        try createLegacyFixture(database, version: 0, conflict: false)
        XCTAssertEqual(try inspect(database), LegacyInspection(version: 0, lineageMask: 0,
            displayCount: 1, recordCount: 1))
        let migrated = try XCTUnwrap(MemoryStore.open(enabled: true, databaseURL: database, keyProvider: provider))
        XCTAssertEqual(try migrated.get(id: "legacy-row")?.body, "migration canary")
        XCTAssertEqual(try migrated.search("migration canary").first?.record.id, "legacy-row")
        try migrated.close()
        XCTAssertEqual(try inspect(database), LegacyInspection(version: 7, lineageMask: 7,
            displayCount: 0, recordCount: 1))
    }

    func testMigrationFailureRollsBackAndUnknownFutureVersionFailsClosed() throws {
        let directory = try temporaryDirectory()
        let database = directory.appendingPathComponent("migration.db")
        let provider = TestKeyProvider()
        try createLegacyFixture(database, version: 1, conflict: true)
        XCTAssertThrowsError(try MemoryStore.open(enabled: true, databaseURL: database, keyProvider: provider))
        XCTAssertEqual(try inspect(database), LegacyInspection(version: 1, lineageMask: 2,
            displayCount: 1, recordCount: 1), "migration must roll back ALTER and old display deletion")

        let future = directory.appendingPathComponent("future.db")
        try createLegacyFixture(future, version: 99, conflict: false)
        XCTAssertThrowsError(try MemoryStore.open(enabled: true, databaseURL: future, keyProvider: provider))
        XCTAssertEqual(try inspect(future).version, 99)
    }

    func testVersionOneMigrationAddsLineageAndRemovesLegacyDisplays() throws {
        let directory = try temporaryDirectory()
        let database = directory.appendingPathComponent("version-one.db")
        let provider = TestKeyProvider()
        try createLegacyFixture(database, version: 1, conflict: false)
        let migrated = try XCTUnwrap(MemoryStore.open(enabled: true, databaseURL: database, keyProvider: provider))
        XCTAssertEqual(try migrated.get(id: "legacy-row")?.body, "migration canary")
        try migrated.close()
        XCTAssertEqual(try inspect(database), LegacyInspection(version: 7, lineageMask: 7,
            displayCount: 0, recordCount: 1))
    }

    private struct LegacyInspection: Equatable {
        let version: Int32
        let lineageMask: Int32
        let displayCount: Int32
        let recordCount: Int32
    }

    private func createLegacyFixture(_ url: URL, version: Int32, conflict: Bool) throws {
        let key = Data(repeating: 0x4a, count: 32)
        let status = url.path.withCString { path in
            key.withUnsafeBytes { bytes in
                memory_test_create_legacy_database(path, bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count, version, conflict ? 1 : 0)
            }
        }
        XCTAssertEqual(status, 0)
    }

    private func inspect(_ url: URL) throws -> LegacyInspection {
        let key = Data(repeating: 0x4a, count: 32)
        var version: Int32 = 0
        var mask: Int32 = 0
        var displays: Int32 = 0
        var records: Int32 = 0
        let status = url.path.withCString { path in
            key.withUnsafeBytes { bytes in
                memory_test_inspect_database(path, bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count, &version, &mask, &displays, &records)
            }
        }
        XCTAssertEqual(status, 0)
        return LegacyInspection(version: version, lineageMask: mask,
            displayCount: displays, recordCount: records)
    }
}

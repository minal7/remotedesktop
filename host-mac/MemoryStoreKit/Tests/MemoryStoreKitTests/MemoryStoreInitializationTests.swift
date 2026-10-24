import Foundation
import XCTest
@testable import MemoryStoreKit

private final class InitializationTestKeyProvider: MemoryKeyProvider, @unchecked Sendable {
    func loadKey() throws -> Data { Data(repeating: 0x5a, count: 32) }
    func destroyKey() throws { }
}

final class MemoryStoreInitializationTests: XCTestCase {
    private func makeStore() throws -> (MemoryStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryStoreInitialization-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let database = root.appendingPathComponent("memory.sqlite")
        let store = try XCTUnwrap(MemoryStore.open(enabled: true, databaseURL: database,
            keyProvider: InitializationTestKeyProvider()))
        return (store, root)
    }

    func testEmptyActiveStoreCanBeInitialized() throws {
        let (store, root) = try makeStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: root) }

        XCTAssertNoThrow(try store.requireEmptyForInitialization())
    }

    func testInactiveRecordStillBlocksInitialization() throws {
        let (store, root) = try makeStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: root) }
        try store.upsert(MemoryRecord(id: "inactive", kind: .fact, body: "hidden fixture content",
            source: .ownerConfirmed, observedAt: 1, active: false))

        XCTAssertThrowsError(try store.requireEmptyForInitialization()) { error in
            XCTAssertEqual(error as? MemoryStoreError, .contentPresent)
        }
    }

    func testReceiptAloneBlocksInitializationAfterItsRecordIsRemoved() throws {
        let (store, root) = try makeStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: root) }
        let record = MemoryRecord(id: "receipt-only", kind: .fact, body: "fixture content",
            source: .ownerConfirmed, observedAt: 2)
        _ = try store.commitOwnerCommand(record, commandKey: "fixture-command",
                                         payloadDigest: Data(repeating: 0x33, count: 32))
        try store.forget(id: record.id)

        XCTAssertThrowsError(try store.requireEmptyForInitialization()) { error in
            XCTAssertEqual(error as? MemoryStoreError, .contentPresent)
        }
    }

    func testVaultDisplayAloneBlocksInitialization() throws {
        let (store, root) = try makeStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: root) }
        try store.upsertVaultDisplay(.labeled(label: .workAddress))

        XCTAssertThrowsError(try store.requireEmptyForInitialization()) { error in
            XCTAssertEqual(error as? MemoryStoreError, .contentPresent)
        }
    }

    func testVaultInventoryAloneBlocksInitialization() throws {
        let (store, root) = try makeStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: root) }
        try store.registerVaultItem(UUID())

        XCTAssertThrowsError(try store.requireEmptyForInitialization()) { error in
            XCTAssertEqual(error as? MemoryStoreError, .contentPresent)
        }
    }

    func testPendingErasureFailsClosedInsteadOfReportingEmpty() throws {
        let (store, root) = try makeStore()
        defer { try? store.close(); try? FileManager.default.removeItem(at: root) }
        try store.beginVaultErasure()

        XCTAssertThrowsError(try store.requireEmptyForInitialization()) { error in
            XCTAssertEqual(error as? MemoryStoreError, .erasurePending)
        }
    }
}

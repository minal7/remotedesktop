import Foundation
import XCTest
@testable import MemoryStoreKit

private final class PaginationKeyProvider: MemoryKeyProvider, @unchecked Sendable {
    func loadKey() throws -> Data { Data(repeating: 0x71, count: 32) }
    func destroyKey() throws {}
}

final class OwnerMemoryPaginationTests: XCTestCase {
    private func fixture() throws -> (MemoryStore, OwnerMemoryWriter, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OwnerMemoryPagination-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(MemoryStore.open(enabled: true,
            databaseURL: directory.appendingPathComponent("memory.db"), keyProvider: PaginationKeyProvider()))
        let writer = OwnerMemoryWriter(store: store, authorize: { $0.ownerID == "owner" && $0.sessionID == "session" },
            isTaskActive: { _, _ in true }, policy: { OwnerMemoryPolicy(featureEnabled: true) })
        return (store, writer, directory)
    }

    private let context = OwnerMemoryContext(ownerID: "owner", sessionID: "session")

    func testListFiltersEpisodesBeforeLimitAndUsesStableIDCursor() throws {
        let (store, writer, _) = try fixture()
        for index in 0..<70 {
            let id = String(format: "record-%03d", index)
            let kind: MemoryKind = index % 3 == 0 ? .episode : (index % 2 == 0 ? .profile : .fact)
            try store.upsert(MemoryRecord(id: id, kind: kind, body: "owner text \(index)", source: .ownerMessage,
                observedAt: 1_800_000_000_000, active: index % 2 == 0))
        }
        var cursor: String?
        var found: [String] = []
        var inactive: [String] = []
        repeat {
            let page = try writer.ownerRecordsPage(afterRecordID: cursor, limit: 7, context: context)
            XCTAssertLessThanOrEqual(page.records.count, 7)
            XCTAssertTrue(page.records.allSatisfy { $0.kind == .profile || $0.kind == .fact })
            found += page.records.map(\.id)
            inactive += page.records.filter { !$0.active }.map(\.id)
            cursor = page.nextRecordID
            if let cursor { XCTAssertEqual(cursor, page.records.last?.id) }
        } while cursor != nil
        let expected = (0..<70).filter { $0 % 3 != 0 }.map { String(format: "record-%03d", $0) }
        XCTAssertEqual(found, expected)
        XCTAssertTrue(inactive.contains("record-001"), "Inactive owner records remain visible")
        XCTAssertTrue(try writer.ownerRecordsPage(afterRecordID: "record-019", limit: 7, context: context)
            .records.allSatisfy { $0.id > "record-019" })
    }

    func testSearchIsLiteralAndIncludesInactiveRecordsInIDOrder() throws {
        let (store, writer, _) = try fixture()
        let bodies = ["Unicode café owner preference", "Unicode café \"quoted\" phrase", "Unrelated note"]
        for (index, body) in bodies.enumerated() {
            try store.upsert(MemoryRecord(id: "search-\(index)", kind: .fact, body: body, source: .ownerConfirmed,
                observedAt: Int64(100 - index), active: index == 0))
        }
        let page = try writer.ownerRecordsPage(query: "café \"quoted\"", limit: 1, context: context)
        XCTAssertEqual(page.records.map(\.id), ["search-1"])
        XCTAssertNil(page.nextRecordID)
        XCTAssertEqual(try writer.ownerRecordsPage(query: "café", limit: 1, context: context).records.map(\.id), ["search-0"])
    }

    func testSearchPaginatesMoreThanWirePageSizeInStableIDOrder() throws {
        let (store, writer, _) = try fixture()
        for index in 0..<67 {
            try store.upsert(MemoryRecord(id: String(format: "match-%03d", index), kind: .fact,
                body: "shared phrase café \(index)", source: .ownerMessage,
                observedAt: Int64(index), active: index % 2 == 0))
        }
        var cursor: String?
        var found: [String] = []
        repeat {
            let page = try writer.ownerRecordsPage(query: "shared phrase", afterRecordID: cursor,
                limit: 20, context: context)
            found += page.records.map(\.id)
            cursor = page.nextRecordID
        } while cursor != nil
        XCTAssertEqual(found, (0..<67).map { String(format: "match-%03d", $0) })
    }

    func testLookaheadCursorSurvivesDeletionAndEditsKeepTheirPosition() throws {
        let (store, writer, _) = try fixture()
        for id in ["a", "b", "c", "d"] {
            try store.upsert(MemoryRecord(id: id, kind: .profile, body: "same day", source: .ownerMessage, observedAt: 1))
        }
        let first = try writer.ownerRecordsPage(limit: 2, context: context)
        XCTAssertEqual(first.records.map(\.id), ["a", "b"])
        XCTAssertEqual(first.nextRecordID, "b")
        try store.forget(id: "b")
        try store.upsert(MemoryRecord(id: "c", kind: .profile, body: "edited body", source: .ownerMessage, observedAt: 999))
        let second = try writer.ownerRecordsPage(afterRecordID: first.nextRecordID, limit: 2, context: context)
        XCTAssertEqual(second.records.map(\.id), ["c", "d"])
        XCTAssertNil(second.nextRecordID)
    }

    func testInvalidBoundsAndReadPolicyFailClosed() throws {
        let (store, writer, _) = try fixture()
        XCTAssertThrowsError(try writer.ownerRecordsPage(limit: 0, context: context))
        XCTAssertThrowsError(try writer.ownerRecordsPage(limit: 33, context: context))
        XCTAssertThrowsError(try writer.ownerRecordsPage(query: "\n", context: context))
        XCTAssertThrowsError(try writer.ownerRecordsPage(afterRecordID: String(repeating: "x", count: 513), context: context))
        let unauthorized = OwnerMemoryWriter(store: store, authorize: { _ in false },
            isTaskActive: { _, _ in true }, policy: { OwnerMemoryPolicy(featureEnabled: true) })
        XCTAssertThrowsError(try unauthorized.ownerRecordsPage(context: context)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .unauthorized)
        }
        try writer.beginForget()
        XCTAssertThrowsError(try writer.ownerRecordsPage(context: context)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .forgotten)
        }
        let disabled = OwnerMemoryWriter(store: try fixture().0, authorize: { _ in true },
            isTaskActive: { _, _ in true }, policy: { OwnerMemoryPolicy(featureEnabled: false) })
        XCTAssertThrowsError(try disabled.ownerRecordsPage(context: context)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .disabled)
        }
    }
}

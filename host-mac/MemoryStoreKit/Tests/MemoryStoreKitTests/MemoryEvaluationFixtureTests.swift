import Foundation
import XCTest
@testable import MemoryStoreKit

private struct FixtureEmbedding: LocalMemoryEmbeddingProvider {
    let identity = "synthetic-fixture-v1"
    let dimensions = 2
    func embed(_ text: String, purpose: MemoryEmbeddingPurpose) async throws -> [Float] { [1, 0] }
}

private struct FixtureTokenCounter: MemoryExactTokenCounter {
    func countTokens(in completeContext: String) async throws -> Int {
        completeContext.split(whereSeparator: \.isWhitespace).count
    }
}

final class MemoryEvaluationFixtureTests: XCTestCase {
    func testSnapshotDigestIsStableAfterOriginalFixtureServiceCloses() throws {
        let fixture = try XCTUnwrap(MemoryStoreFactory.makeDebugEvaluationFixture(enabled: true,
            records: [.init(id: "inactive", kind: .fact, body: "synthetic body",
                observedAt: 8, active: false)], ownerID: "snapshot-owner",
            sessionID: "snapshot-session", taskID: "snapshot-task"))
        defer { try? fixture.close() }

        let before = try fixture.snapshotDigest()
        XCTAssertEqual(before.recordCount, 1)
        XCTAssertEqual(before.sha256.count, 64)
        try fixture.service.close()
        XCTAssertEqual(try fixture.snapshotDigest(), before,
            "Snapshot must reopen the same private fake-keyed generation after prepare closes its service.")
    }

    func testSnapshotDigestChangesForBodyActiveProvenanceAndNewRows() throws {
        let fixture = try XCTUnwrap(MemoryStoreFactory.makeDebugEvaluationFixture(enabled: true,
            records: [.init(id: "record", kind: .fact, body: "initial", observedAt: 10, active: true)],
            ownerID: "snapshot-owner", sessionID: "snapshot-session", taskID: "snapshot-task"))
        defer { try? fixture.close() }
        let baseline = try fixture.snapshotDigest()
        let original = try XCTUnwrap(fixture.service.store.get(id: "record"))

        try fixture.service.store.upsert(MemoryRecord(id: original.id, kind: original.kind,
            body: "changed body", source: original.source, observedAt: original.observedAt,
            active: original.active, confidence: original.confidence, provenance: original.provenance))
        XCTAssertNotEqual(try fixture.snapshotDigest(), baseline, "Body changes must affect the opaque digest.")
        let bodyChanged = try fixture.snapshotDigest()

        try fixture.service.store.upsert(MemoryRecord(id: original.id, kind: original.kind,
            body: "changed body", source: original.source, observedAt: original.observedAt,
            active: false, confidence: original.confidence, provenance: original.provenance))
        XCTAssertNotEqual(try fixture.snapshotDigest(), bodyChanged, "Inactive state must be included.")
        let inactive = try fixture.snapshotDigest()

        try fixture.service.store.upsert(MemoryRecord(id: original.id, kind: original.kind,
            body: "changed body", source: original.source, observedAt: original.observedAt,
            active: false, confidence: original.confidence,
            provenance: MemoryProvenance(statementID: "changed-lineage")))
        XCTAssertNotEqual(try fixture.snapshotDigest(), inactive, "Provenance changes must be included.")
        let provenanceChanged = try fixture.snapshotDigest()

        try fixture.service.store.upsert(MemoryRecord(id: "new-record", kind: .profile,
            body: "new synthetic row", source: .ownerConfirmed, observedAt: 11))
        let withNewRow = try fixture.snapshotDigest()
        XCTAssertEqual(withNewRow.recordCount, 2)
        XCTAssertNotEqual(withNewRow, provenanceChanged, "New rows must affect count and digest.")

        try fixture.service.store.upsert(MemoryRecord(id: "new-record", kind: .profile,
            body: "new synthetic row", source: .ownerMessage, observedAt: 11))
        let changedSource = try fixture.snapshotDigest()
        XCTAssertNotEqual(changedSource, withNewRow, "Source changes must be included.")

        try fixture.service.store.forget(id: "new-record")
        let afterDelete = try fixture.snapshotDigest()
        XCTAssertEqual(afterDelete.recordCount, 1)
        XCTAssertNotEqual(afterDelete, changedSource, "Deleted rows must change count and digest.")
    }

    func testSnapshotDigestRejectsThe500RowBoundInsteadOfHashingPossibleTruncation() throws {
        let fixture = try XCTUnwrap(MemoryStoreFactory.makeDebugEvaluationFixture(enabled: true,
            records: [.init(id: "row-000", kind: .fact, body: "synthetic", observedAt: 0, active: true)],
            ownerID: "snapshot-owner", sessionID: "snapshot-session", taskID: "snapshot-task"))
        defer { try? fixture.close() }
        for index in 1..<500 {
            try fixture.service.store.upsert(MemoryRecord(id: String(format: "row-%03d", index),
                kind: .fact, body: "synthetic", source: .ownerMessage, observedAt: Int64(index)))
        }
        XCTAssertThrowsError(try fixture.snapshotDigest(),
            "A complete digest cannot be claimed when the bounded list reaches its maximum.")
    }

    func testSnapshotDigestRefusesAfterFixtureCloseWithoutRecreatingStore() throws {
        let fixture = try XCTUnwrap(MemoryStoreFactory.makeDebugEvaluationFixture(enabled: true,
            records: [.init(id: "row", kind: .fact, body: "synthetic", observedAt: 1, active: true)],
            ownerID: "snapshot-owner", sessionID: "snapshot-session", taskID: "snapshot-task"))
        try fixture.close()
        XCTAssertThrowsError(try fixture.snapshotDigest()) { error in
            XCTAssertEqual(error as? MemoryStoreError, .closed)
        }
    }

    func testDisabledFixtureDoesNotCreateOrOpenSyntheticStore() throws {
        let fixture = try MemoryStoreFactory.makeDebugEvaluationFixture(enabled: false,
            records: [], ownerID: "owner", sessionID: "session", taskID: "task")
        XCTAssertNil(fixture)
    }

    func testFixtureRequiresBoundedOwnerAndTaskIdentityBeforeCreatingStorage() throws {
        XCTAssertThrowsError(try MemoryStoreFactory.makeDebugEvaluationFixture(enabled: true,
            records: [], ownerID: "", sessionID: "session", taskID: "task"))
        XCTAssertThrowsError(try MemoryStoreFactory.makeDebugEvaluationFixture(enabled: true,
            records: [], ownerID: "owner", sessionID: "session", taskID: "task\n"))
    }

    func testEncryptedFixtureRetrievalIncludesActiveAisleAndExcludesSupersededWindow() async throws {
        let fixture = try XCTUnwrap(MemoryStoreFactory.makeDebugEvaluationFixture(enabled: true,
            records: [
                .init(id: "profile-seat-aisle", kind: .profile,
                      body: "Prefers an aisle seat when available.", observedAt: 100, active: true),
                .init(id: "profile-seat-window-old", kind: .profile,
                      body: "Previously preferred a window seat.", observedAt: 50, active: false),
            ], ownerID: "synthetic-owner", sessionID: "synthetic-session", taskID: "memory-recall-10-01"))
        defer { try? fixture.close() }

        XCTAssertEqual(fixture.binding.reference.count, 64)
        let context = OwnerMemoryContext(ownerID: fixture.ownerID, sessionID: fixture.sessionID,
                                         taskID: fixture.taskID)
        let persisted = try fixture.service.writer.list(context: context, limit: 10)
        XCTAssertEqual(Set(persisted.map(\.id)), ["profile-seat-aisle", "profile-seat-window-old"])
        XCTAssertEqual(persisted.first(where: { $0.id == "profile-seat-window-old" })?.active, false)

        let builder = MemoryContextBuilder(writer: fixture.service.writer, embedding: FixtureEmbedding(),
                                           tokenCounter: FixtureTokenCounter())
        let result = try await builder.build(.init(context: context, query: "usual seat on this flight",
            tokenBudget: 128, candidateLimit: 10, topK: 5))
        XCTAssertEqual(result.entries.map(\.id), ["profile-seat-aisle"])
        XCTAssertFalse(result.serializedContext.contains("window seat"))
    }

    func testActiveProfilesLoadAlongsideRetrievedFactAndSupersededProfileIsExcluded() async throws {
        let records = [
            MemoryEvaluationFixtureRecord(id: "profile-seat-aisle", kind: .profile,
                body: "Prefers an aisle seat when available.", observedAt: 100, active: true),
            MemoryEvaluationFixtureRecord(id: "profile-seat-window-old", kind: .profile,
                body: "Previously preferred a window seat.", observedAt: 50, active: false),
            MemoryEvaluationFixtureRecord(id: "profile-home-airport", kind: .profile,
                body: "Usual home airport is SFO.", observedAt: 75, active: true),
            MemoryEvaluationFixtureRecord(id: "fact-dentist-contact", kind: .fact,
                body: "Dentist is Dr. Mira Example.", observedAt: 100, active: true),
        ]
        let fixture = try XCTUnwrap(MemoryStoreFactory.makeDebugEvaluationFixture(enabled: true,
            records: records, ownerID: "synthetic-owner", sessionID: "synthetic-dentist", taskID: "fixture-dentist"))
        defer { try? fixture.close() }
        let context = OwnerMemoryContext(ownerID: fixture.ownerID, sessionID: fixture.sessionID,
                                         taskID: fixture.taskID)
        let builder = MemoryContextBuilder(writer: fixture.service.writer, embedding: FixtureEmbedding(),
                                           tokenCounter: FixtureTokenCounter())
        let result = try await builder.build(.init(context: context, query: "dentist appointment",
            tokenBudget: 128, candidateLimit: 10, topK: 5))
        XCTAssertEqual(Set(result.entries.map(\.id)),
                       ["profile-seat-aisle", "profile-home-airport", "fact-dentist-contact"])
        XCTAssertFalse(result.entries.map(\.id).contains("profile-seat-window-old"))
        XCTAssertTrue(result.serializedContext.contains("Dr. Mira Example"))
        XCTAssertTrue(result.serializedContext.contains("SFO"))
    }
}

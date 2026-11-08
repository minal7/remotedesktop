import Foundation
import XCTest
@testable import MemoryStoreKit

private final class EditTestKeyProvider: MemoryKeyProvider, @unchecked Sendable {
    func loadKey() throws -> Data { Data(repeating: 0x6b, count: 32) }
    func destroyKey() throws {}
}

private final class EditTestAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    func allow(_ context: OwnerMemoryContext) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled && context.ownerID == "owner" && context.sessionID == "session"
    }
    func setEnabled(_ value: Bool) { lock.lock(); enabled = value; lock.unlock() }
}

final class MemoryRecordEditTests: XCTestCase {
    private let context = OwnerMemoryContext(ownerID: "owner", sessionID: "session")

    private func fixture() throws -> (MemoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryRecordEdit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try XCTUnwrap(MemoryStore.open(enabled: true,
            databaseURL: directory.appendingPathComponent("memory.db"),
            keyProvider: EditTestKeyProvider()))
        addTeardownBlock {
            try? store.close()
            try? FileManager.default.removeItem(at: directory)
        }
        return (store, directory)
    }

    private func writer(_ store: MemoryStore, authority: EditTestAuthority = EditTestAuthority()) -> OwnerMemoryWriter {
        OwnerMemoryWriter(store: store, authorize: { authority.allow($0) },
            isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: true) },
            now: { Date(timeIntervalSince1970: 1_800_123_456) })
    }

    func testEditChangesTextAndFTSButKeepsRecordIdentityAndOwnerLineage() throws {
        let (store, _) = try fixture()
        let memory = writer(store)
        let proposal = try memory.stageProposal(candidate: OwnerMemoryCandidate(kind: .fact,
            text: "Prefers old cedar tea", origin: .page, sourceReference: "page:preferences",
            sourceSpan: "tea-choice"),
            context: OwnerMemoryContext(ownerID: "owner", sessionID: "session", taskID: "task"))
        let original = try memory.confirmProposal(proposalID: proposal.proposalID,
            commandID: "confirm", context: OwnerMemoryContext(ownerID: "owner", sessionID: "session", taskID: "task"))
        let old = try XCTUnwrap(store.get(id: original.recordID))
        XCTAssertEqual(old.source, .ownerConfirmed)
        XCTAssertEqual(old.provenance.candidateOrigin, "page")
        XCTAssertEqual(old.provenance.sourceReference, "page:preferences")
        XCTAssertEqual(old.provenance.sourceSpan, "tea-choice")
        let oldRevision = OwnerMemoryWriter.revision(for: old)

        let edited = try memory.edit(recordID: original.recordID, expectedRevision: oldRevision,
            text: "Prefers new jasmine tea", commandID: "edit-1", context: context)
        XCTAssertEqual(edited.recordID, original.recordID)
        XCTAssertFalse(edited.idempotentRetry)
        let current = try XCTUnwrap(store.get(id: original.recordID))
        XCTAssertEqual(current.kind, .fact)
        XCTAssertEqual(current.body, "Prefers new jasmine tea")
        XCTAssertEqual(current.source, .ownerMessage)
        XCTAssertEqual(current.observedAt, 1_800_123_456_000)
        XCTAssertNotEqual(current.provenance.statementID, old.provenance.statementID)
        XCTAssertNil(current.provenance.sourceMessageID)
        XCTAssertNil(current.provenance.proposalID)
        XCTAssertNil(current.provenance.candidateOrigin)
        XCTAssertNil(current.provenance.sourceReference)
        XCTAssertNil(current.provenance.sourceSpan)
        XCTAssertNotEqual(OwnerMemoryWriter.revision(for: current), oldRevision)
        XCTAssertTrue(try store.search("cedar").isEmpty)
        XCTAssertEqual(try store.search("jasmine").first?.record.id, original.recordID)
    }

    func testStaleRevisionFromAnotherDatabaseConnectionCannotOverwriteEdit() throws {
        let (firstStore, directory) = try fixture()
        let secondStore = try XCTUnwrap(MemoryStore.open(enabled: true,
            databaseURL: directory.appendingPathComponent("memory.db"),
            keyProvider: EditTestKeyProvider()))
        defer { try? secondStore.close() }
        let firstWriter = writer(firstStore)
        let secondWriter = writer(secondStore)
        let saved = try firstWriter.remember(kind: .profile, text: "Lives in North Harbor",
            commandID: "save", context: context)
        let snapshotA = try XCTUnwrap(firstStore.get(id: saved.recordID))
        let snapshotB = try XCTUnwrap(secondStore.get(id: saved.recordID))
        let revisionA = OwnerMemoryWriter.revision(for: snapshotA)
        let revisionB = OwnerMemoryWriter.revision(for: snapshotB)
        XCTAssertEqual(revisionA, revisionB)

        _ = try secondWriter.edit(recordID: saved.recordID, expectedRevision: revisionB,
            text: "Lives in South Harbor", commandID: "edit-b", context: context)
        XCTAssertThrowsError(try firstWriter.edit(recordID: saved.recordID, expectedRevision: revisionA,
            text: "Lives in West Harbor", commandID: "edit-a", context: context)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .commandConflict)
        }
        XCTAssertEqual(try firstStore.get(id: saved.recordID)?.body, "Lives in South Harbor")
    }

    func testEditCommandRetryIsIdempotentAndChangedPayloadConflicts() throws {
        let (store, _) = try fixture()
        let memory = writer(store)
        let saved = try memory.remember(kind: .fact, text: "Prefers a window seat",
            commandID: "save", context: context)
        let original = try XCTUnwrap(store.get(id: saved.recordID))
        let revision = OwnerMemoryWriter.revision(for: original)

        let first = try memory.edit(recordID: saved.recordID, expectedRevision: revision,
            text: "Prefers an aisle seat", commandID: "edit", context: context)
        let retry = try memory.edit(recordID: saved.recordID, expectedRevision: revision,
            text: "Prefers an aisle seat", commandID: "edit", context: context)
        XCTAssertEqual(first.recordID, retry.recordID)
        XCTAssertTrue(retry.idempotentRetry)
        XCTAssertThrowsError(try memory.edit(recordID: saved.recordID, expectedRevision: revision,
            text: "Prefers a middle seat", commandID: "edit", context: context)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .commandConflict)
        }
        XCTAssertEqual(try store.get(id: saved.recordID)?.body, "Prefers an aisle seat")
    }

    func testEditRequiresOwnerAuthorizationAndRejectsInvalidOrMissingRecords() throws {
        let (store, _) = try fixture()
        let authority = EditTestAuthority()
        let memory = writer(store, authority: authority)
        let saved = try memory.remember(kind: .fact, text: "Owner supplied fact",
            commandID: "save", context: context)
        let record = try XCTUnwrap(store.get(id: saved.recordID))
        let revision = OwnerMemoryWriter.revision(for: record)

        authority.setEnabled(false)
        XCTAssertThrowsError(try memory.edit(recordID: saved.recordID, expectedRevision: revision,
            text: "unauthorized edit", commandID: "denied", context: context)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .unauthorized)
        }
        authority.setEnabled(true)
        XCTAssertThrowsError(try memory.edit(recordID: saved.recordID, expectedRevision: revision,
            text: "", commandID: "empty", context: context)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .invalidInput)
        }
        XCTAssertThrowsError(try memory.edit(recordID: saved.recordID, expectedRevision: revision,
            text: String(repeating: "x", count: 4_097), commandID: "oversize", context: context)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .invalidInput)
        }
        XCTAssertThrowsError(try memory.edit(recordID: saved.recordID, expectedRevision: revision,
            text: "bad\u{0001}text", commandID: "control", context: context)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .invalidInput)
        }
        XCTAssertThrowsError(try memory.edit(recordID: "missing", expectedRevision: revision,
            text: "New text", commandID: "missing", context: context)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .recordNotFound)
        }
        let episode = try memory.remember(kind: .fact, text: "Non-episode record",
            commandID: "save-episode-test", context: context)
        let rawEpisode = MemoryRecord(id: "episode", kind: .episode, body: "An event",
            source: .ownerMessage, observedAt: 1)
        try store.upsert(rawEpisode)
        XCTAssertThrowsError(try memory.edit(recordID: "episode",
            expectedRevision: OwnerMemoryWriter.revision(for: rawEpisode), text: "Edited event",
            commandID: "episode-edit", context: context)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .invalidInput)
        }
        XCTAssertNotNil(try store.get(id: episode.recordID))
    }

    func testEditCannotResurrectARecordDeletedAfterItsRevisionWasRead() throws {
        let (store, _) = try fixture()
        let memory = writer(store)
        let saved = try memory.remember(kind: .fact, text: "Temporary fact",
            commandID: "save", context: context)
        let old = try XCTUnwrap(store.get(id: saved.recordID))
        let revision = OwnerMemoryWriter.revision(for: old)
        try memory.delete(recordID: saved.recordID, context: context)

        XCTAssertThrowsError(try memory.edit(recordID: saved.recordID, expectedRevision: revision,
            text: "Resurrected fact", commandID: "edit-after-delete", context: context)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .recordNotFound)
        }
        XCTAssertNil(try store.get(id: saved.recordID))
    }

    func testRetryAfterSuccessfulEditAndDeleteCannotResurrectRecord() throws {
        let (store, _) = try fixture()
        let memory = writer(store)
        let saved = try memory.remember(kind: .profile, text: "Prefers window seats",
            commandID: "save", context: context)
        let before = try XCTUnwrap(store.get(id: saved.recordID))
        let revision = OwnerMemoryWriter.revision(for: before)
        _ = try memory.edit(recordID: saved.recordID, expectedRevision: revision,
            text: "Prefers aisle seats", commandID: "edit", context: context)
        try memory.delete(recordID: saved.recordID, context: context)

        XCTAssertThrowsError(try memory.edit(recordID: saved.recordID, expectedRevision: revision,
            text: "Prefers aisle seats", commandID: "edit", context: context)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .commandConflict)
        }
        XCTAssertNil(try store.get(id: saved.recordID))
    }

    func testSimultaneousConnectionsAllowOneEditAndRejectTheStaleWriter() throws {
        let (firstStore, directory) = try fixture()
        let secondStore = try XCTUnwrap(MemoryStore.open(enabled: true,
            databaseURL: directory.appendingPathComponent("memory.db"),
            keyProvider: EditTestKeyProvider()))
        defer { try? secondStore.close() }
        let firstWriter = writer(firstStore)
        let secondWriter = writer(secondStore)
        let saved = try firstWriter.remember(kind: .fact, text: "Prefers a morning flight",
            commandID: "save", context: context)
        let snapshot = try XCTUnwrap(firstStore.get(id: saved.recordID))
        let revision = OwnerMemoryWriter.revision(for: snapshot)
        let gate = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let lock = NSLock()
        var successes = 0
        var conflicts = 0
        var unexpected: [String] = []
        for (writer, command, text) in [(firstWriter, "edit-1", "Prefers a morning flight"),
                                        (secondWriter, "edit-2", "Prefers an evening flight")] {
            group.enter()
            DispatchQueue.global().async {
                gate.wait()
                do {
                    _ = try writer.edit(recordID: saved.recordID, expectedRevision: revision,
                        text: text, commandID: command, context: self.context)
                    lock.lock(); successes += 1; lock.unlock()
                } catch OwnerMemoryWriterError.commandConflict {
                    lock.lock(); conflicts += 1; lock.unlock()
                } catch {
                    lock.lock(); unexpected.append(String(describing: type(of: error))); lock.unlock()
                }
                group.leave()
            }
        }
        gate.signal(); gate.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(conflicts, 1)
        XCTAssertTrue(unexpected.isEmpty)
    }
}

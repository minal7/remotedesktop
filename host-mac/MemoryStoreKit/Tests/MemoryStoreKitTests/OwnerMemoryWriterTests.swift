import Foundation
import XCTest
import MemoryStoreKitTestSupport
@testable import MemoryStoreKit

private final class WriterTestKeyProvider: MemoryKeyProvider, @unchecked Sendable {
    func loadKey() throws -> Data { Data(repeating: 0x5d, count: 32) }
    func destroyKey() throws {}
}

private final class WriterTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var allowedOwner = "owner-a"
    private var allowedSession = "session-a"
    private var activeTasks: Set<String> = ["task-a", "task-b"]
    private var currentPolicy = OwnerMemoryPolicy(featureEnabled: true)
    private var currentTime = Date(timeIntervalSince1970: 1_800_000_000)
    private var authorizationCalls = 0
    private var livenessCalls = 0

    func authorize(_ context: OwnerMemoryContext) -> Bool {
        lock.lock(); defer { lock.unlock() }
        authorizationCalls += 1
        return context.ownerID == allowedOwner && context.sessionID == allowedSession
    }

    func taskIsActive(ownerID: String, taskID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        livenessCalls += 1
        return ownerID == allowedOwner && activeTasks.contains(taskID)
    }

    func policy() -> OwnerMemoryPolicy { lock.lock(); defer { lock.unlock() }; return currentPolicy }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return currentTime }
    func setPolicy(_ value: OwnerMemoryPolicy) { lock.lock(); defer { lock.unlock() }; currentPolicy = value }
    func setNow(_ value: Date) { lock.lock(); defer { lock.unlock() }; currentTime = value }
    func setActive(_ value: Bool, taskID: String) {
        lock.lock(); defer { lock.unlock() }
        if value { activeTasks.insert(taskID) } else { activeTasks.remove(taskID) }
    }
    func callCounts() -> (authorization: Int, liveness: Int) {
        lock.lock(); defer { lock.unlock() }; return (authorizationCalls, livenessCalls)
    }
}

final class OwnerMemoryWriterTests: XCTestCase {
    private func fixture() throws -> (MemoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwnerMemoryWriter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("memory.db")
        let store = try XCTUnwrap(MemoryStore.open(enabled: true, databaseURL: url,
            keyProvider: WriterTestKeyProvider()))
        return (store, directory)
    }

    private func writer(_ store: MemoryStore, state: WriterTestState) -> OwnerMemoryWriter {
        OwnerMemoryWriter(store: store, authorize: { [weak state] in state?.authorize($0) ?? false },
            isTaskActive: { [weak state] ownerID, taskID in state?.taskIsActive(ownerID: ownerID, taskID: taskID) ?? false },
            policy: { [weak state] in state?.policy() ?? OwnerMemoryPolicy(featureEnabled: false) },
            now: { [weak state] in state?.now() ?? Date(timeIntervalSince1970: 0) })
    }

    private let ownerContext = OwnerMemoryContext(ownerID: "owner-a", sessionID: "session-a")
    private let taskContext = OwnerMemoryContext(ownerID: "owner-a", sessionID: "session-a", taskID: "task-a")

    func testExplicitRememberIsPersistentIdempotentAndChangedPayloadConflicts() throws {
        let (store, _) = try fixture()
        let state = WriterTestState()
        let memory = writer(store, state: state)
        let first = try memory.remember(kind: .fact, text: "Owner says prefers aisle seats",
            commandID: "command-1", context: ownerContext)
        let retry = try memory.remember(kind: .fact, text: "Owner says prefers aisle seats",
            commandID: "command-1", context: ownerContext)
        XCTAssertEqual(retry.recordID, first.recordID)
        XCTAssertFalse(first.idempotentRetry)
        XCTAssertTrue(retry.idempotentRetry)
        XCTAssertThrowsError(try memory.remember(kind: .profile, text: "Changed payload",
            commandID: "command-1", context: ownerContext)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .commandConflict)
        }
        let records = try memory.list(context: ownerContext)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].source, .ownerMessage)
        XCTAssertNil(records[0].provenance.sourceMessageID)
        XCTAssertNotNil(records[0].provenance.statementID)
        XCTAssertNotEqual(records[0].provenance.statementID, "command-1")
    }

    func testProposalIsUntrustedUntilExactOwnerConfirmationAndCannotReplay() throws {
        let (store, _) = try fixture()
        let state = WriterTestState()
        let memory = writer(store, state: state)
        let candidate = OwnerMemoryCandidate(kind: .fact, text: "Page suggests vegetarian meal",
            origin: .page, sourceReference: "page:listing-7", sourceSpan: "meal-choice")
        let proposal = try memory.stageProposal(candidate: candidate, context: taskContext)
        XCTAssertTrue(try memory.list(context: ownerContext).isEmpty)
        XCTAssertThrowsError(try memory.confirmProposal(proposalID: proposal.proposalID,
            commandID: "confirm-1", context: OwnerMemoryContext(ownerID: "other", sessionID: "session-a", taskID: "task-a")))
        XCTAssertThrowsError(try memory.confirmProposal(proposalID: proposal.proposalID,
            commandID: "confirm-1", context: OwnerMemoryContext(ownerID: "owner-a", sessionID: "session-a", taskID: "task-b"))) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .proposalBindingMismatch)
        }
        let saved = try memory.confirmProposal(proposalID: proposal.proposalID,
            commandID: "confirm-1", context: taskContext)
        XCTAssertFalse(saved.idempotentRetry)
        let replay = try memory.confirmProposal(proposalID: proposal.proposalID,
            commandID: "confirm-1", context: taskContext)
        XCTAssertEqual(replay.recordID, saved.recordID)
        XCTAssertTrue(replay.idempotentRetry)
        XCTAssertThrowsError(try memory.confirmProposal(proposalID: proposal.proposalID,
            commandID: "different-command", context: taskContext)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .commandConflict)
        }
        let record = try XCTUnwrap(store.get(id: saved.recordID))
        XCTAssertEqual(record.source, .ownerConfirmed)
        XCTAssertEqual(record.provenance.proposalID, proposal.proposalID)
        XCTAssertNil(record.provenance.sourceMessageID, "A generated ID must not imply message provenance")
        XCTAssertEqual(record.provenance.candidateOrigin, "page")
        XCTAssertEqual(record.provenance.sourceReference, "page:listing-7")
        XCTAssertEqual(record.provenance.sourceSpan, "meal-choice")
        XCTAssertEqual(record.body, candidate.text)
        XCTAssertEqual(try memory.list(context: ownerContext).count, 1)
    }

    func testProposalLimitIsThreeForTaskAndSourcesOnlyStage() throws {
        let (store, _) = try fixture()
        let state = WriterTestState()
        let memory = writer(store, state: state)
        for index in 0..<3 {
            _ = try memory.stageProposal(candidate: OwnerMemoryCandidate(kind: .profile,
                text: "candidate-\(index)", origin: index == 0 ? .model : .tool,
                sourceReference: "message-\(index)", sourceSpan: "step-\(index)"), context: taskContext)
        }
        XCTAssertThrowsError(try memory.stageProposal(candidate: OwnerMemoryCandidate(kind: .fact,
            text: "fourth candidate", origin: .page, sourceReference: "page-4", sourceSpan: "page:4"), context: taskContext)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .proposalLimit)
        }
        XCTAssertTrue(try memory.list(context: ownerContext).isEmpty)
        XCTAssertEqual(state.callCounts().authorization, 5)
        XCTAssertEqual(state.callCounts().liveness, 4)
    }

    func testEveryOperationChecksOwnerAndTaskAndFeaturePolicies() throws {
        let (store, _) = try fixture()
        let state = WriterTestState()
        let memory = writer(store, state: state)
        XCTAssertThrowsError(try memory.remember(kind: .fact, text: "not authorized",
            commandID: "unauth", context: OwnerMemoryContext(ownerID: "owner-b", sessionID: "session-a"))) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .unauthorized)
        }
        XCTAssertThrowsError(try memory.remember(kind: .fact, text: "wrong session",
            commandID: "wrong-session", context: OwnerMemoryContext(ownerID: "owner-a", sessionID: "session-b"))) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .unauthorized)
        }
        state.setActive(false, taskID: "task-a")
        XCTAssertThrowsError(try memory.stageProposal(candidate: OwnerMemoryCandidate(kind: .fact,
            text: "inactive task", origin: .model, sourceReference: "message-1", sourceSpan: "step-1"), context: taskContext)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .inactiveTask)
        }
        state.setActive(true, taskID: "task-a")
        state.setPolicy(OwnerMemoryPolicy(featureEnabled: false))
        XCTAssertThrowsError(try memory.remember(kind: .fact, text: "feature off",
            commandID: "off", context: ownerContext)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .disabled)
        }
        XCTAssertThrowsError(try memory.list(context: ownerContext)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .disabled)
        }
        state.setPolicy(OwnerMemoryPolicy(featureEnabled: true, incognito: true))
        XCTAssertThrowsError(try memory.remember(kind: .fact, text: "incognito",
            commandID: "incognito", context: ownerContext)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .incognito)
        }
        state.setPolicy(OwnerMemoryPolicy(featureEnabled: true, noMemory: true, pauseLearning: true))
        let explicitSave = try memory.remember(kind: .profile, text: "Owner explicitly saved",
            commandID: "explicit-no-memory", context: ownerContext)
        XCTAssertFalse(explicitSave.idempotentRetry)
        XCTAssertThrowsError(try memory.search("Owner", context: ownerContext)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .noMemory)
        }
        XCTAssertThrowsError(try memory.stageProposal(candidate: OwnerMemoryCandidate(kind: .fact,
            text: "paused candidate", origin: .model, sourceReference: "message-2", sourceSpan: "step-2"), context: taskContext)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .learningPaused)
        }
        XCTAssertEqual(state.callCounts().authorization, 9)
        XCTAssertGreaterThanOrEqual(state.callCounts().liveness, 2)
    }

    func testExpiredProposalAndMetadataDelete() throws {
        let (store, _) = try fixture()
        let state = WriterTestState()
        let memory = writer(store, state: state)
        let proposal = try memory.stageProposal(candidate: OwnerMemoryCandidate(kind: .fact,
            text: "expires", origin: .tool, sourceReference: "tool-call-2", sourceSpan: "tool:result"), context: taskContext)
        state.setNow(proposal.expiresAt.addingTimeInterval(1))
        XCTAssertThrowsError(try memory.confirmProposal(proposalID: proposal.proposalID,
            commandID: "expired-confirm", context: taskContext)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .proposalExpired)
        }
        let saved = try memory.remember(kind: .fact, text: "delete me", commandID: "delete-cmd", context: ownerContext)
        try memory.delete(recordID: saved.recordID, context: ownerContext)
        XCTAssertThrowsError(try memory.remember(kind: .fact, text: "delete me",
            commandID: "delete-cmd", context: ownerContext)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .commandConflict)
        }
        XCTAssertTrue(try memory.list(context: ownerContext).isEmpty)
    }

    func testConfirmedProposalRetrySurvivesWriterAndStoreRestartWithBindings() throws {
        let (store, directory) = try fixture()
        let state = WriterTestState()
        let firstWriter = writer(store, state: state)
        let proposal = try firstWriter.stageProposal(candidate: OwnerMemoryCandidate(kind: .fact,
            text: "A reviewed candidate", origin: .model, sourceReference: "message-42",
            sourceSpan: "statement-3"), context: taskContext)
        let saved = try firstWriter.confirmProposal(proposalID: proposal.proposalID,
            commandID: "confirm-durable", context: taskContext)
        try store.close()

        let reopened = try XCTUnwrap(MemoryStore.open(enabled: true,
            databaseURL: directory.appendingPathComponent("memory.db"), keyProvider: WriterTestKeyProvider()))
        let resumedWriter = writer(reopened, state: state)
        XCTAssertThrowsError(try resumedWriter.confirmProposal(proposalID: proposal.proposalID,
            commandID: "different-command", context: taskContext)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .commandConflict)
        }
        XCTAssertThrowsError(try resumedWriter.confirmProposal(proposalID: proposal.proposalID,
            commandID: "confirm-durable",
            context: OwnerMemoryContext(ownerID: "owner-b", sessionID: "session-a", taskID: "task-a"))) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .unauthorized)
        }
        XCTAssertThrowsError(try resumedWriter.confirmProposal(proposalID: proposal.proposalID,
            commandID: "confirm-durable",
            context: OwnerMemoryContext(ownerID: "owner-a", sessionID: "session-b", taskID: "task-a"))) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .unauthorized)
        }
        XCTAssertThrowsError(try resumedWriter.confirmProposal(proposalID: proposal.proposalID,
            commandID: "confirm-durable",
            context: OwnerMemoryContext(ownerID: "owner-a", sessionID: "session-a", taskID: "task-b"))) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .proposalBindingMismatch)
        }

        let retry = try resumedWriter.confirmProposal(proposalID: proposal.proposalID,
            commandID: "confirm-durable", context: taskContext)
        XCTAssertEqual(retry.recordID, saved.recordID)
        XCTAssertTrue(retry.idempotentRetry)
        XCTAssertEqual(try resumedWriter.list(context: ownerContext).filter { $0.id == saved.recordID }.count, 1)
        let persisted = try XCTUnwrap(reopened.get(id: saved.recordID))
        XCTAssertEqual(persisted.provenance.candidateOrigin, "model")
        XCTAssertEqual(persisted.provenance.sourceReference, "message-42")
        XCTAssertEqual(persisted.provenance.sourceSpan, "statement-3")
    }

    func testDurableProposalRetryExpiresAndDeletedRecordDoesNotResurrect() throws {
        let (store, directory) = try fixture()
        let state = WriterTestState()
        let memory = writer(store, state: state)
        let proposal = try memory.stageProposal(candidate: OwnerMemoryCandidate(kind: .fact,
            text: "Delete after save", origin: .tool, sourceReference: "tool-call-9",
            sourceSpan: "result-1"), context: taskContext)
        let saved = try memory.confirmProposal(proposalID: proposal.proposalID,
            commandID: "confirm-delete", context: taskContext)
        try store.close()
        let reopened = try XCTUnwrap(MemoryStore.open(enabled: true,
            databaseURL: directory.appendingPathComponent("memory.db"), keyProvider: WriterTestKeyProvider()))
        let resumedWriter = writer(reopened, state: state)
        try resumedWriter.delete(recordID: saved.recordID, context: ownerContext)
        XCTAssertThrowsError(try resumedWriter.confirmProposal(proposalID: proposal.proposalID,
            commandID: "confirm-delete", context: taskContext)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .proposalNotFound)
        }
        XCTAssertNil(try reopened.get(id: saved.recordID))
        XCTAssertTrue(try resumedWriter.list(context: ownerContext).isEmpty)

        let expiring = try resumedWriter.stageProposal(candidate: OwnerMemoryCandidate(kind: .fact,
            text: "Expires after commit", origin: .page, sourceReference: "page-10",
            sourceSpan: "summary"), context: taskContext)
        _ = try resumedWriter.confirmProposal(proposalID: expiring.proposalID,
            commandID: "confirm-expired", context: taskContext)
        state.setNow(expiring.expiresAt.addingTimeInterval(1))
        XCTAssertThrowsError(try resumedWriter.confirmProposal(proposalID: expiring.proposalID,
            commandID: "confirm-expired", context: taskContext)) { error in
            XCTAssertEqual(error as? OwnerMemoryWriterError, .proposalExpired)
        }
    }

    func testVersionTwoMigrationCreatesPersistentIdempotencyReceipts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwnerMemoryV2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("memory.db")
        let key = Data(repeating: 0x5d, count: 32)
        let fixtureStatus = database.path.withCString { path in
            key.withUnsafeBytes { bytes in
                memory_test_create_legacy_database(path, bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count, 2, 0)
            }
        }
        XCTAssertEqual(fixtureStatus, 0)
        let store = try XCTUnwrap(MemoryStore.open(enabled: true, databaseURL: database,
            keyProvider: WriterTestKeyProvider()))
        let state = WriterTestState()
        let memory = writer(store, state: state)
        let first = try memory.remember(kind: .fact, text: "B3 migration retry",
            commandID: "stable-command", context: ownerContext)
        try store.close()

        let reopened = try XCTUnwrap(MemoryStore.open(enabled: true, databaseURL: database,
            keyProvider: WriterTestKeyProvider()))
        let resumedWriter = writer(reopened, state: state)
        let retry = try resumedWriter.remember(kind: .fact, text: "B3 migration retry",
            commandID: "stable-command", context: ownerContext)
        XCTAssertEqual(retry.recordID, first.recordID)
        XCTAssertTrue(retry.idempotentRetry)
        XCTAssertEqual(try resumedWriter.list(context: ownerContext).filter { $0.id == first.recordID }.count, 1)
    }
}

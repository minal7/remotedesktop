import Foundation
import XCTest
@testable import MemoryStoreKit

private final class PeerForgetKeychain: KeychainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ExactKeychainItem: Data] = [:]
    private var deleteFailure: ExactKeychainItem?
    private var copyBarrierItem: ExactKeychainItem?
    private var copyBarrier: (DispatchSemaphore, DispatchSemaphore)?
    private var beforeDatabaseKeyDelete: (() -> Void)?
    private var accessCounts: [ExactKeychainItem: Int] = [:]
    private var deleteCounts: [ExactKeychainItem: Int] = [:]

    func add(_ item: ExactKeychainItem, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        accessCounts[item, default: 0] += 1
        guard items[item] == nil else { throw KeychainBoundaryError.duplicateItem }
        items[item] = data
    }

    func copy(_ item: ExactKeychainItem) throws -> Data {
        lock.lock()
        accessCounts[item, default: 0] += 1
        let barrier = copyBarrierItem == item ? copyBarrier : nil
        lock.unlock()
        if let barrier { barrier.0.signal(); _ = barrier.1.wait(timeout: .now() + 5) }
        lock.lock(); defer { lock.unlock() }
        guard let data = items[item] else { throw KeychainBoundaryError.missingItem }
        return data
    }

    func delete(_ item: ExactKeychainItem) throws {
        lock.lock()
        let callback = item.account == "database-key" ? beforeDatabaseKeyDelete : nil
        lock.unlock()
        callback?()
        lock.lock(); defer { lock.unlock() }
        accessCounts[item, default: 0] += 1
        deleteCounts[item, default: 0] += 1
        if deleteFailure == item {
            deleteFailure = nil
            throw KeychainBoundaryError.accessDenied
        }
        guard items.removeValue(forKey: item) != nil else { throw KeychainBoundaryError.missingItem }
    }

    func failNextDelete(_ item: ExactKeychainItem) { lock.lock(); deleteFailure = item; lock.unlock() }
    func observeBeforeDatabaseKeyDelete(_ callback: @escaping () -> Void) {
        lock.lock(); beforeDatabaseKeyDelete = callback; lock.unlock()
    }
    func itemsContainForTesting(_ item: ExactKeychainItem) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return items[item] != nil
    }
    func accessCountForTesting(_ item: ExactKeychainItem) -> Int {
        lock.lock(); defer { lock.unlock() }
        return accessCounts[item, default: 0]
    }
    func deleteCountForTesting(_ item: ExactKeychainItem) -> Int {
        lock.lock(); defer { lock.unlock() }
        return deleteCounts[item, default: 0]
    }

    func armCopyBarrier(_ item: ExactKeychainItem) -> DispatchSemaphore {
        lock.lock(); defer { lock.unlock() }
        let barrier = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        copyBarrierItem = item; copyBarrier = barrier
        return barrier.0
    }

    func releaseCopyBarrier() {
        lock.lock(); defer { lock.unlock() }
        copyBarrier?.1.signal(); copyBarrier = nil; copyBarrierItem = nil
    }
}

private struct PeerForgetRandom: MemoryKeyRandomSource {
    func bytes(count: Int) throws -> Data { Data(repeating: 0x63, count: count) }
}

private final class PeerForgetAction: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() throws -> Void)?
    func set(_ action: @escaping () throws -> Void) { lock.lock(); self.action = action; lock.unlock() }
    func runOnce() {
        lock.lock(); let current = action; action = nil; lock.unlock()
        try? current?()
    }
}

private final class PeerForgetResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    func set(_ result: Result<Void, Error>) { lock.lock(); self.result = result; lock.unlock() }
    func get() -> Result<Void, Error>? { lock.lock(); defer { lock.unlock() }; return result }
}

private final class PeerForgetOpenResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<PersonalMemoryService, Error>?
    func set(_ result: Result<PersonalMemoryService, Error>) { lock.lock(); self.result = result; lock.unlock() }
    func get() -> Result<PersonalMemoryService, Error>? { lock.lock(); defer { lock.unlock() }; return result }
}

private final class PeerForgetAuthGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var first = true
    func authorize() -> Bool {
        lock.lock(); let wait = first; first = false; lock.unlock()
        if wait { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        return true
    }
}

private final class PeerForgetVerifier: VaultFillTrustedApprovalVerifier, @unchecked Sendable {
    func verifyOwnerApproval(_ receipt: VaultFillApprovalReceipt,
                             for challenge: VaultFillApprovalChallenge) throws { }
    func verifyFreshPhoneBiometric(_ receipt: VaultFillApprovalReceipt,
                                   for challenge: VaultFillApprovalChallenge) throws { }
}

final class PersonalMemoryPeerForgetTests: XCTestCase {
    private let owner = OwnerMemoryContext(ownerID: "peer-owner", sessionID: "peer-session")
    private let task = OwnerMemoryContext(ownerID: "peer-owner", sessionID: "peer-session",
                                          taskID: "peer-task")

    private func makeRoot() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalMemoryPeerForget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        return parent.appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
    }

    private func open(_ root: URL, client: PeerForgetKeychain, namespace: KeychainNamespace,
                      authorize: @escaping OwnerMemoryAuthorizer = { _ in true }) throws -> PersonalMemoryService {
        let opened = try MemoryStoreFactory.openForTesting(enabled: true, root: root,
            client: client, random: PeerForgetRandom(), namespace: namespace,
            authorize: authorize, isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: true) })
        return try XCTUnwrap(opened)
    }

    private func proposal(_ writer: OwnerMemoryWriter, text: String = "peer candidate") throws -> OwnerMemoryProposal {
        try writer.stageProposal(candidate: OwnerMemoryCandidate(kind: .fact, text: text, origin: .page,
            sourceReference: "fixture-reference", sourceSpan: "fixture-span"), context: task)
    }

    private func markerItem(_ namespace: KeychainNamespace) -> ExactKeychainItem {
        ExactKeychainItem(service: namespace.databaseKeyService + ".forget-recovery",
            account: "forget-files-pending-v1", protection: .deviceOnlyWhenUnlocked)
    }

    private func databaseKey(_ namespace: KeychainNamespace) -> ExactKeychainItem {
        ExactKeychainItem(service: namespace.databaseKeyService, account: "database-key",
            protection: .deviceOnlyWhenUnlocked)
    }

    func testForgetPurgesAndClosesEverySameRootPeerBeforeSuccess() throws {
        let root = try makeRoot()
        let namespace = KeychainNamespace.testing("peer-forget-\(UUID().uuidString)")
        let client = PeerForgetKeychain()
        let first = try open(root, client: client, namespace: namespace)
        let second = try open(root, client: client, namespace: namespace)
        let staged = try proposal(second.writer)
        XCTAssertEqual(second.writer.stagedProposalCountForTesting, 1)
        XCTAssertTrue(second.writer.hasOpenStoreHandleForTesting)

        let peersWerePurgedAndClosed = PeerForgetResult()
        client.observeBeforeDatabaseKeyDelete { [weak second] in
            guard let second else {
                peersWerePurgedAndClosed.set(.failure(MemoryFactoryError.memoryErasureFailed))
                return
            }
            peersWerePurgedAndClosed.set(second.writer.stagedProposalCountForTesting == 0 &&
                !second.writer.hasOpenStoreHandleForTesting ? .success(()) :
                .failure(MemoryFactoryError.memoryErasureFailed))
        }

        try first.forgetAll()

        guard case .success? = peersWerePurgedAndClosed.get() else {
            return XCTFail("all same-root peers must be purged and closed before database-key deletion")
        }

        XCTAssertEqual(second.writer.stagedProposalCountForTesting, 0,
                       "Forget must clear peer-held candidate text before returning")
        XCTAssertFalse(second.writer.hasOpenStoreHandleForTesting,
                        "Forget must close every same-root SQLite handle before deleting its key")
        XCTAssertTrue(client.itemsContainForTesting(markerItem(namespace)))
        XCTAssertThrowsError(try second.writer.confirmProposal(proposalID: staged.proposalID,
            commandID: "confirm-after-peer-forget", context: task)) {
            XCTAssertEqual($0 as? OwnerMemoryWriterError, .forgotten)
        }
    }

    func testRetainedWriterIsRegisteredAfterItsServiceIsReleased() throws {
        let root = try makeRoot()
        let namespace = KeychainNamespace.testing("retained-writer-\(UUID().uuidString)")
        let client = PeerForgetKeychain()
        let first = try open(root, client: client, namespace: namespace)
        var second: PersonalMemoryService? = try open(root, client: client, namespace: namespace)
        weak var weakSecond = second
        let retainedWriter = try XCTUnwrap(second?.writer)
        let staged = try proposal(retainedWriter, text: "retained writer candidate")
        second = nil
        XCTAssertNil(weakSecond, "the registry must not keep the service alive")
        XCTAssertEqual(retainedWriter.stagedProposalCountForTesting, 1)

        try first.forgetAll()

        XCTAssertEqual(retainedWriter.stagedProposalCountForTesting, 0)
        XCTAssertFalse(retainedWriter.hasOpenStoreHandleForTesting)
        XCTAssertThrowsError(try retainedWriter.confirmProposal(proposalID: staged.proposalID,
            commandID: "retained-confirm-after-forget", context: task)) {
            XCTAssertEqual($0 as? OwnerMemoryWriterError, .forgotten)
        }
    }

    func testRetainedPermitKeepsItsRevocationDomainParticipatingAfterServiceRelease() throws {
        let root = try makeRoot()
        let namespace = KeychainNamespace.testing("retained-permit-\(UUID().uuidString)")
        let client = PeerForgetKeychain()
        let first = try open(root, client: client, namespace: namespace)
        var second: PersonalMemoryService? = try open(root, client: client, namespace: namespace)
        let draft = try makeDraft()
        var lifecycle: VaultFillAuthorizationLifecycle? = try XCTUnwrap(second)
            .makeVaultFillAuthorizationLifecycle(draft: draft,
                currentRuntime: { VaultFillRuntimeSnapshot(binding: VaultFillCurrentBinding(draft: draft), status: .active) },
                verifier: PeerForgetVerifier(), now: { draft.createdAtWall.addingTimeInterval(1) },
                monotonicNow: { draft.createdAtMonotonic + 1 })
        let permit = try XCTUnwrap(lifecycle).authorize(VaultFillApprovalReceipt(
            challenge: VaultFillApprovalChallenge(draft: draft), proof: Data([1])))
        lifecycle = nil
        second = nil

        try first.forgetAll()

        XCTAssertThrowsError(try permit.consume()) {
            XCTAssertEqual($0 as? VaultFillAuthorizationError, .invalidated(.memoryForgotten))
        }
    }

    func testForgetDrainsAnAdmittedPeerWriterBeforeClosingItsStore() throws {
        let root = try makeRoot()
        let namespace = KeychainNamespace.testing("peer-drain-\(UUID().uuidString)")
        let client = PeerForgetKeychain()
        let first = try open(root, client: client, namespace: namespace)
        let gate = PeerForgetAuthGate()
        let second = try open(root, client: client, namespace: namespace,
            authorize: { _ in gate.authorize() })
        let writerResult = PeerForgetResult()
        let writerFinished = DispatchSemaphore(value: 0)
        let workers = DispatchGroup()
        workers.enter()
        DispatchQueue.global().async {
            do {
                _ = try second.writer.remember(kind: .fact, text: "active peer write",
                    commandID: "peer-drain-write", context: self.owner)
                writerResult.set(.success(()))
            } catch { writerResult.set(.failure(error)) }
            writerFinished.signal()
            workers.leave()
        }
        defer {
            gate.release.signal()
            _ = workers.wait(timeout: .now() + 6)
        }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 2), .success)
        let forgetFinished = DispatchSemaphore(value: 0)
        let forgetResult = PeerForgetResult()
        workers.enter()
        DispatchQueue.global().async {
            do { try first.forgetAll(); forgetResult.set(.success(())) }
            catch { forgetResult.set(.failure(error)) }
            forgetFinished.signal()
            workers.leave()
        }

        let firstForgetWait = forgetFinished.wait(timeout: .now() + .milliseconds(100))
        XCTAssertEqual(firstForgetWait, .timedOut,
                       "Forget cannot return while a peer writer still holds staged input")
        gate.release.signal()
        XCTAssertEqual(writerFinished.wait(timeout: .now() + 3), .success)
        if firstForgetWait == .timedOut {
            XCTAssertEqual(forgetFinished.wait(timeout: .now() + 3), .success)
        }
        guard case .success? = forgetResult.get() else {
            return XCTFail("Forget should complete after the blocked peer operation drains")
        }
        guard case .failure(let writerError)? = writerResult.get() else {
            return XCTFail("the operation admitted before the fence must be discarded")
        }
        XCTAssertEqual(writerError as? OwnerMemoryWriterError, .forgotten)
        XCTAssertFalse(second.writer.hasOpenStoreHandleForTesting)
    }

    func testOpenAdmittedBeforeForgetFenceIsRegisteredAndClosedBeforeSuccess() throws {
        let root = try makeRoot()
        let namespace = KeychainNamespace.testing("peer-open-race-\(UUID().uuidString)")
        let client = PeerForgetKeychain()
        let first = try open(root, client: client, namespace: namespace)
        let copyEntered = client.armCopyBarrier(databaseKey(namespace))
        let openResult = PeerForgetOpenResult()
        let workers = DispatchGroup()
        workers.enter()
        DispatchQueue.global().async {
            do { openResult.set(.success(try self.open(root, client: client, namespace: namespace))) }
            catch { openResult.set(.failure(error)) }
            workers.leave()
        }
        defer {
            client.releaseCopyBarrier()
            _ = workers.wait(timeout: .now() + 6)
        }
        XCTAssertEqual(copyEntered.wait(timeout: .now() + 2), .success,
                       "peer open must pause while holding the lifecycle lease")

        let forgetFinished = DispatchSemaphore(value: 0)
        let forgetResult = PeerForgetResult()
        workers.enter()
        DispatchQueue.global().async {
            do { try first.forgetAll(); forgetResult.set(.success(())) }
            catch { forgetResult.set(.failure(error)) }
            forgetFinished.signal()
            workers.leave()
        }
        let firstForgetWait = forgetFinished.wait(timeout: .now() + .milliseconds(100))
        XCTAssertEqual(firstForgetWait, .timedOut,
                       "Forget must wait for a factory open already admitted under the lease")
        client.releaseCopyBarrier()
        if firstForgetWait == .timedOut {
            XCTAssertEqual(forgetFinished.wait(timeout: .now() + 3), .success)
        }
        guard case .success(let peer)? = openResult.get() else {
            return XCTFail("the in-flight open should finish and be included in the peer snapshot")
        }
        guard case .success? = forgetResult.get() else {
            return XCTFail("Forget should finish after closing the admitted peer")
        }
        XCTAssertFalse(peer.writer.hasOpenStoreHandleForTesting)
        XCTAssertThrowsError(try peer.writer.list(context: owner)) {
            XCTAssertEqual($0 as? OwnerMemoryWriterError, .forgotten)
        }
    }

    func testDatabaseKeyFailureClosesPeersAndSameServiceRetryUsesRecoveryPath() throws {
        let root = try makeRoot()
        let namespace = KeychainNamespace.testing("peer-key-retry-\(UUID().uuidString)")
        let client = PeerForgetKeychain()
        let first = try open(root, client: client, namespace: namespace)
        let second = try open(root, client: client, namespace: namespace)
        _ = try proposal(second.writer)
        let dbURL = root.appendingPathComponent("memory.sqlite")
        let peersClosedBeforeKeyDelete = PeerForgetResult()
        client.observeBeforeDatabaseKeyDelete { [weak second] in
            guard let second else {
                peersClosedBeforeKeyDelete.set(.failure(MemoryFactoryError.memoryErasureFailed))
                return
            }
            peersClosedBeforeKeyDelete.set(second.writer.stagedProposalCountForTesting == 0 &&
                !second.writer.hasOpenStoreHandleForTesting ? .success(()) :
                .failure(MemoryFactoryError.memoryErasureFailed))
        }
        client.failNextDelete(databaseKey(namespace))

        XCTAssertThrowsError(try first.forgetAll())
        guard case .success? = peersClosedBeforeKeyDelete.get() else {
            return XCTFail("peer close must precede database-key destruction")
        }
        XCTAssertTrue(client.itemsContainForTesting(markerItem(namespace)))
        XCTAssertTrue(client.itemsContainForTesting(databaseKey(namespace)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
        XCTAssertFalse(second.writer.hasOpenStoreHandleForTesting)

        try first.forgetAll()

        XCTAssertTrue(client.itemsContainForTesting(markerItem(namespace)),
                      "the authenticated completion tombstone remains after retry")
        XCTAssertFalse(client.itemsContainForTesting(databaseKey(namespace)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path))
        XCTAssertFalse(second.writer.hasOpenStoreHandleForTesting)
    }

    func testPeerCloseFailureAfterMarkerRetainsKeyAndCanBeRetried() throws {
        let root = try makeRoot()
        let namespace = KeychainNamespace.testing("peer-close-retry-\(UUID().uuidString)")
        let client = PeerForgetKeychain()
        let first = try open(root, client: client, namespace: namespace)
        let second = try open(root, client: client, namespace: namespace)
        _ = try proposal(second.writer)
        second.failNextStoreCloseForErasureForTesting()

        XCTAssertThrowsError(try first.forgetAll())
        XCTAssertTrue(client.itemsContainForTesting(markerItem(namespace)))
        XCTAssertTrue(client.itemsContainForTesting(databaseKey(namespace)))
        XCTAssertTrue(second.writer.hasOpenStoreHandleForTesting,
                      "a failed peer close must not proceed to key deletion")
        XCTAssertEqual(second.writer.stagedProposalCountForTesting, 0)

        try first.forgetAll()

        XCTAssertFalse(client.itemsContainForTesting(databaseKey(namespace)))
        XCTAssertFalse(second.writer.hasOpenStoreHandleForTesting)
    }

    func testStandaloneRecoveryClosesStillLiveRegisteredPeerBeforeKeyCleanup() throws {
        let root = try makeRoot()
        let namespace = KeychainNamespace.testing("peer-standalone-recovery-\(UUID().uuidString)")
        let client = PeerForgetKeychain()
        let first = try open(root, client: client, namespace: namespace)
        let peer = try open(root, client: client, namespace: namespace)
        _ = try proposal(peer.writer)
        peer.failNextStoreCloseForErasureForTesting()
        XCTAssertThrowsError(try first.forgetAll())
        XCTAssertTrue(client.itemsContainForTesting(markerItem(namespace)))
        XCTAssertTrue(peer.writer.hasOpenStoreHandleForTesting)

        XCTAssertTrue(try MemoryStoreFactory.recoverForgetForTesting(enabled: true, root: root,
            client: client, namespace: namespace))

        XCTAssertFalse(peer.writer.hasOpenStoreHandleForTesting)
        XCTAssertEqual(peer.writer.stagedProposalCountForTesting, 0)
        XCTAssertFalse(client.itemsContainForTesting(databaseKey(namespace)))
    }

    func testInvalidRecoveryMarkerLeavesLivePeerUntouched() throws {
        let root = try makeRoot()
        let namespace = KeychainNamespace.testing("peer-invalid-recovery-\(UUID().uuidString)")
        let client = PeerForgetKeychain()
        let first = try open(root, client: client, namespace: namespace)
        let peer = try open(root, client: client, namespace: namespace)
        _ = try proposal(peer.writer)
        try client.add(markerItem(namespace), data: Data("invalid-marker".utf8))

        XCTAssertThrowsError(try MemoryStoreFactory.recoverForgetForTesting(enabled: true,
            root: root, client: client, namespace: namespace)) {
            XCTAssertEqual($0 as? MemoryFactoryError, .unsafeForgetJournal)
        }

        XCTAssertEqual(peer.writer.stagedProposalCountForTesting, 1)
        XCTAssertTrue(peer.writer.hasOpenStoreHandleForTesting)
        XCTAssertTrue(first.writer.hasOpenStoreHandleForTesting)
        XCTAssertTrue(client.itemsContainForTesting(databaseKey(namespace)))
    }

    func testRepeatedCompletedForgetDoesNotDeleteAlreadyMissingKeyAgain() throws {
        let root = try makeRoot()
        let namespace = KeychainNamespace.testing("peer-repeat-complete-\(UUID().uuidString)")
        let client = PeerForgetKeychain()
        let service = try open(root, client: client, namespace: namespace)

        try service.forgetAll()
        XCTAssertEqual(client.deleteCountForTesting(databaseKey(namespace)), 1)

        try service.forgetAll()

        XCTAssertEqual(client.deleteCountForTesting(databaseKey(namespace)), 1,
                       "completion retry verifies the key is absent without issuing a duplicate delete")
    }

    func testVaultDeleteFailurePurgesPeersButAllowsPendingStoreReopenAndRetry() throws {
        let root = try makeRoot()
        let namespace = KeychainNamespace.testing("peer-retry-\(UUID().uuidString)")
        let client = PeerForgetKeychain()
        let first = try open(root, client: client, namespace: namespace)
        let second = try open(root, client: client, namespace: namespace)
        _ = try proposal(second.writer)
        let itemID = VaultItemID()
        let vaultItem = ExactKeychainItem(service: namespace.vaultService,
            account: itemID.account(for: .cardNumber), protection: .userPresenceWhenUnlocked)
        try first.storeVaultSecret(VaultSecretValue("synthetic card fixture"),
                                   for: itemID, field: .cardNumber)
        client.failNextDelete(vaultItem)

        XCTAssertThrowsError(try first.forgetAll())
        XCTAssertFalse(client.itemsContainForTesting(markerItem(namespace)),
                       "the recovery marker is written only after exact vault deletion completes")
        XCTAssertTrue(client.itemsContainForTesting(databaseKey(namespace)))
        XCTAssertEqual(second.writer.stagedProposalCountForTesting, 0)
        XCTAssertTrue(second.writer.hasOpenStoreHandleForTesting,
                      "without the marker, a failed vault erase leaves peer handles retryable")

        let reopened = try open(root, client: client, namespace: namespace)
        XCTAssertThrowsError(try reopened.writer.remember(kind: .fact, text: "blocked by pending fence",
            commandID: "pending-fence-write", context: owner)) {
            XCTAssertEqual($0 as? OwnerMemoryWriterError, .forgotten)
        }
        try reopened.forgetAll()
        XCTAssertFalse(client.itemsContainForTesting(databaseKey(namespace)))
        XCTAssertFalse(second.writer.hasOpenStoreHandleForTesting)
    }

    func testPeerWriterReentrantForgetIsRejectedBeforeAnyPeerIsRevoked() throws {
        let root = try makeRoot()
        let namespace = KeychainNamespace.testing("peer-reentrant-\(UUID().uuidString)")
        let client = PeerForgetKeychain()
        let first = try open(root, client: client, namespace: namespace)
        let action = PeerForgetAction()
        let result = PeerForgetResult()
        let second = try open(root, client: client, namespace: namespace, authorize: { _ in
            action.runOnce()
            return true
        })
        action.set {
            do { try first.forgetAll(); result.set(.success(())) }
            catch { result.set(.failure(error)) }
        }

        _ = try second.writer.remember(kind: .fact, text: "survives rejected reentry",
            commandID: "reentrant-first", context: owner)

        guard case .failure(let error)? = result.get() else {
            return XCTFail("reentrant Forget must be rejected before any peer revocation")
        }
        XCTAssertEqual(error as? MemoryFactoryError, .memoryErasureFailed)
        XCTAssertTrue(try XCTUnwrap(second.writer.list(context: owner)).count == 1)
        _ = try second.writer.remember(kind: .fact, text: "still writable",
            commandID: "reentrant-second", context: owner)
    }

    func testUnrelatedRootWithSameNamespaceRemainsUsable() throws {
        let namespace = KeychainNamespace.testing("same-namespace-different-roots-\(UUID().uuidString)")
        let firstClient = PeerForgetKeychain()
        let secondClient = PeerForgetKeychain()
        let first = try open(try makeRoot(), client: firstClient, namespace: namespace)
        let second = try open(try makeRoot(), client: secondClient, namespace: namespace)
        _ = try first.writer.remember(kind: .fact, text: "first root", commandID: "first", context: owner)
        _ = try second.writer.remember(kind: .fact, text: "second root", commandID: "second", context: owner)

        try first.forgetAll()

        XCTAssertEqual(try second.writer.list(context: owner).count, 1)
        _ = try second.writer.remember(kind: .fact, text: "second root remains live",
            commandID: "second-after-first-forget", context: owner)
    }

    func testConflictingLiveNamespaceOnSameDatabaseRootIsRejectedBeforeKeyAccess() throws {
        let root = try makeRoot()
        let client = PeerForgetKeychain()
        let firstNamespace = KeychainNamespace.testing("root-conflict-a-\(UUID().uuidString)")
        let secondNamespace = KeychainNamespace.testing("root-conflict-b-\(UUID().uuidString)")
        let first = try open(root, client: client, namespace: firstNamespace)
        XCTAssertFalse(client.itemsContainForTesting(databaseKey(secondNamespace)))

        XCTAssertThrowsError(try open(root, client: client, namespace: secondNamespace))
        XCTAssertEqual(client.accessCountForTesting(databaseKey(secondNamespace)), 0,
                       "the conflicting namespace must be rejected before Keychain access")
        withExtendedLifetime(first) {}
        XCTAssertFalse(client.itemsContainForTesting(databaseKey(secondNamespace)),
                       "conflicting namespace must be rejected before key access or creation")
    }

    func testServiceClosePurgesItsWriterHeldCandidate() throws {
        let root = try makeRoot()
        let namespace = KeychainNamespace.testing("peer-close-\(UUID().uuidString)")
        let service = try open(root, client: PeerForgetKeychain(), namespace: namespace)
        _ = try proposal(service.writer)
        XCTAssertEqual(service.writer.stagedProposalCountForTesting, 1)

        try service.close()

        XCTAssertEqual(service.writer.stagedProposalCountForTesting, 0)
        XCTAssertFalse(service.writer.hasOpenStoreHandleForTesting)
    }

    private func makeDraft() throws -> VaultFillApprovalDraft {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let authority = VaultFillOwnerTaskAuthority(ownerID: "peer-owner", sessionID: "peer-session",
            taskID: "peer-task", revision: 1, intent: .ownerTaskExplicitlyRequestedFill)
        let target = VaultFillWebTargetInput(reference: "peer-ref", navigationGeneration: 1,
            frameGeneration: 1, topLevelOrigin: "https://checkout.example",
            frameOrigin: "https://checkout.example", autocomplete: "cc-number", inputType: .text,
            purpose: .typedFormField, contentEditable: false, visible: true, editable: true, secure: false)
        return try XCTUnwrap(VaultFillEligibility.assess(authority: authority, target: .web(target),
            request: VaultFillRequest(handle: VaultItemID(), itemKind: .paymentCard, field: .cardNumber),
            now: now, monotonicNow: { 1_000 }).draft)
    }
}


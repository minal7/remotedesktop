import Darwin
import Foundation
import XCTest
@testable import MemoryStoreKit

private enum MemoryGenerationFixtureError: Error { case injected }

private final class GenerationFixtureAdapters: KeychainClient, MemoryGenerationStateStore,
                                              MemoryKeyRandomSource, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ExactKeychainItem: Data] = [:]
    private var added: [ExactKeychainItem] = []
    private var deleted: [ExactKeychainItem] = []
    private var databaseKeyDeleteFailure = false
    private var readOverride: Data?
    private var replaceFailure = false
    private var committedReplaceFailureSkips = 0
    private var committedReplaceFailureCount = 0
    private var randomFailure = false
    private var randomCounter: UInt8 = 0x40

    func add(_ item: ExactKeychainItem, data: Data) throws {
        try withLock {
            guard values[item] == nil else { throw KeychainBoundaryError.duplicateItem }
            values[item] = data
            added.append(item)
        }
    }

    func copy(_ item: ExactKeychainItem) throws -> Data {
        try withLock {
            guard let value = values[item] else { throw KeychainBoundaryError.missingItem }
            return value
        }
    }

    func delete(_ item: ExactKeychainItem) throws {
        try withLock {
            if databaseKeyDeleteFailure, item.account == "database-key" {
                databaseKeyDeleteFailure = false
                throw MemoryGenerationFixtureError.injected
            }
            guard values.removeValue(forKey: item) != nil else {
                throw KeychainBoundaryError.missingItem
            }
            deleted.append(item)
        }
    }

    func read(_ item: ExactKeychainItem) throws -> Data {
        try withLock {
            if let readOverride { return readOverride }
            guard let value = values[item] else { throw KeychainBoundaryError.missingItem }
            return value
        }
    }

    func replace(_ item: ExactKeychainItem, with data: Data) throws {
        try withLock {
            if replaceFailure {
                replaceFailure = false
                throw MemoryGenerationFixtureError.injected
            }
            guard values[item] != nil else { throw KeychainBoundaryError.missingItem }
            values[item] = data
            added.append(item)
            if committedReplaceFailureSkips > 0 {
                committedReplaceFailureSkips -= 1
            } else if committedReplaceFailureCount > 0 {
                committedReplaceFailureCount -= 1
                throw MemoryGenerationFixtureError.injected
            }
        }
    }

    func replace(_ item: ExactKeychainItem, data: Data) throws {
        try replace(item, with: data)
    }

    func bytes(count: Int) throws -> Data {
        try withLock {
            if randomFailure {
                randomFailure = false
                throw MemoryGenerationFixtureError.injected
            }
            randomCounter &+= 1
            return Data(repeating: randomCounter, count: count)
        }
    }

    func armDatabaseKeyDeleteFailure() { withLock { databaseKeyDeleteFailure = true } }
    func armMalformedState(_ bytes: Data) { withLock { readOverride = bytes } }
    func armReplaceFailure() { withLock { replaceFailure = true } }
    func armCommittedReplaceFailure(afterSuccessfulReplaces: Int = 0) {
        withLock {
            committedReplaceFailureSkips = afterSuccessfulReplaces
            committedReplaceFailureCount = 1
        }
    }
    func armRandomFailure() { withLock { randomFailure = true } }
    func addedItems() -> [ExactKeychainItem] { withLock { added } }
    func deletedItems() -> [ExactKeychainItem] { withLock { deleted } }
    func contains(_ item: ExactKeychainItem) -> Bool { withLock { values[item] != nil } }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

private final class SerialGenerationTransitionLock: MemoryGenerationTransitionLock, @unchecked Sendable {
    private let lock = NSLock()
    func withExclusive<T>(at parentRoot: URL, _ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        return try operation()
    }
}

private final class GenerationInitializationBarrier: MemoryGenerationInitializationObserver,
                                                     @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let releaseGate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var shouldBlock = true
    private let point: MemoryGenerationInitializationPoint

    init(blocking point: MemoryGenerationInitializationPoint) { self.point = point }

    func reached(_ point: MemoryGenerationInitializationPoint) throws {
        guard Self.same(point, self.point) else { return }
        lock.lock()
        let shouldBlockNow = shouldBlock
        shouldBlock = false
        lock.unlock()
        guard shouldBlockNow else { return }
        entered.signal()
        guard releaseGate.wait(timeout: .now() + 5) == .success else {
            throw MemoryGenerationFixtureError.injected
        }
    }

    func waitUntilEntered() -> DispatchTimeoutResult {
        entered.wait(timeout: .now() + 3)
    }

    func release() { releaseGate.signal() }

    private static func same(_ lhs: MemoryGenerationInitializationPoint,
                             _ rhs: MemoryGenerationInitializationPoint) -> Bool {
        switch (lhs, rhs) {
        case (.afterReservation, .afterReservation), (.afterStorePrepared, .afterStorePrepared),
             (.beforeCommit, .beforeCommit), (.afterCommit, .afterCommit): return true
        default: return false
        }
    }
}

private final class GenerationResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?
    func set(_ value: Result<T, Error>) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Result<T, Error>? { lock.lock(); defer { lock.unlock() }; return value }
}

final class MemoryGenerationTests: XCTestCase {
    private struct Fixture {
        let parent: URL
        let root: URL
        let namespace: KeychainNamespace
        let adapters: GenerationFixtureAdapters
        let transitionLock: SerialGenerationTransitionLock

        func cleanup() { try? FileManager.default.removeItem(at: parent) }

        func openLegacy() throws -> PersonalMemoryService {
            let service = try MemoryStoreFactory.openForTesting(enabled: true, root: root,
                client: adapters, random: adapters, namespace: namespace,
                authorize: { _ in true }, isTaskActive: { _, _ in true },
                policy: { OwnerMemoryPolicy(featureEnabled: true) })
            return try XCTUnwrap(service)
        }

        func capture() throws -> MemoryStoreGeneration {
            let generation = try MemoryStoreFactory.captureGenerationForTesting(enabled: true,
                root: root, client: adapters, namespace: namespace,
                stateStore: adapters, transitionLock: transitionLock)
            return try XCTUnwrap(generation)
        }

        func initialize(_ old: MemoryStoreGeneration, id: UUID,
                        observer: (any MemoryGenerationInitializationObserver)? = nil) throws
            -> MemoryStoreGeneration {
            let generation = try MemoryStoreFactory.initializeAfterForgetForTesting(enabled: true,
                expectedGeneration: old, commandID: id, client: adapters, random: adapters,
                stateStore: adapters, transitionLock: transitionLock, observer: observer)
            return try XCTUnwrap(generation)
        }

        func open(_ generation: MemoryStoreGeneration) throws -> PersonalMemoryService {
            let service = try MemoryStoreFactory.openGenerationForTesting(enabled: true,
                generation: generation, client: adapters, random: adapters,
                authorize: { _ in true }, isTaskActive: { _, _ in true },
                policy: { OwnerMemoryPolicy(featureEnabled: true) }, stateStore: adapters)
            return try XCTUnwrap(service)
        }
    }

    private func fixture() throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryGeneration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let root = parent.appendingPathComponent("legacy", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        return Fixture(parent: parent, root: root,
            namespace: .testing("generation-\(UUID().uuidString)"),
            adapters: GenerationFixtureAdapters(), transitionLock: SerialGenerationTransitionLock())
    }

    private func context(_ suffix: String = "fixture") -> OwnerMemoryContext {
        OwnerMemoryContext(ownerID: String(repeating: "a", count: 64), sessionID: suffix)
    }

    @discardableResult
    private func remember(_ service: PersonalMemoryService, _ text: String,
                          command: UUID = UUID()) throws -> OwnerMemoryWriteReceipt {
        try service.writer.remember(kind: .fact, text: text,
            commandID: command.uuidString.lowercased(), context: context())
    }

    private func databaseKey(_ generation: MemoryStoreGeneration) -> ExactKeychainItem {
        ExactKeychainItem(service: generation.namespace.databaseKeyService, account: "database-key",
                          protection: .deviceOnlyWhenUnlocked)
    }

    private func vaultItem(_ id: VaultItemID, _ field: VaultSecretField,
                           generation: MemoryStoreGeneration) -> ExactKeychainItem {
        ExactKeychainItem(service: generation.namespace.vaultService,
            account: id.account(for: field), protection: .userPresenceWhenUnlocked)
    }

    private func vaultDraft() throws -> VaultFillApprovalDraft {
        let authority = VaultFillOwnerTaskAuthority(ownerID: "fixture-owner", sessionID: "fixture-session",
            taskID: "fixture-task", revision: 1, intent: .ownerTaskExplicitlyRequestedFill)
        let target = VaultFillWebTargetInput(reference: "fixture-ref", navigationGeneration: 1,
            frameGeneration: 1, topLevelOrigin: "https://checkout.example",
            frameOrigin: "https://checkout.example", autocomplete: "cc-number", inputType: .text,
            purpose: .typedFormField, contentEditable: false, visible: true, editable: true, secure: false)
        let request = VaultFillRequest(handle: VaultItemID(), itemKind: .paymentCard,
                                       field: .cardNumber)
        return try XCTUnwrap(VaultFillEligibility.assess(authority: authority, target: .web(target),
            request: request, now: Date(timeIntervalSince1970: 1_800_000_000),
            monotonicNow: { 1_000 }).draft)
    }

    func testDisabledCaptureAndInitializationReturnBeforeFilesystemOrKeychain() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let missing = f.parent.appendingPathComponent("missing", isDirectory: true)
        let capture = try MemoryStoreFactory.captureGenerationForTesting(enabled: false,
            root: missing, client: f.adapters, namespace: f.namespace,
            stateStore: f.adapters, transitionLock: f.transitionLock)
        XCTAssertNil(capture)
        let disabled = try MemoryStoreFactory.initializeAfterForgetForTesting(enabled: false,
            expectedGeneration: .legacy(root: missing, namespace: f.namespace), commandID: UUID(),
            client: f.adapters, random: f.adapters, stateStore: f.adapters,
            transitionLock: f.transitionLock)
        XCTAssertNil(disabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertTrue(f.adapters.addedItems().isEmpty)
    }

    func testLegacyCaptureAndOpenPreserveExistingDataWithoutRotating() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let original = try f.openLegacy()
        defer { try? original.close() }
        try remember(original, "fixture legacy fact")
        let legacy = try f.capture()
        XCTAssertEqual(legacy.identifier, MemoryStoreGeneration.legacyIdentifier)
        XCTAssertEqual(legacy.root, f.root)

        let reopened = try f.open(legacy)
        defer { try? reopened.close() }
        XCTAssertEqual(try reopened.writer.list(context: context()).map(\.body), ["fixture legacy fact"])
        XCTAssertEqual(f.adapters.addedItems().filter { $0.account == "database-key" }.count, 1)
    }

    func testExplicitResetAfterCompletedForgetCreatesDistinctEmptyGeneration() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let legacyService = try f.openLegacy()
        defer { try? legacyService.close() }
        let legacy = try f.capture()
        try remember(legacyService, "fixture old fact")
        try legacyService.forgetAll()

        let fresh = try f.initialize(legacy, id: UUID())
        XCTAssertNotEqual(fresh.identifier, legacy.identifier)
        XCTAssertNotEqual(fresh.root, legacy.root)
        XCTAssertNotEqual(fresh.namespace, legacy.namespace)
        XCTAssertEqual(fresh.parentRoot, legacy.parentRoot)
        let newService = try f.open(fresh)
        defer { try? newService.close() }
        XCTAssertTrue(try newService.writer.list(context: context()).isEmpty)
        XCTAssertTrue(f.adapters.contains(databaseKey(fresh)))
        XCTAssertFalse(f.adapters.contains(databaseKey(legacy)))
    }

    func testResetRetryIsIdempotentAndDifferentCommandCannotClaimGeneration() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.openLegacy()
        let legacy = try f.capture()
        try service.forgetAll()
        let resetID = UUID()
        let first = try f.initialize(legacy, id: resetID)
        let retry = try f.initialize(legacy, id: resetID)
        XCTAssertEqual(retry, first)
        XCTAssertThrowsError(try f.initialize(legacy, id: UUID()))
        let wrongRoot = MemoryStoreGeneration(identifier: legacy.identifier,
            parentRoot: legacy.parentRoot,
            root: f.parent.appendingPathComponent("descriptor-tamper", isDirectory: true),
            namespace: legacy.namespace, baseNamespace: legacy.baseNamespace)
        XCTAssertThrowsError(try f.initialize(wrongRoot, id: resetID),
                             "same-ID replay must validate the captured root")
        let wrongNamespace = MemoryStoreGeneration(identifier: legacy.identifier,
            parentRoot: legacy.parentRoot, root: legacy.root,
            namespace: .testing("tampered-generation-namespace"),
            baseNamespace: legacy.baseNamespace)
        XCTAssertThrowsError(try f.initialize(wrongNamespace, id: resetID),
                             "same-ID replay must validate the captured namespace")
        XCTAssertTrue(f.adapters.contains(databaseKey(first)))
        XCTAssertEqual(f.adapters.addedItems().filter {
            $0.service == first.namespace.databaseKeyService && $0.account == "database-key"
        }.count, 1)
    }

    func testResetWithoutCompletedForgetCannotCreateGeneration() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.openLegacy()
        defer { try? service.close() }
        let legacy = try f.capture()
        let initialKeyCount = f.adapters.addedItems().filter { $0.account == "database-key" }.count
        XCTAssertThrowsError(try f.initialize(legacy, id: UUID()))
        XCTAssertEqual(f.adapters.addedItems().filter { $0.account == "database-key" }.count,
                       initialKeyCount)
    }

    func testPendingForgetAndMalformedGenerationStateFailClosedWithoutNewKey() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.openLegacy()
        let legacy = try f.capture()
        f.adapters.armDatabaseKeyDeleteFailure()
        XCTAssertThrowsError(try service.forgetAll())
        let countAfterFailedForget = f.adapters.addedItems().filter { $0.account == "database-key" }.count
        XCTAssertThrowsError(try f.initialize(legacy, id: UUID()))
        XCTAssertEqual(f.adapters.addedItems().filter { $0.account == "database-key" }.count,
                       countAfterFailedForget)

        // A malformed state item must never be interpreted as an absent/legacy pointer.
        let malformed = try fixture()
        defer { malformed.cleanup() }
        malformed.adapters.armMalformedState(Data("not-a-generation-state".utf8))
        XCTAssertThrowsError(try MemoryStoreFactory.captureGenerationForTesting(enabled: true,
            root: malformed.root, client: malformed.adapters, namespace: malformed.namespace,
            stateStore: malformed.adapters, transitionLock: malformed.transitionLock))
        XCTAssertTrue(malformed.adapters.addedItems().isEmpty)
    }

    func testCapturedGenerationWithWrongRootOrNamespaceFailsBeforeKeyAccess() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.openLegacy()
        let generation = try f.capture()
        let initialAdds = f.adapters.addedItems().count
        let otherRoot = f.parent.appendingPathComponent("other", isDirectory: true)
        let wrongRoot = MemoryStoreGeneration(identifier: generation.identifier,
            parentRoot: generation.parentRoot, root: otherRoot,
            namespace: generation.namespace, baseNamespace: generation.baseNamespace)
        XCTAssertThrowsError(try f.open(wrongRoot))

        let wrongNamespace = MemoryStoreGeneration(identifier: generation.identifier,
            parentRoot: generation.parentRoot, root: generation.root,
            namespace: .testing("wrong-generation-namespace"),
            baseNamespace: generation.baseNamespace)
        XCTAssertThrowsError(try f.open(wrongNamespace))
        XCTAssertEqual(f.adapters.addedItems().count, initialAdds)
        try? service.close()
    }

    func testSymlinkGenerationRootFailsClosedBeforeKeyAccess() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.openLegacy()
        defer { try? service.close() }
        let generation = try f.capture()
        let link = f.parent.appendingPathComponent("linked-generation", isDirectory: true)
        XCTAssertEqual(symlink(generation.root.path, link.path), 0)
        let linked = MemoryStoreGeneration(identifier: generation.identifier,
            parentRoot: generation.parentRoot, root: link,
            namespace: generation.namespace, baseNamespace: generation.baseNamespace)
        let initialAdds = f.adapters.addedItems().count
        XCTAssertThrowsError(try f.open(linked))
        XCTAssertEqual(f.adapters.addedItems().count, initialAdds)
    }

    func testHardLinkedGenerationDatabaseFailsClosedAndPreservesTarget() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.openLegacy()
        let generation = try f.capture()
        try service.close()
        let database = generation.root.appendingPathComponent("memory.sqlite")
        let target = f.parent.appendingPathComponent("sentinel.sqlite")
        let sentinel = Data("synthetic hard-link sentinel".utf8)
        try sentinel.write(to: target)
        try FileManager.default.removeItem(at: database)
        XCTAssertEqual(link(target.path, database.path), 0)
        let initialAdds = f.adapters.addedItems().count
        XCTAssertThrowsError(try f.open(generation))
        XCTAssertEqual(f.adapters.addedItems().count, initialAdds)
        XCTAssertEqual(try Data(contentsOf: target), sentinel)
    }

    func testPreparedAndCommittedResetRetriesRecoverOnlySameCommand() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.openLegacy()
        let legacy = try f.capture()
        try service.forgetAll()
        let id = UUID()
        // Injected observer failure leaves a reserved transition. Only the same ID may resume it.
        let failPrepared = GenerationInitializationFailure(point: .afterStorePrepared)
        XCTAssertThrowsError(try f.initialize(legacy, id: id, observer: failPrepared))
        let resumed = try f.initialize(legacy, id: id)
        XCTAssertThrowsError(try f.initialize(legacy, id: UUID()))
        let resumedService = try f.open(resumed)
        try resumedService.forgetAll()

        let committedID = UUID()
        let failReceipt = GenerationInitializationFailure(point: .afterCommit)
        XCTAssertThrowsError(try f.initialize(resumed, id: committedID, observer: failReceipt))
        let committed = try f.initialize(resumed, id: committedID)
        XCTAssertNotEqual(committed.identifier, resumed.identifier)
        XCTAssertThrowsError(try f.initialize(resumed, id: UUID()))
    }

    func testReservationOnlyRetryResumesOnlyForSameCommand() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.openLegacy()
        defer { try? service.close() }
        let legacy = try f.capture()
        try service.forgetAll()

        let resetID = UUID()
        XCTAssertThrowsError(try f.initialize(legacy, id: resetID,
            observer: GenerationInitializationFailure(point: .afterReservation)))
        let resumed = try f.initialize(legacy, id: resetID)
        XCTAssertThrowsError(try f.initialize(legacy, id: UUID()))
        XCTAssertEqual(try f.initialize(legacy, id: resetID), resumed)
    }

    func testAtomicStateReplaceThatCommitsThenThrowsRecoversSameGeneration() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.openLegacy()
        defer { try? service.close() }
        let legacy = try f.capture()
        try service.forgetAll()

        let resetID = UUID()
        // The fake persists the replacement and then reports failure, modeling a lost receipt.
        f.adapters.armCommittedReplaceFailure()
        XCTAssertThrowsError(try f.initialize(legacy, id: resetID))
        let recovered = try f.initialize(legacy, id: resetID)
        XCTAssertEqual(try f.initialize(legacy, id: resetID), recovered)
        XCTAssertThrowsError(try f.initialize(legacy, id: UUID()))
        XCTAssertEqual(f.adapters.addedItems().filter {
            $0.service == recovered.namespace.databaseKeyService && $0.account == "database-key"
        }.count, 1)
    }

    func testAmbiguousActivePointerReplaceDoesNotDuplicateCommittedGeneration() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let legacyService = try f.openLegacy()
        defer { try? legacyService.close() }
        let legacy = try f.capture()
        try legacyService.forgetAll()

        let firstID = UUID()
        let generation2 = try f.initialize(legacy, id: firstID)
        let generation2Service = try f.open(generation2)
        defer { try? generation2Service.close() }
        try generation2Service.forgetAll()

        let secondID = UUID()
        // One replacement records the reservation; the following active-pointer replacement
        // is persisted but reports failure, so recovery must honor that exact command ID.
        f.adapters.armCommittedReplaceFailure(afterSuccessfulReplaces: 1)
        XCTAssertThrowsError(try f.initialize(generation2, id: secondID))
        let generation3 = try f.initialize(generation2, id: secondID)
        XCTAssertEqual(try f.initialize(generation2, id: secondID), generation3)
        XCTAssertThrowsError(try f.initialize(generation2, id: UUID()))
        XCTAssertEqual(try f.capture(), generation3)
        XCTAssertEqual(f.adapters.addedItems().filter {
            $0.service == generation3.namespace.databaseKeyService && $0.account == "database-key"
        }.count, 1)
    }

    func testOrdinaryCaptureAndOpenCannotExposeOrCreatePendingGeneration() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.openLegacy()
        defer { try? service.close() }
        let legacy = try f.capture()
        try service.forgetAll()

        XCTAssertThrowsError(try f.initialize(legacy, id: UUID(),
            observer: GenerationInitializationFailure(point: .afterReservation)))
        let keyAddsBeforeOrdinaryAccess = f.adapters.addedItems().filter {
            $0.account == "database-key"
        }.count
        let ordinaryCapture: MemoryStoreGeneration?
        do {
            ordinaryCapture = try f.capture()
        } catch {
            ordinaryCapture = nil
        }
        if let ordinaryCapture {
            XCTAssertEqual(ordinaryCapture, legacy,
                           "ordinary capture may expose only the prior generation while reset is pending")
            XCTAssertThrowsError(try f.open(ordinaryCapture),
                                 "ordinary open must not recreate or expose either generation")
        }
        XCTAssertEqual(f.adapters.addedItems().filter { $0.account == "database-key" }.count,
                       keyAddsBeforeOrdinaryAccess)
    }

    func testFailedFirstGenerationPreparationResumesSameIDAndProtectsOldGeneration() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let legacyService = try f.openLegacy()
        defer { try? legacyService.close() }
        let legacy = try f.capture()
        try remember(legacyService, "fixture legacy remains isolated")
        let legacyDatabase = legacy.root.appendingPathComponent("memory.sqlite")
        try legacyService.forgetAll()
        let keyCountAfterForget = f.adapters.addedItems().filter { $0.account == "database-key" }.count
        let legacyBytesAfterForget = try? Data(contentsOf: legacyDatabase)

        let resetID = UUID()
        f.adapters.armRandomFailure()
        XCTAssertThrowsError(try f.initialize(legacy, id: resetID),
                             "first-generation key preparation should fail once")
        XCTAssertEqual(f.adapters.addedItems().filter { $0.account == "database-key" }.count,
                       keyCountAfterForget)
        let generationsRoot = legacy.parentRoot.appendingPathComponent("Generations", isDirectory: true)
        let generationDirectories = try FileManager.default.contentsOfDirectory(
            at: generationsRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(generationDirectories.count, 1)
        let reservedRoot = try XCTUnwrap(generationDirectories.first)
        let lifecycleLock = reservedRoot.appendingPathComponent(".vault-lifecycle.lock")
        var rootBeforeRetry = stat()
        var lockBeforeRetry = stat()
        XCTAssertEqual(lstat(reservedRoot.path, &rootBeforeRetry), 0,
                       "reservation must retain its generation directory after preparation fails")
        XCTAssertEqual(lstat(lifecycleLock.path, &lockBeforeRetry), 0,
                       "reservation must retain its permanent lifecycle lock")
        XCTAssertThrowsError(try f.open(legacy),
                             "ordinary open must not recreate the forgotten generation during reservation")
        XCTAssertEqual(f.adapters.addedItems().filter { $0.account == "database-key" }.count,
                       keyCountAfterForget)
        XCTAssertEqual(try? Data(contentsOf: legacyDatabase), legacyBytesAfterForget,
                       "failed preparation must not rewrite prior-generation artifacts")

        let tamperedRoot = MemoryStoreGeneration(identifier: legacy.identifier,
            parentRoot: legacy.parentRoot,
            root: f.parent.appendingPathComponent("pending-tamper", isDirectory: true),
            namespace: legacy.namespace, baseNamespace: legacy.baseNamespace)
        XCTAssertThrowsError(try f.initialize(tamperedRoot, id: resetID),
                             "pending same-ID replay must validate its original root")
        let tamperedNamespace = MemoryStoreGeneration(identifier: legacy.identifier,
            parentRoot: legacy.parentRoot, root: legacy.root,
            namespace: .testing("pending-tampered-namespace"),
            baseNamespace: legacy.baseNamespace)
        XCTAssertThrowsError(try f.initialize(tamperedNamespace, id: resetID),
                             "pending same-ID replay must validate its original namespace")

        let resumed = try f.initialize(legacy, id: resetID)
        var rootAfterRetry = stat()
        var lockAfterRetry = stat()
        XCTAssertEqual(lstat(resumed.root.path, &rootAfterRetry), 0)
        XCTAssertEqual(lstat(lifecycleLock.path, &lockAfterRetry), 0)
        XCTAssertEqual(rootAfterRetry.st_ino, rootBeforeRetry.st_ino,
                       "same-ID retry must reuse the reserved generation directory")
        XCTAssertEqual(lockAfterRetry.st_ino, lockBeforeRetry.st_ino,
                       "same-ID retry must keep the lifecycle lock inode stable")
        XCTAssertThrowsError(try f.initialize(legacy, id: UUID()))
        XCTAssertNotEqual(resumed.identifier, legacy.identifier)
        XCTAssertTrue(f.adapters.contains(databaseKey(resumed)))
    }

    func testDefaultGenerationAdapterAndTransitionLockWorkWithSyntheticKeychain() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.openLegacy()
        defer { try? service.close() }
        let legacy = try XCTUnwrap(MemoryStoreFactory.captureGenerationForTesting(enabled: true,
            root: f.root, client: f.adapters, namespace: f.namespace))
        try service.forgetAll()

        let fresh = try XCTUnwrap(MemoryStoreFactory.initializeAfterForgetForTesting(enabled: true,
            expectedGeneration: legacy, commandID: UUID(), client: f.adapters, random: f.adapters))
        let captured = try XCTUnwrap(MemoryStoreFactory.captureGenerationForTesting(enabled: true,
            root: f.root, client: f.adapters, namespace: f.namespace))
        XCTAssertEqual(captured, fresh)
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            f.root.appendingPathComponent(".generation-transition.lock").path))
    }

    func testCompetingResetIDsSerializeAndPublishAtMostOneGeneration() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.openLegacy()
        let legacy = try f.capture()
        try service.forgetAll()
        let barrier = GenerationInitializationBarrier(blocking: .afterReservation)
        let first = GenerationResultBox<MemoryStoreGeneration>()
        let second = GenerationResultBox<MemoryStoreGeneration>()
        let firstDone = DispatchSemaphore(value: 0)
        let secondDone = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let id1 = UUID(), id2 = UUID()

        DispatchQueue.global().async {
            do { first.set(.success(try f.initialize(legacy, id: id1, observer: barrier))) }
            catch { first.set(.failure(error)) }
            firstDone.signal()
        }
        XCTAssertEqual(barrier.waitUntilEntered(), .success)
        DispatchQueue.global().async {
            secondStarted.signal()
            do { second.set(.success(try f.initialize(legacy, id: id2))) }
            catch { second.set(.failure(error)) }
            secondDone.signal()
        }
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondDone.wait(timeout: .now() + 0.05), .timedOut,
                       "the transition lock must serialize competing reset IDs")
        barrier.release()
        XCTAssertEqual(firstDone.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(secondDone.wait(timeout: .now() + 3), .success)
        XCTAssertNotNil(first.get()?.successValue)
        XCTAssertNotNil(second.get()?.failureValue)
    }

    func testRetainedOldServiceAndRecoveryCannotEraseFreshGenerationData() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let oldService = try f.openLegacy()
        defer { try? oldService.close() }
        let oldGeneration = try f.capture()
        try remember(oldService, "fixture first generation fact")
        let oldVaultItem = VaultItemID()
        try oldService.storeVaultSecret(try VaultSecretValue("fictional old vault"),
                                        for: oldVaultItem, field: .cardNumber)
        let draft = try vaultDraft()
        let oldLifecycle = try oldService.makeVaultFillAuthorizationLifecycle(draft: draft,
            currentRuntime: { VaultFillRuntimeSnapshot(
                binding: VaultFillCurrentBinding(draft: draft), status: .active) },
            verifier: GenerationTestVerifier(), now: { draft.createdAtWall.addingTimeInterval(1) },
            monotonicNow: { draft.createdAtMonotonic + 1 })
        let oldPermit = try oldLifecycle.authorize(VaultFillApprovalReceipt(
            challenge: VaultFillApprovalChallenge(draft: draft), proof: Data([0x44])))
        try oldService.forgetAll()
        let fresh = try f.initialize(oldGeneration, id: UUID())
        let newService = try f.open(fresh)
        defer { try? newService.close() }
        try remember(newService, "fixture second generation fact")
        let itemID = VaultItemID()
        try newService.storeVaultSecret(try VaultSecretValue("fictional vault fixture"),
                                        for: itemID, field: .cardNumber)
        let freshFile = fresh.root.appendingPathComponent("memory.sqlite")

        XCTAssertThrowsError(try remember(oldService, "fixture stale old write"))
        XCTAssertThrowsError(try oldService.withVaultSecret(for: itemID, field: .cardNumber) { _ in
            XCTFail("forgotten generation must not expose a copied vault value")
        })
        XCTAssertThrowsError(try oldPermit.consume())
        try oldService.forgetAll()
        _ = try MemoryStoreFactory.recoverGenerationForTesting(enabled: true,
            generation: oldGeneration, client: f.adapters, stateStore: f.adapters)

        XCTAssertTrue(f.adapters.contains(databaseKey(fresh)))
        XCTAssertTrue(f.adapters.contains(vaultItem(itemID, .cardNumber, generation: fresh)))
        XCTAssertEqual(try newService.writer.list(context: context()).map(\.body),
                       ["fixture second generation fact"])
        XCTAssertNotNil(try Data(contentsOf: freshFile))
        XCTAssertTrue(f.adapters.addedItems().contains { $0.service == fresh.namespace.vaultService })
    }

    func testStaleExpectedGenerationCannotResetOrRepointCurrentGeneration() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let legacyService = try f.openLegacy()
        let legacy = try f.capture()
        try legacyService.forgetAll()
        let firstResetID = UUID()
        let generation2 = try f.initialize(legacy, id: firstResetID)
        let generation2Service = try f.open(generation2)
        defer { try? generation2Service.close() }
        try remember(generation2Service, "fixture generation two")
        try generation2Service.forgetAll()

        let keyAddsBeforeReboundID = f.adapters.addedItems().filter {
            $0.account == "database-key"
        }.count
        XCTAssertThrowsError(try f.initialize(generation2, id: firstResetID),
                             "a reset ID accepted for G1 cannot be rebound to G2")
        XCTAssertEqual(f.adapters.addedItems().filter { $0.account == "database-key" }.count,
                       keyAddsBeforeReboundID)

        let secondResetID = UUID()
        let generation3 = try f.initialize(generation2, id: secondResetID)
        let generation3Service = try f.open(generation3)
        defer { try? generation3Service.close() }
        try remember(generation3Service, "fixture generation three")
        XCTAssertThrowsError(try f.initialize(legacy, id: firstResetID))
        XCTAssertEqual(try f.capture(), generation3)
        XCTAssertTrue(f.adapters.contains(databaseKey(generation3)))
        XCTAssertFalse(f.adapters.deletedItems().contains(databaseKey(generation3)))
        XCTAssertEqual(try generation3Service.writer.list(context: context()).map(\.body),
                       ["fixture generation three"])
    }
}

private struct GenerationInitializationFailure: MemoryGenerationInitializationObserver {
    let point: MemoryGenerationInitializationPoint
    init(point: MemoryGenerationInitializationPoint) { self.point = point }
    func reached(_ candidate: MemoryGenerationInitializationPoint) throws {
        let matches: Bool
        switch (point, candidate) {
        case (.afterReservation, .afterReservation), (.afterStorePrepared, .afterStorePrepared),
             (.beforeCommit, .beforeCommit), (.afterCommit, .afterCommit): matches = true
        default: matches = false
        }
        if matches { throw MemoryGenerationFixtureError.injected }
    }
}

private struct GenerationTestVerifier: VaultFillTrustedApprovalVerifier {
    func verifyOwnerApproval(_ receipt: VaultFillApprovalReceipt,
                             for challenge: VaultFillApprovalChallenge) throws {}
    func verifyFreshPhoneBiometric(_ receipt: VaultFillApprovalReceipt,
                                   for challenge: VaultFillApprovalChallenge) throws {}
}

private extension Result {
    var successValue: Success? { try? get() }
    var failureValue: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}

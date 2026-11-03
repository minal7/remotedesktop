import Darwin
import Foundation
import XCTest
@testable import MemoryStoreKit

private final class BindingInitializationKeys: KeychainClient, MemoryKeyRandomSource, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ExactKeychainItem: Data] = [:]
    private var readCalls = 0
    private var writeCalls = 0
    private var counter: UInt8 = 0

    func add(_ item: ExactKeychainItem, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard values[item] == nil else { throw KeychainBoundaryError.duplicateItem }
        values[item] = data
        writeCalls += 1
    }

    func copy(_ item: ExactKeychainItem) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        readCalls += 1
        guard let data = values[item] else { throw KeychainBoundaryError.missingItem }
        return data
    }

    func delete(_ item: ExactKeychainItem) throws {
        lock.lock(); defer { lock.unlock() }
        guard values.removeValue(forKey: item) != nil else { throw KeychainBoundaryError.missingItem }
        writeCalls += 1
    }

    func replace(_ item: ExactKeychainItem, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard values[item] != nil else { throw KeychainBoundaryError.missingItem }
        values[item] = data
        writeCalls += 1
    }

    func bytes(count: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        counter &+= 1
        return Data(repeating: counter, count: count)
    }

    func callCounts() -> (reads: Int, writes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (readCalls, writeCalls)
    }

    func contains(_ item: ExactKeychainItem) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return values[item] != nil
    }
}

private struct BindingInitializationFailure: Error {}

private struct FailAtGenerationInitialization: MemoryGenerationInitializationObserver {
    let target: MemoryGenerationInitializationPoint
    func reached(_ point: MemoryGenerationInitializationPoint) throws {
        switch (target, point) {
        case (.afterReservation, .afterReservation), (.afterStorePrepared, .afterStorePrepared),
             (.beforeCommit, .beforeCommit), (.afterCommit, .afterCommit):
            throw BindingInitializationFailure()
        default: break
        }
    }
}

private final class ReplaceBoundRootBeforeUse: MemoryGenerationTransitionLock, @unchecked Sendable {
    private let root: URL
    private let movedRoot: URL
    private var didReplace = false

    init(root: URL, movedRoot: URL) {
        self.root = root
        self.movedRoot = movedRoot
    }

    func withExclusive<T>(at parentRoot: URL, _ operation: () throws -> T) throws -> T {
        if !didReplace {
            didReplace = true
            try FileManager.default.moveItem(at: root, to: movedRoot)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        return try operation()
    }
}

final class MemoryGenerationBindingInitializationTests: XCTestCase {
    private struct Fixture {
        let parent: URL
        let root: URL
        let namespace: KeychainNamespace
        let keys: BindingInitializationKeys

        func cleanup() { try? FileManager.default.removeItem(at: parent) }

        func openLegacy() throws -> PersonalMemoryService {
            try XCTUnwrap(MemoryStoreFactory.openForTesting(enabled: true, root: root,
                client: keys, random: keys, namespace: namespace, authorize: { _ in true },
                isTaskActive: { _, _ in true },
                policy: { OwnerMemoryPolicy(featureEnabled: true) }))
        }

        func capture() throws -> MemoryStoreBinding {
            try XCTUnwrap(MemoryStoreFactory.captureBindingForTesting(enabled: true,
                root: root, client: keys, namespace: namespace))
        }

        func initialize(_ binding: MemoryStoreBinding, command: UUID,
                        observer: (any MemoryGenerationInitializationObserver)? = nil,
                        transitionLock: (any MemoryGenerationTransitionLock)? = nil) throws
            -> MemoryStoreBinding {
            guard let binding = try MemoryStoreFactory.initializeAfterForgetBindingForTesting(enabled: true,
                expectedBinding: binding, commandID: command, client: keys, random: keys,
                transitionLock: transitionLock, observer: observer) else {
                throw BindingInitializationFailure()
            }
            return binding
        }

        func open(_ binding: MemoryStoreBinding) throws -> PersonalMemoryService {
            try XCTUnwrap(MemoryStoreFactory.openBoundGenerationForTesting(enabled: true,
                binding: binding, client: keys, random: keys, authorize: { _ in true },
                isTaskActive: { _, _ in true },
                policy: { OwnerMemoryPolicy(featureEnabled: true) }))
        }
    }

    private func fixture() throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryGenerationBindingInit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return Fixture(parent: parent,
            root: parent.appendingPathComponent("memory", isDirectory: true),
            namespace: .testing("generation-binding-\(UUID().uuidString)"),
            keys: BindingInitializationKeys())
    }

    func testDisabledBoundInitializationReturnsBeforeFakeKeychainAccess() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.openLegacy()
        let source = try f.capture()
        let before = f.keys.callCounts()
        let result = try MemoryStoreFactory.initializeAfterForgetBindingForTesting(enabled: false,
            expectedBinding: source, commandID: UUID(), client: f.keys, random: f.keys)
        let productionResult = try MemoryStoreFactory.initializeAfterForgetProduction(
            expectedBinding: source, commandID: UUID())
        XCTAssertNil(result)
        XCTAssertNil(productionResult)
        XCTAssertEqual(f.keys.callCounts().reads, before.reads)
        XCTAssertEqual(f.keys.callCounts().writes, before.writes)
        try service.close()
    }

    func testExplicitForgetThenSameCommandRetryReturnsSameNewBinding() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.openLegacy()
        let source = try f.capture()
        XCTAssertThrowsError(try f.initialize(source, command: UUID()),
            "initialization without completed Forget must fail")
        try service.forgetAll()

        let command = UUID()
        let first = try f.initialize(source, command: command)
        let retry = try f.initialize(source, command: command)
        XCTAssertEqual(retry, first)
        XCTAssertNotEqual(first.reference, source.reference)
        let opened = try f.open(first)
        XCTAssertTrue(try opened.writer.list(context: Self.context()).isEmpty)
        XCTAssertThrowsError(try f.initialize(source, command: UUID()))
        try opened.close()
    }

    func testTamperedBoundDescriptorCannotInitializeWithMatchingReferenceFields() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.openLegacy()
        let source = try f.capture()
        try service.forgetAll()
        let altered = MemoryStoreGeneration(identifier: source.generation.identifier,
            parentRoot: source.generation.parentRoot,
            root: f.parent.appendingPathComponent("different-root", isDirectory: true),
            namespace: source.generation.namespace,
            baseNamespace: source.generation.baseNamespace)
        let forgedCorrelation = MemoryStoreBinding(generation: altered,
            device: source.device, inode: source.inode)
        XCTAssertThrowsError(try f.initialize(forgedCorrelation, command: UUID()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: altered.root.path))
    }

    func testReservationRetryStaysBoundToOriginalBindingAndCommand() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.openLegacy()
        let source = try f.capture()
        try service.forgetAll()
        let command = UUID()

        XCTAssertThrowsError(try f.initialize(source, command: command,
            observer: FailAtGenerationInitialization(target: .afterReservation)))
        let resumed = try f.initialize(source, command: command)
        XCTAssertEqual(try f.initialize(source, command: command), resumed)
        XCTAssertThrowsError(try f.initialize(source, command: UUID()))
    }

    func testRootReplacementAtSamePathRejectsBeforeLockOrKeychainMutation() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.openLegacy()
        let binding = try f.capture()
        try service.close()

        let moved = f.parent.appendingPathComponent("original-root", isDirectory: true)
        try FileManager.default.moveItem(at: f.root, to: moved)
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let before = f.keys.callCounts()
        XCTAssertThrowsError(try f.initialize(binding, command: UUID()))
        XCTAssertEqual(f.keys.callCounts().reads, before.reads)
        XCTAssertEqual(f.keys.callCounts().writes, before.writes)
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            f.root.appendingPathComponent(".generation-transition.lock").path))
    }

    func testRootReplacedAfterTransitionLeaseAcquisitionIsRevalidatedBeforeKeychainAccess() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.openLegacy()
        let binding = try f.capture()
        try service.close()
        let moved = f.parent.appendingPathComponent("root-moved-during-transition", isDirectory: true)
        let replacingLock = ReplaceBoundRootBeforeUse(root: f.root, movedRoot: moved)
        let before = f.keys.callCounts()

        XCTAssertThrowsError(try f.initialize(binding, command: UUID(), transitionLock: replacingLock))
        XCTAssertEqual(f.keys.callCounts().reads, before.reads)
        XCTAssertEqual(f.keys.callCounts().writes, before.writes)
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            f.root.appendingPathComponent(".generation-transition.lock").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            f.root.appendingPathComponent("memory.sqlite").path))
    }

    func testLostCommitReceiptRetryUsesItsCommittedTargetWithoutFollowingLaterGeneration() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let sourceService = try f.openLegacy()
        let source = try f.capture()
        try sourceService.forgetAll()

        let firstCommand = UUID()
        XCTAssertThrowsError(try f.initialize(source, command: firstCommand,
            observer: FailAtGenerationInitialization(target: .afterCommit)))
        let first = try f.initialize(source, command: firstCommand)
        XCTAssertEqual(try f.initialize(source, command: firstCommand), first)

        let firstService = try f.open(first)
        try firstService.forgetAll()
        let secondCommand = UUID()
        let second = try f.initialize(first, command: secondCommand)
        XCTAssertNotEqual(first.reference, second.reference)
        XCTAssertThrowsError(try f.initialize(source, command: firstCommand),
            "a replay of the older command must not follow the newly active pointer")
        XCTAssertEqual(try f.capture().reference, second.reference)
    }

    func testCommittedTargetForgottenBeforeRetryIsNotReturnedAsAvailable() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let sourceService = try f.openLegacy()
        let source = try f.capture()
        try sourceService.forgetAll()

        let command = UUID()
        let target = try f.initialize(source, command: command)
        let targetService = try f.open(target)
        try targetService.forgetAll()

        let beforeRetry = f.keys.callCounts()
        XCTAssertThrowsError(try f.initialize(source, command: command),
            "the retained transition receipt cannot advertise a generation that was later forgotten")
        XCTAssertEqual(f.keys.callCounts().writes, beforeRetry.writes,
                       "rejecting a forgotten target must not recreate its key")
    }

    func testCommittedRetryRejectsTargetWithMissingDatabaseWithoutRecreatingIt() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let sourceService = try f.openLegacy()
        let source = try f.capture()
        try sourceService.forgetAll()

        let command = UUID()
        let target = try f.initialize(source, command: command)
        let database = target.generation.root.appendingPathComponent("memory.sqlite")
        try FileManager.default.removeItem(at: database)
        let before = f.keys.callCounts()

        XCTAssertThrowsError(try f.initialize(source, command: command),
            "committed replay must not recreate a missing target database")
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        XCTAssertEqual(f.keys.callCounts().writes, before.writes)
    }

    func testCommittedRetryRejectsTargetWithMalformedDatabaseKeyWithoutReplacingIt() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let sourceService = try f.openLegacy()
        let source = try f.capture()
        try sourceService.forgetAll()

        let command = UUID()
        let target = try f.initialize(source, command: command)
        let key = ExactKeychainItem(service: target.generation.namespace.databaseKeyService,
            account: "database-key", protection: .deviceOnlyWhenUnlocked)
        try f.keys.replace(key, data: Data(repeating: 0x2a, count: 31))
        let before = f.keys.callCounts()

        XCTAssertThrowsError(try f.initialize(source, command: command),
            "committed replay must reject a malformed key instead of treating it as available")
        XCTAssertEqual(f.keys.callCounts().writes, before.writes)
        XCTAssertEqual(try f.keys.copy(key).count, 31,
            "availability validation must not replace or delete the exact target key")
    }

    private static func context() -> OwnerMemoryContext {
        OwnerMemoryContext(ownerID: String(repeating: "b", count: 64), sessionID: "generation-binding")
    }
}

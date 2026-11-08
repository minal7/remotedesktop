import Darwin
import Foundation
import XCTest
@testable import MemoryStoreKit

private final class BindingFixtureKeys: KeychainClient, MemoryKeyRandomSource, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ExactKeychainItem: Data] = [:]
    private var copies = 0

    func add(_ item: ExactKeychainItem, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard values[item] == nil else { throw KeychainBoundaryError.duplicateItem }
        values[item] = data
    }
    func copy(_ item: ExactKeychainItem) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        copies += 1
        guard let value = values[item] else { throw KeychainBoundaryError.missingItem }
        return value
    }
    func delete(_ item: ExactKeychainItem) throws {
        lock.lock(); defer { lock.unlock() }
        guard values.removeValue(forKey: item) != nil else { throw KeychainBoundaryError.missingItem }
    }
    func replace(_ item: ExactKeychainItem, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard values[item] != nil else { throw KeychainBoundaryError.missingItem }
        values[item] = data
    }
    func bytes(count: Int) throws -> Data { Data(repeating: 0x5a, count: count) }
    func copyCount() -> Int { lock.lock(); defer { lock.unlock() }; return copies }
    func contains(_ item: ExactKeychainItem) -> Bool {
        lock.lock(); defer { lock.unlock() }; return values[item] != nil
    }
}

final class MemoryStoreBindingTests: XCTestCase {
    private struct Fixture {
        let parent: URL
        let root: URL
        let namespace: KeychainNamespace
        let keys: BindingFixtureKeys
        func cleanup() { try? FileManager.default.removeItem(at: parent) }
        func open() throws -> PersonalMemoryService {
            try XCTUnwrap(MemoryStoreFactory.openForTesting(enabled: true, root: root,
                client: keys, random: keys, namespace: namespace, authorize: { _ in true },
                isTaskActive: { _, _ in true },
                policy: { OwnerMemoryPolicy(featureEnabled: true) }))
        }
        func capture() throws -> MemoryStoreBinding {
            let binding = try MemoryStoreFactory.captureBindingForTesting(enabled: true,
                root: root, client: keys, namespace: namespace)
            return try XCTUnwrap(binding)
        }
    }

    private func fixture(_ suffix: String = UUID().uuidString) throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryBinding-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let root = parent.appendingPathComponent("store", isDirectory: true)
        return Fixture(parent: parent, root: root,
            namespace: .testing("binding-\(suffix)"), keys: BindingFixtureKeys())
    }

    func testDisabledBindingOperationsReturnBeforeKeychainAccess() throws {
        let f = try fixture()
        defer { f.cleanup() }
        XCTAssertNil(try MemoryStoreFactory.captureBindingForTesting(enabled: false,
            root: f.root.appendingPathComponent("missing"), client: f.keys,
            namespace: f.namespace))
        let generation = MemoryStoreGeneration.legacy(root: f.parent, namespace: f.namespace)
        var info = stat()
        XCTAssertEqual(f.parent.path.withCString { lstat($0, &info) }, 0)
        let binding = MemoryStoreBinding(generation: generation,
            device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        XCTAssertNil(try MemoryStoreFactory.openBoundGenerationForTesting(enabled: false,
            binding: binding, client: f.keys, random: f.keys, authorize: { _ in false },
            isTaskActive: { _, _ in false }, policy: { OwnerMemoryPolicy(featureEnabled: false) }))
        XCTAssertFalse(try MemoryStoreFactory.recoverBoundGenerationForTesting(enabled: false,
            binding: binding, client: f.keys))
        XCTAssertEqual(f.keys.copyCount(), 0)
    }

    func testBindingReferenceIsStableAcrossCaptureAndRestart() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.open()
        defer { try? service.close() }
        let first = try f.capture()
        let afterRestart = try f.capture()
        XCTAssertEqual(first.reference, afterRestart.reference)
        XCTAssertEqual(first.reference.count, 64)
        XCTAssertTrue(first.reference.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testBindingChangesAfterGenerationTransitionAndAcrossRootNamespace() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.open()
        defer { try? service.close() }
        let legacyBinding = try f.capture()
        let legacy = legacyBinding.generation
        try service.forgetAll()
        let fresh = try XCTUnwrap(MemoryStoreFactory.initializeAfterForgetForTesting(enabled: true,
            expectedGeneration: legacy, commandID: UUID(), client: f.keys, random: f.keys))
        let freshBinding = try f.capture()
        XCTAssertNotEqual(legacyBinding.reference, freshBinding.reference)
        XCTAssertEqual(fresh.identifier, freshBinding.generation.identifier)

        let other = try fixture()
        defer { other.cleanup() }
        let otherService = try other.open()
        defer { try? otherService.close() }
        XCTAssertNotEqual(legacyBinding.reference, try other.capture().reference)
    }

    func testBindingReferenceChangesForSameRootWithDifferentNamespace() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.open()
        defer { try? service.close() }
        let first = try f.capture()
        let otherNamespace = KeychainNamespace.testing("binding-independent-namespace")
        let second = try XCTUnwrap(MemoryStoreFactory.captureBindingForTesting(enabled: true,
            root: f.root, client: f.keys, namespace: otherNamespace))
        XCTAssertNotEqual(first.reference, second.reference)
        XCTAssertEqual(first.generation.parentRoot, second.generation.parentRoot)
    }

    func testBindingReferenceChangesWhenRootIdentityIsReplacedAtSamePath() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.open()
        try service.close()
        let before = try f.capture()
        let moved = f.parent.appendingPathComponent("old-root", isDirectory: true)
        try FileManager.default.moveItem(at: f.root, to: moved)
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let after = try f.capture()
        XCTAssertEqual(before.generation.parentRoot.path, after.generation.parentRoot.path)
        XCTAssertNotEqual(before.reference, after.reference)
    }

    func testStaleBoundOpenRejectsAfterForgetAndBoundRecoveryStaysOnCapturedRoot() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let oldService = try f.open()
        let oldBinding = try f.capture()
        try oldService.forgetAll()
        let fresh = try XCTUnwrap(MemoryStoreFactory.initializeAfterForgetForTesting(enabled: true,
            expectedGeneration: oldBinding.generation, commandID: UUID(), client: f.keys, random: f.keys))
        XCTAssertThrowsError(try MemoryStoreFactory.openBoundGenerationForTesting(enabled: true,
            binding: oldBinding, client: f.keys, random: f.keys, authorize: { _ in true },
            isTaskActive: { _, _ in true }, policy: { OwnerMemoryPolicy(featureEnabled: true) }))
        let recoveryResult = try MemoryStoreFactory.recoverBoundGenerationForTesting(enabled: true,
            binding: oldBinding, client: f.keys)
        XCTAssertTrue(recoveryResult)
        let freshKey = try f.keys.copy(ExactKeychainItem(service: fresh.namespace.databaseKeyService,
            account: "database-key", protection: .deviceOnlyWhenUnlocked))
        XCTAssertEqual(freshKey.count, 32)
    }

    func testCaptureAfterCompletedForgetNeedsNoDatabaseKey() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let service = try f.open()
        defer { try? service.close() }
        let before = try f.capture()
        try service.forgetAll()
        let key = ExactKeychainItem(service: before.generation.namespace.databaseKeyService,
                                    account: "database-key", protection: .deviceOnlyWhenUnlocked)
        XCTAssertFalse(f.keys.contains(key))
        let copiesBefore = f.keys.copyCount()
        let after = try f.capture()
        XCTAssertEqual(before.reference, after.reference)
        XCTAssertEqual(f.keys.copyCount(), copiesBefore + 1,
                       "capture reads only generation state, not the deleted database key")
    }
}

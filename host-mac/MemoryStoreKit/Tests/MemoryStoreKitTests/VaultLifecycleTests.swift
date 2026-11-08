import Darwin
import Foundation
import XCTest
@testable import MemoryStoreKit

private enum VaultLifecycleTestError: Error { case injected }

private final class LifecycleKeychain: KeychainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ExactKeychainItem: Data] = [:]
    private var deleteFailure: ExactKeychainItem?
    private var addFailure: ExactKeychainItem?
    private var blockedAdd: ExactKeychainItem?
    private var blockedDelete: ExactKeychainItem?
    private var blockedCopy: ExactKeychainItem?
    private var addGate: (DispatchSemaphore, DispatchSemaphore)?
    private var deleteGate: (DispatchSemaphore, DispatchSemaphore)?
    private var copyGate: (DispatchSemaphore, DispatchSemaphore)?
    private var deletedItems: [ExactKeychainItem] = []
    private var addedItems: [ExactKeychainItem] = []

    func add(_ item: ExactKeychainItem, data: Data) throws {
        let gate = withLock { () -> (DispatchSemaphore, DispatchSemaphore)? in
            guard blockedAdd == item else { return nil }
            return addGate
        }
        if let gate { gate.0.signal(); _ = gate.1.wait(timeout: .now() + 5) }
        try withLock {
            if addFailure == item { addFailure = nil; throw VaultLifecycleTestError.injected }
            guard values[item] == nil else { throw KeychainBoundaryError.duplicateItem }
            values[item] = data
            addedItems.append(item)
        }
    }

    func copy(_ item: ExactKeychainItem) throws -> Data {
        let gate = withLock { () -> (DispatchSemaphore, DispatchSemaphore)? in
            guard blockedCopy == item else { return nil }
            return copyGate
        }
        if let gate { gate.0.signal(); _ = gate.1.wait(timeout: .now() + 5) }
        return try withLock {
            guard let data = values[item] else { throw KeychainBoundaryError.missingItem }
            return data
        }
    }

    func delete(_ item: ExactKeychainItem) throws {
        let gate = withLock { () -> (DispatchSemaphore, DispatchSemaphore)? in
            guard blockedDelete == item else { return nil }
            return deleteGate
        }
        if let gate { gate.0.signal(); _ = gate.1.wait(timeout: .now() + 5) }
        try withLock {
            deletedItems.append(item)
            if deleteFailure == item { deleteFailure = nil; throw VaultLifecycleTestError.injected }
            guard values.removeValue(forKey: item) != nil else { throw KeychainBoundaryError.missingItem }
        }
    }

    func armAddFailure(_ item: ExactKeychainItem) { withLock { addFailure = item } }
    func armDeleteFailure(_ item: ExactKeychainItem) { withLock { deleteFailure = item } }
    func armDeleteBarrier(_ item: ExactKeychainItem) -> DispatchSemaphore {
        withLock {
            let gate = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
            blockedDelete = item; deleteGate = gate
            return gate.0
        }
    }
    func releaseDeleteBarrier() {
        withLock { deleteGate?.1.signal(); blockedDelete = nil; deleteGate = nil }
    }
    func armAddBarrier(_ item: ExactKeychainItem) -> DispatchSemaphore {
        withLock {
            let gate = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
            blockedAdd = item; addGate = gate
            return gate.0
        }
    }
    func releaseAddBarrier() { withLock { addGate?.1.signal(); blockedAdd = nil; addGate = nil } }
    func armCopyBarrier(_ item: ExactKeychainItem) -> DispatchSemaphore {
        withLock {
            let gate = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
            blockedCopy = item; copyGate = gate
            return gate.0
        }
    }
    func releaseCopyBarrier() { withLock { copyGate?.1.signal(); blockedCopy = nil; copyGate = nil } }
    func contains(_ item: ExactKeychainItem) -> Bool { withLock { values[item] != nil } }
    func deletes() -> [ExactKeychainItem] { withLock { deletedItems } }
    func additions() -> [ExactKeychainItem] { withLock { addedItems } }
    func seed(_ item: ExactKeychainItem, data: Data = Data("fixture".utf8)) { withLock { values[item] = data } }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

private struct LifecycleRandom: MemoryKeyRandomSource {
    func bytes(count: Int) throws -> Data { Data(repeating: 0x52, count: count) }
}

private final class LifecycleResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ value: String) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class LifecycleAuthorizationBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var first = true
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func authorize() -> Bool {
        lock.lock()
        let shouldWait = first
        first = false
        lock.unlock()
        if shouldWait { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        return true
    }
}

private final class LifecycleWriterOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var error: OwnerMemoryWriterError?
    func set(_ error: OwnerMemoryWriterError?) { lock.lock(); self.error = error; lock.unlock() }
    func get() -> OwnerMemoryWriterError? { lock.lock(); defer { lock.unlock() }; return error }
}

private actor LeaseCancellationGate {
    private var parked: CheckedContinuation<Void, Never>?
    private var ready: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            parked = continuation
            ready?.resume()
            ready = nil
        }
    }

    func waitUntilParked() async {
        if parked != nil { return }
        await withCheckedContinuation { ready = $0 }
    }

    func release() {
        parked?.resume()
        parked = nil
    }
}

final class VaultLifecycleTests: XCTestCase {
    private func fixture(_ client: LifecycleKeychain = LifecycleKeychain(),
                         namespace: KeychainNamespace = .testing(UUID().uuidString),
                         authorize: @escaping OwnerMemoryAuthorizer = { _ in true }) throws
        -> (PersonalMemoryService, LifecycleKeychain, URL, KeychainNamespace) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultLifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let root = parent.appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let service = try XCTUnwrap(MemoryStoreFactory.openForTesting(enabled: true, root: root,
            client: client, random: LifecycleRandom(), namespace: namespace,
            authorize: authorize, isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: true) }))
        return (service, client, root, namespace)
    }

    private func item(_ id: VaultItemID, _ field: VaultSecretField,
                      namespace: KeychainNamespace) -> ExactKeychainItem {
        ExactKeychainItem(service: namespace.vaultService, account: id.account(for: field),
                          protection: .userPresenceWhenUnlocked)
    }

    func testWholeForgetDeletesOnlyCatalogedNamespaceAndThenMemoryKey() throws {
        let namespace = KeychainNamespace.testing("whole-namespace-\(UUID().uuidString)")
        let (service, client, _, _) = try fixture(namespace: namespace)
        let id = VaultItemID()
        let retainedNamespace = KeychainNamespace.testing("retained-\(UUID().uuidString)")
        let retained = ExactKeychainItem(service: retainedNamespace.vaultService,
            account: id.account(for: .cardNumber), protection: .userPresenceWhenUnlocked)
        client.seed(retained)
        XCTAssertNoThrow(try service.storeVaultSecret(try VaultSecretValue("fictional card"),
            for: id, field: .cardNumber))
        XCTAssertNoThrow(try service.forgetAll())
        XCTAssertFalse(client.contains(item(id, .cardNumber, namespace: namespace)))
        XCTAssertTrue(client.contains(retained), "other exact service namespace must survive")
        XCTAssertTrue(client.deletes().allSatisfy { $0.service == namespace.vaultService
            || $0.service == namespace.databaseKeyService })
    }

    func testInventoryPrecedesSecretAddAndPartialAddRemainsForgettable() throws {
        let (service, client, _, namespace) = try fixture()
        let id = VaultItemID()
        let failedField = item(id, .cardExpiryMonth, namespace: namespace)
        client.armAddFailure(failedField)
        XCTAssertThrowsError(try service.storeVaultSecret(try VaultSecretValue("fictional month"),
            for: id, field: .cardExpiryMonth))
        XCTAssertNoThrow(try service.forgetAll())
        XCTAssertTrue(client.deletes().contains { $0.service == namespace.vaultService
            && $0.account == failedField.account },
            "the ID must be durably inventoried before Keychain add is attempted")
    }

    func testPartialDeleteCanResumeFromDurableInventoryAfterReopen() throws {
        let namespace = KeychainNamespace.testing("retry-\(UUID().uuidString)")
        let (first, client, root, _) = try fixture(namespace: namespace)
        let id = VaultItemID()
        for field in [VaultSecretField.cardNumber, .cardExpiryMonth] {
            XCTAssertNoThrow(try first.storeVaultSecret(try VaultSecretValue("fictional field"),
                for: id, field: field))
        }
        client.armDeleteFailure(item(id, .cardExpiryMonth, namespace: namespace))
        XCTAssertThrowsError(try first.forgetAll())
        try first.close()
        let reopened = try XCTUnwrap(MemoryStoreFactory.openForTesting(enabled: true, root: root,
            client: client, random: LifecycleRandom(), namespace: namespace,
            authorize: { _ in true }, isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: true) }))
        XCTAssertThrowsError(try reopened.writer.list(context: OwnerMemoryContext(
            ownerID: "fixture-owner", sessionID: "fixture-session")))
        XCTAssertNoThrow(try reopened.forgetAll())
        XCTAssertFalse(client.contains(item(id, .cardNumber, namespace: namespace)))
        XCTAssertFalse(client.contains(item(id, .cardExpiryMonth, namespace: namespace)))
    }

    func testConcurrentStoreAndForgetCannotLeaveAnUncatalogedSecret() throws {
        let namespace = KeychainNamespace.testing("concurrent-\(UUID().uuidString)")
        let (writer, client, root, _) = try fixture(namespace: namespace)
        let observer = try XCTUnwrap(MemoryStoreFactory.openForTesting(enabled: true, root: root,
            client: client, random: LifecycleRandom(), namespace: namespace,
            authorize: { _ in true }, isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: true) }))
        let id = VaultItemID()
        let secretItem = item(id, .phoneNumber, namespace: namespace)
        let addEntered = client.armAddBarrier(secretItem)
        let writeFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do { try writer.storeVaultSecret(try VaultSecretValue("fictional phone"), for: id, field: .phoneNumber) }
            catch { }
            writeFinished.signal()
        }
        XCTAssertEqual(addEntered.wait(timeout: .now() + 2), .success)
        let forgetResult = LifecycleResult()
        let forgetFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do { try observer.forgetAll(); forgetResult.set("done") }
            catch { forgetResult.set("failed") }
            forgetFinished.signal()
        }
        let deadline = DispatchTime.now() + .seconds(2)
        var fenced = false
        while DispatchTime.now() < deadline {
            do { _ = try observer.writer.list(context: OwnerMemoryContext(
                ownerID: "fixture-owner", sessionID: "fixture-session")) }
            catch { fenced = true; break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertTrue(fenced, "Forget must publish the durable fence before waiting for the lease")
        XCTAssertEqual(forgetFinished.wait(timeout: .now()), .timedOut)
        client.releaseAddBarrier()
        XCTAssertEqual(writeFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(forgetFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(forgetResult.get(), "done")
        XCTAssertFalse(client.contains(secretItem))
    }

    func testOtherServiceFenceDiscardsAnAlreadyAdmittedWriterResult() throws {
        let namespace = KeychainNamespace.testing("writer-fence-\(UUID().uuidString)")
        let barrier = LifecycleAuthorizationBarrier()
        let (writerService, client, root, _) = try fixture(namespace: namespace,
            authorize: { _ in barrier.authorize() })
        let forgetService = try XCTUnwrap(MemoryStoreFactory.openForTesting(enabled: true, root: root,
            client: client, random: LifecycleRandom(), namespace: namespace,
            authorize: { _ in true }, isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: true) }))
        let watcher = try XCTUnwrap(MemoryStoreFactory.openForTesting(enabled: true, root: root,
            client: client, random: LifecycleRandom(), namespace: namespace,
            authorize: { _ in true }, isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: true) }))
        let writerOutcome = LifecycleWriterOutcome()
        let writeFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                _ = try writerService.writer.remember(kind: .fact, text: "synthetic admitted write",
                    commandID: "admitted", context: OwnerMemoryContext(ownerID: "fixture-owner",
                        sessionID: "fixture-session"))
                writerOutcome.set(nil)
            } catch { writerOutcome.set(error as? OwnerMemoryWriterError) }
            writeFinished.signal()
        }
        XCTAssertEqual(barrier.entered.wait(timeout: .now() + 2), .success)
        let forgetResult = LifecycleResult()
        let forgetFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do { try forgetService.forgetAll(); forgetResult.set("done") }
            catch { forgetResult.set("failed") }
            forgetFinished.signal()
        }
        let deadline = DispatchTime.now() + .seconds(2)
        var durableFenceObserved = false
        while DispatchTime.now() < deadline {
            do { _ = try watcher.writer.list(context: OwnerMemoryContext(
                ownerID: "fixture-owner", sessionID: "fixture-session")) }
            catch OwnerMemoryWriterError.forgotten {
                durableFenceObserved = true
                break
            } catch { }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertTrue(durableFenceObserved)
        barrier.release.signal()
        XCTAssertEqual(writeFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(forgetFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(writerOutcome.get(), .forgotten,
            "An operation admitted before another service's durable fence cannot return success")
        XCTAssertEqual(forgetResult.get(), "done")
    }

    func testCopyRechecksPendingFenceBeforeEnteringScopedCallback() throws {
        let namespace = KeychainNamespace.testing("copy-fence-\(UUID().uuidString)")
        let (service, client, root, _) = try fixture(namespace: namespace)
        let observer = try XCTUnwrap(MemoryStoreFactory.openForTesting(enabled: true, root: root,
            client: client, random: LifecycleRandom(), namespace: namespace,
            authorize: { _ in true }, isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: true) }))
        let id = VaultItemID()
        let secretItem = item(id, .addressCity, namespace: namespace)
        XCTAssertNoThrow(try service.storeVaultSecret(try VaultSecretValue("fictional city"),
            for: id, field: .addressCity))
        let copyEntered = client.armCopyBarrier(secretItem)
        let callbackEntered = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let readFinished = DispatchSemaphore(value: 0)
        defer {
            client.releaseCopyBarrier()
            releaseCallback.signal()
        }
        DispatchQueue.global().async {
            try? service.withVaultSecret(for: id, field: .addressCity) { _ in
                callbackEntered.signal()
                _ = releaseCallback.wait(timeout: .now() + 5)
            }
            readFinished.signal()
        }
        XCTAssertEqual(copyEntered.wait(timeout: .now() + 2), .success)
        let forgetFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { try? service.forgetAll(); forgetFinished.signal() }
        let deadline = DispatchTime.now() + .seconds(2)
        var fenced = false
        while DispatchTime.now() < deadline {
            do { _ = try observer.writer.list(context: OwnerMemoryContext(
                ownerID: "fixture-owner", sessionID: "fixture-session")) }
            catch { fenced = true; break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertTrue(fenced)
        client.releaseCopyBarrier()
        releaseCallback.signal()
        XCTAssertEqual(readFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(callbackEntered.wait(timeout: .now()), .timedOut,
            "After the read finishes, a copy completing after the durable fence must not have entered the callback")
        XCTAssertEqual(forgetFinished.wait(timeout: .now() + 2), .success)
    }

    func testForgetWaitsForAnAlreadyEnteredScopedCallback() throws {
        let namespace = KeychainNamespace.testing("callback-drain-\(UUID().uuidString)")
        let (service, client, root, _) = try fixture(namespace: namespace)
        let observer = try XCTUnwrap(MemoryStoreFactory.openForTesting(enabled: true, root: root,
            client: client, random: LifecycleRandom(), namespace: namespace,
            authorize: { _ in true }, isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: true) }))
        let id = VaultItemID()
        XCTAssertNoThrow(try service.storeVaultSecret(try VaultSecretValue("fictional city"),
            for: id, field: .addressCity))
        let callbackEntered = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let readFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? service.withVaultSecret(for: id, field: .addressCity) { _ in
                callbackEntered.signal()
                _ = releaseCallback.wait(timeout: .now() + 5)
            }
            readFinished.signal()
        }
        XCTAssertEqual(callbackEntered.wait(timeout: .now() + 2), .success)
        let forgetFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { try? service.forgetAll(); forgetFinished.signal() }
        let deadline = DispatchTime.now() + .seconds(2)
        var fenced = false
        while DispatchTime.now() < deadline {
            do { _ = try observer.writer.list(context: OwnerMemoryContext(
                ownerID: "fixture-owner", sessionID: "fixture-session")) }
            catch { fenced = true; break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertTrue(fenced)
        XCTAssertEqual(forgetFinished.wait(timeout: .now()), .timedOut,
            "Forget must wait while an admitted scoped callback holds the lease")
        releaseCallback.signal()
        XCTAssertEqual(readFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(forgetFinished.wait(timeout: .now() + 2), .success)
    }

    func testForgetFromScopedCallbackRejectsBeforeFencingWriter() throws {
        let namespace = KeychainNamespace.testing("reentrant-forget-\(UUID().uuidString)")
        let (service, _, _, _) = try fixture(namespace: namespace)
        let id = VaultItemID()
        XCTAssertNoThrow(try service.storeVaultSecret(try VaultSecretValue("fictional city"),
            for: id, field: .addressCity))
        var nestedForgetError: Error?
        XCTAssertNoThrow(try service.withVaultSecret(for: id, field: .addressCity) { _ in
            do { try service.forgetAll() } catch { nestedForgetError = error }
        })
        XCTAssertEqual(nestedForgetError as? MemoryFactoryError, .memoryErasureFailed)
        XCTAssertNoThrow(try service.writer.list(context: OwnerMemoryContext(
            ownerID: "fixture-owner", sessionID: "fixture-session")),
            "same-thread reentry must be rejected before fencing ordinary memory access")
    }

    func testDatabaseKeyFailureAfterVaultDeletionKeepsForgetRetryable() throws {
        let namespace = KeychainNamespace.testing("db-key-retry-\(UUID().uuidString)")
        let (service, client, _, _) = try fixture(namespace: namespace)
        let id = VaultItemID()
        let vaultItem = item(id, .membershipNumber, namespace: namespace)
        XCTAssertNoThrow(try service.storeVaultSecret(try VaultSecretValue("fictional membership"),
            for: id, field: .membershipNumber))
        let databaseKey = ExactKeychainItem(service: namespace.databaseKeyService,
            account: "database-key", protection: .deviceOnlyWhenUnlocked)
        client.armDeleteFailure(databaseKey)
        XCTAssertThrowsError(try service.forgetAll())
        XCTAssertFalse(client.contains(vaultItem), "vault deletion should finish before DB key teardown")
        XCTAssertTrue(client.contains(databaseKey), "failed key deletion must remain retryable")
        XCTAssertNoThrow(try service.forgetAll())
        XCTAssertFalse(client.contains(databaseKey))
    }

    func testForgottenRootCannotSilentlyCreateANewDatabaseKeyGeneration() throws {
        let namespace = KeychainNamespace.testing("generation-\(UUID().uuidString)")
        let (oldService, client, root, _) = try fixture(namespace: namespace)
        let databaseKey = ExactKeychainItem(service: namespace.databaseKeyService,
            account: "database-key", protection: .deviceOnlyWhenUnlocked)
        XCTAssertTrue(client.contains(databaseKey))
        XCTAssertNoThrow(try oldService.forgetAll())
        XCTAssertFalse(client.contains(databaseKey))

        let recreated = try? MemoryStoreFactory.openForTesting(enabled: true, root: root,
            client: client, random: LifecycleRandom(), namespace: namespace,
            authorize: { _ in true }, isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: true) })
        XCTAssertNil(recreated,
            "a retained lifecycle lock after Forget must prevent implicit creation of a new key generation")
        XCTAssertEqual(client.additions().filter { $0 == databaseKey }.count, 1,
            "factory must not add a second item under the fixed database-key account")

        if recreated != nil {
            XCTAssertNoThrow(try oldService.forgetAll())
            XCTAssertTrue(client.contains(databaseKey),
                "a completed old service must never destroy a later database-key generation")
        } else {
            XCTAssertNoThrow(try oldService.forgetAll(),
                "repeating Forget on the completed old generation should be idempotent")
        }
    }

    func testFactoryOpenRacingForgetNeverCreatesAnotherKeyGeneration() throws {
        let namespace = KeychainNamespace.testing("open-forget-race-\(UUID().uuidString)")
        let (service, client, root, _) = try fixture(namespace: namespace)
        let databaseKey = ExactKeychainItem(service: namespace.databaseKeyService,
            account: "database-key", protection: .deviceOnlyWhenUnlocked)
        let deletionEntered = client.armDeleteBarrier(databaseKey)
        let forgetFinished = DispatchSemaphore(value: 0)
        let forgetResult = LifecycleResult()
        DispatchQueue.global().async {
            do { try service.forgetAll(); forgetResult.set("done") }
            catch { forgetResult.set("failed") }
            forgetFinished.signal()
        }

        defer { client.releaseDeleteBarrier() }
        XCTAssertEqual(deletionEntered.wait(timeout: .now() + 3), .success,
            "Forget should reach database-key teardown while holding the lifecycle lease")

        let factoryFinished = DispatchSemaphore(value: 0)
        let factoryResult = LifecycleResult()
        DispatchQueue.global().async {
            do {
                let opened = try MemoryStoreFactory.openForTesting(enabled: true, root: root,
                    client: client, random: LifecycleRandom(), namespace: namespace,
                    authorize: { _ in true }, isTaskActive: { _, _ in true },
                    policy: { OwnerMemoryPolicy(featureEnabled: true) })
                factoryResult.set(opened == nil ? "disabled" : "opened")
            } catch { factoryResult.set("rejected") }
            factoryFinished.signal()
        }
        XCTAssertEqual(factoryFinished.wait(timeout: .now() + 0.1), .timedOut,
            "factory open must remain blocked until key and database teardown leave the lease")
        client.releaseDeleteBarrier()
        XCTAssertEqual(forgetFinished.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(factoryFinished.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(forgetResult.get(), "done")
        XCTAssertEqual(factoryResult.get(), "rejected",
            "a factory queued behind completed Forget must fail closed rather than initialize a new generation")
        XCTAssertEqual(client.additions().filter { $0 == databaseKey }.count, 1,
            "factory and Forget must serialize so a deleted key is never recreated")
        XCTAssertFalse(client.contains(databaseKey))
    }

    func testCancelledTaskCannotEnterLeaseOperation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultLeaseCancelled-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = VaultLifecycleLease(root: root)
        let gate = LeaseCancellationGate()
        let operationEntered = DispatchSemaphore(value: 0)
        let task = Task {
            await gate.wait()
            try lease.withExclusive { operationEntered.signal() }
        }
        await gate.waitUntilParked()
        task.cancel()
        await gate.release()
        do {
            try await task.value
            XCTFail("a cancelled task must be rejected before lease work")
        } catch {
            XCTAssertEqual(error as? VaultLifecycleLeaseError, .cancelled)
        }
        XCTAssertEqual(operationEntered.wait(timeout: .now()), .timedOut)
    }

    func testLeaseRejectsSameThreadReentryAndBoundsContention() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultLease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = VaultLifecycleLease(root: root)
        XCTAssertThrowsError(try lease.withExclusive {
            try lease.withExclusive(timeout: 0.02) { () }
        }) { XCTAssertEqual($0 as? VaultLifecycleLeaseError, .reentrant) }

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? lease.withExclusive { entered.signal(); _ = release.wait(timeout: .now() + 2) }
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertThrowsError(try lease.withExclusive(timeout: 0.03) { () }) {
            XCTAssertEqual($0 as? VaultLifecycleLeaseError, .busy)
        }
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
    }

    func testLeaseRejectsSymlinkLockAndNeverUnlinksLockFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultLeaseSymlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let victim = root.appendingPathComponent("victim")
        try Data("fixture".utf8).write(to: victim)
        let lockPath = root.appendingPathComponent(".vault-lifecycle.lock")
        try FileManager.default.createSymbolicLink(atPath: lockPath.path, withDestinationPath: victim.path)
        let lease = VaultLifecycleLease(root: root)
        XCTAssertThrowsError(try lease.withExclusive { () }) {
            XCTAssertEqual($0 as? VaultLifecycleLeaseError, .unsafeLock)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: lockPath.path), victim.path,
            "rejecting the lock must leave the test-owned symlink unchanged")
        XCTAssertEqual(try Data(contentsOf: victim), Data("fixture".utf8))
        try FileManager.default.removeItem(at: lockPath)
        try lease.withExclusive { () }
        var lockInfo = stat()
        XCTAssertEqual(lockPath.path.withCString { lstat($0, &lockInfo) }, 0)
        XCTAssertEqual(lockInfo.st_mode & S_IFMT, S_IFREG)
    }
}

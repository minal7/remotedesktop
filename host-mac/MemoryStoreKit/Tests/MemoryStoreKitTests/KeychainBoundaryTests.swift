import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import MemoryStoreKit

private final class FakeKeychainClient: KeychainClient, @unchecked Sendable {
    enum Operation: Equatable { case add, copy, delete }
    struct Call: Equatable {
        let operation: Operation
        let item: ExactKeychainItem
    }

    private let lock = NSLock()
    private var values: [ExactKeychainItem: Data] = [:]
    private(set) var calls: [Call] = []
    var nextCopyError: KeychainBoundaryError?
    var nextDeleteError: KeychainBoundaryError?

    func add(_ item: ExactKeychainItem, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        calls.append(Call(operation: .add, item: item))
        guard values[item] == nil else { throw KeychainBoundaryError.duplicateItem }
        values[item] = data
    }

    func copy(_ item: ExactKeychainItem) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        calls.append(Call(operation: .copy, item: item))
        if let error = nextCopyError {
            nextCopyError = nil
            throw error
        }
        guard let value = values[item] else { throw KeychainBoundaryError.missingItem }
        return value
    }

    func delete(_ item: ExactKeychainItem) throws {
        lock.lock(); defer { lock.unlock() }
        calls.append(Call(operation: .delete, item: item))
        if let error = nextDeleteError {
            nextDeleteError = nil
            throw error
        }
        guard values.removeValue(forKey: item) != nil else { throw KeychainBoundaryError.missingItem }
    }

    func contains(_ item: ExactKeychainItem) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return values[item] != nil
    }
}

private struct FixedMemoryKeyRandomSource: MemoryKeyRandomSource {
    let value: Data
    func bytes(count: Int) throws -> Data { value }
}

private final class CountingMemoryKeyRandomSource: MemoryKeyRandomSource, @unchecked Sendable {
    private let lock = NSLock()
    private let value: Data
    private(set) var calls = 0

    init(_ value: Data) { self.value = value }
    func bytes(count: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return value
    }
}

private final class RecordingSecurityCallExecutor: SecurityCallExecutor, @unchecked Sendable {
    struct Snapshot {
        let operation: String
        let itemClass: String?
        let service: String?
        let account: String?
        let dataProtection: Bool
        let synchronizable: Bool
        let accessible: String?
        let hasAccessControl: Bool
        let hasReturnData: Bool
        let matchLimit: String?
        let interactionNotAllowed: Bool?
        let queryKeys: Set<String>
        let attributeKeys: Set<String>
        let attributeData: Data?
    }

    private(set) var calls: [Snapshot] = []
    var nextUpdateStatus: OSStatus = errSecSuccess

    func add(_ query: CFDictionary) -> OSStatus {
        calls.append(snapshot(query, operation: "add"))
        return errSecSuccess
    }

    func copy(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus {
        calls.append(snapshot(query, operation: "copy"))
        return errSecItemNotFound
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        calls.append(snapshot(query, operation: "delete"))
        return errSecSuccess
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        calls.append(snapshot(query, operation: "update", attributes: attributes))
        return nextUpdateStatus
    }

    private func snapshot(_ dictionary: CFDictionary, operation: String,
                          attributes: CFDictionary? = nil) -> Snapshot {
        let query = dictionary as NSDictionary
        let updateAttributes = attributes as? NSDictionary
        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        return Snapshot(operation: operation,
            itemClass: query[kSecClass as String] as? String,
            service: query[kSecAttrService as String] as? String,
            account: query[kSecAttrAccount as String] as? String,
            dataProtection: (query[kSecUseDataProtectionKeychain as String] as? Bool) == true,
            synchronizable: (query[kSecAttrSynchronizable as String] as? Bool) == true,
            accessible: query[kSecAttrAccessible as String] as? String,
            hasAccessControl: query[kSecAttrAccessControl as String] != nil,
            hasReturnData: (query[kSecReturnData as String] as? Bool) == true,
            matchLimit: query[kSecMatchLimit as String] as? String,
            interactionNotAllowed: context?.interactionNotAllowed,
            queryKeys: Set(query.allKeys.compactMap { $0 as? String }),
            attributeKeys: Set(updateAttributes?.allKeys.compactMap { $0 as? String } ?? []),
            attributeData: updateAttributes?[kSecValueData as String] as? Data)
    }
}

final class KeychainBoundaryTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeychainBoundaryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testDatabaseKeyProviderUsesExactDeviceOnlyItemAndInjectedRandomness() throws {
        let client = FakeKeychainClient()
        let namespace = KeychainNamespace.testing("db-provider")
        let expected = Data(repeating: 0x32, count: 32)
        let provider = KeychainMemoryKeyProvider(client: client,
            random: FixedMemoryKeyRandomSource(value: expected), namespace: namespace)

        let databaseURL = try temporaryDirectory().appendingPathComponent("memory.db")
        let created = try provider.createKeyForNewStore(databaseURL: databaseURL)
        XCTAssertEqual(created, expected)
        XCTAssertEqual(try provider.loadKey(), expected)
        XCTAssertEqual(client.calls.map(\.operation), [.add, .copy])
        XCTAssertEqual(client.calls.map(\.item), [
            ExactKeychainItem(service: namespace.databaseKeyService, account: "database-key",
                              protection: .deviceOnlyWhenUnlocked),
            ExactKeychainItem(service: namespace.databaseKeyService, account: "database-key",
                              protection: .deviceOnlyWhenUnlocked)
        ])

        try provider.destroyKey()
        try provider.destroyKey() // Missing exact item is idempotent.
        XCTAssertFalse(client.contains(ExactKeychainItem(service: namespace.databaseKeyService,
            account: "database-key", protection: .deviceOnlyWhenUnlocked)))
    }

    func testConcurrentDatabaseKeyCreationReturnsExactWinningKey() throws {
        let client = FakeKeychainClient()
        let namespace = KeychainNamespace.testing("db-race")
        let provider = KeychainMemoryKeyProvider(client: client,
            random: FixedMemoryKeyRandomSource(value: Data(repeating: 0x42, count: 32)),
            namespace: namespace)
        let databaseURL = try temporaryDirectory().appendingPathComponent("memory.db")
        _ = try provider.createKeyForNewStore(databaseURL: databaseURL)

        let second = KeychainMemoryKeyProvider(client: client,
            random: FixedMemoryKeyRandomSource(value: Data(repeating: 0x99, count: 32)),
            namespace: namespace)
        XCTAssertEqual(try second.createKeyForNewStore(databaseURL: databaseURL),
                       Data(repeating: 0x42, count: 32))
        XCTAssertEqual(client.calls.map(\.operation), [.add, .add, .copy])
    }

    func testExistingDatabaseNeverGeneratesOrReplacesItsMissingKey() throws {
        let directory = try temporaryDirectory()
        let databaseURL = directory.appendingPathComponent("memory.db")
        try Data("existing encrypted database".utf8).write(to: databaseURL)
        let client = FakeKeychainClient()
        let random = CountingMemoryKeyRandomSource(Data(repeating: 0x66, count: 32))
        let provider = KeychainMemoryKeyProvider(client: client, random: random,
                                                  namespace: .testing("existing-db"))

        XCTAssertThrowsError(try provider.createKeyForNewStore(databaseURL: databaseURL)) { error in
            XCTAssertEqual(error as? KeychainBoundaryError, .storeAlreadyExists)
        }
        XCTAssertEqual(random.calls, 0)
        XCTAssertTrue(client.calls.isEmpty)
    }

    func testDanglingDatabaseSymlinkIsRejectedBeforeRandomnessOrKeychain() throws {
        let directory = try temporaryDirectory()
        let databaseURL = directory.appendingPathComponent("dangling.db")
        try FileManager.default.createSymbolicLink(atPath: databaseURL.path,
            withDestinationPath: directory.appendingPathComponent("missing-target.db").path)
        let client = FakeKeychainClient()
        let random = CountingMemoryKeyRandomSource(Data(repeating: 0x77, count: 32))
        let provider = KeychainMemoryKeyProvider(client: client, random: random,
                                                  namespace: .testing("dangling-link"))

        XCTAssertThrowsError(try provider.createKeyForNewStore(databaseURL: databaseURL)) { error in
            XCTAssertEqual(error as? KeychainBoundaryError, .storeAlreadyExists)
        }
        XCTAssertEqual(random.calls, 0)
        XCTAssertTrue(client.calls.isEmpty)
    }

    func testProductionAdapterBuildsExactDataProtectionQueriesWithoutCallingSecurity() throws {
        let executor = RecordingSecurityCallExecutor()
        let client = SystemKeychainClient(executor: executor)
        let namespace = KeychainNamespace.testing("actual-dictionary")
        let databaseItem = ExactKeychainItem(service: namespace.databaseKeyService,
            account: "database-key", protection: .deviceOnlyWhenUnlocked)
        let vaultItem = ExactKeychainItem(service: namespace.vaultService,
            account: "v1:01234567-89ab-cdef-0123-456789abcdef:card.number",
            protection: .userPresenceWhenUnlocked)

        try client.add(databaseItem, data: Data(repeating: 0x10, count: 32))
        XCTAssertThrowsError(try client.copy(vaultItem))
        try client.delete(vaultItem)
        try client.add(vaultItem, data: Data("fixture".utf8))

        XCTAssertEqual(executor.calls.count, 4)
        for snapshot in executor.calls {
            XCTAssertEqual(snapshot.itemClass, kSecClassGenericPassword as String)
            XCTAssertTrue(snapshot.dataProtection)
            XCTAssertFalse(snapshot.synchronizable)
            XCTAssertNotNil(snapshot.service)
            XCTAssertNotNil(snapshot.account)
        }
        XCTAssertEqual(executor.calls[0].service, namespace.databaseKeyService)
        XCTAssertEqual(executor.calls[0].account, "database-key")
        XCTAssertEqual(executor.calls[0].accessible,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertFalse(executor.calls[0].hasAccessControl)

        let vaultCopy = executor.calls[1]
        XCTAssertEqual(vaultCopy.service, namespace.vaultService)
        XCTAssertEqual(vaultCopy.account, vaultItem.account)
        XCTAssertTrue(vaultCopy.hasReturnData)
        XCTAssertEqual(vaultCopy.matchLimit, kSecMatchLimitOne as String)
        XCTAssertEqual(vaultCopy.interactionNotAllowed, true)
        XCTAssertEqual(executor.calls[2].interactionNotAllowed, true)
        let vaultAdd = executor.calls[3]
        XCTAssertTrue(vaultAdd.hasAccessControl)
        XCTAssertNil(vaultAdd.accessible, "ACL item must not also set plain accessibility")
    }

    func testReplaceUsesOneExactNoninteractiveUpdateAndChangesOnlyData() throws {
        let executor = RecordingSecurityCallExecutor()
        let client = SystemKeychainClient(executor: executor)
        let item = ExactKeychainItem(service: "fixture.db", account: "generation-state-v1",
                                     protection: .deviceOnlyWhenUnlocked)
        let replacement = Data("new-generation-pointer".utf8)

        XCTAssertNoThrow(try client.replace(item, data: replacement))

        XCTAssertEqual(executor.calls.count, 1)
        let call = try XCTUnwrap(executor.calls.first)
        XCTAssertEqual(call.operation, "update")
        XCTAssertEqual(call.itemClass, kSecClassGenericPassword as String)
        XCTAssertEqual(call.service, item.service)
        XCTAssertEqual(call.account, item.account)
        XCTAssertTrue(call.dataProtection)
        XCTAssertFalse(call.synchronizable)
        XCTAssertEqual(call.interactionNotAllowed, true)
        XCTAssertEqual(call.queryKeys, Set([
            kSecClass as String, kSecUseDataProtectionKeychain as String,
            kSecAttrService as String, kSecAttrAccount as String,
            kSecAttrSynchronizable as String, kSecUseAuthenticationContext as String
        ]))
        XCTAssertEqual(call.attributeKeys, Set([kSecValueData as String]))
        XCTAssertEqual(call.attributeData, replacement)
    }

    func testReplaceRefusesUserPresenceItemBeforeCallingExecutor() throws {
        let executor = RecordingSecurityCallExecutor()
        let client = SystemKeychainClient(executor: executor)
        let item = ExactKeychainItem(service: "fixture.vault", account: "v1:opaque",
                                     protection: .userPresenceWhenUnlocked)

        XCTAssertThrowsError(try client.replace(item, data: Data("replacement".utf8))) { error in
            XCTAssertEqual(error as? KeychainBoundaryError, .unsupportedProtection)
        }
        XCTAssertTrue(executor.calls.isEmpty)
    }

    func testReplaceMapsMissingDeniedAndNoninteractiveStatusesWithoutFallback() throws {
        let cases: [(OSStatus, KeychainBoundaryError)] = [
            (errSecItemNotFound, .missingItem),
            (errSecInteractionNotAllowed, .ownerHandoffRequired),
            (errSecAuthFailed, .accessDenied)
        ]
        for (status, expected) in cases {
            let executor = RecordingSecurityCallExecutor()
            executor.nextUpdateStatus = status
            let client = SystemKeychainClient(executor: executor)
            let item = ExactKeychainItem(service: "fixture.db", account: "generation-state-v1",
                                         protection: .deviceOnlyWhenUnlocked)

            XCTAssertThrowsError(try client.replace(item, data: Data("new".utf8))) { error in
                XCTAssertEqual(error as? KeychainBoundaryError, expected)
            }
            XCTAssertEqual(executor.calls.map(\.operation), ["update"])
            XCTAssertEqual(executor.calls.count, 1)
        }
    }

    func testVaultStoresOnlyExactItemFieldAndDoesNotExposeDescription() throws {
        let client = FakeKeychainClient()
        let namespace = KeychainNamespace.testing("vault-one")
        let vault = KeychainVault(client: client, namespace: namespace)
        let id = VaultItemID(uuid: UUID(uuidString: "A1B2C3D4-E5F6-4789-ABCD-0123456789AB")!)
        let canary = "fixture-secret-\(UUID().uuidString)"
        let value = try VaultSecretValue(canary)

        try vault.store(value, for: id, field: .cardNumber)
        var revealedInsideScope = false
        try vault.withSecret(for: id, field: .cardNumber) { scoped in
            scoped.withString { revealedInsideScope = ($0 == canary) }
        }
        XCTAssertTrue(revealedInsideScope)
        XCTAssertEqual(String(describing: value), "<redacted>")
        XCTAssertEqual(String(reflecting: value), "<redacted>")
        XCTAssertEqual(String(describing: id), "<vault-item-id>")
        XCTAssertFalse(VaultSecretValue.self is any Encodable.Type)

        let expected = ExactKeychainItem(service: namespace.vaultService,
            account: id.account(for: .cardNumber), protection: .userPresenceWhenUnlocked)
        XCTAssertEqual(client.calls.map(\.item), [expected, expected])
        XCTAssertEqual(client.calls.map(\.operation), [.add, .copy])
        XCTAssertTrue(client.contains(expected))
    }

    func testVaultNamespacesDoNotCrossReadOrDelete() throws {
        let client = FakeKeychainClient()
        let firstNamespace = KeychainNamespace.testing("isolated-a")
        let secondNamespace = KeychainNamespace.testing("isolated-b")
        let first = KeychainVault(client: client, namespace: firstNamespace)
        let second = KeychainVault(client: client, namespace: secondNamespace)
        let id = VaultItemID()
        try first.store(try VaultSecretValue("fixture-a"), for: id, field: .phoneNumber)

        XCTAssertThrowsError(try second.withSecret(for: id, field: .phoneNumber) { _ in }) { error in
            XCTAssertEqual(error as? KeychainBoundaryError, .missingItem)
        }
        try second.forget(itemIDs: [id])
        XCTAssertTrue(client.contains(ExactKeychainItem(service: firstNamespace.vaultService,
            account: id.account(for: .phoneNumber), protection: .userPresenceWhenUnlocked)))
        XCTAssertFalse(client.calls.contains { $0.item.service == firstNamespace.vaultService &&
            $0.operation == .delete })
    }

    func testVaultAuthenticationFailureHandsOffWithoutInteractiveRetry() throws {
        let client = FakeKeychainClient()
        let namespace = KeychainNamespace.testing("auth-refused")
        let vault = KeychainVault(client: client, namespace: namespace)
        let id = VaultItemID()
        client.nextCopyError = .ownerHandoffRequired

        XCTAssertThrowsError(try vault.withSecret(for: id, field: .identityNumber) { _ in }) { error in
            XCTAssertEqual(error as? KeychainBoundaryError, .ownerHandoffRequired)
            XCTAssertFalse(String(describing: error).contains("fixture-secret"))
        }
        XCTAssertEqual(client.calls.map(\.operation), [.copy])
        XCTAssertEqual(client.calls.first?.item.protection, .userPresenceWhenUnlocked)
    }

    func testForgetDeletesOnlyKnownIDsAndRetriesAfterFailure() throws {
        let client = FakeKeychainClient()
        let namespace = KeychainNamespace.testing("forget-scope")
        let vault = KeychainVault(client: client, namespace: namespace)
        let retained = VaultItemID()
        let forgotten = VaultItemID()
        try vault.store(try VaultSecretValue("retained"), for: retained, field: .addressCity)
        try vault.store(try VaultSecretValue("forgotten"), for: forgotten, field: .membershipNumber)

        client.nextDeleteError = .ownerHandoffRequired
        XCTAssertThrowsError(try vault.forget(itemIDs: [forgotten])) { error in
            XCTAssertEqual(error as? KeychainBoundaryError, .ownerHandoffRequired)
        }
        try vault.forget(itemIDs: [forgotten])
        try vault.forget(itemIDs: [forgotten]) // Subsequent missing fields are harmless.

        XCTAssertTrue(client.contains(ExactKeychainItem(service: namespace.vaultService,
            account: retained.account(for: .addressCity), protection: .userPresenceWhenUnlocked)))
        XCTAssertFalse(client.contains(ExactKeychainItem(service: namespace.vaultService,
            account: forgotten.account(for: .membershipNumber), protection: .userPresenceWhenUnlocked)))
        let forgottenAccounts = Set(VaultSecretField.allCases.map { forgotten.account(for: $0) })
        XCTAssertTrue(client.calls.filter { $0.operation == .delete }.allSatisfy {
            $0.item.service == namespace.vaultService && forgottenAccounts.contains($0.item.account)
        })
        XCTAssertFalse(VaultSecretField.allCases.map(\.rawValue).contains("card.cvv"))
        XCTAssertFalse(VaultSecretField.allCases.map(\.rawValue).contains("password"))
    }

    func testAllVaultStringInputsRejectEmbeddedNULAndInvalidLengths() throws {
        XCTAssertThrowsError(try VaultSecretValue("prefix\0suffix")) { error in
            XCTAssertEqual(error as? KeychainBoundaryError, .invalidIdentifier)
        }
        XCTAssertThrowsError(try VaultSecretValue(String(repeating: "x", count: 16_385))) { error in
            XCTAssertEqual(error as? KeychainBoundaryError, .invalidIdentifier)
        }
    }
}

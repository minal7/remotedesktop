import Foundation
import XCTest
@testable import MemoryStoreKit

private final class OwnerEntryKeychain: KeychainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ExactKeychainItem: Data] = [:]
    private var additions: [ExactKeychainItem] = []
    private var failAt: Int?
    var afterAdd: (() -> Void)?
    var blockFirstAdd = false
    let addEntered = DispatchSemaphore(value: 0)
    let releaseFirstAdd = DispatchSemaphore(value: 0)

    init(failAt: Int? = nil) { self.failAt = failAt }
    func add(_ item: ExactKeychainItem, data: Data) throws {
        lock.lock()
        let isVaultItem = item.account.hasPrefix("v1:")
        let index = additions.filter { $0.account.hasPrefix("v1:") }.count + (isVaultItem ? 1 : 0)
        if isVaultItem && failAt == index { lock.unlock(); throw KeychainBoundaryError.accessDenied }
        guard values[item] == nil else { lock.unlock(); throw KeychainBoundaryError.duplicateItem }
        values[item] = data
        additions.append(item)
        let callback = isVaultItem ? afterAdd : nil
        let shouldBlock = isVaultItem && blockFirstAdd && index == 1
        lock.unlock()
        callback?()
        if shouldBlock {
            addEntered.signal()
            _ = releaseFirstAdd.wait(timeout: .now() + 5)
        }
    }
    func copy(_ item: ExactKeychainItem) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let value = values[item] else { throw KeychainBoundaryError.missingItem }
        return value
    }
    func delete(_ item: ExactKeychainItem) throws {
        lock.lock(); defer { lock.unlock() }
        guard values.removeValue(forKey: item) != nil else { throw KeychainBoundaryError.missingItem }
    }
    func snapshot() -> ([ExactKeychainItem: Data], [ExactKeychainItem]) {
        lock.lock(); defer { lock.unlock() }
        return (values.filter { $0.key.account.hasPrefix("v1:") },
                additions.filter { $0.account.hasPrefix("v1:") })
    }
}

private struct OwnerEntryRandom: MemoryKeyRandomSource {
    func bytes(count: Int) throws -> Data { Data(repeating: 0x51, count: count) }
}

private final class OwnerEntryAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    var authorized: Bool { lock.lock(); defer { lock.unlock() }; return current }
    func revoke() { lock.lock(); current = false; lock.unlock() }
    func restore() { lock.lock(); current = true; lock.unlock() }
}

final class VaultOwnerEntryTests: XCTestCase {
    private static let ownerID = "vault-entry-owner"
    private let context = OwnerMemoryContext(ownerID: "vault-entry-owner", sessionID: "vault-entry-session")

    private func makeRoot() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultOwnerEntry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        return parent.appendingPathComponent("store", isDirectory: true)
    }

    private func open(_ root: URL, keychain: OwnerEntryKeychain,
                      auth: OwnerEntryAuthorization = OwnerEntryAuthorization(),
                      namespaceID: String = UUID().uuidString,
                      policy: @escaping OwnerMemoryPolicyProvider = { OwnerMemoryPolicy(featureEnabled: true) }) throws -> PersonalMemoryService {
        try XCTUnwrap(MemoryStoreFactory.openForTesting(enabled: true, root: root, client: keychain,
            random: OwnerEntryRandom(), namespace: .testing("owner-entry-\(namespaceID)"),
            authorize: { $0.ownerID == Self.ownerID && $0.sessionID == "vault-entry-session" && auth.authorized },
            isTaskActive: { _, _ in true },
            policy: policy))
    }

    private func value(_ text: String) throws -> VaultSecretValue { try VaultSecretValue(text) }

    private var entries: [(OwnerVaultEntryPayload, [String])] {
        get throws {
            [
                (.paymentCard(brand: .visa, holderName: try value("Fictional Holder"),
                              number: try value("4242424242424242"), expiryMonth: 8, expiryYear: 2029),
                 ["card.holder-name", "card.number", "card.expiry-month", "card.expiry-year"]),
                (.address(label: .homeAddress, line1: try value("1 Fictional Way"), line2: nil,
                          city: try value("Exampletown"), region: try value("CA"),
                          postalCode: try value("90000"), country: try value("US")),
                 ["address.line-1", "address.city", "address.region", "address.postal-code", "address.country"]),
                (.phone(try value("+15550100000")), ["phone.number"]),
                (.membership(try value("MEMBER-12345")), ["membership.number"]),
                (.identity(name: try value("Fictional Person"), number: try value("ID-12345"),
                           expiry: try value("2030-01")),
                 ["identity.name", "identity.number", "identity.expiry"])
            ]
        }
    }

    func testAllTypedEntryKindsStoreOnlyExactUserPresenceFieldsAndSafeDisplays() throws {
        for (payload, expectedFields) in try entries {
            let root = try makeRoot()
            let client = OwnerEntryKeychain()
            let service = try open(root, keychain: client)
            let command = UUID()
            let receipt = try service.createVaultEntry(commandID: command, payload: payload, context: context)
            XCTAssertEqual(receipt.commandID, command)
            XCTAssertEqual(try service.vaultEntryCreationStatus(commandID: command, context: context).state, .completed)
            let stored = client.snapshot()
            XCTAssertEqual(Set(stored.1.map(\.account)), Set(expectedFields.map { "v1:\(receipt.itemID.uuidString.lowercased()):\($0)" }))
            XCTAssertTrue(stored.1.allSatisfy { $0.protection == .userPresenceWhenUnlocked })
            let expectedDisplay: String
            switch payload {
            case .paymentCard: expectedDisplay = "Visa ending in 4242, expires 08/2029"
            case .address: expectedDisplay = VaultDisplayLabel.homeAddress.rawValue
            case .phone: expectedDisplay = VaultDisplayLabel.mobilePhone.rawValue
            case .membership: expectedDisplay = VaultDisplayLabel.membership.rawValue
            case .identity: expectedDisplay = VaultDisplayLabel.identityDocument.rawValue
            }
            XCTAssertEqual(receipt.displayText, expectedDisplay)
            for value in stored.0.values {
                XCTAssertFalse(receipt.displayText.utf8.elementsEqual(value), "display metadata cannot echo a field value")
            }
            XCTAssertFalse(receipt.displayText.contains("4242424242424242"))
            XCTAssertFalse(receipt.displayText.contains("Fictional Holder"))
            XCTAssertNoThrow(try service.close())
        }
    }

    func testSameCommandCannotReplayOrOverwriteChangedSecretAndStatusIsValueFree() throws {
        let root = try makeRoot()
        let client = OwnerEntryKeychain()
        let service = try open(root, keychain: client)
        let id = UUID()
        let first = OwnerVaultEntryPayload.phone(try value("+15550100000"))
        let changed = OwnerVaultEntryPayload.phone(try value("+15550100001"))
        let receipt = try service.createVaultEntry(commandID: id, payload: first, context: context)
        XCTAssertThrowsError(try service.createVaultEntry(commandID: id, payload: changed, context: context)) {
            XCTAssertEqual($0 as? VaultEntryError, .commandReserved)
        }
        XCTAssertEqual(client.snapshot().1.count, 1)
        let status = try service.vaultEntryCreationStatus(commandID: id, context: context)
        XCTAssertEqual(status.itemID, receipt.itemID)
        XCTAssertEqual(status.state, .completed)
        XCTAssertFalse(String(describing: status).contains("+15550100000"))
    }

    func testNthKeychainFailureLeavesDurablePendingReservationForForget() throws {
        let root = try makeRoot()
        let client = OwnerEntryKeychain(failAt: 2)
        let service = try open(root, keychain: client, namespaceID: "pending-reopen")
        let id = UUID()
        let card = try XCTUnwrap(entries.first?.0)
        XCTAssertThrowsError(try service.createVaultEntry(commandID: id, payload: card, context: context))
        XCTAssertNoThrow(try service.close())
        let reopened = try open(root, keychain: client, namespaceID: "pending-reopen")
        let pending = try reopened.vaultEntryCreationStatus(commandID: id, context: context)
        XCTAssertEqual(pending.state, .pending)
        XCTAssertThrowsError(try reopened.isEmptyForGenerationPublication()) {
            XCTAssertEqual($0 as? MemoryStoreError, .contentPresent)
        }
        XCTAssertEqual(client.snapshot().1.count, 1)
        XCTAssertThrowsError(try reopened.createVaultEntry(commandID: id, payload: card, context: context))
        XCTAssertEqual(client.snapshot().1.count, 1, "pending entries are not replayed or overwritten")
        XCTAssertNoThrow(try reopened.forgetAll())
    }

    func testSecretCanaryStaysInVaultAndNotAtRestCiphertextOrOrdinaryMemory() throws {
        let root = try makeRoot()
        let client = OwnerEntryKeychain()
        let service = try open(root, keychain: client)
        let canary = "OWNER_VAULT_CANARY_92c75ad4"
        let secret = try value(canary)
        let payload = OwnerVaultEntryPayload.membership(secret)
        XCTAssertFalse(String(reflecting: secret).contains(canary))
        XCTAssertFalse(String(describing: Mirror(reflecting: secret)).contains(canary))
        XCTAssertFalse(String(reflecting: payload).contains(canary))
        XCTAssertFalse(String(describing: payload).contains(canary))
        let receipt = try service.createVaultEntry(commandID: UUID(), payload: payload, context: context)
        let persisted = try service.vaultEntryCreationStatus(commandID: receipt.commandID, context: context)
        XCTAssertEqual(persisted.state, .completed)
        XCTAssertEqual(persisted.displayText, VaultDisplayLabel.membership.rawValue)
        XCTAssertFalse(String(describing: persisted).contains(canary))
        XCTAssertTrue(try service.writer.list(context: context).isEmpty)
        XCTAssertTrue(try service.writer.search(canary, context: context).isEmpty)
        XCTAssertFalse(String(describing: receipt).contains(canary))
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for file in files where file.lastPathComponent.hasPrefix("memory.sqlite") {
            XCTAssertFalse((try Data(contentsOf: file)).range(of: Data(canary.utf8)) != nil)
        }
        XCTAssertFalse(receipt.displayText.contains(canary))
    }

    func testRevokedOwnerBetweenFieldsStopsFurtherWritesAndKeepsPendingReservation() throws {
        let root = try makeRoot()
        let auth = OwnerEntryAuthorization()
        let client = OwnerEntryKeychain()
        client.afterAdd = { auth.revoke() }
        let service = try open(root, keychain: client, auth: auth)
        let card = try XCTUnwrap(entries.first?.0)
        let command = UUID()
        XCTAssertThrowsError(try service.createVaultEntry(commandID: command, payload: card, context: context))
        XCTAssertEqual(client.snapshot().1.count, 1)
        XCTAssertThrowsError(try service.vaultEntryCreationStatus(commandID: command, context: context))
        auth.restore()
        XCTAssertEqual(try service.vaultEntryCreationStatus(commandID: command, context: context).state, .pending)
    }

    func testConcurrentForgetDrainsCreationAndErasesItsInventoriedPartialItem() throws {
        let root = try makeRoot()
        let client = OwnerEntryKeychain()
        client.blockFirstAdd = true
        let service = try open(root, keychain: client, namespaceID: "forget-race")
        let forgettingService = try open(root, keychain: client, namespaceID: "forget-race")
        let card = try XCTUnwrap(entries.first?.0)
        let result = OwnerEntryResult()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do { result.set(try service.createVaultEntry(commandID: UUID(), payload: card, context: self.context)) }
            catch { result.set(error) }
            finished.signal()
        }
        XCTAssertEqual(client.addEntered.wait(timeout: .now() + 2), .success)
        let forgetFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do { try forgettingService.forgetAll(); result.setForget(nil) }
            catch { result.setForget(error) }
            forgetFinished.signal()
        }
        let deadline = Date().addingTimeInterval(2)
        var erasureFenceObserved = false
        while Date() < deadline {
            do { try service.store.requireActive() }
            catch { erasureFenceObserved = true; break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        client.releaseFirstAdd.signal()
        XCTAssertTrue(erasureFenceObserved)
        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(forgetFinished.wait(timeout: .now() + 3), .success)
        XCTAssertNil(result.receipt)
        XCTAssertNotNil(result.createError)
        XCTAssertNil(result.forgetError)
        XCTAssertEqual(client.snapshot().0.count, 0)
    }

    func testRevocationAfterFinalFieldLeavesPendingCreation() throws {
        let root = try makeRoot()
        let auth = OwnerEntryAuthorization()
        let client = OwnerEntryKeychain()
        client.afterAdd = { auth.revoke() }
        let service = try open(root, keychain: client, auth: auth)
        let command = UUID()
        XCTAssertThrowsError(try service.createVaultEntry(commandID: command,
            payload: .phone(try value("+15550100000")), context: context))
        XCTAssertEqual(client.snapshot().1.count, 1)
        auth.restore()
        XCTAssertEqual(try service.vaultEntryCreationStatus(commandID: command, context: context).state, .pending)
    }

    func testNoMemoryAllowsExplicitOwnerVaultCreation() throws {
        let root = try makeRoot()
        let client = OwnerEntryKeychain()
        let service = try open(root, keychain: client,
            policy: { OwnerMemoryPolicy(featureEnabled: true, noMemory: true) })
        let receipt = try service.createVaultEntry(commandID: UUID(),
            payload: .phone(try value("+15550100000")), context: context)
        XCTAssertEqual(receipt.kind, .phone)
        XCTAssertEqual(client.snapshot().1.count, 1)
    }

    func testConcurrentSameCommandAcrossServicesReservesOnlyOnce() throws {
        let root = try makeRoot()
        let client = OwnerEntryKeychain()
        let first = try open(root, keychain: client, namespaceID: "concurrent-create")
        let second = try open(root, keychain: client, namespaceID: "concurrent-create")
        let command = UUID()
        let phone = OwnerVaultEntryPayload.phone(try value("+15550100000"))
        let counts = OwnerEntryCounter()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                _ = try (index == 0 ? first : second).createVaultEntry(
                    commandID: command, payload: phone, context: self.context)
                counts.completed()
            } catch {
                counts.refused()
            }
        }
        XCTAssertEqual(counts.values.completed, 1)
        XCTAssertEqual(counts.values.refused, 1)
        XCTAssertEqual(client.snapshot().1.count, 1)
    }

    func testWrongOwnerDisabledAndIncognitoFailBeforeVaultWrite() throws {
        let root = try makeRoot()
        let client = OwnerEntryKeychain()
        let service = try open(root, keychain: client)
        let phone = OwnerVaultEntryPayload.phone(try value("+15550100000"))
        XCTAssertThrowsError(try service.createVaultEntry(commandID: UUID(), payload: phone,
            context: OwnerMemoryContext(ownerID: "different-owner", sessionID: "vault-entry-session")))
        XCTAssertThrowsError(try service.vaultEntryCreationStatus(commandID: UUID(),
            context: OwnerMemoryContext(ownerID: "different-owner", sessionID: "vault-entry-session")))
        XCTAssertEqual(client.snapshot().1.count, 0)

        let incognito = try open(root.appendingPathComponent("incognito", isDirectory: true),
            keychain: client, policy: { OwnerMemoryPolicy(featureEnabled: true, incognito: true) })
        XCTAssertThrowsError(try incognito.createVaultEntry(commandID: UUID(), payload: phone, context: context))
        XCTAssertEqual(client.snapshot().1.count, 0)
        XCTAssertNil(try MemoryStoreFactory.openForTesting(enabled: false,
            root: root.appendingPathComponent("disabled", isDirectory: true), client: client,
            random: OwnerEntryRandom(), namespace: .testing("owner-entry-disabled"),
            authorize: { _ in true }, isTaskActive: { _, _ in true },
            policy: { OwnerMemoryPolicy(featureEnabled: true) }))
        XCTAssertEqual(client.snapshot().1.count, 0)
    }

    func testMalformedTypedFieldsFailBeforeAnyVaultItemIsAdded() throws {
        let root = try makeRoot()
        let client = OwnerEntryKeychain()
        let service = try open(root, keychain: client)
        let invalid = [
            OwnerVaultEntryPayload.paymentCard(brand: .visa, holderName: try value("Holder"),
                number: try value("123456789012"), expiryMonth: 13, expiryYear: 2030),
            .address(label: .homeAddress, line1: try value("  "), line2: nil, city: try value("City"),
                     region: nil, postalCode: nil, country: try value("US")),
            .phone(try value("\n")),
            .membership(try value(" ")),
            .identity(name: try value("Name"), number: try value("ID"), expiry: try value("\n"))
        ]
        for payload in invalid {
            XCTAssertThrowsError(try service.createVaultEntry(commandID: UUID(), payload: payload, context: context))
        }
        XCTAssertEqual(client.snapshot().1.count, 0)
    }
}

private final class OwnerEntryResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedReceipt: VaultEntryReceipt?
    private var storedError: Error?
    private var storedForgetError: Error?
    var receipt: VaultEntryReceipt? { lock.lock(); defer { lock.unlock() }; return storedReceipt }
    var createError: Error? { lock.lock(); defer { lock.unlock() }; return storedError }
    var forgetError: Error? { lock.lock(); defer { lock.unlock() }; return storedForgetError }
    func set(_ receipt: VaultEntryReceipt) { lock.lock(); storedReceipt = receipt; lock.unlock() }
    func set(_ error: Error) { lock.lock(); storedError = error; lock.unlock() }
    func setForget(_ error: Error?) { lock.lock(); storedForgetError = error; lock.unlock() }
}

private final class OwnerEntryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var successCount = 0
    private var refusedCount = 0
    var values: (completed: Int, refused: Int) {
        lock.lock(); defer { lock.unlock() }
        return (successCount, refusedCount)
    }
    func completed() { lock.lock(); successCount += 1; lock.unlock() }
    func refused() { lock.lock(); refusedCount += 1; lock.unlock() }
}

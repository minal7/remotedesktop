import Foundation
import Darwin
import LocalAuthentication
import Security

/// Internal-only item namespace. Production services are fixed to this application's bundle
/// namespace; tests can inject an isolated namespace through @testable access.
struct KeychainNamespace: Sendable, Equatable {
    let databaseKeyService: String
    let vaultService: String

    static let production = KeychainNamespace(
        databaseKeyService: "com.threadmark.remotedesktop.host.personal-memory.db-key.v1",
        vaultService: "com.threadmark.remotedesktop.host.personal-memory.vault.v1")

    static func testing(_ suffix: String) -> KeychainNamespace {
        KeychainNamespace(
            databaseKeyService: "com.threadmark.remotedesktop.host.personal-memory.tests.\(suffix).db",
            vaultService: "com.threadmark.remotedesktop.host.personal-memory.tests.\(suffix).vault")
    }
}

enum KeychainProtection: Sendable, Hashable {
    case deviceOnlyWhenUnlocked
    case userPresenceWhenUnlocked
}

/// A typed description of one exact Keychain item. It cannot represent a match-all query.
struct ExactKeychainItem: Sendable, Hashable {
    let service: String
    let account: String
    let protection: KeychainProtection

    init(service: String, account: String, protection: KeychainProtection) {
        self.service = service
        self.account = account
        self.protection = protection
    }
}

enum KeychainBoundaryError: Error, Equatable {
    case missingItem
    case duplicateItem
    case storeAlreadyExists
    case ownerHandoffRequired
    case accessDenied
    case unsupportedProtection
    case invalidKey
    case invalidIdentifier
    case pathUnavailable
    case storageFailure(Int32)
}

extension KeychainBoundaryError: LocalizedError, CustomStringConvertible, CustomDebugStringConvertible {
    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .missingItem: return "Protected item is unavailable."
        case .duplicateItem: return "Protected item already exists."
        case .storeAlreadyExists: return "A database already exists; its protected key will not be replaced."
        case .ownerHandoffRequired: return "Owner action is required to access this protected item."
        case .accessDenied: return "Access to the protected item was denied."
        case .unsupportedProtection: return "This protected item cannot be replaced."
        case .invalidKey: return "The protected database key is invalid."
        case .invalidIdentifier: return "The protected item identifier is invalid."
        case .pathUnavailable: return "The new database location is unavailable."
        case .storageFailure: return "Protected storage operation failed."
        }
    }

    var debugDescription: String { description }
}

/// The adapter contract accepts only exact namespace+account operations and cannot enumerate.
protocol KeychainClient: Sendable {
    func add(_ item: ExactKeychainItem, data: Data) throws
    func copy(_ item: ExactKeychainItem) throws -> Data
    func delete(_ item: ExactKeychainItem) throws
    func replace(_ item: ExactKeychainItem, data: Data) throws
}

extension KeychainClient {
    func replace(_ item: ExactKeychainItem, data: Data) throws {
        throw KeychainBoundaryError.storageFailure(-1)
    }
}

/// The only seam around Security's item APIs. Tests inject a fake here so they inspect the exact
/// dictionaries and LAContext produced by the adapter without invoking Keychain storage.
protocol SecurityCallExecutor: Sendable {
    func add(_ query: CFDictionary) -> OSStatus
    func copy(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
}

extension SecurityCallExecutor {
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        errSecUnimplemented
    }
}

struct SystemSecurityCallExecutor: SecurityCallExecutor {
    func add(_ query: CFDictionary) -> OSStatus { SecItemAdd(query, nil) }
    func copy(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus {
        SecItemCopyMatching(query, result)
    }
    func delete(_ query: CFDictionary) -> OSStatus { SecItemDelete(query) }
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }
}

/// Production adapter. The only query forms below include Data Protection Keychain selection,
/// a fixed service, and one exact account. Authentication-required reads fail without UI.
struct SystemKeychainClient: KeychainClient {
    private let executor: any SecurityCallExecutor

    init(executor: any SecurityCallExecutor = SystemSecurityCallExecutor()) {
        self.executor = executor
    }

    func add(_ item: ExactKeychainItem, data: Data) throws {
        var query = baseQuery(item)
        query[kSecValueData as String] = data
        switch item.protection {
        case .deviceOnlyWhenUnlocked:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .userPresenceWhenUnlocked:
            var accessError: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.userPresence], &accessError) else {
                throw sanitized(accessError?.takeRetainedValue())
            }
            query[kSecAttrAccessControl as String] = access
        }
        try check(executor.add(query as CFDictionary))
    }

    func copy(_ item: ExactKeychainItem) throws -> Data {
        var query = baseQuery(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = nonInteractiveContext()
        var result: CFTypeRef?
        try check(executor.copy(query as CFDictionary, result: &result))
        guard let data = result as? Data else { throw KeychainBoundaryError.invalidKey }
        return data
    }

    func delete(_ item: ExactKeychainItem) throws {
        var query = baseQuery(item)
        query[kSecUseAuthenticationContext as String] = nonInteractiveContext()
        try check(executor.delete(query as CFDictionary))
    }

    func replace(_ item: ExactKeychainItem, data: Data) throws {
        // Atomic replacement is limited to noninteractive device-only metadata and keys.
        // Rewriting user-presence items could weaken their ACL, so refuse before Security.
        guard item.protection == .deviceOnlyWhenUnlocked else {
            throw KeychainBoundaryError.unsupportedProtection
        }
        var query = baseQuery(item)
        query[kSecUseAuthenticationContext as String] = nonInteractiveContext()
        let attributes: [String: Any] = [kSecValueData as String: data]
        // SecItemUpdate affects only the exact item selected by query. A missing item is an
        // error; there is deliberately no delete/add fallback or accessibility mutation.
        try check(executor.update(query as CFDictionary, attributes: attributes as CFDictionary))
    }

    private func baseQuery(_ item: ExactKeychainItem) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrService as String: item.service,
         kSecAttrAccount as String: item.account,
         kSecAttrSynchronizable as String: false]
    }

    private func nonInteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound: throw KeychainBoundaryError.missingItem
        case errSecDuplicateItem: throw KeychainBoundaryError.duplicateItem
        case errSecInteractionNotAllowed: throw KeychainBoundaryError.ownerHandoffRequired
        case errSecAuthFailed: throw KeychainBoundaryError.accessDenied
        default: throw KeychainBoundaryError.storageFailure(Int32(status))
        }
    }

    private func sanitized(_ error: CFError?) -> KeychainBoundaryError {
        guard let error else { return .storageFailure(-1) }
        let code = CFErrorGetCode(error)
        if code == Int(errSecInteractionNotAllowed) { return .ownerHandoffRequired }
        if code == Int(errSecAuthFailed) { return .accessDenied }
        return .storageFailure(Int32(clamping: code))
    }
}

protocol MemoryKeyRandomSource: Sendable {
    func bytes(count: Int) throws -> Data
}

struct SystemMemoryKeyRandomSource: MemoryKeyRandomSource {
    func bytes(count: Int) throws -> Data {
        guard count == 32 else { throw KeychainBoundaryError.invalidKey }
        var output = Data(count: count)
        let status = output.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw KeychainBoundaryError.storageFailure(Int32(status))
        }
        return output
    }
}

/// The provider is deliberately separate from vault access. Creation is explicit so a caller
/// can create a key only for a genuinely new store; a missing key never silently resets a DB.
/// App-root containment and serialized first-open remain composition responsibilities.
final class KeychainMemoryKeyProvider: MemoryKeyProvider, @unchecked Sendable {
    private let client: any KeychainClient
    private let random: any MemoryKeyRandomSource
    private let namespace: KeychainNamespace

    init(client: any KeychainClient = SystemKeychainClient(),
         random: any MemoryKeyRandomSource = SystemMemoryKeyRandomSource(),
         namespace: KeychainNamespace = .production) {
        self.client = client
        self.random = random
        self.namespace = namespace
    }

    func loadKey() throws -> Data {
        let data = try client.copy(databaseKeyItem)
        guard data.count == 32 else { throw KeychainBoundaryError.invalidKey }
        return data
    }

    func createKeyForNewStore(databaseURL: URL) throws -> Data {
        guard databaseURL.isFileURL, !databaseURL.path.utf8.contains(0) else {
            throw KeychainBoundaryError.pathUnavailable
        }
        try Self.requireNewDatabasePaths(databaseURL)
        let bytes = try random.bytes(count: 32)
        guard bytes.count == 32 else { throw KeychainBoundaryError.invalidKey }
        do {
            try client.add(databaseKeyItem, data: bytes)
            return bytes
        } catch KeychainBoundaryError.duplicateItem {
            // A concurrent initializer may have won. Return only the exact app-owned item.
            return try loadKey()
        }
    }

    func destroyKey() throws {
        do { try client.delete(databaseKeyItem) }
        catch KeychainBoundaryError.missingItem { return }
    }

    private var databaseKeyItem: ExactKeychainItem {
        ExactKeychainItem(service: namespace.databaseKeyService, account: "database-key",
                          protection: .deviceOnlyWhenUnlocked)
    }

    private static func requireNewDatabasePaths(_ databaseURL: URL) throws {
        let parentPath = databaseURL.deletingLastPathComponent().path
        var parentInfo = stat()
        let parentResult = parentPath.withCString { lstat($0, &parentInfo) }
        guard parentResult == 0, (parentInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw KeychainBoundaryError.pathUnavailable
        }

        for path in [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"] {
            var info = stat()
            let result = path.withCString { lstat($0, &info) }
            if result == 0 { throw KeychainBoundaryError.storeAlreadyExists }
            if errno != ENOENT { throw KeychainBoundaryError.pathUnavailable }
        }
    }
}

/// Closed set of supported vault fields. CVV and passwords have no representable value.
enum VaultSecretField: String, CaseIterable, Sendable {
    case cardNumber = "card.number"
    case cardExpiryMonth = "card.expiry-month"
    case cardExpiryYear = "card.expiry-year"
    case cardholderName = "card.holder-name"
    case addressLine1 = "address.line-1"
    case addressLine2 = "address.line-2"
    case addressCity = "address.city"
    case addressRegion = "address.region"
    case addressPostalCode = "address.postal-code"
    case addressCountry = "address.country"
    case phoneNumber = "phone.number"
    case membershipNumber = "membership.number"
    case identityNumber = "identity.number"
    case identityName = "identity.name"
    case identityExpiry = "identity.expiry"
}

struct VaultItemID: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let rawValue: UUID
    var uuid: UUID { rawValue }

    init() { rawValue = UUID() }
    init(uuid: UUID) { rawValue = uuid }

    var description: String { "<vault-item-id>" }
    var debugDescription: String { description }

    func account(for field: VaultSecretField) -> String {
        "v1:\(rawValue.uuidString.lowercased()):\(field.rawValue)"
    }
}

/// A short-lived value with no serialization or raw-value accessor. `withString` scopes its use;
/// Swift's String/Data copy-on-write storage prevents a guarantee of immediate physical zeroing.
public struct VaultSecretValue: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private var storage: Data

    public init(_ value: String) throws {
        guard !value.isEmpty, !value.utf8.contains(0), value.utf8.count <= 16_384 else {
            throw KeychainBoundaryError.invalidIdentifier
        }
        storage = Data(value.utf8)
    }

    init(data: Data) throws {
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainBoundaryError.invalidIdentifier
        }
        try self.init(value)
    }

    func withString(_ body: (String) throws -> Void) rethrows {
        try body(String(decoding: storage, as: UTF8.self))
    }

    public var description: String { "<redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: EmptyCollection<Mirror.Child>(), displayStyle: .struct)
    }
}

/// Exact-item vault with no list/read-all operation. The caller must retain trusted item IDs.
/// This remains unintegrated: the fake-backed tests are contract tests, not live Keychain or
/// biometric acceptance. This adapter always fails closed on interaction; a separate owner-
/// initiated interactive flow and phone Face ID receipt validation remain unimplemented.
final class KeychainVault: @unchecked Sendable {
    private let client: any KeychainClient
    private let namespace: KeychainNamespace

    init(client: any KeychainClient = SystemKeychainClient(),
         namespace: KeychainNamespace = .production) {
        self.client = client
        self.namespace = namespace
    }

    func store(_ value: VaultSecretValue, for itemID: VaultItemID,
               field: VaultSecretField) throws {
        var data = Data()
        value.withString { data = Data($0.utf8) }
        defer { data.resetBytes(in: 0..<data.count) }
        try client.add(item(for: itemID, field: field), data: data)
    }

    func withSecret(for itemID: VaultItemID, field: VaultSecretField,
                    _ body: (VaultSecretValue) throws -> Void) throws {
        var data = try client.copy(item(for: itemID, field: field))
        defer { data.resetBytes(in: 0..<data.count) }
        let value = try VaultSecretValue(data: data)
        try body(value)
    }

    /// Deletes only supplied trusted IDs and known field accounts. Missing entries are harmless;
    /// authentication/storage failures propagate so callers can retry or hand off to the owner.
    func forget(itemIDs: [VaultItemID]) throws {
        for itemID in Set(itemIDs) {
            for field in VaultSecretField.allCases {
                do { try client.delete(item(for: itemID, field: field)) }
                catch KeychainBoundaryError.missingItem { continue }
            }
        }
    }

    private func item(for itemID: VaultItemID, field: VaultSecretField) -> ExactKeychainItem {
        ExactKeychainItem(service: namespace.vaultService,
                          account: itemID.account(for: field),
                          protection: .userPresenceWhenUnlocked)
    }
}

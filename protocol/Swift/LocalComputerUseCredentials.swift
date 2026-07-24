import CryptoKit
import Foundation
import Security

/// A high-entropy TLS pre-shared key used only for local Computer Use.
///
/// `accessKey` is the canonical unpadded Base64URL serialization used by
/// compatibility tests and secure storage. The SHA-256
/// `credentialID` is non-secret and may be published in Bonjour to select a
/// matching Keychain item. None of the textual representations are logged by
/// this type.
public struct LocalComputerUseCredential:
    Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public static let rawKeyByteCount = 32

    public let rawKey: Data
    public let credentialID: String
    public let accessKey: String
    public let displayAccessKey: String

    public init(rawKey: Data) throws {
        guard rawKey.count == Self.rawKeyByteCount else {
            throw LocalComputerUseCredentialError.invalidAccessKey
        }
        self.rawKey = rawKey
        accessKey = Self.base64URLEncoded(rawKey)
        displayAccessKey = Self.grouped(accessKey)
        credentialID = SHA256.hash(data: rawKey)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public init(accessKey: String) throws {
        let canonical = accessKey.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init)
            .joined()
        guard let rawKey = Self.base64URLDecoded(canonical),
              rawKey.count == Self.rawKeyByteCount,
              Self.base64URLEncoded(rawKey) == canonical else {
            throw LocalComputerUseCredentialError.invalidAccessKey
        }
        try self.init(rawKey: rawKey)
    }

    public static func generate() throws -> Self {
        var bytes = [UInt8](repeating: 0, count: rawKeyByteCount)
        let status = SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes)
        guard status == errSecSuccess else {
            throw LocalComputerUseCredentialError.randomGenerationFailed(
                status)
        }
        return try Self(rawKey: Data(bytes))
    }

    public var description: String {
        "LocalComputerUseCredential(id: \(credentialID), key: <redacted>)"
    }

    public var debugDescription: String { description }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecoded(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "-" || scalar == "_"
              }) else {
            return nil
        }
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.utf8.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    private static func grouped(_ value: String) -> String {
        var groups: [String] = []
        var start = value.startIndex
        while start < value.endIndex {
            let end = value.index(
                start,
                offsetBy: 4,
                limitedBy: value.endIndex) ?? value.endIndex
            groups.append(String(value[start ..< end]))
            start = end
        }
        return groups.joined(separator: " ")
    }
}

public enum LocalComputerUseCredentialError:
    Error, Equatable, LocalizedError, Sendable {
    case invalidAccessKey
    case invalidHostID
    case invalidCredentialID
    case randomGenerationFailed(OSStatus)
    case keychainFailure(OSStatus)
    case malformedStoredCredential
    case malformedStoredAccountBinding

    public var errorDescription: String? {
        switch self {
        case .invalidAccessKey:
            return "The automatic local pairing credential is invalid."
        case .invalidHostID:
            return "The local host identity is invalid."
        case .invalidCredentialID:
            return "The local credential identity is invalid."
        case .randomGenerationFailed:
            return "A secure automatic local pairing credential could not be generated."
        case .keychainFailure:
            return "The automatic local pairing credential could not be stored securely."
        case .malformedStoredCredential:
            return "The stored automatic local pairing credential is invalid."
        case .malformedStoredAccountBinding:
            return "The stored Apple Account binding is invalid."
        }
    }
}

/// Device-local storage for account-bound host credentials and each iOS
/// client's account/host copy. Items are explicitly non-synchronizable, so they
/// never move through iCloud. iOS additionally enforces a ThisDeviceOnly
/// accessibility class; macOS keeps the item in its local, non-syncing keychain.
public final class LocalComputerUseCredentialStore: @unchecked Sendable {
    public static let defaultService =
        "com.threadmark.remotedesktop.local-computer-use.v1"
    static let confirmedAccountBindingAccount =
        "account-binding.confirmed.v1"

    private static let lock = NSLock()
    private let service: String

    public init(service: String = defaultService) {
        self.service = service
    }

    /// Returns the last CloudKit account owner that this device positively
    /// resolved. A missing marker is distinct from a Keychain failure or a
    /// malformed marker so callers cannot silently skip account-change work.
    public func confirmedAccountBinding() throws -> CloudKitAccountBinding? {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        var query = baseQuery(account: Self.confirmedAccountBindingAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw LocalComputerUseCredentialError.keychainFailure(status)
        }
        guard let data = result as? Data,
              let rawValue = String(data: data, encoding: .utf8),
              let binding = CloudKitAccountBinding(rawValue: rawValue) else {
            throw LocalComputerUseCredentialError
                .malformedStoredAccountBinding
        }
        return binding
    }

    /// Persists a positive account resolution in a non-synchronizable Keychain
    /// item (and a ThisDeviceOnly item on platforms that support that class).
    public func setConfirmedAccountBinding(
        _ binding: CloudKitAccountBinding
    ) throws {
        let data = Data(binding.rawValue.utf8)
        Self.lock.lock()
        defer { Self.lock.unlock() }

        let status = SecItemUpdate(
            baseQuery(account: Self.confirmedAccountBindingAccount)
                as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw LocalComputerUseCredentialError.keychainFailure(status)
        }

        var attributes = baseQuery(
            account: Self.confirmedAccountBindingAccount)
        attributes[kSecValueData as String] = data
#if os(iOS)
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
#endif
        attributes[kSecAttrSynchronizable as String] = false
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw LocalComputerUseCredentialError.keychainFailure(addStatus)
        }
    }

    /// Clears the confirmed owner after CloudKit positively reports no
    /// account or a restricted account. Transient resolution failures must not
    /// call this method.
    public func clearConfirmedAccountBinding() throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let status = SecItemDelete(baseQuery(
            account: Self.confirmedAccountBindingAccount) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LocalComputerUseCredentialError.keychainFailure(status)
        }
    }

    /// Loads the durable key for this CloudKit account or atomically adopts an
    /// existing key if another caller won the first-creation race.
    public func hostCredential(
        accountBinding: CloudKitAccountBinding
    ) throws -> LocalComputerUseCredential {
        let account = hostAccount(accountBinding: accountBinding)
        Self.lock.lock()
        defer { Self.lock.unlock() }

        if let stored = try loadCredential(account: account) {
            return stored
        }
        let generated = try LocalComputerUseCredential.generate()
        do {
            try addCredential(generated, account: account)
            return generated
        } catch LocalComputerUseCredentialError.keychainFailure(
            errSecDuplicateItem) {
            guard let winner = try loadCredential(account: account) else {
                throw LocalComputerUseCredentialError.keychainFailure(
                    errSecDuplicateItem)
            }
            return winner
        }
    }

    /// Generates and replaces the host credential. Callers must republish the
    /// new fingerprint and intentionally re-pair clients after this succeeds.
    public func rotateHostCredential(
        accountBinding: CloudKitAccountBinding
    ) throws -> LocalComputerUseCredential {
        let account = hostAccount(accountBinding: accountBinding)
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let credential = try LocalComputerUseCredential.generate()
        try upsertCredential(credential, account: account)
        return credential
    }

    /// Returns only the exact account/host/fingerprint selected by CloudKit
    /// and Bonjour.
    /// Keychain errors and malformed items fail closed as an unavailable key.
    public func clientCredential(
        hostID: String,
        credentialID: String,
        accountBinding: CloudKitAccountBinding
    ) -> LocalComputerUseCredential? {
        guard let account = try? clientAccount(
                hostID: hostID,
                accountBinding: accountBinding),
              Self.isCredentialID(credentialID) else {
            return nil
        }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        do {
            guard let stored = try loadCredential(account: account) else {
                return nil
            }
            return stored.credentialID == credentialID ? stored : nil
        } catch {
            // A malformed account-bound item or any Keychain failure fails
            // closed. Unbound legacy credentials are never consulted.
            return nil
        }
    }

    public func saveClientCredential(
        _ credential: LocalComputerUseCredential,
        hostID: String,
        accountBinding: CloudKitAccountBinding
    ) throws {
        let account = try clientAccount(
            hostID: hostID,
            accountBinding: accountBinding)
        Self.lock.lock()
        defer { Self.lock.unlock() }
        // One Keychain item per account/host makes rotation a single update.
        // The fingerprint never selects an item from another account.
        try upsertCredential(credential, account: account)
    }

    public func removeClientCredential(
        hostID: String,
        credentialID: String,
        accountBinding: CloudKitAccountBinding
    ) {
        guard let account = try? clientAccount(
                hostID: hostID,
                accountBinding: accountBinding),
              Self.isCredentialID(credentialID) else {
            return
        }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let stored = try? loadCredential(account: account),
              stored.credentialID == credentialID else {
            return
        }
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private func hostAccount(
        accountBinding: CloudKitAccountBinding
    ) -> String {
        "host.\(accountBinding.rawValue)"
    }

    private func clientAccount(
        hostID: String,
        accountBinding: CloudKitAccountBinding
    ) throws -> String {
        guard Self.isBoundedIdentifier(hostID, maximumBytes: 128) else {
            throw LocalComputerUseCredentialError.invalidHostID
        }
        return "client.\(accountBinding.rawValue).\(hostID)"
    }

    private func loadCredential(
        account: String
    ) throws -> LocalComputerUseCredential? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw LocalComputerUseCredentialError.keychainFailure(status)
        }
        guard let rawKey = result as? Data else {
            throw LocalComputerUseCredentialError.malformedStoredCredential
        }
        do {
            return try LocalComputerUseCredential(rawKey: rawKey)
        } catch {
            throw LocalComputerUseCredentialError.malformedStoredCredential
        }
    }

    private func upsertCredential(
        _ credential: LocalComputerUseCredential,
        account: String
    ) throws {
        let status = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: credential.rawKey] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw LocalComputerUseCredentialError.keychainFailure(status)
        }
        try addCredential(credential, account: account)
    }

    private func addCredential(
        _ credential: LocalComputerUseCredential,
        account: String
    ) throws {
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = credential.rawKey
#if os(iOS)
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
#endif
        attributes[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw LocalComputerUseCredentialError.keychainFailure(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query = baseServiceQuery()
        query[kSecAttrAccount as String] = account
        return query
    }

    private func baseServiceQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // Never read or update a similarly named synchronizable item left
            // by an older build. The LAN key is deliberately device-local.
            kSecAttrSynchronizable as String: false,
        ]
    }

    private static func isBoundedIdentifier(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
                    && !CharacterSet.newlines.contains($0)
            }
    }

    private static func isCredentialID(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { byte in
                (byte >= 0x30 && byte <= 0x39)
                    || (byte >= 0x61 && byte <= 0x66)
            }
    }
}

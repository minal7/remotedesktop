import Foundation
import Security

enum DeviceIdentityStorageRead: Equatable {
    case value(String)
    case missing
    case failed(OSStatus)
}

enum DeviceIdentityStorageWrite: Equatable {
    case stored
    case duplicate
    case failed(OSStatus)
}

/// Serializes the process-wide check/create/cache sequence while still
/// resolving a cross-process first-writer race through Keychain.
///
/// An unavailable or malformed Keychain result is sticky for this process and
/// returns the empty identity. Callers already reject an empty sender/target
/// before advertising, pairing, or accepting a local route, so secure storage
/// failure cannot silently create a process-only identity that changes later.
final class DeviceIdentityResolver: @unchecked Sendable {
    typealias Reader = () -> DeviceIdentityStorageRead
    typealias Writer = (String) -> DeviceIdentityStorageWrite
    typealias Generator = () -> String

    private enum CachedResolution {
        case unresolved
        case available(String)
        case unavailable
    }

    init(
        read: @escaping Reader,
        write: @escaping Writer,
        generate: @escaping Generator
    ) {
        self.read = read
        self.write = write
        self.generate = generate
    }

    func get() -> String {
        lock.lock()
        defer { lock.unlock() }

        switch cachedResolution {
        case .available(let value):
            return value
        case .unavailable:
            return ""
        case .unresolved:
            break
        }

        guard let value = resolve() else {
            cachedResolution = .unavailable
            return ""
        }
        cachedResolution = .available(value)
        return value
    }

    private func resolve() -> String? {
        switch read() {
        case .value(let existing):
            return Self.canonicalIdentity(existing)
        case .failed:
            return nil
        case .missing:
            break
        }

        guard let fresh = Self.canonicalIdentity(generate()) else {
            return nil
        }
        switch write(fresh) {
        case .stored:
            return fresh
        case .duplicate:
            // Another process using the same application identity won the
            // atomic add. Adopt only its validated durable value.
            guard case .value(let winner) = read() else { return nil }
            return Self.canonicalIdentity(winner)
        case .failed:
            return nil
        }
    }

    private static func canonicalIdentity(_ value: String) -> String? {
        guard value.utf8.count == 36,
              let uuid = UUID(uuidString: value),
              uuid.uuidString == value.uppercased() else {
            return nil
        }
        return uuid.uuidString
    }

    private let read: Reader
    private let write: Writer
    private let generate: Generator
    private let lock = NSLock()
    private var cachedResolution: CachedResolution = .unresolved
}

/// A stable per-install UUID, persisted in the Keychain so it survives
/// app reinstalls and iCloud sign-outs. Used as `senderID` / `targetID`
/// on every `WebRTCSignal` record.
///
/// Why Keychain instead of `UserDefaults`: Keychain entries persist
/// across iOS app deletions (when the device isn't wiped) and survive
/// macOS "Reset All Settings." That matters because the host and client
/// need to keep recognizing each other as the same peer across runs —
/// if the ID resets, any pending signaling records become unroutable
/// orphans.
public enum DeviceIdentity {
    private static let service = "com.threadmark.remotedesktop.deviceID"
    private static let account = "singleton"
    private static let resolver = DeviceIdentityResolver(
        read: readFromKeychain,
        write: addToKeychain,
        generate: { UUID().uuidString })

    /// Returns the cached ID, creating and persisting a new one on
    /// first call. Returns an empty, fail-closed identity when secure storage
    /// cannot provide or atomically persist a canonical UUID.
    public static func get() -> String {
        resolver.get()
    }

    // MARK: -

    private static func readFromKeychain() -> DeviceIdentityStorageRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return .missing
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return .failed(status == errSecSuccess ? errSecDecode : status)
        }
        return .value(value)
    }

    private static func addToKeychain(
        _ value: String
    ) -> DeviceIdentityStorageWrite {
        let data = Data(value.utf8)
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrSynchronizable as String: false,
        ]
#if os(iOS)
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
#else
        // After first unlock matches the lifecycle of the macOS host, which
        // cannot run before the login keychain is available.
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlock
#endif
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return .stored
        case errSecDuplicateItem:
            return .duplicate
        default:
            return .failed(status)
        }
    }
}

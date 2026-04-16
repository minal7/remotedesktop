import Foundation
import Security

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

    /// Returns the cached ID, creating and persisting a new one on
    /// first call. Thread-safe: Keychain APIs serialize internally.
    public static func get() -> String {
        if let existing = readFromKeychain() {
            return existing
        }
        let fresh = UUID().uuidString
        writeToKeychain(fresh)
        return fresh
    }

    // MARK: -

    private static func readFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private static func writeToKeychain(_ value: String) {
        let data = Data(value.utf8)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // After first unlock: usable when device is unlocked at least
            // once since boot. Matches the lifecycle of the apps — neither
            // runs before first unlock anyway.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        _ = SecItemAdd(attrs as CFDictionary, nil)
    }
}

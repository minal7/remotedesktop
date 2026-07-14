import Foundation
import Security

/// Write-ahead recovery record for one in-flight privileged prompt. Prompt
/// text stays in the device Keychain rather than UserDefaults, and the same
/// message/session IDs are reused after an app restart so the host's durable
/// at-most-once ledger can replay a result without repeating the task.
struct ComputerUsePendingPrompt: Codable, Equatable, Sendable {
    let hostID: String
    let pairingCode: String
    let sessionID: String
    let messageID: String
    let prompt: String
    /// The already-encoded structured prompt. Retrying or recovering after an
    /// app termination must reuse this byte-for-byte instead of rebuilding
    /// conversation context that may have changed in memory.
    let wireBody: String?
    let createdAt: Date

    init(
        hostID: String,
        pairingCode: String,
        sessionID: String,
        messageID: String,
        prompt: String,
        wireBody: String? = nil,
        createdAt: Date
    ) {
        self.hostID = hostID
        self.pairingCode = pairingCode
        self.sessionID = sessionID
        self.messageID = messageID
        self.prompt = prompt
        self.wireBody = wireBody
        self.createdAt = createdAt
    }

    var exactWireBody: String { wireBody ?? prompt }
}

final class ComputerUsePendingPromptStore: @unchecked Sendable {
    static let shared = ComputerUsePendingPromptStore()

    private let service = "com.threadmark.remotedesktop.computer-use.pending-prompt"
    private let maximumAge: TimeInterval = 24 * 60 * 60

    func load(hostID: String, pairingCode: String) -> ComputerUsePendingPrompt? {
        var query = baseQuery(hostID: hostID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let pending = try? JSONDecoder().decode(
                ComputerUsePendingPrompt.self,
                from: data),
              pending.hostID == hostID,
              pending.pairingCode == pairingCode,
              Date().timeIntervalSince(pending.createdAt) <= maximumAge else {
            remove(hostID: hostID)
            return nil
        }
        return pending
    }

    func save(_ pending: ComputerUsePendingPrompt) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        remove(hostID: pending.hostID)
        var attributes = baseQuery(hostID: pending.hostID)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        _ = SecItemAdd(attributes as CFDictionary, nil)
    }

    func remove(hostID: String) {
        SecItemDelete(baseQuery(hostID: hostID) as CFDictionary)
    }

    private func baseQuery(hostID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostID,
        ]
    }
}

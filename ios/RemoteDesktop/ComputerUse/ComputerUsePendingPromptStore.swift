import Foundation
import Security

struct ComputerUsePendingApprovalDecision: Codable, Equatable, Sendable {
    let request: ComputerUseApprovalRequest
    let approved: Bool
    /// The exact response bytes are persisted before transmission so an
    /// ambiguous CloudKit error or app relaunch can only retry the same choice.
    let responseBody: String
}

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
    /// Highest lifecycle control revision issued for this task. Optional keeps
    /// Keychain records written by pre-revision clients decodable.
    let controlRevision: UInt64?
    /// The lifecycle kind paired with `controlRevision`. Recovery replays this
    /// exact pair instead of allocating a newer intent or accidentally
    /// refreshing a paused/cancelled Prompt first.
    let lastControlKind: ComputerUseEnvelope.Kind?
    /// A locked, durable approval choice. It is removed only by a terminal task
    /// result or a genuinely new approval request ID.
    let approvalDecision: ComputerUsePendingApprovalDecision?
    /// Exact bounded guidance for a resumable person-only handoff. Presence is
    /// also durable proof that the active paused task's typed outcome is
    /// `userInterventionRequired`; older recovery records decode it as `nil`.
    let interventionGuidance: String?

    init(
        hostID: String,
        pairingCode: String,
        sessionID: String,
        messageID: String,
        prompt: String,
        wireBody: String? = nil,
        createdAt: Date,
        controlRevision: UInt64? = nil,
        lastControlKind: ComputerUseEnvelope.Kind? = nil,
        approvalDecision: ComputerUsePendingApprovalDecision? = nil,
        interventionGuidance: String? = nil
    ) {
        self.hostID = hostID
        self.pairingCode = pairingCode
        self.sessionID = sessionID
        self.messageID = messageID
        self.prompt = prompt
        self.wireBody = wireBody
        self.createdAt = createdAt
        self.controlRevision = controlRevision
        self.lastControlKind = lastControlKind
        self.approvalDecision = approvalDecision
        self.interventionGuidance = interventionGuidance.map {
            String($0
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(ComputerUseStatusSignal.maximumInterventionCharacters))
        }
    }

    var exactWireBody: String { wireBody ?? prompt }
}

protocol ComputerUsePendingPromptStoring: Sendable {
    func load(hostID: String, pairingCode: String) -> ComputerUsePendingPrompt?
    @discardableResult
    func save(_ pending: ComputerUsePendingPrompt) -> Bool
    func remove(hostID: String)
}

final class ComputerUsePendingPromptStore:
    ComputerUsePendingPromptStoring,
    @unchecked Sendable
{
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

    @discardableResult
    func save(_ pending: ComputerUsePendingPrompt) -> Bool {
        guard let data = try? JSONEncoder().encode(pending) else { return false }
        let query = baseQuery(hostID: pending.hostID)
        let updates: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            updates as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
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

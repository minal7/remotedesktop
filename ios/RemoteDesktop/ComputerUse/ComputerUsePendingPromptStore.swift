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
    /// Opaque owner of a local LAN task. CloudKit/WebRTC tasks remain nil.
    /// Storing the canonical digest keeps older optional-field records
    /// decodable without making the protocol type Codable.
    let localAccountBindingRawValue: String?
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
        localAccountBinding: CloudKitAccountBinding? = nil,
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
        self.localAccountBindingRawValue = localAccountBinding?.rawValue
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

    var localAccountBinding: CloudKitAccountBinding? {
        localAccountBindingRawValue.flatMap(CloudKitAccountBinding.init)
    }

    var hasCanonicalLocalAccountBinding: Bool {
        localAccountBindingRawValue == nil || localAccountBinding != nil
    }

    /// Rebinds only the ephemeral discovery code after the same Mac has been
    /// authenticated with its stable host identity and TLS credential. Every
    /// task identity and byte of the original prompt remains unchanged so the
    /// host ledger can replay a completed result instead of executing twice.
    func rebindingPairingCode(_ pairingCode: String) -> Self {
        Self(
            hostID: hostID,
            pairingCode: pairingCode,
            sessionID: sessionID,
            messageID: messageID,
            prompt: prompt,
            wireBody: wireBody,
            createdAt: createdAt,
            localAccountBinding: localAccountBinding,
            controlRevision: controlRevision,
            lastControlKind: lastControlKind,
            approvalDecision: approvalDecision,
            interventionGuidance: interventionGuidance)
    }
}

protocol ComputerUsePendingPromptStoring: Sendable {
    func load(hostID: String, pairingCode: String) -> ComputerUsePendingPrompt?
    func load(
        hostID: String,
        pairingCode: String,
        localAccountBinding: CloudKitAccountBinding?
    ) -> ComputerUsePendingPrompt?
    func loadForLocalRecovery(
        hostID: String,
        localAccountBinding: CloudKitAccountBinding
    ) -> ComputerUsePendingPrompt?
    @discardableResult
    func save(_ pending: ComputerUsePendingPrompt) -> Bool
    func remove(hostID: String)
    func remove(
        hostID: String,
        localAccountBinding: CloudKitAccountBinding?
    )
}

extension ComputerUsePendingPromptStoring {
    func loadForLocalRecovery(
        hostID: String,
        localAccountBinding: CloudKitAccountBinding
    ) -> ComputerUsePendingPrompt? {
        // Alternate stores that cannot query by stable account/host identity
        // safely decline recovery. The production Keychain store overrides
        // this with its account-namespaced lookup.
        nil
    }

    func load(
        hostID: String,
        pairingCode: String,
        localAccountBinding: CloudKitAccountBinding?
    ) -> ComputerUsePendingPrompt? {
        guard let pending = load(
                hostID: hostID,
                pairingCode: pairingCode),
              pending.hasCanonicalLocalAccountBinding,
              pending.localAccountBinding == localAccountBinding else {
            return nil
        }
        return pending
    }

    func remove(
        hostID: String,
        localAccountBinding: CloudKitAccountBinding?
    ) {
        // Test and alternate stores that keep one record per host retain their
        // existing behavior. The production Keychain store overrides this to
        // remove only the exact account namespace.
        remove(hostID: hostID)
    }
}

final class ComputerUsePendingPromptStore:
    ComputerUsePendingPromptStoring,
    @unchecked Sendable
{
    static let shared = ComputerUsePendingPromptStore()

    private let service: String
    private let maximumAge: TimeInterval = 24 * 60 * 60

    init(
        service: String =
            "com.threadmark.remotedesktop.computer-use.pending-prompt"
    ) {
        self.service = service
    }

    func load(hostID: String, pairingCode: String) -> ComputerUsePendingPrompt? {
        guard let pending = loadPending(
                hostID: hostID,
                localAccountBinding: nil),
              pending.pairingCode == pairingCode else { return nil }
        return pending
    }

    func load(
        hostID: String,
        pairingCode: String,
        localAccountBinding: CloudKitAccountBinding?
    ) -> ComputerUsePendingPrompt? {
        guard let pending = loadPending(
                hostID: hostID,
                localAccountBinding: localAccountBinding),
              pending.pairingCode == pairingCode else { return nil }
        return pending
    }

    /// Loads by stable host identity without accepting the old pairing code as
    /// authentication. Callers must first validate `localAccountBinding`, then
    /// complete a TLS handshake using the exact stored credential fingerprint
    /// before mutating or retransmitting the recovered task.
    func loadForLocalRecovery(
        hostID: String,
        localAccountBinding: CloudKitAccountBinding
    ) -> ComputerUsePendingPrompt? {
        loadPending(
            hostID: hostID,
            localAccountBinding: localAccountBinding)
    }

    private func loadPending(
        hostID: String,
        localAccountBinding: CloudKitAccountBinding?
    ) -> ComputerUsePendingPrompt? {
        var query = baseQuery(
            hostID: hostID,
            localAccountBinding: localAccountBinding)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              let pending = try? JSONDecoder().decode(
                ComputerUsePendingPrompt.self,
                from: data),
              pending.hostID == hostID,
              pending.hasCanonicalLocalAccountBinding,
              pending.localAccountBinding == localAccountBinding,
              Date().timeIntervalSince(pending.createdAt) <= maximumAge else {
            remove(
                hostID: hostID,
                localAccountBinding: localAccountBinding)
            return nil
        }
        return pending
    }

    @discardableResult
    func save(_ pending: ComputerUsePendingPrompt) -> Bool {
        guard pending.hasCanonicalLocalAccountBinding else { return false }
        guard let data = try? JSONEncoder().encode(pending) else { return false }
        let query = baseQuery(
            hostID: pending.hostID,
            localAccountBinding: pending.localAccountBinding)
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
        remove(hostID: hostID, localAccountBinding: nil)
    }

    func remove(
        hostID: String,
        localAccountBinding: CloudKitAccountBinding?
    ) {
        SecItemDelete(baseQuery(
            hostID: hostID,
            localAccountBinding: localAccountBinding) as CFDictionary)
    }

    private func baseQuery(
        hostID: String,
        localAccountBinding: CloudKitAccountBinding?
    ) -> [String: Any] {
        let account = if let localAccountBinding {
            "account.\(localAccountBinding.rawValue).host.\(hostID)"
        } else {
            hostID
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

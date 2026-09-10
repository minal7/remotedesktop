import Foundation
import Security

struct ComputerUsePendingApprovalDecision: Codable, Equatable, Sendable {
    let request: ComputerUseApprovalRequest
    let approved: Bool
    /// The exact response bytes are persisted before transmission so an
    /// ambiguous CloudKit error or app relaunch can only retry the same choice.
    let responseBody: String
}

struct ComputerUsePendingQuestion: Codable, Equatable, Sendable {
    let reference: ComputerUseClarificationReference
    let text: String
    let answerPolicy: ComputerUseClarificationAnswerPolicy?
    let receivedAt: Date
    let validUntil: Date
    let draft: String?
    enum Failure: Error { case invalid }
    init(reference: ComputerUseClarificationReference, text: String, answerPolicy: ComputerUseClarificationAnswerPolicy?,
         receivedAt: Date, validUntil: Date, draft: String? = nil) throws {
        guard ComputerUseClarificationText.isValid(text), receivedAt.timeIntervalSince1970.isFinite,
              validUntil.timeIntervalSince1970.isFinite, validUntil > receivedAt,
              validUntil <= reference.expiresAt, validUntil <= receivedAt.addingTimeInterval(600),
              draft.map({ $0.count <= ComputerUsePromptRequest.maximumPromptLength && $0.utf8.count <= 32 * 1_024 }) ?? true else {
            throw Failure.invalid
        }
        self.reference = reference; self.text = text; self.answerPolicy = answerPolicy
        self.receivedAt = receivedAt; self.validUntil = validUntil; self.draft = draft
    }
    private enum CodingKeys: String, CodingKey { case reference, text, answerPolicy, receivedAt, validUntil, draft }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(reference: values.decode(ComputerUseClarificationReference.self, forKey: .reference),
            text: values.decode(String.self, forKey: .text), answerPolicy: values.decodeIfPresent(ComputerUseClarificationAnswerPolicy.self, forKey: .answerPolicy),
            receivedAt: values.decode(Date.self, forKey: .receivedAt), validUntil: values.decode(Date.self, forKey: .validUntil),
            draft: values.decodeIfPresent(String.self, forKey: .draft))
    }
    func withDraft(_ draft: String?) throws -> Self {
        try .init(reference: reference, text: text, answerPolicy: answerPolicy, receivedAt: receivedAt, validUntil: validUntil, draft: draft)
    }
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
    /// Highest issued or observed lifecycle revision, used for allocation.
    /// Optional keeps pre-revision Keychain records decodable.
    let controlRevision: UInt64?
    /// Highest revision actually acknowledged by the host. Local supersession
    /// can invalidate an issued revision, but never forget an applied one.
    let acknowledgedControlRevision: UInt64?
    /// The lifecycle kind paired with `lastControlRevision`. Recovery replays
    /// that original pair instead of allocating a newer intent or accidentally
    /// refreshing a paused/cancelled Prompt first.
    let lastControlKind: ComputerUseEnvelope.Kind?
    /// Original command revision, separate from the allocation/acknowledgement
    /// high-water marks that may advance before a replay after relaunch.
    let lastControlRevision: UInt64?
    /// Latest host clock observed, and the clock frozen with the last issued
    /// phone intent. These are different after local takeover or handback.
    let hostControlEpoch: UInt64?
    let lastControlHostEpoch: UInt64?
    /// Recover a host-owned pause without inventing a new phone Pause.
    let hostControlPaused: Bool?
    /// A locked, durable approval choice. A terminal result, authoritative
    /// intervention or new approval request can retire it.
    let approvalDecision: ComputerUsePendingApprovalDecision?
    /// Exact bounded guidance for a resumable person-only handoff. Presence is
    /// also durable proof that the active paused task's typed outcome is
    /// `userInterventionRequired`; older recovery records decode it as `nil`.
    let interventionGuidance: String?
    /// Original local deadline of a question whose answer negotiated retry.
    /// Replays/relaunches must not restart the client's question lifetime.
    let clarificationValidUntil: Date?
    /// A terminal question awaiting the person. Recovery probes its native
    /// owner; it must never retransmit this record as an executable prompt.
    let question: ComputerUsePendingQuestion?

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
        acknowledgedControlRevision: UInt64? = nil,
        lastControlKind: ComputerUseEnvelope.Kind? = nil,
        lastControlRevision: UInt64? = nil,
        hostControlEpoch: UInt64? = nil,
        lastControlHostEpoch: UInt64? = nil,
        hostControlPaused: Bool? = nil,
        approvalDecision: ComputerUsePendingApprovalDecision? = nil,
        interventionGuidance: String? = nil,
        clarificationValidUntil: Date? = nil,
        question: ComputerUsePendingQuestion? = nil
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
        self.acknowledgedControlRevision = acknowledgedControlRevision
        self.lastControlKind = lastControlKind
        self.lastControlRevision = lastControlRevision
        self.hostControlEpoch = hostControlEpoch
        self.lastControlHostEpoch = lastControlHostEpoch
        self.hostControlPaused = hostControlPaused
        self.approvalDecision = approvalDecision
        self.clarificationValidUntil = clarificationValidUntil
        self.question = question
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

    var hasValidQuestionRecovery: Bool {
        guard let question else { return true }
        guard controlRevision == nil, acknowledgedControlRevision == nil, lastControlKind == nil,
              lastControlRevision == nil, hostControlEpoch == nil, lastControlHostEpoch == nil,
              hostControlPaused == nil, approvalDecision == nil, interventionGuidance == nil,
              let wireBody, let request = try? ComputerUsePromptRequest.decodeBody(wireBody),
              request.prompt.utf8.elementsEqual(prompt.utf8) else { return false }
        return question.reference.taskID == messageID || request.clarification == question.reference
    }

    func retainingQuestion(_ question: ComputerUsePendingQuestion) -> Self {
        .init(hostID: hostID, pairingCode: pairingCode, sessionID: sessionID, messageID: messageID,
            prompt: prompt, wireBody: wireBody, createdAt: createdAt, localAccountBinding: localAccountBinding,
            clarificationValidUntil: clarificationValidUntil, question: question)
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
            acknowledgedControlRevision: acknowledgedControlRevision,
            lastControlKind: lastControlKind,
            lastControlRevision: lastControlRevision,
            hostControlEpoch: hostControlEpoch,
            lastControlHostEpoch: lastControlHostEpoch,
            hostControlPaused: hostControlPaused,
            approvalDecision: approvalDecision,
            interventionGuidance: interventionGuidance,
            clarificationValidUntil: clarificationValidUntil, question: question)
    }
}

enum ComputerUsePendingPromptReadError: LocalizedError {
    case unavailable
    case invalidRecord
    case pairingChanged

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Secure recovery data could not be read. Unlock this device and reconnect; the saved request has been kept."
        case .invalidRecord:
            return "The saved AI request could not be decoded safely. Its recovery data has been kept and no new request was sent."
        case .pairingChanged:
            return "The saved AI request belongs to an earlier connection. Reconnect to recover it before sending another request."
        }
    }
}

protocol ComputerUsePendingPromptStoring: Sendable {
    /// A nil result means a successful lookup found no usable record. Read
    /// failures must remain distinguishable so callers cannot replace an
    /// unseen task, approval, or question with a fresh request.
    func read(hostID: String, pairingCode: String,
              localAccountBinding: CloudKitAccountBinding?) throws -> ComputerUsePendingPrompt?
    func readForLocalRecovery(hostID: String,
                              localAccountBinding: CloudKitAccountBinding) throws -> ComputerUsePendingPrompt?
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
    func read(hostID: String, pairingCode: String,
              localAccountBinding: CloudKitAccountBinding?) throws -> ComputerUsePendingPrompt? {
        load(hostID: hostID, pairingCode: pairingCode, localAccountBinding: localAccountBinding)
    }

    func readForLocalRecovery(hostID: String,
                              localAccountBinding: CloudKitAccountBinding) throws -> ComputerUsePendingPrompt? {
        loadForLocalRecovery(hostID: hostID, localAccountBinding: localAccountBinding)
    }

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
              pending.hasValidQuestionRecovery,
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

/// The production adapter and deterministic fixtures share the same store
/// decision logic. A failed read is never translated into a delete operation.
protocol ComputerUsePendingPromptKeychain: Sendable {
    func copy(_ query: [String: Any]) -> (OSStatus, Data?)
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

private struct SystemComputerUsePendingPromptKeychain: ComputerUsePendingPromptKeychain {
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

final class ComputerUsePendingPromptStore:
    ComputerUsePendingPromptStoring,
    @unchecked Sendable
{
    static let shared = ComputerUsePendingPromptStore()

    private let service: String
    private let keychain: any ComputerUsePendingPromptKeychain
    private let maximumAge: TimeInterval = 24 * 60 * 60

    init(
        service: String =
            "com.threadmark.remotedesktop.computer-use.pending-prompt",
        keychain: any ComputerUsePendingPromptKeychain = SystemComputerUsePendingPromptKeychain()
    ) {
        self.service = service
        self.keychain = keychain
    }

    func load(hostID: String, pairingCode: String) -> ComputerUsePendingPrompt? {
        try? read(hostID: hostID, pairingCode: pairingCode, localAccountBinding: nil)
    }

    func load(
        hostID: String,
        pairingCode: String,
        localAccountBinding: CloudKitAccountBinding?
    ) -> ComputerUsePendingPrompt? {
        try? read(hostID: hostID, pairingCode: pairingCode, localAccountBinding: localAccountBinding)
    }

    /// Loads by stable host identity without accepting the old pairing code as
    /// authentication. Callers must first validate `localAccountBinding`, then
    /// complete a TLS handshake using the exact stored credential fingerprint
    /// before mutating or retransmitting the recovered task.
    func loadForLocalRecovery(
        hostID: String,
        localAccountBinding: CloudKitAccountBinding
    ) -> ComputerUsePendingPrompt? {
        try? readForLocalRecovery(hostID: hostID, localAccountBinding: localAccountBinding)
    }

    func read(hostID: String, pairingCode: String,
              localAccountBinding: CloudKitAccountBinding?) throws -> ComputerUsePendingPrompt? {
        guard let pending = try readPending(hostID: hostID, localAccountBinding: localAccountBinding) else { return nil }
        guard pending.pairingCode == pairingCode else { throw ComputerUsePendingPromptReadError.pairingChanged }
        return pending
    }

    func readForLocalRecovery(hostID: String,
                              localAccountBinding: CloudKitAccountBinding) throws -> ComputerUsePendingPrompt? {
        try readPending(hostID: hostID, localAccountBinding: localAccountBinding)
    }

    private func readPending(
        hostID: String,
        localAccountBinding: CloudKitAccountBinding?
    ) throws -> ComputerUsePendingPrompt? {
        var query = baseQuery(
            hostID: hostID,
            localAccountBinding: localAccountBinding)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = keychain.copy(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ComputerUsePendingPromptReadError.unavailable }
        guard let data,
              let pending = try? JSONDecoder().decode(
                ComputerUsePendingPrompt.self,
                from: data),
              pending.hostID == hostID,
              pending.hasCanonicalLocalAccountBinding,
              pending.hasValidQuestionRecovery,
              pending.localAccountBinding == localAccountBinding else {
            throw ComputerUsePendingPromptReadError.invalidRecord
        }
        // Expired data is not actionable, but lookup remains read-only. A
        // concurrent replacement must never be erased by this older read.
        guard Date().timeIntervalSince(pending.question?.receivedAt ?? pending.createdAt) <= maximumAge else { return nil }
        return pending
    }

    @discardableResult
    func save(_ pending: ComputerUsePendingPrompt) -> Bool {
        guard pending.hasCanonicalLocalAccountBinding, pending.hasValidQuestionRecovery else { return false }
        guard let data = try? JSONEncoder().encode(pending) else { return false }
        let query = baseQuery(
            hostID: pending.hostID,
            localAccountBinding: pending.localAccountBinding)
        let updates: [String: Any] = [kSecValueData as String: data]
        let updateStatus = keychain.update(query, attributes: updates)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return keychain.add(attributes) == errSecSuccess
    }

    func remove(hostID: String) {
        remove(hostID: hostID, localAccountBinding: nil)
    }

    func remove(
        hostID: String,
        localAccountBinding: CloudKitAccountBinding?
    ) {
        _ = keychain.delete(baseQuery(
            hostID: hostID,
            localAccountBinding: localAccountBinding))
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

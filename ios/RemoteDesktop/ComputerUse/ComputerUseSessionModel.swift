import Foundation
import Combine

protocol ComputerUseSessionChannel: Sendable {
    @discardableResult
    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        to explicitTargetID: String?,
        sessionID explicitSessionID: String?,
        messageID explicitMessageID: String?
    ) async throws -> ComputerUseEnvelope

    func poll() async throws -> [ComputerUseEnvelope]
    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws
}

extension ComputerUseSessionChannel {
    @discardableResult
    func send(
        kind: ComputerUseEnvelope.Kind,
        body: String,
        messageID: String? = nil
    ) async throws -> ComputerUseEnvelope {
        try await send(
            kind: kind,
            body: body,
            to: nil,
            sessionID: nil,
            messageID: messageID)
    }
}

@MainActor
final class ComputerUseSessionModel: ObservableObject {
    struct ChatMessage: Identifiable, Equatable {
        enum Author: Equatable {
            case user
            case assistant
            case system
        }

        let id: String
        let author: Author
        let text: String
        let createdAt: Date
        var approvedActionEvidence: ComputerUseApprovedActionEvidence? = nil
        var researchProgress: ComputerUseResearchProgress? = nil
    }

    enum State: Equatable {
        case ready
        case working
        case paused
        case approvalRequired(ComputerUseApprovalRequest)
        case error(String)
    }

    enum ComposerMode: Equatable {
        case request
        case legacyAnswer
        case answer(ComputerUseClarificationReference, validUntil: Date)
        case recoveringAnswer
        case expiredAnswer
    }

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var state: State = .ready {
        didSet { onRemoteScreenObscurationChange?() }
    }
    @Published private(set) var statusText = "Ready for a request"
    /// Bounded, task-scoped host progress retained independently of the current
    /// status label. A LAN poll can deliver several ordered updates together;
    /// SwiftUI may render only the final label, but accessibility and shipped-
    /// path acceptance must still be able to inspect every completed step.
    @Published private(set) var taskProgressHistory: [String] = []
    @Published private(set) var retryPrompt: String?
    @Published private(set) var composerMode: ComposerMode = .request
    @Published private(set) var restoredClarificationDraft: String?
    @Published private(set) var clarificationChoices: [ComputerUseClarificationChoice]?
    /// The newest machine-readable result received for the active or most
    /// recently finished request. Legacy hosts leave this `nil`.
    @Published private(set) var latestTerminalOutcome: ComputerUseTerminalOutcome?
    /// Becomes true only when `SessionModel` receives the authenticated host
    /// hello and calls `start()`. CloudKit recovery and lifecycle traffic must
    /// never leave the phone while the WebRTC peer is still unauthenticated.
    @Published private(set) var isConnected = false {
        didSet { onRemoteScreenObscurationChange?() }
    }
    /// Embedded Mail MCP tasks can leave a small compose/result window above
    /// unrelated desktop content. Cover the remote pixels for the task's full
    /// lifecycle, starting before the request leaves the phone, until the
    /// person explicitly chooses to reveal the Mac again.
    @Published private(set) var isLiveScreenPrivacyShielded = false {
        didSet { onRemoteScreenObscurationChange?() }
    }

    /// Synchronous owner notification: input must close when pixels are
    /// covered or AI control resumes, without waiting for SwiftUI to remove
    /// keyboard responders.
    var onRemoteScreenObscurationChange: (@MainActor () -> Void)?
    var isRemoteScreenObscured: Bool {
        if isLiveScreenPrivacyShielded { return true }
        if case .approvalRequired = state { return true }
        return false
    }

    var hasActivePrompt: Bool { activePromptID != nil }
    var isCancellationPending: Bool {
        activePromptID != nil && lastControlKind == .cancel
    }
    var interventionGuidance: String? { userInterventionGuidance }
    /// A received acknowledgement for the current task/control clocks. This
    /// is a protocol fact, not proof that all native in-flight work has joined.
    var hasHostPauseAcknowledgement: Bool {
        guard !isStopped, isConnected, !requiresRecoveryReconnect, transportNotice == nil,
              unpersistedHostControlEpoch == nil, case .paused = state,
              let acknowledgement = pauseAcknowledgement else { return false }
        return acknowledgement.taskID == activePromptID && acknowledgement.hostEpoch == hostControlEpoch
            && acknowledgement.appliedRevision >= requiredControlRevision && lastControlKind != .cancel
    }
    var pauseAcknowledgementLabel: String {
        hasHostPauseAcknowledgement ? "Mac acknowledged pause" : "Pause not yet confirmed"
    }
    var isAnsweringClarification: Bool {
        if case .answer = composerMode { return true }
        return composerMode == .legacyAnswer
    }
    var canStartNewRequest: Bool { !requiresRecoveryReconnect && activePromptID == nil && composerMode != .request }
    var canRetryQuestionRecovery: Bool {
        guard isConnected, composerMode == .recoveringAnswer, waitingQuestionRecord != nil else { return false }
        if case .error = state { return true }
        return false
    }

    let hostName: String
    private let channel: any ComputerUseSessionChannel
    private let hostID: String
    private let pairingCode: String
    private let sessionID: String
    private let pendingStore: any ComputerUsePendingPromptStoring
    private var activePendingRecord: ComputerUsePendingPrompt?
    /// An unreadable initial record may own a different session ID. Only a
    /// newly authenticated connection may select that recovered session.
    private var requiresRecoveryReconnect = false
    private let localAccountBinding: CloudKitAccountBinding?
    private var pollingTask: Task<Void, Never>?
    private var responseTimeoutTask: Task<Void, Never>?
    private var promptRefreshTask: Task<Void, Never>?
    private var controlRetryTask: Task<Void, Never>?
    private var clarificationExpiryTask: Task<Void, Never>?
    private var clarificationAnswerPolicy: ComputerUseClarificationAnswerPolicy?
    private var activeClarificationChoices: [ComputerUseClarificationChoice]?
    private var outboundTasks: [UUID: Task<Void, Never>] = [:]
    /// Monotonically identifies the newest local intent or authoritative host
    /// state. An older CloudKit completion may arrive after a person resumes,
    /// stops, or starts another request; it must not overwrite that newer UI.
    private var stateGeneration: UInt64 = 0
    private var isStopped = true
    private let responseTimeoutDuration: Duration
    private let promptRefreshInterval: Duration
    private let now: () -> Date
    private var transportNotice: String?
    private var retryMessageID: String?
    private var retryWireBody: String?
    private var activePromptID: String?
    private var activePromptText: String?
    private var activePromptBody: String?
    private var activePromptCreatedAt: Date?
    private var activeClarificationValidUntil: Date?
    private var waitingQuestionRecord: ComputerUsePendingPrompt?
    private var questionDraft: String?
    private var questionDraftSaveTask: Task<Void, Never>?
    private var questionProbeID: UUID?
    private var questionProbeSendTask: Task<Void, Never>?
    private var questionProbeTimeoutTask: Task<Void, Never>?
    private let questionRecoveryTimeout: Duration
    private var controlRevision: UInt64 = 0
    private var acknowledgedControlRevision: UInt64 = 0
    private var lastControlKind: ComputerUseEnvelope.Kind?
    private var lastControlRevision: UInt64 = 0
    private var hostControlEpoch: UInt64 = 0
    private var lastControlHostEpoch: UInt64 = 0
    private var hostControlPaused: Bool?
    private struct PauseAcknowledgement {
        let taskID: String
        let hostEpoch: UInt64
        let appliedRevision: UInt64
    }
    // Deliberately absent from recovery storage: restored intent/state is not
    // a received acknowledgement on this session's channel.
    @Published private var pauseAcknowledgement: PauseAcknowledgement?
    private var unpersistedHostControlEpoch: UInt64?
    private var pendingControlIntent: PendingControlIntent?
    private var approvalSubmission: ComputerUsePendingApprovalDecision?
    private var approvalResponseInFlightRequestID: String?
    private var userInterventionGuidance: String?
    private static let maximumTaskProgressEntries = 16

    private struct PendingControlIntent: Equatable {
        let taskID: String
        let revision: UInt64
        let kind: ComputerUseEnvelope.Kind
        let hostControlEpoch: UInt64
    }

    init(
        hostName: String,
        pairingCode: String,
        hostID: String,
        sessionID: String? = nil,
        localAccountBinding: CloudKitAccountBinding? = nil,
        pendingStore: any ComputerUsePendingPromptStoring = ComputerUsePendingPromptStore.shared,
        channel: any ComputerUseSessionChannel,
        responseTimeoutDuration: Duration = .seconds(20 * 60),
        promptRefreshInterval: Duration = .seconds(30),
        questionRecoveryTimeout: Duration = .seconds(10),
        now: @escaping () -> Date = Date.init
    ) {
        let restored: ComputerUsePendingPrompt?
        let recoveryReadFailure: String?
        do {
            restored = try pendingStore.read(hostID: hostID, pairingCode: pairingCode,
                localAccountBinding: localAccountBinding)
            recoveryReadFailure = nil
        } catch {
            restored = nil
            recoveryReadFailure = (error as? LocalizedError)?.errorDescription
                ?? "Secure recovery data could not be read. Unlock this device and reconnect before sending a request."
        }
        let effectiveSessionID = restored?.sessionID
            ?? sessionID
            ?? UUID().uuidString
        self.hostName = hostName
        self.hostID = hostID
        self.pairingCode = pairingCode
        self.sessionID = effectiveSessionID
        self.pendingStore = pendingStore
        self.localAccountBinding = localAccountBinding
        self.responseTimeoutDuration = responseTimeoutDuration
        self.promptRefreshInterval = promptRefreshInterval
        self.questionRecoveryTimeout = questionRecoveryTimeout
        self.now = now
        self.channel = channel

        if let recoveryReadFailure {
            requiresRecoveryReconnect = true
            isLiveScreenPrivacyShielded = true
            state = .error(recoveryReadFailure)
            statusText = recoveryReadFailure
        }

        if let restored {
            activePendingRecord = restored
            activePromptID = restored.messageID
            activePromptText = restored.prompt
            activePromptBody = restored.exactWireBody
            activePromptCreatedAt = restored.createdAt
            activeClarificationValidUntil = restored.clarificationValidUntil
            controlRevision = restored.controlRevision ?? 0
            acknowledgedControlRevision = restored.acknowledgedControlRevision ?? 0
            lastControlKind = restored.lastControlKind
            lastControlRevision = restored.lastControlRevision ?? restored.controlRevision ?? 0
            hostControlEpoch = restored.hostControlEpoch ?? 0
            lastControlHostEpoch = restored.lastControlHostEpoch ?? 0
            hostControlPaused = restored.hostControlPaused
            approvalSubmission = restored.approvalDecision
            retryMessageID = restored.messageID
            retryPrompt = restored.prompt
            retryWireBody = restored.exactWireBody
            let request = ComputerUsePromptRequest.decodeCompatibleBody(
                restored.exactWireBody)
            if Self.requiresPersistentPrivacyShield(request) {
                isLiveScreenPrivacyShielded = true
            }
            messages = request.conversation.enumerated().map { index, turn in
                ChatMessage(
                    id: "\(restored.messageID)-context-\(index)",
                    author: turn.role == .user ? .user : .assistant,
                    text: turn.text,
                    createdAt: restored.createdAt.addingTimeInterval(
                        TimeInterval(index - request.conversation.count)))
            }
            messages.append(ChatMessage(
                id: restored.messageID,
                author: .user,
                text: restored.prompt,
                createdAt: restored.createdAt))
            switch restored.lastControlKind {
            case .pause:
                let guidance = Self.boundedInterventionGuidance(
                    restored.interventionGuidance)
                userInterventionGuidance = guidance
                if guidance != nil {
                    latestTerminalOutcome = .userInterventionRequired
                }
                state = .paused
                statusText = "Confirming your previous Take Control request…"
            case .cancel:
                state = .working
                statusText = "Confirming your previous Stop…"
            default:
                state = restored.hostControlPaused == true ? .paused : .working
                if restored.hostControlPaused == true {
                    userInterventionGuidance = Self.boundedInterventionGuidance(restored.interventionGuidance)
                    latestTerminalOutcome = .userInterventionRequired
                    statusText = "Checking whether your Mac is still paused…"
                } else if let decision = restored.approvalDecision {
                    statusText = decision.approved
                        ? "Restoring your approval…"
                        : "Restoring your cancellation…"
                } else {
                    statusText = "Checking your previous request with the Mac…"
                }
            }
            if let question = restored.question {
                clearActivePrompt(removingStoredRecord: false)
                waitingQuestionRecord = restored; questionDraft = question.draft
                composerMode = .recoveringAnswer; state = .working
                statusText = "Checking your saved question with the Mac…"
                messages.append(ChatMessage(id: "saved-question-\(question.reference.nonce.uuidString)", author: .assistant,
                    text: question.text, createdAt: question.receivedAt))
            }
        }
    }

    func start() {
        guard pollingTask == nil else { return }
        isStopped = false
        isConnected = true
        guard !requiresRecoveryReconnect else { return }
        pollingTask = Task { [weak self] in
            await self?.pollLoop()
        }
        if waitingQuestionRecord != nil { retryQuestionRecovery() }
        if activePromptID != nil {
            if lastControlKind != .pause, lastControlKind != .cancel {
                startPromptRefresh(resendImmediately: true)
            }
            replayPersistedControlIfNeeded()
            if lastControlKind != .pause, hostControlPaused != true {
                scheduleResponseTimeout()
            }
            if lastControlKind != .pause,
               lastControlKind != .cancel,
               let approvalSubmission {
                sendApprovalSubmission(approvalSubmission)
            }
        }
    }

    func stop() {
        guard !isStopped else { return }
        if waitingQuestionRecord != nil {
            persistQuestionDraft()
            if waitingQuestionRecord != nil { resetComposerMode(); composerMode = .recoveringAnswer }
        } else if case .answer = composerMode { expireClarification() }
        questionProbeID = nil; questionProbeSendTask?.cancel(); questionProbeTimeoutTask?.cancel(); questionDraftSaveTask?.cancel()
        advanceStateGeneration()
        isStopped = true
        isConnected = false
        pollingTask?.cancel()
        pollingTask = nil
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        promptRefreshTask?.cancel()
        promptRefreshTask = nil
        controlRetryTask?.cancel()
        controlRetryTask = nil
        for task in outboundTasks.values {
            task.cancel()
        }
        outboundTasks.removeAll()
        approvalResponseInFlightRequestID = nil
    }

    /// Invalid or unsaved input stays in the composer. Exact answers never
    /// pass through trimming, truncation or the legacy chat-history path.
    @discardableResult
    func sendPrompt(_ rawPrompt: String) -> Bool { sendPrompt(rawPrompt, clarificationChoiceID: nil) }

    @discardableResult
    func sendClarificationChoice(_ choiceID: String) -> Bool {
        if case .answer(_, let deadline) = composerMode, now() >= deadline {
            expireClarification()
            return false
        }
        guard canSendClarificationChoice(choiceID),
              let choice = activeClarificationChoices?.first(where: { $0.id == choiceID }) else { return false }
        return sendPrompt(choice.label, clarificationChoiceID: choice.id)
    }

    func canSendClarificationChoice(_ choiceID: String) -> Bool {
        guard isConnected, !isStopped, activePromptID == nil, !requiresRecoveryReconnect,
              case .answer(_, let deadline) = composerMode, now() < deadline else { return false }
        switch state { case .ready, .error: break; case .working, .paused, .approvalRequired: return false }
        return activeClarificationChoices?.contains(where: { $0.id == choiceID }) == true
    }

    @discardableResult
    private func sendPrompt(_ rawPrompt: String, clarificationChoiceID: String?) -> Bool {
        guard !isStopped, activePromptID == nil else { return false }
        guard !requiresRecoveryReconnect else { return false }
        if waitingQuestionRecord != nil {
            guard requireWaitingQuestionOwnership() else { return false }
        } else {
            // A successful save alone cannot prove that an earlier task was
            // absent when storage was unreadable. Check before replacement.
            do {
                if try pendingStore.read(hostID: hostID, pairingCode: pairingCode, localAccountBinding: localAccountBinding) != nil {
                    requiresRecoveryReconnect = true
                    isLiveScreenPrivacyShielded = true
                    state = .error("A saved request needs to be recovered.")
                    statusText = "A saved request needs to be recovered. Reconnect before sending a new request."
                    return false
                }
            } catch {
                state = .error("Secure recovery data could not be read.")
                statusText = "Request not sent. Secure recovery data could not be read; unlock this device and try again."
                return false
            }
        }
        switch state {
        case .ready, .error:
            break
        case .working, .paused, .approvalRequired:
            return false
        }
        if case .answer(_, let deadline) = composerMode, now() >= deadline { expireClarification() }
        if let message = promptValidationMessage(rawPrompt) {
            state = .error(message)
            statusText = message
            return false
        }
        let request: ComputerUsePromptRequest
        let wireBody: String
        do {
            switch composerMode {
            case .answer(let reference, let deadline):
                guard now() < deadline else { expireClarification(); return false }
                if let clarificationChoiceID {
                    guard let choice = activeClarificationChoices?.first(where: { $0.id == clarificationChoiceID }),
                          choice.label.utf8.elementsEqual(rawPrompt.utf8) else { return false }
                }
                request = try .answering(reference, text: rawPrompt, supportsApprovedActionEvidence: true,
                    supportsClarificationRetry: clarificationAnswerPolicy?.supportsRetry == true,
                    supportsClarificationFormatRetry: clarificationAnswerPolicy?.supportsRetry == true && clarificationAnswerPolicy?.format != nil,
                    clarificationChoiceID: clarificationChoiceID)
            case .legacyAnswer:
                guard clarificationChoiceID == nil else { return false }
                request = .init(prompt: rawPrompt, conversation: recentConversation(), supportsApprovedActionEvidence: true)
            case .request:
                guard clarificationChoiceID == nil else { return false }
                request = .init(prompt: rawPrompt, supportsApprovedActionEvidence: true)
            case .expiredAnswer, .recoveringAnswer: return false
            }
            wireBody = try request.encodedBody()
        } catch {
            state = .error("This request couldn't be prepared. Your text has not been sent.")
            statusText = "Request not sent"
            return false
        }
        let prompt = request.prompt

        // A valid new submission attempt supersedes the presentation of the
        // previous task's terminal result even if durable recovery storage is
        // unavailable. Otherwise the error below can retain a stale green
        // "Task completed" status from an unrelated request.
        latestTerminalOutcome = nil
        taskProgressHistory.removeAll(keepingCapacity: true)
        let operationGeneration = advanceStateGeneration()
        let messageID = UUID().uuidString
        if Self.requiresPersistentPrivacyShield(request) {
            // This is deliberately synchronous: do not expose unrelated Mac
            // pixels while the embedded Mail request is in flight or being
            // deterministically clarified by the host.
            isLiveScreenPrivacyShielded = true
        }
        guard !isStopped, !requiresRecoveryReconnect,
              stateGeneration == operationGeneration else { return false }
        let message = ChatMessage(
            id: messageID,
            author: .user,
            text: prompt,
            createdAt: now())
        messages.append(message)
        let answerDeadline: Date?
        if request.supportsClarificationRetry, case .answer(_, let deadline) = composerMode { answerDeadline = deadline }
        else { answerDeadline = nil }
        guard rememberActivePrompt(
            prompt,
            wireBody: wireBody,
            messageID: messageID,
            createdAt: message.createdAt, clarificationValidUntil: answerDeadline) else {
            messages.removeAll { $0.id == messageID }
            state = .error("Couldn’t securely save this request, so it was not sent.")
            statusText = "Request not sent — secure recovery storage is unavailable"
            return false
        }
        clearQuestionRecovery(removingStoredRecord: false)
        resetComposerMode()
        state = .working
        statusText = "Sending securely to your Mac…"
        startPromptRefresh(resendImmediately: false)

        launchOutboundTask { model in
            do {
                try await model.channel.send(
                    kind: .prompt,
                    body: wireBody,
                    to: nil,
                    sessionID: nil,
                    messageID: messageID)
                guard !Task.isCancelled,
                      !model.isStopped else { return }
                guard model.isCurrentOperation(
                    operationGeneration,
                    promptID: messageID) else { return }
                model.retryPrompt = nil
                model.retryMessageID = nil
                model.retryWireBody = nil
                model.statusText = "Your Mac is working on it…"
                model.scheduleResponseTimeout()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      !model.isStopped else { return }
                guard model.isCurrentOperation(
                    operationGeneration,
                    promptID: messageID) else { return }
                model.retryPrompt = prompt
                model.retryMessageID = messageID
                model.retryWireBody = wireBody
                model.show(error)
            }
        }
        return true
    }

    func promptValidationMessage(_ text: String) -> String? {
        if requiresRecoveryReconnect { return "Unlock this device and reconnect so the previous request can be checked." }
        if composerMode == .recoveringAnswer { return "Wait for your Mac to check the saved question, or start a new request." }
        if composerMode == .expiredAnswer { return "This question is no longer active. Start a new request." }
        if case .answer(_, let deadline) = composerMode, now() >= deadline {
            return "This question has expired. Start a new request."
        }
        let value: String
        if case .answer = composerMode { value = text }
        else { value = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !value.isEmpty else { return "Enter a request or answer first." }
        guard value.count <= ComputerUsePromptRequest.maximumPromptLength, value.utf8.count <= 32 * 1_024 else {
            return "This text is too long. Shorten it before sending."
        }
        if case .answer = composerMode, let policy = clarificationAnswerPolicy, let rejection = policy.rejection(of: value) {
            return policy.message(for: rejection)
        }
        return nil
    }

    @discardableResult
    func startNewRequest() -> Bool {
        guard !requiresRecoveryReconnect, activePromptID == nil else { return false }
        if waitingQuestionRecord != nil, !requireWaitingQuestionOwnership() { return false }
        advanceStateGeneration()
        guard clearQuestionRecovery(removingStoredRecord: true) else { return false }
        resetComposerMode()
        latestTerminalOutcome = nil
        state = .ready
        statusText = "Ready for a new request"
        return true
    }

    private func resetComposerMode() {
        clarificationExpiryTask?.cancel()
        clarificationExpiryTask = nil
        clarificationAnswerPolicy = nil
        activeClarificationChoices = nil; clarificationChoices = nil
        restoredClarificationDraft = nil
        composerMode = .request
    }

    private func expireClarification() {
        clearQuestionRecovery(removingStoredRecord: true)
        resetComposerMode()
        composerMode = .expiredAnswer
        statusText = "This question is no longer active. Start a new request."
    }

    private func awaitClarification(_ reference: ComputerUseClarificationReference, answerPolicy: ComputerUseClarificationAnswerPolicy?,
                                    choices: [ComputerUseClarificationChoice]? = nil, originalDeadline: Date? = nil) {
        resetComposerMode()
        let current = now(), deadline = min(reference.expiresAt, originalDeadline ?? current.addingTimeInterval(600))
        guard deadline > current else { expireClarification(); return }
        composerMode = .answer(reference, validUntil: deadline)
        clarificationAnswerPolicy = answerPolicy
        activeClarificationChoices = choices; clarificationChoices = choices
        statusText = "Answer the question to continue the original request"
        clarificationExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(deadline.timeIntervalSince(current))) } catch { return }
            guard let self, case .answer(let currentReference, _) = self.composerMode,
                  currentReference == reference else { return }
            self.expireClarification()
        }
    }

    func updateQuestionDraft(_ draft: String) {
        guard waitingQuestionRecord != nil, case .answer = composerMode, activePromptID == nil else { return }
        questionDraft = draft
        questionDraftSaveTask?.cancel()
        questionDraftSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.persistQuestionDraft()
        }
    }

    private func persistQuestionDraft() {
        guard let record = waitingQuestionRecord, let question = record.question else { return }
        guard requireWaitingQuestionOwnership() else { return }
        guard !Self.sameTextBytes(question.draft, questionDraft) else { return }
        guard let updated = try? question.withDraft(questionDraft) else {
            statusText = "This draft is too long to save for recovery. Shorten it before leaving."
            return
        }
        let replacement = record.retainingQuestion(updated)
        guard replaceRecoveryRecord(replacement, expecting: record) else { statusText = "Couldn’t securely save this draft for recovery."; return }
        waitingQuestionRecord = replacement
    }

    @discardableResult
    private func clearQuestionRecovery(removingStoredRecord: Bool) -> Bool {
        if removingStoredRecord, let record = waitingQuestionRecord {
            if pendingStore.remove(ifMatching: record) == .unavailable {
                statusText = "Couldn’t securely retire this question. Its saved recovery data has been kept."
                return false
            }
        }
        waitingQuestionRecord = nil; questionDraft = nil; questionProbeID = nil
        questionProbeSendTask?.cancel(); questionProbeSendTask = nil
        questionProbeTimeoutTask?.cancel(); questionProbeTimeoutTask = nil
        questionDraftSaveTask?.cancel(); questionDraftSaveTask = nil
        return true
    }

    private func readWaitingQuestionOwnership() throws -> Bool {
        guard let record = waitingQuestionRecord else { return false }
        guard let current = try pendingStore.read(hostID: hostID, pairingCode: pairingCode, localAccountBinding: localAccountBinding),
              ComputerUsePendingPrompt.sameRecoveryState(current, record) else { return false }
        return true
    }

    private func requireWaitingQuestionOwnership() -> Bool {
        do {
            guard try readWaitingQuestionOwnership() else { abandonReplacedQuestion(); return false }
            return true
        } catch {
            // Unavailable storage is not evidence that another task replaced
            // this question. Keep its exact draft and original deadline, and
            // require another fresh native probe after reads recover.
            questionProbeID = nil
            questionProbeSendTask?.cancel(); questionProbeTimeoutTask?.cancel(); questionDraftSaveTask?.cancel()
            resetComposerMode(); composerMode = .recoveringAnswer
            state = .error("Secure recovery data could not be read.")
            statusText = "Your saved question could not be read. Unlock this device, then check again."
            return false
        }
    }

    private static func sameTextBytes(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (.some(let lhs), .some(let rhs)): return lhs.utf8.elementsEqual(rhs.utf8)
        default: return false
        }
    }

    private func abandonReplacedQuestion() {
        clearQuestionRecovery(removingStoredRecord: false)
        resetComposerMode(); composerMode = .expiredAnswer; state = .ready
        statusText = "This saved question was replaced by another request. Start a new request here to continue."
    }

    func retryQuestionRecovery() {
        guard !isStopped, activePromptID == nil, let question = waitingQuestionRecord?.question else { return }
        guard requireWaitingQuestionOwnership() else { return }
        guard now() < question.validUntil else { state = .ready; expireClarification(); return }
        questionProbeSendTask?.cancel(); questionProbeTimeoutTask?.cancel()
        let probe = ComputerUseClarificationProbe(reference: question.reference)
        guard let body = try? probe.encodedBody() else { return }
        questionProbeID = probe.probeID
        resetComposerMode(); composerMode = .recoveringAnswer; state = .working
        statusText = "Checking your saved question with the Mac…"
        let channel = self.channel, target = hostID, session = sessionID, timeout = questionRecoveryTimeout
        questionProbeSendTask = Task { [weak self] in
            do {
                _ = try await channel.send(kind: .status, body: body, to: target,
                    sessionID: session, messageID: probe.probeID.uuidString)
            } catch {
                guard let self, !self.isStopped, self.questionProbeID == probe.probeID else { return }
                self.questionProbeTimeoutTask?.cancel()
                self.state = .error("The saved question could not be checked.")
                self.statusText = "Couldn’t check the saved question. Check again or start a new request."
            }
        }
        questionProbeTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, !self.isStopped, self.questionProbeID == probe.probeID else { return }
            if self.now() >= question.validUntil { self.state = .ready; self.expireClarification(); return }
            self.state = .error("The Mac has not confirmed this question.")
            self.statusText = "The Mac has not confirmed this question. Check again or start a new request."
        }
    }

    private func consumeQuestionProbe(_ result: ComputerUseClarificationProbeResult, from envelope: ComputerUseEnvelope) {
        guard !isStopped, activePromptID == nil, composerMode == .recoveringAnswer, hasHostControlScope(envelope),
              questionProbeID == result.probeID, let record = waitingQuestionRecord, let question = record.question,
              result.reference == question.reference else { return }
        guard requireWaitingQuestionOwnership() else { return }
        guard now() < question.validUntil, let text = result.question else {
            latestTerminalOutcome = .unableToComplete; state = .ready; expireClarification(); return
        }
        guard text.utf8.elementsEqual(question.text.utf8) else {
            questionProbeTimeoutTask?.cancel()
            state = .error("The saved question does not match the Mac.")
            statusText = "The saved question does not match the Mac. Check again or start a new request."
            return
        }
        guard result.clarificationChoices == question.choices,
              let updated = try? ComputerUsePendingQuestion(reference: question.reference, text: text, answerPolicy: result.answerPolicy,
            receivedAt: question.receivedAt, validUntil: question.validUntil, draft: questionDraft, choices: result.clarificationChoices) else {
            questionProbeTimeoutTask?.cancel(); state = .error("The saved question choices do not match the Mac.")
            statusText = "The saved question choices do not match the Mac. Check again or start a new request."
            return
        }
        let replacement = record.retainingQuestion(updated)
        guard replaceRecoveryRecord(replacement, expecting: record) else {
            questionProbeTimeoutTask?.cancel(); state = .error("Couldn’t securely restore this question.")
            statusText = "Couldn’t securely restore this question. Check again or start a new request."
            return
        }
        waitingQuestionRecord = replacement; questionProbeID = nil
        questionProbeSendTask?.cancel(); questionProbeTimeoutTask?.cancel()
        latestTerminalOutcome = .userInterventionRequired; state = .ready
        awaitClarification(question.reference, answerPolicy: result.answerPolicy, choices: result.clarificationChoices, originalDeadline: question.validUntil)
        restoredClarificationDraft = questionDraft
    }

    func retryLastPrompt() {
        guard !isStopped else { return }
        guard let retryPrompt, let retryMessageID, let retryWireBody else { return }
        self.retryPrompt = nil
        self.retryMessageID = nil
        self.retryWireBody = nil
        // Keep one conversational bubble; the retry is transport recovery,
        // not a second user request.
        state = .ready
        sendPromptWithoutAppending(
            retryPrompt,
            wireBody: retryWireBody,
            messageID: retryMessageID)
    }

    func takeControl() {
        guard !isStopped,
              let promptID = activePromptID,
              lastControlKind != .cancel else { return }
        let operationGeneration = advanceStateGeneration()
        pauseAcknowledgement = nil
        guard isCurrentOperation(operationGeneration, promptID: promptID) else { return }
        latestTerminalOutcome = nil
        userInterventionGuidance = nil
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        state = .paused
        guard isCurrentOperation(operationGeneration, promptID: promptID) else { return }
        statusText = "Take Control requested — waiting for your Mac…"
        sendControl(.pause, generation: operationGeneration)
    }

    func resumeAI() {
        guard !isStopped,
              let promptID = activePromptID,
              lastControlKind != .cancel else { return }
        let operationGeneration = advanceStateGeneration()
        pauseAcknowledgement = nil
        guard isCurrentOperation(operationGeneration, promptID: promptID) else { return }
        latestTerminalOutcome = nil
        userInterventionGuidance = nil
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        state = .working
        guard isCurrentOperation(operationGeneration, promptID: promptID) else { return }
        statusText = "Asking AI to continue…"
        startPromptRefresh(resendImmediately: true)
        scheduleResponseTimeout(
            message: "No update yet. I’m checking with your Mac again; you can also Take control or stop safely.")
        sendControl(.resume, generation: operationGeneration)
    }

    func stopCurrentTask() {
        guard !isStopped,
              let promptID = activePromptID,
              lastControlKind != .cancel else { return }
        let operationGeneration = advanceStateGeneration()
        pauseAcknowledgement = nil
        guard isCurrentOperation(operationGeneration, promptID: promptID) else { return }
        latestTerminalOutcome = nil
        userInterventionGuidance = nil
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        // Versioned Cancel is absorbing on the host, so no prompt refresh
        // should recreate task traffic after Stop.
        promptRefreshTask?.cancel()
        promptRefreshTask = nil
        state = .working
        guard isCurrentOperation(operationGeneration, promptID: promptID) else { return }
        statusText = "Stopping the task…"
        scheduleResponseTimeout(
            message: "The Mac hasn’t confirmed Stop yet. Use the Mac directly to keep AI paused.")
        sendControl(.cancel, generation: operationGeneration)
    }

    func respondToApproval(_ request: ComputerUseApprovalRequest, approved: Bool) {
        guard !isStopped else { return }
        guard case .approvalRequired(let current) = state,
              current.requestID == request.requestID else { return }
        let response = ComputerUseApprovalResponse(
            requestID: request.requestID,
            approved: approved,
            taskID: request.taskID,
            appliedControlRevision: request.appliedControlRevision,
            hostControlEpoch: request.hostControlEpoch)
        guard let responseBody = try? response.encodedBody() else {
            statusText = "Couldn’t safely record your choice. Please try again."
            return
        }
        let priorSubmission = approvalSubmission
        let submission = ComputerUsePendingApprovalDecision(
            request: request,
            approved: approved,
            responseBody: responseBody)
        approvalSubmission = submission
        guard persistActivePrompt() else {
            approvalSubmission = priorSubmission
            statusText = "Couldn’t safely save your choice. No response was sent."
            return
        }
        let operationGeneration = advanceStateGeneration()
        let promptID = activePromptID
        latestTerminalOutcome = nil
        if approved, Self.requiresPersistentPrivacyShield(request) {
            // Set this before the approval response leaves the phone. The
            // full-card privacy backdrop is about to disappear, and Mail may
            // activate immediately once the host receives the response.
            isLiveScreenPrivacyShielded = true
        }
        guard isCurrentOperation(operationGeneration, promptID: promptID) else { return }
        state = .working
        statusText = approved
            ? "Approved — your Mac is continuing…"
            : "Cancellation sent — waiting for your Mac…"
        scheduleResponseTimeout(message: approved
            ? "No update yet. I’m checking with your Mac again; you can also Take control or stop safely."
            : "The Mac hasn’t confirmed cancellation yet. No action is approved; Take control if needed.")
        sendApprovalSubmission(submission)
    }

    func revealLiveScreen() {
        isLiveScreenPrivacyShielded = false
    }

    private static func requiresPersistentPrivacyShield(
        _ request: ComputerUseApprovalRequest
    ) -> Bool {
        guard request.confirmLabel == "Send email"
                || request.confirmLabel == "Create draft" else {
            return false
        }
        let labels = Set(request.details?.map(\.label) ?? [])
        return ["From", "To", "Subject", "Message"].allSatisfy(
            labels.contains)
    }

    private func sendControl(
        _ kind: ComputerUseEnvelope.Kind,
        generation: UInt64
    ) {
        controlRetryTask?.cancel()
        controlRetryTask = nil
        guard let request = nextControlRequest(kind: kind),
              let body = try? request.encodedBody() else {
            handleControlPersistenceFailure(kind)
            return
        }
        sendControl(
            kind,
            request: request,
            body: body,
            generation: generation)
    }

    private func sendControl(
        _ kind: ComputerUseEnvelope.Kind,
        request: ComputerUseControlRequest,
        body: String,
        generation: UInt64
    ) {
        let intent = PendingControlIntent(
            taskID: request.taskID,
            revision: request.revision,
            kind: kind,
            hostControlEpoch: request.observedHostControlEpoch ?? 0)
        pendingControlIntent = intent
        launchOutboundTask { model in
            do {
                try await model.channel.send(kind: kind, body: body)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      !model.isStopped else { return }
                guard model.isCurrentOperation(
                    generation,
                    promptID: request.taskID),
                      model.pendingControlIntent == intent,
                      model.isExpectedControlSubmissionState(kind) else { return }
                model.responseTimeoutTask?.cancel()
                model.responseTimeoutTask = nil
                switch kind {
                case .pause:
                    model.state = .paused
                    model.statusText = "Couldn’t reach AI securely. Use the Mac directly to take control immediately."
                case .resume:
                    model.state = .paused
                    model.statusText = "Couldn’t resume AI yet. Check the connection and try again."
                case .cancel:
                    model.state = .working
                    model.statusText = "Stop is still pending. The same safe request will be retried."
                default:
                    model.show(error)
                }
                model.scheduleControlRetry(
                    intent,
                    request: request,
                    body: body)
            }
        }
    }

    private func scheduleControlRetry(
        _ intent: PendingControlIntent,
        request: ComputerUseControlRequest,
        body: String
    ) {
        controlRetryTask?.cancel()
        controlRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard let self,
                  !isStopped,
                  activePromptID == intent.taskID,
                  pendingControlIntent == intent,
                  lastControlKind == intent.kind else { return }
            sendControl(
                intent.kind,
                request: request,
                body: body,
                generation: stateGeneration)
        }
    }

    private func sendApprovalSubmission(
        _ submission: ComputerUsePendingApprovalDecision
    ) {
        guard !isStopped,
              activePromptID == submission.request.taskID,
              approvalSubmission == submission,
              approvalResponseInFlightRequestID == nil,
              (submission.request.hostControlEpoch ?? 0) == hostControlEpoch,
              lastControlKind != .pause,
              lastControlKind != .cancel else { return }
        approvalResponseInFlightRequestID = submission.request.requestID
        launchOutboundTask { model in
            defer {
                if model.approvalResponseInFlightRequestID
                    == submission.request.requestID {
                    model.approvalResponseInFlightRequestID = nil
                }
            }
            do {
                try await model.channel.send(
                    kind: .approvalResponse,
                    body: submission.responseBody)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      !model.isStopped,
                      model.activePromptID == submission.request.taskID,
                      model.approvalSubmission == submission else { return }
                // A CloudKit error is ambiguous: the host may already have
                // consumed the response. Keep the exact durable choice locked
                // and retry only those same bytes.
                if case .working = model.state {
                    model.statusText = submission.approved
                        ? "Approval not confirmed yet — retrying the same choice…"
                        : "Cancellation not confirmed yet — retrying the same choice…"
                    model.scheduleResponseTimeout(message: submission.approved
                        ? "No update yet. Your exact approval remains locked; Take control or stop safely if needed."
                        : "No update yet. Your exact cancellation remains locked; Take control if needed.")
                }
            }
        }
    }

    private func launchOutboundTask(
        _ operation: @escaping @MainActor (ComputerUseSessionModel) async -> Void
    ) {
        guard !isStopped, !requiresRecoveryReconnect else { return }
        let id = UUID()
        let generation = stateGeneration, promptID = activePromptID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishOutboundTask(id) }
            guard !Task.isCancelled, !self.isStopped, !self.requiresRecoveryReconnect else { return }
            guard self.isCurrentOperation(generation, promptID: promptID) else { return }
            if let record = self.activePendingRecord {
                do {
                    let current = try self.pendingStore.read(hostID: self.hostID, pairingCode: self.pairingCode,
                        localAccountBinding: self.localAccountBinding)
                    guard ComputerUsePendingPrompt.sameRecoveryState(current, record) else {
                        self.requireRecoveryReconnect("The saved request changed. Reconnect to recover the current request.")
                        return
                    }
                } catch {
                    self.requireRecoveryReconnect("Secure recovery data could not be read. Reconnect before continuing this request.")
                    return
                }
            }
            await operation(self)
        }
        outboundTasks[id] = task
    }

    private func finishOutboundTask(_ id: UUID) {
        outboundTasks[id] = nil
    }

    private func nextControlRequest(
        kind: ComputerUseEnvelope.Kind
    ) -> ComputerUseControlRequest? {
        guard let taskID = activePromptID else { return nil }
        guard kind == .cancel || unpersistedHostControlEpoch == nil else { return nil }
        guard controlRevision < UInt64.max else { return nil }
        let previousRevision = controlRevision
        let previousKind = lastControlKind
        let previousIntentRevision = lastControlRevision
        let previousEpoch = lastControlHostEpoch
        let previousPaused = hostControlPaused
        controlRevision += 1
        lastControlKind = kind
        lastControlRevision = controlRevision
        lastControlHostEpoch = hostControlEpoch
        hostControlPaused = kind == .pause
        guard persistActivePrompt() else {
            controlRevision = previousRevision
            lastControlKind = previousKind
            lastControlRevision = previousIntentRevision
            lastControlHostEpoch = previousEpoch
            hostControlPaused = previousPaused
            return nil
        }
        return ComputerUseControlRequest(
            taskID: taskID,
            revision: lastControlRevision,
            observedHostControlEpoch: lastControlHostEpoch)
    }

    private func replayPersistedControlIfNeeded() {
        guard let taskID = activePromptID,
              lastControlRevision > 0,
              let kind = lastControlKind,
              kind == .pause || kind == .resume || kind == .cancel else {
            return
        }
        let request = ComputerUseControlRequest(
            taskID: taskID,
            revision: lastControlRevision,
            observedHostControlEpoch: lastControlHostEpoch)
        guard let body = try? request.encodedBody() else { return }
        sendControl(
            kind,
            request: request,
            body: body,
            generation: stateGeneration)
    }

    private func handleControlPersistenceFailure(
        _ kind: ComputerUseEnvelope.Kind
    ) {
        guard !requiresRecoveryReconnect else { return }
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        switch kind {
        case .pause:
            state = .paused
            statusText = "Couldn’t safely save Pause. Use the Mac directly to take control immediately."
        case .resume:
            state = .paused
            statusText = "Couldn’t safely save Resume. AI remains paused."
        case .cancel:
            state = .paused
            statusText = "Couldn’t safely save Stop. Use the Mac directly to keep AI paused."
        default:
            break
        }
    }

    @discardableResult
    private func advanceStateGeneration() -> UInt64 {
        stateGeneration &+= 1
        return stateGeneration
    }

    private func isCurrentOperation(
        _ generation: UInt64,
        promptID: String?
    ) -> Bool {
        !isStopped
            && !requiresRecoveryReconnect
            && stateGeneration == generation
            && activePromptID == promptID
    }

    private func isExpectedControlSubmissionState(
        _ kind: ComputerUseEnvelope.Kind
    ) -> Bool {
        switch kind {
        case .pause:
            if case .paused = state { return true }
        case .resume, .cancel:
            if case .working = state { return true }
        default:
            return false
        }
        return false
    }

    private func pollLoop() async {
        while !Task.isCancelled, !isStopped, !requiresRecoveryReconnect {
            do {
                let envelopes = try await channel.poll()
                guard !Task.isCancelled, !isStopped else { return }
                if transportNotice != nil {
                    transportNotice = nil
                    restoreStatusText()
                }
                consume(envelopes)
                guard !Task.isCancelled, !requiresRecoveryReconnect else { return }
                try await channel.acknowledge(envelopes)
                guard !Task.isCancelled, !isStopped else { return }
                // Approval and completion often arrive back-to-back. Poll
                // again immediately after real work so the confirmation
                // result is not hidden behind the idle two-second cadence.
                if !envelopes.isEmpty { continue }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, !isStopped else { return }
                transportNotice = error.localizedDescription
                statusText = "Secure connection interrupted — retrying…"
            }

            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
        }
    }

    private func consume(_ envelopes: [ComputerUseEnvelope]) {
        for envelope in envelopes {
            guard !requiresRecoveryReconnect else { return }
            switch envelope.kind {
            case .assistant:
                let update = try? ComputerUseTaskUpdate.decodeBody(envelope.body)
                if update?.isApprovedActionEvidenceOnly == true || update?.researchProgress != nil { continue }
                if let update { consumeActionEvidence(update, from: envelope) }
                let trimmed = envelope.body.trimmingCharacters(in: .whitespacesAndNewlines)
                if update == nil && (trimmed.first == "{" || trimmed.first == "[") { continue }
                let taskID = update?.taskID ?? activePromptID
                guard let activePromptID,
                      taskID == activePromptID else { continue }
                let recovery = update?.clarificationRetry.flatMap { clarificationRecovery($0) }
                if update?.clarificationRetry != nil && (recovery == nil || !hasHostControlScope(envelope)) { continue }
                if update?.clarification != nil {
                    guard hasHostControlScope(envelope), lastControlKind != .pause,
                          pendingControlIntent?.kind != .pause, hostControlPaused != true else { continue }
                }
                if update?.hostControlEpoch != nil, !hasHostControlScope(envelope) { continue }
                guard acceptHostControlEpoch(update?.hostControlEpoch) else { continue }
                if case .approvalRequired = state {
                    // A terminal envelope created before the approval card
                    // cannot prove that the person authorized or canceled the
                    // proposed effect. Keep the approval absorbing until an
                    // exact persisted decision leaves this client.
                    continue
                }
                if let appliedControlRevision = update?.appliedControlRevision {
                    guard acceptAppliedControlRevision(
                        appliedControlRevision) else { continue }
                } else if requiredControlRevision > 0 {
                    // A terminal reply created before the newest lifecycle
                    // intent is not proof that Pause/Resume/Stop was applied.
                    // Current hosts attach their durable revision snapshot.
                    continue
                } else {
                    approvalSubmission = nil
                }
                var savedQuestion: ComputerUsePendingPrompt?
                if update?.supportsClarificationRecovery == true, lastControlKind != .cancel, pendingControlIntent?.kind != .cancel,
                   let reference = update?.clarification ?? update?.clarificationRetry?.reference {
                    let receivedAt = now(), deadline = recovery?.deadline ?? min(reference.expiresAt, receivedAt.addingTimeInterval(600))
                    if deadline > receivedAt {
                        guard let prompt = activePromptText, let wireBody = activePromptBody, let createdAt = activePromptCreatedAt,
                              let question = try? ComputerUsePendingQuestion(reference: reference, text: update?.text ?? "",
                                answerPolicy: update?.clarificationAnswerPolicy ?? update?.clarificationRetry?.answerPolicy,
                                receivedAt: receivedAt, validUntil: deadline, draft: recovery?.text,
                                choices: update?.clarificationChoices) else { continue }
                        let record = ComputerUsePendingPrompt(hostID: hostID, pairingCode: pairingCode, sessionID: sessionID,
                            messageID: activePromptID, prompt: prompt, wireBody: wireBody, createdAt: createdAt,
                            localAccountBinding: localAccountBinding, clarificationValidUntil: activeClarificationValidUntil, question: question)
                        guard record.hasValidQuestionRecovery, let previous = activePendingRecord,
                              replaceRecoveryRecord(record, expecting: previous) else {
                            state = .error("Couldn’t securely save this question.")
                            statusText = "Couldn’t securely save this question. Checking the original request again."
                            continue
                        }
                        savedQuestion = record
                    }
                }
                advanceStateGeneration()
                responseTimeoutTask?.cancel()
                responseTimeoutTask = nil
                let assistantText = update?.text ?? envelope.body
                messages.append(ChatMessage(
                    id: envelope.id,
                    author: .assistant,
                    text: assistantText,
                    createdAt: envelope.createdAt))
                if let retry = update?.clarificationRetry, let recovery {
                    resetComposerMode()
                    latestTerminalOutcome = .userInterventionRequired; userInterventionGuidance = nil; state = .ready
                    clearActivePrompt(removingStoredRecord: savedQuestion == nil)
                    guard !requiresRecoveryReconnect else { continue }
                    waitingQuestionRecord = savedQuestion; questionDraft = savedQuestion?.question?.draft
                    awaitClarification(retry.reference, answerPolicy: retry.answerPolicy, choices: update?.clarificationChoices, originalDeadline: recovery.deadline)
                    if case .answer = composerMode {
                        restoredClarificationDraft = recovery.text; statusText = retry.answerPolicy.message(for: retry.reason)
                    }
                } else {
                    applyAssistantOutcome(update?.outcome, text: assistantText, clarification: update?.clarification,
                        answerPolicy: update?.clarificationAnswerPolicy, choices: update?.clarificationChoices, savedQuestion: savedQuestion)
                }
            case .status:
                if let result = try? ComputerUseClarificationProbeResult.decodeBody(envelope.body) {
                    consumeQuestionProbe(result, from: envelope)
                    continue
                }
                if let update = try? ComputerUseTaskUpdate.decodeBody(envelope.body) {
                    if update.clarificationRetry != nil { continue }
                    consumeActionEvidence(update, from: envelope)
                    if update.isApprovedActionEvidenceOnly { continue }
                    guard update.taskID == activePromptID else { continue }
                    if update.hostControlEpoch != nil, !hasHostControlScope(envelope) { continue }
                    let paused: Bool? = update.text == "paused"
                        || ComputerUseStatusSignal.userInterventionMessage(from: update.text) != nil
                        ? true : (update.text == "working" ? false : nil)
                    guard acceptHostControlEpoch(update.hostControlEpoch, paused: paused) else { continue }
                    guard shouldApplyHostStatus(
                        update.text,
                        appliedControlRevision: update.appliedControlRevision) else {
                        continue
                    }
                    retryPrompt = nil
                    retryMessageID = nil
                    retryWireBody = nil
                    let acceptedGeneration = stateGeneration
                    recordTaskProgress(update.text, outcome: update.outcome)
                    guard isCurrentOperation(acceptedGeneration, promptID: update.taskID) else { continue }
                    recordPauseAcknowledgement(update, from: envelope)
                    guard isCurrentOperation(acceptedGeneration, promptID: update.taskID) else { continue }
                    applyHostStatus(update.text, outcome: update.outcome)
                    if let report = update.researchProgress, hasHostControlScope(envelope) {
                        // Accepted only after the current task and both control
                        // clocks. Repeated delivery gets one literal bubble;
                        // it never clears the pending prompt or creates an answer.
                        let id = "research:\(update.taskID):\(report.reportID)"
                        if !messages.contains(where: { $0.id == id }) {
                            messages.append(ChatMessage(id: id, author: .assistant, text: report.text,
                                createdAt: envelope.createdAt, researchProgress: report))
                        }
                    }
                } else {
                    let trimmed = envelope.body.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.first == "{" || trimmed.first == "[" { continue }
                    // Legacy raw statuses have no task identity. They may
                    // describe the active v2 task, but must never resurrect a
                    // terminal task after an assistant reply cleared it.
                    guard activePromptID != nil else { continue }
                    guard acceptHostControlEpoch(nil) else { continue }
                    guard shouldApplyHostStatus(
                        envelope.body,
                        appliedControlRevision: nil) else { continue }
                    recordTaskProgress(envelope.body, outcome: nil)
                    applyHostStatus(envelope.body)
                }
            case .approvalRequest:
                guard let request = try? ComputerUseApprovalRequest.decodeBody(envelope.body) else {
                    continue
                }
                guard request.taskID == activePromptID else { continue }
                if request.hostControlEpoch != nil, !hasHostControlScope(envelope) { continue }
                guard acceptHostControlEpoch(request.hostControlEpoch, paused: false) else { continue }
                if lastControlKind == .cancel
                    || pendingControlIntent?.kind == .cancel
                    || pendingControlIntent?.kind == .pause {
                    continue
                }
                if case .paused = state { continue }
                if let appliedControlRevision = request.appliedControlRevision {
                    guard acceptAppliedControlRevision(
                        appliedControlRevision) else { continue }
                } else if requiredControlRevision > 0 {
                    continue
                }
                if let submission = approvalSubmission,
                   submission.request.requestID == request.requestID {
                    sendApprovalSubmission(submission)
                    continue
                }
                if case .approvalRequired(let existing) = state,
                   existing.requestID == request.requestID {
                    continue
                }
                let priorSubmission = approvalSubmission
                approvalSubmission = nil
                approvalResponseInFlightRequestID = nil
                guard priorSubmission == nil || persistActivePrompt() else {
                    approvalSubmission = priorSubmission
                    state = .paused
                    statusText = "Couldn’t safely save the new approval request. AI was paused."
                    continue
                }
                pendingControlIntent = nil
                controlRetryTask?.cancel()
                controlRetryTask = nil
                let operationGeneration = advanceStateGeneration()
                let promptID = activePromptID
                if Self.requiresPersistentPrivacyShield(request) {
                    // The structured host approval is the authoritative fallback
                    // if future Mail phrasing is broader than the bounded
                    // request-side classifier below.
                    isLiveScreenPrivacyShielded = true
                }
                guard isCurrentOperation(operationGeneration, promptID: promptID) else { continue }
                latestTerminalOutcome = .userInterventionRequired
                state = .approvalRequired(request)
                guard isCurrentOperation(operationGeneration, promptID: promptID) else { continue }
                responseTimeoutTask?.cancel()
                responseTimeoutTask = nil
                statusText = "Your approval is needed"
            case .prompt, .pause, .resume, .cancel, .setupRequest, .setupProgress,
                 .approvalResponse:
                break
            }
        }
    }

    private func consumeActionEvidence(_ update: ComputerUseTaskUpdate, from envelope: ComputerUseEnvelope) {
        guard envelope.senderID == hostID, envelope.pairingCode == pairingCode, envelope.sessionID == sessionID,
              let evidence = update.approvedActionEvidence,
              let index = messages.firstIndex(where: { $0.author == .user && $0.id == update.taskID }) else { return }
        if let existing = messages[index].approvedActionEvidence {
            guard existing.actionID == evidence.actionID,
                  existing.state == .unconfirmed, evidence.state == .confirmed else { return }
        }
        // This is an annotation on the exact original request. Do not touch
        // task/control state, timers, the composer, approval or conversation.
        messages[index].approvedActionEvidence = evidence
    }

    private func hasHostControlScope(_ envelope: ComputerUseEnvelope) -> Bool {
        envelope.senderID == hostID && envelope.pairingCode == pairingCode && envelope.sessionID == sessionID
    }

    private func recordPauseAcknowledgement(_ update: ComputerUseTaskUpdate, from envelope: ComputerUseEnvelope) {
        // Called only after task identity, host epoch, durable revision and
        // semantic acknowledgement checks have accepted this status.
        let reportsPause = update.text == "paused" || update.outcome == .userInterventionRequired
            || ComputerUseStatusSignal.userInterventionMessage(from: update.text) != nil
        guard reportsPause, hasHostControlScope(envelope), let taskID = activePromptID,
              update.taskID == taskID, (update.hostControlEpoch ?? 0) == hostControlEpoch,
              (update.appliedControlRevision ?? 0) >= requiredControlRevision else { return }
        pauseAcknowledgement = .init(taskID: taskID, hostEpoch: hostControlEpoch,
            appliedRevision: update.appliedControlRevision ?? 0)
    }

    private func recordTaskProgress(
        _ status: String,
        outcome: ComputerUseTerminalOutcome?
    ) {
        guard outcome == nil else { return }
        let bounded = String(status.trimmingCharacters(
            in: .whitespacesAndNewlines).prefix(240))
        guard bounded.range(
            of: #"^Step [0-9]+: .+"#,
            options: .regularExpression) != nil else {
            return
        }
        if taskProgressHistory.last == bounded { return }
        taskProgressHistory.append(bounded)
        if taskProgressHistory.count > Self.maximumTaskProgressEntries {
            taskProgressHistory.removeFirst(
                taskProgressHistory.count - Self.maximumTaskProgressEntries)
        }
    }

    private func shouldApplyHostStatus(
        _ status: String,
        appliedControlRevision: UInt64?
    ) -> Bool {
        let isSafetyIntervention = ComputerUseStatusSignal
            .userInterventionMessage(from: status) != nil

        if let appliedControlRevision {
            guard acceptAppliedControlRevision(
                appliedControlRevision) else { return false }
            if isSafetyIntervention {
                guard pendingControlIntent?.kind != .cancel else {
                    return false
                }
                guard consumeApprovalForSafetyIntervention() else {
                    return false
                }
                pendingControlIntent = nil
                controlRetryTask?.cancel()
                controlRetryTask = nil
                return true
            }
            if approvalSubmission != nil {
                return false
            }
            if case .approvalRequired = state {
                return false
            }
            if let pendingControlIntent {
                let isSemanticAcknowledgement: Bool
                switch pendingControlIntent.kind {
                case .pause:
                    isSemanticAcknowledgement = status == "paused"
                case .resume:
                    isSemanticAcknowledgement = status == "working"
                        || status == "ready"
                        || status == "paused"
                case .cancel:
                    // `ready` proves the durable Cancel reached a terminal
                    // host ledger, but the assistant reply carries the exact
                    // terminal result and completes the local task.
                    isSemanticAcknowledgement = status == "ready"
                default:
                    isSemanticAcknowledgement = false
                }
                guard isSemanticAcknowledgement else { return false }
                if pendingControlIntent.kind != .cancel {
                    self.pendingControlIntent = nil
                    controlRetryTask?.cancel()
                    controlRetryTask = nil
                } else {
                    controlRetryTask?.cancel()
                    controlRetryTask = nil
                }
            }
            return true
        }

        // Without a newer host epoch, an unversioned status cannot prove that
        // the latest outstanding phone intent or acknowledged revision applied.
        if requiredControlRevision > 0 {
            return false
        }

        if isSafetyIntervention {
            return consumeApprovalForSafetyIntervention()
        }
        if approvalSubmission != nil {
            return false
        }
        if case .approvalRequired = state {
            return false
        }

        return true
    }

    private func consumeApprovalForSafetyIntervention() -> Bool {
        guard approvalSubmission != nil else { return true }
        let previousSubmission = approvalSubmission
        approvalSubmission = nil
        approvalResponseInFlightRequestID = nil
        guard persistActivePrompt() else {
            approvalSubmission = previousSubmission
            return false
        }
        return true
    }

    /// A higher host epoch invalidates older Pause/Resume intents, not Stop.
    /// Keep the phone counter for future allocation, but do not require an
    /// acknowledgement for an intent that the newer local choice superseded.
    private var requiredControlRevision: UInt64 {
        max(acknowledgedControlRevision,
            lastControlKind == .cancel || lastControlHostEpoch == hostControlEpoch ? lastControlRevision : 0)
    }

    private func acceptHostControlEpoch(_ value: UInt64?, paused: Bool? = nil) -> Bool {
        let epoch = value ?? 0
        guard epoch >= max(hostControlEpoch, unpersistedHostControlEpoch ?? 0) else { return false }
        guard epoch > hostControlEpoch else { return true }
        let previousEpoch = hostControlEpoch
        let previousKind = lastControlKind
        let previousPaused = hostControlPaused
        let previousApproval = approvalSubmission
        hostControlEpoch = epoch
        if lastControlKind != .cancel {
            lastControlKind = nil
            approvalSubmission = nil
            hostControlPaused = paused ?? true
        }
        // Commit supersession before canceling retries or changing the card.
        // A crash must never turn the old Resume into a current-epoch command.
        guard persistActivePrompt() else {
            hostControlEpoch = previousEpoch
            lastControlKind = previousKind
            hostControlPaused = previousPaused
            approvalSubmission = previousApproval
            unpersistedHostControlEpoch = epoch
            if lastControlKind != .cancel { state = .paused }
            statusText = "Couldn't safely save the Mac's handoff. Use the Mac directly until recovery is available."
            return false
        }
        unpersistedHostControlEpoch = nil
        if lastControlKind != .cancel {
            pendingControlIntent = nil
            controlRetryTask?.cancel()
            controlRetryTask = nil
            approvalResponseInFlightRequestID = nil
            if paused == false {
                state = .working
            } else if case .approvalRequired = state {
                state = .paused
            }
            advanceStateGeneration()
        }
        return true
    }

    private func acceptAppliedControlRevision(_ revision: UInt64) -> Bool {
        guard revision >= requiredControlRevision else { return false }
        if revision > acknowledgedControlRevision || revision > controlRevision {
            let previousRevision = controlRevision
            let previousAcknowledged = acknowledgedControlRevision
            controlRevision = max(controlRevision, revision)
            acknowledgedControlRevision = max(acknowledgedControlRevision, revision)
            guard persistActivePrompt() else {
                controlRevision = previousRevision
                acknowledgedControlRevision = previousAcknowledged
                return false
            }
        }
        return true
    }

    func applyHostStatus(_ status: String) {
        pauseAcknowledgement = nil // This unscoped helper cannot establish receipt identity.
        applyHostStatus(status, outcome: nil)
    }

    private func applyHostStatus(
        _ status: String,
        outcome: ComputerUseTerminalOutcome?
    ) {
        advanceStateGeneration()
        if let outcome {
            latestTerminalOutcome = outcome
            switch outcome {
            case .userInterventionRequired:
                enterUserIntervention(status)
                return
            case .taskCompleted, .unableToComplete:
                userInterventionGuidance = nil
                responseTimeoutTask?.cancel()
                responseTimeoutTask = nil
                state = .ready
                statusText = status
                clearActivePrompt()
                return
            }
        }
        if let guidance = ComputerUseStatusSignal.userInterventionMessage(
            from: status) {
            enterUserIntervention(guidance)
            return
        }
        switch status {
        case "working":
            pauseAcknowledgement = nil
            latestTerminalOutcome = nil
            userInterventionGuidance = nil
            hostControlPaused = false
            _ = persistActivePrompt()
            guard !requiresRecoveryReconnect else { return }
            state = .working
            statusText = "Your Mac is working on it…"
            scheduleResponseTimeout()
        case "paused":
            // A generic acknowledgement must not erase the specific login or
            // other intervention guidance already associated with this pause.
            let interventionGuidance = latestTerminalOutcome
                == .userInterventionRequired
                ? userInterventionGuidance
                : nil
            userInterventionGuidance = interventionGuidance
            hostControlPaused = true
            _ = persistActivePrompt()
            guard !requiresRecoveryReconnect else { return }
            responseTimeoutTask?.cancel()
            responseTimeoutTask = nil
            state = .paused
            statusText = interventionGuidance
                ?? "AI paused — you're in control"
            stabilizeAuthoritativePause()
        case "ready":
            pauseAcknowledgement = nil
            userInterventionGuidance = nil
            hostControlPaused = false
            _ = persistActivePrompt()
            guard !requiresRecoveryReconnect else { return }
            if pendingControlIntent?.kind == .cancel,
               activePromptID != nil,
               activePromptBody != nil {
                state = .working
                statusText = "Stop confirmed — waiting for the final result…"
                scheduleResponseTimeout(message:
                    "Stop is confirmed. I’m asking the Mac to replay its final result safely.")
                startPromptRefresh(resendImmediately: true)
                return
            }
            if activePromptID != nil {
                state = .working
                statusText = "Finishing your request…"
                scheduleResponseTimeout()
                return
            }
            responseTimeoutTask?.cancel()
            responseTimeoutTask = nil
            state = .ready
            statusText = "Ready for a request"
        case "setupRequired":
            userInterventionGuidance = nil
            responseTimeoutTask?.cancel()
            responseTimeoutTask = nil
            clearActivePrompt()
            state = .error("Finish AI model setup on the Mac first.")
            statusText = "AI setup is required on this Mac"
        default:
            if !status.isEmpty {
                statusText = status
                if activePromptID != nil { scheduleResponseTimeout() }
            }
        }
    }

    private func clarificationRecovery(_ retry: ComputerUseClarificationRetry) -> (text: String, deadline: Date)? {
        guard lastControlKind != .cancel, lastControlKind != .pause,
              pendingControlIntent?.kind != .cancel, pendingControlIntent?.kind != .pause,
              hostControlPaused != true, let body = activePromptBody,
              let submitted = try? ComputerUsePromptRequest.decodeBody(body), submitted.supportsClarificationRetry,
              submitted.clarification == retry.reference, retry.answerPolicy.rejection(of: submitted.prompt) == retry.reason,
              retry.reason != .formatMismatch || submitted.supportsClarificationFormatRetry,
              let deadline = activeClarificationValidUntil, deadline.timeIntervalSince1970.isFinite,
              deadline <= retry.reference.expiresAt, let createdAt = activePromptCreatedAt,
              deadline <= createdAt.addingTimeInterval(600) else { return nil }
        return (submitted.prompt, deadline)
    }

    private func applyAssistantOutcome(
        _ outcome: ComputerUseTerminalOutcome?,
        text: String,
        clarification: ComputerUseClarificationReference?,
        answerPolicy: ComputerUseClarificationAnswerPolicy?,
        choices: [ComputerUseClarificationChoice]?,
        savedQuestion: ComputerUsePendingPrompt?
    ) {
        let acceptsAnswer = lastControlKind != .cancel && pendingControlIntent?.kind != .cancel
        let reference = acceptsAnswer && outcome == .userInterventionRequired
            && clarification?.taskID == activePromptID ? clarification : nil
        resetComposerMode()
        latestTerminalOutcome = outcome
        // Assistant envelopes are conversational task boundaries. Even a
        // typed intervention outcome is a terminal clarification whose answer
        // arrives as a new prompt; resumable live-screen takeover is carried
        // by a status envelope instead.
        userInterventionGuidance = nil
        state = .ready
        switch outcome {
        case .taskCompleted:
            statusText = "Task completed — ready for another request"
        case .userInterventionRequired:
            statusText = "Your input is required before your Mac can continue"
        case .unableToComplete:
            statusText = "Unable to complete — ready for another request"
        case nil:
            statusText = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .hasSuffix("?")
                ? "Answer the question so your Mac can continue"
                : "Ready for another request"
        }
        clearActivePrompt(removingStoredRecord: savedQuestion == nil)
        guard !requiresRecoveryReconnect else { return }
        waitingQuestionRecord = savedQuestion; questionDraft = savedQuestion?.question?.draft
        if let reference {
            awaitClarification(reference, answerPolicy: answerPolicy, choices: choices, originalDeadline: savedQuestion?.question?.validUntil)
        } else if acceptsAnswer, outcome == nil || outcome == .userInterventionRequired,
                  text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") {
            composerMode = .legacyAnswer
        }
    }

    private func enterUserIntervention(_ status: String) {
        let unboundedGuidance = ComputerUseStatusSignal
            .userInterventionMessage(from: status) ?? status
        let guidance = Self.boundedInterventionGuidance(unboundedGuidance)
            ?? "Your input is required before AI can continue."
        latestTerminalOutcome = .userInterventionRequired
        userInterventionGuidance = guidance
        hostControlPaused = true
        state = .paused
        statusText = guidance
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        // Persist the exact handoff instruction even when a Pause revision was
        // already durable. Without this write, a host acknowledgement that
        // arrives after Take control could be visible now but disappear after
        // an app relaunch because `stabilizeAuthoritativePause` has no newer
        // control to allocate.
        _ = persistActivePrompt()
        guard !requiresRecoveryReconnect else { return }
        stabilizeAuthoritativePause()
    }

    private static func boundedInterventionGuidance(
        _ value: String?
    ) -> String? {
        guard let value else { return nil }
        let bounded = String(value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(ComputerUseStatusSignal.maximumInterventionCharacters))
        return bounded.isEmpty ? nil : bounded
    }

    /// Older hosts need a phone Pause to retain their unversioned intervention
    /// through relaunch. Hosts with local epochs already persist that choice.
    private func stabilizeAuthoritativePause() {
        // Versioned local handoffs are already durable on the host. Echoing a
        // newly allocated phone Pause would turn an old status delivery into a
        // fresh command capable of undoing a later handback.
        guard hostControlEpoch == 0 else { return }
        guard activePromptID != nil,
              lastControlKind != .pause,
              lastControlKind != .cancel else { return }
        let generation = advanceStateGeneration()
        sendControl(.pause, generation: generation)
    }

    private func show(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        state = .error(message)
        statusText = message
    }

    private func sendPromptWithoutAppending(
        _ prompt: String,
        wireBody: String,
        messageID: String
    ) {
        let operationGeneration = advanceStateGeneration()
        let request = ComputerUsePromptRequest.decodeCompatibleBody(wireBody)
        if Self.requiresPersistentPrivacyShield(request) {
            isLiveScreenPrivacyShielded = true
        }
        guard !isStopped, !requiresRecoveryReconnect,
              stateGeneration == operationGeneration else { return }
        if activePromptID != messageID {
            guard rememberActivePrompt(
                prompt,
                wireBody: wireBody,
                messageID: messageID,
                createdAt: Date()) else {
                state = .error("Couldn’t securely save this request, so it was not sent.")
                statusText = "Request not sent — secure recovery storage is unavailable"
                return
            }
        }
        startPromptRefresh(resendImmediately: false)
        state = .working
        statusText = "Sending securely to your Mac…"
        launchOutboundTask { model in
            do {
                try await model.channel.send(
                    kind: .prompt,
                    body: wireBody,
                    to: nil,
                    sessionID: nil,
                    messageID: messageID)
                guard !Task.isCancelled,
                      !model.isStopped else { return }
                guard model.isCurrentOperation(
                    operationGeneration,
                    promptID: messageID) else { return }
                model.retryPrompt = nil
                model.retryMessageID = nil
                model.retryWireBody = nil
                model.statusText = "Your Mac is working on it…"
                model.scheduleResponseTimeout()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      !model.isStopped else { return }
                guard model.isCurrentOperation(
                    operationGeneration,
                    promptID: messageID) else { return }
                model.retryPrompt = prompt
                model.retryMessageID = messageID
                model.retryWireBody = wireBody
                model.show(error)
            }
        }
    }

    private func scheduleResponseTimeout(
        message: String = "No update yet. I’m checking with your Mac again; you can also Take control or stop safely."
    ) {
        guard let promptID = activePromptID else { return }
        let duration = responseTimeoutDuration
        responseTimeoutTask?.cancel()
        responseTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            guard let self else { return }
            guard !isStopped,
                  activePromptID == promptID else { return }
            switch state {
            case .working, .ready:
                statusText = message
            case .paused, .approvalRequired, .error:
                return
            }
        }
    }

    @discardableResult
    private func rememberActivePrompt(
        _ prompt: String,
        wireBody: String,
        messageID: String,
        createdAt: Date,
        clarificationValidUntil: Date? = nil
    ) -> Bool {
        let record = ComputerUsePendingPrompt(
            hostID: hostID,
            pairingCode: pairingCode,
            sessionID: sessionID,
            messageID: messageID,
            prompt: prompt,
            wireBody: wireBody,
            createdAt: createdAt,
            localAccountBinding: localAccountBinding,
            controlRevision: nil,
            lastControlKind: nil,
            approvalDecision: nil, clarificationValidUntil: clarificationValidUntil)
        guard replaceRecoveryRecord(record, expecting: waitingQuestionRecord ?? activePendingRecord) else {
            return false
        }
        activePendingRecord = record
        activePromptID = messageID
        activePromptText = prompt
        activePromptBody = wireBody
        activePromptCreatedAt = createdAt
        activeClarificationValidUntil = clarificationValidUntil
        controlRevision = 0
        acknowledgedControlRevision = 0
        lastControlKind = nil
        lastControlRevision = 0
        hostControlEpoch = 0
        lastControlHostEpoch = 0
        hostControlPaused = nil
        pauseAcknowledgement = nil
        unpersistedHostControlEpoch = nil
        pendingControlIntent = nil
        approvalSubmission = nil
        approvalResponseInFlightRequestID = nil
        controlRetryTask?.cancel()
        controlRetryTask = nil
        return true
    }

    @discardableResult
    private func persistActivePrompt() -> Bool {
        guard let messageID = activePromptID,
              let prompt = activePromptText,
              let wireBody = activePromptBody,
              let createdAt = activePromptCreatedAt,
              let previous = activePendingRecord else { return false }
        let record = ComputerUsePendingPrompt(
            hostID: hostID,
            pairingCode: pairingCode,
            sessionID: sessionID,
            messageID: messageID,
            prompt: prompt,
            wireBody: wireBody,
            createdAt: createdAt,
            localAccountBinding: localAccountBinding,
            controlRevision: controlRevision == 0 ? nil : controlRevision,
            acknowledgedControlRevision: acknowledgedControlRevision,
            lastControlKind: lastControlKind,
            lastControlRevision: lastControlRevision,
            hostControlEpoch: hostControlEpoch,
            lastControlHostEpoch: lastControlHostEpoch,
            hostControlPaused: hostControlPaused,
            approvalDecision: approvalSubmission,
            interventionGuidance: userInterventionGuidance, clarificationValidUntil: activeClarificationValidUntil)
        guard replaceRecoveryRecord(record, expecting: previous) else { return false }
        activePendingRecord = record
        return true
    }

    private func replaceRecoveryRecord(_ record: ComputerUsePendingPrompt,
                                       expecting previous: ComputerUsePendingPrompt?) -> Bool {
        switch pendingStore.replace(record, expecting: previous) {
        case .applied: return true
        case .conflict:
            requireRecoveryReconnect("The saved request changed. Reconnect to recover the current request.")
            return false
        case .unavailable: return false
        }
    }

    private func requireRecoveryReconnect(_ message: String) {
        requiresRecoveryReconnect = true
        isLiveScreenPrivacyShielded = true
        advanceStateGeneration()
        pollingTask?.cancel()
        promptRefreshTask?.cancel(); controlRetryTask?.cancel(); responseTimeoutTask?.cancel()
        questionProbeSendTask?.cancel(); questionProbeTimeoutTask?.cancel(); questionDraftSaveTask?.cancel()
        questionProbeID = nil
        for task in outboundTasks.values { task.cancel() }
        state = .error(message); statusText = message
    }

    private func clearActivePrompt(removingStoredRecord: Bool = true) {
        if removingStoredRecord, let previous = activePendingRecord {
            switch pendingStore.remove(ifMatching: previous) {
            case .applied: break
            case .conflict:
                requireRecoveryReconnect("The saved request changed. Reconnect to recover the current request.")
            case .unavailable:
                requireRecoveryReconnect("The task ended, but its saved recovery data could not be removed. Reconnect before sending another request.")
            }
        }
        activePendingRecord = nil
        activePromptID = nil
        activePromptText = nil
        activePromptBody = nil
        activePromptCreatedAt = nil
        activeClarificationValidUntil = nil
        controlRevision = 0
        acknowledgedControlRevision = 0
        lastControlKind = nil
        lastControlRevision = 0
        hostControlEpoch = 0
        lastControlHostEpoch = 0
        hostControlPaused = nil
        pauseAcknowledgement = nil
        unpersistedHostControlEpoch = nil
        pendingControlIntent = nil
        approvalSubmission = nil
        approvalResponseInFlightRequestID = nil
        retryPrompt = nil
        retryMessageID = nil
        retryWireBody = nil
        promptRefreshTask?.cancel()
        promptRefreshTask = nil
        controlRetryTask?.cancel()
        controlRetryTask = nil
    }

    private func startPromptRefresh(resendImmediately: Bool) {
        guard let messageID = activePromptID,
              let wireBody = activePromptBody else { return }
        let refreshInterval = promptRefreshInterval
        promptRefreshTask?.cancel()
        promptRefreshTask = Task { [weak self] in
            guard let self else { return }
            if resendImmediately {
                enqueuePromptRefresh(
                    messageID: messageID,
                    wireBody: wireBody)
            }
            while !Task.isCancelled,
                  !isStopped,
                  activePromptID == messageID {
                do {
                    try await Task.sleep(for: refreshInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      !isStopped,
                      activePromptID == messageID else { return }
                // Paused and approval-gated work is already durable on the
                // host. Do not place a duplicate prompt after a newer control
                // intent; Resume will continue the retained host context.
                guard case .working = state else { continue }
                enqueuePromptRefresh(
                    messageID: messageID,
                    wireBody: wireBody)
            }
        }
    }

    private func enqueuePromptRefresh(
        messageID: String,
        wireBody: String
    ) {
        launchOutboundTask { model in
            guard model.activePromptID == messageID else { return }
            _ = try? await model.channel.send(
                kind: .prompt,
                body: wireBody,
                to: nil,
                sessionID: nil,
                messageID: messageID)
        }
    }

    private func recentConversation() -> [ComputerUseConversationTurn] {
        // A completed response is a hard task boundary. The only context a
        // new wire request carries is the immediately preceding user request
        // and an assistant question that is awaiting this answer. This keeps
        // completed email/order details out of both the host preflight and the
        // visual planner while preserving ordinary one-turn clarification.
        guard messages.count >= 2 else { return [] }
        let priorUser = messages[messages.count - 2]
        let assistant = messages[messages.count - 1]
        guard priorUser.author == .user,
              assistant.author == .assistant,
              assistant.researchProgress == nil,
              assistant.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .hasSuffix("?") else {
            return []
        }
        return [
            ComputerUseConversationTurn(role: .user, text: priorUser.text),
            ComputerUseConversationTurn(role: .assistant, text: assistant.text),
        ]
    }

    private func restoreStatusText() {
        switch state {
        case .ready:
            switch composerMode {
            case .answer: statusText = "Answer the question to continue the original request"
            case .legacyAnswer: statusText = "Answer the question or start a new request"
            case .recoveringAnswer: statusText = "Checking your saved question with the Mac…"
            case .expiredAnswer: statusText = "This question is no longer active. Start a new request."
            case .request: statusText = "Ready for a request"
            }
        case .working: statusText = "Your Mac is working on it…"
        case .paused:
            statusText = hasHostPauseAcknowledgement
                ? (userInterventionGuidance ?? "AI paused — you're in control")
                : "Waiting for your Mac to confirm control…"
        case .approvalRequired: statusText = "Your approval is needed"
        case .error(let message): statusText = message
        }
    }

    /// Mirrors the host's deterministic embedded-Mail request boundary. It
    /// intentionally excludes merely opening Mail, reading an inbox, or an
    /// unrelated visual task so OSAtlas and ordinary MCP work remain visible.
    private static func requiresPersistentPrivacyShield(
        _ request: ComputerUsePromptRequest
    ) -> Bool {
        var userTurns = [request.prompt]
        if request.conversation.count >= 2 {
            let priorUser = request.conversation[request.conversation.count - 2]
            let assistant = request.conversation[request.conversation.count - 1]
            if priorUser.role == .user,
               assistant.role == .assistant,
               isMailClarification(assistant.text) {
                userTurns.insert(priorUser.text, at: 0)
            }
        }

        let value = userTurns.joined(separator: "\n")
        let text = normalized(value)
        let mentionsEmail = containsAny(
            ["email", "e mail", "mail message"],
            in: text)
        let asksToSend = containsAny(
            ["send", "write", "compose", "draft"],
            in: text)
            || containsMatch(
                #"\b(?:email|mail)\s+(?!(?:app|inbox|message|window)\b)\S+"#,
                in: value)
        return mentionsEmail && asksToSend
    }

    private static func isMailClarification(_ value: String) -> Bool {
        let question = normalized(value)
        let knownQuestions: Set<String> = [
            "who should receive the email and what should it say",
            "who should receive the email please give me their name or email address",
            "what email address should i use for the to recipient",
            "what should the email say",
            "should i send the email now or create a draft for review",
        ]
        if knownQuestions.contains(question) { return true }
        return question.hasPrefix("which recipient field should i use for ")
            && question.hasSuffix(" to cc or bcc")
    }

    private static func containsAny(
        _ values: [String],
        in text: String
    ) -> Bool {
        let padded = " \(normalized(text)) "
        return values.contains { padded.contains(" \(normalized($0)) ") }
    }

    private static func normalized(_ value: String) -> String {
        let mapped = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(mapped)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func containsMatch(
        _ pattern: String,
        in value: String
    ) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)) != nil
    }
}

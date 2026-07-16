import Foundation

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

extension CloudKitComputerUseChannel: ComputerUseSessionChannel {}

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
    }

    enum State: Equatable {
        case ready
        case working
        case paused
        case approvalRequired(ComputerUseApprovalRequest)
        case error(String)
    }

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var state: State = .ready
    @Published private(set) var statusText = "Ready for a request"
    @Published private(set) var retryPrompt: String?
    /// Becomes true only when `SessionModel` receives the authenticated host
    /// hello and calls `start()`. CloudKit recovery and lifecycle traffic must
    /// never leave the phone while the WebRTC peer is still unauthenticated.
    @Published private(set) var isConnected = false
    /// Embedded Mail MCP tasks can leave a small compose/result window above
    /// unrelated desktop content. Cover the remote pixels for the task's full
    /// lifecycle, starting before the request leaves the phone, until the
    /// person explicitly chooses to reveal the Mac again.
    @Published private(set) var isLiveScreenPrivacyShielded = false

    var hasActivePrompt: Bool { activePromptID != nil }
    var isCancellationPending: Bool {
        activePromptID != nil && lastControlKind == .cancel
    }
    var interventionGuidance: String? { userInterventionGuidance }

    let hostName: String
    private let channel: any ComputerUseSessionChannel
    private let hostID: String
    private let pairingCode: String
    private let sessionID: String
    private let pendingStore: any ComputerUsePendingPromptStoring
    private var pollingTask: Task<Void, Never>?
    private var responseTimeoutTask: Task<Void, Never>?
    private var promptRefreshTask: Task<Void, Never>?
    private var controlRetryTask: Task<Void, Never>?
    private var outboundTasks: [UUID: Task<Void, Never>] = [:]
    /// Monotonically identifies the newest local intent or authoritative host
    /// state. An older CloudKit completion may arrive after a person resumes,
    /// stops, or starts another request; it must not overwrite that newer UI.
    private var stateGeneration: UInt64 = 0
    private var isStopped = true
    private let responseTimeoutDuration: Duration
    private let promptRefreshInterval: Duration
    private var transportNotice: String?
    private var retryMessageID: String?
    private var retryWireBody: String?
    private var activePromptID: String?
    private var activePromptText: String?
    private var activePromptBody: String?
    private var activePromptCreatedAt: Date?
    private var controlRevision: UInt64 = 0
    private var lastControlKind: ComputerUseEnvelope.Kind?
    private var pendingControlIntent: PendingControlIntent?
    private var approvalSubmission: ComputerUsePendingApprovalDecision?
    private var approvalResponseInFlightRequestID: String?
    private var userInterventionGuidance: String?

    private struct PendingControlIntent: Equatable {
        let taskID: String
        let revision: UInt64
        let kind: ComputerUseEnvelope.Kind
    }

    init(
        hostName: String,
        pairingCode: String,
        hostID: String,
        sessionID: String? = nil,
        senderID: String = DeviceIdentity.get(),
        pendingStore: any ComputerUsePendingPromptStoring = ComputerUsePendingPromptStore.shared,
        channel: (any ComputerUseSessionChannel)? = nil,
        responseTimeoutDuration: Duration = .seconds(20 * 60),
        promptRefreshInterval: Duration = .seconds(30)
    ) {
        let restored = pendingStore.load(
            hostID: hostID,
            pairingCode: pairingCode)
        let effectiveSessionID = restored?.sessionID
            ?? sessionID
            ?? UUID().uuidString
        self.hostName = hostName
        self.hostID = hostID
        self.pairingCode = pairingCode
        self.sessionID = effectiveSessionID
        self.pendingStore = pendingStore
        self.responseTimeoutDuration = responseTimeoutDuration
        self.promptRefreshInterval = promptRefreshInterval
        self.channel = channel ?? CloudKitComputerUseChannel(
            containerIdentifier: Config.cloudKitContainerIdentifier,
            pairingCode: pairingCode,
            sessionID: effectiveSessionID,
            senderID: senderID,
            targetID: hostID,
            startedAt: restored?.createdAt.addingTimeInterval(-30) ?? Date())

        if let restored {
            activePromptID = restored.messageID
            activePromptText = restored.prompt
            activePromptBody = restored.exactWireBody
            activePromptCreatedAt = restored.createdAt
            controlRevision = restored.controlRevision ?? 0
            lastControlKind = restored.lastControlKind
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
                state = .paused
                statusText = "AI paused — you're in control"
            case .cancel:
                state = .working
                statusText = "Confirming your previous Stop…"
            default:
                state = .working
                if let decision = restored.approvalDecision {
                    statusText = decision.approved
                        ? "Restoring your approval…"
                        : "Restoring your cancellation…"
                } else {
                    statusText = "Checking your previous request with the Mac…"
                }
            }
        }
    }

    func start() {
        guard pollingTask == nil else { return }
        isStopped = false
        isConnected = true
        pollingTask = Task { [weak self] in
            await self?.pollLoop()
        }
        if activePromptID != nil {
            if lastControlKind != .pause, lastControlKind != .cancel {
                startPromptRefresh(resendImmediately: true)
            }
            replayPersistedControlIfNeeded()
            if lastControlKind != .pause {
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

    func sendPrompt(_ rawPrompt: String) {
        guard !isStopped else { return }
        let prompt = String(rawPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(8_000))
        guard !prompt.isEmpty, activePromptID == nil else { return }
        switch state {
        case .ready, .error:
            break
        case .working, .paused, .approvalRequired:
            return
        }

        let operationGeneration = advanceStateGeneration()
        let messageID = UUID().uuidString
        let request = ComputerUsePromptRequest(
            prompt: prompt,
            conversation: recentConversation())
        let wireBody = (try? request.encodedBody()) ?? prompt
        if Self.requiresPersistentPrivacyShield(request) {
            // This is deliberately synchronous: do not expose unrelated Mac
            // pixels while the embedded Mail request is in flight or being
            // deterministically clarified by the host.
            isLiveScreenPrivacyShielded = true
        }
        let message = ChatMessage(
            id: messageID,
            author: .user,
            text: prompt,
            createdAt: Date())
        messages.append(message)
        guard rememberActivePrompt(
            prompt,
            wireBody: wireBody,
            messageID: messageID,
            createdAt: message.createdAt) else {
            messages.removeAll { $0.id == messageID }
            state = .error("Couldn’t securely save this request, so it was not sent.")
            statusText = "Request not sent — secure recovery storage is unavailable"
            return
        }
        state = .working
        statusText = "Sending securely through iCloud…"
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
              activePromptID != nil,
              lastControlKind != .cancel else { return }
        let operationGeneration = advanceStateGeneration()
        userInterventionGuidance = nil
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        state = .paused
        statusText = "AI paused — you're in control"
        sendControl(.pause, generation: operationGeneration)
    }

    func resumeAI() {
        guard !isStopped,
              activePromptID != nil,
              lastControlKind != .cancel else { return }
        let operationGeneration = advanceStateGeneration()
        userInterventionGuidance = nil
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        state = .working
        statusText = "Asking AI to continue…"
        startPromptRefresh(resendImmediately: true)
        scheduleResponseTimeout(
            message: "No update yet. I’m checking with your Mac again; you can also Take control or stop safely.")
        sendControl(.resume, generation: operationGeneration)
    }

    func stopCurrentTask() {
        guard !isStopped,
              activePromptID != nil,
              lastControlKind != .cancel else { return }
        let operationGeneration = advanceStateGeneration()
        userInterventionGuidance = nil
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        // Versioned Cancel is absorbing on the host, so no prompt refresh
        // should recreate task traffic after Stop.
        promptRefreshTask?.cancel()
        promptRefreshTask = nil
        state = .working
        statusText = "Stopping the task…"
        scheduleResponseTimeout(
            message: "The Mac hasn’t confirmed Stop yet. Touch the live screen to keep AI paused.")
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
            appliedControlRevision: request.appliedControlRevision)
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
        advanceStateGeneration()
        if approved, Self.requiresPersistentPrivacyShield(request) {
            // Set this before the approval response leaves the phone. The
            // full-card privacy backdrop is about to disappear, and Mail may
            // activate immediately once the host receives the response.
            isLiveScreenPrivacyShielded = true
        }
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
            kind: kind)
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
                    model.statusText = "Couldn’t reach AI through iCloud. Touch the live screen to take control immediately."
                case .resume:
                    model.state = .paused
                    model.statusText = "Couldn’t resume AI yet. Check iCloud and try again."
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
        guard !isStopped else { return }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishOutboundTask(id) }
            guard !Task.isCancelled, !self.isStopped else { return }
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
        guard controlRevision < UInt64.max else { return nil }
        let previousRevision = controlRevision
        let previousKind = lastControlKind
        controlRevision += 1
        lastControlKind = kind
        guard persistActivePrompt() else {
            controlRevision = previousRevision
            lastControlKind = previousKind
            return nil
        }
        return ComputerUseControlRequest(
            taskID: taskID,
            revision: controlRevision)
    }

    private func replayPersistedControlIfNeeded() {
        guard let taskID = activePromptID,
              controlRevision > 0,
              let kind = lastControlKind,
              kind == .pause || kind == .resume || kind == .cancel else {
            return
        }
        let request = ComputerUseControlRequest(
            taskID: taskID,
            revision: controlRevision)
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
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        switch kind {
        case .pause:
            state = .paused
            statusText = "Couldn’t safely save Pause. Touch the live screen to take control immediately."
        case .resume:
            state = .paused
            statusText = "Couldn’t safely save Resume. AI remains paused."
        case .cancel:
            state = .paused
            statusText = "Couldn’t safely save Stop. Touch the live screen to keep AI paused."
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
        while !Task.isCancelled, !isStopped {
            do {
                let envelopes = try await channel.poll()
                guard !Task.isCancelled, !isStopped else { return }
                if transportNotice != nil {
                    transportNotice = nil
                    restoreStatusText()
                }
                consume(envelopes)
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
                statusText = "iCloud connection interrupted — retrying…"
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
            switch envelope.kind {
            case .assistant:
                let update = try? ComputerUseTaskUpdate.decodeBody(envelope.body)
                let taskID = update?.taskID ?? activePromptID
                guard let activePromptID,
                      taskID == activePromptID else { continue }
                if let appliedControlRevision = update?.appliedControlRevision {
                    guard acceptAppliedControlRevision(
                        appliedControlRevision) else { continue }
                } else if controlRevision > 0 {
                    // A terminal reply created before the newest lifecycle
                    // intent is not proof that Pause/Resume/Stop was applied.
                    // Current hosts attach their durable revision snapshot.
                    continue
                } else {
                    approvalSubmission = nil
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
                state = .ready
                statusText = assistantText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasSuffix("?")
                    ? "Answer the question so your Mac can continue"
                    : "Ready for another request"
                clearActivePrompt()
            case .status:
                if let update = try? ComputerUseTaskUpdate.decodeBody(envelope.body) {
                    guard update.taskID == activePromptID else { continue }
                    guard shouldApplyHostStatus(
                        update.text,
                        appliedControlRevision: update.appliedControlRevision) else {
                        continue
                    }
                    retryPrompt = nil
                    retryMessageID = nil
                    retryWireBody = nil
                    applyHostStatus(update.text)
                } else {
                    // Legacy raw statuses have no task identity. They may
                    // describe the active v2 task, but must never resurrect a
                    // terminal task after an assistant reply cleared it.
                    guard activePromptID != nil else { continue }
                    guard shouldApplyHostStatus(
                        envelope.body,
                        appliedControlRevision: nil) else { continue }
                    applyHostStatus(envelope.body)
                }
            case .approvalRequest:
                guard let request = try? ComputerUseApprovalRequest.decodeBody(envelope.body) else {
                    continue
                }
                guard request.taskID == activePromptID else { continue }
                if lastControlKind == .cancel
                    || pendingControlIntent?.kind == .cancel
                    || pendingControlIntent?.kind == .pause {
                    continue
                }
                if case .paused = state { continue }
                if let appliedControlRevision = request.appliedControlRevision {
                    guard acceptAppliedControlRevision(
                        appliedControlRevision) else { continue }
                } else if controlRevision > 0 {
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
                advanceStateGeneration()
                if Self.requiresPersistentPrivacyShield(request) {
                    // The structured host approval is the authoritative fallback
                    // if future Mail phrasing is broader than the bounded
                    // request-side classifier below.
                    isLiveScreenPrivacyShielded = true
                }
                state = .approvalRequired(request)
                responseTimeoutTask?.cancel()
                responseTimeoutTask = nil
                statusText = "Your approval is needed"
            case .prompt, .pause, .resume, .cancel, .setupRequest, .setupProgress,
                 .approvalResponse:
                break
            }
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

        // Once this client has issued a versioned lifecycle intent, an
        // unversioned status can have been created before that intent and
        // delivered later. Only a typed safety intervention may supersede it.
        if controlRevision > 0 {
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

    private func acceptAppliedControlRevision(_ revision: UInt64) -> Bool {
        guard revision >= controlRevision else { return false }
        if revision > controlRevision {
            let previousRevision = controlRevision
            controlRevision = revision
            guard persistActivePrompt() else {
                controlRevision = previousRevision
                return false
            }
        }
        return true
    }

    func applyHostStatus(_ status: String) {
        advanceStateGeneration()
        if let guidance = ComputerUseStatusSignal.userInterventionMessage(
            from: status) {
            userInterventionGuidance = guidance
            state = .paused
            statusText = guidance
            responseTimeoutTask?.cancel()
            responseTimeoutTask = nil
            stabilizeAuthoritativePause()
            return
        }
        switch status {
        case "working":
            userInterventionGuidance = nil
            state = .working
            statusText = "Your Mac is working on it…"
            scheduleResponseTimeout()
        case "paused":
            userInterventionGuidance = nil
            responseTimeoutTask?.cancel()
            responseTimeoutTask = nil
            state = .paused
            statusText = "AI paused — you're in control"
            stabilizeAuthoritativePause()
        case "ready":
            userInterventionGuidance = nil
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

    /// A host can pause on its own for manual input or because a Resume could
    /// not continue. Persist a strictly newer Pause before returning control
    /// to the person so relaunch cannot replay the older Resume or approval.
    private func stabilizeAuthoritativePause() {
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
        statusText = "Sending securely through iCloud…"
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
        createdAt: Date
    ) -> Bool {
        guard pendingStore.save(ComputerUsePendingPrompt(
            hostID: hostID,
            pairingCode: pairingCode,
            sessionID: sessionID,
            messageID: messageID,
            prompt: prompt,
            wireBody: wireBody,
            createdAt: createdAt,
            controlRevision: nil,
            lastControlKind: nil,
            approvalDecision: nil)) else {
            return false
        }
        activePromptID = messageID
        activePromptText = prompt
        activePromptBody = wireBody
        activePromptCreatedAt = createdAt
        controlRevision = 0
        lastControlKind = nil
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
              let createdAt = activePromptCreatedAt else { return false }
        return pendingStore.save(ComputerUsePendingPrompt(
            hostID: hostID,
            pairingCode: pairingCode,
            sessionID: sessionID,
            messageID: messageID,
            prompt: prompt,
            wireBody: wireBody,
            createdAt: createdAt,
            controlRevision: controlRevision == 0 ? nil : controlRevision,
            lastControlKind: lastControlKind,
            approvalDecision: approvalSubmission))
    }

    private func clearActivePrompt() {
        activePromptID = nil
        activePromptText = nil
        activePromptBody = nil
        activePromptCreatedAt = nil
        controlRevision = 0
        lastControlKind = nil
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
        pendingStore.remove(hostID: hostID)
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
        case .ready: statusText = "Ready for a request"
        case .working: statusText = "Your Mac is working on it…"
        case .paused:
            statusText = userInterventionGuidance
                ?? "AI paused — you're in control"
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

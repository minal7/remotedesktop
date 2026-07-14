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
    /// Embedded Mail MCP tasks can leave a small compose/result window above
    /// unrelated desktop content. Cover the remote pixels for the task's full
    /// lifecycle, starting before the request leaves the phone, until the
    /// person explicitly chooses to reveal the Mac again.
    @Published private(set) var isLiveScreenPrivacyShielded = false

    var hasActivePrompt: Bool { activePromptID != nil }
    var interventionGuidance: String? { userInterventionGuidance }

    let hostName: String
    private let channel: any ComputerUseSessionChannel
    private let hostID: String
    private let pairingCode: String
    private let sessionID: String
    private let pendingStore: ComputerUsePendingPromptStore
    private var pollingTask: Task<Void, Never>?
    private var responseTimeoutTask: Task<Void, Never>?
    private var promptRefreshTask: Task<Void, Never>?
    private var transportNotice: String?
    private var retryMessageID: String?
    private var retryWireBody: String?
    private var activePromptID: String?
    private var activePromptText: String?
    private var activePromptBody: String?
    private var userInterventionGuidance: String?

    init(
        hostName: String,
        pairingCode: String,
        hostID: String,
        sessionID: String? = nil,
        senderID: String = DeviceIdentity.get(),
        pendingStore: ComputerUsePendingPromptStore = .shared,
        channel: (any ComputerUseSessionChannel)? = nil
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
            state = .working
            statusText = "Checking your previous request with the Mac…"
        }
    }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            await self?.pollLoop()
        }
        if activePromptID != nil {
            startPromptRefresh(resendImmediately: true)
            scheduleResponseTimeout()
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        promptRefreshTask?.cancel()
        promptRefreshTask = nil
    }

    func sendPrompt(_ rawPrompt: String) {
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
        rememberActivePrompt(
            prompt,
            wireBody: wireBody,
            messageID: messageID,
            createdAt: message.createdAt)
        state = .working
        statusText = "Sending securely through iCloud…"
        startPromptRefresh(resendImmediately: false)

        Task { [weak self] in
            guard let self else { return }
            do {
                try await channel.send(
                    kind: .prompt,
                    body: wireBody,
                    to: nil,
                    sessionID: nil,
                    messageID: messageID)
                retryPrompt = nil
                retryMessageID = nil
                retryWireBody = nil
                statusText = "Your Mac is working on it…"
                scheduleResponseTimeout()
            } catch is CancellationError {
                return
            } catch {
                retryPrompt = prompt
                retryMessageID = messageID
                retryWireBody = wireBody
                show(error)
            }
        }
    }

    func retryLastPrompt() {
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
        userInterventionGuidance = nil
        state = .paused
        statusText = "AI paused — you're in control"
        sendControl(.pause)
    }

    func resumeAI() {
        userInterventionGuidance = nil
        state = .working
        statusText = "Asking AI to continue…"
        sendControl(.resume)
    }

    func stopCurrentTask() {
        userInterventionGuidance = nil
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        state = .working
        statusText = "Stopping the task…"
        sendControl(.cancel)
    }

    func respondToApproval(_ request: ComputerUseApprovalRequest, approved: Bool) {
        guard case .approvalRequired(let current) = state,
              current.requestID == request.requestID else { return }
        if approved, Self.requiresPersistentPrivacyShield(request) {
            // Set this before the approval response leaves the phone. The
            // full-card privacy backdrop is about to disappear, and Mail may
            // activate immediately once the host receives the response.
            isLiveScreenPrivacyShielded = true
        }
        state = approved ? .working : .ready
        statusText = approved
            ? "Approved — your Mac is continuing…"
            : "Canceled — no action was taken"
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = ComputerUseApprovalResponse(
                    requestID: request.requestID,
                    approved: approved)
                try await channel.send(
                    kind: .approvalResponse,
                    body: try response.encodedBody())
                if approved { scheduleResponseTimeout() }
            } catch is CancellationError {
                return
            } catch {
                state = .approvalRequired(request)
                statusText = "Couldn’t send your choice. Check iCloud and try again."
            }
        }
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

    private func sendControl(_ kind: ComputerUseEnvelope.Kind) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await channel.send(kind: kind, body: "")
            } catch is CancellationError {
                return
            } catch {
                switch kind {
                case .pause:
                    state = .paused
                    statusText = "Couldn’t reach AI through iCloud. Touch the live screen to take control immediately."
                case .resume:
                    state = .paused
                    statusText = "Couldn’t resume AI yet. Check iCloud and try again."
                case .cancel:
                    state = .paused
                    statusText = "Couldn’t confirm Stop yet. Touch the live screen to keep AI paused."
                default:
                    show(error)
                }
            }
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            do {
                let envelopes = try await channel.poll()
                if transportNotice != nil {
                    transportNotice = nil
                    restoreStatusText()
                }
                consume(envelopes)
                try await channel.acknowledge(envelopes)
                // Approval and completion often arrive back-to-back. Poll
                // again immediately after real work so the confirmation
                // result is not hidden behind the idle two-second cadence.
                if !envelopes.isEmpty { continue }
            } catch is CancellationError {
                return
            } catch {
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
                    retryPrompt = nil
                    retryMessageID = nil
                    retryWireBody = nil
                    applyHostStatus(update.text)
                } else {
                    applyHostStatus(envelope.body)
                }
            case .approvalRequest:
                guard let request = try? ComputerUseApprovalRequest.decodeBody(envelope.body) else {
                    continue
                }
                guard request.taskID == activePromptID else { continue }
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

    func applyHostStatus(_ status: String) {
        if let guidance = ComputerUseStatusSignal.userInterventionMessage(
            from: status) {
            userInterventionGuidance = guidance
            state = .paused
            statusText = guidance
            responseTimeoutTask?.cancel()
            responseTimeoutTask = nil
            return
        }
        switch status {
        case "working":
            userInterventionGuidance = nil
            state = .working
            statusText = "Your Mac is working on it…"
        case "paused":
            userInterventionGuidance = nil
            state = .paused
            statusText = "AI paused — you're in control"
        case "ready":
            userInterventionGuidance = nil
            if activePromptID != nil {
                state = .working
                statusText = "Finishing your request…"
                return
            }
            responseTimeoutTask?.cancel()
            responseTimeoutTask = nil
            state = .ready
            statusText = "Ready for a request"
        case "setupRequired":
            state = .error("Finish AI model setup on the Mac first.")
            statusText = "AI setup is required on this Mac"
        default:
            if !status.isEmpty { statusText = status }
        }
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
        let request = ComputerUsePromptRequest.decodeCompatibleBody(wireBody)
        if Self.requiresPersistentPrivacyShield(request) {
            isLiveScreenPrivacyShielded = true
        }
        if activePromptID != messageID {
            rememberActivePrompt(
                prompt,
                wireBody: wireBody,
                messageID: messageID,
                createdAt: Date())
        }
        startPromptRefresh(resendImmediately: false)
        state = .working
        statusText = "Sending securely through iCloud…"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await channel.send(
                    kind: .prompt,
                    body: wireBody,
                    to: nil,
                    sessionID: nil,
                    messageID: messageID)
                retryPrompt = nil
                retryMessageID = nil
                retryWireBody = nil
                statusText = "Your Mac is working on it…"
                scheduleResponseTimeout()
            } catch is CancellationError {
                return
            } catch {
                retryPrompt = prompt
                retryMessageID = messageID
                retryWireBody = wireBody
                show(error)
            }
        }
    }

    private func scheduleResponseTimeout() {
        responseTimeoutTask?.cancel()
        responseTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(20 * 60))
            } catch {
                return
            }
            guard let self, case .working = state else { return }
            statusText = "No update yet. I’m checking with your Mac again; you can also Take control or stop safely."
        }
    }

    private func rememberActivePrompt(
        _ prompt: String,
        wireBody: String,
        messageID: String,
        createdAt: Date
    ) {
        activePromptID = messageID
        activePromptText = prompt
        activePromptBody = wireBody
        pendingStore.save(ComputerUsePendingPrompt(
            hostID: hostID,
            pairingCode: pairingCode,
            sessionID: sessionID,
            messageID: messageID,
            prompt: prompt,
            wireBody: wireBody,
            createdAt: createdAt))
    }

    private func clearActivePrompt() {
        activePromptID = nil
        activePromptText = nil
        activePromptBody = nil
        retryPrompt = nil
        retryMessageID = nil
        retryWireBody = nil
        promptRefreshTask?.cancel()
        promptRefreshTask = nil
        pendingStore.remove(hostID: hostID)
    }

    private func startPromptRefresh(resendImmediately: Bool) {
        guard let messageID = activePromptID,
              let wireBody = activePromptBody else { return }
        promptRefreshTask?.cancel()
        promptRefreshTask = Task { [weak self] in
            guard let self else { return }
            if resendImmediately {
                _ = try? await channel.send(
                    kind: .prompt,
                    body: wireBody,
                    to: nil,
                    sessionID: nil,
                    messageID: messageID)
            }
            while !Task.isCancelled,
                  activePromptID == messageID {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                guard activePromptID == messageID else { return }
                _ = try? await channel.send(
                    kind: .prompt,
                    body: wireBody,
                    to: nil,
                    sessionID: nil,
                    messageID: messageID)
            }
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

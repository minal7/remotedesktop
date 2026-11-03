import Foundation

/// Routes only an explicit `Remember …` command from the ordinary request composer.
/// The command text is returned unchanged so the owner can review and edit it.
enum PersonalMemoryComposerRoute: Equatable {
    case sendTask
    case openRemember(originalText: String)
    case refuseUnavailable
    case refuseIncognito

    static func decide(text: String, isRequestMode: Bool, memoryAvailable: Bool,
                       incognito: Bool) -> Self {
        guard isRequestMode, isExplicitRememberCommand(text) else { return .sendTask }
        if incognito { return .refuseIncognito }
        guard memoryAvailable else { return .refuseUnavailable }
        return .openRemember(originalText: text)
    }

    private static func isExplicitRememberCommand(_ text: String) -> Bool {
        let leading = text.prefix(while: \.isWhitespace).count
        let command = text.dropFirst(leading)
        guard command.count >= "Remember".count,
              String(command.prefix("Remember".count)).caseInsensitiveCompare("Remember") == .orderedSame
        else { return false }
        return command.count == "Remember".count
            || command.dropFirst("Remember".count).first?.isWhitespace == true
    }
}

@MainActor
extension PersonalMemoryViewModel {
    private typealias PendingRemember = PersonalMemoryPendingRemember

    var canBeginRemember: Bool {
        guard canUseChannel, !disconnected, !verifiedAbsentNeedsInitialization,
              forgetCommandID == nil,
              initializationCommandID == nil, requestTask == nil,
              !mutationInFlight else { return false }
        switch state {
        case .ready, .error: return true
        case .unavailable, .loading: return false
        }
    }

    func beginRememberComposition() -> Bool {
        guard canBeginRemember else { return false }
        clearRememberState()
        rememberCompositionActive = true
        return true
    }

    @discardableResult
    func saveRemember(kind: LocalMemoryRPCCommand.RememberKind, text: String) -> String? {
        guard rememberCompositionActive,
              (rememberState == .idle || rememberState == .rejected),
              canUseChannel, !disconnected, forgetCommandID == nil,
              initializationCommandID == nil, requestTask == nil,
              !mutationInFlight else { return nil }
        let pending = PendingRemember(kind: kind, text: text,
                                      commandID: UUID().uuidString.lowercased())
        let command = LocalMemoryRPCCommand(rememberKind: kind, text: text,
                                            commandID: pending.commandID)
        guard validate(command) else { return nil }
        pendingRemember = pending
        rememberCompositionActive = false
        rememberReceipt = nil
        rememberState = .saving
        mutationInFlight = true
        sendRemember(pending)
        return pending.commandID
    }

    @discardableResult
    func retryRemember() -> String? {
        guard rememberState == .unknown, !rememberCompositionActive,
              canUseChannel, !disconnected, forgetCommandID == nil,
              initializationCommandID == nil, requestTask == nil,
              !mutationInFlight, let pending = pendingRemember else { return nil }
        rememberState = .saving
        mutationInFlight = true
        sendRemember(pending)
        return pending.commandID
    }

    func cancelRememberComposition() {
        switch rememberState {
        case .saving, .unknown:
            // A dismissed form cannot establish that the host did not commit.
            // Retain the command ID so a later explicit retry is idempotent.
            rememberCompositionActive = false
            return
        case .saved:
            finishRememberPresentation()
            return
        case .idle, .rejected:
            break
        }
        clearRememberState()
    }

    func finishRememberPresentation() {
        guard rememberState == .saved else { return }
        let shouldReload = state == .ready && requestTask == nil && !mutationInFlight
        clearRememberState()
        if shouldReload { beginQuery(query) }
    }

    func clearRememberState() {
        pendingRemember = nil
        rememberCompositionActive = false
        rememberState = .idle
        rememberReceipt = nil
    }

    private func sendRemember(_ pending: PendingRemember) {
        guard canUseChannel, !disconnected, forgetCommandID == nil,
              initializationCommandID == nil, pendingRemember == pending,
              let currentChannel = channel else {
            mutationInFlight = false
            rememberState = .unknown
            return
        }
        let command = LocalMemoryRPCCommand(rememberKind: pending.kind, text: pending.text,
                                            commandID: pending.commandID)
        guard validate(command) else {
            mutationInFlight = false
            rememberState = .rejected
            pendingRemember = nil
            return
        }
        let requestGeneration = generation
        let token = beginRequestDeadline(kind: .remember, generation: requestGeneration)
        requestTask = Task { [weak self] in
            guard self?.generation == requestGeneration, !Task.isCancelled else { return }
            do {
                let reply = try await currentChannel.sendMemoryCommand(command)
                guard let self, self.generation == requestGeneration,
                      self.requestToken == token, !Task.isCancelled, !self.disconnected,
                      self.pendingRemember == pending else { return }
                self.finishRequest(token)
                try PersonalMemoryReplyValidator.remember(reply, command: command)
                self.mutationInFlight = false
                switch reply.status {
                case .completed:
                    guard let recordID = reply.recordID else {
                        self.rememberState = .unknown
                        return
                    }
                    self.rememberReceipt = PersonalMemoryRememberReceipt(
                        kind: pending.kind, commandID: pending.commandID, recordID: recordID)
                    self.pendingRemember = nil
                    self.rememberState = .saved
                case .unavailable:
                    self.rememberState = .unknown
                default:
                    self.pendingRemember = nil
                    self.rememberCompositionActive = true
                    self.rememberState = .rejected
                }
            } catch {
                guard let self, self.generation == requestGeneration,
                      self.requestToken == token, !Task.isCancelled, !self.disconnected,
                      self.pendingRemember == pending else { return }
                self.finishRequest(token)
                self.mutationInFlight = false
                self.rememberState = .unknown
            }
        }
    }
}

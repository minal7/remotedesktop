import Combine
import Foundation

protocol PersonalMemoryChannel: Sendable {
    func sendMemoryCommand(_ command: LocalMemoryRPCCommand) async throws -> LocalMemoryRPCReply
}

@MainActor
final class PersonalMemoryViewModel: ObservableObject {
    typealias MutationReceipt = PersonalMemoryMutationReceipt
    typealias State = PersonalMemoryViewState
    private typealias PendingEdit = PersonalMemoryPendingEdit
    private typealias RequestKind = PersonalMemoryRequestKind
    private typealias ValidationFailure = PersonalMemoryValidationFailure

    private static let pageSize = 20
    private static let loadFailure = "Memories could not be loaded. Try again."
    private static let mutationUnknown = "The change may have completed. Reload before trying again."
    private static let forgetUnknown = "Forget could not be confirmed. Retry the same request to finish."
    private static let initializationUnknown = "Fresh memory could not be confirmed. Retry the same request to finish."
    private static let generationUnavailable = "Forget is unavailable. Reload Memory and try again."
    private static let staleEdit = "This memory changed elsewhere. Reload before editing it."
    private static let unavailableMessage = "Memory is unavailable for this connection."

    @Published private(set) var state: State = .unavailable
    @Published private(set) var records: [LocalMemoryRPCRecord] = []
    @Published private(set) var query = ""
    @Published private(set) var nextRecordID: String?
    @Published private(set) var draftText: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var mutationReceipt: MutationReceipt?
    @Published private(set) var forgetConfirmationToken: UUID?
    @Published private(set) var forgetCommandID: String?
    @Published private(set) var generationReference: String?
    @Published private(set) var forgetInProgress = false
    @Published private(set) var forgetCompleted = false
    @Published private(set) var verifiedAbsentNeedsInitialization = false
    @Published private(set) var initializationConfirmationToken: UUID?
    @Published private(set) var initializationCommandID: String?
    @Published private(set) var initializationSourceReference: String?
    @Published private(set) var replacementGenerationReference: String?
    @Published private(set) var initializationInProgress = false
    @Published private(set) var initializationCompleted = false
    @Published var rememberState: PersonalMemoryRememberState = .idle
    @Published var rememberReceipt: PersonalMemoryRememberReceipt?
    @Published var rememberCompositionActive = false

    /// Value-free correlation metadata for the host's Forget-only reply lane.
    var confirmedForgetGenerationReference: String? { forgetGenerationReference }

    var canBeginFreshMemory: Bool {
        allowsInitialization && canUseChannel && !disconnected
            && (forgetCompleted || verifiedAbsentNeedsInitialization)
            && !initializationCompleted && initializationCommandID == nil
            && initializationConfirmationToken == nil && !forgetInProgress
            && !initializationInProgress && requestTask == nil && forgetGenerationReference != nil
    }

    var canRetryFreshMemoryInitialization: Bool {
        allowsInitialization && canUseChannel && !disconnected
            && (forgetCompleted || verifiedAbsentNeedsInitialization)
            && !initializationCompleted && initializationCommandID != nil
            && initializationSourceReference != nil && !initializationInProgress && requestTask == nil
    }

    private let enabled: Bool
    private let allowsInitialization: Bool
    let channel: (any PersonalMemoryChannel)?
    private let requestTimeout: Duration
    private let deadlineSleep: @Sendable (Duration) async throws -> Void
    var generation = 0
    var requestTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    var requestToken: UInt64 = 0
    var disconnected = false
    private var loadingMore = false
    var mutationInFlight = false
    private var pendingEdit: PendingEdit?
    var pendingRemember: PersonalMemoryPendingRemember?
    private var forgetGenerationReference: String?

    init(enabled: Bool = false, channel: (any PersonalMemoryChannel)? = nil,
         allowsInitialization: Bool = false,
         requestTimeout: Duration = .seconds(18),
         deadlineSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.enabled = enabled
        self.allowsInitialization = allowsInitialization
        self.channel = channel
        self.requestTimeout = requestTimeout
        self.deadlineSleep = deadlineSleep
        precondition(requestTimeout > .zero, "requestTimeout must be positive")
        if !enabled || channel == nil {
            state = .unavailable
            errorMessage = Self.unavailableMessage
        }
    }

    func open(query newQuery: String = "") {
        if initializationCommandID != nil {
            showInitializationState()
            return
        }
        guard forgetCommandID == nil else {
            showForgetState()
            return
        }
        guard canUseChannel else {
            state = .unavailable
            errorMessage = Self.unavailableMessage
            return
        }
        guard !disconnected else {
            state = .unavailable
            errorMessage = Self.unavailableMessage
            return
        }
        beginQuery(newQuery)
    }

    func reload(query newQuery: String? = nil) {
        if initializationCommandID != nil {
            showInitializationState()
            return
        }
        guard forgetCommandID == nil else {
            showForgetState()
            return
        }
        guard canUseChannel, !disconnected else {
            state = .unavailable
            errorMessage = Self.unavailableMessage
            return
        }
        beginQuery(newQuery ?? query)
    }

    func loadMore() {
        guard forgetCommandID == nil, canUseChannel, !disconnected,
              requestTask == nil, !loadingMore,
              let cursor = nextRecordID else { return }
        startPage(query: query, cursor: cursor, append: true)
    }

    @discardableResult
    func edit(record: LocalMemoryRPCRecord, text: String) -> String? {
        guard forgetCommandID == nil else { return nil }
        guard canUseChannel, !disconnected else {
            state = .unavailable
            errorMessage = Self.unavailableMessage
            return nil
        }
        guard let visible = records.first(where: { $0.recordID == record.recordID }),
              visible.revision == record.revision else {
            setError(Self.staleEdit)
            return nil
        }
        guard requestTask == nil else { return nil }

        let pending: PendingEdit
        if let prior = pendingEdit,
           prior.recordID == visible.recordID, prior.revision == visible.revision, prior.text == text {
            pending = prior
        } else {
            pending = PendingEdit(recordID: visible.recordID, revision: visible.revision,
                                  text: text, commandID: UUID().uuidString)
            pendingEdit = pending
        }
        draftText = text
        mutationReceipt = nil
        let command = LocalMemoryRPCCommand(editRecord: pending.recordID, revision: pending.revision,
                                            text: pending.text, commandID: pending.commandID)
        guard validate(command) else {
            pendingEdit = nil
            draftText = nil
            setError(Self.staleEdit)
            return nil
        }
        let requestGeneration = generation
        state = .loading
        errorMessage = nil
        mutationInFlight = true
        guard let currentChannel = channel else { return nil }
        let token = beginRequestDeadline(kind: .mutation, generation: requestGeneration)
        requestTask = Task { [weak self] in
            guard self?.generation == requestGeneration, !Task.isCancelled else { return }
            do {
                let reply = try await currentChannel.sendMemoryCommand(command)
                guard let self, self.generation == requestGeneration,
                      self.requestToken == token, !Task.isCancelled else { return }
                self.finishRequest(token)
                try PersonalMemoryReplyValidator.mutation(reply, command: command)
                switch reply.status {
                case .completed:
                    self.mutationInFlight = false
                    self.mutationReceipt = MutationReceipt(kind: .edit,
                        recordID: pending.recordID, requestID: pending.commandID)
                    self.pendingEdit = nil
                    self.draftText = nil
                    self.requestTask = nil
                    self.beginQuery(self.query)
                case .conflict, .notFound:
                    self.mutationInFlight = false
                    self.pendingEdit = nil
                    self.draftText = nil
                    self.requestTask = nil
                    self.setError(Self.staleEdit)
                default:
                    self.mutationInFlight = false
                    self.requestTask = nil
                    self.setError(Self.mutationUnknown)
                }
            } catch {
                guard let self, self.generation == requestGeneration,
                      self.requestToken == token, !Task.isCancelled else { return }
                self.finishRequest(token)
                self.mutationInFlight = false
                self.setError(Self.mutationUnknown)
            }
        }
        return pending.commandID
    }

    @discardableResult
    func delete(record: LocalMemoryRPCRecord) -> String? {
        guard forgetCommandID == nil else { return nil }
        guard canUseChannel, !disconnected else {
            state = .unavailable
            errorMessage = Self.unavailableMessage
            return nil
        }
        guard let visible = records.first(where: { $0.recordID == record.recordID }),
              visible.revision == record.revision else {
            setError(Self.staleEdit)
            return nil
        }
        guard requestTask == nil else { return nil }
        let command = LocalMemoryRPCCommand(deleteMetadata: visible.recordID)
        guard validate(command) else { setError(Self.loadFailure); return nil }
        let receiptRequestID = UUID().uuidString
        mutationReceipt = nil
        let requestGeneration = generation
        state = .loading
        errorMessage = nil
        mutationInFlight = true
        guard let currentChannel = channel else { return nil }
        let token = beginRequestDeadline(kind: .mutation, generation: requestGeneration)
        requestTask = Task { [weak self] in
            guard self?.generation == requestGeneration, !Task.isCancelled else { return }
            do {
                let reply = try await currentChannel.sendMemoryCommand(command)
                guard let self, self.generation == requestGeneration,
                      self.requestToken == token, !Task.isCancelled else { return }
                self.finishRequest(token)
                try PersonalMemoryReplyValidator.mutation(reply, command: command)
                guard reply.status == .completed else {
                    self.mutationInFlight = false
                    self.setError(reply.status == .notFound ? Self.staleEdit : Self.mutationUnknown)
                    return
                }
                self.mutationInFlight = false
                self.mutationReceipt = MutationReceipt(kind: .delete,
                    recordID: visible.recordID, requestID: receiptRequestID)
                self.beginQuery(self.query)
            } catch {
                guard let self, self.generation == requestGeneration,
                      self.requestToken == token, !Task.isCancelled else { return }
                self.finishRequest(token)
                self.mutationInFlight = false
                self.setError(Self.mutationUnknown)
            }
        }
        return receiptRequestID
    }

    func recoverableDraft(for record: LocalMemoryRPCRecord) -> String? {
        guard let pendingEdit,
              pendingEdit.recordID == record.recordID,
              pendingEdit.revision == record.revision,
              records.contains(where: { $0.recordID == record.recordID && $0.revision == record.revision }) else {
            return nil
        }
        return pendingEdit.text
    }

    func close() {
        invalidateAndClear(disconnect: false)
    }

    func disconnect() {
        invalidateAndClear(disconnect: true)
    }

    func beginForgetConfirmation() -> UUID? {
        guard canUseChannel, !disconnected, forgetCommandID == nil,
              generationReference != nil, canConfirmForgetState else { return nil }
        if pendingRemember != nil || rememberCompositionActive {
            if rememberState == .saving, pendingRemember != nil {
                generation &+= 1
                cancelCurrentRequest()
                mutationInFlight = false
            }
            clearRememberState()
        }
        guard requestTask == nil, !mutationInFlight else { return nil }
        let token = UUID()
        forgetConfirmationToken = token
        return token
    }

    func cancelForgetConfirmation(_ token: UUID) {
        guard forgetConfirmationToken == token, !forgetInProgress else { return }
        forgetConfirmationToken = nil
    }
    func beginFreshMemoryConfirmation() -> UUID? {
        guard allowsInitialization, canUseChannel, !disconnected,
              (forgetCompleted || verifiedAbsentNeedsInitialization),
              !initializationCompleted, initializationCommandID == nil,
              !forgetInProgress, !initializationInProgress, requestTask == nil,
              let generationReference = forgetGenerationReference else { return nil }
        let token = UUID()
        initializationSourceReference = generationReference; initializationConfirmationToken = token
        return token
    }
    func cancelFreshMemoryConfirmation(_ token: UUID) {
        guard initializationConfirmationToken == token, !initializationInProgress else { return }
        initializationConfirmationToken = nil; initializationSourceReference = nil
    }
    @discardableResult
    func confirmFreshMemory(_ token: UUID) -> String? {
        guard allowsInitialization, initializationConfirmationToken == token,
              canUseChannel, !disconnected,
              (forgetCompleted || verifiedAbsentNeedsInitialization), !forgetInProgress,
              !initializationInProgress, !initializationCompleted, requestTask == nil,
              let sourceReference = initializationSourceReference,
              sourceReference == forgetGenerationReference else { return nil }
        if verifiedAbsentNeedsInitialization && !forgetCompleted {
            var forgetID = UUID().uuidString.lowercased()
            while forgetID == forgetCommandID { forgetID = UUID().uuidString.lowercased() }
            let command = LocalMemoryRPCCommand(forgetEverything: forgetID,
                                                generationReference: sourceReference)
            guard validate(command) else { return nil }
            initializationConfirmationToken = nil
            forgetCommandID = forgetID
            forgetGenerationReference = sourceReference
            forgetCompleted = false
            clearOwnerContent()
            generation &+= 1
            cancelCurrentRequest()
            errorMessage = nil
            forgetInProgress = true
            state = .loading
            sendForget(commandID: forgetID)
            return forgetID
        }
        var commandID = UUID().uuidString.lowercased()
        while commandID == forgetCommandID { commandID = UUID().uuidString.lowercased() }
        let command = LocalMemoryRPCCommand(initializeMemoryGeneration: commandID,
                                            generationReference: sourceReference)
        guard validate(command) else { return nil }
        initializationConfirmationToken = nil; initializationCommandID = commandID
        initializationSourceReference = sourceReference; replacementGenerationReference = nil
        initializationCompleted = false
        clearOwnerContent()
        generation &+= 1
        cancelCurrentRequest()
        errorMessage = nil; initializationInProgress = true; state = .loading
        sendFreshInitialization(commandID: commandID)
        return commandID
    }
    @discardableResult
    func retryFreshMemoryInitialization() -> String? {
        guard allowsInitialization, canUseChannel, !disconnected,
              (forgetCompleted || verifiedAbsentNeedsInitialization),
              !initializationCompleted, !initializationInProgress, requestTask == nil,
              let commandID = initializationCommandID,
              let sourceReference = initializationSourceReference,
              sourceReference == forgetGenerationReference else { return nil }
        initializationInProgress = true; errorMessage = nil; state = .loading
        sendFreshInitialization(commandID: commandID)
        return commandID
    }
    @discardableResult
    func confirmForget(_ token: UUID) -> String? {
        guard forgetConfirmationToken == token, canUseChannel, !disconnected,
              forgetCommandID == nil, requestTask == nil, !mutationInFlight,
              canConfirmForgetState, let generationReference else { return nil }
        let commandID = UUID().uuidString.lowercased()
        guard validate(LocalMemoryRPCCommand(forgetEverything: commandID,
                                              generationReference: generationReference)) else { return nil }
        forgetConfirmationToken = nil
        forgetCommandID = commandID
        forgetGenerationReference = generationReference
        forgetCompleted = false
        clearOwnerContent()
        generation &+= 1
        errorMessage = nil
        forgetInProgress = true
        state = .loading
        sendForget(commandID: commandID)
        return commandID
    }

    @discardableResult
    func retryForget() -> String? {
        guard canUseChannel, !disconnected, let commandID = forgetCommandID,
              forgetGenerationReference != nil, !forgetInProgress, !forgetCompleted,
              requestTask == nil else { return nil }
        forgetInProgress = true
        errorMessage = nil
        state = .loading
        sendForget(commandID: commandID)
        return commandID
    }
    var canUseChannel: Bool { enabled && channel != nil }

    private var canConfirmForgetState: Bool {
        switch state {
        case .ready, .error: return true
        case .unavailable, .loading: return false
        }
    }
    private func sendFreshInitialization(commandID: String) {
        guard allowsInitialization, canUseChannel, !disconnected,
              let sourceReference = initializationSourceReference,
              sourceReference == forgetGenerationReference, commandID == initializationCommandID,
              let currentChannel = channel else { failFreshInitialization(); return }
        let command = LocalMemoryRPCCommand(initializeMemoryGeneration: commandID,
                                            generationReference: sourceReference)
        guard validate(command) else { failFreshInitialization(); return }
        let requestGeneration = generation
        let token = beginRequestDeadline(kind: .initialize, generation: requestGeneration)
        requestTask = Task { [weak self] in
            guard self?.generation == requestGeneration, !Task.isCancelled else { return }
            do {
                let reply = try await currentChannel.sendMemoryCommand(command)
                guard let self, self.generation == requestGeneration,
                      self.requestToken == token, !Task.isCancelled, !self.disconnected,
                      self.initializationCommandID == commandID,
                      self.initializationSourceReference == sourceReference else { return }
                self.finishRequest(token)
                try PersonalMemoryReplyValidator.initialize(
                    reply, commandID: commandID, sourceReference: sourceReference)
                self.initializationInProgress = false; self.initializationCompleted = true
                self.replacementGenerationReference = reply.replacementGenerationReference
                self.errorMessage = nil; self.state = .unavailable
            } catch {
                guard let self, self.generation == requestGeneration,
                      self.requestToken == token, !Task.isCancelled, !self.disconnected,
                      self.initializationCommandID == commandID else { return }
                self.finishRequest(token)
                self.failFreshInitialization()
            }
        }
    }
    private func failFreshInitialization() {
        initializationInProgress = false; setError(Self.initializationUnknown)
    }

    func beginQuery(_ newQuery: String) {
        guard !mutationInFlight, forgetCommandID == nil else { return }
        if !forgetCompleted && verifiedAbsentNeedsInitialization {
            verifiedAbsentNeedsInitialization = false
            forgetGenerationReference = nil
            generationReference = nil
        }
        generation &+= 1
        cancelCurrentRequest()
        loadingMore = false
        records = []
        nextRecordID = nil
        draftText = nil
        pendingEdit = nil
        query = newQuery
        startPage(query: newQuery, cursor: nil, append: false)
    }

    private func sendForget(commandID: String) {
        guard canUseChannel, !disconnected, let currentChannel = channel else {
            forgetInProgress = false
            setError(Self.forgetUnknown)
            return
        }
        guard let generationReference = forgetGenerationReference else {
            forgetInProgress = false
            setError(Self.forgetUnknown)
            return
        }
        let command = LocalMemoryRPCCommand(forgetEverything: commandID,
                                            generationReference: generationReference)
        guard validate(command), commandID == forgetCommandID else {
            forgetInProgress = false
            setError(Self.forgetUnknown)
            return
        }
        let requestGeneration = generation
        let token = beginRequestDeadline(kind: .forget, generation: requestGeneration)
        requestTask = Task { [weak self] in
            guard self?.generation == requestGeneration, !Task.isCancelled else { return }
            do {
                let reply = try await currentChannel.sendMemoryCommand(command)
                guard let self, self.generation == requestGeneration,
                      self.requestToken == token, !Task.isCancelled,
                      !self.disconnected, self.forgetCommandID == commandID else { return }
                self.finishRequest(token)
                try PersonalMemoryReplyValidator.forget(reply, commandID: commandID,
                                                        generationReference: generationReference)
                self.clearOwnerContent()
                self.forgetInProgress = false
                self.forgetCompleted = true
                if self.verifiedAbsentNeedsInitialization {
                    self.startFreshInitializationAfterVerifiedForget()
                } else {
                    self.state = .unavailable
                    self.errorMessage = nil
                }
            } catch {
                guard let self, self.generation == requestGeneration,
                      self.requestToken == token, !Task.isCancelled,
                      !self.disconnected, self.forgetCommandID == commandID else { return }
                self.finishRequest(token)
                self.forgetInProgress = false
                self.setError(Self.forgetUnknown)
            }
        }
    }

    private func startFreshInitializationAfterVerifiedForget() {
        guard let sourceReference = initializationSourceReference,
              sourceReference == forgetGenerationReference,
              !initializationCompleted, !initializationInProgress else {
            state = .unavailable
            errorMessage = Self.initializationUnknown
            return
        }
        var commandID = UUID().uuidString.lowercased()
        while commandID == forgetCommandID { commandID = UUID().uuidString.lowercased() }
        let command = LocalMemoryRPCCommand(initializeMemoryGeneration: commandID,
                                            generationReference: sourceReference)
        guard validate(command) else {
            state = .unavailable
            errorMessage = Self.initializationUnknown
            return
        }
        initializationCommandID = commandID
        initializationSourceReference = sourceReference
        replacementGenerationReference = nil
        initializationCompleted = false
        clearOwnerContent()
        generation &+= 1
        cancelCurrentRequest()
        errorMessage = nil
        initializationInProgress = true
        state = .loading
        sendFreshInitialization(commandID: commandID)
    }

    private func clearOwnerContent() {
        records = []
        query = ""
        nextRecordID = nil
        draftText = nil
        pendingEdit = nil
        mutationReceipt = nil
        loadingMore = false
        mutationInFlight = false
        clearRememberState()
    }

    private func showForgetState() {
        if forgetInProgress {
            state = .loading
            errorMessage = nil
            return
        }
        state = .unavailable
        errorMessage = forgetCompleted ? nil : Self.forgetUnknown
    }

    private func showInitializationState() {
        if initializationInProgress {
            state = .loading
            errorMessage = nil
        } else {
            state = .unavailable
            errorMessage = initializationCompleted ? nil : Self.initializationUnknown
        }
    }

    private func startPage(query pageQuery: String, cursor: String?, append: Bool) {
        guard canUseChannel, !disconnected, requestTask == nil else { return }
        let command: LocalMemoryRPCCommand
        if pageQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            command = LocalMemoryRPCCommand(listRecords: Self.pageSize, afterRecordID: cursor)
        } else {
            command = LocalMemoryRPCCommand(searchRecords: pageQuery, limit: Self.pageSize,
                                            afterRecordID: cursor)
        }
        guard validate(command) else {
            setError(Self.loadFailure)
            return
        }
        let requestGeneration = generation
        state = .loading
        errorMessage = nil
        loadingMore = append
        guard let currentChannel = channel else {
            loadingMore = false
            state = .unavailable
            errorMessage = Self.unavailableMessage
            return
        }
        let requestKind: RequestKind = !append && generationReference == nil ? .initialRead : .read
        let token = beginRequestDeadline(kind: requestKind, generation: requestGeneration)
        requestTask = Task { [weak self] in
            guard self?.generation == requestGeneration, !Task.isCancelled else { return }
            do {
                let reply = try await currentChannel.sendMemoryCommand(command)
                guard let self, self.generation == requestGeneration,
                      self.requestToken == token, !Task.isCancelled else { return }
                self.finishRequest(token)
                if reply.status == .initializationRequired {
                    guard !append else { throw ValidationFailure.invalid }
                    try PersonalMemoryReplyValidator.verifiedAbsent(reply, command: command)
                    guard !Task.isCancelled else { throw CancellationError() }
                    self.records = []
                    self.nextRecordID = nil
                    self.generationReference = nil
                    self.forgetGenerationReference = nil
                    self.verifiedAbsentNeedsInitialization = true
                    self.loadingMore = false
                    self.startGenerationCapture(afterReadState: .ready,
                                                requestGeneration: requestGeneration)
                    return
                }
                try PersonalMemoryReplyValidator.page(reply, command: command, previousCursor: cursor,
                                                      appendingTo: append ? self.records : [])
                if append {
                    self.records.append(contentsOf: reply.records)
                } else {
                    self.records = reply.records
                }
                self.nextRecordID = reply.nextRecordID
                self.loadingMore = false
                if !self.forgetCompleted && self.verifiedAbsentNeedsInitialization {
                    self.verifiedAbsentNeedsInitialization = false
                    self.forgetGenerationReference = nil
                }
                if !append && self.generationReference == nil {
                    self.startGenerationCapture(afterReadState: .ready,
                                                requestGeneration: requestGeneration)
                } else {
                    self.state = .ready
                    self.errorMessage = nil
                }
            } catch {
                guard let self, self.generation == requestGeneration,
                      self.requestToken == token, !Task.isCancelled else { return }
                self.finishRequest(token)
                self.loadingMore = false
                if !append && self.generationReference == nil {
                    self.startGenerationCapture(afterReadState: .error(Self.loadFailure),
                                                requestGeneration: requestGeneration)
                } else {
                    self.state = .error(Self.loadFailure)
                    self.errorMessage = Self.loadFailure
                }
            }
        }
    }

    /// Bind the UI's explicit Forget confirmation to the store generation only
    /// after the normal first-page path has had a chance to initialize it.
    private func startGenerationCapture(afterReadState readState: State,
                                        requestGeneration: Int) {
        guard canUseChannel, !disconnected, generationReference == nil,
              requestTask == nil, let currentChannel = channel else {
            state = readState
            if generationReference == nil { errorMessage = Self.generationUnavailable }
            return
        }
        let command = LocalMemoryRPCCommand(captureMemoryGeneration: ())
        guard validate(command) else {
            state = readState
            errorMessage = Self.generationUnavailable
            return
        }
        state = .loading
        errorMessage = nil
        let token = beginRequestDeadline(kind: .capture(readState), generation: requestGeneration)
        requestTask = Task { [weak self] in
            guard self?.generation == requestGeneration, !Task.isCancelled else { return }
            do {
                let reply = try await currentChannel.sendMemoryCommand(command)
                guard let self, self.generation == requestGeneration,
                      self.requestToken == token, !Task.isCancelled else { return }
                self.finishRequest(token)
                try reply.validate()
                guard reply.operation == .captureMemoryGeneration, reply.commandID == nil,
                      reply.rememberKind == nil, reply.status == .completed,
                      let reference = reply.generationReference,
                      LocalMemoryRPCCommand.isValidGenerationReference(reference),
                      reply.recordID == nil, reply.idempotentRetry == nil,
                      reply.metadata.isEmpty, reply.records.isEmpty, reply.nextRecordID == nil else {
                    throw ValidationFailure.invalid
                }
                self.generationReference = reference
                if self.verifiedAbsentNeedsInitialization {
                    self.forgetGenerationReference = reference
                }
                self.state = readState
                self.errorMessage = {
                    if case .error(let message) = readState { return message }
                    return nil
                }()
            } catch {
                guard let self, self.generation == requestGeneration,
                      self.requestToken == token, !Task.isCancelled else { return }
                self.finishRequest(token)
                self.state = readState
                if case .error(let message) = readState {
                    self.errorMessage = message
                } else {
                    self.errorMessage = Self.generationUnavailable
                }
            }
        }
    }

    func validate(_ command: LocalMemoryRPCCommand) -> Bool {
        (try? command.validate()) != nil
    }

    private func invalidateAndClear(disconnect shouldDisconnect: Bool) {
        generation &+= 1
        cancelCurrentRequest()
        clearOwnerContent()
        forgetConfirmationToken = nil; initializationConfirmationToken = nil
        if initializationCommandID == nil {
            initializationSourceReference = nil
        }
        forgetInProgress = false; initializationInProgress = false
        if shouldDisconnect { disconnected = true }
        if shouldDisconnect {
            forgetCommandID = nil; forgetCompleted = false; forgetGenerationReference = nil
            initializationCommandID = nil; initializationSourceReference = nil
            replacementGenerationReference = nil; initializationCompleted = false
            verifiedAbsentNeedsInitialization = false
        }
        generationReference = nil
        clearRememberState()
        state = .unavailable
        errorMessage = initializationCommandID != nil && !initializationCompleted
            ? Self.initializationUnknown
            : (forgetCommandID != nil && !forgetCompleted ? Self.forgetUnknown : Self.unavailableMessage)
    }

    private func setError(_ message: String) {
        state = .error(message)
        errorMessage = message
    }

    func beginRequestDeadline(kind: PersonalMemoryRequestKind, generation requestGeneration: Int) -> UInt64 {
        requestToken &+= 1
        let token = requestToken
        let timeout = requestTimeout
        let sleep = deadlineSleep
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            do {
                try await sleep(timeout)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.requestTask != nil,
                  self.generation == requestGeneration, self.requestToken == token else { return }
            self.requestTask?.cancel()
            self.requestTask = nil
            self.deadlineTask = nil
            self.generation &+= 1
            self.loadingMore = false
            if kind == .forget {
                self.forgetInProgress = false
                self.setError(Self.forgetUnknown)
            } else if kind == .initialize {
                self.initializationInProgress = false
                self.setError(Self.initializationUnknown)
            } else if kind == .initialRead {
                self.mutationInFlight = false
                let readFailure = State.error(Self.loadFailure)
                self.state = readFailure
                self.errorMessage = Self.loadFailure
                self.startGenerationCapture(afterReadState: readFailure,
                                            requestGeneration: self.generation)
            } else if kind == .remember {
                self.mutationInFlight = false
                self.rememberState = .unknown
            } else {
                self.mutationInFlight = false
                if case .capture(let readState) = kind {
                    self.state = readState
                    if case .error(let message) = readState {
                        self.errorMessage = message
                    } else {
                        self.errorMessage = Self.generationUnavailable
                    }
                } else {
                    self.setError(kind == .read ? Self.loadFailure : Self.mutationUnknown)
                }
            }
        }
        return token
    }

    func finishRequest(_ token: UInt64) {
        guard requestToken == token else { return }
        deadlineTask?.cancel()
        deadlineTask = nil
        requestTask = nil
    }

    func cancelCurrentRequest() {
        deadlineTask?.cancel()
        deadlineTask = nil
        requestTask?.cancel()
        requestTask = nil
        requestToken &+= 1
    }

    deinit {
        requestTask?.cancel()
        deadlineTask?.cancel()
    }
}

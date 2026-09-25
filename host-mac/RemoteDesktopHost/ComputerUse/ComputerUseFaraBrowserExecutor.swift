import Foundation

/// Fara's native image/action loop inside the app-owned browser. The host
/// manager remains responsible for user control, Resume and terminal delivery.
@MainActor
final class ComputerUseFaraBrowserExecutor: ComputerUseTaskAwareExecuting, ComputerUseVisualApprovalContinuing, ComputerUseTextClarificationContinuing {
    typealias Propose = @MainActor @Sendable (ComputerUseFaraModel.Input) async throws -> ComputerUseFaraModel.Proposal
    typealias ReadPage = @MainActor @Sendable (ComputerUseFaraModel.PageReading) async throws -> String
    enum ToolObservation: Sendable {
        case initial(ComputerUseOwnedBrowser.InitialAgentObservation)
        case page(ComputerUseOwnedBrowser.AgentObservation)
        var taskID: String {
            switch self {
            case .initial(let initial): return initial.taskID
            case .page(let page): return page.approvalPageEvidence.document.taskID
            }
        }
    }
    enum ToolPlan: Sendable {
        case proposal(ComputerUseFaraModel.Proposal)
        case nativeReadCompletion(MCPFirstComputerUseExecutor.NativeReadCompletion)
        case nativeFormSubmission(plan: ComputerUseMCPBrowserStepPlanner.FormSubmission, authorityDigest: String)
        case localFileOperation(ComputerUseMCPBrowserStepPlanner.Plan.LocalFileOperation, rootTaskID: String, sessionIdentity: String)
        case handoff(ComputerUseFaraModel.WorkerDirective)
        case noProposal
    }
    private struct PlannedProposal: Sendable {
        let proposal: ComputerUseFaraModel.Proposal
        let nativeReadCompletion: MCPFirstComputerUseExecutor.NativeReadCompletion?
    }
    private enum PlannedStep: Sendable {
        case proposal(PlannedProposal)
        case nativeFormSubmission(plan: ComputerUseMCPBrowserStepPlanner.FormSubmission, authorityDigest: String)
        case localFileOperation(ComputerUseMCPBrowserStepPlanner.Plan.LocalFileOperation, rootTaskID: String, sessionIdentity: String)
    }
    private struct PendingNativeFormSubmission: Sendable {
        let plan: ComputerUseMCPBrowserStepPlanner.FormSubmission
        let authorityDigest: String
        let observation: ComputerUseOwnedBrowser.AgentObservation
        let operationID: String
        var receipt: ComputerUseBrowserNavigationReceipt?
    }
    private struct PendingLocalFileSelection {
        let candidate: ComputerUseLocalFileCatalog.Candidate
        let triggerControlID: String
        let observation: ComputerUseOwnedBrowser.AgentObservation
        let operationID: String
        let key: String
        var wasSupplied = false
    }
    typealias ProposeUsingTools = @MainActor @Sendable (ComputerUseFaraModel.Input, ToolObservation) async throws -> ToolPlan
    typealias LocalFileCatalogFactory = @MainActor (String) throws -> ComputerUseLocalFileCatalog
    enum Failure: Error, LocalizedError, Equatable {
        case changedTask, recoveredTask, uncertainAction, unsupportedAction, stepLimit, browserChanged, invalidApproval, invalidQuestion, selectedFileStale, selectedFileChangeNeedsConfirmation, fileAlreadySupplied, visualModelUnavailable
        var errorDescription: String? {
            switch self {
            case .changedTask: return "The original request changed. Start a new task with the complete request."
            case .recoveredTask: return "This browser task was interrupted and its live action history is unavailable. Check the page before starting a new request."
            case .uncertainAction: return "The last browser action could not be confirmed. Check what happened before starting another request."
            case .unsupportedAction: return "This browser action is not supported yet. Earlier edits remain on the page."
            case .stepLimit: return "The browser task reached its step limit. Check its progress before starting another request."
            case .browserChanged: return "The task's browser session changed. Check the page before starting another request."
            case .invalidApproval: return "This approval no longer matches the pending browser action."
            case .invalidQuestion: return "This answer no longer matches the browser's pending question. Start a new request with the complete instruction."
            case .selectedFileStale: return "The selected file changed. Ask the user to choose a file again before continuing."
            case .selectedFileChangeNeedsConfirmation: return "A different file was nominated after the user's choice. Ask the user to choose again before changing it."
            case .fileAlreadySupplied: return "This file was already supplied to the current page control. Check the page before trying again."
            case .visualModelUnavailable: return "This browser step needs a compatible visual model that is not set up. The task has not completed."
            }
        }
    }
    private final class PendingApproval {
        let continuation: ComputerUseVisualApprovalContinuation
        let action: ComputerUsePredictedAction
        let message: String
        let proposal: ComputerUseFaraModel.Proposal
        let observation: ComputerUseOwnedBrowser.AgentObservation
        var performed = false
        init(taskID: String, action: ComputerUsePredictedAction, message: String,
             proposal: ComputerUseFaraModel.Proposal, observation: ComputerUseOwnedBrowser.AgentObservation,
             nativeTarget: ComputerUseOwnedBrowser.AgentTarget?) {
            continuation = .init(taskID: taskID, nonce: UUID(), browserPageEvidence: observation.approvalPageEvidence, nativeBrowserTarget: nativeTarget)
            self.action = action; self.message = message; self.proposal = proposal; self.observation = observation
        }
        var result: ComputerUseExecutionResult { .approvalRequired(message: message, action: action, continuation: continuation) }
    }
    private final class Session {
        let taskID: String
        let goal: String
        let browserIdentity: String
        var executionTaskID: String
        var clarifiedGoal: ComputerUseUnresolvedTextGoal?
        var question: ComputerUseNativeTextExecutor.Clarification?
        var answerOriginID: String?
        var userResponse: String?
        var actionError: String?
        var journal: ComputerUseTaskJournal
        var history: [ComputerUseFaraModel.Step] = []
        var pageReading: ComputerUseFaraModel.PageReading?
        var turns = 0
        var staleProposals = 0
        var unsupportedNavigations = 0
        var terminal: ComputerUseExecutionResult?
        var approval: PendingApproval?
        var pendingNativeFormSubmission: PendingNativeFormSubmission?
        var observedNativeGETSubmissions: [ComputerUseObservedNativeGETSubmission] = []
        var observedLocalFileSupplies: [ComputerUseObservedLocalFileSupply] = []
        var localFileCatalog: ComputerUseLocalFileCatalog?
        var localFileContext: ComputerUseMCPBrowserStepPlanner.LocalFileContext?
        var selectedLocalFile: ComputerUseLocalFileCatalog.Candidate?
        var userSelectedLocalFileID: String?
        var pendingFileChoiceCandidates: [String: ComputerUseLocalFileCatalog.Candidate]?
        var selectedFileChoice: ComputerUseClarificationChoice?
        var pendingLocalFileSelection: PendingLocalFileSelection?
        var suppliedLocalFileSelectionKeys = Set<String>()
        var isStarting = false
        init(taskID: String, goal: String, browserIdentity: String, journal: ComputerUseTaskJournal) {
            self.taskID = taskID; self.goal = goal; self.browserIdentity = browserIdentity; self.journal = journal
            executionTaskID = taskID
        }
    }
    private let store: ComputerUseTaskJournalStore
    private let propose: Propose
    private let readPage: ReadPage
    private let proposeUsingTools: ProposeUsingTools?
    private let localFileCatalogFactory: LocalFileCatalogFactory
    private let searchProvider: ComputerUseBrowserSearchProvider
    private let finishRun: @MainActor @Sendable () async -> Void
    private let planning = ComputerUsePlanningWorker.shared
    private var session: Session?
    private var sessionTools: ComputerUseHostTools?
    private let now: @MainActor () -> Date
    private var isExecuting = false
    init(journalDirectory: URL, searchProvider: ComputerUseBrowserSearchProvider? = nil, propose: @escaping Propose,
         proposeUsingTools: ProposeUsingTools? = nil,
         localFileCatalogFactory: @escaping LocalFileCatalogFactory = { taskID in
             let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                 ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
             return try ComputerUseLocalFileCatalog(taskID: taskID, approvedDirectory: downloads, pageSize: 8)
         },
         readPage: @escaping ReadPage = { _ in throw Failure.unsupportedAction },
         finishRun: @escaping @MainActor @Sendable () async -> Void = {}, now: @escaping @MainActor () -> Date = Date.init) throws {
        store = try .init(directory: journalDirectory)
        self.propose = propose
        self.proposeUsingTools = proposeUsingTools
        self.localFileCatalogFactory = localFileCatalogFactory
        self.readPage = readPage
        self.searchProvider = try searchProvider ?? .init(endpoint: URL(string: "https://www.bing.com/search")!, queryParameter: "q", queryFormat: .faraBing)
        self.finishRun = finishRun
        self.now = now
    }
    let isReady = true
    let requiresMacControlHelper = false
    let runtimeName = "Fara browser computer use"
    let readyDetail = "Browser computer use is ready"

    func clarification(taskID: String) throws -> ComputerUseNativeTextExecutor.Clarification? {
        guard let session, session.executionTaskID == taskID, let question = session.question else { return nil }
        guard session.terminal == nil, question.expiresAt > now(),
              sessionTools?.matchesOwnedBrowserAgentSession(taskID: session.taskID, identity: session.browserIdentity) == true else { throw Failure.invalidQuestion }
        return question
    }

    func invalidateClarification(taskID: String?) {
        guard let session, taskID == nil || session.executionTaskID == taskID, session.question != nil else { return }
        session.question = nil
        session.terminal = .unableToComplete(Failure.invalidQuestion.localizedDescription)
    }

    func continueClarification(taskID: String, originatingTaskID: String, goal: ComputerUseUnresolvedTextGoal,
                               progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        try await continueClarification(taskID: taskID, originatingTaskID: originatingTaskID, goal: goal,
            selectedChoice: nil, progress: progress)
    }

    func continueClarification(taskID: String, originatingTaskID: String, goal: ComputerUseUnresolvedTextGoal,
                               selectedChoice: ComputerUseClarificationChoice?,
                               progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        guard !isExecuting else { throw ComputerUseTaskExecutionError.alreadyExecuting }
        try Task.checkCancellation()
        guard let session, let tools = sessionTools, taskID != originatingTaskID else { throw Failure.invalidQuestion }
        if session.executionTaskID == taskID {
            guard session.answerOriginID == originatingTaskID, session.clarifiedGoal == goal,
                  session.selectedFileChoice == selectedChoice else { throw Failure.invalidQuestion }
        } else {
            guard session.executionTaskID == originatingTaskID, let pending = try clarification(taskID: originatingTaskID) else {
                throw Failure.invalidQuestion
            }
            let selectedCandidate: ComputerUseLocalFileCatalog.Candidate?
            let answer: String?
            if let selectedChoice {
                guard pending.choices?.contains(selectedChoice) == true,
                      let candidate = session.pendingFileChoiceCandidates?[selectedChoice.id],
                      candidate.id == selectedChoice.id, goal == pending.goal else { throw Failure.invalidQuestion }
                guard let catalog = session.localFileCatalog else { throw Failure.invalidQuestion }
                do { _ = try catalog.resolve(candidateID: candidate.id, taskID: session.taskID) }
                catch { throw Failure.invalidQuestion }
                selectedCandidate = candidate
                answer = nil
            } else {
                guard let text = goal.userTurns.last, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.utf8.count <= 8_192, try pending.goal.answering(pending.question, with: text) == goal else {
                    throw Failure.invalidQuestion
                }
                selectedCandidate = session.selectedLocalFile
                answer = text
            }
            // Bind the new transport request to the original browser before any
            // suspension. A replay cannot consume a choice twice or reset work.
            try tools.bindOwnedBrowserAgentContinuation(rootTaskID: session.taskID, executionTaskID: taskID,
                previousExecutionTaskID: originatingTaskID, sessionIdentity: session.browserIdentity)
            session.executionTaskID = taskID
            session.answerOriginID = originatingTaskID
            session.clarifiedGoal = goal
            session.observedNativeGETSubmissions.removeAll()
            let goalDigest = ComputerUseTaskContract.digest([goal.taskIdentityText])
            session.observedLocalFileSupplies.removeAll { $0.goalDigest != goalDigest }
            session.userResponse = answer
            session.selectedLocalFile = selectedCandidate
            if selectedChoice != nil { session.userSelectedLocalFileID = selectedCandidate?.id }
            session.selectedFileChoice = selectedChoice
            session.pendingFileChoiceCandidates = nil
            if let localFileContext = session.localFileContext {
                session.localFileContext = .init(query: localFileContext.query, page: localFileContext.page,
                    selectedCandidate: selectedCandidate, inventoryState: localFileContext.inventoryState)
            }
            session.question = nil
        }
        return try await execute(taskID: session.taskID, prompt: session.goal, trustedUserPrompt: session.goal, tools: tools, progress: progress)
    }

    func execute(prompt: String, tools: ComputerUseHostTools, progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        try await execute(taskID: UUID().uuidString, prompt: prompt, trustedUserPrompt: prompt, tools: tools, progress: progress)
    }

    func execute(taskID: String, prompt: String, trustedUserPrompt: String,
                 tools: ComputerUseHostTools, progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        guard !isExecuting else { throw ComputerUseTaskExecutionError.alreadyExecuting }
        isExecuting = true
        defer { isExecuting = false }
        do {
            let result = try await run(taskID: taskID, goal: trustedUserPrompt, tools: tools, progress: progress)
            await finishRun()
            return result
        } catch {
            await finishRun()
            throw error
        }
    }

    func performApprovedVisualAction(_ continuation: ComputerUseVisualApprovalContinuation,
        action: ComputerUsePredictedAction, fingerprint: ComputerUseApprovalFingerprint,
        tools: ComputerUseHostTools, willBeginEffect: () -> Void) async throws {
        guard !isExecuting else { throw ComputerUseTaskExecutionError.alreadyExecuting }
        isExecuting = true
        defer { isExecuting = false }
        guard let session, let pending = session.approval, pending.continuation == continuation,
              pending.action == action, !pending.performed, session.terminal == nil else { throw Failure.invalidApproval }
        let lease = try store.acquireExecution(taskID: session.journal.taskID, expected: session.journal)
        defer { lease.release() }
        do {
            _ = try await dispatch(pending.proposal, observation: pending.observation, session: session, tools: tools,
                nativeTarget: pending.continuation.nativeBrowserTarget,
                approvedFingerprint: fingerprint, willBeginEffect: willBeginEffect, assertRootOwnership: { try lease.assertOwnership() })
            pending.performed = true
        } catch let error as ComputerUseBrowserError {
            switch error {
            case .pageChanged, .windowNotActive, .closed, .ownershipLost, .signInWindowOpen:
                throw ComputerUseHostTools.ToolError.approvalTargetChanged
            default: throw error
            }
        }
    }

    func continueAfterApprovedVisualAction(_ continuation: ComputerUseVisualApprovalContinuation,
        action: ComputerUsePredictedAction, tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        guard !isExecuting else { throw ComputerUseTaskExecutionError.alreadyExecuting }
        try Task.checkCancellation()
        guard let session, let pending = session.approval, pending.continuation == continuation,
              pending.action == action, pending.performed, session.terminal == nil else { throw Failure.invalidApproval }
        // Consume before another suspension; the manager has posted this exact
        // action, so its continuation cannot create a second input or history entry.
        session.approval = nil
        record(pending.proposal, observation: pending.observation, session: session)
        return try await execute(taskID: session.taskID, prompt: session.goal, trustedUserPrompt: session.goal, tools: tools, progress: progress)
    }

    func cancelVisualApprovalContinuation(_ continuation: ComputerUseVisualApprovalContinuation) {
        guard let session, let pending = session.approval, pending.continuation == continuation else { return }
        session.approval = nil
        if pending.performed { session.terminal = .unableToComplete("The approved action ran, but the remaining browser task was interrupted. Check the page before starting another request.") }
    }

    private func record(_ proposal: ComputerUseFaraModel.Proposal, observation: ComputerUseOwnedBrowser.AgentObservation, session: Session) {
        record(proposal, png: observation.png, currentURL: observation.currentURL, session: session)
    }

    private func record(_ proposal: ComputerUseFaraModel.Proposal, png: Data, currentURL: URL?, session: Session) {
        session.turns += 1
        if !session.history.isEmpty {
            session.history[session.history.count - 1].resultObservation = .init(currentURL: currentURL,
                userResponse: session.userResponse, actionError: session.actionError)
        }
        session.history.append(.init(screenshotPNG: png, response: proposal.response, currentURL: currentURL, pageReading: session.pageReading, userResponse: session.userResponse, actionError: session.actionError, action: proposal.action))
        session.pageReading = nil
        session.userResponse = nil
        session.actionError = nil
        while session.history.count > 20 {
            // Keep the bounded clarification pairs after their screenshots age
            // out, so an answer never loses the question that gives it meaning.
            guard let index = session.history.firstIndex(where: {
                if $0.userResponse != nil { return false }
                if case .some(.askUser(_)) = $0.action { return false }
                return true
            }) else { break }
            session.history.remove(at: index)
        }
    }

    /// Tool planning shares the original observation and execution history.
    /// Only an explicit no-proposal result can reach the computer-use model;
    /// cancellation, a changed owner/document, or a failed tool read cannot.
    private nonisolated static func readOnlyToolProposal(_ proposal: ComputerUseFaraModel.Proposal) throws
        -> ComputerUseFaraModel.Proposal {
        switch proposal.action {
        case .visitURL, .webSearch, .readPageQuestion, .remember, .askUser, .reportCompletion, .wait:
            return proposal
        default: throw Failure.unsupportedAction
        }
    }

    private func nextProposal(_ input: ComputerUseFaraModel.Input, observation: ToolObservation,
                              tools: ComputerUseHostTools) async throws -> PlannedStep {
        let toolPlanner = proposeUsingTools, visualPlanner = propose
        let hasToolPlanner = toolPlanner != nil || tools.hasOwnedBrowserToolProposals
        return try await planning.perform(timeout: 45) {
            @MainActor func checkObservation() throws {
                try Task.checkCancellation()
                switch observation {
                case .initial(let initial): try tools.validateOwnedBrowserInitialAgentObservation(initial)
                case .page(let page): try tools.validateOwnedBrowserAgentMemoryObservation(page)
                }
            }
            @MainActor func toolPlan(for candidate: ComputerUseFaraModel.Input) async throws -> ToolPlan {
                try await checkObservation()
                let plan: ToolPlan
                do {
                    if let toolPlanner { plan = try await toolPlanner(candidate, observation) }
                    else { plan = try await tools.proposeUsingOwnedBrowserTools(candidate, observation: observation) }
                } catch ComputerUseBrowserGoalPlanError.invalidResponse {
                    try await checkObservation()
                    throw ComputerUseBrowserGoalPlanError.invalidResponse
                }
                try await checkObservation()
                return plan
            }
            @MainActor func visualProposal(_ visualInput: ComputerUseFaraModel.Input) async throws -> PlannedStep {
                try await checkObservation()
                let proposal = try await visualPlanner(visualInput)
                try await checkObservation()
                guard hasToolPlanner, case .reportCompletion(let candidateText) = proposal.action else {
                    return .proposal(PlannedProposal(proposal: proposal, nativeReadCompletion: nil))
                }
                var reviewInput = input
                reviewInput.browserWorkerDirective = nil
                reviewInput.specialistCompletion = candidateText
                let reviewed = try await toolPlan(for: reviewInput)
                let reviewedProposal: ComputerUseFaraModel.Proposal
                switch reviewed {
                case .proposal(let candidate): reviewedProposal = candidate
                case .nativeReadCompletion(let receipt):
                    // A visual specialist's answer has no native evidence receipt;
                    // retain the existing full-scene validation path.
                    reviewedProposal = receipt.proposal
                case .nativeFormSubmission:
                    // Visual answer review is read-only. A form effect can
                    // only be proposed by the native whole-task planner.
                    throw Failure.unsupportedAction
                case .localFileOperation:
                    throw Failure.unsupportedAction
                default: throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
                }
                return .proposal(PlannedProposal(proposal: try Self.readOnlyToolProposal(reviewedProposal), nativeReadCompletion: nil))
            }
            if hasToolPlanner {
                switch try await toolPlan(for: input) {
                case .proposal(let proposal):
                    // This proposal boundary is read/navigation-only. Real
                    // MCP mutations need their own approved effect receipts.
                    return .proposal(PlannedProposal(proposal: try Self.readOnlyToolProposal(proposal), nativeReadCompletion: nil))
                case .nativeReadCompletion(let receipt):
                    return .proposal(PlannedProposal(proposal: try Self.readOnlyToolProposal(receipt.proposal), nativeReadCompletion: receipt))
                case .nativeFormSubmission(let plan, let authorityDigest):
                    guard case .page = observation else { throw Failure.unsupportedAction }
                    return .nativeFormSubmission(plan: plan, authorityDigest: authorityDigest)
                case .localFileOperation(let operation, let rootTaskID, let sessionIdentity):
                    return .localFileOperation(operation, rootTaskID: rootTaskID, sessionIdentity: sessionIdentity)
                case .handoff(let directive):
                    guard input.surface == .browser else { throw Failure.unsupportedAction }
                    try directive.validate()
                    var specialistInput = input
                    specialistInput.browserWorkerDirective = directive
                    specialistInput.specialistCompletion = nil
                    return try await visualProposal(specialistInput)
                case .noProposal:
                    guard input.browserWorkerDirective == nil else {
                        throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
                    }
                    return try await visualProposal(input)
                }
            }
            try Task.checkCancellation()
            return try await visualProposal(input)
        }
    }

    private func start(_ observation: ComputerUseOwnedBrowser.InitialAgentObservation, session: Session,
        tools: ComputerUseHostTools, progress: @escaping (String) -> Void) async throws {
        guard session.turns < 64 else { throw Failure.stepLimit }
        guard session.browserIdentity == observation.sessionIdentity else { throw Failure.browserChanged }
        let lease = try store.acquireExecution(taskID: session.journal.taskID, expected: session.journal)
        defer { lease.release() }
        try lease.assertOwnership()
        progress("Reading the browser…")
        let input = ComputerUseFaraModel.Input(goal: session.goal, screenshotPNG: observation.png, history: session.history,
            userResponse: session.userResponse, actionError: session.actionError, clarifiedGoal: session.clarifiedGoal,
            observedLocalFileSupplies: session.observedLocalFileSupplies,
            localFileCatalog: modelFileContext(for: session))
        let planned = try await nextProposal(input, observation: .initial(observation), tools: tools)
        try Task.checkCancellation(); try lease.assertOwnership()
        if case .localFileOperation(let operation, let rootTaskID, let sessionIdentity) = planned {
            try applyLocalFileOperation(operation, rootTaskID: rootTaskID, sessionIdentity: sessionIdentity,
                observation: .initial(observation), session: session, tools: tools)
            return
        }
        guard case .proposal(let proposalPlan) = planned else { throw Failure.unsupportedAction }
        if proposalPlan.nativeReadCompletion != nil { throw Failure.unsupportedAction }
        let proposal = proposalPlan.proposal
        try Task.checkCancellation(); try lease.assertOwnership()
        try tools.validateOwnedBrowserInitialAgentObservation(observation)
        let destination: URL
        switch proposal.action {
        case .askUser(let question):
            try retainQuestion(question, proposal: proposal, png: observation.png, currentURL: nil, session: session, tools: tools)
            return
        case .unsupportedNavigation:
            record(proposal, png: observation.png, currentURL: nil, session: session)
            try reportUnsupportedNavigation(session: session)
            return
        case .visitURL(let url): destination = url
        case .webSearch(let query): destination = try searchProvider.destination(query: query)
        case .wait(let seconds):
            try await Task.sleep(for: .seconds(seconds))
            record(proposal, png: observation.png, currentURL: nil, session: session)
            return
        case .remember:
            record(proposal, png: observation.png, currentURL: nil, session: session)
            return
        default: throw Failure.unsupportedAction
        }
        let actionID = ComputerUseTaskContract.digest([session.journal.taskID, "native-dispatch", String(session.turns)])
        let dispatchLease = try store.acquireExecution(taskID: actionID, expected: nil)
        defer { dispatchLease.release() }
        let attempted = ComputerUseTaskJournal(taskID: actionID, promptDigest: session.journal.promptDigest,
            contractDigest: ComputerUseTaskContract.digest([observation.authorityDigest, proposal.response]),
            stepIDs: ["native-dispatch-returned"], statuses: [.attempted])
        var began = false
        do {
            try await tools.performOwnedBrowserInitialAgentNavigation(destination, observation: observation, operationID: actionID, willBeginEffect: {
                try lease.assertOwnership(); try dispatchLease.assertOwnership()
                try self.store.save(attempted, replacing: nil)
                began = true
            })
            var dispatched = attempted; dispatched.statuses = [.verified]
            try store.save(dispatched, replacing: attempted)
            record(proposal, png: observation.png, currentURL: nil, session: session)
            session.isStarting = false
        } catch {
            if began {
                var uncertain = attempted; uncertain.statuses = [.uncertain]
                try? store.save(uncertain, replacing: attempted)
                session.terminal = .unableToComplete(Failure.uncertainAction.localizedDescription)
            } else if let rejection = undispatchedURLRejection(error, proposal: proposal) {
                try Task.checkCancellation(); try lease.assertOwnership()
                try tools.validateOwnedBrowserInitialAgentObservation(observation)
                record(proposal, png: observation.png, currentURL: nil, session: session)
                session.actionError = rejection
                return
            }
            throw error
        }
    }

    private func dispatchSelectedLocalFile(candidateID: String, triggerControlID: String,
        rootTaskID: String, sessionIdentity: String, observation: ComputerUseOwnedBrowser.AgentObservation,
        session: Session, tools: ComputerUseHostTools, assertRootOwnership: () throws -> Void) async throws
        -> ComputerUseOwnedBrowser.AgentObservation {
        guard rootTaskID == session.taskID, sessionIdentity == session.browserIdentity,
              observation.approvalPageEvidence.document.taskID == session.taskID,
              observation.sessionIdentity == session.browserIdentity,
              tools.matchesOwnedBrowserAgentSession(taskID: session.taskID, identity: session.browserIdentity),
              let selected = session.selectedLocalFile, selected.id == candidateID,
              let catalog = session.localFileCatalog else { throw Failure.browserChanged }
        // `selected` is host-retained and may come from an earlier catalog page.
        // Resolve by exact scoped ID again without requiring it on the current page.
        let candidate = selected
        do { _ = try catalog.resolve(candidateID: candidateID, taskID: session.taskID) }
        catch { throw Failure.selectedFileStale }
        // This idle-only memory check must precede native input, which marks the
        // browser agent operation busy. The native click path revalidates its target.
        try Task.checkCancellation(); try assertRootOwnership()
        try tools.validateOwnedBrowserAgentMemoryObservation(observation)
        let key = Self.localFileSelectionKey(candidateID: candidateID, triggerControlID: triggerControlID, observation: observation)
        guard !session.suppliedLocalFileSelectionKeys.contains(key), session.pendingLocalFileSelection == nil else {
            throw Failure.fileAlreadySupplied
        }
        let operationID = ComputerUseTaskContract.digest([session.journal.taskID, "native-local-file-selection-v1", key])
        let dispatchLease = try store.acquireExecution(taskID: operationID, expected: nil)
        defer { dispatchLease.release() }
        let attempted = ComputerUseTaskJournal(taskID: operationID, promptDigest: session.journal.promptDigest,
            contractDigest: ComputerUseTaskContract.digest([observation.authorityDigest, candidateID, triggerControlID]),
            stepIDs: ["local-file-supply-returned"], statuses: [.attempted])
        session.pendingLocalFileSelection = .init(candidate: candidate, triggerControlID: triggerControlID,
            observation: observation, operationID: operationID, key: key)
        var began = false
        do {
            try await tools.selectOwnedBrowserLocalFile(taskID: session.taskID, triggerControlID: triggerControlID,
                observation: observation, operationID: operationID, resolve: {
                    try catalog.resolve(candidateID: candidateID, taskID: session.taskID)
                }, willBeginEffect: {
                    try Task.checkCancellation(); try assertRootOwnership(); try dispatchLease.assertOwnership()
                    guard tools.matchesOwnedBrowserAgentSession(taskID: session.taskID, identity: session.browserIdentity) else {
                        throw Failure.browserChanged
                    }
                    try self.store.save(attempted, replacing: nil)
                    began = true
                })
            guard began else { throw Failure.browserChanged }
            // The API return means the native picker callback accepted the file. Retain this
            // before any cancellation/lease check or fresh-capture suspension so Resume
            // reports it without replaying the one-use chooser.
            session.pendingLocalFileSelection?.wasSupplied = true
            session.suppliedLocalFileSelectionKeys.insert(key)
            try Task.checkCancellation(); try assertRootOwnership()
            var verified = attempted; verified.statuses = [.verified]
            try store.save(verified, replacing: attempted)
            let fresh = try await tools.captureOwnedBrowserAgentObservation(taskID: session.taskID, preserving: observation)
            try Task.checkCancellation(); try assertRootOwnership()
            guard fresh.sessionIdentity == session.browserIdentity,
                  tools.matchesOwnedBrowserAgentSession(taskID: session.taskID, identity: session.browserIdentity) else {
                throw Failure.browserChanged
            }
            try finalizeSuppliedLocalFileSelection(session: session, freshObservation: fresh)
            return fresh
        } catch {
            if !began {
                session.pendingLocalFileSelection = nil
            } else if session.pendingLocalFileSelection?.wasSupplied != true {
                var uncertain = attempted; uncertain.statuses = [.uncertain]
                try? store.save(uncertain, replacing: attempted)
                session.terminal = .unableToComplete(Failure.uncertainAction.localizedDescription)
            }
            throw error
        }
    }

    private static func localFileSelectionKey(candidateID: String, triggerControlID: String,
        observation: ComputerUseOwnedBrowser.AgentObservation) -> String {
        let evidence = observation.approvalPageEvidence
        let document = evidence.document
        return ComputerUseTaskContract.digest([document.taskID, observation.sessionIdentity,
            document.contextID, document.generation.description, document.operationID, document.committedURL.absoluteString,
            evidence.documentID, candidateID, triggerControlID])
    }

    /// A returned chooser callback is retained until fresh capture succeeds.
    /// It records only file supply to the page, never remote upload success.
    private func finalizeSuppliedLocalFileSelection(session: Session,
        freshObservation: ComputerUseOwnedBrowser.AgentObservation) throws {
        guard let pending = session.pendingLocalFileSelection, pending.wasSupplied else { return }
        guard freshObservation.approvalPageEvidence.document.taskID == session.taskID,
              freshObservation.sessionIdentity == session.browserIdentity,
              freshObservation.approvalPageEvidence.document.contextID == pending.observation.approvalPageEvidence.document.contextID else {
            throw Failure.browserChanged
        }
        if !session.observedLocalFileSupplies.contains(where: { $0.operationKey == pending.key }) {
            let goal = try session.clarifiedGoal ?? ComputerUseUnresolvedTextGoal(userRequest: session.goal)
            session.observedLocalFileSupplies.append(.init(taskID: session.taskID,
                goalDigest: ComputerUseTaskContract.digest([goal.taskIdentityText]),
                sessionIdentity: session.browserIdentity,
                document: pending.observation.approvalPageEvidence.document,
                pageEvidenceID: pending.observation.approvalPageEvidence.page.id,
                candidateID: pending.candidate.id, displayName: pending.candidate.displayName,
                fileExtension: pending.candidate.fileExtension, byteCount: pending.candidate.byteCount,
                triggerControlID: pending.triggerControlID, operationKey: pending.key))
        }
        let responseObject: [String: Any] = [
            "name": "selectLocalFile",
            "arguments": ["candidateID": pending.candidate.id, "triggerControlID": pending.triggerControlID],
            "result": ["status": "fileSuppliedToPage"]
        ]
        let responseData = try JSONSerialization.data(withJSONObject: responseObject,
            options: [.sortedKeys, .withoutEscapingSlashes])
        let response = String(decoding: responseData, as: UTF8.self)
        if !session.history.isEmpty {
            session.history[session.history.count - 1].resultObservation = .init(currentURL: freshObservation.currentURL,
                userResponse: session.userResponse, actionError: session.actionError)
        }
        session.history.append(.init(screenshotPNG: pending.observation.png, response: response,
            currentURL: pending.observation.currentURL, userResponse: session.userResponse, actionError: session.actionError,
            resultObservation: .init(currentURL: freshObservation.currentURL, userResponse: nil, actionError: nil)))
        session.pendingLocalFileSelection = nil
        session.pageReading = nil
        session.userResponse = nil
        session.actionError = nil
        session.turns += 1
        while session.history.count > 20 {
            guard let index = session.history.firstIndex(where: {
                if $0.userResponse != nil { return false }
                if case .some(.askUser(_)) = $0.action { return false }
                return true
            }) else { break }
            session.history.remove(at: index)
        }
    }

    private func modelFileContext(for session: Session) -> ComputerUseMCPBrowserStepPlanner.LocalFileContext {
        if let context = session.localFileContext { return context }
        return .init(query: .init(), page: .init(candidates: [], isComplete: false, nextCursor: nil,
            hasTiedSortValues: false, hasMissingSortValues: false), inventoryState: .notQueried)
    }

    private func applyLocalFileOperation(_ operation: ComputerUseMCPBrowserStepPlanner.Plan.LocalFileOperation,
        rootTaskID: String, sessionIdentity: String, observation: ToolObservation,
        session: Session, tools: ComputerUseHostTools) throws {
        guard rootTaskID == session.taskID, sessionIdentity == session.browserIdentity,
              observation.taskID == session.taskID,
              tools.matchesOwnedBrowserAgentSession(taskID: session.taskID, identity: session.browserIdentity) else {
            throw Failure.browserChanged
        }
        try Task.checkCancellation()
        try validateUserSelectedFileIfNeeded(session: session)
        let png: Data
        let currentURL: URL?
        switch observation {
        case .initial(let initial): png = initial.png; currentURL = nil
        case .page(let page): png = page.png; currentURL = page.currentURL
        }
        switch operation {
        case .listFiles(let query, let cursor):
            var catalog = try session.localFileCatalog ?? localFileCatalogFactory(session.taskID)
            let page: ComputerUseLocalFileCatalog.Page
            if let cursor {
                guard let current = session.localFileContext, current.query == query,
                      current.page.nextCursor == cursor else { throw Failure.invalidQuestion }
                page = try catalog.nextPage(after: cursor)
            } else {
                guard session.userSelectedLocalFileID == nil else { throw Failure.selectedFileChangeNeedsConfirmation }
                page = try catalog.discover(query: query)
                session.selectedLocalFile = nil
                session.pendingFileChoiceCandidates = nil
            }
            guard page.candidates.count <= 8 else { throw ComputerUseMCPBrowserStepPlanner.Failure.contextLimit }
            session.localFileCatalog = catalog
            session.localFileContext = .init(query: query, page: page,
                selectedCandidate: cursor == nil ? nil : session.selectedLocalFile, inventoryState: .available)
            consumeLocalFileOperation(session: session, observation: observation)
        case .selectFile(let candidateID):
            let candidate = try resolveCurrentCandidate(candidateID, session: session)
            if let userSelectedID = session.userSelectedLocalFileID, candidateID != userSelectedID {
                throw Failure.selectedFileChangeNeedsConfirmation
            }
            session.selectedLocalFile = candidate
            if let context = session.localFileContext {
                session.localFileContext = .init(query: context.query, page: context.page, selectedCandidate: candidate,
                    inventoryState: context.inventoryState)
            }
            consumeLocalFileOperation(session: session, observation: observation)
        case .selectLocalFile(_, _):
            // Upload dispatch is a separate effect path. Catalog nomination
            // alone never authorizes a native picker action.
            throw Failure.unsupportedAction
        case .askFile(let question, let candidateIDs):
            guard let context = session.localFileContext, (2...8).contains(candidateIDs.count),
                  Set(candidateIDs).count == candidateIDs.count,
                  !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  question.utf8.count <= 512 else { throw Failure.invalidQuestion }
            var candidates: [String: ComputerUseLocalFileCatalog.Candidate] = [:]
            var choices: [ComputerUseClarificationChoice] = []
            for id in candidateIDs {
                guard let candidate = context.page.candidates.first(where: { $0.id == id }) else { throw Failure.invalidQuestion }
                candidates[id] = candidate
                var detail = "\(String(candidate.fileExtension.uppercased().prefix(64))) · \(candidate.byteCount) bytes"
                let timestamp = ISO8601DateFormatter()
                if let modifiedAt = candidate.modifiedAt {
                    detail += " · Modified \(timestamp.string(from: modifiedAt))"
                }
                if let createdAt = candidate.createdAt {
                    detail += " · Created \(timestamp.string(from: createdAt))"
                }
                choices.append(try ComputerUseClarificationChoice(id: candidate.id, label: candidate.displayName, detail: detail))
            }
            let proposal = ComputerUseFaraModel.Proposal(response: "The host is asking the user to choose a file.",
                action: .askUser(question))
            try retainQuestion(question, proposal: proposal, png: png, currentURL: currentURL,
                choices: choices, fileCandidates: candidates, session: session, tools: tools)
        }
    }

    /// Keep a human-selected file bound across subsequent model operations.
    /// A stale identity fails closed and requires a fresh user choice.
    private func validateUserSelectedFileIfNeeded(session: Session) throws {
        guard let selectedID = session.userSelectedLocalFileID else { return }
        guard let candidate = session.selectedLocalFile, candidate.id == selectedID,
              let catalog = session.localFileCatalog else { throw Failure.selectedFileStale }
        do { _ = try catalog.resolve(candidateID: selectedID, taskID: session.taskID) }
        catch { throw Failure.selectedFileStale }
    }

    private func resolveCurrentCandidate(_ candidateID: String, session: Session) throws
        -> ComputerUseLocalFileCatalog.Candidate {
        guard let catalog = session.localFileCatalog, let context = session.localFileContext,
              let candidate = context.page.candidates.first(where: { $0.id == candidateID }) else {
            throw Failure.invalidQuestion
        }
        do { _ = try catalog.resolve(candidateID: candidateID, taskID: session.taskID) }
        catch { throw Failure.invalidQuestion }
        return candidate
    }

    private func consumeLocalFileOperation(session: Session, observation: ToolObservation) {
        if let index = session.history.indices.last {
            let currentURL: URL?
            switch observation {
            case .initial: currentURL = nil
            case .page(let page): currentURL = page.currentURL
            }
            session.history[index].resultObservation = .init(currentURL: currentURL,
                userResponse: session.userResponse, actionError: session.actionError)
        }
        session.userResponse = nil
        session.actionError = nil
        session.pageReading = nil
        session.turns += 1
    }

    private func reportUnsupportedNavigation(session: Session) throws {
        // Keep this budget cumulative across Resume and otherwise successful
        // actions. A model repeatedly choosing unavailable navigation must not
        // spend the full action budget retrying or silently change the URL.
        session.unsupportedNavigations += 1
        guard session.unsupportedNavigations <= 3 else {
            session.terminal = .unableToComplete(Failure.stepLimit.localizedDescription)
            throw Failure.stepLimit
        }
        session.actionError = "visit_url failed: this browser supports only HTTP and HTTPS URLs. No URL was opened. To read information on the current page, use read_page_answer_question."
    }

    private func undispatchedURLRejection(_ error: Error, proposal: ComputerUseFaraModel.Proposal) -> String? {
        guard error as? ComputerUseBrowserError == .sourceNotAllowed,
              case .visitURL(let url) = proposal.action else { return nil }
        // Match Fara's visit_url failure observation without exposing raw
        // exceptions or treating web_search/uncertain input as recoverable.
        return "visit_url to \(url.absoluteString) failed: BrowserSourcePolicy: The destination is not permitted for this task."
    }

    private func dispatch(_ proposal: ComputerUseFaraModel.Proposal, observation: ComputerUseOwnedBrowser.AgentObservation,
        session: Session, tools: ComputerUseHostTools, nativeTarget: ComputerUseOwnedBrowser.AgentTarget? = nil,
        approvedFingerprint: ComputerUseApprovalFingerprint? = nil,
        willBeginEffect: () -> Void = {}, assertRootOwnership: () throws -> Void) async throws -> (message: String, observation: ComputerUseOwnedBrowser.AgentObservation)? {
        let actionID = ComputerUseTaskContract.digest([session.journal.taskID, "native-dispatch", String(session.turns)])
        let dispatchLease = try store.acquireExecution(taskID: actionID, expected: nil)
        defer { dispatchLease.release() }
        let attempted = ComputerUseTaskJournal(taskID: actionID, promptDigest: session.journal.promptDigest,
            contractDigest: ComputerUseTaskContract.digest([observation.authorityDigest, proposal.response]),
            stepIDs: ["native-dispatch-returned"], statuses: [.attempted])
        let action: ComputerUseFaraAction
        if case .webSearch(let query) = proposal.action { action = .visitURL(try searchProvider.destination(query: query)) }
        else { action = proposal.action }
        var began = false
        do {
            try await tools.performOwnedBrowserAgentInput(action, observation: observation, operationID: actionID, target: nativeTarget, willBeginEffect: {
                try assertRootOwnership(); try dispatchLease.assertOwnership()
                if let predicted = try tools.predictedOwnedBrowserAgentAction(action, observation: observation) {
                    if let approvedFingerprint { try tools.validateApprovedFingerprint(for: predicted, fingerprint: approvedFingerprint, nativeTarget: nativeTarget) }
                    else if tools.approvalReason(for: predicted, nativeTarget: nativeTarget) != nil { throw Failure.invalidApproval }
                } else if approvedFingerprint != nil { throw Failure.invalidApproval }
                try self.store.save(attempted, replacing: nil)
                began = true
                willBeginEffect()
            })
            var dispatched = attempted; dispatched.statuses = [.verified]
            try store.save(dispatched, replacing: attempted)
            return nil
        } catch {
            if began {
                var uncertain = attempted; uncertain.statuses = [.uncertain]
                try? store.save(uncertain, replacing: attempted)
                session.terminal = .unableToComplete(Failure.uncertainAction.localizedDescription)
                if approvedFingerprint != nil { throw ComputerUseHostTools.ToolError.approvedActionEffectMayHaveOccurred }
            } else if approvedFingerprint == nil, let rejection = undispatchedURLRejection(error, proposal: proposal) {
                try Task.checkCancellation(); try assertRootOwnership()
                // A rejected input retires its observation. Acquire fresh
                // evidence while retaining task/owner/takeover identity;
                // revoked sources, login, lost focus and cancellation still fail.
                let fresh = try await tools.captureOwnedBrowserAgentObservation(taskID: session.taskID, preserving: observation)
                try Task.checkCancellation(); try assertRootOwnership()
                return (rejection, fresh)
            }
            throw error
        }
    }

    private func run(taskID: String, goal: String, tools: ComputerUseHostTools,
                     progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        try Task.checkCancellation()
        if let session, session.taskID == taskID {
            guard session.goal.utf8.elementsEqual(goal.utf8) else { throw Failure.changedTask }
            if let terminal = session.terminal { return terminal }
            if let pending = try clarification(taskID: session.executionTaskID) { return .clarificationRequired(pending.question) }
            if let pending = session.approval {
                guard !pending.performed else { throw Failure.invalidApproval }
                return pending.result
            }
        } else {
            session = nil
        }
        sessionTools = tools
        if let result = try await tools.executeOwnedBrowserTaskIfSupported(taskID: taskID, prompt: goal, progress: progress) {
            return result
        }
        let rootID = ComputerUseTaskContract.digest(["fara-browser-session-v1", taskID])
        if session == nil, try store.load(taskID: rootID) != nil { throw Failure.recoveredTask }
        while session == nil || session?.isStarting == true {
            guard let initial = try await tools.captureOwnedBrowserInitialAgentObservation(taskID: taskID,
                expectedSessionIdentity: session?.browserIdentity) else {
                session?.isStarting = false
                break
            }
            if session == nil {
                let journal = ComputerUseTaskJournal(taskID: rootID, promptDigest: ComputerUseTextTaskContract.digest(goal),
                    contractDigest: ComputerUseTaskContract.digest([rootID, initial.sessionIdentity, goal]),
                    stepIDs: ["model-assessed-completion"], statuses: [.attempted])
                try store.save(journal, replacing: nil)
                session = Session(taskID: taskID, goal: goal, browserIdentity: initial.sessionIdentity, journal: journal)
                session?.isStarting = true
            }
            guard let session else { throw Failure.browserChanged }
            try await start(initial, session: session, tools: tools, progress: progress)
            if let pending = try clarification(taskID: session.executionTaskID) { return .clarificationRequired(pending.question) }
        }
        let first: ComputerUseOwnedBrowser.AgentObservation
        do { first = try await tools.captureOwnedBrowserAgentObservation(taskID: taskID) }
        catch ComputerUseBrowserError.authenticationRequired {
            return .userInterventionRequired("Finish signing in in the browser, then choose Resume.")
        }
        if session == nil {
            guard try store.load(taskID: rootID) == nil else { throw Failure.recoveredTask }
            let journal = ComputerUseTaskJournal(taskID: rootID, promptDigest: ComputerUseTextTaskContract.digest(goal),
                contractDigest: ComputerUseTaskContract.digest([rootID, first.sessionIdentity, goal]),
                stepIDs: ["model-assessed-completion"], statuses: [.attempted])
            try store.save(journal, replacing: nil)
            session = Session(taskID: taskID, goal: goal, browserIdentity: first.sessionIdentity, journal: journal)
        }
        guard let session, session.browserIdentity == first.sessionIdentity else { throw Failure.browserChanged }
        let lease = try store.acquireExecution(taskID: rootID, expected: session.journal)
        defer { lease.release() }
        var observation = first
        try Task.checkCancellation(); try lease.assertOwnership()
        try finalizeSuppliedLocalFileSelection(session: session, freshObservation: first)
        while session.turns < 64 {
            try Task.checkCancellation(); try lease.assertOwnership()
            guard session.browserIdentity == observation.sessionIdentity else { throw Failure.browserChanged }
            progress("Reading the browser…")
            let input = ComputerUseFaraModel.Input(goal: session.goal, screenshotPNG: observation.png,
                history: Array(session.history.suffix(20)), currentURL: observation.currentURL, pageReading: session.pageReading,
                userResponse: session.userResponse, actionError: session.actionError,
                observedPage: ComputerUseFaraModel.observePageText(observation.approvalPageEvidence.page, sourceURL: observation.currentURL),
                clarifiedGoal: session.clarifiedGoal,
                observedNativeGETSubmissions: session.observedNativeGETSubmissions,
                observedLocalFileSupplies: session.observedLocalFileSupplies,
                localFileCatalog: modelFileContext(for: session))
            let plannedStep: PlannedStep
            if let pending = session.pendingNativeFormSubmission {
                plannedStep = .nativeFormSubmission(plan: pending.plan, authorityDigest: pending.authorityDigest)
            } else {
                do {
                    plannedStep = try await nextProposal(input, observation: .page(observation), tools: tools)
                } catch ComputerUseBrowserError.pageChanged {
                // The native planner may finish after its read-only page has
                // changed. No proposal escaped this boundary, so discard it
                // without adding history or feedback and plan from fresh data.
                try Task.checkCancellation(); try lease.assertOwnership()
                session.staleProposals += 1
                guard session.staleProposals <= 3 else {
                    return .userInterventionRequired("I couldn't verify a browser action after several fresh observations. Complete this step in the browser, then choose Resume.")
                }
                do { observation = try await tools.captureOwnedBrowserAgentObservation(taskID: taskID, preserving: observation) }
                catch ComputerUseBrowserError.authenticationRequired {
                    return .userInterventionRequired("Finish signing in in the browser, then choose Resume.")
                }
                try Task.checkCancellation(); try lease.assertOwnership()
                    continue
                }
            }
            if case .localFileOperation(let operation, let rootTaskID, let sessionIdentity) = plannedStep {
                try Task.checkCancellation(); try lease.assertOwnership()
                if case .selectLocalFile(let candidateID, let triggerControlID) = operation {
                    do {
                        observation = try await dispatchSelectedLocalFile(candidateID: candidateID, triggerControlID: triggerControlID,
                            rootTaskID: rootTaskID, sessionIdentity: sessionIdentity, observation: observation, session: session,
                            tools: tools, assertRootOwnership: { try Task.checkCancellation(); try lease.assertOwnership() })
                    } catch Failure.fileAlreadySupplied {
                        let result = ComputerUseExecutionResult.unableToComplete(Failure.fileAlreadySupplied.localizedDescription)
                        session.terminal = result
                        return result
                    }
                    continue
                }
                try applyLocalFileOperation(operation, rootTaskID: rootTaskID, sessionIdentity: sessionIdentity,
                    observation: .page(observation), session: session, tools: tools)
                if let pending = try clarification(taskID: session.executionTaskID) {
                    return .clarificationRequired(pending.question)
                }
                continue
            }
            if case .nativeFormSubmission(let plan, let authorityDigest) = plannedStep {
                var pending: PendingNativeFormSubmission
                if let retained = session.pendingNativeFormSubmission {
                    guard retained.plan == plan, retained.authorityDigest == authorityDigest else { throw Failure.uncertainAction }
                    pending = retained
                } else {
                    guard authorityDigest == observation.authorityDigest else { throw Failure.browserChanged }
                    let operationID = ComputerUseTaskContract.digest([session.journal.taskID, "native-form-submission-v1", authorityDigest])
                    pending = .init(plan: plan, authorityDigest: authorityDigest, observation: observation,
                        operationID: operationID, receipt: nil)
                    session.pendingNativeFormSubmission = pending
                }
                progress("Preparing the observed browser form…")
                let receipt: ComputerUseBrowserNavigationReceipt
                if let retainedReceipt = pending.receipt {
                    receipt = retainedReceipt
                } else {
                    receipt = try await tools.performOwnedBrowserNativeFormSubmission(pending.plan,
                        authorityDigest: pending.authorityDigest, observation: pending.observation,
                        prompt: session.goal, operationID: pending.operationID,
                        checkCurrent: {
                            try Task.checkCancellation(); try lease.assertOwnership()
                            guard tools.matchesOwnedBrowserAgentSession(taskID: taskID, identity: session.browserIdentity) else {
                                throw Failure.browserChanged
                            }
                        }, willBeginEffect: {
                            try Task.checkCancellation(); try lease.assertOwnership()
                            guard tools.matchesOwnedBrowserAgentSession(taskID: taskID, identity: session.browserIdentity) else {
                                throw Failure.browserChanged
                            }
                        })
                    pending.receipt = receipt
                    session.pendingNativeFormSubmission = pending
                }
                guard receipt.document.taskID == taskID else { throw Failure.browserChanged }
                // Keep the pending operation until the fresh capture succeeds.
                // Resume then receives the cached receipt rather than planning
                // or dispatching this form again.
                observation = try await tools.captureOwnedBrowserAgentObservation(taskID: taskID)
                try Task.checkCancellation(); try lease.assertOwnership()
                guard session.browserIdentity == observation.sessionIdentity,
                      tools.matchesOwnedBrowserAgentSession(taskID: taskID, identity: session.browserIdentity),
                      pending.observation.sessionIdentity == session.browserIdentity,
                      pending.observation.approvalPageEvidence.document.taskID == taskID,
                      pending.observation.approvalPageEvidence.document.contextID == observation.approvalPageEvidence.document.contextID,
                      pending.observation.currentURL == pending.observation.approvalPageEvidence.document.committedURL,
                      receipt.document.taskID == taskID,
                      receipt.document.contextID == observation.approvalPageEvidence.document.contextID,
                      receipt.document.operationID == ComputerUseTaskContract.digest([pending.operationID, "form-navigation"]) else {
                    throw Failure.browserChanged
                }
                if !session.observedNativeGETSubmissions.contains(where: { $0.operationID == pending.operationID }) {
                    let goal = try session.clarifiedGoal ?? ComputerUseUnresolvedTextGoal(userRequest: session.goal)
                    session.observedNativeGETSubmissions.append(.init(taskID: taskID,
                        goalDigest: ComputerUseTaskContract.digest([goal.taskIdentityText]),
                        sessionIdentity: session.browserIdentity, operationID: pending.operationID,
                        submitControlID: pending.plan.submitControlID, edits: pending.plan.edits,
                        sourceURL: pending.observation.currentURL.absoluteString, receipt: receipt,
                        capturedURLAfterSubmission: observation.currentURL.absoluteString))
                }
                session.pendingNativeFormSubmission = nil
                let priorUserResponse = session.userResponse
                let priorActionError = session.actionError
                if !session.history.isEmpty {
                    session.history[session.history.count - 1].resultObservation = .init(
                        currentURL: pending.observation.currentURL,
                        userResponse: priorUserResponse, actionError: priorActionError)
                }
                let operationResult: [String: Any] = [
                    "name": "submitForm",
                    "arguments": ["edits": pending.plan.edits.map { ["controlID": $0.controlID, "text": $0.text] },
                        "submitControlID": pending.plan.submitControlID],
                    "result": ["status": "observedNavigation", "currentURL": receipt.document.committedURL.absoluteString]
                ]
                let operationData = try JSONSerialization.data(withJSONObject: operationResult,
                    options: [.sortedKeys, .withoutEscapingSlashes])
                let operationResponse = String(decoding: operationData, as: UTF8.self)
                session.history.append(.init(screenshotPNG: pending.observation.png, response: operationResponse,
                    currentURL: pending.observation.currentURL, pageReading: session.pageReading,
                    userResponse: priorUserResponse, actionError: priorActionError, action: nil,
                    resultObservation: .init(currentURL: observation.currentURL, userResponse: nil, actionError: nil)))
                session.turns += 1
                session.pageReading = nil; session.userResponse = nil; session.actionError = nil
                while session.history.count > 20 {
                    guard let index = session.history.firstIndex(where: {
                        if $0.userResponse != nil { return false }
                        if case .some(.askUser(_)) = $0.action { return false }
                        return true
                    }) else { break }
                    session.history.remove(at: index)
                }
                continue
            }
            guard case .proposal(let planned) = plannedStep else { throw Failure.unsupportedAction }
            let proposal = planned.proposal
            try Task.checkCancellation(); try lease.assertOwnership()
            // Even a model's final assessment needs the same scene it read.
            // Native dispatch receipts below do not themselves prove the goal.
            var nativeTarget: ComputerUseOwnedBrowser.AgentTarget?
            do {
                switch proposal.action {
                case .wait, .pointer(.leftClick, _), .pointer(.doubleClick, _), .typeText, .key, .scroll, .visitURL, .webSearch:
                    // Waiting posts no input. Input reads its exact retained
                    // target below; unrelated content need not stay frozen.
                    // Explicit navigation checks its native document and fresh
                    // authentication gate, without targeting page content.
                    break
                case .remember:
                    try tools.validateOwnedBrowserAgentMemoryObservation(observation)
                case .reportCompletion where planned.nativeReadCompletion != nil:
                    guard let receipt = planned.nativeReadCompletion,
                          receipt.authorityDigest == observation.authorityDigest else {
                        throw ComputerUseBrowserError.pageChanged
                    }
                    // Only the direct native planner can mint this receipt;
                    // it scopes freshness to the selected native records.
                    try await tools.validateOwnedBrowserAgentReadCompletion(observation, references: receipt.references)
                    try Task.checkCancellation(); try lease.assertOwnership()
                case .reportCompletion where session.pageReading == nil && input.observedPage == nil:
                    // The visual-only exception cannot validate an answer
                    // informed by native text or tooltips outside the pixels.
                    try await tools.validateOwnedBrowserAgentObservation(observation, allowingIdenticalScreenshot: true)
                default:
                    try await tools.validateOwnedBrowserAgentObservation(observation)
                }
                switch proposal.action {
                case .pointer(.leftClick, _), .pointer(.doubleClick, _), .typeText, .key, .visitURL, .webSearch, .scroll, .historyBack:
                    nativeTarget = try await tools.inspectOwnedBrowserAgentTarget(proposal.action, observation: observation)
                default: break
                }
            } catch ComputerUseBrowserError.authenticationRequired {
                return .userInterventionRequired("Finish signing in in the browser, then choose Resume.")
            } catch ComputerUseBrowserError.pageChanged {
                // Only read-only preflight is retryable. Preserve the proposal
                // in model conversation history, as upstream Fara does, with
                // its original observation. This creates no dispatch journal.
                let rejectedObservation = observation
                do { observation = try await tools.captureOwnedBrowserAgentObservation(taskID: taskID, preserving: observation) }
                catch ComputerUseBrowserError.authenticationRequired {
                    return .userInterventionRequired("Finish signing in in the browser, then choose Resume.")
                }
                record(proposal, observation: rejectedObservation, session: session)
                session.staleProposals += 1
                // A fresh image alone can be identical after a rejected click
                // on plain text. Pair that proposal with explicit failure
                // feedback, including when control is handed back to the user.
                let description: String
                if case .pointer(let kind, let point) = proposal.action {
                    description = "\(kind.rawValue) at [\(point.x), \(point.y)]"
                } else { description = "The browser proposal" }
                session.actionError = "\(description) was not performed: the observed page or target could not be verified. No input was sent. Inspect the latest screenshot and choose a visible control, scroll, or wait as appropriate."
                guard session.staleProposals <= 3 else {
                    return .userInterventionRequired("I couldn't verify a browser action after several fresh observations. Complete this step in the browser, then choose Resume.")
                }
                continue
            }
            if case .reportCompletion(let answer) = proposal.action {
                var completed = session.journal; completed.statuses = [.verified]
                try store.save(completed, replacing: session.journal)
                session.journal = completed
                let result = ComputerUseExecutionResult.completed(answer)
                session.terminal = result
                return result
            }
            var nextReading: ComputerUseFaraModel.PageReading?
            var rejection: (message: String, observation: ComputerUseOwnedBrowser.AgentObservation)?
            switch proposal.action {
            case .pointer(.leftClick, _), .pointer(.doubleClick, _), .typeText, .key, .visitURL, .webSearch, .scroll, .historyBack:
                if let nativeTarget, nativeTarget.context.isEmpty {
                    return .userInterventionRequired("I couldn't identify that browser control. Complete this step in the browser, then choose Resume.")
                }
                if let predicted = try tools.predictedOwnedBrowserAgentAction(proposal.action, observation: observation),
                   let reason = tools.approvalReason(for: predicted, nativeTarget: nativeTarget) {
                    let pending = PendingApproval(taskID: session.executionTaskID, action: predicted, message: reason, proposal: proposal, observation: observation, nativeTarget: nativeTarget)
                    session.approval = pending
                    return pending.result
                }
                progress("Using the browser…")
                rejection = try await dispatch(proposal, observation: observation, session: session, tools: tools, nativeTarget: nativeTarget,
                    assertRootOwnership: { try lease.assertOwnership() })
            case .wait(let seconds):
                try await Task.sleep(for: .seconds(seconds))
            case .remember, .unsupportedNavigation: break
            case .askUser(let question):
                try retainQuestion(question, proposal: proposal, png: observation.png, currentURL: observation.currentURL, session: session, tools: tools)
                return .clarificationRequired(question)
            case .readPageQuestion(let question):
                guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      question.utf8.count <= 1024 else { throw Failure.unsupportedAction }
                // Preflight above validated the exact native page, source policy,
                // owner and login state. This synchronous projection posts no input.
                let page = ComputerUseFaraModel.observePageText(observation.approvalPageEvidence.page, sourceURL: observation.currentURL)
                var reading = ComputerUseFaraModel.PageReading(sourceURL: page.sourceURL, question: question, text: page.text,
                    truncated: page.truncated, omittedEmbeddedContent: page.omittedEmbeddedContent)
                let source = reading, readPage = self.readPage
                reading.answer = try await planning.perform(timeout: 45) { try await readPage(source) }
                try Task.checkCancellation(); try lease.assertOwnership()
                // Extraction is another asynchronous planning call. Do not
                // publish its result into a changed, revoked or login page.
                do { try await tools.validateOwnedBrowserAgentObservation(observation) }
                catch ComputerUseBrowserError.authenticationRequired {
                    return .userInterventionRequired("Finish signing in in the browser, then choose Resume.")
                }
                nextReading = reading
            default: throw Failure.unsupportedAction
            }
            record(proposal, observation: observation, session: session)
            session.pageReading = nextReading
            if case .unsupportedNavigation = proposal.action { try reportUnsupportedNavigation(session: session) }
            else { session.actionError = rejection?.message }
            if let rejection { observation = rejection.observation; continue }
            do {
                let retainedSession: ComputerUseOwnedBrowser.AgentObservation?
                if case .remember = proposal.action { retainedSession = observation } else { retainedSession = nil }
                observation = try await tools.captureOwnedBrowserAgentObservation(taskID: taskID, preserving: retainedSession)
            }
            catch ComputerUseBrowserError.authenticationRequired {
                return .userInterventionRequired("Finish signing in in the browser, then choose Resume.")
            }
        }
        throw Failure.stepLimit
    }

    private func retainQuestion(_ question: String, proposal: ComputerUseFaraModel.Proposal, png: Data, currentURL: URL?,
                                choices: [ComputerUseClarificationChoice]? = nil,
                                fileCandidates: [String: ComputerUseLocalFileCatalog.Candidate]? = nil,
                                session: Session, tools: ComputerUseHostTools) throws {
        // Publishing the question promises that its accepted answer can reach
        // at least one further proposal under the same cumulative turn budget.
        guard session.turns + 1 < 64 else { throw Failure.stepLimit }
        let goal = try session.clarifiedGoal ?? ComputerUseUnresolvedTextGoal(userRequest: session.goal)
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, question.utf8.count <= 8_192,
              goal.userTurns.count < ComputerUseUnresolvedTextGoal.maximumUserTurns else { throw Failure.invalidQuestion }
        try tools.bindOwnedBrowserAgentContinuation(rootTaskID: session.taskID, executionTaskID: session.executionTaskID,
            previousExecutionTaskID: session.executionTaskID, sessionIdentity: session.browserIdentity)
        let pending = ComputerUseNativeTextExecutor.Clarification(taskID: session.executionTaskID, goal: goal, question: question,
            scope: ComputerUseTaskContract.digest([session.browserIdentity, UUID().uuidString]), expiresAt: now().addingTimeInterval(600),
            choices: choices)
        record(proposal, png: png, currentURL: currentURL, session: session)
        session.clarifiedGoal = goal
        session.question = pending
        session.pendingFileChoiceCandidates = fileCandidates
    }
}

import Foundation

/// Fara's native image/action loop inside the app-owned browser. The host
/// manager remains responsible for user control, Resume and terminal delivery.
@MainActor
final class ComputerUseFaraBrowserExecutor: ComputerUseTaskAwareExecuting, ComputerUseVisualApprovalContinuing, ComputerUseTextClarificationContinuing {
    typealias Propose = @MainActor @Sendable (ComputerUseFaraModel.Input) async throws -> ComputerUseFaraModel.Proposal
    typealias ReadPage = @MainActor @Sendable (ComputerUseFaraModel.PageReading) async throws -> String
    enum Failure: Error, LocalizedError, Equatable {
        case changedTask, recoveredTask, uncertainAction, unsupportedAction, stepLimit, browserChanged, invalidApproval, invalidQuestion
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
        var terminal: ComputerUseExecutionResult?
        var approval: PendingApproval?
        var isStarting = false
        init(taskID: String, goal: String, browserIdentity: String, journal: ComputerUseTaskJournal) {
            self.taskID = taskID; self.goal = goal; self.browserIdentity = browserIdentity; self.journal = journal
            executionTaskID = taskID
        }
    }
    private let store: ComputerUseTaskJournalStore
    private let propose: Propose
    private let readPage: ReadPage
    private let searchProvider: ComputerUseBrowserSearchProvider
    private let finishRun: @MainActor @Sendable () async -> Void
    private let planning = ComputerUsePlanningWorker()
    private var session: Session?
    private var sessionTools: ComputerUseHostTools?
    private let now: @MainActor () -> Date
    private var isExecuting = false
    init(journalDirectory: URL, searchProvider: ComputerUseBrowserSearchProvider? = nil, propose: @escaping Propose,
         readPage: @escaping ReadPage = { _ in throw Failure.unsupportedAction },
         finishRun: @escaping @MainActor @Sendable () async -> Void = {}, now: @escaping @MainActor () -> Date = Date.init) throws {
        store = try .init(directory: journalDirectory)
        self.propose = propose
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
        guard !isExecuting else { throw ComputerUseTaskExecutionError.alreadyExecuting }
        try Task.checkCancellation()
        guard let session, let tools = sessionTools, taskID != originatingTaskID else { throw Failure.invalidQuestion }
        if session.executionTaskID == taskID {
            guard session.answerOriginID == originatingTaskID, session.clarifiedGoal == goal else { throw Failure.invalidQuestion }
        } else {
            guard session.executionTaskID == originatingTaskID, let pending = try clarification(taskID: originatingTaskID),
                  let answer = goal.userTurns.last, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  answer.utf8.count <= 8_192, try pending.goal.answering(pending.question, with: answer) == goal else { throw Failure.invalidQuestion }
            // Bind the new transport request to the original browser before any
            // suspension. A replay cannot consume this answer twice or reset work.
            try tools.bindOwnedBrowserAgentContinuation(rootTaskID: session.taskID, executionTaskID: taskID,
                previousExecutionTaskID: originatingTaskID, sessionIdentity: session.browserIdentity)
            session.executionTaskID = taskID
            session.answerOriginID = originatingTaskID
            session.clarifiedGoal = goal
            session.userResponse = answer
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
        session.history.append(.init(screenshotPNG: png, response: proposal.response, currentURL: currentURL, pageReading: session.pageReading, userResponse: session.userResponse, actionError: session.actionError))
        session.pageReading = nil
        session.userResponse = nil
        session.actionError = nil
        while session.history.count > 20 {
            // Keep the bounded clarification pairs after their screenshots age
            // out, so an answer never loses the question that gives it meaning.
            guard let index = session.history.firstIndex(where: {
                if $0.userResponse != nil { return false }
                if case .some(.askUser(_)) = try? ComputerUseFaraAction.decodeNativeMessage($0.response) { return false }
                return true
            }) else { break }
            session.history.remove(at: index)
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
        let input = ComputerUseFaraModel.Input(goal: session.goal, screenshotPNG: observation.png, history: session.history, userResponse: session.userResponse, actionError: session.actionError)
        let propose = self.propose
        let proposal = try await planning.perform(timeout: 45) { try await propose(input) }
        try Task.checkCancellation(); try lease.assertOwnership()
        try tools.validateOwnedBrowserInitialAgentObservation(observation)
        let destination: URL
        switch proposal.action {
        case .askUser(let question):
            try retainQuestion(question, proposal: proposal, png: observation.png, currentURL: nil, session: session, tools: tools)
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
        while session.turns < 64 {
            try Task.checkCancellation(); try lease.assertOwnership()
            guard session.browserIdentity == observation.sessionIdentity else { throw Failure.browserChanged }
            progress("Reading the browser…")
            let input = ComputerUseFaraModel.Input(goal: session.goal, screenshotPNG: observation.png,
                history: Array(session.history.suffix(20)), currentURL: observation.currentURL, pageReading: session.pageReading, userResponse: session.userResponse, actionError: session.actionError)
            let propose = self.propose
            let proposal = try await planning.perform(timeout: 45) { try await propose(input) }
            try Task.checkCancellation(); try lease.assertOwnership()
            // Even a model's final assessment needs the same scene it read.
            // Native dispatch receipts below do not themselves prove the goal.
            var nativeTarget: ComputerUseOwnedBrowser.AgentTarget?
            do {
                switch proposal.action {
                case .wait, .pointer(.leftClick, _), .typeText, .key:
                    // Waiting posts no input. Input reads its exact retained
                    // target below; unrelated content need not stay frozen.
                    break
                default:
                    try await tools.validateOwnedBrowserAgentObservation(observation)
                }
                switch proposal.action {
                case .pointer(.leftClick, _), .typeText, .key, .visitURL, .webSearch, .scroll, .historyBack:
                    nativeTarget = try await tools.inspectOwnedBrowserAgentTarget(proposal.action, observation: observation)
                default: break
                }
            } catch ComputerUseBrowserError.authenticationRequired {
                return .userInterventionRequired("Finish signing in in the browser, then choose Resume.")
            } catch ComputerUseBrowserError.pageChanged {
                // Only read-only preflight is retryable. Discard this proposal
                // without a history entry or dispatch journal; never replay input.
                do { observation = try await tools.captureOwnedBrowserAgentObservation(taskID: taskID, preserving: observation) }
                catch ComputerUseBrowserError.authenticationRequired {
                    return .userInterventionRequired("Finish signing in in the browser, then choose Resume.")
                }
                session.staleProposals += 1
                guard session.staleProposals <= 3 else {
                    return .userInterventionRequired("The page keeps changing before I can use its controls. Complete this step in the browser, then choose Resume.")
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
            case .pointer(.leftClick, _), .typeText, .key, .visitURL, .webSearch, .scroll, .historyBack:
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
            case .remember: break
            case .askUser(let question):
                try retainQuestion(question, proposal: proposal, png: observation.png, currentURL: observation.currentURL, session: session, tools: tools)
                return .clarificationRequired(question)
            case .readPageQuestion(let question):
                guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      question.utf8.count <= 1024 else { throw Failure.unsupportedAction }
                // Preflight above validated the exact native page, source policy,
                // owner and login state. This synchronous projection posts no input.
                let page = observation.approvalPageEvidence.page
                let fullText = page.texts.map(\.text).joined(separator: "\n")
                var text = "", bytes = 0
                for character in fullText {
                    let part = String(character), size = part.utf8.count
                    guard bytes + size <= 4096 else { break }
                    text += part; bytes += size
                }
                var reading = ComputerUseFaraModel.PageReading(sourceURL: observation.currentURL, question: question, text: text,
                    truncated: page.truncated || text != fullText, omittedEmbeddedContent: page.omittedEmbeddedContent)
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
            session.actionError = rejection?.message
            if let rejection { observation = rejection.observation; continue }
            do { observation = try await tools.captureOwnedBrowserAgentObservation(taskID: taskID) }
            catch ComputerUseBrowserError.authenticationRequired {
                return .userInterventionRequired("Finish signing in in the browser, then choose Resume.")
            }
        }
        throw Failure.stepLimit
    }

    private func retainQuestion(_ question: String, proposal: ComputerUseFaraModel.Proposal, png: Data, currentURL: URL?,
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
            scope: ComputerUseTaskContract.digest([session.browserIdentity, UUID().uuidString]), expiresAt: now().addingTimeInterval(600))
        record(proposal, png: png, currentURL: currentURL, session: session)
        session.clarifiedGoal = goal
        session.question = pending
    }
}

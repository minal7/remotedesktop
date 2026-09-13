import Foundation

/// Fara's native image/action loop inside the app-owned browser. The host
/// manager remains responsible for user control, Resume and terminal delivery.
@MainActor
final class ComputerUseFaraBrowserExecutor: ComputerUseTaskAwareExecuting {
    typealias Propose = @MainActor @Sendable (ComputerUseFaraModel.Input) async throws -> ComputerUseFaraModel.Proposal
    enum Failure: Error, LocalizedError, Equatable {
        case changedTask, recoveredTask, uncertainAction, unsupportedAction, stepLimit, browserChanged
        var errorDescription: String? {
            switch self {
            case .changedTask: return "The original request changed. Start a new task with the complete request."
            case .recoveredTask: return "This browser task was interrupted and its live action history is unavailable. Check the page before starting a new request."
            case .uncertainAction: return "The last browser action could not be confirmed. Check what happened before starting another request."
            case .unsupportedAction: return "This browser action is not supported yet. Earlier edits remain on the page."
            case .stepLimit: return "The browser task reached its step limit. Check its progress before starting another request."
            case .browserChanged: return "The task's browser session changed. Check the page before starting another request."
            }
        }
    }
    private final class Session {
        let taskID: String
        let goal: String
        let browserIdentity: String
        var journal: ComputerUseTaskJournal
        var history: [ComputerUseFaraModel.Step] = []
        var turns = 0
        var terminal: ComputerUseExecutionResult?
        init(taskID: String, goal: String, browserIdentity: String, journal: ComputerUseTaskJournal) {
            self.taskID = taskID; self.goal = goal; self.browserIdentity = browserIdentity; self.journal = journal
        }
    }
    private let store: ComputerUseTaskJournalStore
    private let propose: Propose
    private let searchProvider: ComputerUseBrowserSearchProvider
    private let finishRun: @MainActor @Sendable () async -> Void
    private let planning = ComputerUsePlanningWorker()
    private var session: Session?
    private var isExecuting = false
    init(journalDirectory: URL, searchProvider: ComputerUseBrowserSearchProvider? = nil, propose: @escaping Propose,
         finishRun: @escaping @MainActor @Sendable () async -> Void = {}) throws {
        store = try .init(directory: journalDirectory)
        self.propose = propose
        self.searchProvider = try searchProvider ?? .init(endpoint: URL(string: "https://www.bing.com/search")!, queryParameter: "q")
        self.finishRun = finishRun
    }
    let isReady = true
    let requiresMacControlHelper = false
    let runtimeName = "Fara browser computer use"
    let readyDetail = "Browser computer use is ready"

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

    private func run(taskID: String, goal: String, tools: ComputerUseHostTools,
                     progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        try Task.checkCancellation()
        if let session, session.taskID == taskID {
            guard session.goal.utf8.elementsEqual(goal.utf8) else { throw Failure.changedTask }
            if let terminal = session.terminal { return terminal }
        } else {
            session = nil
        }
        if let result = try await tools.executeOwnedBrowserTaskIfSupported(taskID: taskID, prompt: goal, progress: progress) {
            return result
        }
        let first: ComputerUseOwnedBrowser.AgentObservation
        do { first = try await tools.captureOwnedBrowserAgentObservation(taskID: taskID) }
        catch ComputerUseBrowserError.authenticationRequired {
            return .userInterventionRequired("Finish signing in in the browser, then choose Resume.")
        }
        let rootID = ComputerUseTaskContract.digest(["fara-browser-session-v1", taskID])
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
                history: Array(session.history.suffix(20)), currentURL: observation.currentURL)
            let propose = self.propose
            let proposal = try await planning.perform(timeout: 45) { try await propose(input) }
            try Task.checkCancellation(); try lease.assertOwnership()
            // Even a model's final assessment needs the same scene it read.
            // Native dispatch receipts below do not themselves prove the goal.
            if case .wait = proposal.action {
                // Waiting posts no input. A loading page changing while the
                // model thinks is precisely why it can ask for a fresh view.
            } else {
                try await tools.validateOwnedBrowserAgentObservation(observation)
            }
            if case .reportCompletion(let answer) = proposal.action {
                var completed = session.journal; completed.statuses = [.verified]
                try store.save(completed, replacing: session.journal)
                session.journal = completed
                let result = ComputerUseExecutionResult.completed(answer)
                session.terminal = result
                return result
            }
            switch proposal.action {
            case .pointer(.leftClick, _), .typeText, .key, .visitURL, .webSearch:
                let actionID = ComputerUseTaskContract.digest([rootID, "native-dispatch", String(session.turns)])
                let dispatchLease = try store.acquireExecution(taskID: actionID, expected: nil)
                defer { dispatchLease.release() }
                let attempted = ComputerUseTaskJournal(taskID: actionID, promptDigest: session.journal.promptDigest,
                    contractDigest: ComputerUseTaskContract.digest([observation.authorityDigest, proposal.response]),
                    stepIDs: ["native-dispatch-returned"], statuses: [.attempted])
                let action: ComputerUseFaraAction
                if case .webSearch(let query) = proposal.action {
                    action = .visitURL(try searchProvider.destination(query: query))
                } else { action = proposal.action }
                var began = false
                progress("Using the browser…")
                do {
                    try await tools.performOwnedBrowserAgentInput(action, observation: observation, operationID: actionID, willBeginEffect: {
                        try lease.assertOwnership(); try dispatchLease.assertOwnership()
                        try self.store.save(attempted, replacing: nil)
                        began = true
                    })
                    // Record returned native dispatch before another await.
                    // Never reconstruct an uncertain effect as a new proposal.
                    var dispatched = attempted; dispatched.statuses = [.verified]
                    try store.save(dispatched, replacing: attempted)
                } catch {
                    if began {
                        var uncertain = attempted; uncertain.statuses = [.uncertain]
                        try? store.save(uncertain, replacing: attempted)
                        session.terminal = .unableToComplete(Failure.uncertainAction.localizedDescription)
                    }
                    throw error
                }
            case .wait(let seconds):
                try await Task.sleep(for: .seconds(seconds))
            case .remember: break
            default: throw Failure.unsupportedAction
            }
            session.turns += 1
            session.history.append(.init(screenshotPNG: observation.png, response: proposal.response, currentURL: observation.currentURL))
            if session.history.count > 20 { session.history.removeFirst(session.history.count - 20) }
            do { observation = try await tools.captureOwnedBrowserAgentObservation(taskID: taskID) }
            catch ComputerUseBrowserError.authenticationRequired {
                return .userInterventionRequired("Finish signing in in the browser, then choose Resume.")
            }
        }
        throw Failure.stepLimit
    }
}

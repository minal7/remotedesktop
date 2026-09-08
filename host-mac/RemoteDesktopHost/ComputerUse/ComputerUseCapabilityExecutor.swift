import Foundation

@MainActor
protocol ComputerUseTextClarificationContinuing {
    func clarification(taskID: String) throws -> ComputerUseNativeTextExecutor.Clarification?
    func continueClarification(taskID: String, originatingTaskID: String, goal: ComputerUseUnresolvedTextGoal,
                               progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult
    func invalidateClarification(taskID: String?)
}

/// Routes a whole current-user goal before effects begin. A native attempt
/// may decline with no effects; an error or uncertain edit is never permission
/// to reconstruct and replay the goal through another executor.
@MainActor
final class ComputerUseCapabilityExecutor: ComputerUseTaskAwareExecuting,
    MCPApprovalContinuing, ComputerUseVisualApprovalContinuing, ComputerUseTextClarificationContinuing,
    ComputerUseBrowserResearchContinuing {
    typealias NativeExecution = @MainActor (String, String, @escaping (String) -> Void) async throws -> ComputerUseExecutionResult?
    typealias DesktopFactory = @MainActor (@escaping (String) -> Void) async throws -> any ComputerUseExecuting

    enum RoutingError: Error, Equatable { case taskChanged, missingContinuation, alreadyExecuting }
    private enum Route { case native, research, desktop }
    private struct ResearchState {
        let owner: ComputerUseBrowserResearchTask
        let input: ComputerUseBrowserGoalInput
    }
    private let nativeExecution: NativeExecution
    private let nativeClarification: ComputerUseNativeTextExecutor?
    private let browserResearch: (any ComputerUseBrowserResearchExecuting)?
    private var researchState: ResearchState?
    private var researchAdmissionStarted = false
    private var desktopFactory: DesktopFactory?
    private var desktopIncludesVisualControl: Bool
    private var taskID: String?
    private var promptDigest: String?
    private var route: Route = .native
    private var desktop: (any ComputerUseExecuting)?
    private var isExecuting = false

    init(nativeExecution: @escaping NativeExecution, desktopFactory: DesktopFactory? = nil,
         desktopIncludesVisualControl: Bool = true, nativeClarification: ComputerUseNativeTextExecutor? = nil,
         browserResearch: (any ComputerUseBrowserResearchExecuting)? = nil) {
        self.nativeExecution = nativeExecution
        self.nativeClarification = nativeClarification
        self.browserResearch = browserResearch
        self.desktopFactory = desktopFactory
        self.desktopIncludesVisualControl = desktopFactory != nil && desktopIncludesVisualControl
    }

    convenience init(native: ComputerUseNativeTextExecutor, desktopFactory: DesktopFactory? = nil,
                     browserResearch: (any ComputerUseBrowserResearchExecuting)? = nil) {
        self.init(nativeExecution: { taskID, prompt, progress in
            try await native.execute(taskID: taskID, prompt: prompt, progress: progress)
        }, desktopFactory: desktopFactory, nativeClarification: native, browserResearch: browserResearch)
    }

    let isReady = true
    let requiresMacControlHelper = false
    var hasAdditionalSetup: Bool { desktopFactory == nil || !desktopIncludesVisualControl }
    var readyDetail: String {
        guard desktopFactory != nil else { return "Form editing is ready; desktop tools need setup" }
        return desktopIncludesVisualControl
            ? "Form editing, Mac tools and visual control are ready"
            : "Form editing and Mac tools are ready; visual control needs setup"
    }
    var runtimeName: String { readyDetail }

    /// Package setup affects future tasks. An executor already handling a
    /// paused task retains its contract and continuation identity.
    func setDesktopFactory(includesVisualControl: Bool = true, _ factory: @escaping DesktopFactory) {
        desktopFactory = factory
        desktopIncludesVisualControl = includesVisualControl
    }

    func execute(prompt: String, tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        try await execute(taskID: UUID().uuidString, prompt: prompt,
                          trustedUserPrompt: prompt, tools: tools, progress: progress)
    }

    func execute(taskID: String, prompt: String, trustedUserPrompt: String,
                 tools: ComputerUseHostTools, progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        try await execute(taskID: taskID, modelPrompt: prompt, currentUserPrompt: trustedUserPrompt,
                          conversation: [], tools: tools, progress: progress)
    }

    func execute(taskID: String, modelPrompt: String, currentUserPrompt: String,
                 conversation: [ComputerUseConversationTurn], tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        guard !isExecuting else { throw RoutingError.alreadyExecuting }
        isExecuting = true
        defer { isExecuting = false }
        try Task.checkCancellation()
        let digest = ComputerUseTextTaskContract.digest(currentUserPrompt)
        if self.taskID == taskID {
            guard promptDigest == digest else { throw RoutingError.taskChanged }
        } else {
            researchState?.owner.retire()
            researchState = nil
            researchAdmissionStarted = false
            nativeClarification?.invalidateClarification()
            (desktop as? any MCPApprovalContinuing)?.cancelMCPWork()
            desktop = nil
            self.taskID = taskID
            promptDigest = digest
            route = .native
        }
        if route == .native {
            if let browserResult = try await tools.executeOwnedBrowserTaskIfSupported(
                taskID: taskID, prompt: currentUserPrompt, progress: progress) {
                try Task.checkCancellation()
                try rejectUnroutedResearchQuestion(browserResult)
                return browserResult
            }
            // This receives only the current user request. Conversation and
            // assistant prose cannot supply additional native edit authority.
            let nativeResult = try await nativeExecution(taskID, currentUserPrompt, progress)
            try Task.checkCancellation()
            if let result = nativeResult {
                try rejectUnroutedResearchQuestion(result)
                return result
            }
            try Task.checkCancellation()
            route = browserResearch == nil ? .desktop : .research
        }
        if route == .research {
            // Commit the route before admission can suspend or prepare an
            // owner. An error/cancellation is never a no-effect decline.
            if let result = try await executeResearchRoute(taskID: taskID, prompt: currentUserPrompt,
                tools: tools, progress: progress) { return result }
            route = .desktop
        }
        if desktop == nil {
            guard let desktopFactory else {
                return .unableToComplete("I can edit visible form fields. This request needs desktop tools that are not set up yet.")
            }
            // Native planning may have stopped an older visual process. Build
            // the fallback against a newly activated endpoint for this task.
            let loaded = try await desktopFactory(progress)
            do { try Task.checkCancellation() }
            catch {
                (loaded as? any MCPApprovalContinuing)?.cancelMCPWork()
                throw error
            }
            desktop = loaded
        }
        guard let desktop else { throw RoutingError.missingContinuation }
        let result = try await desktop.execute(taskID: taskID, modelPrompt: modelPrompt,
            currentUserPrompt: currentUserPrompt, conversation: conversation, tools: tools, progress: progress)
        try Task.checkCancellation()
        try rejectUnroutedResearchQuestion(result)
        return result
    }

    private func executeResearchRoute(taskID: String, prompt: String, tools: ComputerUseHostTools,
                                      progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult? {
        guard let browserResearch else { throw RoutingError.missingContinuation }
        let rootID = researchState?.owner.taskID ?? taskID
        do {
            if let owner = try captureResearchOwner(rootID: rootID, prompt: prompt, tools: tools) {
                guard let retained = researchState else { throw RoutingError.missingContinuation }
                try owner.validateDriverContinuation(retained.input)
                let result = try await browserResearch.continueBrowserResearch(taskID: taskID, research: owner,
                    tools: tools, progress: progress)
                try validateResearchResult(result, tools: tools)
                return result
            }
            guard !researchAdmissionStarted else { throw RoutingError.missingContinuation }
            let result = try await tools.withOwnedBrowserResearchAdmission(didPrepare: { [self] owner in
                researchAdmissionStarted = true
                guard try captureResearchOwner(rootID: rootID, prompt: prompt, tools: tools) === owner else {
                    throw RoutingError.taskChanged
                }
            }, operation: {
                try await browserResearch.executeBrowserResearch(taskID: taskID, prompt: prompt,
                    tools: tools, progress: progress)
            })
            let owner = try captureResearchOwner(rootID: rootID, prompt: prompt, tools: tools)
            try Task.checkCancellation()
            guard let result else {
                guard owner == nil, !researchAdmissionStarted else { throw RoutingError.missingContinuation }
                return nil
            }
            guard owner != nil else { throw RoutingError.missingContinuation }
            try validateResearchResult(result, tools: tools)
            return result
        } catch {
            // Preparation may have succeeded before a planner threw or ignored
            // cancellation. Keep that exact owner for Resume; do not re-admit.
            _ = try? captureResearchOwner(rootID: rootID, prompt: prompt, tools: tools)
            throw error
        }
    }

    private func captureResearchOwner(rootID: String, prompt: String,
                                      tools: ComputerUseHostTools) throws -> ComputerUseBrowserResearchTask? {
        guard let actual = tools.ownedBrowserResearch(taskID: rootID) else {
            guard researchState == nil else { throw RoutingError.missingContinuation }
            return nil
        }
        if let retained = researchState {
            guard actual === retained.owner, actual.input == retained.input,
                  actual.executionTaskID == taskID else { throw RoutingError.taskChanged }
        } else {
            guard actual.taskID == taskID, actual.executionTaskID == taskID,
                  actual.input.clarifications.isEmpty, actual.input.prompt.utf8.elementsEqual(prompt.utf8) else {
                throw RoutingError.taskChanged
            }
            researchState = .init(owner: actual, input: actual.input)
        }
        return actual
    }

    func continueBrowserResearch(taskID: String, research: ComputerUseBrowserResearchTask,
        tools: ComputerUseHostTools, progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        guard !isExecuting else { throw RoutingError.alreadyExecuting }
        isExecuting = true
        defer { isExecuting = false }
        try Task.checkCancellation()
        guard route == .research, let browserResearch, let retained = researchState,
              retained.owner === research, tools.ownedBrowserResearch(taskID: research.taskID) === research,
              research.executionTaskID == taskID else { throw RoutingError.missingContinuation }
        let current = research.input
        if current == retained.input {
            guard self.taskID == taskID else { throw RoutingError.taskChanged }
        } else {
            guard self.taskID == (retained.input.clarifications.last?.answerTaskID ?? retained.input.taskID),
                  let answer = current.clarifications.last,
                  (try? retained.input.appending(answer)) == current else { throw RoutingError.taskChanged }
        }
        try research.validateDriverContinuation(current)
        // Advance before awaiting: Resume of an accepted answer uses this same
        // revision and cannot append it again or return to native admission.
        self.taskID = taskID
        researchState = .init(owner: research, input: current)
        let result = try await browserResearch.continueBrowserResearch(taskID: taskID, research: research,
            tools: tools, progress: progress)
        try validateResearchResult(result, tools: tools)
        return result
    }

    private func validateResearchResult(_ result: ComputerUseExecutionResult, tools: ComputerUseHostTools) throws {
        try Task.checkCancellation()
        guard let retained = researchState, tools.ownedBrowserResearch(taskID: retained.owner.taskID) === retained.owner,
              retained.owner.executionTaskID == taskID else { throw RoutingError.missingContinuation }
        try retained.owner.validateDriverContinuation(retained.input)
        switch result {
        case .browserClarificationRequired(let request):
            guard request.taskID == retained.owner.taskID, request.inputDigest == retained.input.digest,
                  let expected = try? retained.owner.proposedQuestionRequest(), expected == request else {
                throw RoutingError.missingContinuation
            }
        case .clarificationRequired, .approvalRequired, .mcpApprovalRequired:
            // This route has typed questions and manual handback. An unrelated
            // native/visual/MCP continuation cannot complete research work.
            throw RoutingError.missingContinuation
        case .completed, .unableToComplete, .userInterventionRequired: break
        }
    }

    private func rejectUnroutedResearchQuestion(_ result: ComputerUseExecutionResult) throws {
        if case .browserClarificationRequired = result { throw RoutingError.missingContinuation }
    }

    func clarification(taskID: String) throws -> ComputerUseNativeTextExecutor.Clarification? {
        guard route == .native, self.taskID == taskID else { return nil }
        return try nativeClarification?.clarification(taskID: taskID)
    }

    func invalidateClarification(taskID: String?) {
        nativeClarification?.invalidateClarification(taskID: taskID)
    }

    func continueClarification(taskID: String, originatingTaskID: String, goal: ComputerUseUnresolvedTextGoal,
                               progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        guard !isExecuting else { throw RoutingError.alreadyExecuting }
        guard route == .native, let native = nativeClarification else { throw RoutingError.missingContinuation }
        let digest = ComputerUseTextTaskContract.digest(goal.taskIdentityText)
        if self.taskID == taskID {
            guard promptDigest == digest else { throw RoutingError.taskChanged }
        } else {
            guard self.taskID == originatingTaskID, let pending = try native.clarification(taskID: originatingTaskID),
                  let answer = goal.userTurns.last,
                  try pending.goal.answering(pending.question, with: answer) == goal else { throw RoutingError.missingContinuation }
            self.taskID = taskID
            promptDigest = digest
        }
        isExecuting = true
        defer { isExecuting = false }
        // A scoped answer never enters navigation, desktop fallback or a
        // general conversation route, including on decline and resume.
        let result = try await native.continueClarification(taskID: taskID, originatingTaskID: originatingTaskID,
            goal: goal, progress: progress)
        try rejectUnroutedResearchQuestion(result)
        return result
    }

    func continueAfterApproval(_ prepared: MCPPreparedApproval, tools: ComputerUseHostTools,
                              progress: @escaping (String) -> Void) async throws -> MCPApprovedActionResult {
        guard !isExecuting else { throw RoutingError.alreadyExecuting }
        isExecuting = true
        defer { isExecuting = false }
        try Task.checkCancellation()
        guard route == .desktop, let continuing = desktop as? any MCPApprovalContinuing else {
            throw RoutingError.missingContinuation
        }
        let result = try await continuing.continueAfterApproval(prepared, tools: tools, progress: progress)
        // A successful approved effect remains a fact after concurrent Stop.
        // The manager records it separately from task cancellation/state.
        return result
    }

    func continueAfterApprovedVisualAction(_ continuation: ComputerUseVisualApprovalContinuation,
        action: ComputerUsePredictedAction, tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        guard !isExecuting else { throw RoutingError.alreadyExecuting }
        isExecuting = true
        defer { isExecuting = false }
        try Task.checkCancellation()
        guard route == .desktop, let continuing = desktop as? any ComputerUseVisualApprovalContinuing else {
            throw RoutingError.missingContinuation
        }
        let result = try await continuing.continueAfterApprovedVisualAction(continuation,
            action: action, tools: tools, progress: progress)
        try Task.checkCancellation()
        try rejectUnroutedResearchQuestion(result)
        return result
    }

    func cancelVisualApprovalContinuation(_ continuation: ComputerUseVisualApprovalContinuation) {
        (desktop as? any ComputerUseVisualApprovalContinuing)?.cancelVisualApprovalContinuation(continuation)
    }

    func cancelMCPWork() {
        (desktop as? any MCPApprovalContinuing)?.cancelMCPWork()
    }
}

/// Defers the expensive visual model until a structured route actually needs
/// it. The same loaded executor handles resume and approval continuation; a
/// continuation never performs another load or enters the planner again.
@MainActor
final class ComputerUseDeferredVisualExecutor: ComputerUseTaskAwareExecuting, ComputerUseVisualApprovalContinuing {
    typealias Loader = @MainActor @Sendable (@escaping (String) -> Void) async throws -> any ComputerUseExecuting
    typealias Abandon = @MainActor @Sendable (any ComputerUseExecuting) async -> Void
    private let loader: Loader?
    private let abandon: Abandon
    private var loaded: (any ComputerUseExecuting)?
    private var taskID: String?
    private var promptDigest: String?
    private var isExecuting = false

    init(loader: Loader? = nil, abandon: @escaping Abandon = { _ in }) {
        self.loader = loader
        self.abandon = abandon
    }

    var isReady: Bool { loader != nil }
    let requiresMacControlHelper = false
    var hasAdditionalSetup: Bool { loader == nil }
    var runtimeName: String { isReady ? "Visual control is available on demand" : "Visual control needs setup" }
    var readyDetail: String { runtimeName }

    func execute(prompt: String, tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        try await execute(taskID: UUID().uuidString, prompt: prompt, trustedUserPrompt: prompt,
                          tools: tools, progress: progress)
    }

    func execute(taskID: String, prompt: String, trustedUserPrompt: String, tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        try await execute(taskID: taskID, modelPrompt: prompt, currentUserPrompt: trustedUserPrompt,
                          conversation: [], tools: tools, progress: progress)
    }

    func execute(taskID: String, modelPrompt: String, currentUserPrompt: String,
                 conversation: [ComputerUseConversationTurn], tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        guard !isExecuting else { throw ComputerUseCapabilityExecutor.RoutingError.alreadyExecuting }
        isExecuting = true
        defer { isExecuting = false }
        try Task.checkCancellation()
        let digest = ComputerUseTextTaskContract.digest(currentUserPrompt)
        if self.taskID == taskID, promptDigest != digest {
            throw ComputerUseCapabilityExecutor.RoutingError.taskChanged
        }
        self.taskID = taskID
        promptDigest = digest
        if loaded == nil {
            guard let loader else {
                return .unableToComplete("This request needs visual control, which is not set up. Return to Devices and choose Check AI setup.")
            }
            let candidate = try await loader(progress)
            do { try Task.checkCancellation() }
            catch { await abandon(candidate); throw error }
            loaded = candidate
        }
        guard let loaded else { throw ComputerUseCapabilityExecutor.RoutingError.missingContinuation }
        let result = try await loaded.execute(taskID: taskID, modelPrompt: modelPrompt,
            currentUserPrompt: currentUserPrompt, conversation: conversation, tools: tools, progress: progress)
        try Task.checkCancellation()
        return result
    }

    func continueAfterApprovedVisualAction(_ continuation: ComputerUseVisualApprovalContinuation,
        action: ComputerUsePredictedAction, tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        guard !isExecuting else { throw ComputerUseCapabilityExecutor.RoutingError.alreadyExecuting }
        guard continuation.taskID == taskID, let visual = loaded as? any ComputerUseVisualApprovalContinuing else {
            throw ComputerUseCapabilityExecutor.RoutingError.missingContinuation
        }
        isExecuting = true
        defer { isExecuting = false }
        try Task.checkCancellation()
        let result = try await visual.continueAfterApprovedVisualAction(continuation, action: action,
            tools: tools, progress: progress)
        try Task.checkCancellation()
        return result
    }

    func cancelVisualApprovalContinuation(_ continuation: ComputerUseVisualApprovalContinuation) {
        guard continuation.taskID == taskID else { return }
        (loaded as? any ComputerUseVisualApprovalContinuing)?.cancelVisualApprovalContinuation(continuation)
    }
}

@MainActor
enum ComputerUseNativeTextExecutorLoader {
    static func load(receipt: ComputerUseInstallationReceipt, tools: ComputerUseHostTools,
                     bundle: Bundle = .main, runtime: OSAtlasLlamaRuntime = .shared,
                     journalDirectory: URL = ComputerUseTextStepStore.defaultDirectory,
                     progress: @escaping (String) -> Void) async throws -> ComputerUseCapabilityExecutor {
        progress("Loading local computer use…")
        let directory = try OSAtlasVisualExecutorLoader.bundledRuntimeDirectoryURL(in: bundle)
        let inputs = try OSAtlasRuntimeInputResolver(manifest: .nativeTextV2).resolveNativeText(
            receipt: receipt, runtimeDirectoryURL: directory, enclosingBundleURL: bundle.bundleURL)
        let providers = try ComputerUseBrowserSourceRequirements.defaultProviders()
        let endpoint = try await runtime.activateNativeText(inputs)
        do { try Task.checkCancellation() }
        catch { await runtime.cancel(endpoint: endpoint); throw error }
        let native = tools.makeNativeTextExecutor(
            planner: ComputerUseRuntimeTextGoalPlanner(inputs: inputs, runtime: runtime),
            journalDirectory: journalDirectory)
        let research = ComputerUseBrowserResearchDriver(
            goalPlanner: ComputerUseRuntimeBrowserGoalPlanner(inputs: inputs, runtime: runtime),
            resultPlanner: ComputerUseReviewedBrowserResultPlanner(
                reader: ComputerUseRuntimeBrowserResultPlanner(inputs: inputs, runtime: runtime),
                reviewer: ComputerUseRuntimeBrowserResultReviewPlanner(inputs: inputs, runtime: runtime)),
            searchPlanner: ComputerUseRuntimeBrowserSearchPlanner(inputs: inputs, runtime: runtime),
            planning: ComputerUseModelBrowserResearchPlanning(providers: providers,
                linkPlanner: ComputerUseRuntimeBrowserLinkPlanner(inputs: inputs, runtime: runtime)))
        return ComputerUseCapabilityExecutor(native: native, browserResearch: research)
    }
}

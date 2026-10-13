import Foundation

/// Starts a routed task with host-validated clarification context. Questions
/// remain context rather than being merged into the current user request.
@MainActor
protocol ComputerUseClarifiedGoalExecuting {
    func execute(taskID: String, goal: ComputerUseUnresolvedTextGoal,
                 tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult
}

@MainActor
protocol ComputerUseTextClarificationContinuing {
    func clarification(taskID: String) throws -> ComputerUseNativeTextExecutor.Clarification?
    func continueClarification(taskID: String, originatingTaskID: String, goal: ComputerUseUnresolvedTextGoal,
                               progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult
    func continueClarification(taskID: String, originatingTaskID: String, goal: ComputerUseUnresolvedTextGoal,
                               selectedChoice: ComputerUseClarificationChoice?,
                               progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult
    func invalidateClarification(taskID: String?)
}

extension ComputerUseTextClarificationContinuing {
    /// Existing continuations still accept ordinary text answers. A typed
    /// catalog selection must be explicitly supported, never silently dropped.
    func continueClarification(taskID: String, originatingTaskID: String, goal: ComputerUseUnresolvedTextGoal,
                               selectedChoice: ComputerUseClarificationChoice?,
                               progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        guard selectedChoice == nil else { throw ComputerUseTextClarificationStore.Failure.invalidChoice }
        return try await continueClarification(taskID: taskID, originatingTaskID: originatingTaskID, goal: goal, progress: progress)
    }
}

/// A native decline is not permission to enter visual execution.
/// The restriction must remain attached to a task across Resume.
@MainActor
protocol ComputerUseNativeOnlyExecuting {
    func executeNativeOnly(taskID: String, modelPrompt: String, currentUserPrompt: String,
        conversation: [ComputerUseConversationTurn], tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult?
}

/// Routes a whole current-user goal before effects begin. A native attempt
/// may decline with no effects; an error or uncertain edit is never permission
/// to reconstruct and replay the goal through another executor.
@MainActor
final class ComputerUseCapabilityExecutor: ComputerUseTaskAwareExecuting,
    MCPApprovalContinuing, ComputerUseVisualApprovalContinuing, ComputerUseTextClarificationContinuing,
    ComputerUseNativeOnlyExecuting, ComputerUseClarifiedGoalExecuting {
    typealias NativeExecution = @MainActor (String, String, @escaping (String) -> Void) async throws -> ComputerUseExecutionResult?
    typealias DesktopFactory = @MainActor (@escaping (String) -> Void) async throws -> any ComputerUseExecuting

    enum RoutingError: Error, Equatable { case taskChanged, missingContinuation, alreadyExecuting }
    private enum Route { case native, desktop }
    private let nativeExecution: NativeExecution
    private let nativeClarification: ComputerUseNativeTextExecutor?
    private var desktopFactory: DesktopFactory?
    private var desktopIncludesVisualControl: Bool
    private var taskID: String?
    private var promptDigest: String?
    private var route: Route = .native
    private var desktop: (any ComputerUseExecuting)?
    private var routedClarifiedGoal: ComputerUseUnresolvedTextGoal?
    private var isExecuting = false
    private var nativeOnlyTask = false
    let agentAdapter: AgentCapabilityAdapter?

    init(nativeExecution: @escaping NativeExecution, desktopFactory: DesktopFactory? = nil,
         desktopIncludesVisualControl: Bool = true, nativeClarification: ComputerUseNativeTextExecutor? = nil) {
        self.nativeExecution = nativeExecution
        self.agentAdapter = nil
        self.nativeClarification = nativeClarification
        self.desktopFactory = desktopFactory
        self.desktopIncludesVisualControl = desktopFactory != nil && desktopIncludesVisualControl
    }

    init(agentAdapter: AgentCapabilityAdapter) {
        self.agentAdapter = agentAdapter
        self.nativeExecution = { _, _, _ in nil }
        self.nativeClarification = nil
        self.desktopFactory = nil
        self.desktopIncludesVisualControl = false
    }

    convenience init(native: ComputerUseNativeTextExecutor, desktopFactory: DesktopFactory? = nil) {
        self.init(nativeExecution: { taskID, prompt, progress in
            try await native.execute(taskID: taskID, prompt: prompt, progress: progress)
        }, desktopFactory: desktopFactory, nativeClarification: native)
    }

    let isReady = true
    let supportsNativeTextTasks = true
    let requiresMacControlHelper = false
    var hasAdditionalSetup: Bool { agentAdapter == nil && (desktopFactory == nil || !desktopIncludesVisualControl) }
    var readyDetail: String {
        if let agentAdapter { return agentAdapter.readyDetail }
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
        guard let result = try await executeResolved(taskID: taskID, modelPrompt: modelPrompt,
            currentUserPrompt: currentUserPrompt, conversation: conversation, tools: tools,
            nativeOnly: false, progress: progress) else {
            return .unableToComplete("The native tools could not finish this task.")
        }
        return result
    }

    /// The structured planner has already selected the desktop route. Preserve
    /// accepted turns as typed context and skip native routing.
    func execute(taskID: String, goal: ComputerUseUnresolvedTextGoal,
        tools: ComputerUseHostTools, progress: @escaping (String) -> Void) async throws
        -> ComputerUseExecutionResult {
        if let agentAdapter {
            return try await agentAdapter.execute(taskID: taskID, prompt: goal.userTurns.joined(separator: "\n"),
                trustedUserPrompt: goal.userTurns[0], tools: tools, progress: progress)
        }
        guard !isExecuting else { throw RoutingError.alreadyExecuting }
        isExecuting = true
        defer { isExecuting = false }
        try Task.checkCancellation()
        guard let originalGoal = goal.userTurns.first,
              !originalGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              originalGoal.utf8.count <= 8_192 else { throw RoutingError.taskChanged }
        let digest = ComputerUseTextTaskContract.digest(goal.taskIdentityText)
        if self.taskID == taskID {
            guard route == .desktop, promptDigest == digest, routedClarifiedGoal == goal else {
                throw RoutingError.taskChanged
            }
        } else {
            nativeClarification?.invalidateClarification()
            (desktop as? any MCPApprovalContinuing)?.cancelMCPWork()
            desktop = nil
            self.taskID = taskID
            promptDigest = digest
            route = .desktop
            nativeOnlyTask = false
            routedClarifiedGoal = goal
        }
        guard let desktopFactory else {
            return .unableToComplete("This accepted task needs desktop tools that are not set up yet.")
        }
        if desktop == nil {
            try Task.checkCancellation()
            let loaded = try await desktopFactory(progress)
            do { try Task.checkCancellation() }
            catch {
                (loaded as? any MCPApprovalContinuing)?.cancelMCPWork()
                throw error
            }
            desktop = loaded
        }
        guard let desktop else { throw RoutingError.missingContinuation }
        guard let clarified = desktop as? any ComputerUseClarifiedGoalExecuting else {
            return .userInterventionRequired("I can't continue this task in the selected app. Start a new task using a supported app.")
        }
        let result = try await clarified.execute(taskID: taskID, goal: goal, tools: tools, progress: progress)
        try Task.checkCancellation()
        return result
    }

    func executeNativeOnly(taskID: String, modelPrompt: String, currentUserPrompt: String,
        conversation: [ComputerUseConversationTurn], tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult? {
        try await executeResolved(taskID: taskID, modelPrompt: modelPrompt,
            currentUserPrompt: currentUserPrompt, conversation: conversation, tools: tools,
            nativeOnly: true, progress: progress)
    }

    private func executeResolved(taskID: String, modelPrompt: String, currentUserPrompt: String,
        conversation: [ComputerUseConversationTurn], tools: ComputerUseHostTools,
        nativeOnly: Bool, progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult? {
        if let agentAdapter {
            return try await agentAdapter.execute(taskID: taskID, prompt: currentUserPrompt,
                trustedUserPrompt: currentUserPrompt, tools: tools, progress: progress)
        }
        guard !isExecuting else { throw RoutingError.alreadyExecuting }
        isExecuting = true
        defer { isExecuting = false }
        try Task.checkCancellation()
        let digest = ComputerUseTextTaskContract.digest(currentUserPrompt)
        if self.taskID == taskID {
            guard promptDigest == digest else { throw RoutingError.taskChanged }
            // A restricted attempt cannot reconstruct a task already owned
            // by another route, or loosen its restriction on ordinary Resume.
            if nativeOnly {
                guard route == .native else { throw RoutingError.missingContinuation }
                nativeOnlyTask = true
            }
        } else {
            nativeClarification?.invalidateClarification()
            (desktop as? any MCPApprovalContinuing)?.cancelMCPWork()
            desktop = nil
            self.taskID = taskID
            promptDigest = digest
            route = .native
            nativeOnlyTask = nativeOnly
            routedClarifiedGoal = nil
        }
        if route == .native {
            // This receives only the current user request. Conversation and
            // assistant prose cannot supply additional native edit authority.
            let nativeResult = try await nativeExecution(taskID, currentUserPrompt, progress)
            try Task.checkCancellation()
            if let result = nativeResult {
                return result
            }
            try Task.checkCancellation()
            if nativeOnlyTask { return nil }
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
        return result
    }

    func clarification(taskID: String) throws -> ComputerUseNativeTextExecutor.Clarification? {
        if let agentAdapter { return try agentAdapter.clarification(taskID: taskID) }
        guard self.taskID == taskID else { return nil }
        if route == .native { return try nativeClarification?.clarification(taskID: taskID) }
        if route == .desktop { return try (desktop as? any ComputerUseTextClarificationContinuing)?.clarification(taskID: taskID) }
        return nil
    }

    func invalidateClarification(taskID: String?) {
        if let agentAdapter { agentAdapter.invalidateClarification(taskID: taskID); return }
        if taskID == nil || taskID == self.taskID { routedClarifiedGoal = nil }
        nativeClarification?.invalidateClarification(taskID: taskID)
        (desktop as? any ComputerUseTextClarificationContinuing)?.invalidateClarification(taskID: taskID)
    }

    func continueClarification(taskID: String, originatingTaskID: String, goal: ComputerUseUnresolvedTextGoal,
                               progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        if let agentAdapter {
            return try await agentAdapter.continueClarification(taskID: taskID, originatingTaskID: originatingTaskID,
                goal: goal, progress: progress)
        }
        guard !isExecuting else { throw RoutingError.alreadyExecuting }
        guard route == .native && nativeClarification != nil || route == .desktop && desktop is any ComputerUseTextClarificationContinuing else { throw RoutingError.missingContinuation }
        let digest = ComputerUseTextTaskContract.digest(goal.taskIdentityText)
        if self.taskID == taskID {
            guard promptDigest == digest else { throw RoutingError.taskChanged }
        } else {
            guard self.taskID == originatingTaskID, let pending = try clarification(taskID: originatingTaskID),
                  let answer = goal.userTurns.last,
                  try pending.goal.answering(pending.question, with: answer) == goal else { throw RoutingError.missingContinuation }
            self.taskID = taskID
            promptDigest = digest
        }
        isExecuting = true
        defer { isExecuting = false }
        // Continue only the retained capability; a scoped answer never repeats
        // native admission or invokes a new desktop/structured planner.
        let result: ComputerUseExecutionResult
        if route == .native, let native = nativeClarification {
            result = try await native.continueClarification(taskID: taskID, originatingTaskID: originatingTaskID, goal: goal, progress: progress)
        } else if let continuing = desktop as? any ComputerUseTextClarificationContinuing {
            result = try await continuing.continueClarification(taskID: taskID, originatingTaskID: originatingTaskID, goal: goal, progress: progress)
        } else { throw RoutingError.missingContinuation }
        if route == .desktop { routedClarifiedGoal = goal }
        return result
    }

    func continueClarification(taskID: String, originatingTaskID: String, goal: ComputerUseUnresolvedTextGoal,
                               selectedChoice: ComputerUseClarificationChoice?,
                               progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        if let agentAdapter {
            return try await agentAdapter.continueClarification(taskID: taskID, originatingTaskID: originatingTaskID,
                goal: goal, selectedChoice: selectedChoice, progress: progress)
        }
        guard let selectedChoice else {
            return try await continueClarification(taskID: taskID, originatingTaskID: originatingTaskID,
                goal: goal, progress: progress)
        }
        guard !isExecuting else { throw RoutingError.alreadyExecuting }
        guard route != .native else { throw ComputerUseTextClarificationStore.Failure.invalidChoice }
        guard route == .desktop,
              let continuing = desktop as? any ComputerUseTextClarificationContinuing else {
            throw RoutingError.missingContinuation
        }
        let digest = ComputerUseTextTaskContract.digest(goal.taskIdentityText)
        if self.taskID == taskID {
            guard promptDigest == digest else { throw RoutingError.taskChanged }
        } else {
            guard self.taskID == originatingTaskID, let pending = try clarification(taskID: originatingTaskID),
                  pending.goal == goal, pending.choices?.contains(selectedChoice) == true else {
                throw RoutingError.missingContinuation
            }
            self.taskID = taskID
            promptDigest = digest
        }
        isExecuting = true
        defer { isExecuting = false }
        try Task.checkCancellation()
        let result = try await continuing.continueClarification(taskID: taskID, originatingTaskID: originatingTaskID,
            goal: goal, selectedChoice: selectedChoice, progress: progress)
        routedClarifiedGoal = goal
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

    func preflightApprovedAction(_ prepared: MCPPreparedApproval) async throws {
        guard !isExecuting else { throw RoutingError.alreadyExecuting }
        isExecuting = true
        defer { isExecuting = false }
        try Task.checkCancellation()
        guard route == .desktop, prepared.call.taskID == taskID,
              let continuing = desktop as? any MCPApprovalContinuing else {
            throw RoutingError.missingContinuation
        }
        try await continuing.preflightApprovedAction(prepared)
        try Task.checkCancellation()
    }

    func approvedActionPlan(taskID: String, promptBody: String) throws -> ComputerUseTaskLedger.ApprovedActionPlan? {
        guard route == .desktop, self.taskID == taskID else { return nil }
        return try (desktop as? any MCPApprovalContinuing)?.approvedActionPlan(taskID: taskID, promptBody: promptBody)
    }

    func continueApprovedActionPlan(taskID: String, confirmedActions: [ComputerUseTaskLedger.ApprovedActionRecord],
        tools: ComputerUseHostTools, progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        guard !isExecuting else { throw RoutingError.alreadyExecuting }
        isExecuting = true
        defer { isExecuting = false }
        try Task.checkCancellation()
        guard route == .desktop, self.taskID == taskID,
              let continuing = desktop as? any MCPApprovalContinuing else { throw RoutingError.missingContinuation }
        let result = try await continuing.continueApprovedActionPlan(taskID: taskID, confirmedActions: confirmedActions,
            tools: tools, progress: progress)
        try Task.checkCancellation()
        return result
    }

    func performApprovedVisualAction(_ continuation: ComputerUseVisualApprovalContinuation,
        action: ComputerUsePredictedAction, fingerprint: ComputerUseApprovalFingerprint,
        tools: ComputerUseHostTools, willBeginEffect: () -> Void) async throws {
        guard !isExecuting else { throw RoutingError.alreadyExecuting }
        isExecuting = true
        defer { isExecuting = false }
        try Task.checkCancellation()
        guard route == .desktop, continuation.taskID == taskID,
              let continuing = desktop as? any ComputerUseVisualApprovalContinuing else { throw RoutingError.missingContinuation }
        try await continuing.performApprovedVisualAction(continuation, action: action,
            fingerprint: fingerprint, tools: tools, willBeginEffect: willBeginEffect)
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
        return result
    }

    func cancelVisualApprovalContinuation(_ continuation: ComputerUseVisualApprovalContinuation) {
        (desktop as? any ComputerUseVisualApprovalContinuing)?.cancelVisualApprovalContinuation(continuation)
    }

    func cancelMCPWork() {
        (desktop as? any MCPApprovalContinuing)?.cancelMCPWork()
    }

    func pauseMCPWork() {
        (desktop as? any MCPApprovalContinuing)?.pauseMCPWork()
    }
}

/// Defers the expensive visual model until a structured route actually needs
/// it. The same loaded executor handles resume and approval continuation; a
/// continuation never performs another load or enters the planner again.
@MainActor
final class ComputerUseDeferredVisualExecutor: ComputerUseTaskAwareExecuting, ComputerUseVisualApprovalContinuing, ComputerUseTextClarificationContinuing {
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

    func clarification(taskID: String) throws -> ComputerUseNativeTextExecutor.Clarification? {
        guard self.taskID == taskID else { return nil }
        return try (loaded as? any ComputerUseTextClarificationContinuing)?.clarification(taskID: taskID)
    }

    func invalidateClarification(taskID: String?) {
        (loaded as? any ComputerUseTextClarificationContinuing)?.invalidateClarification(taskID: taskID)
    }

    func continueClarification(taskID: String, originatingTaskID: String, goal: ComputerUseUnresolvedTextGoal,
                               progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        guard !isExecuting else { throw ComputerUseCapabilityExecutor.RoutingError.alreadyExecuting }
        guard let continuing = loaded as? any ComputerUseTextClarificationContinuing else { throw ComputerUseCapabilityExecutor.RoutingError.missingContinuation }
        let digest = ComputerUseTextTaskContract.digest(goal.taskIdentityText)
        if self.taskID == taskID {
            guard promptDigest == digest else { throw ComputerUseCapabilityExecutor.RoutingError.taskChanged }
        } else {
            guard self.taskID == originatingTaskID, let pending = try continuing.clarification(taskID: originatingTaskID),
                  let answer = goal.userTurns.last, try pending.goal.answering(pending.question, with: answer) == goal else { throw ComputerUseCapabilityExecutor.RoutingError.missingContinuation }
            self.taskID = taskID; promptDigest = digest
        }
        isExecuting = true
        defer { isExecuting = false }
        try Task.checkCancellation()
        return try await continuing.continueClarification(taskID: taskID, originatingTaskID: originatingTaskID, goal: goal, progress: progress)
    }

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

    func performApprovedVisualAction(_ continuation: ComputerUseVisualApprovalContinuation,
        action: ComputerUsePredictedAction, fingerprint: ComputerUseApprovalFingerprint,
        tools: ComputerUseHostTools, willBeginEffect: () -> Void) async throws {
        guard !isExecuting else { throw ComputerUseCapabilityExecutor.RoutingError.alreadyExecuting }
        guard continuation.taskID == taskID, let visual = loaded as? any ComputerUseVisualApprovalContinuing else {
            throw ComputerUseCapabilityExecutor.RoutingError.missingContinuation
        }
        isExecuting = true
        defer { isExecuting = false }
        try Task.checkCancellation()
        try await visual.performApprovedVisualAction(continuation, action: action,
            fingerprint: fingerprint, tools: tools, willBeginEffect: willBeginEffect)
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
    /// Preparation alone never certifies runtime activation. Passive startup
    /// prepares the planner without occupying a worker; the runtime text
    /// planner activates it only when it needs a proposal.
    static func prepare(receipt: ComputerUseInstallationReceipt, tools: ComputerUseHostTools,
                        bundle: Bundle = .main, runtime: OSAtlasLlamaRuntime = .shared,
                        journalDirectory: URL = ComputerUseTextStepStore.defaultDirectory,
                        progress: @escaping (String) -> Void) async throws -> ComputerUseCapabilityExecutor {
        try await load(receipt: receipt, tools: tools, bundle: bundle, runtime: runtime,
            journalDirectory: journalDirectory, activateRuntime: false, progress: progress)
    }

    static func load(receipt: ComputerUseInstallationReceipt, tools: ComputerUseHostTools,
                     bundle: Bundle = .main, runtime: OSAtlasLlamaRuntime = .shared,
                     journalDirectory: URL = ComputerUseTextStepStore.defaultDirectory,
                     activateRuntime: Bool = true,
                     progress: @escaping (String) -> Void) async throws -> ComputerUseCapabilityExecutor {
        try Task.checkCancellation()
        progress(activateRuntime ? "Loading local computer use…" : "Preparing local form editing…")
        let directory = try OSAtlasVisualExecutorLoader.bundledRuntimeDirectoryURL(in: bundle)
        let inputs = try OSAtlasRuntimeInputResolver(manifest: .nativeTextV2).resolveNativeText(
            receipt: receipt, runtimeDirectoryURL: directory, enclosingBundleURL: bundle.bundleURL)
        if activateRuntime {
            let endpoint = try await runtime.activateNativeText(inputs)
            do { try Task.checkCancellation() }
            catch { await runtime.cancel(endpoint: endpoint); throw error }
        } else {
            try Task.checkCancellation()
        }
        let native = tools.makeNativeTextExecutor(
            planner: ComputerUseRuntimeTextGoalPlanner(inputs: inputs, runtime: runtime),
            journalDirectory: journalDirectory)
        return ComputerUseCapabilityExecutor(nativeExecution: { taskID, prompt, progress in
            return try await native.execute(taskID: taskID, prompt: prompt, progress: progress)
        }, nativeClarification: native)
    }
}

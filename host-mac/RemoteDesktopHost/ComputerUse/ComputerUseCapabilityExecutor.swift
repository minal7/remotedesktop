import Foundation

/// Starts a routed task with host-validated clarification context. Questions
/// remain context rather than being merged into the current user request.
@MainActor
protocol ComputerUseClarifiedGoalExecuting {
    func execute(taskID: String, goal: ComputerUseUnresolvedTextGoal,
                 tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult
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
    ComputerUseVisualApprovalContinuing, ComputerUseClarificationContinuing,
    ComputerUseNativeOnlyExecuting, ComputerUseClarifiedGoalExecuting {
    typealias NativeExecution = @MainActor (String, String, @escaping (String) -> Void) async throws -> ComputerUseExecutionResult?
    typealias DesktopFactory = @MainActor (@escaping (String) -> Void) async throws -> any ComputerUseExecuting

    enum RoutingError: Error, Equatable { case taskChanged, missingContinuation, alreadyExecuting }
    private enum Route { case native, desktop }
    private let nativeExecution: NativeExecution
    private let nativeClarification: (any ComputerUseClarificationContinuing)?
    private var desktopFactory: DesktopFactory?
    private var desktopIncludesVisualControl: Bool
    private var taskID: String?
    private var promptDigest: String?
    private var route: Route = .native
    private var desktop: (any ComputerUseExecuting)?
    private var routedClarifiedGoal: ComputerUseUnresolvedTextGoal?
    private var isExecuting = false
    private var nativeOnlyTask = false
    let agentAdapter: (any AgentTaskAdapting)?

    init(nativeExecution: @escaping NativeExecution, desktopFactory: DesktopFactory? = nil,
         desktopIncludesVisualControl: Bool = true, nativeClarification: (any ComputerUseClarificationContinuing)? = nil) {
        self.nativeExecution = nativeExecution
        self.agentAdapter = nil
        self.nativeClarification = nativeClarification
        self.desktopFactory = desktopFactory
        self.desktopIncludesVisualControl = desktopFactory != nil && desktopIncludesVisualControl
    }

    init(agentAdapter: any AgentTaskAdapting) {
        self.agentAdapter = agentAdapter
        self.nativeExecution = { _, _, _ in nil }
        self.nativeClarification = nil
        self.desktopFactory = nil
        self.desktopIncludesVisualControl = false
    }

    let isReady = true
    var hasAdditionalSetup: Bool { agentAdapter == nil && (desktopFactory == nil || !desktopIncludesVisualControl) }
    var readyDetail: String {
        if let agentAdapter { return agentAdapter.readyDetail }
        guard desktopFactory != nil else { return "Form editing is ready; desktop tools need setup" }
        return desktopIncludesVisualControl
            ? "Form editing and visual control are ready"
            : "Form editing is ready; visual control needs setup"
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
        let digest = ComputerUseTaskJournalStore.digest(goal.taskIdentityText)
        if self.taskID == taskID {
            guard route == .desktop, promptDigest == digest, routedClarifiedGoal == goal else {
                throw RoutingError.taskChanged
            }
        } else {
            nativeClarification?.invalidateClarification(taskID: self.taskID)
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
            try Task.checkCancellation()
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
        let digest = ComputerUseTaskJournalStore.digest(currentUserPrompt)
        if self.taskID == taskID {
            guard promptDigest == digest else { throw RoutingError.taskChanged }
            // A restricted attempt cannot reconstruct a task already owned
            // by another route, or loosen its restriction on ordinary Resume.
            if nativeOnly {
                guard route == .native else { throw RoutingError.missingContinuation }
                nativeOnlyTask = true
            }
        } else {
            nativeClarification?.invalidateClarification(taskID: self.taskID)
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
            try Task.checkCancellation()
            desktop = loaded
        }
        guard let desktop else { throw RoutingError.missingContinuation }
        let result = try await desktop.execute(taskID: taskID, modelPrompt: modelPrompt,
            currentUserPrompt: currentUserPrompt, conversation: conversation, tools: tools, progress: progress)
        try Task.checkCancellation()
        return result
    }

    func clarification(taskID: String) throws -> ComputerUseClarificationQuestion? {
        if let agentAdapter { return try agentAdapter.clarification(taskID: taskID) }
        guard self.taskID == taskID else { return nil }
        if route == .native { return try nativeClarification?.clarification(taskID: taskID) }
        if route == .desktop { return try (desktop as? any ComputerUseClarificationContinuing)?.clarification(taskID: taskID) }
        return nil
    }

    func invalidateClarification(taskID: String?) {
        if let agentAdapter { agentAdapter.invalidateClarification(taskID: taskID); return }
        if taskID == nil || taskID == self.taskID { routedClarifiedGoal = nil }
        nativeClarification?.invalidateClarification(taskID: taskID)
        (desktop as? any ComputerUseClarificationContinuing)?.invalidateClarification(taskID: taskID)
    }

    func continueClarification(taskID: String, originatingTaskID: String, goal: ComputerUseUnresolvedTextGoal,
                               progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        if let agentAdapter {
            return try await agentAdapter.continueClarification(taskID: taskID, originatingTaskID: originatingTaskID,
                goal: goal, progress: progress)
        }
        guard !isExecuting else { throw RoutingError.alreadyExecuting }
        guard route == .native && nativeClarification != nil || route == .desktop && desktop is any ComputerUseClarificationContinuing else { throw RoutingError.missingContinuation }
        let digest = ComputerUseTaskJournalStore.digest(goal.taskIdentityText)
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
        } else if let continuing = desktop as? any ComputerUseClarificationContinuing {
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
        guard route != .native else { throw ComputerUseClarificationStore.Failure.invalidChoice }
        guard route == .desktop,
              let continuing = desktop as? any ComputerUseClarificationContinuing else {
            throw RoutingError.missingContinuation
        }
        let digest = ComputerUseTaskJournalStore.digest(goal.taskIdentityText)
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

}

/// Defers the expensive visual model until a structured route actually needs
/// it. The same loaded executor handles resume and approval continuation; a
/// continuation never performs another load or enters the planner again.
@MainActor
final class ComputerUseDeferredVisualExecutor: ComputerUseTaskAwareExecuting, ComputerUseVisualApprovalContinuing, ComputerUseClarificationContinuing {
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
    var hasAdditionalSetup: Bool { loader == nil }
    var runtimeName: String { isReady ? "Visual control is available on demand" : "Visual control needs setup" }
    var readyDetail: String { runtimeName }

    func clarification(taskID: String) throws -> ComputerUseClarificationQuestion? {
        guard self.taskID == taskID else { return nil }
        return try (loaded as? any ComputerUseClarificationContinuing)?.clarification(taskID: taskID)
    }

    func invalidateClarification(taskID: String?) {
        (loaded as? any ComputerUseClarificationContinuing)?.invalidateClarification(taskID: taskID)
    }

    func continueClarification(taskID: String, originatingTaskID: String, goal: ComputerUseUnresolvedTextGoal,
                               progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        guard !isExecuting else { throw ComputerUseCapabilityExecutor.RoutingError.alreadyExecuting }
        guard let continuing = loaded as? any ComputerUseClarificationContinuing else { throw ComputerUseCapabilityExecutor.RoutingError.missingContinuation }
        let digest = ComputerUseTaskJournalStore.digest(goal.taskIdentityText)
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
        let digest = ComputerUseTaskJournalStore.digest(currentUserPrompt)
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

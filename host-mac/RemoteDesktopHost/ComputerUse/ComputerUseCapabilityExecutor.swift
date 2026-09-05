import Foundation

/// Routes a whole current-user goal before effects begin. A native attempt
/// may decline with no effects; an error or uncertain edit is never permission
/// to reconstruct and replay the goal through another executor.
@MainActor
final class ComputerUseCapabilityExecutor: ComputerUseTaskAwareExecuting,
    MCPApprovalContinuing, ComputerUseVisualApprovalContinuing {
    typealias NativeExecution = @MainActor (String, String, @escaping (String) -> Void) async throws -> ComputerUseExecutionResult?
    typealias DesktopFactory = @MainActor (@escaping (String) -> Void) async throws -> any ComputerUseExecuting

    enum RoutingError: Error { case taskChanged, missingContinuation, alreadyExecuting }
    private enum Route { case native, desktop }
    private let nativeExecution: NativeExecution
    private var desktopFactory: DesktopFactory?
    private var desktopIncludesVisualControl: Bool
    private var taskID: String?
    private var promptDigest: String?
    private var route: Route = .native
    private var desktop: (any ComputerUseExecuting)?
    private var isExecuting = false

    init(nativeExecution: @escaping NativeExecution, desktopFactory: DesktopFactory? = nil,
         desktopIncludesVisualControl: Bool = true) {
        self.nativeExecution = nativeExecution
        self.desktopFactory = desktopFactory
        self.desktopIncludesVisualControl = desktopFactory != nil && desktopIncludesVisualControl
    }

    convenience init(native: ComputerUseNativeTextExecutor, desktopFactory: DesktopFactory? = nil) {
        self.init(nativeExecution: { taskID, prompt, progress in
            try await native.execute(taskID: taskID, prompt: prompt, progress: progress)
        }, desktopFactory: desktopFactory)
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
                return browserResult
            }
            // This receives only the current user request. Conversation and
            // assistant prose cannot supply additional native edit authority.
            let nativeResult = try await nativeExecution(taskID, currentUserPrompt, progress)
            try Task.checkCancellation()
            if let result = nativeResult {
                return result
            }
            try Task.checkCancellation()
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

    func continueAfterApproval(_ prepared: MCPPreparedApproval, tools: ComputerUseHostTools,
                              progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        guard !isExecuting else { throw RoutingError.alreadyExecuting }
        isExecuting = true
        defer { isExecuting = false }
        try Task.checkCancellation()
        guard route == .desktop, let continuing = desktop as? any MCPApprovalContinuing else {
            throw RoutingError.missingContinuation
        }
        let result = try await continuing.continueAfterApproval(prepared, tools: tools, progress: progress)
        try Task.checkCancellation()
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
        progress("Loading local form editing…")
        let directory = try OSAtlasVisualExecutorLoader.bundledRuntimeDirectoryURL(in: bundle)
        let inputs = try OSAtlasRuntimeInputResolver(manifest: .nativeTextV2).resolveNativeText(
            receipt: receipt, runtimeDirectoryURL: directory, enclosingBundleURL: bundle.bundleURL)
        let endpoint = try await runtime.activateNativeText(inputs)
        do { try Task.checkCancellation() }
        catch { await runtime.cancel(endpoint: endpoint); throw error }
        let native = tools.makeNativeTextExecutor(
            planner: ComputerUseRuntimeTextGoalPlanner(inputs: inputs, runtime: runtime),
            journalDirectory: journalDirectory)
        return ComputerUseCapabilityExecutor(native: native)
    }
}

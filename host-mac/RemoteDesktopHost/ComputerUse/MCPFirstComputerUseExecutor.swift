import CryptoKit
import Foundation
import Darwin
import os

protocol MCPClientPooling: Sendable {
    func start(binaryURL: URL) async throws -> MCPProcessIdentity
    func allowedTools() async throws -> [MCPAllowedTool]
    func execute(_ call: MCPToolCall) async throws -> MCPToolResult
    func prepareApproval(_ call: MCPToolCall) async throws -> MCPPreparedApproval
    func performApproved(
        _ call: MCPToolCall,
        fingerprint: MCPApprovalFingerprint
    ) async throws -> MCPToolResult
    func preflightApproved(
        _ call: MCPToolCall,
        fingerprint: MCPApprovalFingerprint
    ) async throws
    func cancel(processGeneration: UInt64) async
    func cancelAll() async
}

extension MCPClientPool: MCPClientPooling {}

extension MCPClientPooling {
    func preflightApproved(
        _ call: MCPToolCall,
        fingerprint: MCPApprovalFingerprint
    ) async throws {}
}

@MainActor
protocol ComputerUseTaskAwareExecuting: ComputerUseExecuting {
    func execute(
        taskID: String,
        prompt: String,
        trustedUserPrompt: String,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult
}

@MainActor
protocol MCPApprovalContinuing: AnyObject {
    func preflightApprovedAction(_ prepared: MCPPreparedApproval) async throws
    func continueAfterApproval(
        _ prepared: MCPPreparedApproval,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> MCPApprovedActionResult

    /// Only host-bound plans may opt into ordered, independently approved
    /// effects. Legacy one-action executors leave this nil.
    func approvedActionPlan(taskID: String, promptBody: String) throws -> ComputerUseTaskLedger.ApprovedActionPlan?
    func continueApprovedActionPlan(
        taskID: String, confirmedActions: [ComputerUseTaskLedger.ApprovedActionRecord],
        tools: ComputerUseHostTools, progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult

    /// Invalidates the current run synchronously. The helper shutdown itself
    /// is asynchronous, but is bound to the captured process generation so a
    /// delayed cleanup can never stop a newer resumed run.
    func cancelMCPWork()
    /// Invalidates a paused run while retaining host-verified browser progress.
    /// Legacy executors fall back to their existing cancellation behavior.
    func pauseMCPWork()
}

extension MCPApprovalContinuing {
    func preflightApprovedAction(_ prepared: MCPPreparedApproval) async throws {}
    func pauseMCPWork() { cancelMCPWork() }
    func approvedActionPlan(taskID: String, promptBody: String) throws -> ComputerUseTaskLedger.ApprovedActionPlan? { nil }
    func continueApprovedActionPlan(
        taskID: String, confirmedActions: [ComputerUseTaskLedger.ApprovedActionRecord],
        tools: ComputerUseHostTools, progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult { throw MCPClientError.approvalMismatch }
}

private final class MCPGenerationCancellationJoin: @unchecked Sendable {
    let generation: UInt64
    private let clientPool: any MCPClientPooling
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(clientPool: any MCPClientPooling, generation: UInt64) {
        self.clientPool = clientPool
        self.generation = generation
    }

    func startedTask() -> Task<Void, Never>? { lock.withLock { task } }

    func start() -> Task<Void, Never> {
        lock.withLock {
            if let task { return task }
            let task = Task { [clientPool, generation] in
                await clientPool.cancel(processGeneration: generation)
            }
            self.task = task
            return task
        }
    }
}

/// Routes structured work through a pinned local MCP sidecar and Apple's
/// on-device planner before the fallback text and visual capabilities.
/// Fallback execution is retained once it takes ownership of a task.
/// No remote inference or API credential is used by this executor.
@MainActor
final class MCPFirstComputerUseExecutor:
    ComputerUseTaskAwareExecuting,
    MCPApprovalContinuing,
    ComputerUseVisualApprovalContinuing,
    ComputerUseTextClarificationContinuing {
    /// Host-only proof that a validated native answer used selected records
    /// from one exact page observation. Never decoded from model output.
    struct NativeReadCompletion: Sendable {
        let proposal: ComputerUseFaraModel.Proposal
        let authorityDigest: String
        let references: [String]

        fileprivate init(proposal: ComputerUseFaraModel.Proposal, authorityDigest: String, references: [String]) {
            self.proposal = proposal
            self.authorityDigest = authorityDigest
            self.references = references
        }
    }

    enum ExecutorError: Error, LocalizedError, Equatable {
        case requiredToolsMissing
        case alreadyExecuting
        case tooManySteps
        case approvalStateChanged
        case structuredToolFailed(String)
        case visualApprovalContinuationUnavailable
        case calculatorClearNotVerified
        case taskChanged
        case calculatorResultNotVerified(String)

        var errorDescription: String? {
            switch self {
            case .requiredToolsMissing:
                return "The verified local Mac tools helper is missing required tools."
            case .alreadyExecuting:
                return "This Mac task is still finishing. Wait for it to finish or stop before continuing."
            case .tooManySteps:
                return "The local planner could not finish within the safe step limit."
            case .approvalStateChanged:
                return "The approved Mac action no longer matches the pending task."
            case .structuredToolFailed(let message):
                return message
            case .visualApprovalContinuationUnavailable:
                return "The local visual executor cannot resume this approved action."
            case .calculatorClearNotVerified:
                return "Calculator could not be verified as cleared, so the task was stopped."
            case .taskChanged:
                return "The resumed task no longer matches its original request."
            case .calculatorResultNotVerified(let expected):
                return "Calculator did not show the expected result (\(expected)), so the task was not marked complete."
            }
        }
    }

    static let maximumStructuredSteps = 10
    static let maximumResultCharactersPerStep = 2_000

    private static let log = Logger(
        subsystem: "com.threadmark.remotedesktop.host",
        category: "mcp-first-computer-use")

    private struct StepResult: Equatable {
        let toolName: String
        let risk: MCPToolRisk
        let arguments: [String: MCPJSONValue]
        let readProvenance: ReadProvenance?
        let text: String
        let structuredContent: MCPJSONValue?
        let wasTruncated: Bool
    }

    private enum ReadDomain: String, CaseIterable, Equatable, Hashable {
        case contacts
        case reminders
        case shortcuts
        case focusedApp
        case runningApps
        case windows
        case permissions
    }

    private enum ReminderCompletionIntent: Equatable {
        case incompleteOnly
        case completedOnly
        case all
        case unspecified
    }

    /// Host-reviewed meaning of one exact read call. This is captured before
    /// execution and retained beside the result so completion cannot reinterpret
    /// arguments after seeing private data.
    private enum ReadProvenance: Equatable {
        case contacts(query: String, limit: Int?)
        case reminders(
            completion: ReminderCompletionIntent,
            listName: String?,
            includeCompleted: Bool,
            limit: Int?)
        case shortcuts
        case focusedApp
        case runningApps
        case windowApplicationInventoryDependency
        case windows(pid: Int?, applicationName: String?)
        case permissions

        var completionDomain: ReadDomain? {
            switch self {
            case .contacts: return .contacts
            case .reminders: return .reminders
            case .shortcuts: return .shortcuts
            case .focusedApp: return .focusedApp
            case .runningApps: return .runningApps
            case .windowApplicationInventoryDependency: return nil
            case .windows: return .windows
            case .permissions: return .permissions
            }
        }
    }

    private struct PlanningState: Equatable {
        let taskID: String
        let rootTaskID: String
        let originalPrompt: String
        /// The current user-authored turn from the signed task envelope. The
        /// model prompt may contain conversation history, so it must never be
        /// used to authorize a read result as relevant to this request.
        let trustedUserPrompt: String
        /// Compiled before planning; model queries cannot redefine this scope.
        let contactReadRequirements: ContactReadRequirements?
        var clarificationGoal: ComputerUseUnresolvedTextGoal
        var results: [StepResult]
        var executedCallDigests: Set<String>

        func withTaskID(_ taskID: String) -> PlanningState {
            PlanningState(taskID: taskID, rootTaskID: rootTaskID, originalPrompt: originalPrompt,
                trustedUserPrompt: trustedUserPrompt,
                contactReadRequirements: contactReadRequirements,
                clarificationGoal: clarificationGoal,
                results: results, executedCallDigests: executedCallDigests)
        }
    }

    /// Root-owned session for one model-directed Downloads lookup. The catalog
    /// is keyed to the original task; an accepted choice may continue under a
    /// new answer-envelope ID without changing the original user goal.
    private final class NativeFileRun {
        let rootTaskID: String
        let originalPrompt: String
        let trustedUserPrompt: String
        var planningState: PlanningState
        var currentTaskID: String
        var catalog: ComputerUseLocalFileCatalog?
        var context: ComputerUseMCPBrowserStepPlanner.LocalFileContext
        var selectedCandidate: ComputerUseLocalFileCatalog.Candidate?
        var selectedPath: URL?
        var selectedByUserCandidateID: String?
        var selectedByUserPath: URL?
        var didBroadenNameFilter = false
        var pendingClarification: ComputerUseNativeTextExecutor.Clarification?
        var choicesByID: [String: ComputerUseLocalFileCatalog.Candidate] = [:]
        var invalidated = false
        let tools: ComputerUseHostTools

        init(rootTaskID: String, prompt: String, trustedUserPrompt: String,
             planningState: PlanningState, tools: ComputerUseHostTools) {
            self.rootTaskID = rootTaskID
            self.originalPrompt = prompt
            self.trustedUserPrompt = trustedUserPrompt
            self.planningState = planningState
            self.currentTaskID = planningState.taskID
            self.context = Self.notQueriedContext
            self.tools = tools
        }

        static var notQueriedContext: ComputerUseMCPBrowserStepPlanner.LocalFileContext {
            .init(query: .init(), page: .init(candidates: [], isComplete: false,
                nextCursor: nil, hasTiedSortValues: false, hasMissingSortValues: false),
                inventoryState: .notQueried)
        }
    }

    private struct PendingStructuredClarification {
        let rootTaskID: String
        let info: ComputerUseNativeTextExecutor.Clarification
        let state: PlanningState
        let fileRun: NativeFileRun?
        let tools: ComputerUseHostTools
        var mailRecipients: PendingMailRecipients? = nil
    }

    private struct PendingMailRecipients {
        var resolver: ComputerUseMailRecipients
        let field: String
        let index: Int
        let addressesByChoiceID: [String: String]
    }

    private struct ContactReadRequirements: Equatable {
        /// Ordered, distinct search entities from supported current-turn clauses.
        let queries: [String]

        func contains(_ query: String) -> Bool {
            queries.contains {
                MCPFirstComputerUseExecutor.contactQueryIdentity($0)
                    == MCPFirstComputerUseExecutor.contactQueryIdentity(query)
            }
        }
    }

    struct DeterministicCalculatorRequest: Equatable {
        let expression: String
        let expectedDisplayValue: String
    }

    /// Every planner-visible tool must have a passing real-stdio acceptance
    /// case (or, for embedded Mail, a signed-host acceptance case). Keep this
    /// internal so the release-gate tests can prevent blocked tools from
    /// drifting back into the planner surface.
    nonisolated static let structuredToolNames: Set<String> = [
        // Native Apple applications.
        "contacts_search",
        RemoteDesktopMailMCP.toolName,
        RemoteDesktopCloudStorageMCP.toolName,
        "reminders_list",
        "list_shortcuts",

        // Read-only host context that helps the planner decide whether the
        // requested operation has a structured representation.
        "focused_app",
        "list_apps",
        "list_windows",
        "permissions_status",
    ]

    private let planner: any MCPProposalPlanning
    private let planningWorker: ComputerUsePlanningWorker
    private let planningTimeout: TimeInterval
    private let clientPool: any MCPClientPooling
    private let cloudStorage: RemoteDesktopCloudStorage
    private let binaryURL: URL
    private let visualFallback: any ComputerUseExecuting
    typealias BrowserExecutorFactory = @MainActor () async throws -> any ComputerUseExecuting
    private enum RoutingSignal: Error { case browserTools, desktopTools }
    private let browserExecutorFactory: BrowserExecutorFactory
    private var retainedBrowserExecutor: (any ComputerUseExecuting)?
    private var retainedUsesBrowser = false
    private var retainedExecutor: any ComputerUseExecuting { retainedBrowserExecutor ?? visualFallback }
    private var helperReady = false
    private var activeProcessGeneration: UInt64?
    private var activeCancellationJoin: MCPGenerationCancellationJoin?
    private var cancellationEpoch: UInt64 = 0
    private var activeExecutionEpoch: UInt64?
    private var pendingApprovalState: PlanningState?
    private var pendingApprovalDigest: String?
    private var nativeFileRun: NativeFileRun?
    private var pendingStructuredClarification: PendingStructuredClarification?
    private struct RetainedStructuredRoute {
        let originatingTaskID: String
        let taskID: String
        let goal: ComputerUseUnresolvedTextGoal
        let tools: ComputerUseHostTools
        let usesBrowser: Bool
    }
    private var retainedStructuredRoute: RetainedStructuredRoute?
    private var retainedFallback: (taskID: String, promptDigest: String)?
    private var retainedNativeFailure: Error?
    private var retainedBrowserIntentContract: (rootTaskID: String, contract: ComputerUseBrowserIntentContract)?
    private struct RetainedBrowserVisits {
        let rootTaskID: String
        let goal: ComputerUseUnresolvedTextGoal
        let sessionIdentity: String
        var documents: [ComputerUseBrowserDocument]
    }
    private var retainedBrowserVisits: RetainedBrowserVisits?
    private let documentPlanner: ComputerUseMCPDocumentPlanner
    private final class DocumentRun {
        let prompt: String
        let snapshot: ComputerUseMCPFocusedTextSnapshot
        let document: URL
        let edit: ComputerUseMCPDocumentEdit
        let contract: ComputerUseTaskContract
        let calls: [MCPToolCall]
        var prepared: MCPPreparedApproval?
        var plan: ComputerUseTaskLedger.ApprovedActionPlan?
        var confirmed: [MCPApprovedActionResult] = []
        init(prompt: String, snapshot: ComputerUseMCPFocusedTextSnapshot, document: URL,
             edit: ComputerUseMCPDocumentEdit, contract: ComputerUseTaskContract, calls: [MCPToolCall]) {
            self.prompt = prompt; self.snapshot = snapshot; self.document = document
            self.edit = edit; self.contract = contract; self.calls = calls
        }
    }
    private var documentRun: DocumentRun?
    private weak var browserTools: ComputerUseHostTools?
    private let browserStepPlanner: ComputerUseMCPBrowserStepPlanner
    private let localFileCatalogFactory: ComputerUseDefaultBrowserFileCatalogFactory

    private init(
        planner: any MCPProposalPlanning,
        clientPool: any MCPClientPooling,
        cloudStorage: RemoteDesktopCloudStorage,
        binaryURL: URL,
        visualFallback: any ComputerUseExecuting,
        planningWorker: ComputerUsePlanningWorker,
        planningTimeout: TimeInterval,
        documentPlanner: ComputerUseMCPDocumentPlanner,
        browserStepPlanner: ComputerUseMCPBrowserStepPlanner,
        localFileCatalogFactory: @escaping ComputerUseDefaultBrowserFileCatalogFactory,
        browserExecutorFactory: @escaping BrowserExecutorFactory
    ) {
        self.planner = planner
        self.clientPool = clientPool
        self.cloudStorage = cloudStorage
        self.binaryURL = binaryURL
        self.visualFallback = visualFallback
        self.planningWorker = planningWorker
        self.planningTimeout = planningTimeout
        self.documentPlanner = documentPlanner
        self.browserStepPlanner = browserStepPlanner
        self.localFileCatalogFactory = localFileCatalogFactory
        self.browserExecutorFactory = browserExecutorFactory
    }

    static func load(
        binaryURL: URL,
        visualFallback: any ComputerUseExecuting,
        planner: any MCPProposalPlanning = AppleFoundationMCPPlanner(),
        clientPool: any MCPClientPooling,
        cloudStorage: RemoteDesktopCloudStorage = .init(),
        planningWorker: ComputerUsePlanningWorker = .shared,
        planningTimeout: TimeInterval = ComputerUsePlanningWorker.maximumWait,
        documentPlanner: ComputerUseMCPDocumentPlanner = .init(),
        browserStepPlanner: ComputerUseMCPBrowserStepPlanner = .init(),
        localFileCatalogFactory: @escaping ComputerUseDefaultBrowserFileCatalogFactory = { taskID in
            try ComputerUseLocalFileCatalog(taskID: taskID,
                approvedRoots: ComputerUseLocalFileCatalog.standardApprovedRoots(), pageSize: 8, usesSpotlight: true)
        },
        browserExecutorFactory: @escaping BrowserExecutorFactory = {
            try OSAtlasVisualExecutorLoader().prepareDefaultBrowser(receipt: nil)
        }
    ) async throws -> MCPFirstComputerUseExecutor {
        let executor = MCPFirstComputerUseExecutor(
            planner: planner,
            clientPool: clientPool,
            cloudStorage: cloudStorage,
            binaryURL: binaryURL.standardizedFileURL,
            visualFallback: visualFallback,
            planningWorker: planningWorker,
            planningTimeout: planningTimeout,
            documentPlanner: documentPlanner,
            browserStepPlanner: browserStepPlanner,
            localFileCatalogFactory: localFileCatalogFactory,
            browserExecutorFactory: browserExecutorFactory)
        try Task.checkCancellation()
        let identity = try await clientPool.start(binaryURL: binaryURL)
        do {
            try Task.checkCancellation()
            let tools = try await clientPool.allowedTools()
            try Task.checkCancellation()
            guard tools.contains(where: {
                $0.toolName == RemoteDesktopMailMCP.toolName
                    && $0.serverID == RemoteDesktopMailMCP.serverID
            }) else {
                throw ExecutorError.requiredToolsMissing
            }
            executor.helperReady = true
            executor.activeProcessGeneration = identity.processGeneration
            return executor
        } catch {
            // A late cancellation or failed discovery owns only this start.
            // Join its cleanup without stopping a newer generation in the pool.
            await clientPool.cancel(processGeneration: identity.processGeneration)
            throw error
        }
    }

    var isReady: Bool {
        helperReady
    }

    var supportsNativeTextTasks: Bool { visualFallback.supportsNativeTextTasks }
    var hasAdditionalSetup: Bool { !visualFallback.isReady || visualFallback.hasAdditionalSetup }
    var readyDetail: String {
        if supportsNativeTextTasks { return visualFallback.readyDetail }
        return visualFallback.isReady ? "Mac tools and visual control are ready" : "Mac tools are ready; visual control needs setup"
    }

    var runtimeName: String {
        let visual = hasAdditionalSetup ? "; additional computer-use setup is needed" : ", with fallback computer use available on demand"
        switch planner.availability() {
        case .available:
            return "Apple on-device planner + local Mac tools" + visual
        case .unavailable:
            return "Local deterministic Mac tools (Apple planner unavailable)" + visual
        }
    }

    func execute(
        prompt: String,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        let digest = SHA256.hash(data: Data(prompt.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return try await execute(
            taskID: "legacy-\(digest)",
            prompt: prompt,
            trustedUserPrompt: prompt,
            tools: tools,
            progress: progress)
    }

    func execute(
        taskID: String,
        prompt: String,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        try await execute(
            taskID: taskID,
            prompt: prompt,
            trustedUserPrompt: prompt,
            tools: tools,
            progress: progress)
    }

    func execute(
        taskID: String,
        prompt: String,
        trustedUserPrompt: String,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        try await executeResolved(
            taskID: taskID,
            prompt: prompt,
            trustedUserPrompt: trustedUserPrompt,
            conversation: nil,
            tools: tools,
            progress: progress)
    }

    func execute(
        taskID: String,
        modelPrompt: String,
        currentUserPrompt: String,
        conversation: [ComputerUseConversationTurn],
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        try await executeResolved(
            taskID: taskID,
            prompt: modelPrompt,
            trustedUserPrompt: currentUserPrompt,
            conversation: conversation,
            tools: tools,
            progress: progress)
    }

    private func executeResolved(
        taskID: String,
        prompt: String,
        trustedUserPrompt: String,
        conversation: [ComputerUseConversationTurn]?,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        try beginExecution()
        defer { activeExecutionEpoch = nil }
        let promptDigest = ComputerUseTextTaskContract.digest(trustedUserPrompt)
        func executeNativeAlternative(after failure: Error) async throws -> ComputerUseExecutionResult {
            try checkExecutionCancellation()
            guard let native = visualFallback as? any ComputerUseNativeOnlyExecuting else { throw failure }
            // Retain the restriction before an alternative can suspend or edit.
            // A later native decline must never activate its desktop factory.
            retainedFallback = (taskID, promptDigest)
            retainedNativeFailure = failure
            let result = try await native.executeNativeOnly(taskID: taskID, modelPrompt: prompt,
                currentUserPrompt: trustedUserPrompt, conversation: conversation ?? [], tools: tools,
                progress: progress)
            try checkExecutionCancellation()
            if let result { return result }
            // Keep this task restricted to native tools even if the native
            // executor declines again after an intervention.
            throw failure
        }
        func executeVisualFallback(usingBrowser: Bool = false) async throws
            -> ComputerUseExecutionResult {
            // Commit before fallback can produce an effect or suspend. Resume
            // cannot replay the original goal through newly available MCP.
            retainedFallback = (taskID, promptDigest)
            if usingBrowser { retainedUsesBrowser = true }
            if retainedUsesBrowser, retainedBrowserExecutor == nil {
                try checkExecutionCancellation()
                let candidate = try await browserExecutorFactory()
                try checkExecutionCancellation()
                retainedBrowserExecutor = candidate
            }
            let fallback = retainedExecutor
            return try await withBrowserToolProposals(taskID: taskID, tools: tools) {
                if let conversation {
                    return try await fallback.execute(
                        taskID: taskID,
                        modelPrompt: prompt,
                        currentUserPrompt: trustedUserPrompt,
                        conversation: conversation,
                        tools: tools,
                        progress: progress)
                }
                return try await fallback.execute(
                    taskID: taskID,
                    prompt: prompt,
                    trustedUserPrompt: trustedUserPrompt,
                    tools: tools,
                    progress: progress)
            }
        }
        try await waitForStartedCancellation()
        if retainedStructuredRoute?.taskID == taskID {
            throw ExecutorError.visualApprovalContinuationUnavailable
        }
        if let retainedFallback, retainedFallback.taskID == taskID {
            guard retainedFallback.promptDigest == promptDigest else { throw ExecutorError.taskChanged }
            if let failure = retainedNativeFailure { return try await executeNativeAlternative(after: failure) }
            return try await executeVisualFallback()
        }
        retainedFallback = nil
        retainedNativeFailure = nil
        if retainedStructuredRoute?.taskID != taskID { retainedStructuredRoute = nil }
        retainedBrowserExecutor = nil
        retainedUsesBrowser = false
        retainedBrowserIntentContract = nil
        retainedBrowserVisits = nil
        if let pending = pendingStructuredClarification {
            if pending.info.taskID == taskID {
                guard pending.info.expiresAt > Date(),
                      pending.info.goal.userTurns.first == pending.state.trustedUserPrompt,
                      pending.state.trustedUserPrompt.utf8.elementsEqual(trustedUserPrompt.utf8) else {
                    pendingStructuredClarification = nil
                    throw ExecutorError.taskChanged
                }
                try checkExecutionCancellation()
                try pending.tools.requireActive()
                return .clarificationRequired(pending.info.question)
            }
            pendingStructuredClarification = nil
        }
        if let fileRun = nativeFileRun {
            if fileRun.currentTaskID == taskID {
                guard !fileRun.invalidated,
                      fileRun.trustedUserPrompt.utf8.elementsEqual(trustedUserPrompt.utf8) else {
                    throw ExecutorError.taskChanged
                }
                pendingApprovalState = nil
                pendingApprovalDigest = nil
                let state = fileRun.planningState.withTaskID(taskID)
                return try await runStructured(state: state, tools: tools, fileRun: fileRun, progress: progress)
            }
            nativeFileRun = nil
        }
        pendingApprovalState = nil
        pendingApprovalDigest = nil

        if let run = documentRun, run.contract.taskID == taskID {
            // A cancelled approval has no dispatch authority. Before the
            // first claim only, retain the semantic task and bind it again to
            // the same unchanged document in the replacement helper.
            guard run.plan == nil, run.confirmed.isEmpty,
                  run.prompt.utf8.elementsEqual(trustedUserPrompt.utf8),
                  let result = try await executeDocumentTask(taskID: taskID, prompt: trustedUserPrompt,
                    tools: tools, progress: progress, retained: run) else {
                throw ExecutorError.approvalStateChanged
            }
            return result
        }
        documentRun = nil

        if let browserResult = try await tools.executeOwnedBrowserTaskIfSupported(
            taskID: taskID, prompt: trustedUserPrompt, progress: progress) {
            try Task.checkCancellation()
            return browserResult
        }

        if ComputerUseMCPFocusedTextRead.matches(
            trustedUserPrompt, application: tools.frontmostApplicationSnapshot().localizedName),
           let snapshot = try tools.mcpFocusedTextSnapshot(), snapshot.isReadable,
           ComputerUseMCPFocusedTextRead.matches(trustedUserPrompt, application: snapshot.application.localizedName),
           let result = try await executeFocusedTextRead(
               taskID: taskID, snapshot: snapshot, tools: tools, progress: progress) {
            return result
        }

        // Calculator arithmetic has a small, verifiable local representation.
        // Handle only that bounded shape before either planner/model path: the
        // host opens the real app, types the expression through the same
        // intervention-gated GUI injector, and requires AX display evidence.
        if let request = Self.deterministicCalculatorRequest(
            for: trustedUserPrompt) {
            return try await executeDeterministicCalculator(
                request,
                tools: tools,
                progress: progress)
        }

        // Opening exactly one installed application has a small, validated
        // native representation. Do not ask either local model to rediscover
        // this operation from an unrelated screenshot: the pinned visual model
        // has been observed clicking the visible app instead of honoring
        // OPEN_APP. Chained requests and consequential mutations intentionally
        // remain on the normal planner/approval path.
        if let applicationName = Self.pureOpenApplicationName(
            trustedUserPrompt) {
            Self.log.info(
                "Routed one current-turn pure open-app request to validated Launch Services")
            progress("Opening the requested app…")
            try await tools.openApplication(named: applicationName)
            return .completed("Done. I opened \(applicationName).")
        }

        if let documentResult = try await executeDocumentTask(taskID: taskID, prompt: trustedUserPrompt,
            tools: tools, progress: progress) {
            return documentResult
        }

        if case .unavailable(let reason) = planner.availability() {
            return try await executeNativeAlternative(after: AppleFoundationMCPPlannerError.unavailable(reason))
        }

        let state = PlanningState(
            taskID: taskID,
            rootTaskID: taskID,
            originalPrompt: prompt,
            trustedUserPrompt: trustedUserPrompt,
            contactReadRequirements: Self.compileContactReadRequirements(trustedUserPrompt),
            clarificationGoal: try ComputerUseUnresolvedTextGoal(userRequest: trustedUserPrompt),
            results: [],
            executedCallDigests: [])

        do {
            return try await runStructured(state: state, tools: tools, fileRun: nil, progress: progress)
        } catch RoutingSignal.browserTools {
            if nativeFileRun?.rootTaskID == taskID { throw AppleFoundationMCPPlannerError.noProposal }
            try checkExecutionCancellation()
            progress("Continuing with browser tools…")
            return try await executeVisualFallback(usingBrowser: true)
        } catch RoutingSignal.desktopTools {
            if nativeFileRun?.rootTaskID == taskID { throw AppleFoundationMCPPlannerError.noProposal }
            try checkExecutionCancellation()
            progress("Continuing with local app controls…")
            return try await executeVisualFallback()
        } catch is CancellationError {
            throw CancellationError()
        } catch AppleFoundationMCPPlannerError.cancelled {
            throw CancellationError()
        } catch let error as ComputerUsePlanningWorker.Failure {
            // An expired or still-running proposal cannot authorize another
            // planner or visual fallback.
            throw error
        } catch let error as AppleFoundationMCPPlannerError {
            if nativeFileRun?.rootTaskID == taskID { throw error }
            guard Self.canTryNativeAlternative(after: error) else { throw error }
            return try await executeNativeAlternative(after: error)
        } catch let error as ExecutorError {
            if nativeFileRun?.rootTaskID == taskID { throw error }
            guard error == .tooManySteps else { throw error }

            // Repeating a native read does not show that its capability is
            // insufficient. Only a restricted native alternative may run.
            return try await executeNativeAlternative(after: error)
        }
    }

    func continueAfterApproval(
        _ prepared: MCPPreparedApproval,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> MCPApprovedActionResult {
        try beginExecution()
        defer { activeExecutionEpoch = nil }
        try Task.checkCancellation()
        if let run = documentRun, run.contract.taskID == prepared.call.taskID {
            return try await performDocumentAction(prepared, run: run, tools: tools, progress: progress)
        }
        guard let state = pendingApprovalState,
              pendingApprovalDigest == prepared.call.canonicalDigest,
              prepared.call.taskID == state.taskID else {
            throw ExecutorError.approvalStateChanged
        }
        let fileRun = nativeFileRun?.currentTaskID == prepared.call.taskID ? nativeFileRun : nil
        if let fileRun, fileRun.selectedCandidate != nil {
            try validateFileApprovalForContinuation(prepared.call, state: state, run: fileRun)
            try tools.requireActive()
        } else if fileRun != nil {
            throw ExecutorError.approvalStateChanged
        }
        pendingApprovalState = nil
        pendingApprovalDigest = nil

        let generation = prepared.call.processGeneration
        return try await withGenerationCancellation(generation: generation, preserveCompletedResultOnCancellation: true) {
            try checkGenerationCancellation(generation)
            try tools.requireActive()
            if let fileRun, fileRun.selectedCandidate != nil {
                try validateFileApprovalForContinuation(prepared.call, state: state, run: fileRun)
            } else if fileRun != nil {
                throw ExecutorError.approvalStateChanged
            }
            progress("Performing the one approved Mac action…")
            let result = try await clientPool.performApproved(
                prepared.call,
                fingerprint: prepared.fingerprint)
            guard !result.isError else {
                throw ExecutorError.structuredToolFailed(
                    Self.boundedFailure(result.text))
            }
            // Return only a typed action fact. The host records it before
            // deciding whether the original task has a whole-goal proof.
            // Planner prose and arbitrary tool text cannot manufacture one.
            return try MCPApprovedActionResult.verified(call: prepared.call,
                result: result, trustedUserPrompt: state.trustedUserPrompt)
        }
    }

    func preflightApprovedAction(_ prepared: MCPPreparedApproval) async throws {
        try beginExecution()
        defer { activeExecutionEpoch = nil }
        try Task.checkCancellation()

        if let run = documentRun, run.prepared == prepared,
           run.contract.taskID == prepared.call.taskID {
            return
        }
        guard let state = pendingApprovalState,
              pendingApprovalDigest == prepared.call.canonicalDigest,
              prepared.call.taskID == state.taskID,
              prepared.call.risk == .approvalRequired,
              prepared.fingerprint.matches(call: prepared.call) else {
            throw ExecutorError.approvalStateChanged
        }
        let fileRun = nativeFileRun?.currentTaskID == prepared.call.taskID ? nativeFileRun : nil
        if let fileRun, fileRun.selectedCandidate != nil {
            try validateFileApprovalForContinuation(prepared.call, state: state, run: fileRun)
            try fileRun.tools.requireActive()
        } else if fileRun != nil {
            throw ExecutorError.approvalStateChanged
        }
        let generation = prepared.call.processGeneration
        try await withGenerationCancellation(generation: generation) {
            try checkGenerationCancellation(generation)
            if let fileRun, fileRun.selectedCandidate != nil {
                try validateFileApprovalForContinuation(prepared.call, state: state, run: fileRun)
                try fileRun.tools.requireActive()
            } else if fileRun != nil {
                throw ExecutorError.approvalStateChanged
            }
            try await clientPool.preflightApproved(
                prepared.call,
                fingerprint: prepared.fingerprint)
            try checkGenerationCancellation(generation)
            if let fileRun, fileRun.selectedCandidate != nil {
                try fileRun.tools.requireActive()
                try validateFileApprovalForContinuation(prepared.call, state: state, run: fileRun)
            } else if fileRun != nil {
                throw ExecutorError.approvalStateChanged
            }
        }
    }

    func clarification(taskID: String) throws -> ComputerUseNativeTextExecutor.Clarification? {
        if let pending = pendingStructuredClarification,
           pending.info.taskID == taskID, pending.info.expiresAt > Date() {
            return pending.info
        }
        if let run = nativeFileRun, !run.invalidated,
           let pending = run.pendingClarification,
           pending.taskID == taskID, pending.expiresAt > Date() {
            return pending
        }
        return try (retainedExecutor as? any ComputerUseTextClarificationContinuing)?.clarification(taskID: taskID)
    }

    func invalidateClarification(taskID: String?) {
        if let route = retainedStructuredRoute,
           taskID == nil || taskID == route.taskID || taskID == route.originatingTaskID {
            (retainedExecutor as? any ComputerUseTextClarificationContinuing)?.invalidateClarification(taskID: route.taskID)
            retainedStructuredRoute = nil
            if retainedFallback?.taskID == route.taskID { retainedFallback = nil }
        }
        if let pending = pendingStructuredClarification,
           taskID == nil || taskID == pending.info.taskID || taskID == pending.rootTaskID {
            pendingStructuredClarification = nil
        }
        if let run = nativeFileRun,
           taskID == nil || taskID == run.rootTaskID || taskID == run.currentTaskID
                || taskID == run.pendingClarification?.taskID {
            run.invalidated = true
            run.pendingClarification = nil
            run.choicesByID.removeAll()
            run.selectedCandidate = nil
            run.selectedPath = nil
            nativeFileRun = nil
        }
        (retainedExecutor as? any ComputerUseTextClarificationContinuing)?.invalidateClarification(taskID: taskID)
    }

    func continueClarification(taskID: String, originatingTaskID: String, goal: ComputerUseUnresolvedTextGoal,
                               progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        if let route = retainedStructuredRoute {
            if route.taskID == taskID && route.originatingTaskID == originatingTaskID && route.goal == goal {
                try beginExecution()
                defer { activeExecutionEpoch = nil }
                try await waitForStartedCancellation()
                try checkExecutionCancellation()
                try route.tools.requireActive()
                return try await executeRetainedStructuredRoute(route, progress: progress)
            }
            guard originatingTaskID == route.taskID, taskID != originatingTaskID,
                  let continuing = retainedExecutor as? any ComputerUseTextClarificationContinuing,
                  let nested = try continuing.clarification(taskID: originatingTaskID),
                  nested.choices == nil, goal.userTurns.first == nested.goal.userTurns.first,
                  let answer = goal.userTurns.last,
                  try nested.goal.answering(nested.question, with: answer) == goal else {
                throw ExecutorError.visualApprovalContinuationUnavailable
            }
            // The nested executor owns this new question; only after its pending
            // state and exact answer validate may the original route be retired.
            retainedStructuredRoute = nil
        }
        if let pending = pendingStructuredClarification {
            guard pending.info.taskID == originatingTaskID else {
                throw ExecutorError.visualApprovalContinuationUnavailable
            }
            try beginExecution()
            defer { activeExecutionEpoch = nil }
            try await waitForStartedCancellation()
            let answer = goal.userTurns.last
            guard taskID != originatingTaskID, pending.info.expiresAt > Date(),
                  pending.info.choices == nil, goal.userTurns.first == pending.state.trustedUserPrompt,
                  let answer, try pending.info.goal.answering(pending.info.question, with: answer) == goal,
                  pending.state.taskID == originatingTaskID else {
                throw ExecutorError.visualApprovalContinuationUnavailable
            }
            try pending.tools.requireActive()
            try checkExecutionCancellation()
            if let fileRun = pending.fileRun {
                guard !fileRun.invalidated, fileRun.rootTaskID == pending.rootTaskID,
                      fileRun.currentTaskID == originatingTaskID,
                      let retainedRun = nativeFileRun, retainedRun === fileRun else {
                    throw ExecutorError.visualApprovalContinuationUnavailable
                }
            }
            pendingStructuredClarification = nil
            var state = pending.state.withTaskID(taskID)
            state.clarificationGoal = goal
            if let fileRun = pending.fileRun {
                guard !fileRun.invalidated, fileRun.currentTaskID == originatingTaskID else {
                    throw ExecutorError.visualApprovalContinuationUnavailable
                }
                fileRun.currentTaskID = taskID
                fileRun.planningState = state
                nativeFileRun = fileRun
            }
            do {
                return try await runStructured(state: state, tools: pending.tools,
                    fileRun: pending.fileRun, progress: progress)
            } catch RoutingSignal.browserTools {
                try checkExecutionCancellation()
                guard pending.fileRun == nil, nativeFileRun?.rootTaskID != pending.rootTaskID else {
                    throw AppleFoundationMCPPlannerError.noProposal
                }
                return try await retainAndRunStructuredRoute(taskID: taskID,
                    originatingTaskID: originatingTaskID, goal: goal, tools: pending.tools,
                    usesBrowser: true, progress: progress)
            } catch RoutingSignal.desktopTools {
                try checkExecutionCancellation()
                guard pending.fileRun == nil, nativeFileRun?.rootTaskID != pending.rootTaskID else {
                    throw AppleFoundationMCPPlannerError.noProposal
                }
                return try await retainAndRunStructuredRoute(taskID: taskID,
                    originatingTaskID: originatingTaskID, goal: goal, tools: pending.tools,
                    usesBrowser: false, progress: progress)
            }
        }
        if nativeFileRun?.pendingClarification?.taskID == originatingTaskID {
            throw ExecutorError.visualApprovalContinuationUnavailable
        }
        try beginExecution()
        defer { activeExecutionEpoch = nil }
        try await waitForStartedCancellation()
        guard let continuing = retainedExecutor as? any ComputerUseTextClarificationContinuing else { throw ExecutorError.visualApprovalContinuationUnavailable }
        let digest = ComputerUseTextTaskContract.digest(goal.taskIdentityText)
        guard taskID != originatingTaskID else { throw ExecutorError.visualApprovalContinuationUnavailable }
        if retainedFallback?.taskID == taskID {
            guard retainedFallback?.promptDigest == digest else { throw ExecutorError.taskChanged }
        } else {
            guard retainedFallback?.taskID == originatingTaskID,
                  let pending = try continuing.clarification(taskID: originatingTaskID),
                  let answer = goal.userTurns.last,
                  try pending.goal.answering(pending.question, with: answer) == goal else {
                throw ExecutorError.visualApprovalContinuationUnavailable
            }
            // A validated answer transfers the same fallback session to its
            // new request ID before that continuation can perform any work.
            retainedFallback = (taskID, digest)
        }
        if retainedBrowserIntentContract?.contract.goal != goal {
            retainedBrowserIntentContract = nil
            retainedBrowserVisits = nil
        }
        if let tools = browserTools {
            return try await withBrowserToolProposals(taskID: originatingTaskID, tools: tools) {
                try await continuing.continueClarification(taskID: taskID, originatingTaskID: originatingTaskID, goal: goal, progress: progress)
            }
        }
        return try await continuing.continueClarification(taskID: taskID, originatingTaskID: originatingTaskID, goal: goal, progress: progress)
    }

    private func retainAndRunStructuredRoute(taskID: String, originatingTaskID: String,
        goal: ComputerUseUnresolvedTextGoal, tools: ComputerUseHostTools, usesBrowser: Bool,
        progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        try checkExecutionCancellation()
        try tools.requireActive()
        let route = RetainedStructuredRoute(originatingTaskID: originatingTaskID,
            taskID: taskID, goal: goal, tools: tools, usesBrowser: usesBrowser)
        retainedStructuredRoute = route
        retainedFallback = (taskID, ComputerUseTextTaskContract.digest(goal.taskIdentityText))
        retainedNativeFailure = nil
        retainedUsesBrowser = usesBrowser
        if !usesBrowser { retainedBrowserExecutor = nil }
        return try await executeRetainedStructuredRoute(route, progress: progress)
    }

    private func executeRetainedStructuredRoute(_ route: RetainedStructuredRoute,
        progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        try checkExecutionCancellation()
        try route.tools.requireActive()
        let target: any ComputerUseExecuting
        if route.usesBrowser {
            if retainedBrowserExecutor == nil {
                try checkExecutionCancellation()
                let candidate = try await browserExecutorFactory()
                try checkExecutionCancellation()
                retainedBrowserExecutor = candidate
            }
            guard let browser = retainedBrowserExecutor else {
                return .userInterventionRequired("The browser route could not retain its task executor. Resume the same task or start a new one.")
            }
            target = browser
        } else {
            target = visualFallback
        }
        guard let clarified = target as? any ComputerUseClarifiedGoalExecuting else {
            return .userInterventionRequired("I can't continue this task in the selected app. Start a new task using a supported app.")
        }
        try checkExecutionCancellation()
        try route.tools.requireActive()
        let result: ComputerUseExecutionResult
        if route.usesBrowser {
            result = try await withBrowserToolProposals(taskID: route.taskID, tools: route.tools) {
                try await clarified.execute(taskID: route.taskID, goal: route.goal,
                    tools: route.tools, progress: progress)
            }
        } else {
            result = try await clarified.execute(taskID: route.taskID, goal: route.goal,
                tools: route.tools, progress: progress)
        }
        try checkExecutionCancellation()
        switch result {
        case .completed, .unableToComplete:
            retainedStructuredRoute = nil
        default:
            retainedStructuredRoute = route
        }
        return result
    }

    func continueClarification(taskID: String, originatingTaskID: String, goal: ComputerUseUnresolvedTextGoal,
                               selectedChoice: ComputerUseClarificationChoice?,
                               progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        if let route = retainedStructuredRoute, let selectedChoice {
            guard originatingTaskID == route.taskID, taskID != originatingTaskID,
                  let continuing = retainedExecutor as? any ComputerUseTextClarificationContinuing,
                  let pending = try continuing.clarification(taskID: originatingTaskID),
                  pending.goal == goal, pending.choices?.contains(selectedChoice) == true else {
                throw ExecutorError.visualApprovalContinuationUnavailable
            }
            retainedStructuredRoute = nil
        }
        if let pending = pendingStructuredClarification, var recipients = pending.mailRecipients,
           let selectedChoice {
            try beginExecution()
            defer { activeExecutionEpoch = nil }
            try await waitForStartedCancellation()
            guard taskID != originatingTaskID, pending.info.taskID == originatingTaskID,
                  pending.state.taskID == originatingTaskID, pending.info.expiresAt > Date(),
                  pending.info.goal == goal, pending.info.choices?.contains(selectedChoice) == true,
                  let address = recipients.addressesByChoiceID[selectedChoice.id] else {
                throw ExecutorError.visualApprovalContinuationUnavailable
            }
            try pending.tools.requireActive()
            try checkExecutionCancellation()
            try recipients.resolver.select(address: address, field: recipients.field, index: recipients.index)
            pendingStructuredClarification = nil
            let state = pending.state.withTaskID(taskID)
            if let run = pending.fileRun {
                guard !run.invalidated, run.currentTaskID == originatingTaskID,
                      nativeFileRun === run else { throw ExecutorError.approvalStateChanged }
                run.currentTaskID = taskID
                run.planningState = state
            }
            return try await runStructured(state: state, tools: pending.tools, fileRun: pending.fileRun,
                mailRecipients: recipients.resolver, progress: progress)
        }
        if pendingStructuredClarification != nil, selectedChoice != nil {
            throw ExecutorError.visualApprovalContinuationUnavailable
        }
        guard let selectedChoice else {
            return try await continueClarification(taskID: taskID, originatingTaskID: originatingTaskID,
                goal: goal, progress: progress)
        }
        if let run = nativeFileRun, let pending = run.pendingClarification,
           pending.taskID == originatingTaskID {
            try beginExecution()
            defer { activeExecutionEpoch = nil }
            try await waitForStartedCancellation()
            guard !run.invalidated, taskID != originatingTaskID,
                  run.currentTaskID == originatingTaskID,
                  pending.taskID == originatingTaskID,
                  pending.expiresAt > Date(), pending.goal == goal,
                  pending.choices?.contains(selectedChoice) == true,
                  let candidate = run.choicesByID[selectedChoice.id] else {
                throw ExecutorError.visualApprovalContinuationUnavailable
            }
            try run.tools.requireActive()
            let selectedURL: URL
            do {
                guard let catalog = run.catalog else { throw ExecutorError.approvalStateChanged }
                let resolved = try canonicalNativeFileURL(
                    catalog.resolve(candidateID: candidate.id, taskID: run.rootTaskID))
                let rechecked = try canonicalNativeFileURL(
                    catalog.resolve(candidateID: candidate.id, taskID: run.rootTaskID))
                guard resolved.path == rechecked.path else { throw ExecutorError.approvalStateChanged }
                selectedURL = resolved
            }
            catch {
                run.pendingClarification = nil
                run.choicesByID.removeAll()
                return .userInterventionRequired("The chosen file changed. Search Downloads again before attaching it.")
            }
            run.selectedCandidate = candidate
            run.selectedPath = selectedURL
            run.selectedByUserCandidateID = candidate.id
            run.selectedByUserPath = selectedURL
            run.context = .init(query: run.context.query, page: run.context.page,
                selectedCandidate: candidate,
                nameFilterWasBroadened: run.context.nameFilterWasBroadened)
            run.currentTaskID = taskID
            run.pendingClarification = nil
            run.choicesByID.removeAll()
            nativeFileRun = run
            let state = run.planningState.withTaskID(taskID)
            run.planningState = state
            return try await runStructured(state: state, tools: run.tools, fileRun: run, progress: progress)
        }
        try beginExecution()
        defer { activeExecutionEpoch = nil }
        try await waitForStartedCancellation()
        guard let continuing = retainedExecutor as? any ComputerUseTextClarificationContinuing else {
            throw ExecutorError.visualApprovalContinuationUnavailable
        }
        let digest = ComputerUseTextTaskContract.digest(goal.taskIdentityText)
        guard taskID != originatingTaskID else { throw ExecutorError.visualApprovalContinuationUnavailable }
        if retainedFallback?.taskID == taskID {
            guard retainedFallback?.promptDigest == digest else { throw ExecutorError.taskChanged }
        } else {
            guard retainedFallback?.taskID == originatingTaskID,
                  let pending = try continuing.clarification(taskID: originatingTaskID),
                  pending.goal == goal, pending.choices?.contains(selectedChoice) == true else {
                throw ExecutorError.visualApprovalContinuationUnavailable
            }
            retainedFallback = (taskID, digest)
        }
        if retainedBrowserIntentContract?.contract.goal != goal {
            retainedBrowserIntentContract = nil
            retainedBrowserVisits = nil
        }
        if let tools = browserTools {
            return try await withBrowserToolProposals(taskID: originatingTaskID, tools: tools) {
                try await continuing.continueClarification(taskID: taskID, originatingTaskID: originatingTaskID,
                    goal: goal, selectedChoice: selectedChoice, progress: progress)
            }
        }
        return try await continuing.continueClarification(taskID: taskID, originatingTaskID: originatingTaskID,
            goal: goal, selectedChoice: selectedChoice, progress: progress)
    }

    func performApprovedVisualAction(_ continuation: ComputerUseVisualApprovalContinuation,
        action: ComputerUsePredictedAction, fingerprint: ComputerUseApprovalFingerprint,
        tools: ComputerUseHostTools, willBeginEffect: () -> Void) async throws {
        try beginExecution()
        defer { activeExecutionEpoch = nil }
        try await waitForStartedCancellation()
        guard let visual = retainedExecutor as? any ComputerUseVisualApprovalContinuing else {
            throw ExecutorError.visualApprovalContinuationUnavailable
        }
        try await visual.performApprovedVisualAction(continuation, action: action,
            fingerprint: fingerprint, tools: tools, willBeginEffect: willBeginEffect)
    }

    /// Preserve the visual executor's typed, process-local continuation even
    /// when this hybrid wrapper selected the fallback path. Approval resume is
    /// deliberately not an ordinary execute call: re-entering the structured
    /// planner could lose the visual ledger or repeat the approved action.
    func continueAfterApprovedVisualAction(
        _ continuation: ComputerUseVisualApprovalContinuation,
        action: ComputerUsePredictedAction,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        try beginExecution()
        defer { activeExecutionEpoch = nil }
        try await waitForStartedCancellation()
        guard let visualContinuation = retainedExecutor
            as? any ComputerUseVisualApprovalContinuing else {
            throw ExecutorError.visualApprovalContinuationUnavailable
        }
        return try await withBrowserToolProposals(taskID: continuation.taskID, tools: tools) {
            try await visualContinuation.continueAfterApprovedVisualAction(continuation,
                action: action, tools: tools, progress: progress)
        }
    }

    func cancelVisualApprovalContinuation(
        _ continuation: ComputerUseVisualApprovalContinuation
    ) {
        (retainedExecutor as? any ComputerUseVisualApprovalContinuing)?
            .cancelVisualApprovalContinuation(continuation)
    }

    private func withBrowserToolProposals(taskID: String, tools: ComputerUseHostTools,
        operation: () async throws -> ComputerUseExecutionResult) async throws -> ComputerUseExecutionResult {
        browserTools = tools
        let rootID = tools.ownedBrowserTaskID(forExecution: taskID)
        return try await tools.withOwnedBrowserToolProposals(taskID: rootID, propose: { [self] input, observation in
            try await proposeBrowserToolStep(input, observation: observation, rootTaskID: rootID, tools: tools)
        }, operation: operation)
    }

    private static func nativeDirectReadCompletion(
        plan: ComputerUseMCPBrowserStepPlanner.Plan,
        completion: ComputerUseMCPBrowserStepPlanner.Plan.DirectCompletion,
        context: ComputerUseMCPBrowserStepPlanner.Context,
        observation: ComputerUseOwnedBrowser.AgentObservation,
        proposal: ComputerUseFaraModel.Proposal,
        rootTaskID: String,
        retainedVisits: RetainedBrowserVisits?
    ) throws -> NativeReadCompletion {
        let currentDocument = observation.approvalPageEvidence.document
        guard plan.kind == .answer, !context.isPartialRecordView,
              completion.goal == context.userGoal, completion.sessionIdentity == observation.sessionIdentity,
              context.sessionIdentity == observation.sessionIdentity, context.currentDocument == currentDocument,
              currentDocument.taskID == rootTaskID,
              context.evidenceReferences["source"] == observation.currentURL.absoluteString,
              (1...8).contains(completion.outcomes.count), completion.constraints.count <= 8,
              !completion.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
        }
        var nativeReferences = ["source": observation.currentURL.absoluteString]
        for text in observation.approvalPageEvidence.page.texts {
            nativeReferences["text:\(text.id)"] = text.text
            if let tooltip = text.tooltip { nativeReferences["tooltip:\(text.id)"] = tooltip }
        }
        for link in observation.approvalPageEvidence.page.links { nativeReferences["link:\(link.id)"] = link.label }
        nativeReferences.merge(try ComputerUseMCPBrowserStepPlanner.currentNativeReadingBlockEvidence(
            for: observation.approvalPageEvidence.page)) { _, current in current }

        var selected = Set<String>()
        var effectURLs = Set<String>()
        var verifiedEffectLiterals: [String] = []
        for outcome in completion.outcomes {
            switch outcome.kind {
            case .information:
                guard !outcome.evidenceReferences.isEmpty else {
                    throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
                }
                selected.formUnion(outcome.evidenceReferences)
            case .action:
                guard outcome.evidenceReferences.isEmpty, outcome.effectProof != nil else {
                    throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
                }
            }
            if let proof = outcome.effectProof {
                switch proof {
                case .openURL(let visit):
                    effectURLs.insert(visit.requestedURL.absoluteString)
                    effectURLs.insert(visit.committedURL.absoluteString)
                    guard visit.source == .automationNavigation, visit.taskID == rootTaskID,
                          visit.contextID == currentDocument.contextID,
                          let scope = retainedVisits, scope.rootTaskID == rootTaskID,
                          scope.goal == completion.goal, scope.sessionIdentity == observation.sessionIdentity,
                          context.retainedVisits.count <= 64, context.retainedVisits == scope.documents,
                          scope.documents.contains(visit) else {
                        throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
                    }
                case .nativeGET(let submission):
                    effectURLs.insert(submission.receipt.document.requestedURL.absoluteString)
                    effectURLs.insert(submission.receipt.document.committedURL.absoluteString)
                    guard submission.taskID == rootTaskID,
                          submission.goalDigest == ComputerUseTaskContract.digest([completion.goal.taskIdentityText]),
                          submission.sessionIdentity == observation.sessionIdentity,
                          submission.receipt.document.taskID == rootTaskID,
                          submission.receipt.document.contextID == currentDocument.contextID,
                          submission.receipt.document.operationID == ComputerUseTaskContract.digest([submission.operationID, "form-navigation"]),
                          context.observedNativeGETSubmissions.count <= 64,
                          context.observedNativeGETSubmissions.contains(submission),
                          let scope = retainedVisits, scope.rootTaskID == rootTaskID,
                          scope.goal == completion.goal, scope.sessionIdentity == observation.sessionIdentity else {
                        throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
                    }
                case .fileSuppliedToPage(let supply):
                    guard supply.taskID == rootTaskID,
                          supply.goalDigest == ComputerUseTaskContract.digest([completion.goal.taskIdentityText]),
                          supply.sessionIdentity == observation.sessionIdentity,
                          supply.document.taskID == rootTaskID,
                          supply.document.contextID == currentDocument.contextID,
                          supply.document.generation <= currentDocument.generation,
                          !supply.operationKey.isEmpty, !supply.pageEvidenceID.isEmpty,
                          context.observedLocalFileSupplies.count <= 64,
                          context.observedLocalFileSupplies.contains(supply) else {
                        throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
                    }
                    verifiedEffectLiterals.append(supply.displayName)
                    verifiedEffectLiterals.append(String(supply.byteCount))
                }
            }
        }
        try ComputerUseMCPBrowserStepPlanner().validateAnswerClaims(plan.text, context: context,
            requiresEvidence: completion.outcomes.contains(where: { $0.kind == .information }),
            selectedReferences: selected, verifiedNavigationURLs: effectURLs,
            verifiedEffectLiterals: verifiedEffectLiterals)
        if selected.isEmpty { selected.insert("source") }
        for reference in selected {
            guard let contextValue = context.evidenceReferences[reference],
                  let pageValue = nativeReferences[reference],
                  contextValue.utf8.elementsEqual(pageValue.utf8) else {
                throw ComputerUseMCPBrowserStepPlanner.Failure.unsupportedAnswerClaim
            }
        }
        return NativeReadCompletion(proposal: proposal, authorityDigest: observation.authorityDigest,
            references: selected.sorted())
    }

    private static func nativeReadCompletion(
        plan: ComputerUseMCPBrowserStepPlanner.Plan,
        context: ComputerUseMCPBrowserStepPlanner.Context,
        observation: ComputerUseOwnedBrowser.AgentObservation,
        proposal: ComputerUseFaraModel.Proposal,
        rootTaskID: String,
        retainedVisits: RetainedBrowserVisits?
    ) throws -> NativeReadCompletion {
        guard plan.kind == .answer, !context.isPartialRecordView else {
            throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
        }
        if let completion = plan.directCompletion {
            return try nativeDirectReadCompletion(plan: plan, completion: completion, context: context,
                observation: observation, proposal: proposal, rootTaskID: rootTaskID, retainedVisits: retainedVisits)
        }
        guard let assessment = plan.assessment else { throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence }
        let page = observation.approvalPageEvidence.page
        let currentDocument = observation.approvalPageEvidence.document
        guard currentDocument.taskID == rootTaskID,
              context.evidenceReferences["source"] == observation.currentURL.absoluteString else {
            throw ComputerUseMCPBrowserStepPlanner.Failure.unsupportedAnswerClaim
        }
        let contract = plan.retainedContract ?? context.retainedContract
        if let contract {
            guard contract.goal == context.userGoal,
                  contract.requirements.count == assessment.requirements.count,
                  context.currentDocument == currentDocument else {
                throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
            }
        } else if assessment.requirements.contains(where: { $0.kind != .information }) {
            // Legacy callers without a retained intent contract may still
            // complete information-only tasks, but cannot assert effects.
            throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
        }
        var nativeReferences = ["source": observation.currentURL.absoluteString]
        for text in page.texts {
            nativeReferences["text:\(text.id)"] = text.text
            if let tooltip = text.tooltip { nativeReferences["tooltip:\(text.id)"] = tooltip }
        }
        for link in page.links { nativeReferences["link:\(link.id)"] = link.label }
        nativeReferences.merge(try ComputerUseMCPBrowserStepPlanner.currentNativeReadingBlockEvidence(for: page)) {
            _, current in current
        }
        var selected = Set<String>()
        if let contract {
            for (contractRequirement, assessmentRequirement) in zip(contract.requirements, assessment.requirements) {
                guard contractRequirement.kind.rawValue == assessmentRequirement.kind.rawValue,
                      contractRequirement.instruction.utf8.elementsEqual(assessmentRequirement.instruction.utf8) else {
                    throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
                }
                switch contractRequirement.kind {
                case .information:
                    guard assessmentRequirement.state == .observed,
                          !assessmentRequirement.evidenceReferences.isEmpty,
                          assessmentRequirement.navigationProof == nil else {
                        throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
                    }
                    selected.formUnion(assessmentRequirement.evidenceReferences)
                case .action:
                    guard assessmentRequirement.state == .observed,
                          assessmentRequirement.evidenceReferences.isEmpty,
                          assessmentRequirement.evidence.isEmpty,
                          let proof = assessmentRequirement.navigationProof,
                          let expectedEffect = contractRequirement.expectedEffect,
                          case .openURL(let expectedURL) = expectedEffect,
                          expectedURL.utf8.elementsEqual(proof.requestedURL.absoluteString.utf8),
                          proof.source == .automationNavigation,
                          proof.taskID == rootTaskID,
                          proof.contextID == currentDocument.contextID,
                          let visitScope = retainedVisits,
                          visitScope.rootTaskID == rootTaskID,
                          visitScope.goal == contract.goal,
                          visitScope.sessionIdentity == observation.sessionIdentity,
                          context.retainedVisits.count <= 64,
                          context.retainedVisits == visitScope.documents,
                          visitScope.documents.contains(proof) else {
                        throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
                    }
                }
            }
        } else {
            guard assessment.requirements.allSatisfy({ $0.kind == .information && $0.state == .observed && !$0.evidenceReferences.isEmpty }) else {
                throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
            }
            selected.formUnion(assessment.requirements.flatMap(\.evidenceReferences))
        }
        if selected.isEmpty {
            // Even action-only completion remains bound to a live current
            // source observation, rather than bypassing freshness checks.
            selected.insert("source")
        }
        for reference in selected {
            guard let contextValue = context.evidenceReferences[reference],
                  let pageValue = nativeReferences[reference],
                  contextValue.utf8.elementsEqual(pageValue.utf8) else {
                throw ComputerUseMCPBrowserStepPlanner.Failure.unsupportedAnswerClaim
            }
        }
        for requirement in assessment.requirements where requirement.kind == .information {
            let selectedEvidence = requirement.evidenceReferences.compactMap { context.evidenceReferences[$0] }.joined(separator: "\n")
            guard selectedEvidence.utf8.elementsEqual(requirement.evidence.utf8) else {
                throw ComputerUseMCPBrowserStepPlanner.Failure.unsupportedAnswerClaim
            }
        }
        return NativeReadCompletion(proposal: proposal, authorityDigest: observation.authorityDigest,
            references: selected.sorted())
    }

    static func localFileToolPlan(_ plan: ComputerUseMCPBrowserStepPlanner.Plan,
                                  rootTaskID: String, sessionIdentity: String) throws -> ComputerUseFaraBrowserExecutor.ToolPlan? {
        guard plan.kind == .localFileOperation else { return nil }
        guard let operation = plan.localFileOperation,
              (1...256).contains(rootTaskID.utf8.count), (1...256).contains(sessionIdentity.utf8.count) else {
            throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
        }
        return .localFileOperation(operation, rootTaskID: rootTaskID, sessionIdentity: sessionIdentity)
    }

    private func proposeBrowserToolStep(_ input: ComputerUseFaraModel.Input,
        observation: ComputerUseFaraBrowserExecutor.ToolObservation,
        rootTaskID: String,
        tools: ComputerUseHostTools) async throws -> ComputerUseFaraBrowserExecutor.ToolPlan {
        try checkExecutionCancellation()
        guard observation.taskID == rootTaskID else {
            throw ExecutorError.taskChanged
        }
        let goal = try input.validatedBrowserGoal()
        let currentSessionIdentity: String
        switch observation {
        case .initial(let initial):
            try tools.validateOwnedBrowserInitialAgentObservation(initial)
            currentSessionIdentity = initial.sessionIdentity
        case .page(let page):
            try tools.validateOwnedBrowserAgentMemoryObservation(page)
            guard page.approvalPageEvidence.document.taskID == rootTaskID,
                  input.currentURL == page.currentURL else {
                throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
            }
            currentSessionIdentity = page.sessionIdentity
        }
        let changedSession = retainedBrowserVisits != nil
            && retainedBrowserVisits?.sessionIdentity != currentSessionIdentity
        if retainedBrowserVisits?.rootTaskID != rootTaskID
            || retainedBrowserVisits?.goal != goal
            || retainedBrowserVisits?.sessionIdentity != currentSessionIdentity {
            retainedBrowserVisits = RetainedBrowserVisits(rootTaskID: rootTaskID, goal: goal,
                sessionIdentity: currentSessionIdentity, documents: [])
            if changedSession || retainedBrowserIntentContract?.rootTaskID != rootTaskID
                || retainedBrowserIntentContract?.contract.goal != goal {
                retainedBrowserIntentContract = nil
            }
        }
        if case .page(let page) = observation {
            let document = page.approvalPageEvidence.document
            guard document.contextID.isEmpty == false,
                  document.taskID == rootTaskID,
                  document.committedURL == page.currentURL else {
                throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
            }
            if document.source == .automationNavigation,
               var retained = retainedBrowserVisits,
               retained.rootTaskID == rootTaskID,
               retained.goal == goal,
               retained.sessionIdentity == currentSessionIdentity,
               !retained.documents.contains(document) {
                retained.documents.append(document)
                if retained.documents.count > 64 {
                    retained.documents.removeFirst(retained.documents.count - 64)
                }
                retainedBrowserVisits = retained
            }
        }
        let matchingContract: ComputerUseBrowserIntentContract?
        if let retained = retainedBrowserIntentContract,
           retained.rootTaskID == rootTaskID, retained.contract.goal == goal {
            matchingContract = retained.contract
        } else {
            // A changed task or accepted-goal revision must not reuse clauses
            // from the previous immutable interpretation.
            retainedBrowserIntentContract = nil
            if retainedBrowserVisits?.rootTaskID != rootTaskID || retainedBrowserVisits?.goal != goal {
                retainedBrowserVisits = nil
            }
            matchingContract = nil
        }
        let available = try await clientPool.allowedTools()
        try checkExecutionCancellation()
        guard observation.taskID == rootTaskID else {
            throw ExecutorError.taskChanged
        }
        guard ["find_elements", "get_element_attributes"].allSatisfy({ name in
            available.contains { $0.toolName == name && $0.risk == .readOnly && $0.serverID == MCPServerRegistry.macControl.serverID }
        }) else { return .noProposal }
        switch observation {
        case .initial(let initial): try tools.validateOwnedBrowserInitialAgentObservation(initial)
        case .page(let page): try tools.validateOwnedBrowserAgentMemoryObservation(page)
        }
        let browserPlanner = browserStepPlanner
        // A host context/schema limit is an integration failure, not evidence
        // that Mac tools cannot handle this task. It must not activate vision.
        let (plan, context) = try await browserPlanner.next(input, observation: observation,
            retainedContract: matchingContract,
            retainedVisits: retainedBrowserVisits?.documents ?? [])
        try checkExecutionCancellation()
        guard observation.taskID == rootTaskID else {
            throw ExecutorError.taskChanged
        }
        switch observation {
        case .initial(let initial): try tools.validateOwnedBrowserInitialAgentObservation(initial)
        case .page(let page): try tools.validateOwnedBrowserAgentMemoryObservation(page)
        }
        if let returnedContract = plan.retainedContract {
            guard returnedContract.goal == goal else {
                throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
            }
            if let matchingContract {
                guard returnedContract == matchingContract else {
                    throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
                }
            } else {
                retainedBrowserIntentContract = (rootTaskID, returnedContract)
            }
        } else if matchingContract != nil {
            // Once the managed local planner establishes an immutable intent,
            // a later planner step cannot silently drop it. Initial Apple
            // navigation may precede the managed local page planner.
            throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
        }
        if plan.kind == .nativeFormSubmission {
            guard case .page(let page) = observation, let submission = plan.formSubmission else {
                throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
            }
            return .nativeFormSubmission(plan: submission, authorityDigest: page.authorityDigest)
        }
        if let fileToolPlan = try Self.localFileToolPlan(plan, rootTaskID: rootTaskID,
            sessionIdentity: currentSessionIdentity) {
            return fileToolPlan
        }
        let arguments: [String: Any]
        switch plan.kind {
        case .nativeFormSubmission, .localFileOperation: throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
        case .inspectRecords: throw AppleFoundationMCPPlannerError.unknownProposal
        case .visualFallback:
            guard let assessment = plan.assessment else { throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence }
            return .handoff(try assessment.workerDirective())
        case .search:
            guard !plan.text.isEmpty, plan.text.utf8.count <= 1024 else { throw AppleFoundationMCPPlannerError.unknownProposal }
            arguments = ["action": "web_search", "query": plan.text]
        case .openLink:
            let destination: URL
            if let userURL = context.userURLs[plan.reference] { destination = userURL }
            else {
                guard case .page(let page) = observation, let link = context.links[plan.reference],
                      let verified = try await readBrowserLinkWithMCP(link, observation: page, tools: tools) else { return .noProposal }
                destination = verified
            }
            arguments = ["action": "visit_url", "url": destination.absoluteString]
        case .answer, .incomplete:
            let hasPage: Bool
            if case .page = observation { hasPage = true } else { hasPage = false }
            try Self.validateBrowserCompletion(plan: plan, goal: input.validatedBrowserGoal(), hasPageObservation: hasPage)
            arguments = ["action": "terminate", "answer": plan.text]
        case .askUser:
            guard !plan.text.isEmpty, plan.text.utf8.count <= 1024 else { throw AppleFoundationMCPPlannerError.unknownProposal }
            arguments = ["action": "ask_user_question", "question": plan.text]
        case .wait:
            guard plan.text.isEmpty else { throw AppleFoundationMCPPlannerError.unknownProposal }
            arguments = ["action": "wait", "time": 1]
        }
        let body: [String: Any] = ["name": "computer_use", "arguments": arguments]
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e")
        let response = "<tool_call>" + encoded + "</tool_call>"
        let proposal = try ComputerUseFaraModel.Proposal(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
        if plan.kind == .answer, case .page(let page) = observation {
            return .nativeReadCompletion(try Self.nativeReadCompletion(plan: plan, context: context,
                observation: page, proposal: proposal, rootTaskID: rootTaskID,
                retainedVisits: retainedBrowserVisits))
        }
        return .proposal(proposal)
    }

    // Completion admission is separate from deciding whether native tools
    // have a capability gap. A rejected answer cannot authorize vision.
    static func validateBrowserCompletion(plan: ComputerUseMCPBrowserStepPlanner.Plan,
        goal: ComputerUseUnresolvedTextGoal, hasPageObservation: Bool) throws {
        // The orchestrator sees the exact full conversation in its context.
        // Code admits its bounded evidence contract; it does not reinterpret
        // the user's language with a second keyword classifier.
        try validateBrowserCompletion(plan: plan, goal: goal.taskIdentityText, hasPageObservation: hasPageObservation)
    }

    static func validateBrowserCompletion(plan: ComputerUseMCPBrowserStepPlanner.Plan, goal: String, hasPageObservation: Bool) throws {
        guard !plan.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppleFoundationMCPPlannerError.unknownProposal
        }
        if plan.kind == .incomplete { throw ExecutorError.structuredToolFailed(plan.text) }
        guard plan.kind == .answer, hasPageObservation else {
            throw AppleFoundationMCPPlannerError.unknownProposal
        }
        if let completion = plan.directCompletion {
            guard completion.goal.taskIdentityText.utf8.elementsEqual(goal.utf8),
                  (1...8).contains(completion.outcomes.count),
                  !completion.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  completion.outcomes.allSatisfy({ outcome in
                      switch outcome.kind {
                      case .information: return !outcome.evidenceReferences.isEmpty
                      case .action: return outcome.evidenceReferences.isEmpty && outcome.effectProof != nil
                      }
                  }) else {
                throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
            }
            return
        }
        guard let assessment = plan.assessment else {
            throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence
        }
        try assessment.validateCompletion()
    }

    // A missing accessible value is distinct from an invalid helper reply.
    // These decoders are shared with the native link read's admission tests.
    static func browserLinkDiscovery(_ result: MCPToolResult, pid: Int) throws -> (ids: [String], isComplete: Bool) {
        let invalid = ExecutorError.structuredToolFailed("The native browser link lookup returned an invalid or incomplete reply. The task has not completed.")
        guard !result.isError, !result.wasTruncated, case .object(let root)? = result.structuredContent,
              root["ok"] == .bool(true), root["pid"]?.exactInteger == pid,
              case .array(let rows)? = root["elements"], rows.count <= 8,
              root["count"]?.exactInteger == rows.count, case .bool(let limited)? = root["limit_reached"] else { throw invalid }
        var ids: [String] = []
        for row in rows {
            guard case .object(let item) = row, item["role"] == .string("AXLink"),
                  case .string(let id)? = item["id"], !id.isEmpty, !ids.contains(id) else { throw invalid }
            ids.append(id)
        }
        return (ids, !limited)
    }

    static func browserLinkAttributes(_ result: MCPToolResult, elementID: String) throws -> [String: MCPJSONValue]? {
        let invalid = ExecutorError.structuredToolFailed("The native browser link read returned an invalid or incomplete reply. The task has not completed.")
        guard !result.isError, !result.wasTruncated, case .object(let root)? = result.structuredContent,
              root["ok"] == .bool(true), root["element_id"] == .string(elementID),
              case .array(let unavailable)? = root["unavailable"],
              case .object(let values)? = root["values"] else { throw invalid }
        let requested: Set<String> = ["AXRole", "AXTitle", "AXURL"]
        var missing = Set<String>()
        for attribute in unavailable {
            guard case .string(let name) = attribute, requested.contains(name),
                  missing.insert(name).inserted, values[name] == nil else { throw invalid }
        }
        guard Set(values.keys).union(missing) == requested,
              values.values.allSatisfy({ if case .string = $0 { return true }; return false }) else { throw invalid }
        // Only an explicit, well-formed unavailable attribute is a capability
        // gap. Errors and omitted fields cannot manufacture that evidence.
        guard missing.isEmpty else { return nil }
        return values
    }

    func readBrowserLinkWithMCP(_ link: ComputerUseBrowserPageSnapshot.Link,
        observation: ComputerUseOwnedBrowser.AgentObservation, tools: ComputerUseHostTools) async throws -> URL? {
        let page = observation.approvalPageEvidence
        guard !link.label.isEmpty, page.page.links.filter({ $0.id == link.id }) == [link],
              let destination = URL(string: link.destination), ComputerUseOwnedBrowser.validatedURL(destination) != nil else { return nil }
        let textsByID = Dictionary(uniqueKeysWithValues: page.page.texts.map { ($0.id, $0.text) })
        var candidateLeaves: [(id: String, text: String)] = []
        for textID in link.textIDs {
            guard let text = textsByID[textID],
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !text.utf8.elementsEqual(link.label.utf8),
                  !candidateLeaves.contains(where: { $0.text.utf8.elementsEqual(text.utf8) }) else { continue }
            guard candidateLeaves.count < 4 else { break }
            candidateLeaves.append((textID, text))
        }
        let evidenceReferences = ["link:\(link.id)"] + candidateLeaves.map { "text:\($0.id)" }
        browserStepPlanner.inspectProposal?("Native link: \(link.label), \(destination.absoluteString)")
        return try await withNewHelperGeneration { generation in
            @MainActor func check() async throws {
                try checkGenerationCancellation(generation)
                try tools.validateOwnedBrowserAgentMemoryObservation(observation)
                // Verify only the selected link and the exact leaf strings used
                // for AX matching; unrelated page text may change during reading.
                try await tools.validateOwnedBrowserAgentReadCompletion(observation, references: evidenceReferences)
                try checkGenerationCancellation(generation)
            }
            try await check()
            let available = try await clientPool.allowedTools()
            try await check()
            func tool(_ name: String) -> MCPAllowedTool? {
                available.first { $0.toolName == name && $0.risk == .readOnly && $0.processGeneration == generation
                    && $0.serverID == MCPServerRegistry.macControl.serverID }
            }
            guard let find = tool("find_elements"), let read = tool("get_element_attributes") else { return nil }
            var sawPartialDiscovery = false
            @MainActor func discover(title: String) async throws -> (ids: [String], isComplete: Bool) {
                try await check()
                let found = try await clientPool.execute(find.makeCall(taskID: page.document.taskID, arguments: [
                    "pid": .integer(Int(ProcessInfo.processInfo.processIdentifier)), "role": .string("AXLink"),
                    "title": .string(title), "limit": .integer(8), "max_depth": .integer(30)]))
                if let inspect = browserStepPlanner.inspectProposal {
                    inspect("MCP find_elements: " + String(decoding: try JSONEncoder().encode(found), as: UTF8.self))
                }
                try await check()
                let discovery = try Self.browserLinkDiscovery(found, pid: Int(ProcessInfo.processInfo.processIdentifier))
                if !discovery.isComplete { sawPartialDiscovery = true }
                return (discovery.ids, discovery.isComplete)
            }
            @MainActor func verifiesDestination(ids: [String]) async throws -> Bool {
                for id in ids {
                    try await check()
                    let result = try await clientPool.execute(read.makeCall(taskID: page.document.taskID, arguments: [
                        "element_id": .string(id), "names": .array(["AXRole", "AXTitle", "AXURL"].map(MCPJSONValue.string))]))
                    if let inspect = browserStepPlanner.inspectProposal {
                        inspect("MCP get_element_attributes: " + String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
                    }
                    try await check()
                    guard let values = try Self.browserLinkAttributes(result, elementID: id),
                          values["AXRole"] == .string("AXLink"),
                          case .string(let actualURL)? = values["AXURL"],
                          actualURL.utf8.elementsEqual(destination.absoluteString.utf8) else { continue }
                    // Titles help retrieve AX candidates. This operation opens
                    // the captured URL directly and never clicks an AX node.
                    browserStepPlanner.inspectProposal?("MCP verified native link destination")
                    return true
                }
                return false
            }

            var compositeDiscovery = try await discover(title: link.label)
            if compositeDiscovery.ids.isEmpty && compositeDiscovery.isComplete {
                // A first AX read can expose an empty WebKit tree while
                // accessibility is being activated. Retry the same read
                // once; no failure, partial result or mutation is retried.
                try await Task.sleep(for: .milliseconds(150))
                try await check()
                compositeDiscovery = try await discover(title: link.label)
            }
            if try await verifiesDestination(ids: compositeDiscovery.ids) {
                return destination
            }

            for candidate in candidateLeaves {
                let discovery = try await discover(title: candidate.text)
                if try await verifiesDestination(ids: discovery.ids) {
                    return destination
                }
            }
            guard !sawPartialDiscovery else { throw ComputerUseMCPBrowserStepPlanner.Failure.incompleteEvidence }
            return nil
        }
    }

    func cancelMCPWork() {
        cancelMCPWork(clearBrowserProgress: true)
    }

    func pauseMCPWork() {
        cancelMCPWork(clearBrowserProgress: false)
    }

    private func cancelMCPWork(clearBrowserProgress: Bool) {
        // Invalidate a helper start that has not returned its generation yet,
        // including when no helper is currently published.
        cancellationEpoch &+= 1
        if clearBrowserProgress {
            retainedBrowserVisits = nil
            retainedBrowserIntentContract = nil
            nativeFileRun = nil
            pendingStructuredClarification = nil
            retainedStructuredRoute = nil
        }
        let generation = activeProcessGeneration
        activeProcessGeneration = nil
        pendingApprovalState = nil
        pendingApprovalDigest = nil
        documentRun?.prepared = nil
        guard let generation else { return }
        _ = cancellationJoin(for: generation).start()
    }

    private func beginExecution() throws {
        guard activeExecutionEpoch == nil else { throw ExecutorError.alreadyExecuting }
        try Task.checkCancellation()
        activeExecutionEpoch = cancellationEpoch
    }

    private var executionWasStopped: Bool {
        activeExecutionEpoch.map { $0 != cancellationEpoch } ?? false
    }

    private func checkExecutionCancellation() throws {
        try Task.checkCancellation()
        if executionWasStopped { throw CancellationError() }
    }

    private func cancellationJoin(for generation: UInt64) -> MCPGenerationCancellationJoin {
        if let activeCancellationJoin, activeCancellationJoin.generation == generation {
            return activeCancellationJoin
        }
        let join = MCPGenerationCancellationJoin(clientPool: clientPool, generation: generation)
        activeCancellationJoin = join
        return join
    }

    private func waitForStartedCancellation() async throws {
        await joinStartedCancellation()
        try checkExecutionCancellation()
    }

    private func joinStartedCancellation() async {
        if let join = activeCancellationJoin, let task = join.startedTask() {
            await task.value
            if activeCancellationJoin === join {
                activeCancellationJoin = nil
                if activeProcessGeneration == join.generation { activeProcessGeneration = nil }
            }
        }
    }

    private func checkGenerationCancellation(_ generation: UInt64) throws {
        try checkExecutionCancellation()
        if let join = activeCancellationJoin, join.generation == generation,
           join.startedTask() != nil {
            throw CancellationError()
        }
    }

    private func withGenerationCancellation<Result>(
        generation: UInt64,
        preserveCompletedResultOnCancellation: Bool = false,
        operation: () async throws -> Result
    ) async throws -> Result {
        let join = cancellationJoin(for: generation)
        do {
            let result = try await withTaskCancellationHandler {
                try await operation()
            } onCancel: { _ = join.start() }
            // A returned approved-action result remains a fact. Join cleanup
            // without turning that verified result into an unperformed action.
            if Task.isCancelled || executionWasStopped || join.startedTask() != nil {
                await join.start().value
                if !preserveCompletedResultOnCancellation { throw CancellationError() }
            }
            return result
        } catch {
            if error is CancellationError || Task.isCancelled || executionWasStopped || join.startedTask() != nil
                || error as? AppleFoundationMCPPlannerError == .cancelled
                || error as? MCPClientError == .cancelled {
                await join.start().value
                pendingApprovalState = nil
                pendingApprovalDigest = nil
                throw CancellationError()
            }
            throw error
        }
    }

    private func withNewHelperGeneration<Result>(
        operation: (UInt64) async throws -> Result
    ) async throws -> Result {
        try await waitForStartedCancellation()
        let identity: MCPProcessIdentity
        do { identity = try await clientPool.start(binaryURL: binaryURL) }
        catch {
            await joinStartedCancellation()
            try checkExecutionCancellation()
            if error as? MCPClientError == .cancelled { throw CancellationError() }
            throw error
        }
        // A Stop during start may have begun cleanup of the earlier helper.
        // Join it before recording the returned generation's separate owner.
        // Even a cancelled caller must then retire this returned generation.
        await joinStartedCancellation()
        activeProcessGeneration = identity.processGeneration
        helperReady = true
        return try await withGenerationCancellation(generation: identity.processGeneration) {
            try checkGenerationCancellation(identity.processGeneration)
            return try await operation(identity.processGeneration)
        }
    }

    func approvedActionPlan(taskID: String, promptBody: String) throws -> ComputerUseTaskLedger.ApprovedActionPlan? {
        guard let run = documentRun, run.contract.taskID == taskID else { return nil }
        let candidate = try ComputerUseTaskLedger.ApprovedActionPlan(contract: run.contract,
            promptBody: promptBody, calls: run.calls)
        if let previous = run.plan, previous != candidate { throw MCPClientError.approvalMismatch }
        run.plan = candidate
        return candidate
    }

    func continueApprovedActionPlan(taskID: String,
        confirmedActions: [ComputerUseTaskLedger.ApprovedActionRecord], tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        try beginExecution()
        defer { activeExecutionEpoch = nil }
        guard let run = documentRun, run.contract.taskID == taskID, run.plan != nil,
              !confirmedActions.isEmpty, confirmedActions.count == run.confirmed.count,
              confirmedActions.count <= run.calls.count else { throw MCPClientError.approvalMismatch }
        for (index, record) in confirmedActions.enumerated() {
            guard record.fingerprint.canonicalDigest == run.calls[index].canonicalDigest,
                  record.response == run.confirmed[index].response,
                  record.completionPromptDigest == nil else { throw MCPClientError.approvalMismatch }
        }
        try checkDocument(run, tools: tools, expected: run.edit.expected)
        if confirmedActions.count == run.calls.count {
            if run.edit.save {
                guard try ComputerUseMCPPlainDocument.read(run.document) == Data(run.edit.expected.utf8) else {
                    throw ExecutorError.structuredToolFailed("The saved document changed after confirmation.")
                }
            }
            return .completed(run.edit.save
                ? "The document is updated and saved, and its window is still open."
                : "The document is updated and its window is still open.")
        }
        // Resume can restart the helper after handoff, but never rediscover or
        // replay a completed edit. The next call must keep its exact plan ID.
        return try await withNewHelperGeneration { generation in
            let available = try await clientPool.allowedTools()
            try checkDocument(run, tools: tools, expected: run.edit.expected)
            let original = run.calls[confirmedActions.count]
            guard original.toolName == "press_key",
                  let tool = available.first(where: { $0.toolName == original.toolName && $0.serverID == original.serverID
                      && $0.schemaDigest == original.schemaDigest && $0.processGeneration == generation }) else {
                throw MCPClientError.approvalMismatch
            }
            let call = try tool.makeCall(taskID: taskID, arguments: original.arguments, stepEffectID: original.stepEffectID)
            guard call.canonicalDigest == original.canonicalDigest else { throw MCPClientError.approvalMismatch }
            let prepared = try await clientPool.prepareApproval(call)
            try checkDocument(run, tools: tools, expected: run.edit.expected)
            try checkGenerationCancellation(generation)
            run.prepared = prepared
            return .mcpApprovalRequired(prepared)
        }
    }

    private func executeDocumentTask(taskID: String, prompt: String, tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void, retained: DocumentRun? = nil) async throws -> ComputerUseExecutionResult? {
        guard let snapshot = try tools.mcpFocusedTextSnapshot(), snapshot.isReadable,
              let identity = snapshot.documentIdentity, let document = URL(string: identity), document.isFileURL,
              let bytes = try? ComputerUseMCPPlainDocument.read(document), bytes == Data(snapshot.text.value.utf8) else { return nil }
        if let retained {
            guard snapshot.hasSameDocumentTarget(as: retained.snapshot), document == retained.document,
                  snapshot.text.value.utf8.elementsEqual(retained.snapshot.text.value.utf8) else {
                throw ExecutorError.approvalStateChanged
            }
        }
        let application = snapshot.application.localizedName ?? ""
        let filename = document.lastPathComponent
        return try await withNewHelperGeneration { generation in
            let available = try await clientPool.allowedTools().filter {
                $0.serverID == MCPServerRegistry.macControl.serverID && $0.processGeneration == generation
            }
            func tool(_ name: String) throws -> MCPAllowedTool {
                guard let tool = available.first(where: { $0.toolName == name
                    && $0.serverID == MCPServerRegistry.macControl.serverID && $0.processGeneration == generation }) else {
                    throw ExecutorError.requiredToolsMissing
                }
                return tool
            }
            @MainActor func checkBefore() throws {
                try checkGenerationCancellation(generation)
                guard try tools.mcpFocusedTextSnapshot() == snapshot,
                      try ComputerUseMCPPlainDocument.read(document) == bytes else { throw ExecutorError.approvalStateChanged }
            }
            try checkBefore()
            guard available.contains(where: { $0.toolName == "set_element_attribute" || $0.toolName == "press_key" }) else { return nil }
            let edit: ComputerUseMCPDocumentEdit
            if let retained {
                progress("Checking the document after you resumed…")
                try checkBefore()
                edit = retained.edit
            } else {
                progress("Planning the document task with on-device Apple Intelligence…")
                try checkBefore()
                let documentPlanner = self.documentPlanner
                let proposal = try await planningWorker.perform(timeout: planningTimeout) {
                    try await documentPlanner.propose(prompt: prompt, application: application, document: filename)
                }
                try checkBefore()
                guard let proposal, let compiled = try ComputerUseMCPDocumentEdit.compile(proposal, prompt: prompt,
                    application: application, document: filename, original: snapshot.text.value) else { return nil }
                edit = compiled
            }
            let editsText = !edit.expected.utf8.elementsEqual(snapshot.text.value.utf8)
            let needed = (editsText ? ["find_elements", "set_element_attribute"] : []) + (edit.save ? ["press_key"] : [])
            guard needed.allSatisfy({ name in available.contains { $0.toolName == name } }) else { return nil }
            var unscoped: [MCPToolCall] = []
            if editsText {
                let found = try await clientPool.execute(tool("find_elements").makeCall(taskID: taskID, arguments: [
                    "pid": .integer(Int(snapshot.window.applicationProcessIdentifier)), "role": .string(snapshot.role)]))
                try checkBefore()
                guard let element = ComputerUseMCPFocusedTextRead.elementID(in: found, matching: snapshot) else {
                    throw ExecutorError.approvalStateChanged
                }
                unscoped.append(try tool("set_element_attribute").makeCall(taskID: taskID, arguments: [
                    "element_id": .string(element), "name": .string("AXValue"), "value": .string(edit.expected)]))
            }
            if edit.save {
                unscoped.append(try tool("press_key").makeCall(taskID: taskID,
                    arguments: ["key": .string("s"), "modifiers": .array([.string("command")])]))
            }
            guard !unscoped.isEmpty else { return .completed("The document already contains the requested text and is still open.") }
            let target = ComputerUseTaskContract.digest(["native-plain-document-v1", document.absoluteString,
                String(snapshot.window.applicationProcessIdentifier), String(CFHash(snapshot.focusedElement)),
                String(describing: snapshot.window), String(describing: snapshot.frame)])
            let entities = unscoped.enumerated().map { index, call in
                ComputerUseTaskContract.Entity(id: "action\(index)",
                    authorityDigest: ComputerUseTaskLedger.ApprovedActionPlan.authorityDigest(for: call))
            }
            var predicates: [ComputerUseTaskContract.Predicate] = [
                .init(id: "target", entityID: "action0", kind: "same-native-document", expectedDigest: target),
                .init(id: "original", entityID: "action0", kind: "exact-original-text",
                    expectedDigest: ComputerUseTaskContract.digest([snapshot.text.value]))]
            var steps: [ComputerUseTaskContract.Step] = []
            for (index, call) in unscoped.enumerated() {
                let post = "result\(index)"
                predicates.append(.init(id: post, entityID: "action\(index)",
                    kind: call.toolName == "press_key" ? "exact-saved-text" : "exact-editor-text",
                    expectedDigest: ComputerUseTaskContract.digest([edit.expected])))
                steps.append(.init(id: "step\(index)", dependencies: index == 0 ? [] : ["step\(index - 1)"],
                    operation: .init(capabilityID: "mcp.approved", entityID: "action\(index)",
                        payloadDigest: call.argumentsDigest, payloadVersion: 1),
                    preconditions: ["target", index == 0 ? "original" : "result\(index - 1)"], postconditions: [post]))
            }
            let contract = try ComputerUseTaskContract(taskID: taskID, promptDigest: ComputerUseTaskContract.digest([prompt]),
                entities: entities, predicates: predicates, steps: steps, invariants: ["target"],
                outcomes: ["target"] + steps.flatMap(\.postconditions))
            let calls = try zip(unscoped, steps).map { call, step in
                try tool(call.toolName).makeCall(taskID: taskID, arguments: call.arguments,
                    stepEffectID: contract.effectIdentity(for: step))
            }
            let run = DocumentRun(prompt: prompt, snapshot: snapshot, document: document, edit: edit, contract: contract, calls: calls)
            let prepared = try await clientPool.prepareApproval(calls[0])
            try checkBefore()
            run.prepared = prepared
            documentRun = run
            return .mcpApprovalRequired(prepared)
        }
    }

    private func checkDocument(_ run: DocumentRun, tools: ComputerUseHostTools, expected: String) throws {
        try checkExecutionCancellation()
        guard let current = try tools.mcpFocusedTextSnapshot(), current.isReadable,
              current.hasSameDocumentTarget(as: run.snapshot), current.text.value.utf8.elementsEqual(expected.utf8) else {
            throw ExecutorError.structuredToolFailed("The document or its text changed. The pending action was stopped.")
        }
        let bytes = try ComputerUseMCPPlainDocument.read(run.document)
        guard bytes == Data(run.snapshot.text.value.utf8) || bytes == Data(run.edit.expected.utf8) else {
            throw ExecutorError.structuredToolFailed("The saved document changed outside this task. The pending action was stopped.")
        }
    }

    private func performDocumentAction(_ prepared: MCPPreparedApproval, run: DocumentRun,
        tools: ComputerUseHostTools, progress: @escaping (String) -> Void) async throws -> MCPApprovedActionResult {
        let index = run.confirmed.count
        guard index < run.calls.count, run.prepared == prepared,
              prepared.call.canonicalDigest == run.calls[index].canonicalDigest else { throw MCPClientError.approvalMismatch }
        let isSave = prepared.call.toolName == "press_key"
        let expectedBefore = index == 0 ? run.snapshot.text.value : run.edit.expected
        return try await withGenerationCancellation(generation: prepared.call.processGeneration,
            preserveCompletedResultOnCancellation: true) {
            try checkGenerationCancellation(prepared.call.processGeneration)
            try checkDocument(run, tools: tools, expected: expectedBefore)
            progress(isSave ? "Saving the approved document…" : "Applying the approved document edit…")
            try checkDocument(run, tools: tools, expected: expectedBefore)
            run.prepared = nil
            let result = try await clientPool.performApproved(prepared.call, fingerprint: prepared.fingerprint)
            guard !result.isError, !result.wasTruncated,
                  case .object(let content)? = result.structuredContent, content["ok"] == .bool(true) else {
                throw MCPClientError.toolFailed("The document action was not confirmed. It will not be repeated.")
            }
            if isSave {
                guard content["key"] == .string("s"), content["modifiers"] == .array([.string("command")]) else {
                    throw MCPClientError.approvalMismatch
                }
                for _ in 0..<40 {
                    try checkDocument(run, tools: tools, expected: run.edit.expected)
                    if try ComputerUseMCPPlainDocument.read(run.document) == Data(run.edit.expected.utf8) { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard try ComputerUseMCPPlainDocument.read(run.document) == Data(run.edit.expected.utf8) else {
                    throw MCPClientError.toolFailed("The save could not be verified. It will not be repeated.")
                }
            } else {
                guard content["element_id"] == prepared.call.arguments["element_id"],
                      content["name"] == .string("AXValue"), content["ax_status"] == .integer(0) else {
                    throw MCPClientError.approvalMismatch
                }
            }
            try checkDocument(run, tools: tools, expected: run.edit.expected)
            let fact = MCPApprovedActionResult(callDigest: prepared.call.canonicalDigest,
                response: isSave ? "The saved file contains the approved text." : "The focused document contains the approved text.",
                completionPromptDigest: nil)
            run.confirmed.append(fact)
            return fact
        }
    }

    /// A complete focused-document read needs neither visual inference nor a
    /// generated summary. Discover and read through the actual MCP helper;
    /// independently verify the target and exact bytes across every await.
    private func executeFocusedTextRead(
        taskID: String, snapshot: ComputerUseMCPFocusedTextSnapshot,
        tools: ComputerUseHostTools, progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult? {
        try await withNewHelperGeneration { generation -> ComputerUseExecutionResult? in
            @MainActor func checkScope() throws {
                try checkGenerationCancellation(generation)
                guard try tools.mcpFocusedTextSnapshot() == snapshot else {
                    throw ExecutorError.structuredToolFailed(
                        "The focused document changed during the read. Please retry on the document you want to read.")
                }
            }
            let available = try await clientPool.allowedTools()
            try checkScope()
            func tool(_ name: String) -> MCPAllowedTool? {
                available.first { $0.toolName == name && $0.risk == .readOnly
                    && $0.serverID == MCPServerRegistry.macControl.serverID
                    && $0.processGeneration == generation }
            }
            guard let find = tool("find_elements"), let read = tool("get_element_attributes") else { return nil }
            progress("Reading the focused document with Mac tools…")
            try checkScope()
            let discovery = try await clientPool.execute(find.makeCall(taskID: taskID, arguments: [
                "pid": .integer(Int(snapshot.window.applicationProcessIdentifier)),
                "role": .string(snapshot.role),
            ]))
            try checkScope()
            guard let elementID = ComputerUseMCPFocusedTextRead.elementID(in: discovery, matching: snapshot) else { return nil }
            let value = try await clientPool.execute(read.makeCall(taskID: taskID, arguments: [
                "element_id": .string(elementID), "names": .array([.string("AXRole"), .string("AXValue")]),
            ]))
            try checkScope()
            guard let text = ComputerUseMCPFocusedTextRead.text(in: value, elementID: elementID, matching: snapshot) else { return nil }
            return .completed(text.isEmpty ? "The focused document is empty." : text)
        }
    }

    private func executeDeterministicCalculator(
        _ request: DeterministicCalculatorRequest,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        progress("Opening Calculator on this Mac…")
        try await tools.openApplication(named: "Calculator")
        try await Task.sleep(for: .milliseconds(600))
        try Task.checkCancellation()

        progress("Entering the calculation locally…")
        // Escape is Calculator's Clear shortcut. Send it twice so both a
        // pending entry and any prior operation are cleared before typing.
        try tools.perform(.key(usage: 0x29, modifiers: 0))
        try tools.perform(.key(usage: 0x29, modifiers: 0))

        var clearVerified = false
        for attempt in 0 ..< 12 {
            try Task.checkCancellation()
            if let snapshot = try tools.calculatorSnapshot(),
               snapshot.expressionValue == nil,
               snapshot.inputValue.map(Self.normalizedCalculatorDisplay) == "0" {
                clearVerified = true
                break
            }
            if attempt + 1 < 12 {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        guard clearVerified else {
            throw ExecutorError.calculatorClearNotVerified
        }

        try tools.perform(.typeText(request.expression))
        try tools.perform(.key(usage: 0x28, modifiers: 0))

        progress("Verifying Calculator’s display…")
        for attempt in 0 ..< 20 {
            try Task.checkCancellation()
            if let snapshot = try tools.calculatorSnapshot(),
               snapshot.inputValue.map(Self.normalizedCalculatorDisplay)
                == request.expectedDisplayValue,
               snapshot.expressionValue.map(Self.normalizedCalculatorExpression)
                == request.expression {
                Self.log.info(
                    "Verified deterministic Calculator result: \(request.expectedDisplayValue, privacy: .public)")
                return .completed(
                    "Calculator displays \(request.expectedDisplayValue).")
            }
            if attempt + 1 < 20 {
                try await Task.sleep(for: .milliseconds(150))
            }
        }
        throw ExecutorError.calculatorResultNotVerified(
            request.expectedDisplayValue)
    }

    private func runStructured(
        state initialState: PlanningState,
        tools: ComputerUseHostTools,
        fileRun initialFileRun: NativeFileRun?,
        mailRecipients initialMailRecipients: ComputerUseMailRecipients? = nil,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        var state = initialState
        var activeFileRun = initialFileRun
        var continuingRecipients = initialMailRecipients
        try await waitForStartedCancellation()
        try planningWorker.requireAvailable()
        return try await withNewHelperGeneration { generation in
            try checkGenerationCancellation(generation)
            let allTools = try await clientPool.allowedTools()
            try checkGenerationCancellation(generation)
            try tools.requireActive()
            let structuredTools = allTools.filter {
                Self.structuredToolNames.contains($0.toolName)
            }
            guard !structuredTools.isEmpty else {
                throw AppleFoundationMCPPlannerError.invalidRequest(
                    "No structured tools are available.")
            }

            for step in 0 ..< Self.maximumStructuredSteps {
                try checkGenerationCancellation(generation)
                activeFileRun?.planningState = state
                progress(step == 0
                    ? "Planning with on-device Apple Intelligence…"
                    : "Checking the local result…")
                try requireFileWorkActive(tools: tools, generation: generation)
                let localFileContext = activeFileRun?.context ?? NativeFileRun.notQueriedContext
                let resolvedPaths: [String]
                if let activeFileRun, activeFileRun.selectedCandidate != nil {
                    do {
                        resolvedPaths = [try resolveSelectedFile(activeFileRun).path]
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return .userInterventionRequired("The selected file changed. Search Downloads again before attaching it.")
                    }
                } else {
                    resolvedPaths = []
                }
                let request = MCPProposalPlanningRequest(
                    taskID: state.taskID,
                    prompt: try Self.planningPrompt(state, localFileContext: localFileContext,
                        hostResolvedAttachmentPaths: resolvedPaths),
                    tools: structuredTools, allowsBrowserWorkflow: true,
                    localFileCatalog: localFileContext,
                    hostResolvedAttachmentPaths: resolvedPaths)
                var proposal: MCPProposalPlanningResult
                do {
                    if let recipients = continuingRecipients {
                        continuingRecipients = nil
                        guard let mail = structuredTools.first(where: {
                            $0.serverID == RemoteDesktopMailMCP.serverID && $0.toolName == RemoteDesktopMailMCP.toolName
                        }) else { throw AppleFoundationMCPPlannerError.unknownProposal }
                        proposal = .mailRecipientsRequired(mail, recipients.arguments)
                    } else {
                        proposal = try await planningWorker.perform(timeout: planningTimeout) { [planner] in
                            try await planner.propose(request)
                        }
                    }
                } catch let failure as RemoteDesktopMailRecipientFailure {
                    try checkGenerationCancellation(generation)
                    try tools.requireActive()
                    return try retainStructuredClarification(
                        RemoteDesktopMailRecipientFailure.safeQuestion(for: failure.field),
                        state: state, fileRun: activeFileRun, tools: tools)
                }
                try checkGenerationCancellation(generation)
                try tools.requireActive()

                if case .mailRecipientsRequired(let mailTool, let arguments) = proposal {
                    var resolver = try ComputerUseMailRecipients(arguments: arguments)
                    let resolution: ComputerUseMailRecipients.Resolution
                    do { resolution = try await resolver.resolve() }
                    catch is CancellationError { throw CancellationError() }
                    catch { return .userInterventionRequired(error.localizedDescription) }
                    try requireFileWorkActive(tools: tools, generation: generation)
                    switch resolution {
                    case .ready(let resolved):
                        proposal = .proposedCall(try mailTool.makeCall(taskID: state.taskID, arguments: resolved))
                    case .missing(let question):
                        return try retainStructuredClarification(question, state: state,
                            fileRun: activeFileRun, tools: tools)
                    case .choose(let name, let field, let index, let matches):
                        var addresses: [String: String] = [:]
                        let choices = try matches.map { match in
                            let id = UUID().uuidString
                            addresses[id] = match.address
                            return try ComputerUseClarificationChoice(id: id,
                                label: match.name.isEmpty ? name : match.name, detail: match.address)
                        }
                        return try retainStructuredClarification("Which \(name) should receive the email?",
                            state: state, fileRun: activeFileRun, tools: tools, choices: choices,
                            mailRecipients: .init(resolver: resolver, field: field, index: index,
                                addressesByChoiceID: addresses))
                    }
                }

                switch proposal {
                case .mailRecipientsRequired:
                    throw AppleFoundationMCPPlannerError.unknownProposal
                case .browserTools:
                    throw RoutingSignal.browserTools
                case .localFileOperation(let operation):
                    let update = try await processLocalFileOperation(operation, state: state,
                        current: activeFileRun, tools: tools, generation: generation)
                    activeFileRun = update.run
                    if let result = update.result { return result }
                case .message(let message):
                    let bounded = message.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    if bounded == "VISUAL_FALLBACK_REQUIRED" {
                        throw RoutingSignal.desktopTools
                    }
                    if let clarification = Self.sentinelBody(
                        "CLARIFICATION_REQUIRED:",
                        in: bounded) {
                        return try retainStructuredClarification(clarification, state: state,
                            fileRun: activeFileRun, tools: tools)
                    }
                    if let completion = Self.sentinelBody(
                        "TASK_COMPLETE:",
                        in: bounded) {
                        // Planner prose is only a stop signal. The returned
                        // answer is projected by host code from the latest
                        // typed, untruncated read result; no planner-authored
                        // factual claim crosses this boundary.
                        guard !completion.isEmpty,
                              let answer = Self.hostProjectedReadOnlyAnswer(
                                  state: state),
                              !Self.requestsConsequentialMutation(
                                  state.trustedUserPrompt) else {
                            throw AppleFoundationMCPPlannerError.noProposal
                        }
                        return .completed(answer)
                    }
                    // Initial or untyped free text can never complete a task.
                    throw AppleFoundationMCPPlannerError.noProposal

                case .proposedCall(let call):
                    guard !state.executedCallDigests.contains(call.canonicalDigest) else {
                        throw ExecutorError.tooManySteps
                    }
                    switch call.risk {
                    case .blocked:
                        throw MCPClientError.toolNotAllowed(call.toolName)

                    case .approvalRequired:
                        let isCloudStorageCall = call.serverID == RemoteDesktopCloudStorageMCP.serverID
                            && call.toolName == RemoteDesktopCloudStorageMCP.toolName
                        var approvalCall = call
                        var cloudNeedsReplacementApproval = false
                        if isCloudStorageCall {
                            guard let activeFileRun,
                                  activeFileRun.selectedCandidate != nil else {
                                return .userInterventionRequired(
                                    "Choose the source file from the current local file list before saving it to cloud storage.")
                            }
                            do {
                                try validateNativeFileCloudStorageProposal(
                                    call, run: activeFileRun, state: state)
                                try requireFileWorkActive(tools: tools, generation: generation)
                                let cloudPrepared = try await cloudStorage.prepare(arguments: call.arguments)
                                try checkGenerationCancellation(generation)
                                try tools.requireActive()
                                try validateNativeFileCloudStorageProposal(
                                    call, run: activeFileRun, state: state)
                                guard let cloudTool = structuredTools.first(where: {
                                    $0.serverID == RemoteDesktopCloudStorageMCP.serverID
                                        && $0.toolName == RemoteDesktopCloudStorageMCP.toolName
                                }) else {
                                    throw AppleFoundationMCPPlannerError.unknownProposal
                                }
                                approvalCall = try cloudTool.makeCall(
                                    taskID: call.taskID,
                                    arguments: cloudPrepared.arguments,
                                    stepEffectID: call.stepEffectID)
                                cloudNeedsReplacementApproval = cloudPrepared.needsReplacementApproval
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch RemoteDesktopCloudStorage.Failure.providerUnavailable {
                                return .userInterventionRequired(
                                    RemoteDesktopCloudStorage.Failure.providerUnavailable.localizedDescription)
                            } catch {
                                return .userInterventionRequired(
                                    "The selected file or cloud destination changed before the copy could be prepared. Review the selection and try again.")
                            }
                        }
                        if call.toolName == RemoteDesktopMailMCP.toolName {
                            do {
                                _ = try RemoteDesktopMailRequest(arguments: call.arguments)
                            } catch let failure as RemoteDesktopMailRecipientFailure {
                                try requireFileWorkActive(tools: tools, generation: generation)
                                return try retainStructuredClarification(
                                    RemoteDesktopMailRecipientFailure.safeQuestion(for: failure.field),
                                    state: state, fileRun: activeFileRun, tools: tools)
                            }
                        }
                        if call.serverID == RemoteDesktopMailMCP.serverID,
                           call.toolName == RemoteDesktopMailMCP.toolName,
                           activeFileRun == nil,
                           let mailRequest = try? RemoteDesktopMailRequest(arguments: call.arguments),
                           !mailRequest.attachmentPaths.allSatisfy({ path in
                               Self.isExactAbsolutePathInTrustedUserTurns(
                                   path, turns: state.clarificationGoal.userTurns)
                            }) {
                            return .userInterventionRequired(
                                "The attachment path must appear exactly in a user-provided message before Mail can prepare this action.")
                        }
                        if !isCloudStorageCall,
                           let activeFileRun, activeFileRun.selectedCandidate == nil {
                            return .userInterventionRequired("Resolve the file from the current Downloads list before preparing a Mail attachment.")
                        }
                        if !isCloudStorageCall, let activeFileRun {
                            do { try validateNativeFileMailProposal(call, run: activeFileRun, state: state) }
                            catch { return .userInterventionRequired("The proposed Mail attachment does not match the accepted file. Choose or search again before preparing approval.") }
                            try requireFileWorkActive(tools: tools, generation: generation)
                        }
                        let prepared = try await clientPool.prepareApproval(approvalCall)
                        try checkGenerationCancellation(generation)
                        try tools.requireActive()
                        if isCloudStorageCall, let activeFileRun {
                            do { try validateNativeFileCloudStorageProposal(call, run: activeFileRun, state: state) }
                            catch { return .userInterventionRequired("The selected file changed while approval was being prepared. Search Downloads again.") }
                        } else if let activeFileRun {
                            do { try validateNativeFileMailProposal(call, run: activeFileRun, state: state) }
                            catch { return .userInterventionRequired("The selected file changed while approval was being prepared. Search Downloads again.") }
                        }
                        if call.serverID == RemoteDesktopMailMCP.serverID,
                           call.toolName == RemoteDesktopMailMCP.toolName,
                           try RemoteDesktopMailRequest(arguments: call.arguments).sendNow == false {
                            // Draft creation is reversible. Keep the same exact-file
                            // snapshot, journal and receipt checks without asking to send.
                            try await clientPool.preflightApproved(prepared.call, fingerprint: prepared.fingerprint)
                            try requireFileWorkActive(tools: tools, generation: generation)
                            if let activeFileRun {
                                try validateNativeFileMailProposal(call, run: activeFileRun, state: state)
                            }
                            progress("Saving your draft in Mail…")
                            let result = try await clientPool.performApproved(prepared.call, fingerprint: prepared.fingerprint)
                            let verified = try MCPApprovedActionResult.verified(call: prepared.call,
                                result: result, trustedUserPrompt: state.trustedUserPrompt)
                            return .completed(verified.response)
                        }
                        if isCloudStorageCall, !cloudNeedsReplacementApproval {
                            try await clientPool.preflightApproved(
                                prepared.call, fingerprint: prepared.fingerprint)
                            try requireFileWorkActive(tools: tools, generation: generation)
                            guard let activeFileRun else {
                                throw ExecutorError.approvalStateChanged
                            }
                            try validateNativeFileCloudStorageProposal(
                                call, run: activeFileRun, state: state)
                            progress("Saving the selected file to cloud storage…")
                            let result = try await clientPool.performApproved(
                                prepared.call, fingerprint: prepared.fingerprint)
                            let verified = try MCPApprovedActionResult.verified(
                                call: prepared.call, result: result,
                                trustedUserPrompt: state.trustedUserPrompt)
                            return .completed(verified.response)
                        }
                        pendingApprovalState = state
                        pendingApprovalDigest = prepared.call.canonicalDigest
                        return .mcpApprovalRequired(prepared)

                    case .readOnly:
                        // A planner may see untrusted conversation history.
                        // It cannot turn that context into a local data read:
                        // the signed current user turn must independently
                        // authorize this exact read-tool category.
                        guard let provenance = Self.reviewedReadProvenance(
                            for: call,
                            state: state) else {
                            throw AppleFoundationMCPPlannerError.noProposal
                        }
                        progress(Self.progressMessage(for: call.toolName))
                        let result = try await clientPool.execute(call)
                        try checkGenerationCancellation(generation)
                        try tools.requireActive()
                        guard !result.isError else {
                            throw ExecutorError.structuredToolFailed(
                                Self.boundedFailure(result.text))
                        }
                        let stepResult = StepResult(
                            toolName: call.toolName,
                            risk: call.risk,
                            arguments: call.arguments,
                            readProvenance: provenance,
                            text: Self.boundedResult(result.text),
                            structuredContent: result.structuredContent,
                            wasTruncated: result.wasTruncated)
                        guard Self.hostProjection(
                            for: stepResult,
                            trustedPrompt: state.trustedUserPrompt) != nil else {
                            throw AppleFoundationMCPPlannerError.noProposal
                        }
                        state.executedCallDigests.insert(call.canonicalDigest)
                        state.results.append(stepResult)

                    case .reversible:
                        // No reversible operation is currently reviewed for
                        // the planner-visible surface. Keep future registry
                        // drift fail-closed until it gets a typed intent gate.
                        throw MCPClientError.toolNotAllowed(call.toolName)
                    }
                }
            }
            throw ExecutorError.tooManySteps
        }
    }

    private func retainStructuredClarification(
        _ question: String,
        state: PlanningState,
        fileRun: NativeFileRun?,
        tools: ComputerUseHostTools,
        choices: [ComputerUseClarificationChoice]? = nil,
        mailRecipients: PendingMailRecipients? = nil
    ) throws -> ComputerUseExecutionResult {
        guard (1...512).contains(question.utf8.count),
              !question.unicodeScalars.contains(where: { $0.value == 0 }),
              state.clarificationGoal.userTurns.count < ComputerUseUnresolvedTextGoal.maximumUserTurns else {
            throw AppleFoundationMCPPlannerError.noProposal
        }
        let scope = ComputerUseTaskContract.digest([
            "mcp-structured-clarification-v1", state.rootTaskID, state.taskID,
            state.clarificationGoal.taskIdentityText, question, UUID().uuidString,
        ])
        let info = ComputerUseNativeTextExecutor.Clarification(
            taskID: state.taskID, goal: state.clarificationGoal,
            question: question, scope: scope, expiresAt: Date().addingTimeInterval(600), choices: choices)
        pendingStructuredClarification = PendingStructuredClarification(
            rootTaskID: state.rootTaskID, info: info, state: state,
            fileRun: fileRun, tools: tools, mailRecipients: mailRecipients)
        return .clarificationRequired(question)
    }

    private func requireFileWorkActive(tools: ComputerUseHostTools, generation: UInt64) throws {
        try checkGenerationCancellation(generation)
        try tools.requireActive()
    }

    private func processLocalFileOperation(
        _ operation: ComputerUseMCPBrowserStepPlanner.Plan.LocalFileOperation,
        state: PlanningState,
        current: NativeFileRun?,
        tools: ComputerUseHostTools,
        generation: UInt64
    ) async throws -> (run: NativeFileRun?, result: ComputerUseExecutionResult?) {
        switch operation {
        case .listFiles(let query, let cursor):
            guard query.isValid else {
                return (current, .userInterventionRequired("That file search is too long. Narrow the file name and try again."))
            }
            let run: NativeFileRun
            if let current {
                guard !current.invalidated, current.rootTaskID == state.rootTaskID,
                      current.currentTaskID == state.taskID,
                      current.rootTaskID == (nativeFileRun?.rootTaskID ?? current.rootTaskID) else {
                    return (nil, .userInterventionRequired("The file search no longer belongs to the pending task."))
                }
                run = current
            } else {
                run = NativeFileRun(rootTaskID: state.rootTaskID, prompt: state.originalPrompt,
                    trustedUserPrompt: state.trustedUserPrompt, planningState: state, tools: tools)
                nativeFileRun = run
            }
            try requireFileWorkActive(tools: tools, generation: generation)
            if run.selectedByUserCandidateID != nil {
                return (run, .userInterventionRequired("The accepted file choice is fixed for this task. Start a new task to choose another file."))
            }
            if let cursor {
                guard var catalog = run.catalog, run.context.query == query,
                      run.context.page.nextCursor == cursor else {
                    return (run, .userInterventionRequired("That file list has expired. Search Downloads again."))
                }
                let page = try catalog.nextPage(after: cursor)
                run.catalog = catalog
                run.context = .init(query: query, page: page, selectedCandidate: run.selectedCandidate,
                    nameFilterWasBroadened: run.context.nameFilterWasBroadened)
                return (run, nil)
            }
            var catalog = try localFileCatalogFactory(run.rootTaskID)
            let discoveryDeadline = Date().addingTimeInterval(20)
            var effectiveQuery = query
            var discovery = try await catalog.discoverOffMainActor(query: query,
                timeout: max(0.001, discoveryDeadline.timeIntervalSinceNow))
            try requireFileWorkActive(tools: tools, generation: generation)
            catalog = discovery.catalog
            var nameFilterWasBroadened = false
            if !run.didBroadenNameFilter, discovery.page.isComplete, discovery.page.candidates.isEmpty,
               discovery.page.nextCursor == nil, !query.nameContains.isEmpty {
                run.didBroadenNameFilter = true
                effectiveQuery = .init(fileKind: query.fileKind, sort: query.sort,
                    nameContains: "", folderScope: query.folderScope)
                discovery = try await catalog.discoverOffMainActor(query: effectiveQuery,
                    timeout: max(0.001, discoveryDeadline.timeIntervalSinceNow))
                try requireFileWorkActive(tools: tools, generation: generation)
                catalog = discovery.catalog
                nameFilterWasBroadened = true
            }
            // A fresh scan creates a new inventory and new opaque candidate
            // IDs even when the query text is unchanged.
            run.selectedCandidate = nil
            run.selectedPath = nil
            run.catalog = catalog
            run.context = .init(query: effectiveQuery, page: discovery.page,
                selectedCandidate: run.selectedCandidate, nameFilterWasBroadened: nameFilterWasBroadened)
            nativeFileRun = run
            if !nameFilterWasBroadened,
               let candidate = catalog.automaticSelectionCandidate(for: effectiveQuery) {
                return try await processLocalFileOperation(.selectFile(candidateID: candidate.id),
                    state: state, current: run, tools: tools, generation: generation)
            }
            return (run, nil)

        case .selectFile(let candidateID):
            guard let run = current, !run.invalidated, run.rootTaskID == state.rootTaskID,
                  run.currentTaskID == state.taskID, let catalog = run.catalog,
                  run.context.inventoryState == .available,
                  let candidate = run.context.page.candidates.first(where: { $0.id == candidateID }) else {
                return (current, .userInterventionRequired("That file choice is no longer in the current Downloads list. Search again."))
            }
            if let pinnedID = run.selectedByUserCandidateID, pinnedID != candidateID {
                return (run, .userInterventionRequired("The accepted file choice cannot be replaced by a different file."))
            }
            let reaffirmingPinnedChoice = run.selectedByUserCandidateID == candidateID
            let fallbackSelectionIsCurrentAndComplete = run.context.nameFilterWasBroadened
                && run.context.page.isComplete
                && run.context.page.candidates.contains(where: { $0.id == candidate.id })
            guard reaffirmingPinnedChoice || fallbackSelectionIsCurrentAndComplete
                    || Self.nativeFileSelectionIsUnambiguous(candidate, run: run, catalog: catalog) else {
                return (run, .userInterventionRequired("More than one file matches the best date. Choose from the full set of matching files."))
            }
            do {
                let resolved = try canonicalNativeFileURL(
                    catalog.resolve(candidateID: candidate.id, taskID: run.rootTaskID))
                let rechecked = try canonicalNativeFileURL(
                    catalog.resolve(candidateID: candidate.id, taskID: run.rootTaskID))
                guard resolved.path == rechecked.path else { throw ExecutorError.approvalStateChanged }
                let path = resolved
                try requireFileWorkActive(tools: tools, generation: generation)
                run.selectedCandidate = candidate
                run.selectedPath = path
                run.context = .init(query: run.context.query, page: run.context.page, selectedCandidate: candidate,
                    nameFilterWasBroadened: run.context.nameFilterWasBroadened)
                nativeFileRun = run
                return (run, nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return (run, .userInterventionRequired("The selected file changed. Search Downloads again before attaching it."))
            }

        case .askFile(let question, let candidateIDs):
            guard let run = current, !run.invalidated, run.rootTaskID == state.rootTaskID,
                  run.currentTaskID == state.taskID, let catalog = run.catalog,
                  run.selectedByUserCandidateID == nil,
                  run.context.inventoryState == .available,
                  (1...512).contains(question.utf8.count),
                  !question.unicodeScalars.contains(where: { $0.value == 0 }),
                  !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  candidateIDs.count >= 2, candidateIDs.count <= 8,
                  Set(candidateIDs).count == candidateIDs.count else {
                return (current, .userInterventionRequired("The proposed file choices are incomplete or expired. Search Downloads again."))
            }
            let allowedIDs: [String]
            if run.context.nameFilterWasBroadened {
                let offered = Set(run.context.page.candidates.map(\.id))
                guard run.context.page.isComplete, candidateIDs.allSatisfy(offered.contains) else {
                    return (run, .userInterventionRequired("The proposed choices are no longer in the complete current file list."))
                }
                allowedIDs = candidateIDs
            } else {
                switch catalog.rankedBestCandidates(for: run.context.query) {
                case .ids(let ids):
                    allowedIDs = ids
                case .unranked:
                    let offered = Set(run.context.page.candidates.map(\.id))
                    guard candidateIDs.allSatisfy(offered.contains) else {
                        return (run, .userInterventionRequired("The proposed choices are no longer in the current file list."))
                    }
                    allowedIDs = candidateIDs
                case .incomplete, .missingBestValue:
                    return (run, .userInterventionRequired("The file list does not establish a complete best-date group. Search by a clearer name."))
                }
            }
            guard allowedIDs.count >= 2, allowedIDs.count <= 8,
                  Set(candidateIDs) == Set(allowedIDs),
                  allowedIDs.allSatisfy({ id in run.context.page.candidates.contains(where: { $0.id == id }) }) else {
                return (run, .userInterventionRequired("The proposed choices do not include the full best matching group. Search again to review all matches."))
            }
            var choices: [ComputerUseClarificationChoice] = []
            var candidates: [String: ComputerUseLocalFileCatalog.Candidate] = [:]
            for id in allowedIDs {
                guard let candidate = run.context.page.candidates.first(where: { $0.id == id }) else {
                    return (run, .userInterventionRequired("A file choice is no longer available. Search Downloads again."))
                }
                do { _ = try catalog.resolve(candidateID: id, taskID: run.rootTaskID) }
                catch { return (run, .userInterventionRequired("A file changed while choices were being prepared. Search Downloads again.")) }
                let details = "\(candidate.folderLabel) · \(candidate.fileExtension.uppercased()) · \(candidate.byteCount) bytes"
                choices.append(try ComputerUseClarificationChoice(id: candidate.id,
                    label: candidate.displayName, detail: details))
                candidates[id] = candidate
            }
            let nonce = UUID().uuidString
            let scope = ComputerUseTaskContract.digest(["native-mail-file-choice-v1", run.rootTaskID,
                state.taskID, state.clarificationGoal.taskIdentityText, question, nonce] + allowedIDs.sorted())
            let expiry = Date().addingTimeInterval(600)
            run.pendingClarification = .init(taskID: state.taskID, goal: state.clarificationGoal,
                question: question, scope: scope, expiresAt: expiry, choices: choices)
            run.choicesByID = candidates
            run.currentTaskID = state.taskID
            nativeFileRun = run
            return (run, .clarificationRequired(question))

        case .selectLocalFile:
            return (current, .userInterventionRequired("Native Mail can use a resolved Downloads file directly; it cannot select files through a browser control."))
        }
    }

    private static func nativeFileSelectionIsUnambiguous(
        _ candidate: ComputerUseLocalFileCatalog.Candidate,
        run: NativeFileRun,
        catalog: ComputerUseLocalFileCatalog
    ) -> Bool {
        switch catalog.rankedBestCandidates(for: run.context.query) {
        case .ids(let ids): return ids.count == 1 && ids[0] == candidate.id
        case .unranked:
            return run.context.page.isComplete
                && run.context.page.candidates.contains(where: { $0.id == candidate.id })
        case .incomplete, .missingBestValue: return false
        }
    }

    private func resolveSelectedFile(_ run: NativeFileRun) throws -> URL {
        guard !run.invalidated, let candidate = run.selectedCandidate,
              let catalog = run.catalog else { throw ExecutorError.approvalStateChanged }
        let current = try canonicalNativeFileURL(
            catalog.resolve(candidateID: candidate.id, taskID: run.rootTaskID))
        let rechecked = try canonicalNativeFileURL(
            catalog.resolve(candidateID: candidate.id, taskID: run.rootTaskID))
        guard let selectedPath = run.selectedPath,
              current.path == rechecked.path,
              current.path == selectedPath.path else {
            throw ExecutorError.approvalStateChanged
        }
        if let userChosenPath = run.selectedByUserPath, current.path != userChosenPath.path {
            throw ExecutorError.approvalStateChanged
        }
        return current
    }

    /// FileManager's resolver may preserve `/var` aliases on macOS. Mail's
    /// no-follow reader requires the POSIX canonical path, so resolve it only
    /// after catalog identity validation and then revalidate the catalog.
    private func canonicalNativeFileURL(_ url: URL) throws -> URL {
        let canonicalPath = url.withUnsafeFileSystemRepresentation { representation -> String? in
            guard let representation, let canonical = Darwin.realpath(representation, nil) else { return nil }
            defer { free(canonical) }
            return String(cString: canonical)
        }
        guard let canonicalPath else { throw ExecutorError.approvalStateChanged }
        let canonicalURL = URL(fileURLWithPath: canonicalPath)
        guard canonicalURL.resolvingSymlinksInPath().path == url.path else {
            throw ExecutorError.approvalStateChanged
        }
        return canonicalURL
    }

    private func validateNativeFileMailProposal(_ call: MCPToolCall, run: NativeFileRun,
                                               state: PlanningState) throws {
        let path = try resolveSelectedFile(run).path
        guard call.taskID == state.taskID,
              call.toolName == RemoteDesktopMailMCP.toolName,
              call.risk == .approvalRequired,
              call.arguments["attachment_paths"] == .array([.string(path)]) else {
            throw AppleFoundationMCPPlannerError.noProposal
        }
    }

    private func validateNativeFileCloudStorageProposal(
        _ call: MCPToolCall,
        run: NativeFileRun,
        state: PlanningState
    ) throws {
        let path = try resolveSelectedFile(run).path
        guard call.taskID == state.taskID,
              call.serverID == RemoteDesktopCloudStorageMCP.serverID,
              call.toolName == RemoteDesktopCloudStorageMCP.toolName,
              call.risk == .approvalRequired,
              call.arguments["source_path"] == .string(path) else {
            throw AppleFoundationMCPPlannerError.noProposal
        }
        try RemoteDesktopCloudStorage.validateArguments(call.arguments)
    }

    private nonisolated static func isExactAbsolutePathInTrustedUserTurns(
        _ path: String, turns: [String]) -> Bool {
        guard path.hasPrefix("/"), !path.isEmpty, !path.contains("\0") else { return false }
        let needle = Array(path.utf8)
        func isBoundary(_ byte: UInt8) -> Bool {
            (byte >= 0x09 && byte <= 0x0D) || byte == 0x20
                || [0x22, 0x27, 0x28, 0x29, 0x2C, 0x3B, 0x3C, 0x3E, 0x5B, 0x5D, 0x60, 0x7B, 0x7D].contains(byte)
        }
        for turn in turns {
            let haystack = Array(turn.utf8)
            guard needle.count <= haystack.count else { continue }
            for start in 0...(haystack.count - needle.count) {
                let end = start + needle.count
                let openingQuote: UInt8? = start > 0 && [0x22, 0x27, 0x60].contains(haystack[start - 1])
                    ? haystack[start - 1] : nil
                let closingQuoteMatches = openingQuote.map {
                    end < haystack.count && haystack[end] == $0
                } ?? true
                guard haystack[start..<end].elementsEqual(needle),
                      (start == 0 || isBoundary(haystack[start - 1])),
                      (end == haystack.count || isBoundary(haystack[end])),
                      closingQuoteMatches else { continue }
                return true
            }
        }
        return false
    }

    private func validateFileApprovalForContinuation(_ call: MCPToolCall,
        state: PlanningState, run: NativeFileRun) throws {
        do {
            if call.serverID == RemoteDesktopCloudStorageMCP.serverID,
               call.toolName == RemoteDesktopCloudStorageMCP.toolName {
                try validateNativeFileCloudStorageProposal(call, run: run, state: state)
            } else {
                try validateNativeFileMailProposal(call, run: run, state: state)
            }
        } catch {
            throw ExecutorError.approvalStateChanged
        }
    }

    /// Extract the user turns from the host-labeled model prompt.
    private nonisolated static func deterministicUserSegments(
        in modelPrompt: String
    ) -> [String] {
        let header = "Recent conversation (oldest to newest):\n"
        guard modelPrompt.hasPrefix(header) else {
            let bounded = String(modelPrompt.prefix(20_000))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return bounded.isEmpty ? [] : [bounded]
        }

        enum SegmentRole: Equatable {
            case none
            case user
            case assistant
            case currentUser
        }

        var role = SegmentRole.none
        var segments: [(role: SegmentRole, text: String)] = []
        for line in modelPrompt.dropFirst(header.count)
            .split(separator: "\n", omittingEmptySubsequences: false) {
            let value = String(line)
            if value.hasPrefix("User: ") {
                role = .user
                segments.append((role, String(value.dropFirst("User: ".count))))
            } else if value.hasPrefix("Assistant: ") {
                role = .assistant
                segments.append((role, String(value.dropFirst("Assistant: ".count))))
            } else if value.hasPrefix("Current user request: ") {
                role = .currentUser
                segments.append((role, String(value.dropFirst("Current user request: ".count))))
            } else if role != .none, !segments.isEmpty {
                segments[segments.count - 1].text += "\n" + value
            }
        }

        guard let currentIndex = segments.lastIndex(where: {
            $0.role == .currentUser
        }) else { return [] }

        var scoped = [segments[currentIndex].text]
        if currentIndex >= 2,
           segments[currentIndex - 1].role == .assistant,
           segments[currentIndex - 2].role == .user,
           ComputerUseClarificationPolicy.isMailClarification(
               segments[currentIndex - 1].text) {
            scoped.insert(segments[currentIndex - 2].text, at: 0)
        }

        return scoped.map {
            String($0.prefix(8_000))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    /// Recognizes one intentionally narrow, current-turn Calculator command.
    /// Integer-only arithmetic keeps evaluation bounded and auditable; any
    /// extra action, malformed operand, overflow, non-integral division, or
    /// contradictory expected result stays on the normal planner/model path.
    nonisolated static func deterministicCalculatorRequest(
        for modelPrompt: String
    ) -> DeterministicCalculatorRequest? {
        guard let request = deterministicUserSegments(in: modelPrompt).last,
              request.count <= 500,
              !request.contains("\n"),
              !requestsConsequentialMutation(request),
              let match = firstRegexMatch(
                #"^\s*(?:please\s+)?(?:open|launch|start|bring\s+up)\s+(?:the\s+)?calculator(?:\s+app(?:lication)?)?\s*,?\s*(?:and\s+)?(?:clear\s+(?:it|the\s+calculator)\s*,?\s*(?:and\s+)?)?(?:calculate|compute|evaluate|work\s+out)\s+(-?\d{1,9})\s*(plus|minus|times|multiplied\s+by|divided\s+by|over|[+\-*/×÷x])\s*(-?\d{1,9})(?:\s*[,;]?\s*(?:and\s+)?(?:stop|finish)(?:\s+only)?\s+(?:when|once)\s+(?:the\s+)?calculator(?:\s+display)?\s+(?:shows?|reads?|displays?)\s+(-?\d{1,18}))?\s*[.!]?\s*$"#,
                in: request),
              match.numberOfRanges == 5,
              let leftRange = Range(match.range(at: 1), in: request),
              let operatorRange = Range(match.range(at: 2), in: request),
              let rightRange = Range(match.range(at: 3), in: request),
              let left = Int64(request[leftRange]),
              let right = Int64(request[rightRange]) else {
            return nil
        }

        let operation = String(request[operatorRange])
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        let value: Int64
        let expressionOperator: String
        switch operation {
        case "+", "plus":
            let result = left.addingReportingOverflow(right)
            guard !result.overflow else { return nil }
            value = result.partialValue
            expressionOperator = "+"
        case "-", "minus":
            let result = left.subtractingReportingOverflow(right)
            guard !result.overflow else { return nil }
            value = result.partialValue
            expressionOperator = "-"
        case "*", "x", "×", "times", "multipliedby":
            let result = left.multipliedReportingOverflow(by: right)
            guard !result.overflow else { return nil }
            value = result.partialValue
            expressionOperator = "*"
        case "/", "÷", "over", "dividedby":
            guard right != 0, left % right == 0 else { return nil }
            value = left / right
            expressionOperator = "/"
        default:
            return nil
        }

        let expected = String(value)
        if match.range(at: 4).location != NSNotFound,
           let statedRange = Range(match.range(at: 4), in: request),
           String(request[statedRange]) != expected {
            return nil
        }
        return DeterministicCalculatorRequest(
            expression: "\(left)\(expressionOperator)\(right)",
            expectedDisplayValue: expected)
    }

    nonisolated static func normalizedCalculatorDisplay(_ value: String) -> String {
        let ignorable = CharacterSet(charactersIn:
            "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069},_ \u{00A0}\u{202F}")
        return value.unicodeScalars.reduce(into: "") { result, scalar in
            if scalar == "−" || scalar == "–" {
                result.append("-")
            } else if !ignorable.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func normalizedCalculatorExpression(_ value: String) -> String {
        normalizedCalculatorDisplay(value)
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "x", with: "*", options: [.caseInsensitive])
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Recognizes only a single current-turn request whose whole effect is to
    /// launch one named application. This is deliberately lexical rather than
    /// model-based: completed conversation history cannot activate it, and
    /// connectors or mutation verbs keep multi-action work on the normal
    /// structured/approval path.
    nonisolated static func pureOpenApplicationName(
        _ modelPrompt: String
    ) -> String? {
        guard var request = deterministicUserSegments(in: modelPrompt).last else {
            return nil
        }
        request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty,
              request.count <= 300,
              !request.contains("\n"),
              !requestsConsequentialMutation(request) else {
            return nil
        }

        // Allow the natural completion guard used by the live acceptance task:
        // "Open Calculator and stop when it is visible." It describes when to
        // finish, not a second action.
        request = replacingRegex(
            #"[.!?]+\s*$"#,
            in: request,
            with: "")
        request = replacingRegex(
            #"\s+(?:and\s+)?(?:stop|wait)(?:\s+the\s+task)?\s+(?:when|once)\s+(?:it|the\s+(?:app|application))\s+(?:is\s+)?(?:open|visible|running)\s*$"#,
            in: request,
            with: "")

        guard let match = firstRegexMatch(
            #"^\s*(?:please\s+)?(?:open|launch|start|bring\s+up)\s+(?:the\s+)?(?:app(?:lication)?\s+)?(.+?)\s*$"#,
            in: request),
              match.numberOfRanges == 2,
              let targetRange = Range(match.range(at: 1), in: request) else {
            return nil
        }

        var target = String(request[targetRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        target = replacingRegex(
            #"\s+(?:app|application)\s*$"#,
            in: target,
            with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty,
              target.count <= 120,
              target.split(whereSeparator: { $0.isWhitespace }).count <= 8,
              !containsRegex(
                  #"[,;:!?\n]|\b(?:and|then|after|before|while|to|so|for|because|followed\s+by)\b"#,
                  in: target) else {
            return nil
        }
        return target
    }

    nonisolated static func isPureOpenApplicationRequest(
        _ modelPrompt: String
    ) -> Bool {
        pureOpenApplicationName(modelPrompt) != nil
    }

    private nonisolated static func containsRegex(
        _ pattern: String,
        in value: String
    ) -> Bool {
        firstRegexMatch(pattern, in: value) != nil
    }

    private nonisolated static func firstRegexMatch(
        _ pattern: String,
        in value: String
    ) -> NSTextCheckingResult? {
        regexMatches(pattern, in: value).first
    }

    private nonisolated static func regexMatches(
        _ pattern: String,
        in value: String
    ) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]) else { return [] }
        return regex.matches(
            in: value,
            range: NSRange(value.startIndex..., in: value))
    }

    private nonisolated static func replacingRegex(
        _ pattern: String,
        in value: String,
        with replacement: String
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]) else { return value }
        return regex.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: replacement)
    }

    private static func planningPrompt(
        _ state: PlanningState,
        localFileContext: ComputerUseMCPBrowserStepPlanner.LocalFileContext = NativeFileRun.notQueriedContext,
        hostResolvedAttachmentPaths: [String] = []
    ) throws -> String {
        let results: [MCPJSONValue] = state.results.map { result in
            .object([
                "tool_name": .string(result.toolName),
                "risk": .string(result.risk.rawValue),
                "arguments": .object(result.arguments),
                "text": .string(result.text),
                "was_truncated": .bool(result.wasTruncated),
            ])
        }
        let formatter = ISO8601DateFormatter()
        func date(_ value: Date?) -> MCPJSONValue {
            value.map { .double($0.timeIntervalSince1970) } ?? .null
        }
        func dateDisplay(_ value: Date?) -> MCPJSONValue {
            value.map { .string(formatter.string(from: $0)) } ?? .null
        }
        func candidate(_ value: ComputerUseLocalFileCatalog.Candidate) -> MCPJSONValue {
            .object([
                "id": .string(value.id),
                "display_name": .string(value.displayName),
                "folder": .string(value.folderLabel),
                "content_type_identifier": value.contentTypeIdentifier.map(MCPJSONValue.string) ?? .null,
                "file_extension": .string(value.fileExtension),
                "byte_count": .integer(Int(value.byteCount)),
                "modified_at": date(value.modifiedAt),
                "modified_at_display": dateDisplay(value.modifiedAt),
                "created_at": date(value.createdAt),
                "created_at_display": dateDisplay(value.createdAt),
                "added_to_directory_at": date(value.addedToDirectoryAt),
                "added_to_directory_at_display": dateDisplay(value.addedToDirectoryAt),
            ])
        }
        let query = localFileContext.query
        let localFiles = MCPJSONValue.object([
            "directory_name": .string("Documents, Desktop, Downloads, iCloud Drive"),
            "state": .string(localFileContext.inventoryState.rawValue),
            "query": localFileContext.inventoryState == .notQueried ? .null : .object([
                "file_kind": .string(query.fileKind.rawValue),
                "sort_field": query.sort.map { .string($0.field.rawValue) } ?? .null,
                "sort_direction": query.sort.map { .string($0.direction.rawValue) } ?? .null,
                "name_contains": .string(query.nameContains),
                "folder_scope": .string(query.folderScope.rawValue),
            ]),
            "candidates": .array(localFileContext.page.candidates.map(candidate)),
            "selected_candidate": localFileContext.selectedCandidate.map(candidate) ?? .null,
            "is_complete": .bool(localFileContext.page.isComplete),
            "name_filter_was_broadened": .bool(localFileContext.nameFilterWasBroadened),
            "has_tied_sort_values": .bool(localFileContext.page.hasTiedSortValues),
            "has_missing_sort_values": .bool(localFileContext.page.hasMissingSortValues),
            "next_cursor": localFileContext.page.nextCursor.map(MCPJSONValue.string) ?? .null,
        ])
        let payload = MCPJSONValue.object([
            "original_goal": .string(state.originalPrompt),
            "current_user_request": .string(state.trustedUserPrompt),
            "untrusted_tool_results": .array(results),
            "host_clarification_context": .array(state.clarificationGoal.clarificationContext.map { context in
                .object([
                    "question": .string(context["question"] ?? ""),
                    "answer": .string(context["answer"] ?? ""),
                ])
            }),
            "host_reviewed_contact_queries": .array(
                (state.contactReadRequirements?.queries ?? []).map(MCPJSONValue.string)),
            "local_files": localFiles,
            "host_resolved_attachment_paths": .array(hostResolvedAttachmentPaths.map(MCPJSONValue.string)),
        ])
        let data = try MCPDigest.canonicalData(for: payload)
        guard data.count <= MCPProposalPlanningRequest.maximumPromptBytes else {
            // Never clip a user requirement or turn malformed JSON into an
            // empty prompt. The planner request bound remains enforced.
            throw AppleFoundationMCPPlannerError.invalidRequest(
                "The planning request exceeds 32 KB.")
        }
        guard let prompt = String(data: data, encoding: .utf8) else {
            throw AppleFoundationMCPPlannerError.invalidRequest(
                "The planning request could not be encoded.")
        }
        return prompt
    }

    private static func sentinelBody(
        _ prefix: String,
        in message: String
    ) -> String? {
        guard message.lowercased().hasPrefix(prefix.lowercased()) else {
            return nil
        }
        return String(message.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A TASK_COMPLETE signal is accepted only after every read domain the
    /// current user explicitly requested has its own host-reviewed proof.
    /// Dependency reads never appear in the final answer and cannot substitute
    /// for a requested domain or for an additional non-read operation.
    private static func hostProjectedReadOnlyAnswer(
        state: PlanningState
    ) -> String? {
        guard !requestsUnverifiedNonReadWork(state.trustedUserPrompt) else {
            return nil
        }
        let requiredDomains = explicitlyRequestedReadDomains(
            state.trustedUserPrompt)
        guard !requiredDomains.isEmpty else { return nil }

        var sections: [String] = []
        for domain in ReadDomain.allCases where requiredDomains.contains(domain) {
            let evidence = state.results.filter {
                $0.risk == .readOnly
                    && $0.readProvenance?.completionDomain == domain
            }
            guard !evidence.isEmpty else { return nil }
            if domain == .contacts {
                guard let requirements = state.contactReadRequirements else { return nil }
                var contactSections: [String] = []
                for query in requirements.queries {
                    let matches = evidence.filter {
                        guard case .contacts(let observedQuery, _)? = $0.readProvenance else {
                            return false
                        }
                        return contactQueryIdentity(observedQuery) == contactQueryIdentity(query)
                    }
                    guard let latest = matches.last,
                          let answer = hostProjection(
                              for: latest, trustedPrompt: state.trustedUserPrompt) else {
                        return nil
                    }
                    contactSections.append(requirements.queries.count == 1
                        ? answer : "Contacts query: \(query)\n\(answer)")
                }
                guard evidence.allSatisfy({
                    guard case .contacts(let query, _)? = $0.readProvenance else { return false }
                    return requirements.contains(query)
                }) else { return nil }
                sections.append(contactSections.joined(separator: "\n\n"))
                continue
            }
            let projections = evidence.compactMap {
                hostProjection(
                    for: $0,
                    trustedPrompt: state.trustedUserPrompt)
            }
            guard projections.count == evidence.count else { return nil }
            sections.append(projections.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    /// Contact read obligations are compiled from complete supported clauses,
    /// independently of proposed calls. A domain set or a substring query is
    /// insufficient evidence that every requested entity has been checked.
    private static func compileContactReadRequirements(_ prompt: String) -> ContactReadRequirements? {
        guard prompt.utf8.count <= 12_000 else { return nil }
        let boundary = #"(?:,[ \t]*)?\band[ \t]+(?=(?:please[ \t]+)?(?:find|show|get|list|check|display|report|search|look|what|which|who)\b)"#
        let clauses = AppleFoundationVisualActionRouter.taskAuthoritySegments(
            prompt, preservingQuotedContent: true).flatMap {
                splitUnquotedContactText($0, boundary: boundary)
            }
        let field = #"(?:contacts?|(?:phone|telephone)(?:\s+numbers?)?|numbers?|emails?(?:\s+address(?:es)?)?)"#
        let fields = #"(?:the\s+)?"# + field + #"(?:\s+and\s+"# + field + #")*"#
        let scope = #"(?:in|from)\s+(?:my\s+)?(?:contacts|address\s+book)"#
        let head = #"^(?:please[ ,]+)?(?:when\s+convenient,[ ]+)?(?:(?:could|can|would)\s+you\s+)?(?:find|show|get|list|look\s+up|search\s+for)\s+(?:me\s+)?"#
        let patterns: [(value: String, possessive: Bool)] = [
            (head + #"(.+?)['’]s\s+"# + fields + #"(?:\s+"# + scope + #")?$"#, true),
            (head + fields + #"\s+for\s+(?:contacts\s+matching\s+)?(.+?)(?:\s+"# + scope + #")?$"#, false),
            (head + #"(.+?)\s+"# + scope + #"$"#, false),
        ]
        var queries: [String] = []
        var identities = Set<String>()
        var deniedReads: [String] = []
        for rawClause in clauses {
            let clause = rawClause.trimmingCharacters(in: .whitespacesAndNewlines
                .union(CharacterSet(charactersIn: ",")))
            if containsRegex(#"^(?:do\s+not|don't|don’t|never|without)\b"#, in: clause) {
                if containsRegex(#"\b(?:find(?:ing)?|show(?:ing)?|get(?:ting)?|list(?:ing)?|search(?:ing)?|look(?:ing)?|read(?:ing)?|display(?:ing)?|report(?:ing)?)\b"#,
                                 in: clause) {
                    deniedReads.append(clause)
                }
                continue
            }
            guard trustedPromptAffirmativelyRequestsPrivateRead(clause, domain: .contacts) else {
                // Other explicit read domains retain their own independent
                // completion requirements. An unrepresented residual request
                // (including an inherited entity such as “then find Avery”)
                // cannot disappear from Contacts completion.
                if !explicitlyRequestedReadDomains(clause).isEmpty { continue }
                if containsRegex(#"^(?:the|a|this)\s+(?:quoted\s+)?(?:label|title|name|text)\s+(?:is|says|reads)\s+(?:\"[^\"]*\"|“[^”]*”)$"#, in: clause) {
                    continue
                }
                return nil
            }
            var parsed: [String]?
            for pattern in patterns {
                guard let match = firstRegexMatch(pattern.value, in: clause),
                      let range = Range(match.range(at: 1), in: clause) else { continue }
                parsed = contactQueryList(String(clause[range]), possessive: pattern.possessive)
                if parsed != nil { break }
            }
            guard let parsed else { return nil }
            for query in parsed where identities.insert(contactQueryIdentity(query)).inserted {
                queries.append(query)
            }
        }
        guard !queries.isEmpty, queries.count < maximumStructuredSteps else { return nil }
        guard !deniedReads.contains(where: { denial in
            containsRegex(#"\bcontacts?\b|\baddress\s+book\b"#, in: denial)
                || queries.contains { trustedPromptContainsEntity($0, prompt: denial) }
        }) else { return nil }
        return ContactReadRequirements(queries: queries)
    }

    private static func splitUnquotedContactText(_ text: String, boundary: String) -> [String] {
        let masked = NSMutableString(string: AppleFoundationVisualActionRouter
            .taskTextMaskingQuotedContent(text))
        let source = text as NSString
        // The shared authority mask uses spaces. Turn removed quote/content
        // characters into non-whitespace sentinels so separator whitespace
        // cannot swallow a whole quoted name before/after an unquoted AND.
        for index in 0 ..< masked.length where masked.character(at: index) != source.character(at: index) {
            masked.replaceCharacters(in: NSRange(location: index, length: 1), with: "§")
        }
        var start = 0
        var parts: [String] = []
        for match in regexMatches(boundary, in: masked as String) {
            parts.append(source.substring(with: NSRange(location: start,
                                                       length: match.range.location - start)))
            start = NSMaxRange(match.range)
        }
        parts.append(source.substring(from: start))
        return parts
    }

    private static func contactQueryList(_ text: String, possessive: Bool) -> [String]? {
        let parts = splitUnquotedContactText(text,
            boundary: #"[ \t]*,[ \t]*(?:and[ \t]+)?|[ \t]+and[ \t]+"#)
        let reserved: Set<String> = [
            "and", "or", "but", "then", "for", "in", "from", "to", "with",
            "without", "except", "excluding", "instead", "rather", "who",
            "whose", "where", "when", "if", "unless", "matching", "contact",
            "contacts", "phone", "telephone", "number", "numbers", "email",
            "emails", "address", "addresses", "please", "find", "show", "get",
            "list", "look", "search", "do", "not", "all", "every", "them",
            "him", "her", "their", "its", "it",
        ]
        var queries: [String] = []
        for part in parts {
            var query = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if possessive && (query.hasSuffix("'s") || query.hasSuffix("’s")) {
                query = String(query.dropLast(2)).trimmingCharacters(in: .whitespaces)
            }
            let quoted = (query.hasPrefix("\"") && query.hasSuffix("\""))
                || (query.hasPrefix("“") && query.hasSuffix("”"))
            if quoted {
                guard query.count >= 3 else { return nil }
                query = String(query.dropFirst().dropLast())
                guard !query.contains("\""), !query.contains("“"), !query.contains("”") else {
                    return nil
                }
            } else {
                guard containsRegex(#"^[\p{L}\p{N}][\p{L}\p{M}\p{N}'’.-]*(?:[ \t]+[\p{L}\p{N}][\p{L}\p{M}\p{N}'’.-]*){0,7}$"#, in: query),
                      Set(query.lowercased().split(whereSeparator: \.isWhitespace)
                        .map(String.init)).isDisjoint(with: reserved) else { return nil }
            }
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty,
                  query.utf8.count <= 120,
                  !query.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                return nil
            }
            queries.append(query)
        }
        return queries.isEmpty ? nil : queries
    }

    private nonisolated static func contactQueryIdentity(_ query: String) -> String {
        // Preserve punctuation and accents: “Ann-Marie” must not become
        // “Ann Marie”, and a partial “Lee” cannot satisfy “Jordan Lee”.
        query.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Read provenance proves only the read. Until structured execution has a
    /// complete goal contract, an affirmative additional operation must prevent
    /// a read-only TASK_COMPLETE from ending the whole task. This is a bounded
    /// rejection rule, not a compiler or authority to execute these operations.
    private static func requestsUnverifiedNonReadWork(_ prompt: String) -> Bool {
        var authorityText = AppleFoundationVisualActionRouter
            .taskTextMaskingQuotedContent(prompt)

        // In an inventory request, OPEN can describe windows/apps rather than
        // request an effect. Mask only this contiguous read noun phrase, never
        // across a conjunction, punctuation or a newline into a later command.
        // Preserve the surrounding denial/question scope for the shared parser.
        let inventoryPattern = #"\b(?:list|show|display|report|get|which|what)(?:[ \t]+(?:me|my|the|all|your|current|currently|any|available|of|these|those))*[ \t]+(open)[ \t]+(?:apps?|applications?|windows?)\b"#
        if let expression = try? NSRegularExpression(
            pattern: inventoryPattern,
            options: [.caseInsensitive]) {
            let masked = NSMutableString(string: authorityText)
            let matches = expression.matches(
                in: authorityText,
                range: NSRange(location: 0, length: masked.length))
            for match in matches.reversed() {
                masked.replaceCharacters(in: match.range(at: 1), with: "visible")
            }
            authorityText = masked as String
        }

        return AppleFoundationVisualActionRouter
            .taskAffirmativelyRequestsOperation(
                authorityText,
                operationVerbs: [
                    "open", "activate", "launch", "close", "quit", "switch",
                    "click", "doubleclick", "tap", "type", "enter", "press",
                    "scroll", "drag", "move", "resize", "minimize", "maximize",
                    "copy", "paste", "select", "save", "rename", "delete",
                    "remove", "edit", "change", "set", "fill", "replace",
                    "append", "insert", "send", "compose", "draft", "create",
                    "add", "schedule", "run", "order", "buy", "purchase",
                    "pay", "submit", "book", "reserve", "download", "upload",
                    "install", "uninstall", "enable", "disable", "print",
                ])
    }

    /// Turns one exact, pre-reviewed read call and its typed result into prose.
    /// Raw result text and planner wording are never consulted.
    private static func hostProjection(
        for result: StepResult,
        trustedPrompt: String
    ) -> String? {
        guard result.risk == .readOnly,
              !result.wasTruncated,
              let provenance = result.readProvenance,
              case .object(let root)? = result.structuredContent,
              root["ok"] == .bool(true) else { return nil }

        switch provenance {
        case .contacts(let query, let limit):
            let requiresAllValues = requiresExhaustiveProjection(
                trustedPrompt,
                domain: .contacts)
            guard result.toolName == "contacts_search",
                  exactContactArguments(
                      result.arguments,
                      query: query,
                      limit: limit),
                  trustedPromptAffirmativelyRequestsPrivateRead(
                      trustedPrompt,
                      domain: .contacts,
                      requiredEntity: query),
                  case .array(let values)? = root["contacts"],
                  limit.map({ values.count <= $0 }) ?? true else {
                return nil
            }
            var rows: [String] = []
            for value in values {
                guard case .object(let contact) = value,
                      let name = projectedString(contact["name"]),
                      let phones = projectedStringArray(contact["phones"]),
                      let emails = projectedStringArray(contact["emails"]),
                      contactMatchesQuery(
                          query,
                          name: name,
                          phones: phones,
                          emails: emails),
                      let projectedPhones = projectedValues(
                          phones,
                          requireAll: requiresAllValues),
                      let projectedEmails = projectedValues(
                          emails,
                          requireAll: requiresAllValues) else {
                    return nil
                }
                rows.append(
                    "\(name) — phones: \(projectedPhones); emails: \(projectedEmails).")
            }
            return projectedList(
                heading: boundedCollectionHeading(
                    "Contacts",
                    limit: limit,
                    trustedPrompt: trustedPrompt),
                empty: "No matching contacts were found.",
                rows: rows,
                requireAll: requiresAllValues)

        case .reminders(
            let completion,
            let listName,
            let includeCompleted,
            let limit):
            guard result.toolName == "reminders_list",
                  exactReminderArguments(
                      result.arguments,
                      includeCompleted: includeCompleted,
                      limit: limit),
                  case .array(let values)? = root["reminders"],
                  limit.map({ values.count <= $0 }) ?? true else {
                return nil
            }
            var rows: [String] = []
            for value in values {
                guard case .object(let reminder) = value,
                      let title = projectedString(reminder["title"]),
                      case .bool(let completed)? = reminder["completed"],
                      let list = projectedString(reminder["list"]) else {
                    return nil
                }
                if let listName,
                   normalizedEntity(list) != normalizedEntity(listName) {
                    return nil
                }
                switch completion {
                case .incompleteOnly:
                    guard !completed else { return nil }
                case .completedOnly:
                    if !completed { continue }
                case .all, .unspecified:
                    break
                }
                rows.append(
                    "\(title) — \(completed ? "completed" : "incomplete"); list: \(list).")
            }
            return projectedList(
                heading: boundedCollectionHeading(
                    "Reminders",
                    limit: limit,
                    trustedPrompt: trustedPrompt),
                empty: "No matching reminders were found.",
                rows: rows,
                requireAll: requiresExhaustiveProjection(
                    trustedPrompt,
                    domain: .reminders))

        case .shortcuts:
            guard result.toolName == "list_shortcuts",
                  result.arguments.isEmpty,
                  let names = projectedStringArray(root["names"]),
                  case .integer(let count)? = root["count"],
                  count == names.count else {
                return nil
            }
            return projectedList(
                heading: "Available Shortcuts (\(count)):",
                empty: "No Apple Shortcuts are available.",
                rows: names,
                requireAll: requiresExhaustiveProjection(
                    trustedPrompt,
                    domain: .shortcuts))

        case .focusedApp:
            guard result.toolName == "focused_app",
                  result.arguments.isEmpty,
                  case .object(let app)? = root["app"],
                  let name = projectedString(app["name"]),
                  case .integer(let pid)? = app["pid"],
                  let bundleIdentifier = projectedString(
                      app["bundleIdentifier"]),
                  case .bool(let active)? = app["isActive"] else {
                return nil
            }
            return "Focused app: \(name) — PID \(pid); bundle: \(bundleIdentifier); active: \(active ? "yes" : "no")."

        case .runningApps, .windowApplicationInventoryDependency:
            guard result.toolName == "list_apps",
                  result.arguments.isEmpty,
                  case .array(let values)? = root["apps"] else {
                return nil
            }
            var rows: [String] = []
            var promptMatchedApplication = false
            for value in values {
                guard case .object(let app) = value,
                      let name = projectedString(app["name"]),
                      case .integer(let pid)? = app["pid"] else {
                    return nil
                }
                var attributes = ["PID \(pid)"]
                if let activeValue = app["isActive"] {
                    guard case .bool(let active) = activeValue else {
                        return nil
                    }
                    attributes.append("active: \(active ? "yes" : "no")")
                }
                if trustedPromptContainsEntity(name, prompt: trustedPrompt) {
                    promptMatchedApplication = true
                }
                rows.append("\(name) — \(attributes.joined(separator: "; ")).")
            }
            if provenance == .windowApplicationInventoryDependency,
               !promptMatchedApplication {
                return nil
            }
            return projectedList(
                heading: "Running apps:",
                empty: "No running apps were reported.",
                rows: rows,
                requireAll: requiresExhaustiveProjection(
                    trustedPrompt,
                    domain: .runningApps))

        case .windows(let requestedPID, let applicationName):
            guard result.toolName == "list_windows",
                  exactWindowArguments(
                      result.arguments,
                      pid: requestedPID),
                  exactWindowResultScope(
                      root["pid"],
                      requestedPID: requestedPID),
                  case .array(let values)? = root["windows"] else {
                return nil
            }
            var rows: [String] = []
            for value in values {
                guard case .object(let window) = value,
                      let title = projectedString(window["title"]),
                      case .integer(let pid)? = window["pid"],
                      case .integer(let index)? = window["index"] else {
                    return nil
                }
                if let requestedPID, pid != requestedPID { return nil }
                rows.append("\(title) — PID \(pid); index \(index).")
            }
            return projectedList(
                heading: applicationName.map { "Open windows for \($0):" }
                    ?? "Open windows:",
                empty: "No matching open windows were found.",
                rows: rows,
                requireAll: requiresExhaustiveProjection(
                    trustedPrompt,
                    domain: .windows))

        case .permissions:
            guard result.toolName == "permissions_status",
                  result.arguments.isEmpty,
                  let rawStatus = projectedString(root["accessibility"]),
                  let status = projectedAccessibilityStatus(rawStatus) else {
                return nil
            }
            return "Accessibility permission: \(status)."
        }
    }

    /// Private local data needs affirmative authority in the same bounded
    /// clause as the domain it would expose. A domain noun elsewhere in the
    /// turn is not enough: `do not show Jordan's contact` and
    /// `without showing my reminders` are denials, not read requests. When a
    /// contact query is known, bind that exact entity to the affirmative clause
    /// as well so a permitted Avery lookup cannot authorize a negated Jordan
    /// lookup from the same turn.
    private static func trustedPromptAffirmativelyRequestsPrivateRead(
        _ prompt: String,
        domain: ReadDomain,
        requiredEntity: String? = nil
    ) -> Bool {
        let domainWords: Set<String>
        let domainPhrases: [String]
        switch domain {
        case .contacts:
            domainWords = [
                "contact", "contacts", "email", "number", "phone",
                "telephone",
            ]
            domainPhrases = ["address book"]
        case .reminders:
            domainWords = ["reminder", "reminders", "todo", "todos"]
            domainPhrases = ["to-do"]
        default:
            return false
        }

        let negatedSegmentMarker = "__negated_private_read__"
        let maskedPrompt = AppleFoundationVisualActionRouter.taskTextMaskingQuotedContent(prompt)
        let excludedPrefixPattern = #"(?i)\b(?:without|except|excluding|nor)\b|\b(?:other|rather)\s+than\b|\binstead\s+of\b|\bapart\s+from\b|\b(?:all|anything|everything)(?:\s+\w+){0,4}\s+but\b"#
        var preparedPrompt = NSMutableString(string: prompt)
        if let regex = try? NSRegularExpression(pattern: excludedPrefixPattern) {
            let matches = regex.matches(in: maskedPrompt,
                range: NSRange(maskedPrompt.startIndex..., in: maskedPrompt))
            for match in matches.reversed() {
                preparedPrompt.replaceCharacters(in: match.range,
                    with: "\n\(negatedSegmentMarker) ")
            }
        }
        let scopedPrompt = preparedPrompt as String
        let authoritySegments = AppleFoundationVisualActionRouter.taskAuthoritySegments(scopedPrompt)
        let contentSegments = AppleFoundationVisualActionRouter.taskAuthoritySegments(
            scopedPrompt, preservingQuotedContent: true)
        guard authoritySegments.count == contentSegments.count else { return false }

        let readCues: Set<String> = [
            "check", "display", "find", "get", "list", "look", "read",
            "report", "search", "show", "status", "tell", "what", "which",
            "who",
        ]
        let interrogativeStarts: Set<String> = [
            "are", "do", "does", "has", "have", "is",
        ]
        let explicitNegativeWords: Set<String> = [
            "avoid", "cannot", "cant", "dont", "exclude", "excluding",
            "never", "no", "not", "omit", "omitting", "refuse", "skip",
            "skipping", "without",
        ]

        func containsExplicitNegation(_ words: ArraySlice<String>) -> Bool {
            if !Set(words).isDisjoint(with: explicitNegativeWords) {
                return true
            }
            let values = Array(words)
            guard values.count >= 2 else { return false }
            return (0 ..< values.count - 1).contains { index in
                (values[index] == "don" && values[index + 1] == "t")
                    || (values[index] == "do" && values[index + 1] == "not")
                    || (values[index] == "can" && values[index + 1] == "not")
            }
        }

        for (authoritySegment, contentSegment) in zip(authoritySegments, contentSegments) {
            var separated = authoritySegment.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")).lowercased()
            if let regex = try? NSRegularExpression(
                pattern: #"(?i)\b(?:without|except|excluding|nor)\b|\b(?:other|rather)\s+than\b|\binstead\s+of\b|\bapart\s+from\b|\b(?:all|anything|everything)(?:\s+\w+){0,4}\s+but\b"#) {
                separated = regex.stringByReplacingMatches(
                    in: separated,
                    range: NSRange(separated.startIndex..., in: separated),
                    withTemplate: "\n\(negatedSegmentMarker) ")
            }
            if let regex = try? NSRegularExpression(
                pattern: #"(?i)[.!?;\n]+|,\s*but\b|\bbut\b"#) {
                separated = regex.stringByReplacingMatches(
                    in: separated,
                    range: NSRange(separated.startIndex..., in: separated),
                    withTemplate: "\n")
            }
            let content = contentSegment.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")).lowercased()
            for rawSegment in separated.split(separator: "\n").map(String.init) {
                let inheritedNegation = rawSegment.contains(negatedSegmentMarker)
                let segment = rawSegment.replacingOccurrences(
                    of: negatedSegmentMarker,
                    with: "")
                let words = segment.split {
                    !$0.isLetter && !$0.isNumber
                }.map(String.init)
                guard !words.isEmpty, !inheritedNegation else { continue }
                if let requiredEntity,
                   !trustedPromptContainsEntity(requiredEntity, prompt: content) {
                    continue
                }

                var domainIndices = words.indices.filter {
                    domainWords.contains(words[$0])
                }
                for phrase in domainPhrases {
                    let phraseWords = normalizedEntity(phrase).split(separator: " ")
                        .map(String.init)
                    guard !phraseWords.isEmpty,
                          words.count >= phraseWords.count else { continue }
                    for start in 0 ... (words.count - phraseWords.count)
                    where Array(words[start ..< start + phraseWords.count])
                            == phraseWords {
                        domainIndices.append(start + phraseWords.count - 1)
                    }
                }
                guard !domainIndices.isEmpty else { continue }

                let cueIndices = words.indices.filter { index in
                    readCues.contains(words[index])
                        || (index == words.startIndex
                            && interrogativeStarts.contains(words[index]))
                }
                guard !cueIndices.isEmpty else { continue }

                for domainIndex in domainIndices {
                    // Authority must lead the private-data noun. A later noun that
                    // happens to look like a read cue (`email report status`) cannot
                    // retroactively turn an earlier Contacts/Reminders mention into
                    // permission to access local data.
                    let cueIndex = cueIndices.last(where: { $0 <= domainIndex })
                    guard let cueIndex else { continue }
                    let prefix = words[..<cueIndex]
                    let cueToDomainStart = min(cueIndex + 1, domainIndex)
                    let cueToDomain = words[
                        cueToDomainStart ... max(cueToDomainStart, domainIndex)]
                    if !containsExplicitNegation(prefix),
                       !containsExplicitNegation(cueToDomain) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func trustedPromptIsRelevant(
        _ prompt: String,
        to toolName: String
    ) -> Bool {
        let normalized = prompt.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let orderedWords = normalized.split {
            !$0.isLetter && !$0.isNumber
        }.map(String.init)
        let words = Set(orderedWords)
        let readCues: Set<String> = [
            "check", "display", "find", "get", "list", "look", "read",
            "report", "search", "show", "status", "tell", "what", "which",
            "who",
        ]
        let authoritySegments = AppleFoundationVisualActionRouter.taskAuthoritySegments(prompt)
        let mutationWords: Set<String> = [
            "add", "change", "complete", "create", "delete", "edit", "mark",
            "remove", "update",
        ]
        func hasMutationInReadAuthorityClause(domainWords: Set<String>) -> Bool {
            authoritySegments.contains { segment in
                let segmentWords = Set(segment.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")).lowercased().split {
                        !$0.isLetter && !$0.isNumber
                    }.map(String.init))
                return !segmentWords.isDisjoint(with: domainWords)
                    && !segmentWords.isDisjoint(with: readCues)
                    && !segmentWords.isDisjoint(with: mutationWords)
            }
        }
        let interrogativeStarts: Set<String> = [
            "are", "do", "does", "has", "have", "is",
        ]
        guard !words.intersection(readCues).isEmpty
                || orderedWords.first.map(interrogativeStarts.contains) == true else {
            return false
        }

        switch toolName {
        case "contacts_search":
            guard !hasMutationInReadAuthorityClause(domainWords: [
                "contact", "contacts", "email", "number", "phone", "telephone",
            ]) else { return false }
            return trustedPromptAffirmativelyRequestsPrivateRead(
                prompt,
                domain: .contacts)

        case "reminders_list":
            guard !hasMutationInReadAuthorityClause(domainWords: [
                "reminder", "reminders", "todo", "todos",
            ]) else { return false }
            return trustedPromptAffirmativelyRequestsPrivateRead(
                prompt,
                domain: .reminders)

        case "list_shortcuts":
            guard words.intersection([
                "create", "delete", "remove",
            ]).isEmpty else { return false }
            let executionWords = words.intersection(["execute", "run"])
            if !executionWords.isEmpty {
                let explicitlyReadOnly = normalized.contains("do not run")
                    || normalized.contains("don't run")
                    || normalized.contains("do not execute")
                    || normalized.contains("don't execute")
                    || normalized.contains("without running")
                    || normalized.contains("without executing")
                guard explicitlyReadOnly else { return false }
            }
            return words.contains("shortcut") || words.contains("shortcuts")

        case "focused_app":
            guard words.intersection([
                "activate", "close", "launch", "open", "quit", "start",
                "switch", "terminate",
            ]).isEmpty else { return false }
            let appWords: Set<String> = ["app", "application", "program"]
            let focusWords: Set<String> = [
                "active", "current", "currently", "focus", "focused",
                "frontmost", "using",
            ]
            return !words.intersection(appWords).isEmpty
                && !words.intersection(focusWords).isEmpty

        case "list_apps":
            guard words.intersection([
                "activate", "close", "launch", "quit", "start", "switch",
                "terminate",
            ]).isEmpty else { return false }
            let appWords: Set<String> = [
                "app", "application", "applications", "apps", "process",
                "processes", "program", "programs",
            ]
            let inventoryWords: Set<String> = [
                "list", "open", "running",
            ]
            return !words.intersection(appWords).isEmpty
                && !words.intersection(inventoryWords).isEmpty

        case "list_windows":
            guard words.intersection([
                "activate", "close", "focus", "maximize", "minimize",
                "move", "resize", "switch",
            ]).isEmpty else { return false }
            return words.contains("window") || words.contains("windows")

        case "permissions_status":
            guard words.intersection([
                "change", "disable", "enable", "grant", "revoke",
            ]).isEmpty else { return false }
            return !words.intersection([
                "access", "accessibility", "control", "permission",
                "permissions",
            ]).isEmpty

        default:
            return false
        }
    }

    private static func explicitlyRequestedReadDomains(
        _ prompt: String
    ) -> Set<ReadDomain> {
        Set(ReadDomain.allCases.filter {
            trustedPromptIsRelevant(prompt, to: toolName(for: $0))
        })
    }

    private static func toolName(for domain: ReadDomain) -> String {
        switch domain {
        case .contacts: return "contacts_search"
        case .reminders: return "reminders_list"
        case .shortcuts: return "list_shortcuts"
        case .focusedApp: return "focused_app"
        case .runningApps: return "list_apps"
        case .windows: return "list_windows"
        case .permissions: return "permissions_status"
        }
    }

    /// Reviews exact arguments against the trusted current turn before any
    /// private read executes. The returned value is immutable provenance for
    /// validating the typed result and terminal projection later.
    private static func reviewedReadProvenance(
        for call: MCPToolCall,
        state: PlanningState
    ) -> ReadProvenance? {
        let prompt = state.trustedUserPrompt
        let requested = explicitlyRequestedReadDomains(prompt)

        switch call.toolName {
        case "contacts_search":
            guard requested.contains(.contacts),
                  !requiresExhaustiveProjection(prompt, domain: .contacts),
                  Set(call.arguments.keys).isSubset(of: ["query", "limit"]),
                  case .string(let rawQuery)? = call.arguments["query"],
                  let query = projectedString(.string(rawQuery)),
                  normalizedEntity(query).count >= 2,
                  trustedPromptAffirmativelyRequestsPrivateRead(
                      prompt,
                      domain: .contacts,
                      requiredEntity: query),
                  let reviewedLimit = reviewedOptionalPositiveInteger(
                      call.arguments["limit"],
                      maximum: 100),
                  let limit = reviewedLimit else { return nil }
            if let requirements = state.contactReadRequirements,
               !requirements.contains(query) { return nil }
            if let requestedLimit = requestedResultLimit(prompt),
               limit != requestedLimit {
                return nil
            }
            return .contacts(query: query, limit: limit)

        case "reminders_list":
            guard requested.contains(.reminders),
                  !requiresExhaustiveProjection(prompt, domain: .reminders),
                  Set(call.arguments.keys).isSubset(of: [
                      "include_completed", "limit",
                  ]),
                  case .bool(let includeCompleted)? =
                      call.arguments["include_completed"],
                  let reviewedLimit = reviewedOptionalPositiveInteger(
                      call.arguments["limit"],
                      maximum: 100),
                  let limit = reviewedLimit else { return nil }
            let completion = reminderCompletionIntent(prompt)
            switch completion {
            case .incompleteOnly where includeCompleted:
                return nil
            case .completedOnly where !includeCompleted:
                return nil
            case .all where !includeCompleted:
                return nil
            case .incompleteOnly, .completedOnly, .all, .unspecified:
                break
            }
            if let requestedLimit = requestedResultLimit(prompt),
               limit != requestedLimit {
                return nil
            }
            return .reminders(
                completion: completion,
                listName: requestedReminderListName(prompt),
                includeCompleted: includeCompleted,
                limit: limit)

        case "list_shortcuts":
            guard requested.contains(.shortcuts),
                  call.arguments.isEmpty else { return nil }
            return .shortcuts

        case "focused_app":
            guard requested.contains(.focusedApp),
                  call.arguments.isEmpty else { return nil }
            return .focusedApp

        case "list_apps":
            guard call.arguments.isEmpty else { return nil }
            if requested.contains(.runningApps) {
                return .runningApps
            }
            guard requested.contains(.windows),
                  trustedPromptHasNamedWindowApplication(prompt) else {
                return nil
            }
            return .windowApplicationInventoryDependency

        case "list_windows":
            guard requested.contains(.windows),
                  Set(call.arguments.keys).isSubset(of: ["pid"]) else {
                return nil
            }
            if case .integer(let pid)? = call.arguments["pid"] {
                guard pid > 0,
                      let applicationName = applicationNameProvingPID(
                          pid,
                          state: state) else { return nil }
                return .windows(pid: pid, applicationName: applicationName)
            }
            guard call.arguments["pid"] == nil,
                  !trustedPromptHasNamedWindowApplication(prompt) else {
                return nil
            }
            return .windows(pid: nil, applicationName: nil)

        case "permissions_status":
            guard requested.contains(.permissions),
                  call.arguments.isEmpty else { return nil }
            return .permissions

        default:
            return nil
        }
    }

    /// Returns `.some(nil)` for an omitted optional integer and `nil` for an
    /// invalid value, allowing callers to distinguish absence from rejection.
    private static func reviewedOptionalPositiveInteger(
        _ value: MCPJSONValue?,
        maximum: Int
    ) -> Int?? {
        guard let value else { return .some(nil) }
        guard case .integer(let integer) = value,
              (1 ... maximum).contains(integer) else { return nil }
        return .some(.some(integer))
    }

    private static func exactContactArguments(
        _ arguments: [String: MCPJSONValue],
        query: String,
        limit: Int?
    ) -> Bool {
        guard Set(arguments.keys).isSubset(of: ["query", "limit"]),
              arguments["query"] == .string(query) else { return false }
        return exactOptionalInteger(arguments["limit"], expected: limit)
    }

    private static func exactReminderArguments(
        _ arguments: [String: MCPJSONValue],
        includeCompleted: Bool,
        limit: Int?
    ) -> Bool {
        guard Set(arguments.keys).isSubset(of: [
            "include_completed", "limit",
        ]),
        arguments["include_completed"] == .bool(includeCompleted) else {
            return false
        }
        return exactOptionalInteger(arguments["limit"], expected: limit)
    }

    private static func exactWindowArguments(
        _ arguments: [String: MCPJSONValue],
        pid: Int?
    ) -> Bool {
        guard Set(arguments.keys).isSubset(of: ["pid"]) else { return false }
        return exactOptionalInteger(arguments["pid"], expected: pid)
    }

    private static func exactWindowResultScope(
        _ value: MCPJSONValue?,
        requestedPID: Int?
    ) -> Bool {
        switch (value, requestedPID) {
        case (nil, nil): return true
        case (.integer(let actual)?, .some(let requested)):
            return actual == requested
        default: return false
        }
    }

    private static func exactOptionalInteger(
        _ value: MCPJSONValue?,
        expected: Int?
    ) -> Bool {
        switch (value, expected) {
        case (nil, nil): return true
        case (.integer(let actual)?, .some(let expected)):
            return actual == expected
        default: return false
        }
    }

    private static func reminderCompletionIntent(
        _ prompt: String
    ) -> ReminderCompletionIntent {
        let normalized = prompt.lowercased()
        let words = Set(normalized.split {
            !$0.isLetter && !$0.isNumber
        }.map(String.init))
        if words.contains("all")
            || normalized.contains("include completed")
            || normalized.contains("including completed") {
            return .all
        }
        if !words.intersection([
            "incomplete", "pending", "unfinished",
        ]).isEmpty || normalized.contains("not completed") {
            return .incompleteOnly
        }
        if !words.intersection([
            "completed", "done", "finished",
        ]).isEmpty {
            return .completedOnly
        }
        return .unspecified
    }

    private static func requestedResultLimit(_ prompt: String) -> Int? {
        let normalized = prompt.lowercased()
        let wordValues: [String: Int] = [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        ]
        let patterns = [
            #"\b(?:first|top|show|list)\s+(\d{1,3})\b"#,
            #"\b(?:first|top|show|list)\s+(one|two|three|four|five|six|seven|eight|nine|ten)\b"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]),
                let match = regex.firstMatch(
                    in: normalized,
                    range: NSRange(normalized.startIndex..., in: normalized)),
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: normalized) else {
                continue
            }
            let value = String(normalized[range])
            return Int(value) ?? wordValues[value]
        }
        return nil
    }

    private static func requestedReminderListName(_ prompt: String) -> String? {
        let pattern = #"\b(?:in|from|on)\s+(?:my\s+)?([\p{L}\p{N}][\p{L}\p{N} ._'\-]{0,60}?)\s+list\b"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]),
            let match = regex.firstMatch(
                in: prompt,
                range: NSRange(prompt.startIndex..., in: prompt)),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: prompt) else {
            return nil
        }
        return String(prompt[range])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trustedPromptHasNamedWindowApplication(
        _ prompt: String
    ) -> Bool {
        let words = prompt.lowercased().split {
            !$0.isLetter && !$0.isNumber
        }.map(String.init)
        let genericWords: Set<String> = [
            "a", "all", "an", "any", "current", "currently", "desktop",
            "every", "list", "mac", "my", "open", "show", "the",
            "visible", "what", "which",
        ]
        for index in words.indices
        where words[index] == "window" || words[index] == "windows" {
            // "Notes windows", "Notes open windows", and
            // "the open Notes windows" all name the app before the noun.
            if index > words.startIndex {
                var candidateIndex = words.index(before: index)
                if words[candidateIndex] == "open",
                   candidateIndex > words.startIndex {
                    candidateIndex = words.index(before: candidateIndex)
                }
                let candidate = words[candidateIndex]
                if !genericWords.contains(candidate),
                   Int(candidate) == nil {
                    return true
                }
            }

            // "windows for Notes" / "windows in Notes" name the app after
            // an explicit scoping preposition.
            let nextIndex = words.index(after: index)
            if nextIndex < words.endIndex,
               ["for", "in", "of"].contains(words[nextIndex]) {
                var candidateIndex = words.index(after: nextIndex)
                while candidateIndex < words.endIndex,
                      ["a", "an", "the"].contains(words[candidateIndex]) {
                    candidateIndex = words.index(after: candidateIndex)
                }
                if candidateIndex < words.endIndex,
                   !genericWords.contains(words[candidateIndex]),
                   Int(words[candidateIndex]) == nil {
                    return true
                }
            }

            // "Which windows does Notes have?" is another common named-app
            // form. Auxiliary-only generic questions remain unscoped.
            if nextIndex < words.endIndex,
               ["do", "does", "did"].contains(words[nextIndex]) {
                var candidateIndex = words.index(after: nextIndex)
                while candidateIndex < words.endIndex,
                      ["a", "an", "the"].contains(words[candidateIndex]) {
                    candidateIndex = words.index(after: candidateIndex)
                }
                if candidateIndex < words.endIndex,
                   !genericWords.contains(words[candidateIndex]),
                   Int(words[candidateIndex]) == nil {
                    return true
                }
            }
        }
        return false
    }

    /// Tests an inventory-provided application name against the trusted
    /// window-request grammar. This prevents incidental app names elsewhere in
    /// a compound prompt from becoming PID authorization evidence.
    private static func trustedPromptNamesWindowApplication(
        _ applicationName: String,
        prompt: String
    ) -> Bool {
        let promptWords = normalizedEntity(prompt).split(separator: " ")
            .map(String.init)
        let applicationWords = normalizedEntity(applicationName)
            .split(separator: " ")
            .map(String.init)
        guard !applicationWords.isEmpty,
              promptWords.count >= applicationWords.count else { return false }

        for start in 0 ... (promptWords.count - applicationWords.count) {
            let end = start + applicationWords.count
            guard Array(promptWords[start ..< end]) == applicationWords else {
                continue
            }

            // "Notes windows" / "Notes open windows". An optional app noun
            // supports natural forms such as "Notes app windows".
            var suffix = end
            if suffix < promptWords.count,
               ["app", "application"].contains(promptWords[suffix]) {
                suffix += 1
            }
            if suffix < promptWords.count,
               promptWords[suffix] == "open" {
                suffix += 1
            }
            if suffix < promptWords.count,
               ["window", "windows"].contains(promptWords[suffix]) {
                return true
            }

            // "windows for Notes" / "windows in Notes".
            if start >= 2,
               ["for", "in", "of"].contains(promptWords[start - 1]),
               ["window", "windows"].contains(promptWords[start - 2]) {
                return true
            }
            if start >= 3,
               ["a", "an", "the"].contains(promptWords[start - 1]),
               ["for", "in", "of"].contains(promptWords[start - 2]),
               ["window", "windows"].contains(promptWords[start - 3]) {
                return true
            }

            // "Which windows does Notes have?".
            if start >= 2,
               ["do", "does", "did"].contains(promptWords[start - 1]),
               ["window", "windows"].contains(promptWords[start - 2]),
               end < promptWords.count,
               ["have", "show"].contains(promptWords[end]) {
                return true
            }
            if start >= 3,
               ["a", "an", "the"].contains(promptWords[start - 1]),
               ["do", "does", "did"].contains(promptWords[start - 2]),
               ["window", "windows"].contains(promptWords[start - 3]),
               end < promptWords.count,
               ["have", "show"].contains(promptWords[end]) {
                return true
            }
        }
        return false
    }

    private static func applicationNameProvingPID(
        _ pid: Int,
        state: PlanningState
    ) -> String? {
        guard let inventory = state.results.reversed().first(where: {
            $0.toolName == "list_apps"
                && ($0.readProvenance == .runningApps
                    || $0.readProvenance
                        == .windowApplicationInventoryDependency)
        }),
        !inventory.wasTruncated,
        case .object(let root)? = inventory.structuredContent,
        root["ok"] == .bool(true),
        case .array(let apps)? = root["apps"] else { return nil }

        var candidates: [(name: String, pid: Int)] = []
        for value in apps {
            guard case .object(let app) = value,
                  let name = projectedString(app["name"]),
                  case .integer(let candidatePID)? = app["pid"] else {
                return nil
            }
            if trustedPromptNamesWindowApplication(
                name,
                prompt: state.trustedUserPrompt) {
                candidates.append((name: name, pid: candidatePID))
            }
        }

        // One exact inventory row must uniquely bind the trusted app name to
        // the requested PID. Duplicate names, duplicate rows, and multiple
        // PIDs are all ambiguous and therefore fail closed.
        guard candidates.count == 1,
              candidates[0].pid == pid else { return nil }
        return candidates[0].name
    }

    private static func trustedPromptContainsEntity(
        _ entity: String,
        prompt: String
    ) -> Bool {
        let normalized = normalizedEntity(entity)
        guard normalized.count >= 2 else { return false }
        let promptValue = " \(normalizedEntity(prompt)) "
        return promptValue.contains(" \(normalized) ")
    }

    private static func contactMatchesQuery(
        _ query: String,
        name: String,
        phones: [String],
        emails: [String]
    ) -> Bool {
        let queryValue = normalizedEntity(query)
        guard !queryValue.isEmpty else { return false }
        return ([name] + phones + emails).contains {
            let value = " \(normalizedEntity($0)) "
            return value.contains(" \(queryValue) ")
        }
    }

    private static func normalizedEntity(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars
            .split(whereSeparator: {
                !CharacterSet.alphanumerics.contains($0)
            })
            .map(String.init)
            .joined(separator: " ")
    }

    private static func projectedString(
        _ value: MCPJSONValue?,
        maximumCharacters: Int = 160
    ) -> String? {
        guard case .string(let raw)? = value else { return nil }
        let withoutControls = raw.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        let normalized = withoutControls
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.isEmpty,
              normalized.count <= maximumCharacters else { return nil }
        return normalized
    }

    private static func projectedStringArray(
        _ value: MCPJSONValue?
    ) -> [String]? {
        guard case .array(let values)? = value else { return nil }
        var result: [String] = []
        result.reserveCapacity(values.count)
        for value in values {
            guard let string = projectedString(value) else { return nil }
            result.append(string)
        }
        return result
    }

    private static func projectedValues(
        _ values: [String],
        requireAll: Bool
    ) -> String? {
        guard !values.isEmpty else { return "none" }
        if requireAll {
            return values.joined(separator: ", ")
        }
        let visible = values.prefix(3).joined(separator: ", ")
        guard values.count > 3 else { return visible }
        return "\(visible) (+\(values.count - 3) more)"
    }

    private static func projectedList(
        heading: String,
        empty: String,
        rows: [String],
        requireAll: Bool
    ) -> String? {
        guard !rows.isEmpty else { return empty }
        var answer = heading
        var visibleCount = 0
        for row in rows {
            let next = "\n\(visibleCount + 1). \(row)"
            guard answer.count + next.count <= 1_800 else {
                if requireAll { return nil }
                break
            }
            answer += next
            visibleCount += 1
        }
        guard visibleCount > 0 else { return nil }
        if visibleCount < rows.count {
            guard !requireAll else { return nil }
            answer += "\nShowing \(visibleCount) of \(rows.count) results."
        }
        return answer
    }

    private static func boundedCollectionHeading(
        _ name: String,
        limit: Int?,
        trustedPrompt: String
    ) -> String {
        let domains = explicitlyRequestedReadDomains(trustedPrompt)
        let userExplicitlyBoundedThisCollection = domains.count == 1
            && requestedResultLimit(trustedPrompt) != nil
        guard let limit,
              !userExplicitlyBoundedThisCollection else {
            return "\(name):"
        }
        return "\(name) (showing up to \(limit)):"
    }

    /// Explicit "all" / "every" requests may only complete when host
    /// projection can include every typed value and row. Ordinary reads retain
    /// the concise bounded summary behavior.
    private static func requiresExhaustiveProjection(
        _ prompt: String,
        domain: ReadDomain
    ) -> Bool {
        guard explicitlyRequestedReadDomains(prompt).contains(domain) else {
            return false
        }
        let words = Set(prompt.lowercased().split {
            !$0.isLetter && !$0.isNumber
        }.map(String.init))
        return words.contains("all") || words.contains("every")
    }

    private static func projectedAccessibilityStatus(_ value: String) -> String? {
        switch value.lowercased() {
        case "granted": return "granted"
        case "denied": return "denied"
        case "not granted", "not_granted": return "not granted"
        case "unknown": return "unknown"
        default: return nil
        }
    }

    private nonisolated static func requestsConsequentialMutation(
        _ prompt: String
    ) -> Bool {
        let words = Set(prompt.lowercased().split {
            !$0.isLetter && !$0.isNumber
        }.map(String.init))
        let requestPairs: [([String], [String])] = [
            (["send", "compose", "draft"], ["email", "mail", "message"]),
            (["create", "add", "schedule"], ["event", "appointment", "reminder"]),
            (["run"], ["shortcut"]),
            (["order", "buy", "purchase", "pay"], [
                "order", "food", "item", "purchase", "bill", "payment",
            ]),
            (["submit"], ["form", "application", "order", "payment"]),
        ]
        return requestPairs.contains { verbs, nouns in
            verbs.contains(where: words.contains)
                && nouns.contains(where: words.contains)
        }
    }

    private static func progressMessage(for toolName: String) -> String {
        switch toolName {
        case "contacts_search": return "Looking in Contacts on this Mac…"
        case "calendar_list_events": return "Checking Calendar on this Mac…"
        case "reminders_list": return "Checking Reminders on this Mac…"
        default: return "Using a local Mac tool…"
        }
    }

    private static func boundedResult(_ value: String) -> String {
        let flattened = value.replacingOccurrences(of: "\u{0}", with: "")
        return String(flattened.prefix(maximumResultCharactersPerStep))
    }

    private static func boundedFailure(_ value: String) -> String {
        let bounded = boundedResult(value)
        return bounded.isEmpty
            ? "The local Mac tool could not complete that step."
            : bounded
    }

    private static func canTryNativeAlternative(
        after error: AppleFoundationMCPPlannerError
    ) -> Bool {
        switch error {
        case .unavailable, .unsupportedSchema, .generationFailed, .noProposal:
            return true
        case .invalidRequest(let reason):
            return reason == "No structured tools are available."
        case .unknownProposal, .multipleProposals, .argumentsTooLarge,
             .responseTooLarge, .cancelled:
            return false
        }
    }

}

/// A typed, bounded operation shared by Accessibility text-area editors. It
/// handles only a whole current-document read; transformations and compound
/// tasks keep their normal planner path. Helper text is data, never a prompt.
enum ComputerUseMCPFocusedTextRead {
    static func matches(_ prompt: String, application: String?) -> Bool {
        guard prompt.utf8.count <= 2_000 else { return false }
        let input = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = application.map { "(?:" + NSRegularExpression.escapedPattern(for: $0) + #"\s+)?"# } ?? ""
        let target = #"(?:the\s+)?(?:current|open|focused|frontmost|active)\s+"# + app + #"(?:document|editor|text\s+area)"#
        let content = #"(?:the\s+)?(?:(?:complete|full|entire)\s+|all\s+(?:of\s+)?(?:the\s+)?)?(?:text|contents?)"#
        let polite = #"(?:please[ ,]+)?(?:(?:can|could|would)\s+you\s+)?"#
        let operation = #"(?:(?:read|show|display|get|give|tell)\s+(?:me\s+)?"# + content + #"\s+(?:of|in|from)\s+"# + target
            + #"|read\s+(?:me\s+)?"# + target
            + #"|what\s+does\s+"# + target + #"\s+say"#
            + #"|what(?:\s+is|['’]s)\s+(?:written\s+in\s+"# + target + "|" + content + #"\s+(?:of|in)\s+"# + target + "))"
        return input.range(of: "^" + polite + operation + #"[.?!]*$"#,
                           options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func elementID(in result: MCPToolResult, matching snapshot: ComputerUseMCPFocusedTextSnapshot) -> String? {
        guard snapshot.isReadable, let root = successfulObject(result),
              root["pid"]?.exactInteger == Int(snapshot.window.applicationProcessIdentifier),
              root["limit_reached"] == .bool(false), case .array(let rows)? = root["elements"],
              root["count"]?.exactInteger == rows.count else { return nil }
        var ids = Set<String>(), matches: [String] = []
        for row in rows {
            guard case .object(let fields) = row, case .string(let id)? = fields["id"],
                  !id.isEmpty, ids.insert(id).inserted else { return nil }
            if fields["role"] == .string(snapshot.role), let frame = frame(fields), frame == snapshot.frame {
                matches.append(id)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func text(in result: MCPToolResult, elementID: String, matching snapshot: ComputerUseMCPFocusedTextSnapshot) -> String? {
        guard snapshot.isReadable, let root = successfulObject(result),
              root["element_id"] == .string(elementID), case .object(let values)? = root["values"],
              values["AXRole"] == .string(snapshot.role), case .string(let value)? = values["AXValue"],
              value.utf8.elementsEqual(snapshot.text.value.utf8) else { return nil }
        if let unavailable = root["unavailable"] {
            guard case .array(let names) = unavailable,
                  !names.contains(.string("AXRole")), !names.contains(.string("AXValue")) else { return nil }
        }
        return value
    }

    private static func successfulObject(_ result: MCPToolResult) -> [String: MCPJSONValue]? {
        guard !result.isError, !result.wasTruncated, case .object(let root)? = result.structuredContent,
              root["ok"] == .bool(true) else { return nil }
        return root
    }

    private static func frame(_ fields: [String: MCPJSONValue]) -> CGRect? {
        func number(_ value: MCPJSONValue?) -> Double? {
            switch value {
            case .integer(let value): return Double(value)
            case .double(let value) where value.isFinite: return value
            default: return nil
            }
        }
        guard case .object(let position)? = fields["position"], case .object(let size)? = fields["size"],
              let x = number(position["x"]), let y = number(position["y"]),
              let width = number(size["width"]), let height = number(size["height"]), width > 0, height > 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

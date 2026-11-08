import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import LocalAgentKit

/// What the host manager needs from whichever agent engine it runs.
@MainActor
protocol AgentTaskAdapting: ComputerUseTaskAwareExecuting, ComputerUseClarificationContinuing {
    var hasRetainedTask: Bool { get }
    var readyDetail: String { get }
    func execute(taskID: String, modelPrompt: String, currentUserPrompt: String,
                 conversation: [ComputerUseConversationTurn], tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult
    func ownsApproval(_ request: AgentApprovalRequest, hostTaskID: String) -> Bool
    func ownsTaskMemoryContinuation(rootTaskID: String, originatingHostTaskID: String, currentHostTaskID: String) -> Bool
    func resumeApproval(request: AgentApprovalRequest, approved: Bool,
                        progress: @escaping (String) -> Void) async -> ComputerUseExecutionResult
    func pauseAgent() async
    func requestPause()
    func requestCancellation()
    func cancelAgent() async
#if DEBUG
    func debugPendingApproval(taskID: String, requestID: UUID) -> AgentLoop.PendingStep?
#endif
}

extension AgentCapabilityAdapter: AgentTaskAdapting {}

/// Sends the local agent's input through the host's gated injector, so Stop,
/// takeover and physical intervention cut it off at the same boundary as all other
/// input, and the manager can tell its events from a person's.
final class InjectorInputSink: InputSink, @unchecked Sendable {
    private let injector: InputInjector
    private let gate: () -> Bool

    init(injector: InputInjector, mayAct: @escaping () -> Bool) {
        self.injector = injector
        self.gate = mayAct
    }

    func mayAct() -> Bool { gate() }

    private func send(_ message: ControlMessage) throws {
        guard injector.apply(message, ifAllowed: gate) else { throw ActuationError.stopped }
    }

    func perform(_ effect: () throws -> Void) throws {
        do { try injector.performHostEffectIfAllowed(ifAllowed: gate, effect) }
        catch InputInjector.AutomationGateError.interrupted { throw ActuationError.stopped }
    }

    func move(to point: CGPoint) async throws {
        try send(.pointer(x: Int(point.x), y: Int(point.y), buttons: 0))
    }

    func click(at point: CGPoint, right: Bool, count: Int) async throws {
        let x = Int(point.x), y = Int(point.y)
        let button: UInt8 = right ? 0b010 : 0b001
        try send(.pointer(x: x, y: y, buttons: 0))
        try await Task.sleep(for: .milliseconds(40))
        for _ in 0..<max(1, count) {
            try send(.pointer(x: x, y: y, buttons: button))
            try send(.pointer(x: x, y: y, buttons: 0))
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func drag(from: CGPoint, to: CGPoint) async throws {
        try send(.pointer(x: Int(from.x), y: Int(from.y), buttons: 0))
        try send(.pointer(x: Int(from.x), y: Int(from.y), buttons: 1))
        try await Task.sleep(for: .milliseconds(80))
        for step in 1...12 {
            let t = Double(step) / 12
            try send(.pointer(x: Int(from.x + (to.x - from.x) * t), y: Int(from.y + (to.y - from.y) * t), buttons: 1))
            try await Task.sleep(for: .milliseconds(16))
        }
        try send(.pointer(x: Int(to.x), y: Int(to.y), buttons: 0))
    }

    func scroll(at point: CGPoint, dx: Int, dy: Int) async throws {
        // The injector scrolls in pixels; the harness speaks in lines.
        try send(.scroll(x: Int(point.x), y: Int(point.y), dx: dx * 12, dy: dy * 12, phase: .changed))
    }

    func key(code: CGKeyCode, flags: CGEventFlags) async throws {
        guard let usage = Self.usage(for: code) else { throw ActuationError.unavailable("that key can't be sent") }
        var modifiers: UInt16 = 0
        if flags.contains(.maskShift) { modifiers |= 1 }
        if flags.contains(.maskControl) { modifiers |= 2 }
        if flags.contains(.maskAlternate) { modifiers |= 4 }
        if flags.contains(.maskCommand) { modifiers |= 8 }
        do { try injector.applyHostKeyStroke(usage: usage, modifiers: modifiers, ifAllowed: gate, beforePosting: {}) }
        catch InputInjector.AutomationGateError.interrupted { throw ActuationError.stopped }
    }

    func type(_ text: String) async throws {
        let gate = self.gate
        let injector = self.injector
        let delivered = await MainActor.run { Task { @MainActor in await injector.applyTextPaced(text, ifAllowed: gate) } }.value
        guard delivered else { throw ActuationError.stopped }
    }

    private static let usageByKeyCode: [CGKeyCode: Int] = {
        var map: [CGKeyCode: Int] = [:]
        for usage in 0...0xFF {
            if let code = HIDUsage.toMacKeyCode(usage), map[CGKeyCode(code)] == nil { map[CGKeyCode(code)] = usage }
        }
        return map
    }()

    private static func usage(for code: CGKeyCode) -> Int? { usageByKeyCode[code] }
}

/// Presents the local agent through the host's existing task, approval and
/// clarification APIs, so the phone app and its transport don't change.
@MainActor
final class LocalAgentCapabilityAdapter: AgentTaskAdapting {
    private struct PendingQuestion {
        let hostTaskID: String
        var goal: ComputerUseUnresolvedTextGoal
        let question: UserQuestion
        let choicesByID: [String: String]
    }

    typealias HarnessFactory = @MainActor (_ goal: String, _ prior: [String]) -> AgentHarness

    private let makeHarness: HarnessFactory
    private var harness: AgentHarness?
    private var rootTaskID: String?
    private var hostTaskID: String?
    private var goal: ComputerUseUnresolvedTextGoal?
    private var pendingQuestion: PendingQuestion?
    private var pendingApproval: (request: AgentApprovalRequest, inner: ApprovalRequest)?
    private var runCalls = 0
    private let runtimeLabel: String

    init(runtimeLabel: String, makeHarness: @escaping HarnessFactory) {
        self.runtimeLabel = runtimeLabel
        self.makeHarness = makeHarness
    }

    let isReady = true
    let requiresMacControlHelper = false
    let hasAdditionalSetup = false
    var runtimeName: String { runtimeLabel }
    var readyDetail: String { "Your local agent is ready" }
    var hasRetainedTask: Bool { harness.map { !$0.finished } ?? false }

#if DEBUG
    func debugPendingApproval(taskID: String, requestID: UUID) -> AgentLoop.PendingStep? { nil }
#endif

    // MARK: Starting

    func execute(prompt: String, tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        try await begin(taskID: UUID().uuidString, prompt: prompt, conversation: [], progress: progress)
    }

    func execute(taskID: String, prompt: String, trustedUserPrompt: String, tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        try await begin(taskID: taskID, prompt: trustedUserPrompt, conversation: [], progress: progress)
    }

    func execute(taskID: String, modelPrompt: String, currentUserPrompt: String,
                 conversation: [ComputerUseConversationTurn], tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        try await begin(taskID: taskID, prompt: currentUserPrompt, conversation: conversation, progress: progress)
    }

    private func begin(taskID: String, prompt: String, conversation: [ComputerUseConversationTurn],
                       progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        // Same task again means Resume after a pause or takeover.
        if rootTaskID == taskID || hostTaskID == taskID, let harness, !harness.finished {
            return await drive(harness, progress: progress) { await harness.resumeAfterPause() }
        }
        guard harness == nil || harness?.finished == true || pendingQuestion != nil else {
            throw LocalAgentError.taskAlreadyActive
        }
        // A fresh request replaces a question nobody answered.
        harness?.cancelRequested = true
        let priorTurns = conversation.suffix(6).map { "\($0.role == .user ? "User" : "You"): \($0.text.prefix(200))" }
        let created = makeHarness(prompt, priorTurns)
        harness = created
        rootTaskID = taskID
        hostTaskID = taskID
        goal = try ComputerUseUnresolvedTextGoal(userRequest: prompt)
        pendingQuestion = nil
        pendingApproval = nil
        return await drive(created, progress: progress) { await created.run() }
    }

    /// Runs one stretch of the task off the main thread, so a slow model never
    /// stalls the host's video and input, then translates how it stopped.
    private func drive(_ harness: AgentHarness, progress: @escaping (String) -> Void,
                       body: @escaping @Sendable () async -> HarnessOutcome) async -> ComputerUseExecutionResult {
        harness.onProgress = { text in Task { @MainActor in progress(text) } }
        runCalls += 1
        defer { runCalls -= 1 }
        let outcome = await Task.detached(priority: .userInitiated, operation: body).value
        return present(outcome)
    }

    private func present(_ outcome: HarnessOutcome) -> ComputerUseExecutionResult {
        switch outcome {
        case let .completed(answer, _):
            pendingQuestion = nil
            return .completed(answer.isEmpty ? "Done." : answer)
        case let .failed(reason):
            pendingQuestion = nil
            return .unableToComplete(reason)
        case let .needsApproval(inner):
            let request = AgentApprovalRequest(
                id: inner.id, taskID: rootTaskID ?? "", scopeIdentity: "local-agent",
                fingerprint: Self.approvalMarker + inner.fingerprint, riskTier: inner.high ? .high : .medium,
                reason: inner.reason, action: .askUser(question: inner.actionSummary, choices: nil),
                reviewFields: [.init(label: "Next step", value: inner.actionSummary)])
            pendingApproval = (request, inner)
            return .agentApprovalRequired(request)
        case let .needsAnswer(question):
            guard let goal, let hostTaskID else { return .unableToComplete("The question has no task to go with it.") }
            let pairs = question.choices.enumerated().map { (Self.choiceID(question.id, $0.offset), $0.element) }
            pendingQuestion = PendingQuestion(hostTaskID: hostTaskID, goal: goal, question: question,
                                              choicesByID: Dictionary(pairs, uniquingKeysWith: { first, _ in first }))
            return .clarificationRequired(question.question)
        case let .handoff(reason):
            return .userInterventionRequired(reason)
        case .paused:
            return .userInterventionRequired("Paused. Choose Resume to continue.")
        case .cancelled:
            pendingQuestion = nil
            return .unableToComplete("Stopped.")
        }
    }

    /// Tells the manager this approval carries a plain-language summary rather than raw action JSON.
    static let approvalMarker = "local-agent:"

    // MARK: Approvals

    func ownsApproval(_ request: AgentApprovalRequest, hostTaskID: String) -> Bool {
        pendingApproval?.request.id == request.id && hostTaskID == self.hostTaskID
    }

    func ownsTaskMemoryContinuation(rootTaskID: String, originatingHostTaskID: String, currentHostTaskID: String) -> Bool {
        guard self.rootTaskID == rootTaskID else { return false }
        if let pendingQuestion {
            return pendingQuestion.hostTaskID == originatingHostTaskID && hostTaskID == originatingHostTaskID
        }
        return hostTaskID == currentHostTaskID
    }

    func resumeApproval(request: AgentApprovalRequest, approved: Bool,
                        progress: @escaping (String) -> Void) async -> ComputerUseExecutionResult {
        guard let pending = pendingApproval, pending.request.id == request.id, let harness else {
            return .unableToComplete("This approval is no longer current.")
        }
        pendingApproval = nil
        let id = pending.inner.id
        return await drive(harness, progress: progress) { await harness.resume(approval: id, approved: approved) }
    }

    // MARK: Questions

    func clarification(taskID: String) throws -> ComputerUseClarificationQuestion? {
        guard let pending = pendingQuestion, pending.hostTaskID == taskID else { return nil }
        let choices = try pending.question.choices.enumerated().map { index, label in
            try ComputerUseClarificationChoice(id: Self.choiceID(pending.question.id, index), label: label)
        }
        try ComputerUseClarificationChoice.validate(choices)
        return ComputerUseClarificationQuestion(
            taskID: taskID, goal: pending.goal, question: pending.question.question,
            scope: Self.scope(pending.question.id), expiresAt: Date().addingTimeInterval(600), choices: choices)
    }

    func continueClarification(taskID: String, originatingTaskID: String, goal suppliedGoal: ComputerUseUnresolvedTextGoal,
                               progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        try await continueClarification(taskID: taskID, originatingTaskID: originatingTaskID, goal: suppliedGoal,
                                        selectedChoice: nil, progress: progress)
    }

    func continueClarification(taskID: String, originatingTaskID: String, goal suppliedGoal: ComputerUseUnresolvedTextGoal,
                               selectedChoice: ComputerUseClarificationChoice?,
                               progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        guard let pending = pendingQuestion, pending.hostTaskID == originatingTaskID,
              hostTaskID == originatingTaskID, let harness else { throw LocalAgentError.invalidClarification }
        let answer: String
        let nextGoal: ComputerUseUnresolvedTextGoal
        if let selectedChoice {
            guard pending.choicesByID[selectedChoice.id] == selectedChoice.label, suppliedGoal == pending.goal else {
                throw LocalAgentError.invalidClarification
            }
            answer = selectedChoice.label
            nextGoal = pending.goal
        } else {
            guard let latest = suppliedGoal.userTurns.last,
                  let expected = try? pending.goal.answering(pending.question.question, with: latest),
                  expected == suppliedGoal else { throw LocalAgentError.invalidClarification }
            answer = latest
            nextGoal = suppliedGoal
        }
        pendingQuestion = nil
        hostTaskID = taskID
        goal = nextGoal
        return await drive(harness, progress: progress) { await harness.resume(answer: answer) }
    }

    func invalidateClarification(taskID: String?) {
        guard taskID == nil || pendingQuestion?.hostTaskID == taskID else { return }
        pendingQuestion = nil
    }

    // MARK: Pause and stop

    func requestPause() { harness?.pauseRequested = true }
    func requestCancellation() { harness?.cancelRequested = true }

    func pauseAgent() async {
        harness?.pauseRequested = true
        await waitForRun()
    }

    func cancelAgent() async {
        harness?.cancelRequested = true
        await waitForRun()
        harness = nil
        rootTaskID = nil
        hostTaskID = nil
        goal = nil
        pendingQuestion = nil
        pendingApproval = nil
    }

    private func waitForRun() async {
        // Dropping the model request makes this quick, but never hang Stop on it.
        let deadline = Date().addingTimeInterval(3)
        while runCalls > 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
    }

    private static func choiceID(_ id: UUID, _ index: Int) -> String {
        "agent-choice-\(id.uuidString.lowercased())-\(index)"
    }

    private static func scope(_ id: UUID) -> String {
        SHA256.hash(data: Data(id.uuidString.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum LocalAgentError: Error, Equatable {
    case taskAlreadyActive, invalidClarification
}

/// Builds the local agent from the verified model package and the bundled runtime: a computer-use
/// model that sees and acts and, when the package has one, a small model that plans around it.
@MainActor
enum LocalAgentHostFactory {
    /// Enough for a long task without compaction on any model in the package.
    private static let contextTokens = 131_072
    private static let runtimeName = "llama-b12144"

    static func make(receipt: ComputerUseInstallationReceipt, injector: InputInjector, mayAct: @escaping () -> Bool,
                     bundle: Bundle = .main) throws -> ComputerUseCapabilityExecutor {
        let inputs = try resolveInputs(receipt: receipt, bundle: bundle)
        let dialect = CUADialect.fara
        // These stay warm between tasks and free their memory after ten idle minutes.
        let workerServer = server(binary: inputs.server, model: inputs.worker, projector: inputs.projector,
                                  pidFile: "local-agent-server.pid") {
            $0.extraArguments = dialect.serverArguments
            $0.templateOptions = dialect.templateOptions
        }
        let plannerServer = inputs.planner.map { planner in
            server(binary: inputs.server, model: planner, projector: nil, pidFile: "local-agent-planner.pid") {
                // A planner answers in a strict JSON shape, with no thinking aloud first.
                $0.templateOptions = ["enable_thinking": false]
            }
        }
        let input = InjectorInputSink(injector: injector, mayAct: mayAct)
        let adapter = LocalAgentCapabilityAdapter(runtimeLabel: "Local Agent") { goal, prior in
            let worker = CUAWorker(model: workerServer, dialect: dialect)
            worker.contextTokens = contextTokens
            var configuration = HarnessConfiguration()
            configuration.budget = ContextBudget(contextTokens: contextTokens)
            configuration.orchestrated = plannerServer != nil
            configuration.workerFirst = plannerServer != nil
            configuration.planFirst = plannerServer != nil
            return AgentHarness(goal: goal, model: plannerServer ?? workerServer, actuator: Actuator(input: input),
                                configuration: configuration, priorContext: prior, worker: worker)
        }
        return ComputerUseCapabilityExecutor(agentAdapter: adapter)
    }

    private static func server(binary: URL, model: URL, projector: URL?, pidFile: String,
                               configure: (inout LlamaServer.Configuration) -> Void) -> LlamaServer {
        var configuration = LlamaServer.Configuration(serverBinary: binary, modelFile: model, projectorFile: projector,
                                                      contextTokens: contextTokens)
        configuration.pidFile = HostComputerUseManager.modelDirectoryURL.appendingPathComponent(pidFile)
        configure(&configuration)
        let server = LlamaServer(configuration: configuration)
        server.reapStaleServer()
        return server
    }

    private static func resolveInputs(receipt: ComputerUseInstallationReceipt,
                                      bundle: Bundle) throws -> (server: URL, worker: URL, projector: URL, planner: URL?) {
        let manifest = ComputerUseArtifactManifest.current
        guard receipt.modelVariant == manifest.modelVariant,
              let weights = manifest.modelArtifacts.first(where: { $0.kind == .textModelShard }),
              let projector = manifest.modelArtifacts.first(where: { $0.kind == .visionProjector }) else {
            throw OSAtlasRuntimeInstallationError.invalidReceipt
        }
        let directory = HostComputerUseManager.modelDirectoryURL
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(manifest.installationVersion, isDirectory: true)
        let planner = manifest.modelArtifacts.first { $0.kind == .nativeTextPlannerModel }
        return (try bundledServer(in: bundle),
                directory.appendingPathComponent(weights.fileName),
                directory.appendingPathComponent(projector.fileName),
                planner.map { directory.appendingPathComponent($0.fileName) })
    }

    /// Only ever the signed copy inside this app.
    private static func bundledServer(in bundle: Bundle) throws -> URL {
        guard let resources = bundle.resourceURL else { throw OSAtlasRuntimeInstallationError.bundledRuntimeMissing }
        let server = resources.appendingPathComponent("ComputerUseRuntime/\(runtimeName)/llama-server")
        let inside = bundle.bundleURL.resolvingSymlinksInPath().path + "/"
        guard FileManager.default.isExecutableFile(atPath: server.path),
              server.resolvingSymlinksInPath().path.hasPrefix(inside) else {
            throw OSAtlasRuntimeInstallationError.bundledRuntimeMissing
        }
        return server
    }
}

import CoreGraphics
import Foundation

public struct ApprovalRequest: Sendable, Equatable {
    public let id: UUID
    public let reason: String
    public let actionSummary: String
    public let fingerprint: String
    public let high: Bool
}

public struct UserQuestion: Sendable, Equatable {
    public let id: UUID
    public let question: String
    public let choices: [String]
}

public enum HarnessOutcome: Sendable, Equatable {
    case completed(answer: String, verified: Bool)
    case failed(reason: String)
    case needsApproval(ApprovalRequest)
    case needsAnswer(UserQuestion)
    case handoff(reason: String)
    case paused
    case cancelled
}

public struct HarnessConfiguration: Sendable {
    public var maximumSteps = 80
    /// Test runs keep their files here, and file dialogs may not be sent anywhere else.
    public var fileRoot: String?
    /// What can be switched to. Test runs list only their own apps.
    public var visibleApps: (@Sendable () -> [String])?
    /// Why the models may not look at what is in front right now, if so.
    public var frontFence: (@Sendable () -> String?)?
    public var timeLimit: TimeInterval = 1_800
    public var budget = ContextBudget()
    public var supportsVision = true
    public var imageMaxSide = 1_024
    public var modelTimeout: TimeInterval = 120
    public var verifyCompletion = true
    public var planFirst = true
    /// Keep the settle wait short: most UI updates land in a few hundred milliseconds.
    public var settleLimit: TimeInterval = 2.0
    /// Steps a computer-use worker gets for one job before it reports back.
    public var workerSteps = 40
    /// The main model plans, hands out jobs and checks them; the worker does the screen.
    public var orchestrated = false
    public var maximumJobs = 16
    /// Overrides of the planner's shares of its context, for experiments.
    public var plannerScreenTokens: Int?
    public var plannerLogTokens: Int?
    /// Summarizes older jobs when they outgrow the planner's context. Off, they're just cut.
    public var plannerCompaction = true
    /// The worker starts on the goal as asked; the planner comes in when it reports back.
    public var workerFirst = false
    public init() {}
}

/// What a step looked like, for the phone and the trace file.
public struct StepEvent: Sendable {
    public let step: Int
    public let narration: String
    public let thought: String
    public let toolName: String
    public let usedImage: Bool
    public let promptTokens: Int
    public let cachedTokens: Int
    public let outputTokens: Int
    public let modelSeconds: Double
    public let observeSeconds: Double
    public let result: String
}

/// The agent. Each turn: observe, fit a fresh prompt to the budget, decide (the
/// grammar guarantees a parseable action), check safety, act, measure what changed.
/// Nothing but the working memory survives from one turn to the next, so a task's
/// length never grows the prompt.
public final class AgentHarness: @unchecked Sendable {
    public let goal: String
    public let configuration: HarnessConfiguration
    public var onProgress: (@Sendable (String) -> Void)?
    public var onStep: (@Sendable (StepEvent) -> Void)?
    public var trace: TraceWriter?
    /// Private, redacted record of how tasks go. Stays on this Mac; see `TaskJournal`.
    public var journal: TaskJournal?
    public var journalModels: [String] = []
    private let journalID = UUID()
    private let journalStart = Date()
    private var journalApps = Set<String>()
    private var journalSites = Set<String>()

    let model: ModelClient
    let builder: any SceneSource
    let actuator: Actuator
    private let safety = SafetyPolicy()
    private let estimator = TokenEstimator()
    public let memory: WorkingMemory
    /// The computer-use model, when there is one. Without it the main model acts by itself.
    public let worker: CUAWorker?
    private var supervisor = Supervisor()
    private var budget: ContextBudget

    var scene: Scene?
    private var previousScene: Scene?
    var step = 0
    private var startedAt: Date?
    var startedAtForWorker: Date? { startedAt }
    var planned = false
    private var forceImageOnce = false
    private var zoomRegion: CGRect?
    var nudge: String?
    private var pinnedIDs = Set<Int>()
    private var searchResults: [Int: UIElement] = [:]
    private var searchScene: Scene?
    private var doneRejections = 0
    var modelFailures = 0
    private var denied = Set<String>()
    private var approved = Set<String>()
    private var denialCount = 0
    private var pendingApproval: (request: ApprovalRequest, decision: AgentDecision, scene: Scene)?
    var pendingQuestion: UserQuestion?
    var orchestration = OrchestrationState()
    private var pendingStopReason: String?
    private var lastImageSize: CGSize = .zero
    private var lastThought = ""
    var preflightDone = false

    private let flagLock = NSLock()
    private var _cancelRequested = false
    private var _pauseRequested = false
    private var isFinished = false

    public init(goal: String, model: ModelClient, actuator: Actuator, builder: any SceneSource = SceneBuilder(),
                configuration: HarnessConfiguration = .init(), priorContext: [String] = [], worker: CUAWorker? = nil) {
        self.goal = goal
        self.model = model
        self.actuator = actuator
        self.builder = builder
        self.configuration = configuration
        self.budget = configuration.budget
        self.memory = WorkingMemory(goal: goal, estimator: estimator)
        self.worker = worker
        for line in priorContext.suffix(4) { memory.addNote("Earlier in this chat: \(line)") }
    }

    // MARK: Controls (safe from any thread)

    public var cancelRequested: Bool {
        get { flagLock.withLock { _cancelRequested } }
        set {
            flagLock.withLock { _cancelRequested = newValue }
            if newValue { model.cancelInFlight() }
        }
    }

    public var pauseRequested: Bool {
        get { flagLock.withLock { _pauseRequested } }
        set {
            flagLock.withLock { _pauseRequested = newValue }
            if newValue { model.cancelInFlight() }
        }
    }

    public var finished: Bool { flagLock.withLock { isFinished } }
    public var currentApproval: ApprovalRequest? { pendingApproval?.request }
    public var currentQuestion: UserQuestion? { pendingQuestion }

    // MARK: Entry points

    public func run() async -> HarnessOutcome {
        if let pendingApproval { return .needsApproval(pendingApproval.request) }
        if let pendingQuestion { return .needsAnswer(pendingQuestion) }
        return await loop()
    }

    public func resume(approval id: UUID, approved isApproved: Bool) async -> HarnessOutcome {
        guard let pending = pendingApproval, pending.request.id == id else {
            return .failed(reason: "That approval is no longer current.")
        }
        pendingApproval = nil
        if !isApproved {
            denied.insert(pending.request.fingerprint)
            denialCount += 1
            record(pending.decision.call, action: describe(pending.decision.call, in: pending.scene),
                   result: "the user declined this", hadEffect: false, scene: pending.scene)
            // A "no" ends the task. Only consequential steps ask, and they are usually the point
            // of the request, so looking for another way would work around the person's answer.
            // They can send a new request if they want something else.
            return finish(.failed(reason: "You declined, so I stopped before this step: \(pending.request.actionSummary)"))
        }
        approved.insert(pending.request.fingerprint)
        // The screen may have moved on while the phone was asked. Only carry out what
        // was approved, on the same target.
        var fresh = await observe()
        // A native action's coordinates belong to the frame the model was shown.
        if worker != nil { fresh.screenshot = pending.scene.screenshot }
        if let staleReason = approvalTargetChanged(pending.decision.call, from: pending.scene, to: fresh) {
            record(pending.decision.call, action: describe(pending.decision.call, in: pending.scene),
                   result: "not done: \(staleReason)", hadEffect: false, scene: fresh)
            return await loop()
        }
        if let outcome = await execute(pending.decision, on: fresh, approvedAlready: true) { return outcome }
        return await loop()
    }

    public func resume(answer: String) async -> HarnessOutcome {
        pendingQuestion = nil
        memory.addUserReply(answer)
        worker?.feedback = "The person answered: \(answer)"
        orchestration.note("The person said: \(answer)")
        supervisor.resetSceneMemory()
        return await loop()
    }

    /// Continue after the person took over or the task was paused.
    public func resumeAfterPause() async -> HarnessOutcome {
        pauseRequested = false
        supervisor.resetSceneMemory()
        return await run()
    }

    // MARK: Main loop

    private func loop() async -> HarnessOutcome {
        if startedAt == nil { startedAt = Date() }
        if !preflightDone {
            preflightDone = true
            let current = await observe()
            if let call = Preflight.firstAction(for: goal, currentURL: current.url, openApps: switchableApps, appExists: { AppCatalog.shared.resolve($0) != nil }) {
                step += 1
                onProgress?(describeForPerson(call, in: current))
                let decision = AgentDecision(thought: "", planStep: nil, call: call)
                if let outcome = await execute(decision, on: current, approvedAlready: false) { return outcome }
            }
        }
        if !planned, configuration.planFirst, !(worker != nil && configuration.orchestrated) {
            planned = true
            if let outcome = stopCheck() { return outcome }
            await makePlan()
        }
        if worker != nil { return configuration.orchestrated ? await orchestratedLoop() : await workerLoop() }
        while true {
            if let outcome = stopCheck() { return outcome }
            guard step < configuration.maximumSteps else {
                return finish(.failed(reason: "Stopped after \(step) actions without finishing. So far: \(memory.summary())"))
            }
            if let startedAt, Date().timeIntervalSince(startedAt) > configuration.timeLimit {
                return finish(.failed(reason: "Stopped after \(Int(configuration.timeLimit / 60)) minutes without finishing. So far: \(memory.summary())"))
            }

            let observeStart = Date()
            let current = await observe()
            let observeSeconds = Date().timeIntervalSince(observeStart)
            if let outcome = stopCheck() { return outcome }

            switch supervisor.inspect(records: memory.records, stepsSincePlanProgress: memory.stepsSincePlanProgress,
                                      sceneFingerprint: current.fingerprint) {
            case .proceed: break
            case .nudge(let text): nudge = text
            case .showScreenshot(let text): nudge = text; forceImageOnce = true
            case .replan(let problem):
                // Going in circles often means the job is already done and the model
                // hasn't noticed. Finding that out beats re-doing finished work.
                if let outcome = await checkIfAlreadyFinished(current) { return outcome }
                await replan(problem: problem, scene: current)
                nudge = "\(problem) The plan was changed; follow the new plan."
                forceImageOnce = true
            case .askForHelp(let reason):
                return askForHelp(reason, scene: current)
            }

            let decision: AgentDecision
            let usedImage: Bool
            let reply: ModelReply
            do {
                (decision, usedImage, reply) = try await decide(current)
            } catch is CancellationError {
                if let outcome = stopCheck() { return outcome }
                continue
            } catch let error as ToolSchema.DecodeError {
                step += 1
                nudge = "Your last reply was invalid: \(error.description)"
                continue
            } catch let error as ModelError {
                if let outcome = stopCheck() { return outcome }
                modelFailures += 1
                if modelFailures >= 3 { return finish(.failed(reason: "The local model stopped responding: \(error.description)")) }
                if error == .contextOverflow { budget = budget.shrunk() }
                if case .startupFailed(let detail) = error { return finish(.failed(reason: "The local model could not start: \(detail)")) }
                continue
            } catch {
                if let outcome = stopCheck() { return outcome }
                return finish(.failed(reason: "The local model failed: \(error)"))
            }
            modelFailures = 0
            nudge = nil
            step += 1
            lastThought = String(decision.thought.prefix(200))
            if let number = decision.planStep { memory.advance(toStep: number) }

            onStep?(StepEvent(step: step, narration: describeForPerson(decision.call, in: current), thought: decision.thought,
                              toolName: decision.call.name, usedImage: usedImage, promptTokens: reply.promptTokens,
                              cachedTokens: reply.cachedTokens, outputTokens: reply.outputTokens, modelSeconds: reply.seconds,
                              observeSeconds: observeSeconds, result: ""))
            onProgress?(describeForPerson(decision.call, in: current))

            if let outcome = await execute(decision, on: current, approvedAlready: false) { return outcome }
        }
    }

    func stopCheck() -> HarnessOutcome? {
        if cancelRequested { return finish(.cancelled) }
        if pauseRequested { return .paused }
        if Task.isCancelled { return finish(.cancelled) }
        return nil
    }

    func finish(_ outcome: HarnessOutcome) -> HarnessOutcome {
        flagLock.withLock { isFinished = true }
        AssistiveMode.release()
        trace?.write(["event": "finish", "outcome": String(describing: outcome), "steps": step])
        journal?.record(journalRecord(for: outcome))
        return outcome
    }

    private func journalRecord(for outcome: HarnessOutcome) -> TaskRecord {
        var record = TaskRecord(id: journalID, startedAt: journalStart, request: goal)
        record.seconds = Date().timeIntervalSince(journalStart)
        record.outcome = TaskRecord.outcomeName(outcome)
        record.steps = step
        record.jobs = orchestration.jobsStarted
        record.compactions = orchestration.compactions
        record.apps = journalApps.sorted()
        record.sites = journalSites.sorted()
        record.models = journalModels
        return record
    }

    // MARK: Observing

    func observe() async -> Scene {
        // Something the models shouldn't see is in front: give it a moment to go, and otherwise
        // show them nothing at all. A blank scene reads as having no window to work in.
        if let fence = configuration.frontFence {
            var waited = 0
            while fence() != nil, waited < 8 {
                try? await Task.sleep(for: .milliseconds(250))
                waited += 1
            }
            if let reason = fence() {
                trace?.write(["event": "front_fence", "reason": reason])
                return Scene()
            }
        }
        var next = await builder.build(.init())
        if !next.appName.isEmpty { journalApps.insert(next.appName) }
        if let host = next.url.flatMap(TaskJournal.siteName(from:)) { journalSites.insert(host) }
        // Elements found by an earlier search stay addressable for one more step.
        previousScene = scene
        if next.screenshot == nil { next.screenshot = scene?.screenshot }
        scene = next
        return next
    }

    /// Waits for the screen to stop changing, up to a limit, so results describe the
    /// outcome of the action rather than an animation in progress.
    func settle(limit: TimeInterval) async {
        let deadline = Date().addingTimeInterval(limit)
        try? await Task.sleep(for: .milliseconds(150))
        let rect = scene?.windowFrame.isEmpty == false ? scene!.windowFrame : ScreenCapturer.mainDisplayRect()
        var last = await builder.captureForSettling(rect: rect)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(180))
            guard !cancelRequested, let frame = await builder.captureForSettling(rect: rect) else { return }
            if let last, ScreenFrame.distance(last.signature, frame.signature) < 0.002 { return }
            last = frame
        }
    }

    // MARK: Planning

    private func describeContext(_ scene: Scene) -> String {
        let app = scene.appName.isEmpty ? "no app in front" : "\(scene.appName) is in front"
        let window = scene.windowTitle.isEmpty ? "" : ", window \"\(scene.windowTitle.prefix(60))\""
        let address = scene.url.map { ", showing \($0.prefix(80))" } ?? ""
        return app + window + address
    }

    private func makePlan() async {
        let current = await observe()
        let request = ModelRequest(messages: Prompts.planner(goal: memory.renderGoal(), context: describeContext(current)),
                                   schema: ToolSchema.planSchema, maxTokens: 180, timeout: configuration.modelTimeout * 2)
        var steps: [String] = []
        do { steps = ToolSchema.decodePlan(try await model.complete(request).text) }
        catch { trace?.write(["event": "plan_error", "error": String(describing: error)]) }
        memory.setPlan(steps.isEmpty ? [goal] : steps)
        trace?.write(["event": "plan", "steps": memory.plan.map(\.text)])
    }

    private func replan(problem: String, scene: Scene) async {
        let screen = SceneRenderer.render(scene, tokens: 500, estimator: estimator, keywords: SceneRenderer.keywords(from: goal))
        let request = ModelRequest(messages: Prompts.replanner(goal: memory.renderGoal(), doneSoFar: memory.summary(maximumLines: 10),
                                                               problem: problem, context: screen.text),
                                   schema: ToolSchema.planSchema, maxTokens: 180, timeout: configuration.modelTimeout)
        if let reply = try? await model.complete(request) {
            let steps = ToolSchema.decodePlan(reply.text)
            if !steps.isEmpty { memory.setPlan(steps) }
            trace?.write(["event": "replan", "problem": problem, "steps": steps])
        }
    }

    // MARK: Deciding

    private func decide(_ current: Scene) async throws -> (AgentDecision, Bool, ModelReply) {
        let attachImage = shouldAttachImage(current)
        let system = Prompts.system + "\n\n" + Prompts.machineFacts() + "\n" + memory.renderGoal()
        let systemTokens = estimator.estimate(system)
        let screenTokens = budget.screenTokens(systemTokens: systemTokens, withImage: attachImage)

        var keywords = SceneRenderer.keywords(from: goal)
        if let step = memory.currentStepText { keywords.formUnion(SceneRenderer.keywords(from: step)) }
        let fresh = previousScene.map { old in
            Set(current.elements.map(\.id)).subtracting(old.elements.map(\.id))
        } ?? []
        let rendered = SceneRenderer.render(current, tokens: screenTokens, estimator: estimator, keywords: keywords,
                                            freshIDs: fresh, pinned: pinnedIDs)

        var sections: [String] = []
        let plan = memory.renderPlan(tokens: budget.planTokens)
        if !plan.isEmpty { sections.append(plan) }
        let notes = memory.renderNotes(tokens: budget.notesTokens)
        if !notes.isEmpty { sections.append(notes) }
        let history = memory.renderHistory(tokens: budget.historyTokens)
        if !history.isEmpty { sections.append(history) }
        sections.append("SCREEN NOW:\n" + rendered.text)
        if !searchResults.isEmpty {
            sections.append("FOUND (usable with click):\n" + searchResults.values.sorted { $0.id < $1.id }.prefix(8)
                .map(SceneRenderer.line(for:)).joined(separator: "\n"))
        }
        // Continuity: the model's own last intent, so a multi-step idea survives between turns.
        if !lastThought.isEmpty { sections.append("YOUR LAST THOUGHT: \(lastThought)") }
        if let nudge { sections.append("IMPORTANT: \(nudge)") }
        sections.append("Reply with the next action as JSON.")
        let user = sections.joined(separator: "\n\n")

        var image: Data?
        var imageSize = CGSize.zero
        if attachImage, let frame = imageFrame(current) {
            let marks = current.elements.filter { $0.isInteractive && rendered.shownIDs.contains($0.id) }
                .map { ImageMark(id: $0.id, frame: $0.frame) }
            if let encoded = frame.encodedForModel(maxSide: configuration.imageMaxSide, marks: Array(marks.prefix(40))) {
                image = encoded.data
                imageSize = encoded.size
            }
        }
        lastImageSize = imageSize
        zoomRegion = nil
        forceImageOnce = false

        // Near the step limit, take away tools that spend steps without progress.
        let request = ModelRequest(messages: [.init(role: .system, text: system),
                                              .init(role: .user, text: user, imageJPEG: image)],
                                   schema: decisionSchema(current, shown: rendered.shownIDs), maxTokens: budget.outputTokens,
                                   timeout: configuration.modelTimeout)
        let reply = try await model.complete(request)
        if reply.promptTokens > 0 {
            let imageShare = image == nil ? 0 : budget.imageTokens
            estimator.observe(characters: system.utf8.count + user.utf8.count, tokens: max(1, reply.promptTokens - imageShare))
        }
        trace?.step(step: step + 1, system: step == 0 ? system : nil, user: user, reply: reply, image: image)
        let decision = try ToolSchema.decode(reply.text)
        return (decision, image != nil, reply)
    }

    /// Numbers can only name something listed, minus whatever just proved useless on
    /// this very screen. After several dead actions, the tool that keeps failing goes
    /// too, which forces a genuinely different move.
    private func decisionSchema(_ scene: Scene, shown: Set<Int>) -> String {
        let recent = memory.records.suffix(6)
        let dead = recent.filter { !$0.hadEffect && $0.sceneFingerprint == scene.fingerprint }
        var ids = shown.union(searchResults.keys)
        for record in dead { if let id = record.targetID { ids.remove(id) } }
        // Also anything already used twice from this exact screen: if it "worked" and
        // here we are again, it's a loop, whatever effect it appeared to have.
        var usesHere: [Int: Int] = [:]
        for record in memory.records where record.sceneFingerprint == scene.fingerprint {
            if let id = record.targetID { usesHere[id, default: 0] += 1 }
        }
        for (id, uses) in usesHere where uses >= 2 { ids.remove(id) }
        var tools = ToolSchema.allTools
        if !configuration.supportsVision { tools.removeAll { ["look", "zoom", "click_at"].contains($0) } }
        if Supervisor.noEffectStreak(Array(memory.records)) >= 3, let last = dead.last?.toolName {
            tools.removeAll { $0 == last }
        }
        return ToolSchema.decisionSchema(allowed: tools, ids: ids.isEmpty ? nil : ids.sorted())
    }

    private func shouldAttachImage(_ scene: Scene) -> Bool {
        guard configuration.supportsVision, scene.screenshot != nil else { return false }
        return forceImageOnce || zoomRegion != nil || scene.isVisuallyOpaque
    }

    private func imageFrame(_ scene: Scene) -> ScreenFrame? {
        guard let frame = scene.screenshot else { return nil }
        if let zoomRegion, let cropped = frame.cropped(to: zoomRegion) { return cropped }
        return frame
    }

    // MARK: Executing

    /// Returns an outcome to stop the loop, or nil to keep going.
    func execute(_ decision: AgentDecision, on current: Scene, approvedAlready: Bool) async -> HarnessOutcome? {
        var decision = decision
        var call = decision.call

        // Typing with no target needs somewhere to go. Pressing keys into nothing
        // is at best useless, and "clear" could wipe out whatever was selected.
        if case let .type(nil, text, clear, submit) = call, !current.usedOCR {
            let fields = current.elements.filter { $0.editable && $0.enabled && !$0.offscreen }
            if current.focused?.editable != true, !fields.isEmpty {
                if fields.count == 1 {
                    call = .type(id: fields[0].id, text: text, clear: clear, submit: submit)
                    decision.call = call
                } else {
                    let options = fields.prefix(6).map { "[\($0.id)] \"\($0.label.prefix(24))\"" }.joined(separator: ", ")
                    record(call, action: describe(call, in: current), result: "not done: no field has focus. Say which, with id: \(options)", hadEffect: false, scene: current)
                    return nil
                }
            }
        }
        call = Self.corrected(call, in: current)
        // A one-line field already holding something (a suggested name, an old search)
        // is meant to be replaced unless the model said otherwise. Documents aren't.
        if decision.clearUnspecified, case let .type(id, text, false, submit) = call,
           let target = id.flatMap({ lookup($0, in: current) }) ?? current.focused,
           target.editable, target.frame.height < 44, target.value?.isEmpty == false {
            call = .type(id: id, text: text, clear: true, submit: submit)
        }
        decision.call = call
        // Invalid target: nothing happens, the model learns why, costs one step.
        if let problem = validate(call, in: current) {
            record(call, action: describe(call, in: current), result: "not done: \(problem)", hadEffect: false, scene: current)
            return nil
        }
        if Supervisor.isPointlessRepeat(fingerprint: describe(call, in: current).lowercased(), isWait: { if case .wait = call { return true }; return false }(),
                                        records: memory.records, sceneFingerprint: current.fingerprint) {
            nudge = "That exact action already did nothing on this same screen, so it wasn't run again. Do something different."
            record(call, action: describe(call, in: current), result: "not run again: it did nothing last time", hadEffect: false, scene: current)
            forceImageOnce = true
            return nil
        }

        // The safety decision is the host's, not the model's.
        let fingerprint = approvalFingerprint(call, in: current)
        if denied.contains(fingerprint) {
            nudge = "The user already declined that. Take another way, or use fail to stop."
            record(call, action: describe(call, in: current), result: "blocked: the user already declined this", hadEffect: false, scene: current)
            return nil
        }
        if !approvedAlready, !approved.contains(fingerprint) {
            switch safety.evaluate(call, scene: current) {
            case .allow: break
            case let .approve(reason, high):
                let request = ApprovalRequest(id: UUID(), reason: reason, actionSummary: describeForPerson(call, in: current),
                                              fingerprint: fingerprint, high: high)
                pendingApproval = (request, decision, current)
                trace?.write(["event": "approval", "reason": reason])
                return .needsApproval(request)
            case .handoff(let reason):
                trace?.write(["event": "handoff", "reason": reason])
                return .handoff(reason: reason)
            case .refuse(let reason):
                record(call, action: describe(call, in: current), result: "refused: \(reason)", hadEffect: false, scene: current)
                return nil
            }
        }

        switch call {
        case let .done(answer): return await handleDone(answer, scene: current)
        case let .fail(reason): return finish(.failed(reason: reason))
        case let .askUser(question, choices):
            let asked = UserQuestion(id: UUID(), question: question, choices: choices)
            pendingQuestion = asked
            record(call, action: "asked the user: \(question.prefix(100))", result: "waiting for answer", hadEffect: true, scene: current)
            return .needsAnswer(asked)
        case .look:
            forceImageOnce = true
            record(call, action: "look", result: "screenshot shown below", hadEffect: true, scene: current)
            return nil
        case let .zoom(id):
            if let element = lookup(id, in: current) {
                zoomRegion = element.frame.insetBy(dx: -120, dy: -80)
            }
            forceImageOnce = true
            record(call, action: "zoom on [\(id)]", result: "close-up shown below", hadEffect: true, scene: current)
            return nil
        case let .note(text):
            memory.addNote(text)
            record(call, action: "noted a fact", result: "saved", hadEffect: true, scene: current)
            return nil
        case let .find(text): await handleFind(text, scene: current); return nil
        case let .read(question): await handleRead(question, scene: current); return nil
        default: break
        }

        pinnedIDs.removeAll()
        let settleLimit: TimeInterval
        switch call {
        case .openApp, .openURL: settleLimit = 4
        case .wait(let seconds): settleLimit = seconds
        default: settleLimit = configuration.settleLimit
        }

        do {
            let detail = try await perform(call, in: current)
            await settle(limit: settleLimit)
            var after = await observe()
            var diff = SceneDiff(from: current, to: after)
            var note = detail

            // AXPress can report success and do nothing. Only retry when nothing at all
            // changed, and never for an action that needed approval.
            if diff.isEmpty, !approvedAlready, case let .click(id, right, double) = call, !right, !double,
               detail == "pressed", let element = lookup(id, in: current), element.handle != nil {
                _ = try await actuator.click(element, in: current, viaPointer: true)
                await settle(limit: settleLimit)
                after = await observe()
                diff = SceneDiff(from: current, to: after)
                note = "pressed, then clicked"
            }
            // AX can claim a field has focus when the keys went elsewhere. Nothing landed,
            // so nothing is at risk: click the field for real and type once more.
            if diff.isEmpty, !approvedAlready, case let .type(id, text, clear, submit) = call,
               let target = id.flatMap({ lookup($0, in: current) }) ?? current.focused, target.editable {
                try await actuator.clickAt(target.center, in: current)
                try await Task.sleep(for: .milliseconds(150))
                _ = try await actuator.type(text, into: nil, in: current, clear: clear, submit: submit)
                await settle(limit: settleLimit)
                after = await observe()
                diff = SceneDiff(from: current, to: after)
            }
            var result = diff.summary
            if case let .type(id, text, _, _) = call { result += typingCheck(text, id: id, in: after) }
            if case let .menu(path) = call, note.hasPrefix("items:") { result = "\(path): \(note.dropFirst(7))" }
            if case .scroll = call, diff.isEmpty { result = "couldn't scroll any further" }
            if case .type = call, diff.isEmpty, current.usedOCR {
                result = "nothing appeared. This screen is read from pixels: use type with the id of the label beside the field, or click_at on the field first"
            }
            let hadEffect = !diff.isEmpty || note.hasPrefix("items:")
            record(call, action: describe(call, in: current), result: result, hadEffect: hadEffect, scene: current)
            searchResults.removeAll()
        } catch ActuationError.stopped {
            return stopCheck() ?? .paused
        } catch {
            record(call, action: describe(call, in: current), result: "failed: \(error)", hadEffect: false, scene: current)
        }
        return nil
    }

    /// Small, safe repairs of things a small model commonly gets almost right.
    static func corrected(_ call: ToolCall, in scene: Scene) -> ToolCall {
        switch call {
        case let .key(keys):
            // "34" or "hello" sent as keys is typing.
            if !keys.contains("+"), (try? KeyMap.parse(keys)) == nil { return .type(id: nil, text: keys, clear: false, submit: false) }
            return call
        case let .type(id, text, clear, submit):
            // The system's Go To Folder sheet replaces its contents and does nothing until
            // Return. It's the same on every Mac, so don't leave that to the model.
            let isPath = text.hasPrefix("/") || text.hasPrefix("~")
            if isPath, scene.elements.contains(where: { $0.label.lowercased().hasPrefix("go to") }) {
                let field = scene.focused?.editable == true ? scene.focused : scene.elements.first(where: \.editable)
                return .type(id: field?.id, text: text, clear: true, submit: true)
            }
            guard let id, let target = scene.element(id: id) else { return call }
            // Text read from pixels isn't a control. With a real field in focus, that's the target.
            if target.source == .ocr, let focus = scene.focused, focus.editable {
                return .type(id: focus.id, text: text, clear: clear, submit: submit)
            }
            // Typing "at" a button on a screen with no fields, like a calculator's keypad,
            // means using the keyboard.
            if !target.editable, target.role == "button", !scene.elements.contains(where: \.editable) {
                return .type(id: nil, text: text, clear: clear, submit: submit)
            }
            return call
        default:
            return call
        }
    }

    func perform(_ call: ToolCall, in scene: Scene) async throws -> String {
        switch call {
        case let .click(id, right, double):
            guard let element = lookup(id, in: scene) else { throw ActuationError.elementGone }
            return try await actuator.click(element, in: searchScene(for: id) ?? scene, right: right, count: double ? 2 : 1)
        case let .clickAt(x, y):
            try await actuator.clickAt(SafetyPolicy.point(x: x, y: y, in: scene), in: scene)
            return "clicked"
        case let .type(id, text, clear, submit):
            let target = id.flatMap { lookup($0, in: scene) }
            return try await actuator.type(text, into: target, in: scene, clear: clear, submit: submit)
        case let .key(chord):
            try await actuator.press(chord, in: scene)
            return "pressed"
        case let .menu(path):
            switch try await actuator.menu(path: path, in: scene) {
            case .pressed(let trail): return "chose \(trail)"
            case let .listing(parent, items):
                return "items: \(parent) contains " + items.prefix(40).joined(separator: ", ")
            }
        case let .scroll(direction, id, amount):
            try await actuator.scroll(direction: direction, amount: amount, at: id.flatMap { lookup($0, in: scene) }, in: scene)
            return "scrolled"
        case let .drag(fromID, toID):
            guard let from = lookup(fromID, in: scene), let to = lookup(toID, in: scene) else { throw ActuationError.elementGone }
            try await actuator.drag(from: from.center, to: to.center, in: scene)
            return "dragged"
        case let .openApp(name): return try await actuator.openApp(named: name)
        case let .openURL(url): return try await actuator.openURL(url)
        case let .pointAt(x, y, right, count):
            let aimed = SafetyPolicy.point(x: x, y: y, in: scene)
            try await actuator.clickAt(SafetyPolicy.nearestControl(to: aimed, in: scene) ?? aimed, in: scene, right: right, count: count)
            return "clicked"
        case let .moveTo(x, y):
            try await actuator.move(to: SafetyPolicy.point(x: x, y: y, in: scene), in: scene)
            return "moved"
        case let .dragAt(fromX, fromY, toX, toY):
            try await actuator.drag(from: SafetyPolicy.point(x: fromX, y: fromY, in: scene),
                                    to: SafetyPolicy.point(x: toX, y: toY, in: scene), in: scene)
            return "dragged"
        case let .scrollBy(pixels, horizontal, x, y):
            let at = x.flatMap { x in y.map { y in SafetyPolicy.point(x: x, y: y, in: scene) } }
            try await actuator.scroll(pixels: pixels, horizontal: horizontal, at: at, in: scene)
            return "scrolled"
        case let .typeAtFocus(text):
            try await actuator.typeAtFocus(text, in: scene)
            return "typed"
        case let .wait(seconds):
            try await Task.sleep(for: .seconds(seconds))
            return "waited"
        default:
            throw ActuationError.unavailable("that isn't an action")
        }
    }

    private func lookup(_ id: Int, in scene: Scene) -> UIElement? {
        scene.element(id: id) ?? searchResults[id]
    }

    private func searchScene(for id: Int) -> Scene? {
        searchResults[id] != nil ? searchScene : nil
    }

    private func validate(_ call: ToolCall, in scene: Scene) -> String? {
        func check(_ id: Int) -> String? {
            guard let element = lookup(id, in: scene) else { return "[\(id)] isn't on the screen now" }
            if !element.enabled { return "[\(id)] \"\(element.label.prefix(30))\" is disabled" }
            return nil
        }
        switch call {
        case let .click(id, _, _), let .zoom(id): return check(id)
        case let .type(id?, _, _, _):
            guard let problem = check(id) else {
                let element = lookup(id, in: scene)
                if element?.secure == true { return nil }
                if let element, !element.editable, element.role != "text", element.source == .accessibility {
                    if element.role == "popup" || element.role == "menubutton" {
                        return "[\(id)] is a popup: click it, then click the option you want"
                    }
                    return "[\(id)] is a \(element.role), not a text field"
                }
                return nil
            }
            return problem
        case let .scroll(_, id?, _): return check(id)
        case let .drag(from, to): return check(from) ?? check(to)
        case .look, .zoom:
            return configuration.supportsVision ? nil : "this model can't see images"
        case .clickAt:
            return worker != nil || configuration.supportsVision ? nil : "this model can't see images"
        default: return nil
        }
    }

    /// Plain-language check that the text actually arrived, using host-side state only.
    private func typingCheck(_ text: String, id: Int?, in after: Scene) -> String {
        guard let target = id.flatMap(after.element(id:)) ?? after.focused,
              target.editable, !target.secure, let value = target.value else { return "" }
        let tail = String(text.suffix(24)).lowercased()
        if value.lowercased().contains(tail) { return "; field reads \"\(SceneRenderer.truncateMiddle(value, 70))\"" }
        return "; WARNING field reads \"\(SceneRenderer.truncateMiddle(value, 70))\", which doesn't show what you typed"
    }

    func record(_ call: ToolCall, action: String, result: String, hadEffect: Bool, scene: Scene) {
        // Compare actions by what they mean, not by element number: an ID can change
        // after a window closes while "click File" is plainly the same thing again.
        var target: Int?
        switch call {
        case let .click(id, _, _): target = id
        case let .type(id, _, _, _): target = id
        default: target = nil
        }
        memory.record(.init(step: step, action: action, result: result, hadEffect: hadEffect,
                            fingerprint: action.lowercased(), sceneFingerprint: scene.fingerprint,
                            toolName: call.name, targetID: target))
        trace?.write(["event": "result", "step": step, "action": action, "result": result, "effect": hadEffect])
    }

    // MARK: Tools that don't touch the computer

    private func handleFind(_ text: String, scene current: Scene) async {
        let deep = await builder.build(.init(capture: false, deep: true))
        let needle = text.lowercased()
        let words = SceneRenderer.keywords(from: text)
        func matches(_ element: UIElement) -> Bool {
            let label = (element.label + " " + (element.value ?? "")).lowercased()
            if label.contains(needle) { return true }
            return !words.isEmpty && words.allSatisfy { label.contains($0) }
        }
        let found = deep.elements.filter(matches).prefix(8)
        searchResults = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        searchScene = deep
        pinnedIDs = Set(found.map(\.id))
        let result = found.isEmpty ? "nothing in this window matches \"\(text.prefix(40))\"" : "\(found.count) match(es) listed under FOUND"
        record(.find(text), action: "find \"\(text.prefix(40))\"", result: result, hadEffect: !found.isEmpty, scene: current)
    }

    /// Map-reduce over text too long for one prompt, so a long page or document can
    /// be read with a small context.
    private func handleRead(_ question: String, scene current: Scene) async {
        let deep = await builder.build(.init(capture: false, deep: true))
        let text = deep.fullText.isEmpty ? current.fullText : deep.fullText
        let chunkTokens = max(400, budget.contextTokens - budget.outputTokens - 500)
        let chunkCharacters = Int(Double(min(chunkTokens, 3_000)) * estimator.ratio)
        let chunks = Self.chunk(text, size: chunkCharacters, maximumChunks: 6)
        var answers: [String] = []
        for chunk in chunks {
            if cancelRequested || pauseRequested { return }
            let request = ModelRequest(messages: Prompts.reader(question: question, text: chunk), schema: nil, maxTokens: 160,
                                       timeout: configuration.modelTimeout)
            guard let reply = try? await model.complete(request) else { continue }
            let answer = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !answer.isEmpty, !answer.uppercased().hasPrefix("NONE") { answers.append(answer) }
        }
        var final = answers.first ?? ""
        if answers.count > 1 {
            let joined = answers.joined(separator: "\n")
            let request = ModelRequest(messages: Prompts.reader(question: question, text: joined), schema: nil, maxTokens: 160,
                                       timeout: configuration.modelTimeout)
            if let reply = try? await model.complete(request) {
                final = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if final.isEmpty || final.uppercased().hasPrefix("NONE") {
            record(.read(question), action: "read for \"\(question.prefix(50))\"", result: "the text in this window doesn't answer that", hadEffect: false, scene: current)
        } else {
            memory.addNote("\(question.prefix(60)): \(final)")
            record(.read(question), action: "read for \"\(question.prefix(50))\"", result: "answer saved to notes: \(final.prefix(120))", hadEffect: true, scene: current)
        }
    }

    static func chunk(_ text: String, size: Int, maximumChunks: Int) -> [String] {
        guard size > 0, !text.isEmpty else { return [] }
        var chunks: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") {
            if current.count + line.count + 1 > size, !current.isEmpty {
                chunks.append(current)
                current = ""
                if chunks.count == maximumChunks { return chunks }
            }
            current += String(line.prefix(size)) + "\n"
        }
        if !current.isEmpty, chunks.count < maximumChunks { chunks.append(current) }
        return chunks
    }

    // MARK: Finishing

    /// Small models declare victory too early. A separate, strict question to the
    /// model with a fresh look at the screen catches many of those.
    func handleDone(_ claimed: String, scene current: Scene) async -> HarnessOutcome? {
        // A found answer sitting in the notes is what the person asked for.
        let answer = claimed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (memory.notes.last ?? "Done.") : claimed
        guard configuration.verifyCompletion else { return finish(.completed(answer: answer, verified: false)) }
        await settle(limit: 0.6)
        let fresh = await observe()
        if let outcome = stopCheck() { return outcome }
        let screen = SceneRenderer.render(fresh, tokens: min(budget.maximumScreenTokens, 1_000), estimator: estimator,
                                          keywords: SceneRenderer.keywords(from: goal))
        // The model that can see does the checking. A text-only planner has only its own reading
        // of a screen listing, and it talked itself out of right answers.
        var image: Data?
        var checker = model
        if let worker {
            var frame: ScreenFrame?
            if let view = await builder.captureApp(for: fresh), let first = view.regions.first {
                frame = view.frame.cropped(to: view.regions.reduce(first) { $0.union($1) }) ?? view.frame
            } else if let rect = worker.frameRect(for: fresh) {
                frame = await builder.captureForSettling(rect: rect)
            }
            image = frame?.encodedForModel(maxSide: worker.dialect.imageMaxSide, quality: 0.9)?.data
            if image != nil, configuration.orchestrated { checker = worker.model }
        } else if configuration.supportsVision, let frame = fresh.screenshot {
            image = frame.encodedForModel(maxSide: configuration.imageMaxSide)?.data
        }
        let jobs = configuration.orchestrated ? orchestration.log.suffix(6).joined(separator: "\n") + "\n\n" : ""
        let request = ModelRequest(messages: Prompts.verifier(goal: memory.renderGoal(), claim: answer,
                                                              history: jobs + memory.renderHistory(tokens: 300), screen: screen.text, image: image),
                                   schema: ToolSchema.verdictSchema, maxTokens: 160, timeout: configuration.modelTimeout)
        guard let reply = try? await checker.complete(request), let verdict = ToolSchema.decodeVerdict(reply.text) else {
            trace?.write(["event": "verify_unavailable"])
            return finish(.completed(answer: answer + " (I couldn't confirm this on screen.)", verified: false))
        }
        trace?.write(["event": "verify", "finished": verdict.finished, "missing": verdict.missing])
        if verdict.finished { return finish(.completed(answer: answer, verified: true)) }
        // "Nothing on screen proves it" isn't something wrong. Redoing the work would overwrite
        // what was done, so the person gets the answer and is told it wasn't confirmed.
        if worker != nil, verdict.cannotTell {
            return finish(.completed(answer: answer + " (I couldn't confirm this on screen.)", verified: false))
        }
        doneRejections += 1
        // Redoing finished work to satisfy a text-only check does more harm than saying it's unconfirmed.
        if doneRejections >= (configuration.orchestrated ? 2 : 3) {
            return finish(.completed(answer: answer + " (I couldn't fully confirm this on screen: \(verdict.missing))", verified: false))
        }
        let missing = verdict.missing.isEmpty ? "it doesn't look finished yet" : verdict.missing
        nudge = "A check says the goal isn't complete: \(missing). Do what's missing, then use done again. If it IS complete, say exactly why in done."
        record(.done(answer), action: "said done", result: "check failed: \(missing)", hadEffect: false, scene: fresh)
        forceImageOnce = true
        return nil
    }

    private func checkIfAlreadyFinished(_ current: Scene) async -> HarnessOutcome? {
        guard configuration.verifyCompletion else { return nil }
        let screen = SceneRenderer.render(current, tokens: min(budget.maximumScreenTokens, 1_000), estimator: estimator,
                                          keywords: SceneRenderer.keywords(from: goal))
        var image: Data?
        if configuration.supportsVision, let frame = current.screenshot { image = frame.encodedForModel(maxSide: configuration.imageMaxSide)?.data }
        let request = ModelRequest(messages: Prompts.verifier(goal: memory.renderGoal(), claim: "(not claimed yet) Has this already been achieved?",
                                                              history: memory.renderHistory(tokens: 300), screen: screen.text, image: image),
                                   schema: ToolSchema.verdictSchema, maxTokens: 90, timeout: configuration.modelTimeout)
        guard let reply = try? await model.complete(request), let verdict = ToolSchema.decodeVerdict(reply.text), verdict.finished else { return nil }
        trace?.write(["event": "found_already_finished"])
        let summary = memory.notes.last ?? "Done. Last step: \(memory.records.last(where: \.hadEffect)?.action ?? "finished")."
        return finish(.completed(answer: summary, verified: true))
    }

    private func askForHelp(_ reason: String, scene: Scene) -> HarnessOutcome {
        let question = UserQuestion(id: UUID(), question: "\(reason) What should I try? You can also take over on the live view and tell me when to continue.", choices: [])
        pendingQuestion = question
        supervisor = Supervisor()
        trace?.write(["event": "ask_for_help", "reason": reason])
        return .needsAnswer(question)
    }

    // MARK: Describing

    private func approvalFingerprint(_ call: ToolCall, in scene: Scene) -> String {
        switch call {
        case let .click(id, _, _):
            let label = lookup(id, in: scene)?.label ?? ""
            return "click|\(scene.bundleID)|\(label)"
        default:
            return "\(call.name)|\(scene.bundleID)|\(call.fingerprint)"
        }
    }

    private func approvalTargetChanged(_ call: ToolCall, from old: Scene, to new: Scene) -> String? {
        if old.bundleID != new.bundleID { return "a different app is now in front" }
        func same(_ id: Int) -> Bool {
            guard let before = lookup(id, in: old), let after = lookup(id, in: new) else { return false }
            return before.label == after.label && before.role == after.role
        }
        switch call {
        case let .pointAt(x, y, _, _):
            let point = SafetyPolicy.point(x: x, y: y, in: old)
            func under(_ scene: Scene) -> String? {
                scene.elements.filter { $0.isInteractive && $0.frame.contains(point) }
                    .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?.label
            }
            return under(old) == under(new) ? nil : "what's at that spot has changed"
        case let .click(id, _, _): return same(id) ? nil : "the approved button is gone or changed"
        case let .type(id?, _, _, _): return same(id) ? nil : "the approved field is gone or changed"
        case let .drag(from, to): return same(from) && same(to) ? nil : "the approved items are gone or changed"
        default: return nil
        }
    }

    /// For the model's own history: exact and terse.
    func describe(_ call: ToolCall, in scene: Scene) -> String {
        func name(_ id: Int) -> String {
            guard let element = lookup(id, in: scene) else { return "[\(id)]" }
            return "\(element.role) \"\(element.label.prefix(36))\""
        }
        switch call {
        case let .click(id, right, double): return "\(right ? "right-" : "")\(double ? "double-" : "")click \(name(id))"
        case let .clickAt(x, y): return "click_at \(Int(x)),\(Int(y))"
        case let .type(id, text, clear, submit):
            let target = id.map(name) ?? "focused field"
            return "type \"\(text.prefix(50))\" into \(target)\(clear ? " (replacing)" : "")\(submit ? " + Return" : "")"
        case let .key(chord): return "key \(chord)"
        case let .menu(path): return "menu \(path)"
        case let .scroll(direction, _, _): return "scroll \(direction)"
        case let .drag(from, to): return "drag \(name(from)) to \(name(to))"
        case let .openApp(app): return "open_app \(app)"
        case let .openURL(url): return "open_url \(url.prefix(70))"
        case let .wait(seconds): return "wait \(Int(seconds))s"
        case let .pointAt(x, y, right, count): return "\(right ? "right-" : "")\(count > 1 ? "\(count)x-" : "")click at \(Int(x)),\(Int(y))"
        case let .moveTo(x, y): return "move pointer to \(Int(x)),\(Int(y))"
        case let .dragAt(a, b, c, d): return "drag \(Int(a)),\(Int(b)) to \(Int(c)),\(Int(d))"
        case let .scrollBy(pixels, horizontal, _, _): return "scroll \(horizontal ? (pixels > 0 ? "right" : "left") : (pixels > 0 ? "up" : "down"))"
        case let .typeAtFocus(text): return "type \"\(text.prefix(50))\""
        default: return call.name
        }
    }

    /// For the person watching on the phone.
    func describeForPerson(_ call: ToolCall, in scene: Scene) -> String {
        func name(_ id: Int) -> String {
            guard let element = lookup(id, in: scene) else { return "an item" }
            return element.label.isEmpty ? "a \(element.role)" : "“\(element.label.prefix(40))”"
        }
        switch call {
        case let .click(id, _, _): return "Clicking \(name(id))"
        case .clickAt: return "Clicking on the screen"
        case let .type(id, text, _, _):
            if scene.elements.first(where: { $0.id == id })?.secure == true { return "Waiting for you to enter a password" }
            return "Typing “\(text.prefix(40))”"
        case let .key(chord): return "Pressing \(chord)"
        case let .menu(path): return "Using the menu: \(path.prefix(50))"
        case let .scroll(direction, _, _): return "Scrolling \(direction)"
        case .drag: return "Dragging an item"
        case let .openApp(app): return "Opening \(app)"
        case let .openURL(url): return "Going to \(url.prefix(60))"
        case let .find(text): return "Looking for “\(text.prefix(40))”"
        case .look, .zoom: return "Looking at the screen"
        case .read: return "Reading the screen"
        case .note: return "Keeping a note"
        case .wait: return "Waiting for the screen to load"
        case .askUser: return "Asking you a question"
        case .done: return "Checking the result"
        case .fail: return "Stopping"
        case let .pointAt(x, y, _, _):
            let point = SafetyPolicy.point(x: x, y: y, in: scene)
            if let hit = scene.elements.filter({ $0.frame.contains(point) && !$0.label.isEmpty }).min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                return "Clicking “\(hit.label.prefix(40))”"
            }
            return "Clicking on the screen"
        case .moveTo: return "Moving the pointer"
        case .dragAt: return "Dragging on the screen"
        case let .scrollBy(pixels, _, _, _): return "Scrolling \(pixels > 0 ? "up" : "down")"
        case let .typeAtFocus(text):
            if scene.focused?.secure == true { return "Waiting for you to enter a password" }
            return "Typing “\(text.trimmingCharacters(in: .newlines).prefix(40))”"
        }
    }
}

/// One JSON object per line, screenshots beside it. For debugging and evaluation.
public final class TraceWriter: @unchecked Sendable {
    private let directory: URL
    private let handle: FileHandle?
    private let lock = NSLock()

    public init?(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("trace.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        guard let opened = try? FileHandle(forWritingTo: file) else { return nil }
        handle = opened
    }

    public func write(_ object: [String: Any]) {
        lock.withLock {
            var payload = object
            payload["t"] = Date().timeIntervalSince1970
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
            handle?.write(data)
            handle?.write(Data([0x0A]))
        }
    }

    func step(step: Int, system: String?, user: String, reply: ModelReply, image: Data?) {
        if let image { try? image.write(to: directory.appendingPathComponent("step-\(step).jpg")) }
        var object: [String: Any] = [
            "event": "step", "step": step, "user": user, "reply": reply.text, "prompt_tokens": reply.promptTokens,
            "cached_tokens": reply.cachedTokens, "output_tokens": reply.outputTokens, "seconds": reply.seconds, "image": image != nil,
        ]
        if let system { object["system"] = system }
        write(object)
    }
}

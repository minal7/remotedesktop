import AppKit
import Foundation

/// How much of the planner's context each part of its prompt may use. A planner reads
/// text only, so a small model has plenty of room: the limits exist to keep it from
/// running out on a long task, and compaction is what enforces them.
public struct PlannerBudget: Sendable, Equatable {
    public var screenTokens: Int
    public var factTokens: Int
    public var logTokens: Int
    public static let outputTokens = 320

    public init(contextTokens: Int) {
        // The instructions, the goal and a margin for a miscounted estimate come off the top.
        let usable = max(1_200, contextTokens - Self.outputTokens - 800)
        // Room is only spent when a page is that long; a short screen still sends a short prompt.
        screenTokens = min(24_000, usable * 35 / 100)
        factTokens = usable * 15 / 100
        logTokens = usable * 35 / 100
    }
}

/// What survives between jobs. A worker starts each job with no memory of the last,
/// so anything it has to know travels through here.
struct OrchestrationState {
    var facts: [String] = []
    var log: [String] = []
    /// Older jobs, summarized once the log no longer fits.
    var digest = ""
    var activeJob: String?
    var jobsStarted = 0
    var jobsFailed = 0
    var badReplies = 0
    var compactions = 0
    var overflows = 0
    var finalTurnTaken = false
    /// What the completion check last said, so the planner repeating it isn't taken for an answer.
    var lastCheck: String?
    /// What the worker last said when it finished a job, in its own words.
    var lastWorkerAnswer: String?
    let estimator = TokenEstimator()

    mutating func note(_ line: String) { log.append(line) }

    static func squeezed(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Whole words only, however they're spaced: "Fixture Notes" is FixtureNotes, but "email" isn't Mail.
    static func names(goal: String, oneOf apps: [String]) -> Bool {
        let words = goal.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let wanted = Set(apps.map(squeezed).filter { $0.count >= 3 })
        for start in words.indices {
            for length in 1...4 where start + length <= words.count {
                if wanted.contains(words[start..<(start + length)].joined()) { return true }
            }
        }
        return false
    }

    /// What can be switched to right now.
    static func openApps() -> [String] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)
    }

    mutating func remember(_ fact: String) {
        let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !facts.contains(trimmed) else { return }
        facts.append(trimmed)
    }

    var logTokens: Int { estimator.estimate(digest) + log.reduce(0) { $0 + estimator.estimate($1) } }
    var factTokens: Int { facts.reduce(0) { $0 + estimator.estimate($1) } }

    func needsCompaction(_ budget: PlannerBudget) -> Bool { logTokens > budget.logTokens || factTokens > budget.factTokens }

    /// Numbers, paths and quoted names: what a later job copies exactly and a summary may round off.
    static func exactValues(in text: String) -> [String] {
        let pattern = #""[^"]+"|'[^']+'|[$~/]?[A-Za-z0-9_./-]*[0-9/][A-Za-z0-9_.,/-]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,")) }.filter { !$0.isEmpty }
    }

    /// Takes a summary of the older jobs. A fact whose exact values the summary lost stays
    /// as it was, so compaction can shorten what the planner knows but can't change it.
    mutating func applyCompaction(summary: String, keptFacts: [String], keepingNewest count: Int, budget: PlannerBudget) {
        let kept = keptFacts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let written = ([summary] + kept).joined(separator: "\n")
        let lost = facts.filter { fact in Self.exactValues(in: fact).contains { !written.contains($0) } }
        var merged: [String] = []
        for fact in kept + lost where !merged.contains(fact) { merged.append(fact) }
        facts = merged
        digest = summary
        log = Array(log.suffix(count))
        trimToFit(budget)
        compactions += 1
    }

    /// The summary can't be had, or didn't shrink enough: older detail goes, oldest first,
    /// and each job leaves one line. Never fails the task over bookkeeping.
    mutating func trimToFit(_ budget: PlannerBudget) {
        while logTokens > budget.logTokens, log.count > 1 {
            let oldest = log.removeFirst().replacingOccurrences(of: "\n", with: " ")
            digest += (digest.isEmpty ? "" : "\n") + oldest.prefix(120)
        }
        while logTokens > budget.logTokens, digest.count > 200 {
            digest = String(digest.suffix(digest.count * 3 / 4))
        }
        while factTokens > budget.factTokens, facts.count > 1 { facts.removeFirst() }
    }
}

public struct CompactionSummary: Sendable, Equatable {
    public var summary: String
    public var facts: [String]

    public static let schema = """
    {"type":"object","properties":{"summary":{"type":"string","maxLength":900},"facts":{"type":"array","items":{"type":"string","maxLength":160},"maxItems":16}},"required":["summary","facts"]}
    """

    public static func decode(_ raw: String) -> CompactionSummary? {
        guard let data = ToolSchema.firstJSONObject(in: raw).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let summary = (object["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else { return nil }
        return CompactionSummary(summary: summary, facts: (object["facts"] as? [Any])?.compactMap { $0 as? String } ?? [])
    }
}

public struct PlannerDecision: Sendable, Equatable {
    public enum Next: String, Sendable { case job, answer, ask, fail }
    public var next: Next
    public var text: String
    public var app: String?
    public var url: String?
    public var remember: [String]

    public static let schema = """
    {"type":"object","properties":{"thought":{"type":"string","maxLength":200},"remember":{"type":"array","items":{"type":"string","maxLength":160},"maxItems":3},"next":{"type":"string","enum":["job","answer","ask","fail"]},"app":{"type":"string","maxLength":60},"url":{"type":"string","maxLength":200},"text":{"type":"string","minLength":4,"maxLength":500}},"required":["thought","remember","next","app","url","text"]}
    """

    public static func decode(_ raw: String) -> PlannerDecision? {
        guard let data = ToolSchema.firstJSONObject(in: raw).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let next = (object["next"] as? String).flatMap(Next.init(rawValue:)),
              let text = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        func optional(_ key: String) -> String? {
            let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        return PlannerDecision(next: next, text: text, app: optional("app"), url: optional("url"),
                               remember: (object["remember"] as? [Any])?.compactMap { $0 as? String } ?? [])
    }
}

extension AgentHarness {
    /// The main model decides what happens next and the worker does the screen work.
    /// Every action still goes through `execute`, so approvals, Stop and takeover hold
    /// whichever model chose it, and neither model can talk its way past them.
    func orchestratedLoop() async -> HarnessOutcome {
        guard let worker else { return finish(.failed(reason: "No computer-use model is available.")) }
        while true {
            if let outcome = stopCheck() { return outcome }
            // Out of actions, the planner still gets the last word: the work may well be done.
            if isOutOfRoom {
                orchestration.activeJob = nil
                guard !orchestration.finalTurnTaken else {
                    return finish(.failed(reason: "Stopped after \(step) actions without finishing. So far: \(memory.summary())"))
                }
                orchestration.finalTurnTaken = true
            }

            // The worker tries the whole goal first, and the planner steps in when it reports back.
            if configuration.workerFirst, orchestration.jobsStarted == 0, !isOutOfRoom {
                orchestration.jobsStarted = 1
                orchestration.activeJob = goal
                worker.begin(job: goal, canHandBack: true, openApps: switchableApps)
                trace?.write(["event": "job_start", "job": goal])
            }
            if orchestration.activeJob == nil {
                if let outcome = await startNextJob(worker) { return outcome }
                if orchestration.activeJob == nil { continue }
            }

            switch await runWorker(worker) {
            case let .stop(outcome):
                return outcome // The job stays active, so a resume carries on with it.
            case let .finished(answer):
                orchestration.jobsFailed = 0
                orchestration.lastWorkerAnswer = answer
                let wasWholeGoal = orchestration.activeJob == goal
                closeJob(worker, result: "the agent says it finished: \(answer.prefix(600))")
                // It was given the whole goal and says it's done, so there's nothing to plan:
                // the planner would only reword its answer. Check the result, and plan if that fails.
                if wasWholeGoal {
                    if let outcome = await handleDone(answer, scene: await observe()) { return outcome }
                    orchestration.note("- It said it was finished, but a check disagreed: \(nudge ?? "it doesn't look finished").")
                    orchestration.lastCheck = nudge
                    // It has the screen and everything it did, so it goes on rather than the planner rewording this.
                    if configuration.workerFirst {
                        worker.resume(saying: nudge ?? "A check says this isn't finished yet. Do what's missing, then finish.")
                        orchestration.jobsStarted += 1
                        orchestration.activeJob = goal
                        trace?.write(["event": "job_start", "job": "carry on after the check: \(nudge ?? "")"])
                    }
                    nudge = nil
                }
            case let .gaveUp(reason):
                orchestration.jobsFailed += 1
                // A job that couldn't even take one step will fail the same way however it's reworded.
                if worker.stepsThisJob == 0 { orchestration.jobsFailed += 1 }
                closeJob(worker, result: "NOT finished: \(reason.prefix(300)) It got this far, and the screen is where it left off: \(memory.summary().prefix(500))")
                if orchestration.jobsFailed >= 3 {
                    orchestration.jobsFailed = 0
                    return askPerson("I've tried a few ways and can't get this done: \(reason) What should I try? You can also take over on the live view and tell me when to continue.")
                }
            }
        }
    }

    private func closeJob(_ worker: CUAWorker, result: String) {
        for note in memory.notes { orchestration.remember(note) }
        let job = orchestration.activeJob ?? ""
        orchestration.note("- Job: \(job.prefix(160))\n  Result: \(result)")
        orchestration.activeJob = nil
        trace?.write(["event": "job_end", "job": job, "result": result])
    }

    private func askPerson(_ question: String) -> HarnessOutcome {
        let asked = UserQuestion(id: UUID(), question: question, choices: [])
        pendingQuestion = asked
        trace?.write(["event": "ask", "question": question])
        return .needsAnswer(asked)
    }

    var switchableApps: [String] { configuration.visibleApps?() ?? OrchestrationState.openApps() }

    private var isOutOfRoom: Bool {
        if step >= configuration.maximumSteps || orchestration.jobsStarted >= configuration.maximumJobs { return true }
        if let startedAt = startedAtForWorker, Date().timeIntervalSince(startedAt) > configuration.timeLimit { return true }
        return false
    }

    private var plannerBudget: PlannerBudget {
        var budget = PlannerBudget(contextTokens: configuration.budget.contextTokens)
        if let tokens = configuration.plannerScreenTokens { budget.screenTokens = tokens }
        if let tokens = configuration.plannerLogTokens { budget.logTokens = tokens }
        // Each overflow the runtime reports halves the room the estimate thought it had.
        let shrink = 1 << min(orchestration.overflows, 3)
        budget.screenTokens /= shrink
        budget.logTokens /= shrink
        budget.factTokens /= shrink
        return budget
    }

    /// Folds older jobs into a summary once the log or the facts outgrow their share.
    private func compactIfNeeded() async {
        let budget = plannerBudget
        guard orchestration.needsCompaction(budget) else { return }
        let before = orchestration.logTokens + orchestration.factTokens
        defer { trace?.write(["event": "compaction", "before_tokens": before, "after_tokens": orchestration.logTokens + orchestration.factTokens,
                              "enabled": configuration.plannerCompaction]) }
        let newest = 2
        let older = Array(orchestration.log.dropLast(newest))
        // With only the newest jobs left there's nothing a summary could shorten.
        guard configuration.plannerCompaction, !older.isEmpty || orchestration.factTokens > budget.factTokens else {
            orchestration.trimToFit(budget)
            return
        }
        let request = ModelRequest(messages: Prompts.compaction(goal: memory.renderGoal(), digest: orchestration.digest, facts: orchestration.facts, older: older),
                                   schema: CompactionSummary.schema, maxTokens: 480, temperature: 0.1, timeout: configuration.modelTimeout)
        if let reply = try? await model.complete(request), let compacted = CompactionSummary.decode(reply.text) {
            orchestration.applyCompaction(summary: compacted.summary, keptFacts: compacted.facts, keepingNewest: newest, budget: budget)
        } else {
            orchestration.trimToFit(budget)
        }
    }

    /// Asks the planner what's next and sets it up. Returns an outcome if that ends the run.
    private func startNextJob(_ worker: CUAWorker) async -> HarnessOutcome? {
        let current = await observe()
        if let outcome = stopCheck() { return outcome }
        await compactIfNeeded()
        if let outcome = stopCheck() { return outcome }
        let budget = plannerBudget
        let finalTurn = orchestration.finalTurnTaken
        let screen = SceneRenderer.render(current, tokens: budget.screenTokens, estimator: orchestration.estimator,
                                          keywords: SceneRenderer.keywords(from: goal))
        // A planner that has eyes uses them; one that hasn't reads the screen's text.
        let image = configuration.supportsVision ? current.screenshot?.encodedForModel(maxSide: configuration.imageMaxSide)?.data : nil
        let messages = Prompts.orchestrator(goal: memory.renderGoal(), digest: orchestration.digest, facts: orchestration.facts,
                                            log: orchestration.log, screen: screen.text, finalTurn: finalTurn, image: image, openApps: switchableApps)
        let request = ModelRequest(messages: messages, schema: PlannerDecision.schema, maxTokens: PlannerBudget.outputTokens,
                                   temperature: 0.1, timeout: configuration.modelTimeout)
        let decision: PlannerDecision
        do {
            let reply = try await model.complete(request)
            modelFailures = 0
            trace?.write(["event": "planner", "reply": reply.text, "prompt_tokens": reply.promptTokens, "seconds": reply.seconds, "context_tokens": configuration.budget.contextTokens])
            orchestration.estimator.observe(characters: messages.reduce(0) { $0 + $1.text.utf8.count }, tokens: reply.promptTokens)
            guard let decoded = PlannerDecision.decode(reply.text) else {
                orchestration.badReplies += 1
                guard orchestration.badReplies >= 2 else { return nil }
                orchestration.badReplies = 0
                // The goal itself is a job the worker can start on.
                if orchestration.jobsStarted == 0 {
                    orchestration.jobsStarted = 1
                    orchestration.activeJob = goal
                    worker.begin(job: goal, canHandBack: true, openApps: switchableApps)
                    trace?.write(["event": "job_start", "job": goal])
                    return nil
                }
                return askPerson("I'm having trouble working out what to do next. What should I try? You can also take over on the live view and tell me when to continue.")
            }
            decision = decoded
        } catch is CancellationError {
            return stopCheck()
        } catch let error as ModelError {
            if let outcome = stopCheck() { return outcome }
            if case .startupFailed(let detail) = error { return finish(.failed(reason: "The local model could not start: \(detail)")) }
            // The prompt won't get smaller on its own, so make it smaller before asking again.
            if error == .contextOverflow, orchestration.overflows < 3 {
                orchestration.overflows += 1
                trace?.write(["event": "planner_overflow", "count": orchestration.overflows])
                return nil
            }
            modelFailures += 1
            return modelFailures >= 3 ? finish(.failed(reason: "The local model stopped responding: \(error.description)")) : nil
        } catch {
            return stopCheck() ?? finish(.failed(reason: "The local model failed: \(error)"))
        }
        orchestration.badReplies = 0
        for fact in decision.remember { orchestration.remember(fact) }

        switch decision.next {
        case .fail:
            return finish(.failed(reason: decision.text))
        case .ask:
            return askPerson(decision.text)
        case .answer:
            // The person gets the planner's words only after a separate check of the screen.
            // A small planner sometimes answers with a scrap, and the worker's report is better.
            let repeatsCheck = orchestration.lastCheck?.contains(decision.text) == true
            let usable = !decision.text.lowercased().hasPrefix("next") && !repeatsCheck
            let outcome = await handleDone(usable ? decision.text : (orchestration.lastWorkerAnswer ?? decision.text), scene: current)
            if outcome == nil {
                orchestration.note("- You said it was finished, but a check disagreed: \(nudge ?? "it doesn't look finished").")
                nudge = nil
            }
            return outcome
        case .job:
            guard !finalTurn else {
                return finish(.failed(reason: "Stopped after \(step) actions and \(orchestration.jobsStarted) jobs without finishing. So far: \(memory.summary())"))
            }
            // The planner's words are advice to a worker that keeps its goal and all it has seen.
            // A small planner rewords goals badly and invents addresses, so neither is used as given.
            if configuration.workerFirst, orchestration.jobsStarted > 0 {
                var advice = decision
                advice.url = nil
                if let outcome = await prepare(advice, on: current) { return outcome }
                orchestration.jobsStarted += 1
                orchestration.activeJob = goal
                var note = "You stopped before this was finished. It's still the same task, and what you've already done stays done, so don't start over. A suggestion, which may be wrong: \(decision.text)"
                if !orchestration.facts.isEmpty { note += "\nKnown: " + orchestration.facts.joined(separator: "; ") }
                worker.resume(saying: note)
                onProgress?("Trying another way")
                trace?.write(["event": "job_start", "job": "carry on: \(decision.text)"])
                return nil
            }
            if let outcome = await prepare(decision, on: current) { return outcome }
            orchestration.jobsStarted += 1
            orchestration.activeJob = decision.text
            var job = decision.text
            if !orchestration.facts.isEmpty { job += "\n\nKnown: " + orchestration.facts.joined(separator: "; ") }
            worker.begin(job: job, canHandBack: true, openApps: switchableApps)
            onProgress?("Next: \(decision.text.prefix(100))")
            trace?.write(["event": "job_start", "job": job])
            return nil
        }
    }

    static func isSamePage(_ wanted: String, as current: String?) -> Bool {
        guard let current else { return false }
        func bare(_ text: String) -> String {
            var value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["https://", "http://", "www."] where value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
            while value.hasSuffix("/") { value.removeLast() }
            return value
        }
        return bare(current).hasPrefix(bare(wanted))
    }

    /// Opens what the job needs, by the same checked route as any other action.
    private func prepare(_ decision: PlannerDecision, on current: Scene) async -> HarnessOutcome? {
        var scene = current
        var decision = decision
        // A small planner sometimes fills this with a sentence.
        if let url = decision.url, Preflight.firstURL(in: url) == nil { decision.url = nil }
        // Given both, the job's own wording says which comes first. Opening both would only
        // leave the second in front, and "Mail" plus a webmail address means the address.
        if let url = decision.url, let app = decision.app {
            let urlAt = decision.text.range(of: url).map { decision.text.distance(from: decision.text.startIndex, to: $0.lowerBound) } ?? Int.max
            if let named = Preflight.firstNamedApp(in: decision.text, oneOf: [app]), named.position < urlAt { decision.url = nil } else { decision.app = nil }
        }
        // A small planner sometimes names the page it's reading; that isn't worth an action.
        if let app = decision.app, app.lowercased() != scene.appName.lowercased(), AppCatalog.shared.resolve(app) != nil {
            step += 1
            onProgress?(describeForPerson(.openApp(app), in: scene))
            if let outcome = await execute(AgentDecision(thought: "", planStep: nil, call: .openApp(app)), on: scene, approvedAlready: false) { return outcome }
            scene = await observe()
        }
        // Reopening the page it's already on would throw away what the last job did there.
        if let url = decision.url, !Self.isSamePage(url, as: scene.url) {
            step += 1
            onProgress?(describeForPerson(.openURL(url), in: scene))
            if let outcome = await execute(AgentDecision(thought: "", planStep: nil, call: .openURL(url)), on: scene, approvedAlready: false) { return outcome }
        }
        return nil
    }
}

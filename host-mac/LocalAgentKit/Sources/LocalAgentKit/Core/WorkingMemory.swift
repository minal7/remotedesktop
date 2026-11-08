import Foundation

/// Everything the agent remembers about a task, in fixed-size pieces. Old detail
/// is folded away deterministically (no model calls) as the plan moves on.
public final class WorkingMemory: @unchecked Sendable {
    public struct PlanItem: Sendable, Equatable {
        public var text: String
        public var done = false
    }

    public struct Record: Sendable, Equatable {
        public var step: Int
        public var action: String
        public var result: String
        public var hadEffect: Bool
        public var fingerprint: String
        public var sceneFingerprint: String
        public var toolName: String = ""
        public var targetID: Int?
    }

    public let goal: String
    public private(set) var plan: [PlanItem] = []
    public private(set) var notes: [String] = []
    public private(set) var records: [Record] = []
    public private(set) var userReplies: [String] = []
    /// One line per finished plan step or folded stretch of steps.
    public private(set) var rollup: [String] = []
    public private(set) var stepsSincePlanProgress = 0

    private let estimator: TokenEstimator

    public init(goal: String, estimator: TokenEstimator) {
        self.goal = goal
        self.estimator = estimator
    }

    public func setPlan(_ steps: [String]) {
        let finished = plan.filter(\.done)
        plan = finished + steps.map { PlanItem(text: $0) }
        stepsSincePlanProgress = 0
    }

    public var currentPlanIndex: Int? { plan.firstIndex { !$0.done } }
    public var currentStepText: String? { currentPlanIndex.map { plan[$0].text } }

    /// The model says it's on step N, so everything before N is finished. Forward
    /// only: a confused model can't erase progress, and this folds finished detail
    /// out of the prompt so it can't be tempted to redo it.
    public func advance(toStep number: Int) {
        let index = number - 1
        guard index > 0, index < plan.count else { return }
        var advanced = false
        for earlier in 0..<index where !plan[earlier].done {
            plan[earlier].done = true
            rollup.append("Finished: \(plan[earlier].text)")
            advanced = true
        }
        guard advanced else { return }
        // Keep the last action: it tells the model what just happened.
        if records.count > 1 { records.removeFirst(records.count - 1) }
        stepsSincePlanProgress = 0
    }

    public func addNote(_ text: String) {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        guard !trimmed.isEmpty, !notes.contains(trimmed) else { return }
        notes.append(trimmed)
    }

    public func addUserReply(_ text: String) { userReplies.append(String(text.prefix(600))) }

    public func record(_ record: Record) {
        records.append(record)
        stepsSincePlanProgress += 1
        // Hard cap, so one bad stretch can't grow without bound. Rendering trims further.
        if records.count > 24 {
            let dropped = records.removeFirst()
            rollup.append("Did: \(dropped.action)")
        }
        if rollup.count > 20 { rollup.removeFirst(rollup.count - 20) }
    }

    // MARK: Rendering (every section respects its token share)

    public func renderGoal() -> String {
        var text = "GOAL (from the user): \(goal)"
        for reply in userReplies { text += "\nUser added: \(reply)" }
        return text
    }

    public func renderPlan(tokens: Int) -> String {
        guard !plan.isEmpty else { return "" }
        var lines: [String] = []
        var used = 0
        for (index, item) in plan.enumerated() {
            let marker = item.done ? "x" : (index == currentPlanIndex ? ">" : " ")
            let line = "\(index + 1). [\(marker)] \(item.text)"
            let cost = estimator.estimate(line)
            if used + cost > tokens { break }
            used += cost
            lines.append(line)
        }
        return "PLAN:\n" + lines.joined(separator: "\n")
    }

    public func renderNotes(tokens: Int) -> String {
        guard !notes.isEmpty else { return "" }
        var kept: [String] = []
        var used = 0
        // Newest first when space runs out, printed oldest first.
        for note in notes.reversed() {
            let cost = estimator.estimate(note) + 1
            if used + cost > tokens { break }
            used += cost
            kept.insert("- \(note)", at: 0)
        }
        return "NOTES:\n" + kept.joined(separator: "\n")
    }

    /// Last actions in full, then older ones condensed, then a count.
    public func renderHistory(tokens: Int) -> String {
        guard !records.isEmpty || !rollup.isEmpty else { return "" }
        var remaining = tokens
        var recent: [String] = []
        var fullCount = 0
        for record in records.reversed() {
            let line = fullCount < 4 ? "\(record.action) -> \(record.result)" : record.action
            let cost = estimator.estimate(line) + 1
            if cost > remaining { break }
            remaining -= cost
            recent.insert("- \(line)", at: 0)
            fullCount += 1
        }
        let skipped = records.count - recent.count
        var earlier: [String] = []
        for line in rollup.reversed() {
            let cost = estimator.estimate(line) + 1
            if cost > remaining { break }
            remaining -= cost
            earlier.insert("- \(line)", at: 0)
        }
        var text = "DONE SO FAR:\n"
        if !earlier.isEmpty { text += earlier.joined(separator: "\n") + "\n" }
        if skipped > 0 || earlier.count < rollup.count {
            text += "- (\(skipped + rollup.count - earlier.count) earlier items omitted)\n"
        }
        text += recent.joined(separator: "\n")
        return text
    }

    /// Short recap for the phone and for replans.
    public func summary(maximumLines: Int = 6) -> String {
        (rollup + records.map(\.action)).suffix(maximumLines).joined(separator: "; ")
    }
}

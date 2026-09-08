import Foundation

enum ComputerUseBrowserResearchEvidenceError: Error, Equatable { case inputChanged, limitReached, unavailable }

/// Task-local historical observations. No entry is an actionable page, a
/// fresh availability claim or a completed answer. The owner records only
/// after native reading validation and clears its archive on retirement.
struct ComputerUseBrowserResearchEvidence: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let maximumReadings = 64
    static let maximumRecalledReadings = 8
    private struct Entry: Sendable {
        let goal: ComputerUseBrowserGoalInput
        let reading: ComputerUseBrowserResultCandidates
    }
    private let rootDigest: String
    private let readingLimit: Int
    private var sessionIdentity: String?
    private var entries: [Entry] = []
    private var firstAnswerReading = 0
    var count: Int { entries.count }
    init(goal: ComputerUseBrowserGoalInput, readingLimit: Int = Self.maximumReadings) {
        rootDigest = goal.rootDigest; self.readingLimit = min(Self.maximumReadings, max(1, readingLimit))
    }
    func requireCapacity() throws {
        guard entries.count < readingLimit else { throw ComputerUseBrowserResearchEvidenceError.limitReached }
    }
    /// Manual control may change accounts or selections without changing the
    /// user's words. Preserve context, but require new answer evidence.
    mutating func invalidateAnswerReadings() { firstAnswerReading = entries.count }

    mutating func record(_ reading: ComputerUseBrowserResultCandidates, goal: ComputerUseBrowserGoalInput) throws {
        try validate(goal: goal)
        try reading.validateHistoricalGoal(goal)
        guard sessionIdentity == nil || sessionIdentity == reading.historicalSessionIdentity else {
            throw ComputerUseBrowserResearchEvidenceError.inputChanged
        }
        // Revalidation of the same immutable observation is not another read.
        // A new native snapshot remains a separate historical observation.
        if let previous = entries.first(where: { $0.reading.requirementAssessmentIdentity == reading.requirementAssessmentIdentity }) {
            guard previous.goal == goal else { throw ComputerUseBrowserResearchEvidenceError.inputChanged }
            return
        }
        try requireCapacity()
        entries.append(.init(goal: goal, reading: reading))
        sessionIdentity = reading.historicalSessionIdentity
    }

    func validate(goal: ComputerUseBrowserGoalInput, current: ComputerUseBrowserResultCandidates? = nil) throws {
        guard goal.rootDigest == rootDigest,
              entries.allSatisfy({ entry in
                  entry.goal.rootDigest == goal.rootDigest && entry.goal.clarifications.count <= goal.clarifications.count
                    && Array(goal.clarifications.prefix(entry.goal.clarifications.count)) == entry.goal.clarifications
              }) else { throw ComputerUseBrowserResearchEvidenceError.inputChanged }
        if let current { try current.validateHistoricalGoal(goal) }
        if let current, let sessionIdentity, current.historicalSessionIdentity != sessionIdentity {
            throw ComputerUseBrowserResearchEvidenceError.inputChanged
        }
    }
    var digest: String {
        ComputerUseTaskContract.digest(["browser-research-evidence-v2", rootDigest, String(readingLimit), String(entries.count), String(firstAnswerReading)]
            + entries.flatMap { [$0.goal.digest, $0.reading.requirementAssessmentIdentity] })
    }
    func selectableIndices(current: ComputerUseBrowserResultCandidates) -> [Int] {
        entries.indices.filter { entries[$0].reading.requirementAssessmentIdentity != current.requirementAssessmentIdentity }
    }
    private func newerReading(after index: Int) -> Int? {
        guard let latest = entries.lastIndex(where: { $0.reading.historicalSourceIdentity == entries[index].reading.historicalSourceIdentity }),
              latest > index else { return nil }
        return latest
    }
    func answerReadings(_ indices: [Int], goal: ComputerUseBrowserGoalInput,
                        current: ComputerUseBrowserResultCandidates) throws -> [(index: Int, reading: ComputerUseBrowserResultCandidates)] {
        try validate(goal: goal, current: current)
        let offered = selectableIndices(current: current)
        guard indices.count <= Self.maximumRecalledReadings, Set(indices).count == indices.count,
              indices.allSatisfy({ offered.contains($0) }) else { throw ComputerUseBrowserResearchEvidenceError.inputChanged }
        return indices.compactMap { index in
            let entry = entries[index]
            guard index >= firstAnswerReading, entry.goal == goal,
                  entry.reading.hasSameAnswerInterpretationAndPolicy(as: current),
                  entry.reading.historicalSourceIdentity != current.historicalSourceIdentity,
                  newerReading(after: index) == nil else { return nil }
            return (index, entry.reading)
        }
    }
    func catalog(goal: ComputerUseBrowserGoalInput, current: ComputerUseBrowserResultCandidates) throws -> [[String: Any]] {
        try validate(goal: goal, current: current)
        return entries.enumerated().map { index, entry in
            ["reading":index, "observed_at_milliseconds":entry.reading.observedAtMilliseconds, "current_goal_revision":entry.goal == goal,
             "answer_requires_fresh_reading":index < firstAnswerReading, "newer_reading":newerReading(after: index).map { $0 as Any } ?? NSNull(),
             "current_reading":entry.reading.requirementAssessmentIdentity == current.requirementAssessmentIdentity,
             "candidate_count":entry.reading.candidates.count, "reviewed":entry.reading.review != nil]
        }
    }
    /// Capability selection happens before a fresh candidate reading exists.
    /// Permit historical recall only inside the archive's original session;
    /// a new page is still the sole authority for current controls/actions.
    func actionCatalog(goal: ComputerUseBrowserGoalInput, page: ComputerUseBrowserPageEvidence) throws -> [[String: Any]] {
        try validate(goal: goal)
        guard page.document.taskID == goal.taskID,
              sessionIdentity == nil || sessionIdentity == page.document.contextID else {
            throw ComputerUseBrowserResearchEvidenceError.inputChanged
        }
        return entries.enumerated().map { index, entry in
            ["reading":index, "observed_at_milliseconds":entry.reading.observedAtMilliseconds, "current_goal_revision":entry.goal == goal,
             "answer_requires_fresh_reading":index < firstAnswerReading, "newer_reading":newerReading(after: index).map { $0 as Any } ?? NSNull(),
             "candidate_count":entry.reading.candidates.count, "reviewed":entry.reading.review != nil]
        }
    }
    func recall(_ index: Int, goal: ComputerUseBrowserGoalInput) throws -> [String: Any] {
        try validate(goal: goal)
        guard entries.indices.contains(index) else { throw ComputerUseBrowserResearchEvidenceError.unavailable }
        let entry = entries[index]
        return ["reading":index, "historical":true, "observed_at_milliseconds":entry.reading.observedAtMilliseconds, "current_goal_revision":entry.goal == goal,
                "answer_requires_fresh_reading":index < firstAnswerReading, "newer_reading":newerReading(after: index).map { $0 as Any } ?? NSNull(),
                "accepted_answer_count_at_reading":entry.goal.clarifications.count,
                "observation":Self.namespaceReferences(try entry.reading.historicalPlannerContext(), prefix: "r\(index)/")]
    }
    /// Historical references cannot alias the current page's t1/l1/g1 IDs.
    /// Rewrite only schema reference fields, never observed labels or prose.
    private static func namespaceReferences(_ value: Any, prefix: String) -> Any {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, item in
                let (key, child) = item
                if ["id", "group", "parent", "container"].contains(key), let id = child as? String { result[key] = prefix + id }
                else if ["texts", "text_ids", "links", "unclassified_texts", "qualifiers"].contains(key), let ids = child as? [String] {
                    result[key] = ids.map { prefix + $0 }
                } else { result[key] = namespaceReferences(child, prefix: prefix) }
            }
        }
        if let array = value as? [Any] { return array.map { namespaceReferences($0, prefix: prefix) } }
        return value
    }
    var description: String { "BrowserResearchEvidence(readings: \(count))" }
    var debugDescription: String { description }
}

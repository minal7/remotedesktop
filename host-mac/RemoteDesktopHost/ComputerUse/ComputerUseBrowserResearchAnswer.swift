import Foundation

/// A delivered informational answer grounded in complete observed passages.
/// Semantic matching/distinctness remains the model's proposed interpretation;
/// native admission checks provenance, coverage and supported scalar bounds.
/// This is not a booking receipt or independently verified inventory.
struct ComputerUseBrowserResearchAnswer: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    struct Selection: Equatable, Sendable {
        fileprivate let eligibilityDigest: String
        fileprivate let indices: [Int]
        let recalledReadings: [Int]
    }
    struct Page: Equatable, Sendable {
        fileprivate let readingIdentity: String
        fileprivate let source: String
        fileprivate let observedAtMilliseconds: Int64
        fileprivate let requirements: [String]
        fileprivate let passages: [Int: String]
        fileprivate let surroundingText: String
        fileprivate let resultCounts: [ComputerUseBrowserScalarRequirements.Condition]
        let candidateIndices: [Int]

        init?(goal: ComputerUseBrowserGoalInput, reading: ComputerUseBrowserResultCandidates,
              interpretation: ComputerUseBrowserGoalProposal, source: String) {
            guard interpretation.input == goal, interpretation.disposition == .research,
                  reading.documentAnswerSourceStatus == .permitted,
                  !reading.sourceTruncated, !reading.omittedStructure, !reading.omittedEmbeddedContent, !reading.omittedControls,
                  !reading.projectionOmittedRecords,
                  let review = reading.review, review.hasRequirementMapping,
                  let assessment = reading.requirementAssessment,
                  ComputerUseBrowserSourceRequirements(proposal: interpretation).unresolved.isEmpty else { return nil }
            self.readingIdentity = reading.requirementAssessmentIdentity; self.source = source
            observedAtMilliseconds = reading.observedAtMilliseconds
            requirements = interpretation.requirements.compactMap { interpretation.source(of: $0) }
            guard requirements.count == interpretation.requirements.count else { return nil }
            surroundingText = reading.surroundingTexts.map(\.text).joined(separator: "\n")
            let scalars = ComputerUseBrowserScalarRequirements(proposal: interpretation)
            let counts = scalars.entries.compactMap { entry -> ComputerUseBrowserScalarRequirements.Condition? in
                if case .bound(let condition) = entry.resolution, case .quantity(_, _, let unit) = condition.predicate,
                   unit.scope == .resultSet { return condition }
                return nil
            }
            resultCounts = counts
            var passages: [Int: String] = [:]
            for (index, candidate) in reading.candidates.enumerated() {
                guard review.candidates[index].association == .singleOffer,
                      candidate.unprojectedTextIDs.isEmpty, candidate.unprojectedLinkIDs.isEmpty else { continue }
                let evaluations = assessment.candidates[index].requirements
                guard evaluations.count == interpretation.requirements.count else { continue }
                let covered = interpretation.requirements.enumerated().allSatisfy { offset, requirement in
                    let status = evaluations[offset].status
                    // Execution restrictions remain in the complete model
                    // request and answer ledger. They are not page facts.
                    if requirement.role == .prohibition {
                        guard let source = interpretation.source(of: requirement) else { return false }
                        let clause = source.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!"))).lowercased()
                        return ["do not buy", "do not book", "do not purchase", "do not reserve",
                            "don't buy", "don't book", "don't purchase", "don't reserve"].contains(clause)
                    }
                    guard [.outcome, .condition].contains(requirement.role) else { return false }
                    if [.source, .navigationSource, .answerSource].contains(requirement.field) { return true }
                    if status == .needsResultSet { return counts.contains { $0.requirementID == requirement.id } }
                    if status == .quotedCapacitySufficient {
                        // A stock number alone cannot reconcile a selected
                        // amount, purchase cap or package-size rule. Until
                        // those are jointly compiled, retain the open task.
                        return candidate.fields.indices.filter { candidate.fields[$0].kind == .quantity }
                            .allSatisfy { review.candidates[index].fields[$0].quantity == .availableQuantity }
                    }
                    return [.reviewRequirementSupported, .quotedValueMatches, .clarificationApplied].contains(status)
                }
                guard covered else { continue }
                passages[index] = candidate.texts.map(\.text).joined(separator: "\n")
            }
            self.passages = passages
            candidateIndices = passages.keys.sorted()
        }
    }

    struct Eligibility: Equatable, Sendable {
        private struct Option: Equatable, Sendable {
            let index: Int
            let reading: Int?
            let candidate: Int
            let page: Page
            let text: String
        }
        private let goal: ComputerUseBrowserGoalInput
        private let currentIdentity: String
        private let archiveDigest: String?
        private let recalledReadings: [Int]
        private let requirements: [String]
        private let options: [Option]
        let candidateIndices: [Int]
        let selectionCounts: [Int]
        private var digest: String {
            ComputerUseTaskContract.digest(["browser-answer-eligibility-v2", goal.digest, currentIdentity, archiveDigest ?? ""]
                + recalledReadings.map(String.init) + requirements
                + options.flatMap { [String($0.index), $0.reading.map(String.init) ?? "current", String($0.candidate),
                    $0.page.readingIdentity, $0.page.source, String($0.page.observedAtMilliseconds), $0.page.surroundingText, $0.text] }
                + selectionCounts.map(String.init))
        }
        var plannerOptions: [[String: Any]] {
            options.map { ["index":$0.index, "reading":$0.reading.map { $0 as Any } ?? NSNull(),
                "candidate":$0.candidate, "observed_at_milliseconds":$0.page.observedAtMilliseconds] }
        }
        init?(goal: ComputerUseBrowserGoalInput, current: ComputerUseBrowserResultCandidates,
              evidence: ComputerUseBrowserResearchEvidence?, recalledReadings: [Int]) throws {
            guard evidence != nil || recalledReadings.isEmpty else { throw ComputerUseBrowserLinkPlanError.inputChanged }
            let historical = try evidence?.answerReadings(recalledReadings, goal: goal, current: current) ?? []
            guard let page = current.answerPage(goal: goal) else { return nil }
            self.goal = goal; currentIdentity = current.requirementAssessmentIdentity
            archiveDigest = evidence?.digest; self.recalledReadings = recalledReadings; requirements = page.requirements
            var options: [Option] = page.candidateIndices.compactMap { index in
                page.passages[index].map { .init(index: index, reading: nil, candidate: index, page: page, text: $0) }
            }
            var nextIndex = current.candidates.count
            for (reading, value) in historical {
                guard let retained = value.answerPage(goal: goal), retained.requirements == requirements else { continue }
                for candidate in retained.candidateIndices {
                    guard let text = retained.passages[candidate] else { continue }
                    options.append(.init(index: nextIndex, reading: reading, candidate: candidate, page: retained, text: text))
                    nextIndex += 1
                }
            }
            self.options = options; candidateIndices = options.map(\.index)
            selectionCounts = (1...max(1, min(8, options.count))).filter { count in
                count <= options.count && page.resultCounts.allSatisfy { condition in
                    guard case .quantity(_, _, let unit) = condition.predicate else { return false }
                    return condition.compareLiteral(.quantity(Int64(count), unit)) == .satisfied
                }
            }
        }
        func selection(_ indices: [Int]) throws -> Selection {
            guard selectionCounts.contains(indices.count), Set(indices).count == indices.count,
                  indices.allSatisfy({ candidateIndices.contains($0) }) else { throw ComputerUseBrowserLinkPlanError.invalidProposal }
            let signatures = indices.map { index in
                (options.first { $0.index == index }?.text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            }
            // Exact duplicate passages cannot count twice. Other semantic
            // duplicates remain the selector's responsibility across sources.
            guard Set(signatures).count == signatures.count else { throw ComputerUseBrowserLinkPlanError.invalidProposal }
            return .init(eligibilityDigest: digest, indices: indices, recalledReadings: recalledReadings)
        }
        func answer(for selection: Selection) throws -> ComputerUseBrowserResearchAnswer {
            guard selection == (try self.selection(selection.indices)) else { throw ComputerUseBrowserLinkPlanError.inputChanged }
            let passages = try selection.indices.map { index -> Passage in
                guard let option = options.first(where: { $0.index == index }), !option.text.isEmpty else { throw ComputerUseBrowserLinkPlanError.inputChanged }
                return .init(source: option.page.source, observedAtMilliseconds: option.page.observedAtMilliseconds,
                    text: option.text, surroundingText: option.page.surroundingText, readingIdentity: option.page.readingIdentity)
            }
            let message = try ComputerUseBrowserResearchAnswer.render(passages: passages, requirements: requirements)
            return .init(rootTaskID: goal.taskID, goalRevision: goal.digest, readingIdentity: currentIdentity, selection: selection, message: message)
        }
    }

    let rootTaskID: String
    let goalRevision: String
    let readingIdentity: String
    fileprivate let selection: Selection
    var recalledReadings: [Int] { selection.recalledReadings }
    let message: String
    private init(rootTaskID: String, goalRevision: String, readingIdentity: String, selection: Selection, message: String) {
        self.rootTaskID = rootTaskID; self.goalRevision = goalRevision; self.readingIdentity = readingIdentity
        self.selection = selection; self.message = message
    }
    func validate(for eligibility: Eligibility) throws {
        guard self == (try eligibility.answer(for: selection)) else { throw ComputerUseBrowserLinkPlanError.inputChanged }
    }
    private struct Passage {
        let source: String
        let observedAtMilliseconds: Int64
        let text: String
        let surroundingText: String
        let readingIdentity: String
    }
    /// Display formatting alone cannot create a typed, admitted answer.
    static func render(source: String, passages: [String], surroundingText: String, requirements: [String]) throws -> String {
        try render(passages: passages.map { .init(source: source, observedAtMilliseconds: 0, text: $0,
            surroundingText: surroundingText, readingIdentity: "display") }, requirements: requirements)
    }
    private static func render(passages: [Passage], requirements: [String]) throws -> String {
        func quote(_ text: String) -> String { text.components(separatedBy: "\n").map { "│ " + $0 }.joined(separator: "\n") }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        var message = "Source-reported options for your request:\n"
        for (offset, passage) in passages.enumerated() {
            let observed = formatter.string(from: Date(timeIntervalSince1970: Double(passage.observedAtMilliseconds) / 1_000))
            message += "\nOption \(offset + 1) — page details (quoted):\nSource page: " + passage.source
                + "\nObserved: " + observed + "\n" + quote(passage.text) + "\n"
        }
        var included: Set<String> = []
        for passage in passages where included.insert(passage.readingIdentity).inserted && !passage.surroundingText.isEmpty {
            message += "\nOther observed page text from " + passage.source + " (quoted):\n" + quote(passage.surroundingText) + "\n"
        }
        message += "\nRequest and constraints used:\n" + requirements.map(quote).joined(separator: "\n")
        message += "\n\nThese are source-reported details, not a booking confirmation. Availability can change after each observation."
        // The durable terminal ledger retains at most 4,000 Characters
        // (the wire allows 8,000). Reject before either can truncate it.
        guard message.count <= 4_000, message.utf8.count <= ComputerUseResearchProgress.maximumTextBytes,
              !message.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else {
            throw ComputerUseBrowserLinkPlanError.contextLimit
        }
        return message
    }
    var description: String { "BrowserResearchAnswer(options: \(selection.indices.count))" }
    var debugDescription: String { description }
}

import Foundation

/// A delivered informational answer grounded in complete observed passages.
/// Semantic matching/distinctness remains the model's proposed interpretation;
/// native admission checks provenance, coverage and supported scalar bounds.
/// This is not a booking receipt or independently verified inventory.
struct ComputerUseBrowserResearchAnswer: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    struct Selection: Equatable, Sendable {
        fileprivate let eligibilityDigest: String
        fileprivate let indices: [Int]
    }
    struct Eligibility: Equatable, Sendable {
        private let goal: ComputerUseBrowserGoalInput
        private let readingIdentity: String
        private let source: String
        private let requirements: [String]
        private let passages: [Int: String]
        private let surroundingText: String
        let candidateIndices: [Int]
        let selectionCounts: [Int]
        private var digest: String {
            ComputerUseTaskContract.digest(["browser-answer-eligibility-v1", goal.digest, readingIdentity, source,
                surroundingText] + requirements + candidateIndices.flatMap { [String($0), passages[$0] ?? ""] }
                + selectionCounts.map(String.init))
        }

        init?(goal: ComputerUseBrowserGoalInput, reading: ComputerUseBrowserResultCandidates,
              interpretation: ComputerUseBrowserGoalProposal, source: String) {
            guard interpretation.input == goal, interpretation.disposition == .research,
                  reading.documentAnswerSourceStatus == .permitted,
                  !reading.sourceTruncated, !reading.omittedStructure, !reading.omittedEmbeddedContent, !reading.omittedControls,
                  !reading.projectionOmittedRecords,
                  let review = reading.review, review.hasRequirementMapping,
                  let assessment = reading.requirementAssessment,
                  ComputerUseBrowserSourceRequirements(proposal: interpretation).unresolved.isEmpty else { return nil }
            self.goal = goal; self.readingIdentity = reading.requirementAssessmentIdentity; self.source = source
            requirements = interpretation.requirements.compactMap { interpretation.source(of: $0) }
            guard requirements.count == interpretation.requirements.count else { return nil }
            surroundingText = reading.surroundingTexts.map(\.text).joined(separator: "\n")
            let scalars = ComputerUseBrowserScalarRequirements(proposal: interpretation)
            var resultCounts: [(ComputerUseBrowserScalarRequirements.Condition, ComputerUseBrowserScalarRequirements.QuantityUnit)] = []
            for entry in scalars.entries {
                if case .bound(let condition) = entry.resolution, case .quantity(_, _, let unit) = condition.predicate,
                   unit.scope == .resultSet { resultCounts.append((condition, unit)) }
            }
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
                    if status == .needsResultSet { return resultCounts.contains { $0.0.requirementID == requirement.id } }
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
            selectionCounts = (1...max(1, passages.count)).filter { count in
                count <= passages.count && resultCounts.allSatisfy { $0.0.compareLiteral(.quantity(Int64(count), $0.1)) == .satisfied }
            }
        }

        func selection(_ indices: [Int]) throws -> Selection {
            guard selectionCounts.contains(indices.count), Set(indices).count == indices.count,
                  indices.allSatisfy({ candidateIndices.contains($0) }) else { throw ComputerUseBrowserLinkPlanError.invalidProposal }
            // Exact repeated passages cannot count twice. Different strings
            // alone do not prove distinct offers; the final selector must
            // interpret distinctness under the full original request.
            let signatures = indices.map { index in
                (passages[index] ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            }
            guard Set(signatures).count == signatures.count else { throw ComputerUseBrowserLinkPlanError.invalidProposal }
            return .init(eligibilityDigest: digest, indices: indices)
        }

        func answer(for selection: Selection) throws -> ComputerUseBrowserResearchAnswer {
            guard selection == (try self.selection(selection.indices)) else { throw ComputerUseBrowserLinkPlanError.inputChanged }
            let selected = try selection.indices.map { index -> String in
                guard let passage = passages[index], !passage.isEmpty else { throw ComputerUseBrowserLinkPlanError.inputChanged }
                return passage
            }
            let message = try ComputerUseBrowserResearchAnswer.render(source: source, passages: selected,
                surroundingText: surroundingText, requirements: requirements)
            return .init(rootTaskID: goal.taskID, goalRevision: goal.digest, readingIdentity: readingIdentity, selection: selection, message: message)
        }
    }

    let rootTaskID: String
    let goalRevision: String
    let readingIdentity: String
    fileprivate let selection: Selection
    let message: String
    private init(rootTaskID: String, goalRevision: String, readingIdentity: String, selection: Selection, message: String) {
        self.rootTaskID = rootTaskID; self.goalRevision = goalRevision; self.readingIdentity = readingIdentity
        self.selection = selection; self.message = message
    }
    func validate(for eligibility: Eligibility) throws {
        guard self == (try eligibility.answer(for: selection)) else { throw ComputerUseBrowserLinkPlanError.inputChanged }
    }
    /// Display formatting alone cannot create a typed, admitted answer.
    static func render(source: String, passages: [String], surroundingText: String, requirements: [String]) throws -> String {
        func quote(_ text: String) -> String { text.components(separatedBy: "\n").map { "│ " + $0 }.joined(separator: "\n") }
        var message = "Source-reported options for your request:\n\nSource page: " + source + "\n"
        for (offset, passage) in passages.enumerated() {
            message += "\nOption \(offset + 1) — page details (quoted):\n" + quote(passage) + "\n"
        }
        if !surroundingText.isEmpty { message += "\nOther observed page text (quoted):\n" + quote(surroundingText) + "\n" }
        message += "\nRequest and constraints used:\n" + requirements.map(quote).joined(separator: "\n")
        message += "\n\nThese are source-reported details, not a booking confirmation."
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

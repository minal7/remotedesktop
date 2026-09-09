import Foundation

/// An explicit semantic review of unread control metadata under the complete
/// task. It supplies no values and is not proof that the model's meaning is right.
struct ComputerUseBrowserEffectControlReview: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    struct Entry: Equatable, Sendable {
        let controlID: String
        let relationship: ComputerUseBrowserControlRelevance.Relationship
        let requirementIndices: [Int]
        let evidenceIDs: [String]
        var context: [String: Any] {
            ["control":controlID,"relationship":relationship.rawValue,"requirements":requirementIndices,"evidence":evidenceIDs]
        }
        func isValid(controlIDs: [String], evidenceIDs allowedEvidence: [String], requirementIndices allowedRequirements: [Int],
                     metadataComplete: Bool) -> Bool {
            controlIDs.contains(controlID) && requirementIndices.count <= 8 && Set(requirementIndices).count == requirementIndices.count
                && requirementIndices.allSatisfy(allowedRequirements.contains)
                && evidenceIDs.count <= 8 && Set(evidenceIDs).count == evidenceIDs.count
                && evidenceIDs.allSatisfy { allowedEvidence.contains($0) && ($0 == controlID || !controlIDs.contains($0)) }
                && (relationship == .unknown || evidenceIDs.contains(controlID))
                && (relationship != .relevant || !requirementIndices.isEmpty)
                && (relationship != .unrelated || (metadataComplete && requirementIndices.isEmpty))
        }
    }
    private let interpretation: ComputerUseBrowserGoalProposal
    private let evidence: ComputerUseBrowserPageEvidence
    let entries: [Entry]
    var description: String { "BrowserEffectControlReview(controls: \(entries.count))" }
    var debugDescription: String { description }

    private init(input: ComputerUseBrowserActionInput, entries: [Entry]) {
        interpretation = input.interpretation; evidence = input.evidence; self.entries = entries
    }

    static func decode(_ value: MCPJSONValue?, input: ComputerUseBrowserActionInput) throws -> Self {
        let invalid = ComputerUseBrowserActionPlanError.invalidProposal
        guard !input.effectReviewNextControlIDs.isEmpty, case .array(let rows)? = value,
              rows.count == input.effectReviewNextControlIDs.count else { throw invalid }
        let entries = try rows.enumerated().map { index, value -> Entry in
            guard case .object(let row) = value, Set(row.keys) == ["control","relationship","requirements","evidence"],
                  case .string(let id)? = row["control"], id == input.effectReviewNextControlIDs[index],
                  case .string(let name)? = row["relationship"], let relationship = ComputerUseBrowserControlRelevance.Relationship(rawValue: name),
                  case .array(let requirements)? = row["requirements"], case .array(let evidence)? = row["evidence"] else { throw invalid }
            let indices = try requirements.map { value -> Int in
                guard case .number(let number) = value, let index = Int(exactly: number) else { throw invalid }
                return index
            }
            let references = try evidence.map { value -> String in
                guard case .string(let id) = value else { throw invalid }; return id
            }
            let entry = Entry(controlID: id, relationship: relationship, requirementIndices: indices, evidenceIDs: references)
            guard entry.isValid(controlIDs: input.effectReviewControlIDs, evidenceIDs: input.effectReviewEvidenceIDs,
                requirementIndices: input.readableRequirementIndices, metadataComplete: input.effectReviewMetadataComplete) else { throw invalid }
            return entry
        }
        return .init(input: input, entries: entries)
    }

    static func retainedEntries(_ reviews: [Self], interpretation: ComputerUseBrowserGoalProposal, evidence: ComputerUseBrowserPageEvidence,
                                controlIDs: [String], evidenceIDs: [String], requirementIndices: [Int], metadataComplete: Bool) throws -> [Entry] {
        guard reviews.count <= 64 else { throw ComputerUseBrowserActionPlanError.invalidInput }
        var result: [Entry] = []
        for review in reviews {
            guard review.interpretation == interpretation, review.evidence == evidence, !review.entries.isEmpty,
                  review.entries.count <= 4, review.entries.map(\.controlID) == Array(controlIDs.dropFirst(result.count).prefix(review.entries.count)),
                  review.entries.allSatisfy({ $0.isValid(controlIDs: controlIDs, evidenceIDs: evidenceIDs,
                    requirementIndices: requirementIndices, metadataComplete: metadataComplete) }) else { throw ComputerUseBrowserActionPlanError.inputChanged }
            result += review.entries
        }
        return result
    }

    /// Keep a complete output unit inside the existing bounded action reply.
    /// A part is not a complete review and cannot release pending controls.
    static func nextControls(_ pending: [String], evidenceIDs: [String], requirementIndices: [Int]) throws -> [String] {
        let references = Array(evidenceIDs.sorted { $0.utf8.count > $1.utf8.count }.prefix(8))
        let requirements = Array(requirementIndices.sorted(by: >).prefix(8))
        var selected: [String] = []
        for id in pending.prefix(4) {
            let next = selected + [id]
            let rows: [[String: Any]] = next.map { ["control":$0,"relationship":"unrelated","requirements":requirements,"evidence":references] }
            guard try JSONSerialization.data(withJSONObject: ["review_controls":rows], options: [.sortedKeys]).count <= 896 else { break }
            selected = next
        }
        guard pending.isEmpty || !selected.isEmpty else { throw ComputerUseBrowserActionPlanError.contextLimit }
        return selected
    }

    static func schema(_ input: ComputerUseBrowserActionInput) -> [String: Any] {
        let relationships = input.effectReviewMetadataComplete ? ["unrelated","relevant","unknown"] : ["relevant","unknown"]
        let properties: [String: Any] = ["control":["type":"string","enum":input.effectReviewNextControlIDs],
            "relationship":["type":"string","enum":relationships],
            "requirements":["type":"array","maxItems":8,"items":["type":"integer","enum":input.readableRequirementIndices]],
            "evidence":["type":"array","maxItems":8,"items":["type":"string","enum":input.effectReviewEvidenceIDs]]]
        return ["type":"array","minItems":input.effectReviewNextControlIDs.count,"maxItems":input.effectReviewNextControlIDs.count,
            "items":["type":"object","additionalProperties":false,"properties":properties,"required":properties.keys.sorted()]]
    }
}

/// Completed structural scope review, still subject to model qualification.
/// Normal research owners bind it into their effect contract before dispatch.
struct ComputerUseBrowserEffectScopeReview: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let interpretation: ComputerUseBrowserGoalProposal
    private let evidence: ComputerUseBrowserPageEvidence
    let readControls: [ComputerUseBrowserControlRead]
    let reviews: [ComputerUseBrowserEffectControlReview]
    let digest: String
    var description: String { "BrowserEffectScopeReview" }
    var debugDescription: String { description }

    init(input: ComputerUseBrowserActionInput) throws {
        guard input.usesEffectScopeContext, input.effectScopeAllowsActions else { throw ComputerUseBrowserActionPlanError.invalidProposal }
        interpretation = input.interpretation; evidence = input.evidence
        readControls = input.optionReadControls; reviews = input.effectControlReviews
        digest = ComputerUseTaskContract.digest(["browser-effect-scope-review-v1",input.contextJSON])
    }
    func matches(interpretation: ComputerUseBrowserGoalProposal, evidence: ComputerUseBrowserPageEvidence) -> Bool {
        self.interpretation == interpretation && self.evidence == evidence
    }
}

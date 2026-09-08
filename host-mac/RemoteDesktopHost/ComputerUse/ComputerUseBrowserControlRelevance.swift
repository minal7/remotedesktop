import Foundation

/// Proposed relevance of visible metadata whose value was deliberately not
/// observed. This never supplies a value, result fact or authority to read it.
struct ComputerUseBrowserControlRelevance: Equatable, Sendable {
    enum Relationship: String, CaseIterable, Sendable { case unrelated, relevant, unknown }
    let controlID: String
    let relationship: Relationship
    let evidenceIDs: [String]
    var context: [String: Any] { ["control":controlID, "relationship":relationship.rawValue, "evidence":evidenceIDs] }

    static func decode(_ value: MCPJSONValue?, input: ComputerUseBrowserResultReviewInput, candidate: Int,
                       expected: [String]? = nil, allowMissing: Bool = true) throws -> [Self] {
        let ids = expected ?? input.unobservedControlIDs
        // Earlier/conservative reviewers cannot erase a missing value merely
        // by omitting the new review member.
        if value == nil, allowMissing { return ids.map { .init(controlID: $0, relationship: .unknown, evidenceIDs: []) } }
        guard case .array(let rows)? = value, rows.count == ids.count else { throw ComputerUseBrowserResultReviewError.invalidProposal }
        return try rows.enumerated().map { index, row in
            guard case .object(let item) = row, Set(item.keys) == ["control", "relationship", "evidence"],
                  case .string(let id)? = item["control"], id == ids[index],
                  case .string(let name)? = item["relationship"], let relationship = Relationship(rawValue: name),
                  case .array(let references)? = item["evidence"], references.count <= 8 else {
                throw ComputerUseBrowserResultReviewError.invalidProposal
            }
            var evidence: [String] = []
            for reference in references {
                guard case .string(let source) = reference, !evidence.contains(source),
                      input.controlRelevanceEvidenceIDs.contains(source),
                      source == id || (!input.unobservedControlIDs.contains(source) && input.permitsReference(source, for: candidate)) else {
                    throw ComputerUseBrowserResultReviewError.invalidProposal
                }
                evidence.append(source)
            }
            guard relationship == .unknown || evidence.contains(id),
                  relationship != .unrelated || (input.controlMetadataComplete && input.permitsOfferAssertions && input.interpretation != nil) else {
                throw ComputerUseBrowserResultReviewError.invalidProposal
            }
            return .init(controlID: id, relationship: relationship, evidenceIDs: evidence)
        }
    }

    static func schema(input: ComputerUseBrowserResultReviewInput, ids: [String]) -> [String: Any] {
        func enumeration(_ values: [String]) -> [String: Any] { values.isEmpty ? ["type":"string"] : ["type":"string", "enum":values] }
        let relationships = input.controlMetadataComplete && input.permitsOfferAssertions && input.interpretation != nil
            ? Relationship.allCases.map(\.rawValue) : ["relevant", "unknown"]
        return ["type":"array", "minItems":ids.count, "maxItems":ids.count,
            "items":["type":"object", "additionalProperties":false,
                "properties":["control":enumeration(ids), "relationship":enumeration(relationships),
                    "evidence":["type":"array", "maxItems":min(8, input.controlRelevanceEvidenceIDs.count),
                        "items":enumeration(input.controlRelevanceEvidenceIDs)]],
                "required":["control", "relationship", "evidence"]]]
    }

    static func outputBounds(input: ComputerUseBrowserResultReviewInput, ids: [String]) -> [[String: Any]] {
        let evidence = Array(input.controlRelevanceEvidenceIDs.sorted { $0.utf8.count > $1.utf8.count }.prefix(8))
        return ids.map { ["control":$0, "relationship":"unrelated", "evidence":evidence] }
    }
}

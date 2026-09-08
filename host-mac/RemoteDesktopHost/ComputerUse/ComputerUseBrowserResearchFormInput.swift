import Foundation

enum ComputerUseBrowserResearchFormError: Error, Equatable { case invalidInput, invalidProposal, inputChanged, contextLimit, stageLimit }

/// Source-bound control references selected before private field values are read.
struct ComputerUseBrowserControlPreservation: Equatable, Sendable {
    let controlID: String
    let requirementIndex: Int
}

/// Proposal-only form context. Aliases describe native correspondence, not
/// permission to edit or submit. The original request and every accepted answer
/// remain intact; a later compiler must account for the remaining requirements.
struct ComputerUseBrowserResearchFormInput: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let interpretation: ComputerUseBrowserGoalProposal
    let evidence: ComputerUseBrowserFormEvidence
    let contextJSON: String
    let fieldAliases: [String]
    let editableFieldAliases: [String]
    let selectedFormID: String?
    let requiredPreservation: [ComputerUseBrowserFormProposal.Preservation]
    let previous: ComputerUseBrowserResearchFormContinuation?
    struct Normalization: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        enum Kind: String, Sendable { case date, partySize }
        let id: String
        let requirementIndex: Int
        let kind: Kind
        let value: String
        let unit: String
        var description: String { "BrowserFormNormalization(kind: \(kind.rawValue))" }
        var debugDescription: String { description }
    }
    let normalizations: [Normalization]

    /// Only exact dates and explicit party counts have an unambiguous scalar
    /// representation for these native input kinds. Ranges, maxima and counts
    /// of desired results cannot silently become an exact day or party size.
    static func normalizations(for interpretation: ComputerUseBrowserGoalProposal) -> [Normalization] {
        let ledger = ComputerUseBrowserScalarRequirements(proposal: interpretation)
        return ledger.entries.enumerated().compactMap { index, entry in
            guard case .bound(let condition) = entry.resolution else { return nil }
            switch condition.predicate {
            case .day(let range):
                guard let day = range.lower, range.upper == day, range.lowerInclusive, range.upperInclusive else { return nil }
                return .init(id: "value\(index + 1)", requirementIndex: index, kind: .date, value: day.iso8601, unit: "civilDay")
            case .quantity(.equal, let count, let unit) where unit.isPartySize:
                return .init(id: "value\(index + 1)", requirementIndex: index, kind: .partySize, value: String(count), unit: unit.rawValue)
            default: return nil
            }
        }
    }

    init(interpretation: ComputerUseBrowserGoalProposal, evidence: ComputerUseBrowserFormEvidence, selectedFormID: String? = nil,
         preservedControls: [ComputerUseBrowserControlPreservation] = [], previous: ComputerUseBrowserResearchFormContinuation? = nil) throws {
        guard interpretation.disposition == .research,
              interpretation.input.taskID.utf8.elementsEqual(evidence.page.document.taskID.utf8),
              (1...16).contains(evidence.fields.count), preservedControls.count <= 16,
              Set(preservedControls.map(\.controlID)).count == preservedControls.count else { throw ComputerUseBrowserResearchFormError.invalidInput }
        if let previous {
            guard previous.taskID == interpretation.input.taskID, previous.rootDigest == interpretation.input.rootDigest,
                  previous.goalRevision == interpretation.input.digest, previous.formID == selectedFormID,
                  previous.document == evidence.page.document, previous.documentID == evidence.page.documentID,
                  previous.finalValues.allSatisfy({ id, value in
                      evidence.fields.contains { $0.editable.snapshot.targetID == id && $0.editable.snapshot.value.utf8.elementsEqual(value.utf8) }
                  }) else { throw ComputerUseBrowserResearchFormError.inputChanged }
        }
        var carriedControls = previous?.preservedControls ?? []
        for control in preservedControls {
            if let earlier = carriedControls.first(where: { $0.controlID == control.controlID }) {
                guard earlier == control else { throw ComputerUseBrowserResearchFormError.invalidInput }
            } else { carriedControls.append(control) }
        }
        let serialized = try ComputerUseBrowserPlanningContext(page: evidence.page.page).serialized()
        guard let page = try JSONSerialization.jsonObject(with: Data(serialized.utf8)) as? [String: Any],
              let records = page["records"] as? [[String: Any]] else { throw ComputerUseBrowserResearchFormError.invalidInput }
        let projectedControls = Set(records.filter { $0["kind"] as? String == "control" }.compactMap { $0["id"] as? String })
        guard Set(evidence.fields.map { $0.control.id }).isSubset(of: projectedControls) else {
            // An alias without its complete observed type/constraints/choices
            // would ask the planner to guess. Never trim a control to fit.
            throw ComputerUseBrowserResearchFormError.contextLimit
        }
        let aliases = evidence.fields.indices.map { "field\($0 + 1)" }
        let preserved: [ComputerUseBrowserFormProposal.Preservation] = try carriedControls.map { item in
            guard let index = evidence.fields.firstIndex(where: { $0.control.id == item.controlID }),
                  interpretation.requirements.indices.contains(item.requirementIndex),
                  [.outcome, .condition, .prohibition].contains(interpretation.requirements[item.requirementIndex].role) else {
                throw ComputerUseBrowserResearchFormError.invalidInput
            }
            return .init(field: aliases[index], requirementIndex: item.requirementIndex)
        }
        let preservedIDs = Set(carriedControls.map(\.controlID))
        if let selectedFormID {
            guard evidence.fields.allSatisfy({ $0.control.form?.id == selectedFormID || preservedIDs.contains($0.control.id) }) else {
                throw ComputerUseBrowserResearchFormError.invalidInput
            }
        }
        let editable = zip(aliases, evidence.fields).compactMap { alias, field in
            !preservedIDs.contains(field.control.id) && (selectedFormID == nil || field.control.form?.id == selectedFormID) ? alias : nil
        }
        guard !editable.isEmpty else { throw ComputerUseBrowserResearchFormError.invalidInput }
        let bindings = zip(aliases, evidence.fields).map {
            ["field":$0.0, "control":$0.1.control.id, "editable":editable.contains($0.0)] as [String: Any]
        }
        let requirements: [[String: Any]] = try interpretation.requirements.enumerated().map { index, requirement in
            guard let source = interpretation.source(of: requirement) else { throw ComputerUseBrowserResearchFormError.invalidInput }
            return ["index":index, "turn":requirement.sourceTurnIndex,
                "sourceByteOffset":requirement.sourceByteOffset, "sourceByteCount":requirement.sourceByteCount,
                "source":source, "role":requirement.role.rawValue, "field":requirement.field.rawValue,
                "relation":requirement.relation.rawValue, "values":requirement.values]
        }
        let normalized = Self.normalizations(for: interpretation)
        let priorEdits: [[String: Any]] = zip(aliases, evidence.fields).compactMap { alias, field in
            guard let indices = previous?.editedRequirements[field.editable.snapshot.targetID] else { return nil }
            return ["field":alias, "requirements":indices]
        }
        let context: [String: Any] = ["version":5, "goal":interpretation.input.plannerContext,
            "selected_form":selectedFormID.map { $0 as Any } ?? NSNull(),
            "required_preservation":preserved.map { ["field":$0.field, "requirement":$0.requirementIndex] as [String: Any] },
            "previous_edits":priorEdits,
            "requirements":requirements, "page":page, "field_bindings":bindings,
            "normalized_values":normalized.map { ["id":$0.id, "requirement":$0.requirementIndex,
                "kind":$0.kind.rawValue, "value":$0.value, "unit":$0.unit] as [String: Any] }]
        contextJSON = String(decoding: try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]), as: UTF8.self)
        self.interpretation = interpretation; self.evidence = evidence; fieldAliases = aliases
        normalizations = normalized; editableFieldAliases = editable; self.selectedFormID = selectedFormID
        requiredPreservation = preserved
        self.previous = previous
    }

    /// Resolve only an offered reference in this immutable input. Execution
    /// still requires owner revalidation and a separately compiled contract.
    func field(for alias: String) throws -> ComputerUseBrowserFormEvidence.Field {
        guard let index = fieldAliases.firstIndex(where: { $0.utf8.elementsEqual(alias.utf8) }) else {
            throw ComputerUseBrowserResearchFormError.invalidInput
        }
        return evidence.fields[index]
    }

    var description: String { "BrowserResearchFormInput(fields: \(fieldAliases.count))" }
    var debugDescription: String { description }
}

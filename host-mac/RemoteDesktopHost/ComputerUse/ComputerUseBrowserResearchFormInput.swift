import Foundation

enum ComputerUseBrowserResearchFormError: Error, Equatable { case invalidInput, inputChanged, contextLimit }

/// Proposal-only form context. Aliases describe native correspondence, not
/// permission to edit or submit. The original request and every accepted answer
/// remain intact; a later compiler must account for the remaining requirements.
struct ComputerUseBrowserResearchFormInput: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let interpretation: ComputerUseBrowserGoalProposal
    let evidence: ComputerUseBrowserFormEvidence
    let contextJSON: String
    let fieldAliases: [String]

    init(interpretation: ComputerUseBrowserGoalProposal, evidence: ComputerUseBrowserFormEvidence) throws {
        guard interpretation.disposition == .research,
              interpretation.input.taskID.utf8.elementsEqual(evidence.page.document.taskID.utf8),
              !evidence.fields.isEmpty else { throw ComputerUseBrowserResearchFormError.invalidInput }
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
        let bindings = zip(aliases, evidence.fields).map { ["field":$0.0, "control":$0.1.control.id] }
        let requirements: [[String: Any]] = try interpretation.requirements.enumerated().map { index, requirement in
            guard let source = interpretation.source(of: requirement) else { throw ComputerUseBrowserResearchFormError.invalidInput }
            return ["index":index, "turn":requirement.sourceTurnIndex,
                "sourceByteOffset":requirement.sourceByteOffset, "sourceByteCount":requirement.sourceByteCount,
                "source":source, "role":requirement.role.rawValue, "field":requirement.field.rawValue,
                "relation":requirement.relation.rawValue, "values":requirement.values]
        }
        let context: [String: Any] = ["version":1, "goal":interpretation.input.plannerContext,
            "requirements":requirements, "page":page, "field_bindings":bindings]
        contextJSON = String(decoding: try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]), as: UTF8.self)
        self.interpretation = interpretation; self.evidence = evidence; fieldAliases = aliases
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

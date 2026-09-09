import Foundation

/// A retained form/query selection before discovery or navigation. It grants
/// no effect authority; the remaining control metadata must be accounted for.
struct ComputerUseBrowserFormEffectScope: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Kind: Equatable, Sendable {
        case form(String)
        case query(String, ComputerUseBrowserResearchFormReceipt)
    }
    let kind: Kind
    let preservedControls: [ComputerUseBrowserControlPreservation]
    private let interpretation: ComputerUseBrowserGoalProposal
    private let evidence: ComputerUseBrowserPageEvidence
    let digest: String
    var description: String { "BrowserFormEffectScope" }
    var debugDescription: String { description }
    var formID: String? { if case .form(let id) = kind { return id }; return nil }
    var queryControlID: String? { if case .query(let id, _) = kind { return id }; return nil }
    var context: [String: Any] {
        ["kind":formID == nil ? "query" : "form", "target":formID ?? queryControlID ?? "",
         "preserve":preservedControls.map { ["control":$0.controlID,"requirement":$0.requirementIndex] as [String: Any] }]
    }
    var actionContent: String {
        get throws {
            let object: [String: Any]
            switch kind {
            case .form(let id): object = ["form":id,"preserve":context["preserve"] ?? []]
            case .query(let id, _): object = ["query":id]
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
    }

    init(action: ComputerUseBrowserActionProposal) throws {
        let input = action.input
        let kind: Kind, preserved: [ComputerUseBrowserControlPreservation]
        switch action.step {
        case .editForm(let id):
            kind = .form(id)
            var controls = input.formEffectScope?.preservedControls ?? []
            for carried in input.carriedFormPreservation.filter({ $0.formID == id }).map(\.control) {
                if !controls.contains(where: { $0.controlID == carried.controlID }) { controls.append(carried) }
            }
            for control in action.preservedControls {
                if let old = controls.first(where: { $0.controlID == control.controlID }) {
                    guard old.requirementIndex == control.requirementIndex else { throw ComputerUseBrowserActionPlanError.invalidProposal }
                }
                else { controls.append(control) }
            }
            preserved = controls
        case .openQuery(let id, let receipt): kind = .query(id, receipt); preserved = []
        default: throw ComputerUseBrowserActionPlanError.invalidProposal
        }
        try self.init(kind: kind, preservedControls: preserved, interpretation: input.interpretation, evidence: input.evidence)
    }

    private init(kind: Kind, preservedControls: [ComputerUseBrowserControlPreservation],
                 interpretation: ComputerUseBrowserGoalProposal, evidence: ComputerUseBrowserPageEvidence) throws {
        guard preservedControls.count <= 16, Set(preservedControls.map(\.controlID)).count == preservedControls.count,
              preservedControls.allSatisfy({ interpretation.requirements.indices.contains($0.requirementIndex)
                && [.outcome, .condition, .prohibition].contains(interpretation.requirements[$0.requirementIndex].role) }) else {
            throw ComputerUseBrowserActionPlanError.invalidProposal
        }
        self.kind = kind; self.preservedControls = preservedControls; self.interpretation = interpretation; self.evidence = evidence
        let target: [String]
        switch kind {
        case .form(let id): target = ["form", id]
        case .query(let id, let receipt): target = ["query", id, receipt.stageID, receipt.contractDigest]
        }
        digest = ComputerUseTaskContract.digest(["browser-form-effect-scope-v1", interpretation.input.digest,
            evidence.document.contextID, evidence.documentID, evidence.page.id] + target
            + preservedControls.flatMap { [$0.controlID, String($0.requirementIndex)] })
    }

    func extending(_ controls: [ComputerUseBrowserControlPreservation]) throws -> Self {
        guard formID != nil, !controls.isEmpty,
              controls.allSatisfy({ added in !preservedControls.contains { $0.controlID == added.controlID } }) else {
            throw ComputerUseBrowserActionPlanError.invalidProposal
        }
        return try .init(kind: kind, preservedControls: preservedControls + controls, interpretation: interpretation, evidence: evidence)
    }

    /// Only the owner uses this after native revalidation and an additive read.
    func continuingQuery(with evidence: ComputerUseBrowserPageEvidence) throws -> Self {
        guard queryControlID != nil, evidence.document == self.evidence.document, evidence.documentID == self.evidence.documentID else {
            throw ComputerUseBrowserActionPlanError.inputChanged
        }
        return try .init(kind: kind, preservedControls: preservedControls, interpretation: interpretation, evidence: evidence)
    }

    func matches(interpretation: ComputerUseBrowserGoalProposal, evidence: ComputerUseBrowserPageEvidence,
                 forms: [String], queries: [String], receipt: ComputerUseBrowserResearchFormReceipt?) -> Bool {
        guard self.interpretation == interpretation, self.evidence == evidence else { return false }
        switch kind {
        case .form(let id): return forms.contains(id)
        case .query(let id, let expected): return queries.contains(id) && receipt == expected
        }
    }

    func coveredControlIDs(in page: ComputerUseBrowserPageSnapshot, discoverableControls: [String], queryBoundControls: [String]) -> Set<String> {
        switch kind {
        case .form(let id): return Set(page.controls.filter { $0.form?.id == id && (discoverableControls.contains($0.id) || ["submit","button","reset","image"].contains($0.kind)) }.map(\.id) + preservedControls.map(\.controlID))
        case .query(let id, _): return Set(queryBoundControls + [id])
        }
    }
}

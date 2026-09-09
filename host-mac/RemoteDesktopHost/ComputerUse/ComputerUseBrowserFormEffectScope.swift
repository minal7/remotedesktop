import Foundation

/// A retained form/query selection before discovery or navigation. It grants
/// no effect authority; the remaining control metadata must be accounted for.
struct ComputerUseBrowserFormEffectScope: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    struct FieldIntent: Equatable, Sendable {
        enum Disposition: String, Sendable { case edit, retain, deferred }
        let controlID: String
        let disposition: Disposition
        let requirementIndices: [Int]
        var context: [String: Any] {
            ["control":controlID, "disposition":disposition.rawValue, "requirements":requirementIndices]
        }
    }
    enum Kind: Equatable, Sendable {
        case form(String)
        case query(String, ComputerUseBrowserResearchFormReceipt)
    }
    let kind: Kind
    let preservedControls: [ComputerUseBrowserControlPreservation]
    let fieldIntents: [FieldIntent]
    var plannedControlIDs: [String] { fieldIntents.map(\.controlID) + preservedControls.map(\.controlID) }
    var discoveryControlIDs: [String] { fieldIntents.filter { $0.disposition != .deferred }.map(\.controlID) + preservedControls.map(\.controlID) }
    var selectedControlIDs: [String] { fieldIntents.filter { $0.disposition != .deferred }.map(\.controlID) }
    private let interpretation: ComputerUseBrowserGoalProposal
    private let evidence: ComputerUseBrowserPageEvidence
    let digest: String
    var description: String { "BrowserFormEffectScope" }
    var debugDescription: String { description }
    var formID: String? { if case .form(let id) = kind { return id }; return nil }
    var queryControlID: String? { if case .query(let id, _) = kind { return id }; return nil }
    var context: [String: Any] {
        ["kind":formID == nil ? "query" : "form", "target":formID ?? queryControlID ?? "",
         "preserve":preservedControls.map { ["control":$0.controlID,"requirement":$0.requirementIndex] as [String: Any] },
         "fields":fieldIntents.map(\.context)]
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
        try self.init(kind: kind, preservedControls: preserved, fieldIntents: [], interpretation: input.interpretation, evidence: input.evidence)
    }

    private init(kind: Kind, preservedControls: [ComputerUseBrowserControlPreservation], fieldIntents: [FieldIntent],
                 interpretation: ComputerUseBrowserGoalProposal, evidence: ComputerUseBrowserPageEvidence) throws {
        let ids = preservedControls.map(\.controlID) + fieldIntents.map(\.controlID)
        guard ids.count <= 16, Set(ids).count == ids.count,
              fieldIntents.filter({ $0.disposition == .edit }).count <= 8,
              fieldIntents.allSatisfy({ intent in
                  (1...8).contains(intent.requirementIndices.count)
                    && Set(intent.requirementIndices).count == intent.requirementIndices.count
                    && intent.requirementIndices.allSatisfy { index in interpretation.requirements.indices.contains(index)
                        && [.outcome, .condition].contains(interpretation.requirements[index].role) }
              }),
              preservedControls.allSatisfy({ interpretation.requirements.indices.contains($0.requirementIndex)
                && [.outcome, .condition, .prohibition].contains(interpretation.requirements[$0.requirementIndex].role) }) else {
            throw ComputerUseBrowserActionPlanError.invalidProposal
        }
        self.kind = kind; self.preservedControls = preservedControls; self.fieldIntents = fieldIntents
        self.interpretation = interpretation; self.evidence = evidence
        let target: [String]
        switch kind {
        case .form(let id): target = ["form", id]
        case .query(let id, let receipt): target = ["query", id, receipt.stageID, receipt.contractDigest]
        }
        digest = ComputerUseTaskContract.digest(["browser-form-effect-scope-v2", interpretation.input.digest,
            evidence.document.contextID, evidence.documentID, evidence.page.id] + target
            + [String(preservedControls.count)] + preservedControls.flatMap { [$0.controlID, String($0.requirementIndex)] }
            + [String(fieldIntents.count)] + fieldIntents.flatMap { [$0.controlID, $0.disposition.rawValue, String($0.requirementIndices.count)] + $0.requirementIndices.map(String.init) })
    }

    func extending(_ controls: [ComputerUseBrowserControlPreservation]) throws -> Self {
        guard formID != nil, !controls.isEmpty,
              controls.allSatisfy({ added in !preservedControls.contains { $0.controlID == added.controlID } }) else {
            throw ComputerUseBrowserActionPlanError.invalidProposal
        }
        return try .init(kind: kind, preservedControls: preservedControls + controls, fieldIntents: fieldIntents, interpretation: interpretation, evidence: evidence)
    }

    func planning(_ intents: [FieldIntent]) throws -> Self {
        guard formID != nil, !intents.isEmpty,
              intents.allSatisfy({ !plannedControlIDs.contains($0.controlID) }) else { throw ComputerUseBrowserActionPlanError.invalidProposal }
        return try .init(kind: kind, preservedControls: preservedControls, fieldIntents: fieldIntents + intents,
                         interpretation: interpretation, evidence: evidence)
    }

    /// Only the owner uses this after native revalidation and an additive read.
    func continuingQuery(with evidence: ComputerUseBrowserPageEvidence) throws -> Self {
        guard queryControlID != nil, evidence.document == self.evidence.document, evidence.documentID == self.evidence.documentID else {
            throw ComputerUseBrowserActionPlanError.inputChanged
        }
        return try .init(kind: kind, preservedControls: preservedControls, fieldIntents: fieldIntents, interpretation: interpretation, evidence: evidence)
    }

    func matches(interpretation: ComputerUseBrowserGoalProposal, evidence: ComputerUseBrowserPageEvidence,
                 forms: [String], queries: [String], receipt: ComputerUseBrowserResearchFormReceipt?) -> Bool {
        guard self.interpretation == interpretation, self.evidence == evidence else { return false }
        switch kind {
        case .form(let id): return forms.contains(id)
        case .query(let id, let expected): return queries.contains(id) && receipt == expected
        }
    }

    func coveredControlIDs(in page: ComputerUseBrowserPageSnapshot, queryBoundControls: [String]) -> Set<String> {
        switch kind {
        case .form(let id): return Set(page.controls.filter { $0.form?.id == id && ["submit","button","reset","image"].contains($0.kind) }.map(\.id) + plannedControlIDs)
        case .query(let id, _): return Set(queryBoundControls + [id])
        }
    }
}

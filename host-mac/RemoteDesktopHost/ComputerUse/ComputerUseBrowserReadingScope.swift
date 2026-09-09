import Foundation

/// A proposed read scope, selected from metadata before any scoped value enters
/// research context. A source reference is not proof of semantic relevance.
struct ComputerUseBrowserControlRead: Equatable, Sendable {
    let controlID: String
    let requirementIndex: Int

    static func accepts(_ requirement: ComputerUseBrowserGoalProposal.Requirement) -> Bool {
        [.outcome, .condition].contains(requirement.role)
            && ![.source, .navigationSource, .answerSource].contains(requirement.field)
    }

    static func allows(_ control: ComputerUseBrowserPageSnapshot.Control) -> Bool {
        if control.compositeRole != nil {
            return control.compositeMetadataIsWellFormed && control.researchReadable && !control.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return control.researchReadable && (["text", "search", "date", "datetime-local", "month", "week", "time", "number", "select", "checkbox", "radio"].contains(control.kind)
            || ComputerUseBrowserDeclaredState.kinds.contains(control.kind))
            && (["text", "search"].contains(control.kind) || control.disabled || control.readOnly || ComputerUseBrowserDeclaredState.kinds.contains(control.kind))
            && !control.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension ComputerUseOwnedBrowser {
    /// The script first revalidates the metadata snapshot and native objects,
    /// then reads only the explicitly selected restricted controls in that invocation.
    func observeResearchControls(for action: ComputerUseBrowserActionProposal) async throws -> ComputerUseBrowserPageEvidence {
        let evidence = action.input.evidence
        guard action.step == .readResults || action.step == .inspectOptions, !action.readControls.isEmpty,
              action.input.interpretation.input.taskID == evidence.document.taskID,
              hasRequiredPresentation else { throw ComputerUseBrowserActionPlanError.inputChanged }
        try validateSourceDocument(evidence.document)
        let ids = action.readControls.map(\.controlID)
        let result = try await callDOM(.observeResearchControls, arguments: ["documentID":evidence.documentID,
            "snapshotID":evidence.page.id, "readControlIDs":ids], document: evidence.document)
        guard hasRequiredPresentation, result.status == "page-snapshot", result.fields == nil,
              result.documentID == evidence.documentID, let page = result.page, page.isWellFormed,
              page.controlStateObserved, page.scopedControlIDs == ids else { throw ComputerUseBrowserError.pageChanged }
        try validateSourceDocument(evidence.document)
        return .init(document: evidence.document, documentID: result.documentID, page: page)
    }
}

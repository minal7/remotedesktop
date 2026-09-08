import Foundation

/// A proposed read scope, selected from metadata before any text value enters
/// research context. A source reference is not proof of semantic relevance.
struct ComputerUseBrowserControlRead: Equatable, Sendable {
    let controlID: String
    let requirementIndex: Int

    static func accepts(_ requirement: ComputerUseBrowserGoalProposal.Requirement) -> Bool {
        [.outcome, .condition].contains(requirement.role)
            && [.category, .origin, .destination, .location, .date, .time, .quantity].contains(requirement.field)
    }

    static func allows(_ control: ComputerUseBrowserPageSnapshot.Control) -> Bool {
        control.researchReadable && ["text", "search"].contains(control.kind) && !control.disabled && !control.readOnly
            && !control.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension ComputerUseOwnedBrowser {
    /// The script first revalidates the metadata snapshot and native objects,
    /// then reads only the selected text controls in that same invocation.
    func observeResearchControls(for action: ComputerUseBrowserActionProposal) async throws -> ComputerUseBrowserPageEvidence {
        let evidence = action.input.evidence
        guard case .readResults = action.step, !action.readControls.isEmpty,
              action.input.interpretation.input.taskID == evidence.document.taskID,
              hasRequiredPresentation else { throw ComputerUseBrowserActionPlanError.inputChanged }
        try validateSourceDocument(evidence.document)
        let ids = action.readControls.map(\.controlID)
        let result = try await callDOM(.observeResearchControls, arguments: ["documentID":evidence.documentID,
            "snapshotID":evidence.page.id, "readControlIDs":ids], document: evidence.document)
        guard hasRequiredPresentation, result.status == "page-snapshot", result.fields == nil,
              result.documentID == evidence.documentID, let page = result.page, page.isWellFormed,
              page.controlStateObserved, page.textControlIDs == ids else { throw ComputerUseBrowserError.pageChanged }
        try validateSourceDocument(evidence.document)
        return .init(document: evidence.document, documentID: result.documentID, page: page)
    }
}

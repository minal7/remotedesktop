import Foundation

/// Retained before the first private read. Cancellation can stop the waiter,
/// but cannot replace this intent, its captured values or its native adapter.
@MainActor
final class ComputerUseBrowserResearchFormPreparation {
    let interpretation: ComputerUseBrowserGoalProposal
    let page: ComputerUseBrowserPageEvidence
    let review: ComputerUseBrowserEffectScopeReview
    let formID: String
    let target: ComputerUseBrowserTextTarget
    private let parent: ComputerUseBrowserResearchFormStage?
    private let previous: ComputerUseBrowserResearchFormContinuation?
    private let fieldsCapture: ComputerUseBrowserDOMReadCapture
    private let bindingCapture: ComputerUseBrowserDOMReadCapture
    private let preservationCapture: ComputerUseBrowserDOMReadCapture
    private var fields: [ComputerUseTextField]?
    private var evidence: ComputerUseBrowserFormEvidence?
    private var preservation: ComputerUseBrowserFormPreservation?
    private var preservationFinished = false
    private(set) var preparedInput: ComputerUseBrowserResearchFormInput?
    var hasPreservationObligations: Bool {
        previous != nil || review.formScope?.preservedControls.isEmpty != true || !review.readControls.isEmpty
    }

    init(action: ComputerUseBrowserActionProposal, browser: ComputerUseOwnedBrowser, parent: ComputerUseBrowserResearchFormStage? = nil) throws {
        guard case .editForm(let formID) = action.step else { throw ComputerUseBrowserActionPlanError.invalidProposal }
        let review = try ComputerUseBrowserEffectScopeReview(input: action.input)
        guard review.formScope?.formID == formID, review.formScope?.preservedControls == action.preservedControls else {
            throw ComputerUseBrowserActionPlanError.invalidProposal
        }
        interpretation = action.input.interpretation; page = action.input.evidence; self.formID = formID; self.review = review
        let prior = try parent?.preparationContext(for: action)
        self.parent = parent; previous = prior?.continuation
        target = prior?.target ?? .init(browser: browser, document: page.document, requiresFrontmost: browser.isFrontmostWindow)
        fieldsCapture = try .init(command: prior == nil ? .formFields : .extendFormFields, document: page.document)
        bindingCapture = try .init(command: .bindPageFields, document: page.document)
        preservationCapture = try .init(command: .prepareFormPreservation, document: page.document)
    }

    func prepare(browser: ComputerUseOwnedBrowser, checkCurrent: () throws -> Void) async throws -> ComputerUseBrowserResearchFormInput {
        func check() throws {
            try checkCurrent()
            if let parent, let previous { try parent.validatePreparationContinuation(previous) }
        }
        do {
            try check()
            if let preparedInput {
                try await ComputerUseBrowserResearchFormStage.validateOriginalInput(preparedInput, target: target,
                    browser: browser, checkCurrent: check)
                return preparedInput
            }
            let current = try await ComputerUseBrowserResearchFormStage.restoreOriginalPage(page, review: review,
                browser: browser, checkCurrent: check)
            guard let scope = review.formScope else { throw ComputerUseBrowserResearchFormError.inputChanged }
            if fields == nil {
                if let previous {
                    fields = try await target.extendFields(in: formID, page: current, preserving: scope.editablePreservedControlIDs,
                        selecting: scope.selectedControlIDs, after: previous, retaining: fieldsCapture)
                } else {
                    fields = try await target.fields(in: formID, page: current, preserving: scope.editablePreservedControlIDs,
                        selecting: scope.selectedControlIDs, retaining: fieldsCapture)
                }
                try check()
            }
            guard let fields else { throw ComputerUseBrowserResearchFormError.invalidInput }
            if evidence == nil {
                let bound = try await target.bindFields(fields, to: current, retaining: bindingCapture)
                guard bound.fields.count == fields.count, fields.allSatisfy({ field in
                    bound.fields.contains { $0.editable == field }
                }) else { throw ComputerUseBrowserResearchFormError.inputChanged }
                evidence = .init(page: page, fields: bound.fields, adapterID: bound.adapterID)
                try check()
            }
            if !preservationFinished {
                preservation = try await target.prepareFormPreservation(scope: scope, page: current, retaining: preservationCapture)
                preservationFinished = true
                try check()
            }
            guard let evidence else { throw ComputerUseBrowserResearchFormError.invalidInput }
            let prepared = try ComputerUseBrowserResearchFormInput(interpretation: interpretation, evidence: evidence,
                selectedFormID: formID, preservedControls: scope.preservedControls, previous: previous,
                scopeReview: review, nativePreservation: preservation)
            preparedInput = prepared // Keep the original result before the next cancellable validation.
            try await ComputerUseBrowserResearchFormStage.validateOriginalInput(prepared, target: target, browser: browser, checkCurrent: check)
            return prepared
        } catch {
            // The callback publishes into its capture before waking this join.
            // Do not release the owner's slot while private reads still run.
            await browser.joinDOMCompletion(document: page.document)
            throw error
        }
    }
}

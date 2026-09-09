import Foundation

/// Historical purposes for a fresh review of a retained preparation. Native
/// field values, target IDs, guard IDs and operation receipts stay out of this
/// proposal context. Source overlap is a reference, not semantic equivalence.
struct ComputerUseBrowserFormPreparationReviewContext: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    struct FieldPurpose: Equatable, Sendable {
        let controlID: String
        let disposition: ComputerUseBrowserFormEffectScope.FieldIntent.Disposition
        let sources: [ComputerUseBrowserFormSource]
    }
    let formID: String
    let preservedSources: [ComputerUseBrowserFormPreservationSource]
    let readSources: [ComputerUseBrowserFormPreservationSource]
    let fieldPurposes: [FieldPurpose]
    private let original: ComputerUseBrowserGoalInput
    private let page: ComputerUseBrowserPageEvidence
    let digest: String
    var description: String { "BrowserFormPreparationReviewContext" }
    var debugDescription: String { description }

    init(interpretation: ComputerUseBrowserGoalProposal, page: ComputerUseBrowserPageEvidence,
         review: ComputerUseBrowserEffectScopeReview, previous: ComputerUseBrowserResearchFormContinuation?) throws {
        guard review.matches(interpretation: interpretation, evidence: page), let scope = review.formScope, let formID = scope.formID else {
            throw ComputerUseBrowserActionPlanError.invalidInput
        }
        if let previous {
            guard interpretation.input.continues(previous.goal), previous.document == page.document,
                  previous.documentID == page.documentID, previous.formID == formID else { throw ComputerUseBrowserActionPlanError.inputChanged }
        }
        var sources = previous?.preservedControls ?? []
        for item in scope.preservedControls {
            if let old = sources.first(where: { $0.controlID == item.controlID }) {
                guard try old.source.indices(in: interpretation).contains(item.requirementIndex) else { throw ComputerUseBrowserActionPlanError.inputChanged }
            } else {
                sources.append(.init(controlID: item.controlID, source: try .init(index: item.requirementIndex, interpretation: interpretation)))
            }
        }
        guard Set(sources.map(\.controlID)) == Set(scope.preservedControls.map(\.controlID)) else { throw ComputerUseBrowserActionPlanError.inputChanged }
        preservedSources = sources
        readSources = try review.readControls.map { .init(controlID: $0.controlID, source: try .init(index: $0.requirementIndex, interpretation: interpretation)) }
        fieldPurposes = try scope.fieldIntents.map { intent in
            .init(controlID: intent.controlID, disposition: intent.disposition,
                sources: try intent.requirementIndices.map { try .init(index: $0, interpretation: interpretation) })
        }
        self.formID = formID; original = interpretation.input; self.page = page
        digest = ComputerUseTaskContract.digest(["browser-form-preparation-review-v1", original.digest,
            page.document.contextID, String(page.document.generation), page.documentID, page.page.id, review.digest, previous?.digest ?? ""])
    }

    func validate(interpretation: ComputerUseBrowserGoalProposal, evidence: ComputerUseBrowserPageEvidence) throws {
        let ids = Array(Set(preservedSources.map(\.controlID) + readSources.map(\.controlID) + fieldPurposes.map(\.controlID))).sorted()
        guard interpretation.disposition == .research, interpretation.input.continues(original),
              evidence.document == page.document, evidence.documentID == page.documentID,
              try ComputerUseBrowserObservedCriteria.metadataDigest(controlIDs: ids, page: page.page)
                == ComputerUseBrowserObservedCriteria.metadataDigest(controlIDs: ids, page: evidence.page) else {
            throw ComputerUseBrowserActionPlanError.inputChanged
        }
    }

    func preservation(in interpretation: ComputerUseBrowserGoalProposal) throws -> [ComputerUseBrowserControlPreservation] {
        guard interpretation.disposition == .research, interpretation.input.continues(original) else { throw ComputerUseBrowserActionPlanError.inputChanged }
        return try preservedSources.map { item in
            guard let index = try item.source.indices(in: interpretation).first(where: {
                [.outcome, .condition, .prohibition].contains(interpretation.requirements[$0].role)
            }) else { throw ComputerUseBrowserActionPlanError.inputChanged }
            return .init(controlID: item.controlID, requirementIndex: index)
        }
    }

    func readings(in interpretation: ComputerUseBrowserGoalProposal) throws -> [ComputerUseBrowserControlRead] {
        guard interpretation.disposition == .research, interpretation.input.continues(original) else { throw ComputerUseBrowserActionPlanError.inputChanged }
        return try readSources.map { item in
            guard let index = try item.source.indices(in: interpretation).first(where: {
                ComputerUseBrowserControlRead.accepts(interpretation.requirements[$0])
            }) else { throw ComputerUseBrowserActionPlanError.inputChanged }
            return .init(controlID: item.controlID, requirementIndex: index)
        }
    }

    func context(in interpretation: ComputerUseBrowserGoalProposal) throws -> [String: Any] {
        guard interpretation.disposition == .research, interpretation.input.continues(original) else { throw ComputerUseBrowserActionPlanError.inputChanged }
        return ["form":formID, "executed":false,
         "preservation_sources":try preservedSources.map { ["control":$0.controlID,"source":try $0.source.context(in: interpretation)] as [String: Any] },
         "previous_read_sources":try readSources.map { ["control":$0.controlID,"source":try $0.source.context(in: interpretation)] as [String: Any] },
         "previous_field_intents":try fieldPurposes.map {
             ["control":$0.controlID,"disposition":$0.disposition.rawValue,"sources":try $0.sources.map { try $0.context(in: interpretation) }] as [String: Any]
         }]
    }
}

/// Retained before the first private read. Cancellation can stop the waiter,
/// but cannot replace this intent, its captured values or its native adapter.
@MainActor
final class ComputerUseBrowserResearchFormPreparation {
    let interpretation: ComputerUseBrowserGoalProposal
    let page: ComputerUseBrowserPageEvidence
    let review: ComputerUseBrowserEffectScopeReview
    let formID: String
    let target: ComputerUseBrowserTextTarget
    let reviewContext: ComputerUseBrowserFormPreparationReviewContext
    private(set) var revisedAction: ComputerUseBrowserActionProposal?
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
        reviewContext = try .init(interpretation: interpretation, page: page, review: review, previous: previous)
        target = prior?.target ?? .init(browser: browser, document: page.document, requiresFrontmost: browser.isFrontmostWindow)
        fieldsCapture = try .init(command: prior == nil ? .formFields : .extendFormFields, document: page.document)
        bindingCapture = try .init(command: .bindPageFields, document: page.document)
        preservationCapture = try .init(command: .prepareFormPreservation, document: page.document)
    }

    func restoreForReview(browser: ComputerUseOwnedBrowser, checkCurrent: () throws -> Void) async throws -> ComputerUseBrowserPageEvidence {
        func check() throws {
            try checkCurrent()
            if let parent, let previous { try parent.validatePreparationContinuation(previous) }
        }
        do {
            return try await ComputerUseBrowserResearchFormStage.restoreOriginalPage(page, review: review, browser: browser, checkCurrent: check)
        } catch {
            await browser.joinDOMCompletion(document: page.document)
            throw error
        }
    }

    func retainRevisedAction(_ action: ComputerUseBrowserActionProposal) throws {
        guard action.input.preparationReview == reviewContext,
              case .editForm(let id) = action.step, id == formID else { throw ComputerUseBrowserActionPlanError.invalidProposal }
        try reviewContext.validate(interpretation: action.input.interpretation, evidence: action.input.evidence)
        let fresh = try ComputerUseBrowserEffectScopeReview(input: action.input)
        let required = try reviewContext.preservation(in: action.input.interpretation)
        guard fresh.formScope?.formID == formID, required.allSatisfy({ fresh.formScope?.preservedControls.contains($0) == true }) else {
            throw ComputerUseBrowserActionPlanError.invalidProposal
        }
        revisedAction = action
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
                evidence = try bound.retainingOriginalPage(page)
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

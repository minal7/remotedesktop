import Foundation

/// Historical and subsequently reviewed purposes for retained preparation. Native
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
         review: ComputerUseBrowserEffectScopeReview, previous: ComputerUseBrowserResearchFormContinuation?, retaining original: Self? = nil) throws {
        guard review.matches(interpretation: interpretation, evidence: page), let scope = review.formScope, let formID = scope.formID else {
            throw ComputerUseBrowserActionPlanError.invalidInput
        }
        if let previous {
            guard interpretation.input.continues(previous.goal), previous.document == page.document,
                  previous.documentID == page.documentID, previous.formID == formID else { throw ComputerUseBrowserActionPlanError.inputChanged }
        }
        try original?.validate(interpretation: interpretation, evidence: page)
        var sources = original?.preservedSources ?? []
        for item in previous?.preservedControls ?? [] {
            if let old = sources.first(where: { $0.controlID == item.controlID }) {
                guard old.source == item.source else { throw ComputerUseBrowserActionPlanError.inputChanged }
            } else { sources.append(item) }
        }
        for item in scope.preservedControls {
            if let old = sources.first(where: { $0.controlID == item.controlID }) {
                guard try old.source.indices(in: interpretation).contains(item.requirementIndex) else { throw ComputerUseBrowserActionPlanError.inputChanged }
            } else {
                sources.append(.init(controlID: item.controlID, source: try .init(index: item.requirementIndex, interpretation: interpretation)))
            }
        }
        guard Set(sources.map(\.controlID)) == Set(scope.preservedControls.map(\.controlID)) else { throw ComputerUseBrowserActionPlanError.inputChanged }
        preservedSources = sources
        var reads = original?.readSources ?? []
        for item in review.readControls {
            if let old = reads.first(where: { $0.controlID == item.controlID }) {
                guard try old.source.indices(in: interpretation).contains(item.requirementIndex) else { throw ComputerUseBrowserActionPlanError.inputChanged }
            } else { reads.append(.init(controlID: item.controlID, source: try .init(index: item.requirementIndex, interpretation: interpretation))) }
        }
        guard Set(reads.map(\.controlID)) == Set(review.readControls.map(\.controlID)) else { throw ComputerUseBrowserActionPlanError.inputChanged }
        readSources = reads
        fieldPurposes = try scope.fieldIntents.map { intent in
            .init(controlID: intent.controlID, disposition: intent.disposition,
                sources: try intent.requirementIndices.map { try .init(index: $0, interpretation: interpretation) })
        }
        self.formID = formID; self.original = interpretation.input; self.page = page
        digest = ComputerUseTaskContract.digest(["browser-form-preparation-review-v2", interpretation.input.digest,
            page.document.contextID, String(page.document.generation), page.documentID, page.page.id, review.digest, previous?.digest ?? "", original?.digest ?? ""])
    }

    private init(formID: String, preservedSources: [ComputerUseBrowserFormPreservationSource],
                 readSources: [ComputerUseBrowserFormPreservationSource], fieldPurposes: [FieldPurpose],
                 original: ComputerUseBrowserGoalInput, page: ComputerUseBrowserPageEvidence, digest: String) {
        self.formID = formID; self.preservedSources = preservedSources; self.readSources = readSources; self.fieldPurposes = fieldPurposes
        self.original = original; self.page = page; self.digest = digest
    }

    /// Retain a validated semantic duty before another await. This records
    /// no value observation and cannot turn an unfinished review into an edit.
    func retainingPreservation(from action: ComputerUseBrowserActionProposal) throws -> Self {
        switch action.step {
        case .preserveControls, .editForm: break
        default: return self
        }
        guard action.input.preparationReview == self, action.input.formEffectScope?.formID == formID else {
            throw ComputerUseBrowserActionPlanError.inputChanged
        }
        try action.validate(for: action.input)
        let interpretation = action.input.interpretation, evidence = action.input.evidence
        try validate(interpretation: interpretation, evidence: evidence)
        var sources = preservedSources
        for item in action.preservedControls {
            if let original = sources.first(where: { $0.controlID == item.controlID }) {
                guard try original.source.indices(in: interpretation).contains(item.requirementIndex) else {
                    throw ComputerUseBrowserActionPlanError.inputChanged
                }
            } else {
                let source = try ComputerUseBrowserFormSource(index: item.requirementIndex, interpretation: interpretation)
                guard [.outcome, .condition, .prohibition].contains(source.role) else { throw ComputerUseBrowserActionPlanError.invalidProposal }
                sources.append(.init(controlID: item.controlID, source: source))
            }
        }
        guard sources.count <= 16 else { throw ComputerUseBrowserActionPlanError.invalidProposal }
        guard sources != preservedSources else { return self }
        let ids = Array(Set(sources.map(\.controlID) + readSources.map(\.controlID) + fieldPurposes.map(\.controlID))).sorted()
        let metadata = try ComputerUseBrowserObservedCriteria.metadataDigest(controlIDs: ids, page: evidence.page)
        let data = try JSONSerialization.data(withJSONObject: sources.map {
            ["control":$0.controlID,"source":try $0.source.context(in: interpretation)] as [String: Any]
        }, options: [.sortedKeys])
        return .init(formID: formID, preservedSources: sources, readSources: readSources, fieldPurposes: fieldPurposes,
            original: interpretation.input, page: evidence,
            digest: ComputerUseTaskContract.digest(["browser-partial-preservation-review-v1",digest,interpretation.input.digest,
                metadata,String(decoding: data, as: UTF8.self)]))
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

/// A sealed historical baseline for a revised input. It supplies no editable
/// alias or receipt authority. Values remain private, and every original
/// field must survive a fresh native binding before the input can be planned.
struct ComputerUseBrowserFormPreparationBaseline: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let evidence: ComputerUseBrowserFormEvidence
    private let goal: ComputerUseBrowserGoalInput
    private let previous: ComputerUseBrowserResearchFormContinuation?
    let reviewContext: ComputerUseBrowserFormPreparationReviewContext
    private let obligationsContext: ComputerUseBrowserFormPreparationReviewContext
    private let ignoresCapturedCaret: Bool
    var preservedSources: [ComputerUseBrowserFormPreservationSource] { obligationsContext.preservedSources }
    let digest: String
    var capturedControlIDs: Set<String> { Set(evidence.fields.map { $0.control.id }) }
    var capturedTargetIDs: Set<String> { Set(evidence.fields.map { $0.editable.snapshot.targetID }) }
    var description: String { "BrowserFormPreparationBaseline" }
    var debugDescription: String { description }

    @MainActor fileprivate init(input: ComputerUseBrowserResearchFormInput, target: ComputerUseBrowserTextTarget,
                               reviewContext: ComputerUseBrowserFormPreparationReviewContext,
                               retaining obligations: ComputerUseBrowserFormPreparationReviewContext,
                               interpretation: ComputerUseBrowserGoalProposal) throws {
        try reviewContext.validate(interpretation: input.interpretation, evidence: input.evidence.page)
        try obligations.validate(interpretation: interpretation, evidence: input.evidence.page)
        guard interpretation.input.continues(input.interpretation.input) else { throw ComputerUseBrowserResearchFormError.inputChanged }
        let requirements = try target.preparedFormRequirements(from: input)
        evidence = input.evidence; goal = input.interpretation.input; previous = input.previous; self.reviewContext = reviewContext
        obligationsContext = obligations; ignoresCapturedCaret = input.isRetainOnly
        digest = ComputerUseTaskContract.digest([input.isRetainOnly ? "browser-form-preparation-baseline-v3" : "browser-form-preparation-baseline-v2", requirements.digest, reviewContext.digest, obligations.digest])
    }

    func validate(interpretation: ComputerUseBrowserGoalProposal, evidence: ComputerUseBrowserFormEvidence,
                  formID: String?, review: ComputerUseBrowserEffectScopeReview?, previous: ComputerUseBrowserResearchFormContinuation?) throws {
        guard interpretation.input.continues(goal), evidence.retainsCapturedFields(from: self.evidence, ignoringCaret: ignoresCapturedCaret),
              formID == reviewContext.formID, previous == self.previous, let review,
              review.matches(interpretation: interpretation, evidence: evidence.page) else { throw ComputerUseBrowserResearchFormError.inputChanged }
        try reviewContext.validate(interpretation: interpretation, evidence: evidence.page)
        try obligationsContext.validate(interpretation: interpretation, evidence: evidence.page)
        let preserved = try obligationsContext.preservation(in: interpretation), reads = try obligationsContext.readings(in: interpretation)
        guard preserved.allSatisfy({ review.formScope?.preservedControls.contains($0) == true }),
              reads.allSatisfy({ review.readControls.contains($0) }) else { throw ComputerUseBrowserResearchFormError.inputChanged }
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
    private let preparedReviewContext: ComputerUseBrowserFormPreparationReviewContext
    private(set) var reviewContext: ComputerUseBrowserFormPreparationReviewContext
    private(set) var revisedAction: ComputerUseBrowserActionProposal?
    private let parent: (any ComputerUseBrowserFormStage)?
    private let previous: ComputerUseBrowserResearchFormContinuation?
    private let originalPreparation: ComputerUseBrowserResearchFormPreparation?
    private let revisionDepth: Int
    private var baseline: ComputerUseBrowserFormPreparationBaseline?
    private let fieldsCapture: ComputerUseBrowserDOMReadCapture
    private let bindingCapture: ComputerUseBrowserDOMReadCapture
    private let preservationCapture: ComputerUseBrowserDOMReadCapture
    private var fields: [ComputerUseTextField]?
    private var evidence: ComputerUseBrowserFormEvidence?
    private var preservation: ComputerUseBrowserFormPreservation?
    private var preservationFinished = false
    private(set) var preparedInput: ComputerUseBrowserResearchFormInput?
    var hasPreservationObligations: Bool {
        originalPreparation != nil || previous != nil || !reviewContext.preservedSources.isEmpty || !reviewContext.readSources.isEmpty
    }

    init(action: ComputerUseBrowserActionProposal, browser: ComputerUseOwnedBrowser, parent: (any ComputerUseBrowserFormStage)? = nil,
         revising original: ComputerUseBrowserResearchFormPreparation? = nil) throws {
        guard case .editForm(let formID) = action.step else { throw ComputerUseBrowserActionPlanError.invalidProposal }
        let review = try ComputerUseBrowserEffectScopeReview(input: action.input)
        guard review.formScope?.formID == formID, review.formScope?.preservedControls == action.preservedControls else {
            throw ComputerUseBrowserActionPlanError.invalidProposal
        }
        interpretation = action.input.interpretation; page = action.input.evidence; self.formID = formID; self.review = review
        if let original {
            guard parent == nil, original.revisedAction == action, action.input.preparationReview == original.reviewContext,
                  original.revisionDepth < 32, interpretation.input.continues(original.interpretation.input),
                  formID == original.formID else { throw ComputerUseBrowserActionPlanError.invalidProposal }
            self.parent = original.parent; previous = original.previous; target = original.target
            revisionDepth = original.revisionDepth + 1
        } else {
            let prior = try parent?.preparationContext(for: action)
            self.parent = parent; previous = prior?.continuation
            target = prior?.target ?? .init(browser: browser, document: page.document, requiresFrontmost: browser.isFrontmostWindow)
            revisionDepth = 0
        }
        originalPreparation = original
        let preparedContext = try ComputerUseBrowserFormPreparationReviewContext(interpretation: interpretation, page: page,
            review: review, previous: previous, retaining: original?.reviewContext)
        preparedReviewContext = preparedContext; reviewContext = preparedContext
        fieldsCapture = try .init(command: original != nil ? .reviseFormFields : (previous == nil ? .formFields : .extendFormFields), document: page.document)
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

    func retainReviewObligations(from action: ComputerUseBrowserActionProposal) throws {
        let retained = try reviewContext.retainingPreservation(from: action)
        if retained != reviewContext {
            reviewContext = retained
            revisedAction = nil
        }
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
            if let originalPreparation, baseline == nil {
                // Finish any interrupted original capture before extending its
                // catalogue. Once retained here, never rerun that old full-field
                // preparation against the larger revised adapter.
                let original = try await originalPreparation.prepare(browser: browser, checkCurrent: check)
                baseline = try .init(input: original, target: target, reviewContext: originalPreparation.preparedReviewContext,
                    retaining: originalPreparation.reviewContext, interpretation: interpretation)
                try check()
            }
            let current = try await ComputerUseBrowserResearchFormStage.restoreOriginalPage(page, review: review,
                browser: browser, checkCurrent: check)
            guard let scope = review.formScope else { throw ComputerUseBrowserResearchFormError.inputChanged }
            if fields == nil {
                if originalPreparation != nil {
                    guard baseline != nil, let original = originalPreparation?.preparedInput else { throw ComputerUseBrowserResearchFormError.inputChanged }
                    fields = try await target.reviseFields(in: formID, page: current, preserving: scope.editablePreservedControlIDs,
                        selecting: scope.selectedControlIDs, scopeDigest: scope.digest, from: original, retaining: fieldsCapture)
                } else if let previous {
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
                let bound: ComputerUseBrowserFormEvidence
                if let previous, review.permitsReadOnlyRetention(after: previous, on: current) {
                    bound = try await target.bindRetainedFields(fields, to: current, review: review, after: previous, retaining: bindingCapture)
                } else { bound = try await target.bindFields(fields, to: current, retaining: bindingCapture) }
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
                scopeReview: review, nativePreservation: preservation, preparationBaseline: baseline)
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

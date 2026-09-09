import Foundation

/// Unused historical purposes, never a field binding, baseline or receipt.
/// Old public labels are page data and cannot identify controls on a new page.
struct ComputerUseBrowserUnobservedFormIntent: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let maximumCount = 32
    struct Purpose: Equatable, Sendable {
        let label: String
        let kind: String
        let disposition: ComputerUseBrowserFormEffectScope.FieldIntent.Disposition
        let sources: [ComputerUseBrowserFormSource]
    }
    let index: Int
    private let goal: ComputerUseBrowserGoalInput
    private let retiredAtGoal: ComputerUseBrowserGoalInput
    private let sessionIdentity: String
    private let purposes: [Purpose]

    @MainActor
    init(preparation: ComputerUseBrowserResearchFormPreparation, index: Int,
         goal: ComputerUseBrowserGoalInput, page: ComputerUseBrowserPageEvidence) throws {
        guard (0..<Self.maximumCount).contains(index), preparation.canRetireUnobservedInitialIntent,
              goal.continues(preparation.interpretation.input), page.document.taskID == goal.taskID,
              page.document.contextID == preparation.page.document.contextID,
              page.documentID != preparation.page.documentID else { throw ComputerUseBrowserActionPlanError.inputChanged }
        self.index = index; self.goal = preparation.interpretation.input; retiredAtGoal = goal
        sessionIdentity = page.document.contextID
        purposes = try preparation.reviewContext.fieldPurposes.map { purpose in
            guard let control = preparation.page.page.controls.first(where: { $0.id == purpose.controlID }) else {
                throw ComputerUseBrowserActionPlanError.inputChanged
            }
            return .init(label: control.label, kind: control.kind, disposition: purpose.disposition, sources: purpose.sources)
        }
    }

    func context(interpretation: ComputerUseBrowserGoalProposal, evidence: ComputerUseBrowserPageEvidence) throws -> [String: Any] {
        guard interpretation.input.continues(goal), interpretation.input.continues(retiredAtGoal),
              evidence.document.contextID == sessionIdentity else { throw ComputerUseBrowserActionPlanError.invalidInput }
        return ["intent":index, "retired_after_handback":true, "values_observed":false, "input_dispatched":false,
            "current_field_verification":false, "purposes":try purposes.map { purpose -> [String: Any] in
                ["historical_label":purpose.label, "historical_kind":purpose.kind, "disposition":purpose.disposition.rawValue,
                 "sources":try purpose.sources.map { source -> [String: Any] in
                    ["turn":source.turn, "sourceByteOffset":source.offset, "source":source.source,
                     "role_at_preparation":source.role.rawValue, "field_at_preparation":source.field.rawValue,
                     "requirements":try source.indices(in: interpretation)]
                 }]
            }]
    }
    var description: String { "BrowserUnobservedFormIntent(index: \(index))" }
    var debugDescription: String { description }
}

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
    let requiredEditControlIDs: Set<String>
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
        self.formID = formID; self.original = interpretation.input; self.page = page; requiredEditControlIDs = []
        digest = ComputerUseTaskContract.digest(["browser-form-preparation-review-v2", interpretation.input.digest,
            page.document.contextID, String(page.document.generation), page.documentID, page.page.id, review.digest, previous?.digest ?? "", original?.digest ?? ""])
    }

    private init(formID: String, preservedSources: [ComputerUseBrowserFormPreservationSource],
                 readSources: [ComputerUseBrowserFormPreservationSource], fieldPurposes: [FieldPurpose],
                 requiredEditControlIDs: Set<String>, original: ComputerUseBrowserGoalInput, page: ComputerUseBrowserPageEvidence, digest: String) {
        self.formID = formID; self.preservedSources = preservedSources; self.readSources = readSources; self.fieldPurposes = fieldPurposes
        self.original = original; self.page = page; self.digest = digest
        self.requiredEditControlIDs = requiredEditControlIDs
    }

    func requiringFreshEdits(_ controlIDs: Set<String>) throws -> Self {
        let required = requiredEditControlIDs.union(controlIDs)
        guard required.isSubset(of: Set(fieldPurposes.map(\.controlID))),
              required.isDisjoint(with: preservedSources.map(\.controlID)),
              required.isDisjoint(with: readSources.map(\.controlID)) else {
            throw ComputerUseBrowserActionPlanError.inputChanged
        }
        guard required != requiredEditControlIDs else { return self }
        return .init(formID: formID, preservedSources: preservedSources, readSources: readSources, fieldPurposes: fieldPurposes,
            requiredEditControlIDs: required, original: original, page: page,
            digest: ComputerUseTaskContract.digest(["browser-preparation-fresh-edit-review-v1",digest] + required.sorted()))
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
            requiredEditControlIDs: requiredEditControlIDs, original: interpretation.input, page: evidence,
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
        var context: [String: Any] = ["form":formID, "executed":false,
         "preservation_sources":try preservedSources.map { ["control":$0.controlID,"source":try $0.source.context(in: interpretation)] as [String: Any] },
         "previous_read_sources":try readSources.map { ["control":$0.controlID,"source":try $0.source.context(in: interpretation)] as [String: Any] },
         "previous_field_intents":try fieldPurposes.map {
             ["control":$0.controlID,"disposition":$0.disposition.rawValue,"sources":try $0.sources.map { try $0.context(in: interpretation) }] as [String: Any]
         }]
        if !requiredEditControlIDs.isEmpty { context["required_edit_controls"] = requiredEditControlIDs.sorted() }
        return context
    }
}

/// Private observations can outlive an interrupted preparation without ever
/// having constituted a valid planner input. This type exposes no edit aliases.
struct ComputerUseBrowserFormPreparationCapture: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let interpretation: ComputerUseBrowserGoalProposal
    let evidence: ComputerUseBrowserFormEvidence
    let selectedFormID: String?
    let previous: ComputerUseBrowserResearchFormContinuation?
    let scopeReview: ComputerUseBrowserEffectScopeReview?
    let nativePreservation: ComputerUseBrowserFormPreservation?
    let preparationBaseline: ComputerUseBrowserFormPreparationBaseline?
    let isRetainOnly: Bool
    let wasPreparedInput: Bool
    var description: String { "BrowserFormPreparationCapture" }
    var debugDescription: String { description }

    init(input: ComputerUseBrowserResearchFormInput) {
        interpretation = input.interpretation; evidence = input.evidence; selectedFormID = input.selectedFormID
        previous = input.previous; scopeReview = input.scopeReview; nativePreservation = input.nativePreservation
        preparationBaseline = input.preparationBaseline; isRetainOnly = input.isRetainOnly; wasPreparedInput = true
    }

    fileprivate init(interpretation: ComputerUseBrowserGoalProposal, evidence: ComputerUseBrowserFormEvidence,
                     formID: String, review: ComputerUseBrowserEffectScopeReview,
                     previous: ComputerUseBrowserResearchFormContinuation?,
                     preservation: ComputerUseBrowserFormPreservation?, baseline: ComputerUseBrowserFormPreparationBaseline?) throws {
        guard review.matches(interpretation: interpretation, evidence: evidence.page),
              review.permitsPreparationRecovery(after: previous, on: evidence.page), let scope = review.formScope,
              scope.formID == formID, (1...16).contains(evidence.fields.count) else { throw ComputerUseBrowserResearchFormError.inputChanged }
        let targets = Set(evidence.fields.map { $0.editable.snapshot.targetID }), controls = Set(evidence.fields.map { $0.control.id })
        let inherited = Set(evidence.fields.filter { previous?.finalValues[$0.editable.snapshot.targetID] != nil }.map { $0.control.id })
        guard targets.count == evidence.fields.count, controls.count == evidence.fields.count,
              Set(previous?.finalValues.keys.map { $0 } ?? []).isSubset(of: targets),
              controls == Set(scope.discoveryControlIDs).union(inherited).union(baseline?.capturedControlIDs ?? []),
              scope.fieldIntents.filter({ $0.disposition == .retain }).allSatisfy({ intent in
                  evidence.fields.contains { $0.control.id == intent.controlID && previous?.verifiedTargetIDs.contains($0.editable.snapshot.targetID) == true }
              }), evidence.fields.allSatisfy({ field in
                  field.control.form?.id == formID || scope.preservedControls.contains { $0.controlID == field.control.id }
              }) else {
            throw ComputerUseBrowserResearchFormError.inputChanged
        }
        let nativeIDs = scope.nativePreservedControlIDs
        guard Set(previous?.nativePreservation?.controlIDs ?? []).isSubset(of: Set(nativeIDs)) else {
            throw ComputerUseBrowserResearchFormError.inputChanged
        }
        if let preservation {
            guard preservation.controlIDs == nativeIDs, preservation.scopeDigest == scope.digest,
                  preservation.document == evidence.page.document, preservation.documentID == evidence.page.documentID else {
                throw ComputerUseBrowserResearchFormError.inputChanged
            }
        } else if !nativeIDs.isEmpty || previous?.nativePreservation != nil { throw ComputerUseBrowserResearchFormError.inputChanged }
        try baseline?.validate(interpretation: interpretation, evidence: evidence, formID: formID, review: review, previous: previous)
        self.interpretation = interpretation; self.evidence = evidence; selectedFormID = formID; scopeReview = review
        self.previous = previous; nativePreservation = preservation; preparationBaseline = baseline
        isRetainOnly = previous.map { review.permitsReadOnlyRetention(after: $0, on: evidence.page) } ?? false; wasPreparedInput = false
    }

    var capturedCriterionChanges: Set<String> {
        Set(evidence.fields.compactMap { field in
            let id = field.editable.snapshot.targetID
            guard let value = previous?.finalValues[id], !value.utf8.elementsEqual(field.editable.snapshot.value.utf8) else { return nil }
            return id
        })
    }

    /// Only a newly captured, explicitly editable field may receive a fresh
    /// baseline. Earlier invariants, verified criteria and scoped reads keep
    /// their own provenance and cannot enter this set.
    var refreshableTargetIDs: Set<String> {
        guard !isRetainOnly, let review = scopeReview, let scope = review.formScope else { return [] }
        let readIDs = Set(review.readControls.map(\.controlID))
        let editIDs = Set(scope.fieldIntents.filter { $0.disposition == .edit }.map(\.controlID)).subtracting(readIDs)
        return Set(evidence.fields.filter { editIDs.contains($0.control.id)
            && previous?.finalValues[$0.editable.snapshot.targetID] == nil }.map { $0.editable.snapshot.targetID })
    }
}

/// A read-only recovery observation, never a proposal, receipt or new origin.
/// Only this file can seal it after inspecting the original native history.
struct ComputerUseBrowserFormPreparationRepair: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let original: ComputerUseBrowserFormPreparationCapture
    let changedTargetIDs: Set<String>
    let refreshedTargetIDs: Set<String>
    var revisedTargetIDs: Set<String> { changedTargetIDs.union(refreshedTargetIDs) }
    let digest: String
    var description: String { "BrowserFormPreparationRepair" }
    var debugDescription: String { description }

    @MainActor fileprivate init(original: ComputerUseBrowserFormPreparationCapture, changed: Set<String>, refreshed: Set<String>, target: ComputerUseBrowserTextTarget) throws {
        let previous = original.previous
        guard previous?.pendingEdits.isEmpty ?? true,
              original.scopeReview?.permitsPreparationRecovery(after: previous, on: original.evidence.page) == true,
              !changed.isEmpty || !refreshed.isEmpty,
              changed.isSubset(of: previous?.repairableTargetIDs ?? []), refreshed.isSubset(of: original.refreshableTargetIDs),
              original.capturedCriterionChanges.isSubset(of: changed),
              changed.isSubset(of: Set(original.evidence.fields.map { $0.editable.snapshot.targetID })) else {
            throw ComputerUseBrowserResearchFormError.inputChanged
        }
        self.original = original; changedTargetIDs = changed; refreshedTargetIDs = refreshed
        let version: String
        if previous == nil { version = "browser-initial-preparation-refresh-v1" }
        else if !refreshed.isEmpty { version = "browser-planned-preparation-refresh-v1" }
        else { version = original.isRetainOnly ? "browser-retained-preparation-repair-v1" : "browser-planned-preparation-repair-v1" }
        digest = ComputerUseTaskContract.digest([version,
            try target.preparedFormRequirements(from: original, repairingCriteria: !original.isRetainOnly, refreshingFields: !refreshed.isEmpty).digest,
            previous?.digest ?? ""] + changed.sorted() + (refreshed.isEmpty ? [] : ["refreshed-fields"] + refreshed.sorted()))
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
    private let captureReviewContext: ComputerUseBrowserFormPreparationReviewContext
    private let obligationsContext: ComputerUseBrowserFormPreparationReviewContext
    private let ignoresCapturedCaret: Bool
    private let repairableTargetIDs: Set<String>
    let refreshedTargetIDs: Set<String>
    var preservedSources: [ComputerUseBrowserFormPreservationSource] { obligationsContext.preservedSources }
    let digest: String
    var capturedControlIDs: Set<String> { Set(evidence.fields.map { $0.control.id }) }
    var capturedTargetIDs: Set<String> { Set(evidence.fields.map { $0.editable.snapshot.targetID }) }
    var description: String { "BrowserFormPreparationBaseline" }
    var debugDescription: String { description }

    @MainActor fileprivate init(input: ComputerUseBrowserFormPreparationCapture, target: ComputerUseBrowserTextTarget,
                               reviewContext: ComputerUseBrowserFormPreparationReviewContext,
                               retaining obligations: ComputerUseBrowserFormPreparationReviewContext,
                               interpretation: ComputerUseBrowserGoalProposal,
                               repair: ComputerUseBrowserFormPreparationRepair? = nil,
                               captureReviewContext: ComputerUseBrowserFormPreparationReviewContext? = nil) throws {
        let capturedReview = captureReviewContext ?? reviewContext
        try capturedReview.validate(interpretation: input.interpretation, evidence: input.evidence.page)
        try reviewContext.validate(interpretation: interpretation, evidence: input.evidence.page)
        try obligations.validate(interpretation: interpretation, evidence: input.evidence.page)
        guard interpretation.input.continues(input.interpretation.input) else { throw ComputerUseBrowserResearchFormError.inputChanged }
        if let repair { guard repair.original == input else { throw ComputerUseBrowserResearchFormError.inputChanged } }
        let physicalRepair = repair != nil && !input.isRetainOnly
        let refreshing = repair?.refreshedTargetIDs.isEmpty == false
        let requirements = try target.preparedFormRequirements(from: input, repairingCriteria: physicalRepair, refreshingFields: refreshing)
        evidence = input.evidence; goal = input.interpretation.input; previous = input.previous; self.reviewContext = reviewContext
        self.captureReviewContext = capturedReview
        obligationsContext = obligations; ignoresCapturedCaret = input.isRetainOnly
        repairableTargetIDs = repair?.revisedTargetIDs ?? []
        refreshedTargetIDs = repair?.refreshedTargetIDs ?? []
        guard input.wasPreparedInput || repair != nil else { throw ComputerUseBrowserResearchFormError.inputChanged }
        let inherited = capturedReview != reviewContext
        let version: String
        if refreshing && input.previous == nil { version = "browser-form-preparation-baseline-v9" }
        else if refreshing { version = "browser-form-preparation-baseline-v8" }
        else if physicalRepair { version = "browser-form-preparation-baseline-v7" }
        else if inherited { version = "browser-form-preparation-baseline-v6" }
        else if !input.wasPreparedInput { version = "browser-form-preparation-baseline-v5" }
        else if repair != nil { version = "browser-form-preparation-baseline-v4" }
        else { version = input.isRetainOnly ? "browser-form-preparation-baseline-v3" : "browser-form-preparation-baseline-v2" }
        let parts = [version, requirements.digest, reviewContext.digest, obligations.digest]
        digest = ComputerUseTaskContract.digest(parts + (repair.map { [$0.digest] } ?? []) + (inherited ? [capturedReview.digest] : []))
    }

    func validate(interpretation: ComputerUseBrowserGoalProposal, evidence: ComputerUseBrowserFormEvidence,
                  formID: String?, review: ComputerUseBrowserEffectScopeReview?, previous: ComputerUseBrowserResearchFormContinuation?) throws {
        guard interpretation.input.continues(goal), evidence.retainsCapturedFields(from: self.evidence,
                ignoringCaret: ignoresCapturedCaret, repairing: repairableTargetIDs),
              formID == reviewContext.formID, previous == self.previous, let review,
              review.matches(interpretation: interpretation, evidence: evidence.page) else { throw ComputerUseBrowserResearchFormError.inputChanged }
        try reviewContext.validate(interpretation: interpretation, evidence: evidence.page)
        try captureReviewContext.validate(interpretation: interpretation, evidence: evidence.page)
        try obligationsContext.validate(interpretation: interpretation, evidence: evidence.page)
        let preserved = try obligationsContext.preservation(in: interpretation), reads = try obligationsContext.readings(in: interpretation)
        guard preserved.allSatisfy({ review.formScope?.preservedControls.contains($0) == true }),
              reads.allSatisfy({ review.readControls.contains($0) }) else { throw ComputerUseBrowserResearchFormError.inputChanged }
        let editIDs = Set(review.formScope?.fieldIntents.filter { $0.disposition == .edit }.map(\.controlID) ?? [])
        guard evidence.fields.filter({ refreshedTargetIDs.contains($0.editable.snapshot.targetID) })
            .allSatisfy({ editIDs.contains($0.control.id) }) else { throw ComputerUseBrowserResearchFormError.inputChanged }
    }
}

/// Retained before the first private read. Cancellation can stop the waiter,
/// but cannot replace this intent, its captured values or its native adapter.
@MainActor
final class ComputerUseBrowserResearchFormPreparation {
    private struct CaptureOrigin: Equatable {
        let capture: ComputerUseBrowserFormPreparationCapture
        let reviewContext: ComputerUseBrowserFormPreparationReviewContext
        let repair: ComputerUseBrowserFormPreparationRepair?
    }
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
    private var baselineOrigin: CaptureOrigin?
    private var inheritedCriteriaOrigin: CaptureOrigin?
    private let fieldsCapture: ComputerUseBrowserDOMReadCapture
    private let bindingCapture: ComputerUseBrowserDOMReadCapture
    private let preservationCapture: ComputerUseBrowserDOMReadCapture
    private var fields: [ComputerUseTextField]?
    private var evidence: ComputerUseBrowserFormEvidence?
    private var preservation: ComputerUseBrowserFormPreservation?
    private var preservationFinished = false
    private(set) var preparedInput: ComputerUseBrowserResearchFormInput?
    private(set) var criteriaRepair: ComputerUseBrowserFormPreparationRepair?
    private var criteriaRepairCount = 0
    private var isReadOnlyRetention: Bool {
        previous.map { review.permitsReadOnlyRetention(after: $0, on: page) } ?? false
    }
    private var permitsOwnCriteriaRecovery: Bool {
        review.permitsPreparationRecovery(after: previous, on: page)
    }
    private var hasStartedCapture: Bool {
        fieldsCapture.didStart || bindingCapture.didStart || preservationCapture.didStart
            || fields != nil || evidence != nil || preservationFinished || preparedInput != nil
    }
    private var hasUncapturedRevision: Bool {
        originalPreparation != nil && baselineOrigin != nil && target.revisionWasNotCaptured(fieldsCapture)
            && !bindingCapture.didStart && !preservationCapture.didStart
            && fields == nil && evidence == nil && !preservationFinished && preparedInput == nil
    }
    private var canRecoverEarlierCapture: Bool { !hasStartedCapture || hasUncapturedRevision }
    var needsCriteriaReview: Bool { criteriaRepair != nil || inheritedCriteriaOrigin != nil }
    var permitsCriteriaRecovery: Bool {
        permitsOwnCriteriaRecovery || (canRecoverEarlierCapture && originalPreparation?.permitsCriteriaRecovery == true)
    }
    var hasPreservationObligations: Bool {
        originalPreparation != nil || previous != nil || !reviewContext.preservedSources.isEmpty || !reviewContext.readSources.isEmpty
    }

    /// This is absence of observation/effect, not recovery of a captured
    /// baseline. The owner must separately prove explicit handback to a new
    /// document and retain the unused purposes before releasing this frame.
    var canRetireUnobservedInitialIntent: Bool {
        parent == nil && previous == nil && originalPreparation == nil && revisionDepth == 0
            && baseline == nil && baselineOrigin == nil && inheritedCriteriaOrigin == nil
            && criteriaRepair == nil && revisedAction == nil && criteriaRepairCount == 0
            && reviewContext == preparedReviewContext && !hasPreservationObligations
            && !reviewContext.fieldPurposes.contains(where: { $0.disposition == .retain })
            && fields == nil && evidence == nil && preservation == nil && !preservationFinished && preparedInput == nil
            && fieldsCapture.initialFieldsWereNotObserved && !bindingCapture.didStart && !preservationCapture.didStart
            && target.hasNoCapturedFields && !page.page.controlStateObserved
            && page.page.controlStates.isEmpty && page.page.scopedControlIDs.isEmpty
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
        let edits = Set(fresh.formScope?.fieldIntents.filter { $0.disposition == .edit }.map(\.controlID) ?? [])
        guard fresh.formScope?.formID == formID, required.allSatisfy({ fresh.formScope?.preservedControls.contains($0) == true }),
              reviewContext.requiredEditControlIDs.isSubset(of: edits) else {
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

    /// Finish the original private capture without manufacturing a planner
    /// input or preceding stage, then request fresh review of changed fields.
    func recoverCriteriaForReview(browser: ComputerUseOwnedBrowser, checkCurrent: () throws -> Void) async throws -> Bool {
        guard criteriaRepairCount < 8, permitsCriteriaRecovery else { return false }
        // Keep every started callback. An explicit native pre-capture
        // rejection can inherit the earlier capture without retrying its ID.
        if !permitsOwnCriteriaRecovery || ((!isReadOnlyRetention || hasUncapturedRevision)
            && canRecoverEarlierCapture && originalPreparation?.permitsCriteriaRecovery == true) {
            return try await recoverInheritedCriteria(browser: browser, checkCurrent: checkCurrent)
        }
        func check() throws {
            try checkCurrent()
            if let parent, let previous { try parent.validatePreparationContinuation(previous) }
            if preservationFinished, preservation != target.formPreservation { throw ComputerUseBrowserResearchFormError.inputChanged }
            try browser.validateSourceDocument(page.document)
        }
        do {
            try check()
            let original: ComputerUseBrowserFormPreparationCapture
            if let input = preparedInput { original = .init(input: input) }
            else {
                try await captureFields(browser: browser, recoveringCriteria: true, checkCurrent: check)
                guard let evidence, preservationFinished else { throw ComputerUseBrowserResearchFormError.inputChanged }
                original = try .init(interpretation: interpretation, evidence: evidence, formID: formID, review: review,
                    previous: previous, preservation: preservation, baseline: baseline)
            }
            guard original.previous == previous, original.nativePreservation == target.formPreservation else {
                throw ComputerUseBrowserResearchFormError.inputChanged
            }
            let current = try await restoreForReview(browser: browser, checkCurrent: check)
            let bound = try await target.bindFieldsForCriteriaRepair(original.evidence.fields.map(\.editable), to: current,
                review: review, after: previous)
            try check()
            guard bound.evidence.fields == original.evidence.fields else { throw ComputerUseBrowserResearchFormError.inputChanged }
            let changed = bound.changedTargetIDs.union(original.capturedCriterionChanges)
            guard !changed.isEmpty || !bound.refreshedTargetIDs.isEmpty else { return false }
            let repair = try ComputerUseBrowserFormPreparationRepair(original: original, changed: changed,
                refreshed: bound.refreshedTargetIDs, target: target)
            guard repair != criteriaRepair else { return false }
            let refreshedControls = Set(original.evidence.fields.filter { repair.refreshedTargetIDs.contains($0.editable.snapshot.targetID) }.map { $0.control.id })
            let context = try reviewContext.requiringFreshEdits(refreshedControls)
            criteriaRepair = repair; criteriaRepairCount += 1
            reviewContext = context
            revisedAction = nil
            return true
        } catch {
            await browser.joinDOMCompletion(document: page.document)
            // Native history may have reconciled a failed callback as an
            // explicit pre-capture rejection during captureFields above.
            if hasUncapturedRevision {
                return try await recoverInheritedCriteria(browser: browser, checkCurrent: checkCurrent)
            }
            throw error
        }
    }

    func prepare(browser: ComputerUseOwnedBrowser, checkCurrent: () throws -> Void) async throws -> ComputerUseBrowserResearchFormInput {
        func check() throws {
            try checkCurrent()
            if let parent, let previous { try parent.validatePreparationContinuation(previous) }
        }
        do {
            try check()
            guard inheritedCriteriaOrigin == nil, !hasUncapturedRevision else { throw ComputerUseBrowserResearchFormError.inputChanged }
            if let preparedInput {
                try await ComputerUseBrowserResearchFormStage.validateOriginalInput(preparedInput, target: target,
                    browser: browser, checkCurrent: check)
                return preparedInput
            }
            try await captureFields(browser: browser, recoveringCriteria: false, checkCurrent: check)
            guard let evidence, let scope = review.formScope else { throw ComputerUseBrowserResearchFormError.invalidInput }
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

    /// An unstarted or provably uncaptured revision owns reviewed purposes
    /// but no new baseline. Keep that frame and any rejected callback forever.
    private func recoverInheritedCriteria(browser: ComputerUseOwnedBrowser, checkCurrent: () throws -> Void) async throws -> Bool {
        guard canRecoverEarlierCapture, let originalPreparation else { return false }
        func check() throws {
            try checkCurrent()
            guard canRecoverEarlierCapture else { throw ComputerUseBrowserResearchFormError.inputChanged }
            if let parent, let previous { try parent.validatePreparationContinuation(previous) }
        }
        do {
            try check()
            _ = try await restoreForReview(browser: browser, checkCurrent: check)
            _ = try await originalPreparation.recoverCriteriaForReview(browser: browser, checkCurrent: check)
            try check()
            guard originalPreparation.needsCriteriaReview else { return false }
            let origin = try await originalPreparation.captureOriginForRevision(browser: browser, for: page, checkCurrent: check)
            guard origin.repair != nil else { throw ComputerUseBrowserResearchFormError.inputChanged }
            _ = try await restoreForReview(browser: browser, checkCurrent: check)
            try check()
            guard inheritedCriteriaOrigin != origin else { return false }
            let refreshed = origin.repair?.refreshedTargetIDs ?? []
            let controls = Set(origin.capture.evidence.fields.filter { refreshed.contains($0.editable.snapshot.targetID) }.map { $0.control.id })
            let context = try reviewContext.requiringFreshEdits(controls)
            inheritedCriteriaOrigin = origin; criteriaRepairCount += 1; revisedAction = nil
            reviewContext = context
            return true
        } catch {
            await browser.joinDOMCompletion(document: page.document)
            throw error
        }
    }

    /// Traverse only retained, unstarted or proven uncaptured revisions. Restore every historical
    /// read scope and keep its semantic context; never prepare a skipped edit.
    private func captureOriginForRevision(browser: ComputerUseOwnedBrowser, for reviewedPage: ComputerUseBrowserPageEvidence,
                                          checkCurrent: () throws -> Void) async throws -> CaptureOrigin {
        try checkCurrent()
        try ComputerUseBrowserObservedCriteria.requireUnchanged(controlIDs: review.readControls.map(\.controlID),
            original: page, current: reviewedPage)
        if let inheritedCriteriaOrigin {
            guard canRecoverEarlierCapture, let originalPreparation else { throw ComputerUseBrowserResearchFormError.inputChanged }
            _ = try await restoreForReview(browser: browser, checkCurrent: checkCurrent)
            let original = try await originalPreparation.captureOriginForRevision(browser: browser, for: reviewedPage, checkCurrent: checkCurrent)
            try checkCurrent()
            guard original == inheritedCriteriaOrigin else { throw ComputerUseBrowserResearchFormError.inputChanged }
            return original
        }
        if let criteriaRepair {
            _ = try await restoreForReview(browser: browser, checkCurrent: checkCurrent)
            return .init(capture: criteriaRepair.original, reviewContext: preparedReviewContext, repair: criteriaRepair)
        }
        let input = try await prepare(browser: browser, checkCurrent: checkCurrent)
        return .init(capture: .init(input: input), reviewContext: preparedReviewContext, repair: nil)
    }

    private func captureFields(browser: ComputerUseOwnedBrowser, recoveringCriteria: Bool, checkCurrent: () throws -> Void) async throws {
        func check() throws { try checkCurrent() }
        try check()
        if let originalPreparation, baseline == nil {
            // Finish any interrupted original capture before extending its
            // catalogue. Once retained here, never rerun that old full-field
            // preparation against the larger revised adapter.
            if recoveringCriteria, !originalPreparation.needsCriteriaReview, originalPreparation.permitsCriteriaRecovery {
                _ = try await originalPreparation.recoverCriteriaForReview(browser: browser, checkCurrent: check)
            }
            let origin = try await originalPreparation.captureOriginForRevision(browser: browser, for: page, checkCurrent: check)
            baseline = try .init(input: origin.capture, target: target, reviewContext: originalPreparation.preparedReviewContext,
                retaining: originalPreparation.reviewContext, interpretation: interpretation, repair: origin.repair,
                captureReviewContext: origin.reviewContext)
            baselineOrigin = origin
            try check()
        }
        let current = try await ComputerUseBrowserResearchFormStage.restoreOriginalPage(page, review: review,
            browser: browser, checkCurrent: check)
        guard let scope = review.formScope else { throw ComputerUseBrowserResearchFormError.inputChanged }
        if fields == nil {
            if originalPreparation != nil {
                guard baseline != nil, let origin = baselineOrigin else {
                    throw ComputerUseBrowserResearchFormError.inputChanged
                }
                fields = try await target.reviseFields(in: formID, page: current, preserving: scope.editablePreservedControlIDs,
                    selecting: scope.selectedControlIDs, scopeDigest: scope.digest, from: origin.capture, retaining: fieldsCapture,
                    repairing: origin.repair)
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
            if recoveringCriteria, review.permitsPreparationRecovery(after: previous, on: current) {
                bound = try await target.bindFieldsForCriteriaRepair(fields, to: current, review: review, after: previous, retaining: bindingCapture).evidence
            } else if let previous, review.permitsReadOnlyRetention(after: previous, on: current) {
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
    }
}

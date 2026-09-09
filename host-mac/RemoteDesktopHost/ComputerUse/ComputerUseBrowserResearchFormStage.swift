import Foundation

/// An ordered set of historical stages on the same retained native form.
/// It describes what a query must still prove, not current satisfaction.
struct ComputerUseBrowserResearchFormContinuation: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let taskID: String
    let rootDigest: String
    let goalRevision: String
    let goal: ComputerUseBrowserGoalInput
    let document: ComputerUseBrowserDocument
    let documentID: String
    let formID: String?
    let stageIDs: [String]
    let finalValues: [String: String]
    let editedTargetIDs: Set<String>
    let inputOperationIDs: [String]
    let preservedControls: [ComputerUseBrowserFormPreservationSource]
    let nativePreservation: ComputerUseBrowserFormPreservation?
    let preservedTargetIDs: Set<String>
    let editedSources: [String: [ComputerUseBrowserFormSource]]
    let pendingEdits: [ComputerUseBrowserFormPendingEdit]
    var repairableTargetIDs: Set<String> { editedTargetIDs.subtracting(preservedTargetIDs) }
    let digest: String

    @MainActor fileprivate init(stage: ComputerUseBrowserResearchFormStage, current: ComputerUseTextTaskContinuation,
                               completedEditCount: Int? = nil) throws {
        let input = stage.input, previous = input.previous
        let count = completedEditCount ?? stage.proposal.edits.count
        guard (1...stage.proposal.edits.count).contains(count), current.inputOperationIDs.count == count,
              current.taskID == input.interpretation.input.taskID,
              current.contractDigest == stage.contract.contractDigest,
              previous == nil || (previous.map { input.interpretation.input.continues($0.goal) } == true
                && previous?.document == input.evidence.page.document && previous?.documentID == input.evidence.page.documentID
                && previous?.formID == input.selectedFormID) else { throw ComputerUseBrowserResearchFormStage.Failure.invalidStage }
        taskID = current.taskID; rootDigest = input.interpretation.input.rootDigest; goalRevision = input.interpretation.input.digest
        goal = input.interpretation.input
        document = input.evidence.page.document; documentID = input.evidence.page.documentID; formID = input.selectedFormID
        stageIDs = (previous?.stageIDs ?? []) + [stage.id]
        inputOperationIDs = (previous?.inputOperationIDs ?? []) + current.inputOperationIDs
        guard stageIDs.count <= 32, Set(stageIDs).count == stageIDs.count,
              (1...64).contains(inputOperationIDs.count), Set(inputOperationIDs).count == inputOperationIDs.count else {
            throw ComputerUseBrowserResearchFormStage.Failure.invalidStage
        }
        // Only a verified edit supersedes an earlier criterion. A future
        // suffix edit may have removed it from this contract's invariants;
        // retain that earlier intent until its replacement is verified.
        finalValues = (previous?.finalValues ?? [:]).merging(current.finalValues) { _, current in current }
        editedTargetIDs = (previous?.editedTargetIDs ?? []).union(current.editedTargetIDs)
        guard editedTargetIDs.isSubset(of: Set(finalValues.keys)),
              Set(previous?.finalValues.keys.map { $0 } ?? []).isSubset(of: Set(finalValues.keys)) else {
            throw ComputerUseBrowserResearchFormStage.Failure.invalidStage
        }
        preservedControls = try stage.proposal.preserved.map {
            .init(controlID: try input.field(for: $0.field).control.id, source: $0.source)
        } + input.nativePreservedSources
        nativePreservation = input.nativePreservation
        preservedTargetIDs = Set(try stage.proposal.preserved.map { try input.field(for: $0.field).editable.snapshot.targetID })
        var sources = previous?.editedSources ?? [:]
        for edit in stage.proposal.edits.prefix(count) {
            let targetID = try input.field(for: edit.field).editable.snapshot.targetID
            sources[targetID] = try stage.proposal.sources(for: edit)
        }
        editedSources = sources
        pendingEdits = try stage.proposal.edits.dropFirst(count).map { try stage.proposal.pendingEdit(for: $0) }
        digest = ComputerUseTaskContract.digest(["browser-research-form-continuation-v5", taskID, rootDigest, goalRevision,
            document.contextID, String(document.generation), documentID, formID ?? "", previous?.digest ?? "", current.digest]
            + [stage.contract.contractDigest, String(count)] + stageIDs + inputOperationIDs)
    }

    var description: String { "BrowserResearchFormContinuation(stages: \(stageIDs.count))" }
    var debugDescription: String { description }
}

/// Historical proof of one verified edit stage, never a current-page assertion
/// or a completed research answer. Construction stays with native execution.
struct ComputerUseBrowserResearchFormReceipt: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let taskID: String
    let rootDigest: String
    let goalRevision: String
    let stageID: String
    let index: Int
    let contractDigest: String
    let editCount: Int
    let plannedEditCount: Int
    var isCompleteStage: Bool { editCount == plannedEditCount }
    @MainActor fileprivate init(stage: ComputerUseBrowserResearchFormStage, completedEditCount: Int? = nil) {
        taskID = stage.input.interpretation.input.taskID; rootDigest = stage.input.interpretation.input.rootDigest
        goalRevision = stage.input.interpretation.input.digest
        stageID = stage.id; index = stage.index; contractDigest = stage.contract.contractDigest
        plannedEditCount = stage.contract.steps.count; editCount = completedEditCount ?? plannedEditCount
    }
    var description: String { "BrowserResearchFormReceipt(edits: \(editCount))" }
    var debugDescription: String { description }
}

/// One immutable, in-memory native binding with a durable per-step journal.
/// Reopening its store after a failed write never recreates its contract or
/// field objects. Lost browser/process state cannot be reconstructed from the
/// journal alone and remains an explicit recovery limitation.
@MainActor
final class ComputerUseBrowserResearchFormStage {
    enum Failure: Error, Equatable { case invalidStage, busy, retired, notVerified, retirementPending }
    struct Retirement: Equatable, Sendable {
        let stageID: String
        let index: Int
        let goalRevision: String
        let contractDigest: String
        let digest: String
        @MainActor fileprivate init(stage: ComputerUseBrowserResearchFormStage, digest: String) {
            stageID = stage.id; index = stage.index; goalRevision = stage.input.interpretation.input.digest
            contractDigest = stage.contract.contractDigest; self.digest = digest
        }
    }
    struct PrefixResolution: Equatable, Sendable {
        let retirement: Retirement
        let receipt: ComputerUseBrowserResearchFormReceipt
        fileprivate init(retirement: Retirement, receipt: ComputerUseBrowserResearchFormReceipt) {
            self.retirement = retirement; self.receipt = receipt
        }
    }
    let input: ComputerUseBrowserResearchFormInput
    let proposal: ComputerUseBrowserFormProposal
    let id: String
    let index: Int
    let contract: ComputerUseTextTaskContract
    private let browser: ComputerUseOwnedBrowser
    private let target: ComputerUseBrowserTextTarget
    private let directory: URL
    private let makeStore: (URL) throws -> ComputerUseTaskJournalStore
    private var completed: ComputerUseBrowserResearchFormReceipt?
    private var continuation: ComputerUseBrowserResearchFormContinuation?
    private var isExecuting = false
    private var isRetired = false
    private var retirementPending = false
    private var retirement: Retirement?
    private var observedNativeAttempt = false
    private(set) var nativePrefixResolution: PrefixResolution?
    var nativeReceipt: ComputerUseBrowserResearchFormReceipt? { completed }
    var nativeContinuation: ComputerUseBrowserResearchFormContinuation? { continuation }

    init(input: ComputerUseBrowserResearchFormInput, proposal: ComputerUseBrowserFormProposal,
         target: ComputerUseBrowserTextTarget, browser: ComputerUseOwnedBrowser, index: Int, sequence: Int? = nil, journalDirectory: URL,
         makeStore: @escaping (URL) throws -> ComputerUseTaskJournalStore = { try .init(directory: $0) }) throws {
        guard (0..<32).contains(index), (0..<64).contains(sequence ?? index) else { throw ComputerUseBrowserResearchFormError.stageLimit }
        guard input.nativePreservation == target.formPreservation else { throw ComputerUseBrowserResearchFormError.inputChanged }
        self.input = input; self.proposal = proposal; self.target = target; self.browser = browser; self.index = index
        id = ComputerUseTaskContract.digest(["browser-research-form-stage-v2", input.interpretation.input.taskID,
            input.interpretation.input.rootDigest, String(index), String(sequence ?? index)])
        guard let contract = try proposal.textContract(for: input, stageID: id) else { throw Failure.invalidStage }
        guard (input.previous?.inputOperationIDs.count ?? 0) + contract.steps.count <= 64 else { throw ComputerUseBrowserResearchFormError.stageLimit }
        self.contract = contract
        directory = journalDirectory.appendingPathComponent("Research Forms", isDirectory: true).appendingPathComponent(id, isDirectory: true)
        self.makeStore = makeStore
    }

    func run(checkCurrent: @escaping @MainActor () throws -> Void) async throws -> ComputerUseBrowserResearchFormReceipt {
        guard !isExecuting else { throw Failure.busy }
        isExecuting = true
        defer { isExecuting = false }
        func check() throws {
            try Task.checkCancellation()
            guard !isRetired else { throw Failure.retired }
            guard completed != nil || input.nativePreservation == target.formPreservation else { throw ComputerUseBrowserResearchFormError.inputChanged }
            try checkCurrent()
        }
        try check()
        if let completed { return completed } // Historical receipt; no replay or new page adoption.
        guard !retirementPending else { throw Failure.retirementPending }
        let store = try makeStore(directory)
        var persisted = try store.load(taskID: contract.taskID)
        let lease = try store.acquireExecution(taskID: contract.taskID, expected: persisted)
        defer { lease.release() }
        try check(); try lease.assertOwnership()
        let task = try ComputerUseTextTask(contract: contract, recovered: persisted,
            read: { [self] id in
                try check(); try browser.validateSourceDocument(input.evidence.page.document)
                let value = try await target.read(targetID: id)
                try check(); try browser.validateSourceDocument(input.evidence.page.document)
                return value
            }, apply: { _, _ in throw ComputerUseTextTaskError.invalidPlan },
            applyWithIdentity: { [self] dispatch in
                try check(); try browser.validateSourceDocument(input.evidence.page.document)
                try await target.apply(dispatch)
                try check(); try browser.validateSourceDocument(input.evidence.page.document)
            }, didDispatchInput: { [self] operationID in
                try check()
                let value = try await target.didDispatchInput(operationID: operationID)
                try check()
                return value
            }, finishPendingInput: { [self] _, operationID in
                try check(); try lease.assertOwnership()
                guard let persisted else { throw ComputerUseTextTaskError.journalMismatch }
                try store.confirmPendingAttempt(persisted)
                _ = try await target.finishPendingChange(operationID: operationID)
                try check(); try lease.assertOwnership()
            }, persist: { journal in
                try store.save(journal, replacing: persisted)
                persisted = journal
            }, acquireExecutionLease: {
                try lease.assertOwnership()
                return BorrowedLease(lease)
            }, mayAct: { do { try check(); return true } catch { return false } })
        do {
            if persisted == nil || persisted?.statuses.allSatisfy({ $0 == .planned }) == true {
                try await validateUnsentInput(checkCurrent: check)
                try check(); try lease.assertOwnership()
                try await target.validateRepresentability(of: contract)
                try check(); try lease.assertOwnership()
            }
            // Attempted steps go through the engine's original receipt/outcome
            // reconciliation. Matching a value alone never permits replay.
            try await task.run()
            try check(); try lease.assertOwnership()
            if let binding = input.nativePreservation {
                try await target.validateFormPreservation(binding)
                try check(); try lease.assertOwnership()
            }
            continuation = try .init(stage: self, current: task.verifiedContinuation())
            let receipt = ComputerUseBrowserResearchFormReceipt(stage: self)
            completed = receipt
            return receipt
        } catch {
            await browser.joinDOMCompletion(document: input.evidence.page.document)
            throw error
        }
    }

    /// Retire work with no native input under the same disk lease used to execute
    /// it. Native revocation precedes the durable tombstone. If either return
    /// is lost, only this retirement can resume; the old plan cannot run.
    func retireUnsent(checkCurrent: @escaping @MainActor () throws -> Void) async throws -> Retirement? {
        guard !isExecuting else { throw Failure.busy }
        try Task.checkCancellation(); try checkCurrent()
        if let retirement { return retirement }
        guard !isRetired else { throw Failure.retired }
        guard completed == nil, !observedNativeAttempt else { return nil }
        isExecuting = true
        defer { isExecuting = false }
        let plan = try ComputerUseTextTask(contract: contract, read: { _ in nil },
            apply: { _, _ in throw Failure.invalidStage }, persist: { _ in throw Failure.invalidStage }, mayAct: { false })
        let initial = plan.journal
        let digest = ComputerUseTaskContract.digest(["browser-unsent-form-retirement-v1", id,
            input.interpretation.input.rootDigest, input.interpretation.input.digest, contract.contractDigest])
        let store = try makeStore(directory), persisted = try store.load(taskID: contract.taskID)
        let lease = try store.acquireExecution(taskID: contract.taskID, expected: persisted)
        defer { lease.release() }
        if let persisted {
            guard persisted.taskID == initial.taskID, persisted.promptDigest == initial.promptDigest,
                  persisted.contractDigest == initial.contractDigest, persisted.stepIDs == initial.stepIDs,
                  persisted.retainedPrefixCount == nil,
                  persisted.retirementDigest == nil || persisted.retirementDigest == digest else { throw ComputerUseTextTaskError.journalMismatch }
            guard !persisted.statuses.contains(.verified) else { return nil }
        }
        // Preserve the disk attempt/uncertainty history. Only native proof
        // permits retirement; no status is rewritten to planned.
        let retired = ComputerUseTaskJournal(taskID: initial.taskID, promptDigest: initial.promptDigest,
            contractDigest: initial.contractDigest, stepIDs: initial.stepIDs,
            statuses: persisted?.statuses ?? initial.statuses, retirementDigest: digest)
        func check() throws {
            try Task.checkCancellation(); try checkCurrent(); try lease.assertOwnership()
            guard !isRetired else { throw Failure.retired }
        }
        do {
            try check()
            retirementPending = true
            // An exact saved tombstone already records the earlier native
            // proof. Resolve its durability even if that ledger later reset;
            // do not manufacture a new absence claim from the new ledger.
            if persisted?.retirementDigest == nil {
                guard try await target.retireUnsentInputs(operationIDs: plan.inputOperationIDs) else {
                    retirementPending = false; observedNativeAttempt = true; return nil
                }
            }
            try check()
            try store.retireUnsent(retired, replacing: persisted)
            let receipt = Retirement(stage: self, digest: digest)
            retirement = receipt
            // Publication is historical even if Pause closes the outer return.
            try check()
            return receipt
        } catch {
            await browser.joinDOMCompletion(document: input.evidence.page.document)
            throw error
        }
    }

    /// Retain verified historical work while revoking the unfinished suffix.
    /// Disk flags identify a candidate prefix; the original native receipts,
    /// required objects and exact no-attempt ledger must prove it atomically.
    func retainVerifiedPrefix(checkCurrent: @escaping @MainActor () throws -> Void) async throws -> PrefixResolution? {
        guard !isExecuting else { throw Failure.busy }
        try Task.checkCancellation(); try checkCurrent()
        guard !isRetired else { throw Failure.retired }
        if let nativePrefixResolution { return nativePrefixResolution }
        guard completed == nil else { return nil }
        isExecuting = true
        defer { isExecuting = false }
        let plan = try ComputerUseTextTask(contract: contract, read: { _ in nil },
            apply: { _, _ in throw Failure.invalidStage }, persist: { _ in throw Failure.invalidStage }, mayAct: { false })
        let store = try makeStore(directory), persisted = try store.load(taskID: contract.taskID)
        let lease = try store.acquireExecution(taskID: contract.taskID, expected: persisted)
        defer { lease.release() }
        guard let persisted, let prefix = try plan.historicalPrefixRequirements(in: persisted) else { return nil }
        let count = prefix.inputOperationIDs.count
        let digest = ComputerUseTaskContract.digest(["browser-form-suffix-retirement-v1", id,
            input.interpretation.input.rootDigest, input.interpretation.input.digest, contract.contractDigest, String(count)])
        guard (persisted.retirementDigest == nil && persisted.retainedPrefixCount == nil)
                || (persisted.retirementDigest == digest && persisted.retainedPrefixCount == count) else {
            throw ComputerUseTextTaskError.journalMismatch
        }
        let retained = try ComputerUseBrowserResearchFormContinuation(stage: self, current: prefix, completedEditCount: count)
        let retired = ComputerUseTaskJournal(taskID: persisted.taskID, promptDigest: persisted.promptDigest,
            contractDigest: persisted.contractDigest, stepIDs: persisted.stepIDs, statuses: persisted.statuses,
            retirementDigest: digest, retainedPrefixCount: count)
        func check() throws {
            try Task.checkCancellation(); try checkCurrent(); try lease.assertOwnership()
            guard !isRetired else { throw Failure.retired }
        }
        do {
            try check()
            retirementPending = true
            if persisted.retirementDigest == nil {
                guard try await target.retireUnsentInputs(operationIDs: Array(plan.inputOperationIDs.dropFirst(count)), after: retained) else {
                    retirementPending = false
                    return nil
                }
            }
            try check()
            try store.retireRemainingInput(retired, replacing: persisted)
            let receipt = ComputerUseBrowserResearchFormReceipt(stage: self, completedEditCount: count)
            let resolution = PrefixResolution(retirement: .init(stage: self, digest: digest), receipt: receipt)
            continuation = retained; completed = receipt; nativePrefixResolution = resolution
            // Persisted native facts survive a late Pause. A later return can
            // publish this exact partial receipt, but cannot replay the suffix.
            try check()
            return resolution
        } catch {
            await browser.joinDOMCompletion(document: input.evidence.page.document)
            throw error
        }
    }

    /// Inspect historical criteria before offering a query. Changed values
    /// are repair work, not new success; original objects/receipts and explicit
    /// preservation still have to hold. No binding or journal is replaced.
    func inspectChangedCriteria(page: ComputerUseBrowserPageEvidence,
                                checkCurrent: @escaping @MainActor () throws -> Void) async throws -> Set<String> {
        guard !isExecuting else { throw Failure.busy }
        guard !isRetired else { throw Failure.retired }
        guard completed != nil, let continuation else { throw Failure.notVerified }
        isExecuting = true
        defer { isExecuting = false }
        do {
            try Task.checkCancellation(); try checkCurrent()
            let changed = try await target.inspectChangedCriteria(page: page, after: continuation)
            try Task.checkCancellation(); try checkCurrent()
            guard !isRetired else { throw Failure.retired }
            try browser.validateSourceDocument(page.document)
            return changed
        } catch {
            await browser.joinDOMCompletion(document: input.evidence.page.document)
            throw error
        }
    }

    /// Extend a verified stage's native field catalogue without rediscovery.
    /// Cancellation may leave a read-only extension committed in WebKit; a
    /// retry reuses its objects and the original required receipts.
    func prepareNextFormInput(interpretation: ComputerUseBrowserGoalProposal, formID: String,
                              page: ComputerUseBrowserPageEvidence, preserving: [ComputerUseBrowserControlPreservation],
                              scopeReview: ComputerUseBrowserEffectScopeReview? = nil, checkCurrent: @escaping @MainActor () throws -> Void) async throws
        -> (target: ComputerUseBrowserTextTarget, input: ComputerUseBrowserResearchFormInput) {
        guard !isExecuting else { throw Failure.busy }
        guard !isRetired else { throw Failure.retired }
        guard completed != nil, let continuation else { throw Failure.notVerified }
        guard interpretation.disposition == .research, interpretation.input.continues(input.interpretation.input), formID == input.selectedFormID,
              page.document == input.evidence.page.document, page.documentID == input.evidence.page.documentID else {
            throw ComputerUseBrowserActionPlanError.retainedFormRequiresExtension
        }
        isExecuting = true
        defer { isExecuting = false }
        func check() throws {
            try Task.checkCancellation(); try checkCurrent()
            guard !isRetired else { throw Failure.retired }
            try browser.validateSourceDocument(page.document)
        }
        do {
            try check()
            let fields = try await target.extendFields(in: formID, page: page,
                preserving: scopeReview?.formScope?.editablePreservedControlIDs ?? preserving.map(\.controlID),
                selecting: scopeReview?.formScope?.selectedControlIDs, after: continuation)
            try check()
            let evidence = try await target.bindFields(fields, to: page)
            let nativePreservation = try await target.prepareFormPreservation(scope: scopeReview?.formScope, page: page)
            try check()
            let next = try ComputerUseBrowserResearchFormInput(interpretation: interpretation, evidence: evidence,
                selectedFormID: formID, preservedControls: preserving, previous: continuation, scopeReview: scopeReview,
                nativePreservation: nativePreservation)
            return (target, next)
        } catch {
            await browser.joinDOMCompletion(document: page.document)
            throw error
        }
    }

    /// Explicit handback may replace the observation nonce without changing
    /// the page or field objects. Refresh only the no-attempt observation under
    /// the execution lease; keep the exact original proposal and contract.
    private func validateUnsentInput(checkCurrent: () throws -> Void) async throws {
        try await Self.validateOriginalInput(input, target: target, browser: browser, checkCurrent: checkCurrent)
    }

    /// Re-establish observation nonces after handback without changing the
    /// retained proposal, source scope, native objects or private baseline.
    static func validateOriginalInput(_ input: ComputerUseBrowserResearchFormInput, target: ComputerUseBrowserTextTarget,
                                      browser: ComputerUseOwnedBrowser, checkCurrent: () throws -> Void) async throws {
        try checkCurrent()
        if let binding = input.nativePreservation { try await target.validateFormPreservation(binding); try checkCurrent() }
        let original = input.evidence.page
        try browser.validateSourceDocument(original.document)
        let metadata = try await browser.observePage(document: original.document)
        try checkCurrent()
        let current: ComputerUseBrowserPageEvidence
        if let review = input.scopeReview, !review.readControls.isEmpty {
            current = try await browser.observeResearchControls(for: review.restoredReadProposal(for: metadata))
        } else { current = metadata }
        try checkCurrent()
        let fields = try await target.bindFields(input.evidence.fields.map(\.editable), to: current)
        try checkCurrent()
        let page = current.page, before = original.page
        // Field input does not use viewport coordinates. Ignore only the
        // observation nonce and viewport; all captured page content stays fixed.
        let comparable = ComputerUseBrowserPageSnapshot(id: before.id, texts: page.texts, links: page.links, controls: page.controls,
            truncated: page.truncated, omittedEmbeddedContent: page.omittedEmbeddedContent, omittedControls: page.omittedControls,
            viewport: before.viewport, containers: page.containers, omittedStructure: page.omittedStructure,
            controlStates: page.controlStates, controlStateObserved: page.controlStateObserved, scopedControlIDs: page.scopedControlIDs,
            omittedControlMetadata: page.omittedControlMetadata)
        guard current.documentID == original.documentID, comparable == before, fields.fields == input.evidence.fields else {
            throw ComputerUseBrowserResearchFormError.inputChanged
        }
        if let review = input.scopeReview {
            try ComputerUseBrowserObservedCriteria.requireUnchanged(controlIDs: review.readControls.map(\.controlID),
                original: original, current: current)
        }
        try browser.validateSourceDocument(original.document)
    }

    func prepareQuery(controlID: String, evidence: ComputerUseBrowserPageEvidence,
                      checkCurrent: @escaping @MainActor () throws -> Void) async throws -> ComputerUseBrowserNavigationTarget {
        guard !isExecuting else { throw Failure.busy }
        guard !isRetired else { throw Failure.retired }
        guard completed != nil, let continuation else { throw Failure.notVerified }
        isExecuting = true
        defer { isExecuting = false }
        try Task.checkCancellation(); try checkCurrent()
        try browser.validateSourceDocument(evidence.document)
        do {
            let query = try await target.prepareFormQuery(controlID: controlID, evidence: evidence, after: continuation)
            try Task.checkCancellation(); try checkCurrent()
            guard !isRetired else { throw Failure.retired }
            try browser.validateSourceDocument(evidence.document)
            return query
        } catch {
            await browser.joinDOMCompletion(document: input.evidence.page.document)
            throw error
        }
    }

    func retire() { isRetired = true; completed = nil; continuation = nil }

    private final class BorrowedLease: ComputerUseTaskExecutionLease {
        let lease: any ComputerUseTaskExecutionLease
        init(_ lease: any ComputerUseTaskExecutionLease) { self.lease = lease }
        func assertOwnership() throws { try lease.assertOwnership() }
        func release() { } // The enclosing stage owns the actual release.
    }
}

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
    let verifiedTargetIDs: Set<String>
    let stateProofsByTarget: [String: ComputerUseBrowserFormStateProof]
    let inputOperationIDs: [String]
    let preservedControls: [ComputerUseBrowserFormPreservationSource]
    let nativePreservation: ComputerUseBrowserFormPreservation?
    let preservedTargetIDs: Set<String>
    let editedSources: [String: [ComputerUseBrowserFormSource]]
    let verifiedSources: [String: [ComputerUseBrowserFormSource]]
    let pendingEdits: [ComputerUseBrowserFormPendingEdit]
    var repairableTargetIDs: Set<String> { verifiedTargetIDs.subtracting(preservedTargetIDs) }
    let digest: String

    @MainActor fileprivate init(stage: ComputerUseBrowserResearchFormStage, current: ComputerUseTextTaskContinuation,
                               completedEditCount: Int? = nil, stateProof: ComputerUseBrowserFormStateProof? = nil) throws {
        let executionEdits = stage.executionPlan.inputEdits, count = completedEditCount ?? executionEdits.count
        guard (1...executionEdits.count).contains(count), current.inputOperationIDs.count == count,
              current.taskID == stage.input.interpretation.input.taskID,
              current.contractDigest == stage.contract.contractDigest else { throw ComputerUseBrowserResearchFormStage.Failure.invalidStage }
        var verified = Array(executionEdits.prefix(count))
        if stage.executionPlan.isMixed {
            guard let stateProof, let plan = stage.executionPlan.statePlan else { throw ComputerUseBrowserResearchFormStage.Failure.notVerified }
            try Self.validate(stateProof, plan: plan, stage: stage)
            verified = stage.executionPlan.observedEdits + verified
        } else if stateProof != nil { throw ComputerUseBrowserResearchFormStage.Failure.invalidStage }
        try self.init(stage: stage, verifiedEdits: verified, pending: Array(executionEdits.dropFirst(count)),
            finalValues: current.finalValues, inputIDs: current.inputOperationIDs,
            actualEdits: current.editedTargetIDs, proof: stateProof,
            evidenceDigest: stateProof.map { ComputerUseTaskContract.digest(["browser-form-mixed-evidence-v1", current.digest, $0.digest]) } ?? current.digest)
    }

    @MainActor private static func validate(_ proof: ComputerUseBrowserFormStateProof, plan: ComputerUseBrowserFormStatePlan,
                                            stage: ComputerUseBrowserResearchFormStage) throws {
        try plan.validate(for: stage.input)
        guard proof.planDigest == plan.digest, proof.verifiedValues == plan.expectedValues,
              proof.goalRevision == stage.input.interpretation.input.digest,
              proof.document == stage.input.evidence.page.document, proof.documentID == stage.input.evidence.page.documentID else {
            throw ComputerUseBrowserResearchFormStage.Failure.invalidStage
        }
    }

    @MainActor fileprivate init(stage: ComputerUseBrowserResearchFormStage, proof: ComputerUseBrowserFormStateProof,
                               plan: ComputerUseBrowserFormStatePlan) throws {
        guard stage.executionPlan.verificationOnly else { throw ComputerUseBrowserResearchFormStage.Failure.invalidStage }
        try Self.validate(proof, plan: plan, stage: stage)
        try self.init(stage: stage, verifiedEdits: stage.proposal.edits, pending: [], finalValues: stage.contract.finalValues,
            inputIDs: [], actualEdits: [], proof: proof, evidenceDigest: proof.digest)
    }

    @MainActor private init(stage: ComputerUseBrowserResearchFormStage, verifiedEdits: [ComputerUseBrowserFormProposal.Edit],
                            pending: [ComputerUseBrowserFormProposal.Edit], finalValues currentValues: [String: String],
                            inputIDs: [String], actualEdits: Set<String>, proof: ComputerUseBrowserFormStateProof?, evidenceDigest: String) throws {
        let input = stage.input, previous = input.previous
        guard previous == nil || (previous.map { input.interpretation.input.continues($0.goal) } == true
                && previous?.document == input.evidence.page.document && previous?.documentID == input.evidence.page.documentID
                && previous?.formID == input.selectedFormID) else { throw ComputerUseBrowserResearchFormStage.Failure.invalidStage }
        taskID = input.interpretation.input.taskID; rootDigest = input.interpretation.input.rootDigest; goalRevision = input.interpretation.input.digest
        goal = input.interpretation.input
        document = input.evidence.page.document; documentID = input.evidence.page.documentID; formID = input.selectedFormID
        stageIDs = (previous?.stageIDs ?? []) + [stage.id]
        inputOperationIDs = (previous?.inputOperationIDs ?? []) + inputIDs
        guard stageIDs.count <= 32, Set(stageIDs).count == stageIDs.count,
              inputOperationIDs.count <= 64, Set(inputOperationIDs).count == inputOperationIDs.count else {
            throw ComputerUseBrowserResearchFormStage.Failure.invalidStage
        }
        // Only completed criteria supersede earlier criteria. Unfinished
        // suffix work keeps its earlier values and exact source purposes.
        finalValues = (previous?.finalValues ?? [:]).merging(currentValues) { _, current in current }
        editedTargetIDs = (previous?.editedTargetIDs ?? []).union(actualEdits)
        let verified = Set(try verifiedEdits.map { try input.field(for: $0.field).editable.snapshot.targetID })
        verifiedTargetIDs = (previous?.verifiedTargetIDs ?? []).union(verified)
        guard !verifiedTargetIDs.isEmpty, verifiedTargetIDs.isSubset(of: Set(finalValues.keys)),
              editedTargetIDs.isSubset(of: verifiedTargetIDs),
              Set(previous?.finalValues.keys.map { $0 } ?? []).isSubset(of: Set(finalValues.keys)) else {
            throw ComputerUseBrowserResearchFormStage.Failure.invalidStage
        }
        preservedControls = try stage.proposal.preserved.map {
            .init(controlID: try input.field(for: $0.field).control.id, source: $0.source)
        } + input.nativePreservedSources
        nativePreservation = input.nativePreservation
        preservedTargetIDs = Set(try stage.proposal.preserved.map { try input.field(for: $0.field).editable.snapshot.targetID })
        var editedSources = previous?.editedSources ?? [:], sources = previous?.verifiedSources ?? [:]
        var proofs = previous?.stateProofsByTarget ?? [:]
        for edit in verifiedEdits {
            let targetID = try input.field(for: edit.field).editable.snapshot.targetID
            sources[targetID] = try stage.proposal.resolvedSources(for: edit)
            if actualEdits.contains(targetID) { editedSources[targetID] = sources[targetID]; proofs.removeValue(forKey: targetID) }
            else if let proof { proofs[targetID] = proof }
            else { throw ComputerUseBrowserResearchFormStage.Failure.invalidStage }
        }
        self.editedSources = editedSources; verifiedSources = sources; stateProofsByTarget = proofs
        pendingEdits = try pending.map { try stage.proposal.pendingEdit(for: $0) }
        digest = ComputerUseTaskContract.digest([stage.executionPlan.isMixed ? "browser-research-form-continuation-v7" : "browser-research-form-continuation-v6", taskID, rootDigest, goalRevision,
            document.contextID, String(document.generation), documentID, formID ?? "", previous?.digest ?? "", evidenceDigest]
            + [stage.contract.contractDigest, String(verifiedEdits.count)] + stageIDs + inputOperationIDs
            + proofs.keys.sorted().flatMap { [$0,proofs[$0]!.digest] })
    }

    var description: String { "BrowserResearchFormContinuation(stages: \(stageIDs.count))" }
    var debugDescription: String { description }
}

/// Historical proof of one verified form stage, never a current-page assertion
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
    let verifiedWithoutInputCount: Int
    var isCompleteStage: Bool { editCount + verifiedWithoutInputCount == plannedEditCount }
    @MainActor fileprivate init(stage: ComputerUseBrowserResearchFormStage, completedEditCount: Int? = nil, verifiedWithoutInputCount: Int = 0) {
        taskID = stage.input.interpretation.input.taskID; rootDigest = stage.input.interpretation.input.rootDigest
        goalRevision = stage.input.interpretation.input.digest
        stageID = stage.id; index = stage.index; contractDigest = stage.contract.contractDigest
        plannedEditCount = stage.proposal.edits.count
        editCount = completedEditCount ?? stage.contract.steps.count
        self.verifiedWithoutInputCount = verifiedWithoutInputCount
    }
    var description: String { "BrowserResearchFormReceipt(edits: \(editCount), verifiedWithoutInput: \(verifiedWithoutInputCount))" }
    var debugDescription: String { description }
}

/// One immutable, in-memory native binding with a durable per-step journal.
/// Reopening its store after a failed write never recreates its contract or
/// field objects. Lost browser/process state cannot be reconstructed from the
/// journal alone and remains an explicit recovery limitation.
@MainActor
final class ComputerUseBrowserResearchFormStage {
    enum Failure: Error, Equatable { case invalidStage, busy, retired, notVerified, retirementPending, valueCheckpointRequired }
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
    fileprivate let executionPlan: ComputerUseBrowserFormExecutionPlan
    private var statePlan: ComputerUseBrowserFormStatePlan? { executionPlan.statePlan }
    private var stateCapture: ComputerUseBrowserDOMReadCapture?
    private var stateProof: ComputerUseBrowserFormStateProof?
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
        let plan = try ComputerUseBrowserFormExecutionPlan(input: input, proposal: proposal, stageID: id)
        executionPlan = plan
        guard (input.previous?.inputOperationIDs.count ?? 0) + (plan.verificationOnly ? 0 : plan.contract.steps.count) <= 64 else {
            throw ComputerUseBrowserResearchFormError.stageLimit
        }
        contract = plan.contract
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
                if input.scopeReview != nil, dispatch.edit.mode == .replaceAll,
                   let index = contract.steps.firstIndex(where: { $0.targetID == dispatch.edit.targetID }), index > 0,
                   dispatch.expected.value.utf8.elementsEqual(dispatch.edit.text.utf8) {
                    // This is a fresh read at the field's ordered position,
                    // after earlier input was verified. Do not dispatch a
                    // redundant event. The driver must prove/revoke the unsent
                    // suffix and reprepare it; this signal is not a receipt.
                    throw Failure.valueCheckpointRequired
                }
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
            if let statePlan, persisted == nil || persisted?.statuses.allSatisfy({ $0 == .planned }) == true {
                // Bind the original contract on disk before the first private
                // observation. No status is marked attempted or verified. A
                // reconstructed different proposal cannot reuse an empty store.
                if persisted == nil {
                    let initial = task.journal
                    try store.save(initial, replacing: nil); persisted = initial
                } else if let persisted { try store.confirmRecoveredProgress(persisted) }
                let page = try await Self.restoreOriginalPage(input.evidence.page, review: input.scopeReview,
                    browser: browser, checkCurrent: check)
                try check(); try lease.assertOwnership()
                if stateCapture == nil { stateCapture = try .init(command: .verifyFormState, document: page.document) }
                guard let stateCapture else { throw Failure.invalidStage }
                if stateProof == nil {
                    stateProof = try await target.verifyFormState(statePlan, input: input, page: page, retaining: stateCapture)
                }
                try check(); try lease.assertOwnership()
                guard let stateProof else { throw ComputerUseBrowserResearchFormError.inputChanged }
                try await target.validateFormState(stateProof, for: statePlan, input: input, page: page)
                try check(); try lease.assertOwnership()
                guard let persisted else { throw ComputerUseTextTaskError.journalMismatch }
                try store.confirmRecoveredProgress(persisted)
                if executionPlan.verificationOnly {
                    continuation = try .init(stage: self, proof: stateProof, plan: statePlan)
                    let receipt = ComputerUseBrowserResearchFormReceipt(stage: self, completedEditCount: 0,
                        verifiedWithoutInputCount: proposal.edits.count)
                    completed = receipt
                    return receipt
                }
            }
            // A mixed contract omitted real operations only after observing
            // its leading criteria. Recovery cannot recreate that evidence
            // from current values after an input may already have occurred.
            guard !executionPlan.isMixed || stateProof != nil else { throw Failure.notVerified }
            // An attempted/uncertain journal always uses input reconciliation,
            // even if the original desired values were already present.
            guard (input.previous?.inputOperationIDs.count ?? 0) + contract.steps.count <= 64 else {
                throw ComputerUseBrowserResearchFormError.stageLimit
            }
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
            let retained = try ComputerUseBrowserResearchFormContinuation(stage: self, current: task.verifiedContinuation(),
                stateProof: executionPlan.isMixed ? stateProof : nil)
            if executionPlan.isMixed {
                // Validate historical observation origins against the now
                // extended real-input ledger and the current final values.
                let page = try await browser.observePage(document: input.evidence.page.document)
                try check(); try lease.assertOwnership()
                let changed = try await target.inspectChangedCriteria(page: page, after: retained)
                try check(); try lease.assertOwnership()
                guard changed.isEmpty, let persisted else { throw ComputerUseBrowserResearchFormError.inputChanged }
                try store.confirmRecoveredProgress(persisted)
            }
            let receipt = ComputerUseBrowserResearchFormReceipt(stage: self,
                verifiedWithoutInputCount: executionPlan.isMixed ? executionPlan.observedEdits.count : 0)
            continuation = retained; completed = receipt
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
        let retained = try ComputerUseBrowserResearchFormContinuation(stage: self, current: prefix, completedEditCount: count,
            stateProof: executionPlan.isMixed ? stateProof : nil)
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
            let receipt = ComputerUseBrowserResearchFormReceipt(stage: self, completedEditCount: count,
                verifiedWithoutInputCount: executionPlan.isMixed ? executionPlan.observedEdits.count : 0)
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

    /// Lend the retained adapter and exact continuation to a preparation
    /// frame before that frame starts any cancellable native work.
    func preparationContext(for action: ComputerUseBrowserActionProposal) throws
        -> (target: ComputerUseBrowserTextTarget, continuation: ComputerUseBrowserResearchFormContinuation) {
        guard let continuation else { throw Failure.notVerified }
        try validatePreparationContinuation(continuation)
        guard case .editForm(let formID) = action.step, formID == input.selectedFormID,
              action.input.interpretation.disposition == .research,
              action.input.interpretation.input.continues(input.interpretation.input),
              action.input.evidence.document == input.evidence.page.document,
              action.input.evidence.documentID == input.evidence.page.documentID else {
            throw ComputerUseBrowserActionPlanError.retainedFormRequiresExtension
        }
        return (target, continuation)
    }

    func validatePreparationContinuation(_ expected: ComputerUseBrowserResearchFormContinuation) throws {
        guard !isExecuting else { throw Failure.busy }
        guard !isRetired else { throw Failure.retired }
        guard completed != nil, continuation == expected else { throw Failure.notVerified }
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
        let current = try await restoreOriginalPage(original, review: input.scopeReview, browser: browser, checkCurrent: checkCurrent)
        let fields = try await target.bindFields(input.evidence.fields.map(\.editable), to: current)
        try checkCurrent()
        guard fields.fields == input.evidence.fields else { throw ComputerUseBrowserResearchFormError.inputChanged }
        try browser.validateSourceDocument(original.document)
    }

    static func restoreOriginalPage(_ original: ComputerUseBrowserPageEvidence, review: ComputerUseBrowserEffectScopeReview?,
                                    browser: ComputerUseOwnedBrowser, checkCurrent: () throws -> Void) async throws -> ComputerUseBrowserPageEvidence {
        try checkCurrent()
        try browser.validateSourceDocument(original.document)
        let metadata = try await browser.observePage(document: original.document)
        try checkCurrent()
        let current: ComputerUseBrowserPageEvidence
        if let review, !review.readControls.isEmpty {
            current = try await browser.observeResearchControls(for: review.restoredReadProposal(for: metadata))
        } else { current = metadata }
        try checkCurrent()
        guard current.documentID == original.documentID, current.page.matchesFormObservation(original.page) else {
            throw ComputerUseBrowserResearchFormError.inputChanged
        }
        if let review {
            try ComputerUseBrowserObservedCriteria.requireUnchanged(controlIDs: review.readControls.map(\.controlID),
                original: original, current: current)
        }
        try browser.validateSourceDocument(original.document)
        return current
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

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
    let preservedTargetIDs: Set<String>
    let editedSources: [String: [ComputerUseBrowserFormSource]]
    var repairableTargetIDs: Set<String> { editedTargetIDs.subtracting(preservedTargetIDs) }
    let digest: String

    @MainActor fileprivate init(stage: ComputerUseBrowserResearchFormStage, current: ComputerUseTextTaskContinuation) throws {
        let input = stage.input, previous = input.previous
        guard current.taskID == input.interpretation.input.taskID,
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
        // The next contract explicitly carries earlier values for fields it
        // does not edit; an intentional new edit supersedes that field only.
        finalValues = current.finalValues
        editedTargetIDs = (previous?.editedTargetIDs ?? []).union(current.editedTargetIDs)
        guard editedTargetIDs.isSubset(of: Set(finalValues.keys)),
              Set(previous?.finalValues.keys.map { $0 } ?? []).isSubset(of: Set(finalValues.keys)) else {
            throw ComputerUseBrowserResearchFormStage.Failure.invalidStage
        }
        preservedControls = try stage.proposal.preserved.map {
            .init(controlID: try input.field(for: $0.field).control.id, source: $0.source)
        }
        preservedTargetIDs = Set(try stage.proposal.preserved.map { try input.field(for: $0.field).editable.snapshot.targetID })
        var sources = previous?.editedSources ?? [:]
        for edit in stage.proposal.edits {
            let targetID = try input.field(for: edit.field).editable.snapshot.targetID
            switch edit.payload {
            case .text(let query):
                sources[targetID] = try query.terms.map { term in
                    guard let index = input.interpretation.requirements.firstIndex(where: { $0.id == term.requirementID }) else {
                        throw ComputerUseBrowserResearchFormStage.Failure.invalidStage
                    }
                    return try .init(index: index, interpretation: input.interpretation)
                }
            case .normalized(let value): sources[targetID] = [try .init(index: value.requirementIndex, interpretation: input.interpretation)]
            case .choice(_, let index): sources[targetID] = [try .init(index: index, interpretation: input.interpretation)]
            }
            // Several query terms may cite the same original clause. Retain
            // that source once, without repeating it in every later context.
            var unique: [ComputerUseBrowserFormSource] = []
            for source in sources[targetID] ?? [] where !unique.contains(source) { unique.append(source) }
            sources[targetID] = unique
        }
        editedSources = sources
        digest = ComputerUseTaskContract.digest(["browser-research-form-continuation-v3", taskID, rootDigest, goalRevision,
            document.contextID, String(document.generation), documentID, formID ?? "", previous?.digest ?? "", current.digest]
            + stageIDs + inputOperationIDs)
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
    @MainActor fileprivate init(stage: ComputerUseBrowserResearchFormStage) {
        taskID = stage.input.interpretation.input.taskID; rootDigest = stage.input.interpretation.input.rootDigest
        goalRevision = stage.input.interpretation.input.digest
        stageID = stage.id; index = stage.index; contractDigest = stage.contract.contractDigest; editCount = stage.contract.steps.count
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
    enum Failure: Error, Equatable { case invalidStage, busy, retired, notVerified }
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
    var nativeReceipt: ComputerUseBrowserResearchFormReceipt? { completed }
    var nativeContinuation: ComputerUseBrowserResearchFormContinuation? { continuation }

    init(input: ComputerUseBrowserResearchFormInput, proposal: ComputerUseBrowserFormProposal,
         target: ComputerUseBrowserTextTarget, browser: ComputerUseOwnedBrowser, index: Int, journalDirectory: URL,
         makeStore: @escaping (URL) throws -> ComputerUseTaskJournalStore = { try .init(directory: $0) }) throws {
        guard (0..<32).contains(index) else { throw Failure.invalidStage }
        self.input = input; self.proposal = proposal; self.target = target; self.browser = browser; self.index = index
        id = ComputerUseTaskContract.digest(["browser-research-form-stage-v1", input.interpretation.input.taskID,
            input.interpretation.input.rootDigest, String(index)])
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
            try checkCurrent()
        }
        try check()
        if let completed { return completed } // Historical receipt; no replay or new page adoption.
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
            continuation = try .init(stage: self, current: task.verifiedContinuation())
            let receipt = ComputerUseBrowserResearchFormReceipt(stage: self)
            completed = receipt
            return receipt
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
                              checkCurrent: @escaping @MainActor () throws -> Void) async throws
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
            let fields = try await target.extendFields(in: formID, page: page, preserving: preserving.map(\.controlID), after: continuation)
            try check()
            let evidence = try await target.bindFields(fields, to: page)
            try check()
            let next = try ComputerUseBrowserResearchFormInput(interpretation: interpretation, evidence: evidence,
                selectedFormID: formID, preservedControls: preserving, previous: continuation)
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
        try checkCurrent()
        let original = input.evidence.page
        try browser.validateSourceDocument(original.document)
        let current = try await browser.observePage(document: original.document)
        try checkCurrent()
        let fields = try await target.bindFields(input.evidence.fields.map(\.editable), to: current)
        try checkCurrent()
        let page = current.page, before = original.page
        // Field input does not use viewport coordinates. Ignore only the
        // observation nonce and viewport; all captured page content stays fixed.
        let comparable = ComputerUseBrowserPageSnapshot(id: before.id, texts: page.texts, links: page.links, controls: page.controls,
            truncated: page.truncated, omittedEmbeddedContent: page.omittedEmbeddedContent, omittedControls: page.omittedControls,
            viewport: before.viewport, containers: page.containers, omittedStructure: page.omittedStructure)
        guard current.documentID == original.documentID, comparable == before, fields.fields == input.evidence.fields else {
            throw ComputerUseBrowserResearchFormError.inputChanged
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

import Foundation

/// One opening under an immutable intent and native binding. This stage never
/// selects an option or treats a visible list as completion of the research goal.
@MainActor
final class ComputerUseBrowserPopupStage {
    @MainActor private final class State {
        var saved: ComputerUseTaskJournal?
        var receipt: ComputerUseBrowserPopupReceipt?
        var check: (() throws -> Void)?
        var retired = false
        func requireCurrent() throws {
            try Task.checkCancellation()
            guard !retired else { throw ComputerUseBrowserPopupError.retired }
            guard let check else { throw ComputerUseBrowserPopupError.busy }
            try check()
        }
    }
    let target: ComputerUseBrowserPopupTarget
    let contract: ComputerUseTaskContract
    let operationID: String
    let sequence: Int
    private let browser: ComputerUseOwnedBrowser
    private let store: ComputerUseTaskJournalStore
    private let state: State
    private let execution: ComputerUseTaskExecution
    private let journalDirectory: URL
    private var isExecuting = false
    private var retirementPending = false
    private(set) var retirementDigest: String?
    var completedReceipt: ComputerUseBrowserPopupReceipt? { state.receipt }

    init(target: ComputerUseBrowserPopupTarget, sequence: Int, browser: ComputerUseOwnedBrowser,
         journalDirectory: URL, confirmationBudget: Duration = .seconds(2),
         beforeDispatch: (@MainActor () async throws -> Void)? = nil,
         makeStore: (URL) throws -> ComputerUseTaskJournalStore = { try .init(directory: $0) }) throws {
        guard (0..<32).contains(sequence), target.binding.isWellFormed,
              target.binding.controlID == target.intent.controlID else { throw ComputerUseBrowserPopupError.invalidIntent }
        self.target = target; self.browser = browser; self.sequence = sequence; self.journalDirectory = journalDirectory
        let goal = target.intent.interpretation.input, entity = "popup", stepID = "open"
        let stageID = ComputerUseTaskContract.digest(["browser-popup-stage-v1",goal.taskID,goal.rootDigest,String(sequence)])
        let authority = ComputerUseTaskContract.digest([target.intent.evidence.document.contextID,goal.taskID])
        let contract = try ComputerUseTaskContract(taskID: stageID, promptDigest: goal.rootDigest,
            entities: [.init(id: entity, authorityDigest: authority)],
            predicates: [.init(id: "owned", entityID: entity, kind: "task-ownership", expectedDigest: authority),
                .init(id: "prepared", entityID: entity, kind: "popup-preflight", expectedDigest: target.payloadDigest),
                .init(id: "opened", entityID: entity, kind: "popup-opening-receipt", expectedDigest: target.payloadDigest)],
            steps: [.init(id: stepID, dependencies: [], operation: .init(capabilityID: "browser.openPopup", entityID: entity,
                payloadDigest: target.payloadDigest, payloadVersion: 1), preconditions: ["prepared"], postconditions: ["opened"])],
            invariants: ["owned"], outcomes: ["opened"])
        self.contract = contract
        let operationID = contract.effectIdentity(for: contract.steps[0]); self.operationID = operationID
        let store = try makeStore(journalDirectory); self.store = store
        let state = State(); self.state = state; state.saved = try store.load(taskID: stageID)
        if let saved = state.saved, saved.retirementDigest != nil {
            let digest = ComputerUseTaskContract.digest(["browser-popup-unsent-retirement-v1",contract.contractDigest,operationID])
            guard saved.taskID == stageID, saved.promptDigest == contract.promptDigest, saved.contractDigest == contract.contractDigest,
                  saved.stepIDs == [stepID], saved.statuses.count == 1, !saved.statuses.contains(.verified),
                  saved.retainedPrefixCount == nil, saved.retirementDigest == digest else { throw ComputerUseTaskExecutionError.journalMismatch }
            retirementPending = true // Reconfirm the tombstone before publishing it.
        }
        let budget = min(.seconds(2), max(.zero, confirmationBudget))
        execution = try ComputerUseTaskExecution(contract: contract, recovered: retirementPending ? nil : state.saved,
            observe: { predicate in
                do {
                    try state.requireCurrent()
                    switch predicate.id {
                    case "owned": return browser.hasOwnership(taskID: goal.taskID) && browser.contextID == target.intent.evidence.document.contextID
                    case "prepared":
                        do { try await browser.validatePopup(target); return true }
                        catch let error as ComputerUseBrowserPopupError where error == .unavailable {
                            // A failed preflight can detach from an in-flight DOM
                            // callback too. Keep the execution lease until it ends.
                            await browser.joinDOMCompletion(document: target.intent.evidence.document)
                            return false
                        }
                    case "opened":
                        if let receipt = state.receipt { return receipt.validates(target, operationID: operationID) }
                        let deadline = ContinuousClock.now.advanced(by: budget)
                        while true {
                            try state.requireCurrent()
                            if let receipt = try await browser.popupReceipt(target, operationID: operationID) {
                                // Preserve a confirmed native fact before an outer
                                // Pause can reject publication to the research owner.
                                state.receipt = receipt
                                try state.requireCurrent()
                                return true
                            }
                            try state.requireCurrent()
                            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserPopupError.uncertain }
                            try await Task.sleep(for: min(.milliseconds(50), ContinuousClock.now.duration(to: deadline)))
                        }
                    default: return false
                    }
                } catch {
                    await browser.joinDOMCompletion(document: target.intent.evidence.document)
                    throw error
                }
            }, perform: { _, id in
                do {
                    if let beforeDispatch { try await beforeDispatch() }
                    try state.requireCurrent()
                    try await browser.dispatchPopup(target, operationID: id, willBeginEffect: { try state.requireCurrent() })
                } catch {
                    await browser.joinDOMCompletion(document: target.intent.evidence.document)
                    throw error
                }
            }, persist: { journal in
                try state.requireCurrent()
                try store.save(journal, replacing: state.saved); state.saved = journal
            }, finishPendingEffect: { _, id in
                do {
                    try state.requireCurrent()
                    if let receipt = state.receipt, receipt.validates(target, operationID: id) { return }
                    // The same native command atomically rejects a second dispatch.
                    // If its ledger is empty, it revalidates the ORIGINAL page and
                    // binding before starting this original journaled operation.
                    try await browser.dispatchPopup(target, operationID: id, willBeginEffect: { try state.requireCurrent() })
                } catch {
                    await browser.joinDOMCompletion(document: target.intent.evidence.document)
                    throw error
                }
            }, acquireExecutionLease: {
                let current = try store.load(taskID: stageID)
                let lease = try store.acquireExecution(taskID: stageID, expected: current)
                state.saved = current
                return lease
            },
            reloadJournal: {
                let current = try store.load(taskID: stageID)
                if let current { try store.confirmRecoveredProgress(current) }
                state.saved = current
                return current
            },
            assertOwnership: {
                try state.requireCurrent()
                guard browser.hasOwnership(taskID: goal.taskID), browser.contextID == target.intent.evidence.document.contextID else {
                    throw ComputerUseBrowserError.ownershipLost
                }
            })
    }

    func run(checkCurrent: @escaping @MainActor () throws -> Void) async throws -> ComputerUseBrowserPopupReceipt {
        guard !isExecuting else { throw ComputerUseBrowserPopupError.busy }
        guard retirementDigest == nil else { throw ComputerUseBrowserPopupError.retired }
        guard !retirementPending else { throw ComputerUseBrowserPopupError.retirementPending }
        isExecuting = true; state.check = checkCurrent
        defer { isExecuting = false; state.check = nil }
        do {
            try state.requireCurrent()
            try await execution.run()
            guard let receipt = state.receipt, receipt.validates(target, operationID: operationID) else { throw ComputerUseBrowserPopupError.uncertain }
            try state.requireCurrent()
            return receipt
        } catch {
            // Cancellation cannot release the owning operation while WebKit
            // still has its already-dispatched native call in flight.
            await browser.joinDOMCompletion(document: target.intent.evidence.document)
            throw error
        }
    }

    /// A durable attempt can be retired only with native proof that no click
    /// began. Historical journal statuses are retained, never reset to planned.
    func retireUnsent(checkCurrent: @escaping @MainActor () throws -> Void) async throws -> String? {
        guard !isExecuting else { throw ComputerUseBrowserPopupError.busy }
        guard !state.retired else { throw ComputerUseBrowserPopupError.retired }
        isExecuting = true; state.check = checkCurrent
        defer { isExecuting = false; state.check = nil }
        let saved = try store.load(taskID: contract.taskID)
        let lease = try store.acquireExecution(taskID: contract.taskID, expected: saved)
        defer { lease.release() }
        let digest = ComputerUseTaskContract.digest(["browser-popup-unsent-retirement-v1",contract.contractDigest,operationID])
        if let saved {
            guard saved.taskID == contract.taskID, saved.promptDigest == contract.promptDigest,
                  saved.contractDigest == contract.contractDigest, saved.stepIDs == contract.steps.map(\.id),
                  saved.retainedPrefixCount == nil, saved.retirementDigest == nil || saved.retirementDigest == digest else {
                throw ComputerUseTaskExecutionError.journalMismatch
            }
            if saved.statuses.contains(.verified) { return nil }
        }
        func check() throws { try state.requireCurrent(); try lease.assertOwnership() }
        do {
            try check()
            retirementPending = true
            guard try await browser.retireUnsentPopup(target, operationID: operationID) else { retirementPending = false; return nil }
            try check()
            let retired = ComputerUseTaskJournal(taskID: contract.taskID, promptDigest: contract.promptDigest,
                contractDigest: contract.contractDigest, stepIDs: contract.steps.map(\.id), statuses: saved?.statuses ?? [.planned],
                retirementDigest: digest)
            try store.retireUnsent(retired, replacing: saved)
            retirementDigest = digest; state.saved = retired
            try check()
            return digest
        } catch {
            await browser.joinDOMCompletion(document: target.intent.evidence.document)
            throw error
        }
    }

    func retire() { state.retired = true }

    /// Called only after the old run has joined. Carry an already observed
    /// native fact, but let the new lease reconfirm disk before publication.
    func reopened(makeStore: (URL) throws -> ComputerUseTaskJournalStore) throws -> ComputerUseBrowserPopupStage {
        guard !isExecuting, !state.retired else { throw ComputerUseBrowserPopupError.busy }
        let replacement = try ComputerUseBrowserPopupStage(target: target, sequence: sequence, browser: browser,
            journalDirectory: journalDirectory, makeStore: makeStore)
        replacement.state.receipt = state.receipt
        return replacement
    }
}

/// Historical opening/retirement under the original requirement. This is
/// neither a current selection nor evidence that a research result is true.
struct ComputerUseBrowserResearchPopupRecord: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Outcome: String, Sendable { case opened, retiredUnsent }
    let index: Int
    let operationID: String
    let intent: ComputerUseBrowserPopupIntent
    let outcome: Outcome
    let digest: String
    @MainActor init(stage: ComputerUseBrowserPopupStage, outcome: Outcome, digest: String) {
        index = stage.sequence; operationID = stage.operationID; intent = stage.target.intent; self.outcome = outcome; self.digest = digest
    }
    var description: String { "BrowserPopupRecord(\(index), \(outcome.rawValue))" }
    var debugDescription: String { description }
}

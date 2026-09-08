import Foundation

/// One selected earlier visit, with the same journal/operation identity across
/// Pause and no-attempt rebinding. Browser history and a fresh GET revisit are
/// distinct native targets; recovery cannot silently switch between them.
@MainActor
final class ComputerUseBrowserResearchHistoryNavigation {
    enum Failure: Error, Equatable { case invalidIntent, busy, retired }
    let option: ComputerUseBrowserHistoryOption
    let goal: ComputerUseBrowserGoalInput
    let operationID: String
    private let browser: ComputerUseOwnedBrowser
    private let navigation: ComputerUseBrowserNavigationTask
    private var target: ComputerUseBrowserNavigationTarget
    private var alternative: ComputerUseBrowserNavigationTarget?
    private var didBegin = false
    private var completed: ComputerUseBrowserNavigationReceipt?
    private var isExecuting = false
    private var isRetired = false

    init(option: ComputerUseBrowserHistoryOption, goal: ComputerUseBrowserGoalInput, sequence: Int,
         browser: ComputerUseOwnedBrowser, journalDirectory: URL,
         makeStore: @escaping (URL) throws -> ComputerUseTaskJournalStore = { try .init(directory: $0) }) throws {
        guard option.target.taskID == goal.taskID, (0..<32).contains(sequence) else { throw Failure.invalidIntent }
        self.option = option; self.goal = goal; self.browser = browser; target = option.target
        operationID = ComputerUseTaskContract.digest(["browser-research-history-stage-v1", goal.taskID, goal.rootDigest, String(sequence)])
        navigation = .init(browser: browser, journalDirectory: journalDirectory, observedNavigationStore: makeStore)
    }

    func run(prepareCurrent: @escaping @MainActor () async throws -> ComputerUseBrowserPageEvidence,
             checkCurrent: @escaping @MainActor () throws -> Void) async throws -> ComputerUseBrowserNavigationReceipt {
        guard !isExecuting else { throw Failure.busy }
        isExecuting = true
        defer { isExecuting = false }
        func check() throws {
            try Task.checkCancellation()
            guard !isRetired else { throw Failure.retired }
            try checkCurrent()
        }
        try check()
        if let completed { return completed }
        do {
            if didBegin {
                if let alternative {
                    target = try navigation.resolveUnconfirmedObservedDestination(target, replacement: alternative,
                        promptDigest: goal.rootDigest, operationID: operationID, checkCurrent: check)
                    self.alternative = nil
                }
                var prepared: ComputerUseBrowserNavigationTarget?
                do {
                    let previous = target
                    let result = try await navigation.replanUnsentObservedDestination(previous, promptDigest: goal.rootDigest,
                        operationID: operationID, prepare: {
                            let page = try await prepareCurrent()
                            try check()
                            let fresh = try self.browser.historyOption(visit: self.option.visit,
                                operationID: self.option.operationID, evidence: page).target
                            try self.browser.validateHistoryRefresh(previous, replacement: fresh)
                            prepared = fresh
                            return fresh
                        })
                    switch result {
                    case .refreshed(let fresh): if !isRetired { target = fresh }
                    case .requiresReconciliation: break
                    case .noSelection: throw Failure.invalidIntent
                    }
                    try check()
                } catch {
                    if !isRetired { alternative = prepared }
                    throw error
                }
            }
            didBegin = true
            let receipt = try await navigation.openObservedDestination(target, promptDigest: goal.rootDigest,
                operationID: operationID, willBeginEffect: {})
            guard receipt.document.taskID == goal.taskID, receipt.document.operationID == operationID,
                  receipt.payloadDigest == target.payloadDigest else { throw Failure.invalidIntent }
            if !isRetired { completed = receipt }
            try check()
            return receipt
        } catch {
            // Fresh rebinding may own a DOM callback on the post-login page.
            // Keep the operation until that callback finishes or closes.
            if let document = browser.currentDocument(taskID: goal.taskID) { await browser.joinDOMCompletion(document: document) }
            throw error
        }
    }

    func retire() { isRetired = true; alternative = nil; completed = nil }
}

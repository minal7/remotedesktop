import Foundation

/// One retained query intent after a verified form stage. Its exact native
/// target is journaled by the existing navigation engine and may refresh only
/// with proof that it is unsent. A retry cannot switch submitters, rediscover
/// fields or create a new load ID.
@MainActor
final class ComputerUseBrowserResearchFormNavigation {
    enum Failure: Error, Equatable { case invalidIntent, busy, retired }
    let form: ComputerUseBrowserResearchFormReceipt
    let controlID: String
    let evidence: ComputerUseBrowserPageEvidence
    let goal: ComputerUseBrowserGoalInput
    let operationID: String
    private let stage: ComputerUseBrowserResearchFormStage
    private let browser: ComputerUseOwnedBrowser
    private let navigation: ComputerUseBrowserNavigationTask
    private var target: ComputerUseBrowserNavigationTarget?
    private var unconfirmedReplacement: ComputerUseBrowserNavigationTarget?
    private var didBeginPreparation = false
    private var completed: ComputerUseBrowserNavigationReceipt?
    private var isExecuting = false
    private var isRetired = false

    init(form: ComputerUseBrowserResearchFormReceipt, controlID: String, evidence: ComputerUseBrowserPageEvidence,
         stage: ComputerUseBrowserResearchFormStage, browser: ComputerUseOwnedBrowser, journalDirectory: URL,
         makeStore: @escaping (URL) throws -> ComputerUseTaskJournalStore = { try .init(directory: $0) }) throws {
        let goal = stage.input.interpretation.input
        guard form.stageID == stage.id, form.taskID == goal.taskID, form.goalRevision == goal.digest,
              form.contractDigest == stage.contract.contractDigest, evidence.document == stage.input.evidence.page.document,
              evidence.documentID == stage.input.evidence.page.documentID,
              evidence.page.controls.contains(where: { $0.id == controlID && $0.kind == "submit" && !$0.disabled }) else {
            throw Failure.invalidIntent
        }
        self.form = form; self.controlID = controlID; self.evidence = evidence; self.goal = goal
        self.stage = stage; self.browser = browser
        operationID = ComputerUseTaskContract.digest(["browser-research-form-query-stage-v1", goal.taskID, goal.rootDigest, stage.id])
        navigation = .init(browser: browser, journalDirectory: journalDirectory, observedNavigationStore: makeStore)
    }

    func run(checkCurrent: @escaping @MainActor () throws -> Void) async throws -> ComputerUseBrowserNavigationReceipt {
        guard !isExecuting else { throw Failure.busy }
        isExecuting = true
        defer { isExecuting = false }
        func check() throws {
            try Task.checkCancellation()
            guard !isRetired else { throw Failure.retired }
            try checkCurrent()
        }
        try check()
        if let completed { return completed } // Historical navigation only.
        do {
            if let previous = target {
                let resolved: ComputerUseBrowserNavigationTarget
                if let replacement = unconfirmedReplacement {
                    resolved = try navigation.resolveUnconfirmedObservedDestination(previous, replacement: replacement,
                        promptDigest: goal.rootDigest, operationID: operationID, checkCurrent: check)
                    target = resolved; unconfirmedReplacement = nil
                } else { resolved = previous }
                var prepared: ComputerUseBrowserNavigationTarget?
                do {
                    let result = try await navigation.replanUnsentObservedDestination(resolved, promptDigest: goal.rootDigest,
                        operationID: operationID, prepare: {
                            let fresh = try await self.prepareTarget(refresh: true, checkCurrent: check)
                            try self.browser.validateFormQueryRefresh(resolved, replacement: fresh)
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
                    // A failed post-rename write can expose either binding.
                    // Keep both known targets for leased resolution on Resume.
                    if !isRetired { unconfirmedReplacement = prepared }
                    throw error
                }
            } else {
                guard !browser.hasObservedNavigationAttempt(operationID: operationID) else {
                    throw ComputerUseBrowserError.observedNavigationUncertain
                }
                let refresh = didBeginPreparation
                didBeginPreparation = true
                let prepared = try await prepareTarget(refresh: refresh, checkCurrent: check)
                // Preparation itself cannot navigate. Retain the native target
                // before any journal write or call that can begin a request.
                if !isRetired { target = prepared }
                try check()
            }
            guard let target else { throw Failure.invalidIntent }
            let receipt = try await navigation.openObservedDestination(target, promptDigest: goal.rootDigest,
                operationID: operationID, willBeginEffect: {})
            guard receipt.document.taskID == goal.taskID, receipt.document.operationID == operationID,
                  receipt.payloadDigest == target.payloadDigest else { throw Failure.invalidIntent }
            if !isRetired { completed = receipt }
            try check()
            return receipt
        } catch {
            // Query preparation/validation can have an outstanding read-only
            // DOM call after Swift cancellation. Keep the owner occupied until
            // that call returns or the original browser is released.
            await browser.joinDOMCompletion(document: evidence.document)
            throw error
        }
    }

    private func prepareTarget(refresh: Bool, checkCurrent: @escaping @MainActor () throws -> Void) async throws -> ComputerUseBrowserNavigationTarget {
        try checkCurrent()
        let current: ComputerUseBrowserPageEvidence
        if refresh {
            try browser.validateSourceDocument(evidence.document)
            current = try await browser.observePage(document: evidence.document)
            try checkCurrent()
            let page = current.page, before = evidence.page
            let comparable = ComputerUseBrowserPageSnapshot(id: before.id, texts: page.texts, links: page.links, controls: page.controls,
                truncated: page.truncated, omittedEmbeddedContent: page.omittedEmbeddedContent, omittedControls: page.omittedControls,
                viewport: before.viewport, containers: page.containers, omittedStructure: page.omittedStructure)
            guard current.document == evidence.document, current.documentID == evidence.documentID, comparable == before else {
                throw ComputerUseBrowserError.pageChanged
            }
        } else { current = evidence }
        return try await stage.prepareQuery(controlID: controlID, evidence: current, checkCurrent: checkCurrent)
    }

    func retire() { isRetired = true; target = nil; unconfirmedReplacement = nil; completed = nil }
}

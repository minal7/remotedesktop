import Foundation

/// Retains dynamically discovered result-link stages under one research root.
/// The existing native navigation journal owns effect/replay authority; this
/// state retains the chosen stage across Pause and caller retries.
@MainActor
final class ComputerUseBrowserResearchNavigation {
    enum Failure: Error, Equatable { case invalidSelection, pendingStage, stageLimit, retired, busy }
    struct Selection: Hashable, Sendable {
        let goalRevision: String
        let candidateID: String
        let linkID: String
    }
    enum ReplanResult: Equatable, Sendable { case noPendingStage, requiresReconciliation, noSelection, updated }
    private struct Stage {
        let selection: Selection
        let operationID: String
        let target: ComputerUseBrowserNavigationTarget
    }
    private let taskID: String
    private let rootDigest: String
    private let browser: ComputerUseOwnedBrowser
    private let navigation: ComputerUseBrowserNavigationTask
    private var pending: Stage?
    private var unconfirmedReplacement: Stage?
    private var completed: [Selection: Stage] = [:]
    private var isExecuting = false
    private var isRetired = false
    var pendingSelection: Selection? { pending?.selection }

    init(input: ComputerUseBrowserGoalInput, browser: ComputerUseOwnedBrowser, journalDirectory: URL,
         navigationStore: @escaping (URL) throws -> ComputerUseTaskJournalStore = { try .init(directory: $0) }) {
        taskID = input.taskID; rootDigest = input.rootDigest; self.browser = browser
        navigation = .init(browser: browser, journalDirectory: journalDirectory, observedNavigationStore: navigationStore)
    }

    /// A receipt proves a historical navigation, not a current result page or
    /// completed research. Returning it again never dispatches another load.
    func open(_ selection: Selection, goal: ComputerUseBrowserGoalInput, candidates: ComputerUseBrowserResultCandidates?,
              checkCurrent: () throws -> Void) async throws -> ComputerUseBrowserNavigationReceipt {
        guard !isExecuting else { throw Failure.busy }
        guard !isRetired else { throw Failure.retired }
        guard goal.taskID == taskID, goal.rootDigest == rootDigest, goal.digest == selection.goalRevision,
              selection.candidateID.utf8.count == 64, !selection.linkID.isEmpty, selection.linkID.utf8.count <= 256 else {
            throw Failure.invalidSelection
        }
        isExecuting = true
        defer { isExecuting = false }
        func check() throws {
            try Task.checkCancellation()
            guard !isRetired else { throw Failure.retired }
            try checkCurrent()
        }
        try check()
        let stage: Stage
        if let pending {
            guard pending.selection == selection else { throw Failure.pendingStage }
            stage = try resolvePendingBinding(pending, checkCurrent: check)
        } else if let previous = completed[selection] {
            stage = previous
        } else {
            guard completed.count < 32 else { throw Failure.stageLimit }
            guard let candidates else { throw Failure.invalidSelection }
            let target = try await browser.prepareResultLinkNavigation(candidates, candidateID: selection.candidateID,
                linkID: selection.linkID, goal: goal)
            try check()
            // Payload, page identity and answer IDs cannot create a fresh
            // effect namespace for an interrupted stage.
            stage = .init(selection: selection, operationID: ComputerUseTaskContract.digest([
                "browser-research-link-stage-v1", taskID, rootDigest, String(completed.count)]), target: target)
            pending = stage
        }
        let receipt = try await navigation.openObservedDestination(stage.target, promptDigest: rootDigest,
            operationID: stage.operationID, willBeginEffect: {})
        try check()
        completed[stage.selection] = stage
        pending = nil
        return receipt
    }

    func retire() { isRetired = true; pending = nil; unconfirmedReplacement = nil; completed.removeAll() }

    private func resolvePendingBinding(_ previous: Stage, checkCurrent: () throws -> Void) throws -> Stage {
        guard let replacement = unconfirmedReplacement else { return previous }
        guard replacement.operationID == previous.operationID,
              replacement.selection.goalRevision == previous.selection.goalRevision else { throw Failure.invalidSelection }
        let target = try navigation.resolveUnconfirmedObservedDestination(previous.target, replacement: replacement.target,
            promptDigest: rootDigest, operationID: previous.operationID, checkCurrent: checkCurrent)
        let resolved = target == previous.target ? previous : replacement
        // No suspension separates the leased resolution and this assignment.
        // Subsequent effect/replan entry rechecks the saved identity itself.
        pending = resolved; unconfirmedReplacement = nil
        return resolved
    }

    /// The durable/native no-attempt proof and execution lease surround the
    /// fresh reading, selection and binding replacement. This never navigates.
    func replan(goal: ComputerUseBrowserGoalInput,
                prepare: () async throws -> (Selection, ComputerUseBrowserResultCandidates)?,
                checkCurrent: () throws -> Void) async throws -> ReplanResult {
        guard !isExecuting else { throw Failure.busy }
        guard !isRetired else { throw Failure.retired }
        guard let retained = pending else { return .noPendingStage }
        guard goal.taskID == taskID, goal.rootDigest == rootDigest, goal.digest == retained.selection.goalRevision else {
            throw Failure.invalidSelection
        }
        isExecuting = true
        defer { isExecuting = false }
        func check() throws {
            try Task.checkCancellation()
            guard !isRetired else { throw Failure.retired }
            try checkCurrent()
        }
        try check()
        let previous = try resolvePendingBinding(retained, checkCurrent: check)
        var prepared: Stage?
        let result: ComputerUseBrowserNavigationTask.ObservedReplanResult
        do {
            result = try await navigation.replanUnsentObservedDestination(previous.target, promptDigest: rootDigest,
                operationID: previous.operationID, prepare: {
                    guard let (selection, candidates) = try await prepare() else { return nil }
                    try check()
                    guard selection.goalRevision == goal.digest, completed[selection] == nil else { throw Failure.invalidSelection }
                    let target = try await browser.prepareResultLinkNavigation(candidates, candidateID: selection.candidateID,
                        linkID: selection.linkID, goal: goal)
                    try check()
                    prepared = Stage(selection: selection, operationID: previous.operationID, target: target)
                    return target
                })
        } catch {
            // Preparation has no effect authority. Keep at most the proposed
            // alternative so a failed post-rename write can be reconciled on
            // a later call, including after Pause. Stop cannot retain it.
            if !isRetired, pending?.operationID == previous.operationID { unconfirmedReplacement = prepared }
            try check()
            throw error
        }
        switch result {
        case .requiresReconciliation:
            try check()
            return .requiresReconciliation
        case .noSelection:
            try check()
            return .noSelection
        case .refreshed(let target):
            guard let prepared, prepared.target == target else { throw Failure.invalidSelection }
            // A completed durable replacement remains a fact after a late
            // Pause. Retain its matching target before surfacing cancellation;
            // otherwise Resume would use the old binding against the new file.
            if !isRetired, pending?.operationID == previous.operationID { pending = prepared; unconfirmedReplacement = nil }
            try check()
            return .updated
        }
    }
}

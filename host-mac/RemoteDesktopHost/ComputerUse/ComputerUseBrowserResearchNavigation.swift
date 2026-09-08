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
    private var completed: [Selection: Stage] = [:]
    private var isExecuting = false
    private var isRetired = false
    var pendingSelection: Selection? { pending?.selection }

    init(input: ComputerUseBrowserGoalInput, browser: ComputerUseOwnedBrowser, journalDirectory: URL) {
        taskID = input.taskID; rootDigest = input.rootDigest; self.browser = browser
        navigation = .init(browser: browser, journalDirectory: journalDirectory)
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
            stage = pending
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
        completed[selection] = stage
        pending = nil
        return receipt
    }

    func retire() { isRetired = true; pending = nil; completed.removeAll() }
}

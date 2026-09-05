import Foundation

/// Current-form text capability. Unsupported tasks cause no effects and remain
/// available to other reviewed capabilities. Interrupted tasks retain their
/// immutable contract instead of asking a model to reconstruct completed work.
@MainActor
final class ComputerUseNativeTextExecutor {
    private let target = ComputerUseAccessibilityTextTarget()
    private let injector: InputInjector
    private let mayAct: () -> Bool
    private let journalDirectory: URL
    private let planner: any ComputerUseTextGoalPlanning
    private let editOverride: ((ComputerUseTextPlanEdit, ComputerUseTextSnapshot) async throws -> Void)?
    private var retainedTask: ComputerUseTextTask?

    init(injector: InputInjector, mayAct: @escaping () -> Bool,
         journalDirectory: URL = ComputerUseTextStepStore.defaultDirectory,
         planner: any ComputerUseTextGoalPlanning,
         editOverride: ((ComputerUseTextPlanEdit, ComputerUseTextSnapshot) async throws -> Void)? = nil) {
        self.injector = injector
        self.mayAct = mayAct
        self.journalDirectory = journalDirectory
        self.planner = planner
        self.editOverride = editOverride
    }

    func execute(taskID: String, prompt: String,
                 verifiedStep: (Int, Int) -> Void = { _, _ in }, progress: (String) -> Void) async throws
        -> ComputerUseExecutionResult? {
        if let retainedTask, retainedTask.contract.taskID == taskID {
            guard retainedTask.contract.promptDigest == ComputerUseTextTaskContract.digest(prompt) else {
                throw ComputerUseTextTaskError.journalMismatch
            }
            return try await run(retainedTask, verifiedStep: verifiedStep, progress: progress)
        }
        retainedTask = nil
        let fields = target.fields()
        guard !fields.isEmpty else { return nil }
        guard mayAct() else { throw ComputerUseTextEditError.interrupted }
        let proposal = try await planner.propose(prompt: prompt, fields: fields)
        try Task.checkCancellation()
        guard mayAct() else { throw ComputerUseTextEditError.interrupted }
        switch proposal {
        case .unsupported: return nil
        case .clarification:
            return .clarificationRequired("Which field should I edit, and what exact text should it contain?")
        case .edits(let edits, let unchanged):
            // Recheck every discovered field after inference before any focus
            // or value change. Planning observations are never effect authority.
            for field in fields {
                guard target.snapshot(targetID: field.snapshot.targetID) == field.snapshot else {
                    throw ComputerUseTextTaskError.staleTarget
                }
            }
            let contract = try ComputerUseTextTaskContract(taskID: taskID, prompt: prompt,
                                                           fields: fields, edits: edits,
                                                           unchangedTargetIDs: unchanged)
            let store = try ComputerUseTextStepStore(directory: journalDirectory)
            let task = try ComputerUseTextTask(contract: contract, recovered: store.load(taskID: taskID),
                read: { [target] in target.snapshot(targetID: $0) },
                apply: { [weak self] edit, expected in
                    guard let self else { throw CancellationError() }
                    if let editOverride { try await editOverride(edit, expected) }
                    else { try await apply(edit, expected: expected) }
                },
                persist: { try store.save($0) }, mayAct: mayAct)
            retainedTask = task
            return try await run(task, verifiedStep: verifiedStep, progress: progress)
        }
    }

    private func run(_ task: ComputerUseTextTask, verifiedStep: (Int, Int) -> Void,
                     progress: (String) -> Void) async throws
        -> ComputerUseExecutionResult {
        try await task.run { complete, total in
            progress("Verified text edit \(complete) of \(total)…")
            verifiedStep(complete, total)
        }
        // Keep the completed task for same-ID replay within this executor; the
        // host's outer durable task ledger also retains the terminal outcome.
        return .completed("Done. I verified all \(task.contract.steps.count) requested text edits.")
    }

    private func apply(_ edit: ComputerUseTextPlanEdit, expected: ComputerUseTextSnapshot) async throws {
        guard target.snapshot(targetID: edit.targetID) == expected else {
            throw ComputerUseTextTaskError.staleTarget
        }
        let focused = try injector.performHostEffectIfAllowed(ifAllowed: mayAct) {
            target.focus(targetID: edit.targetID)
        }
        guard focused else { throw ComputerUseTextTaskError.staleTarget }
        var current: ComputerUseTextSnapshot?
        for _ in 0..<12 {
            try Task.checkCancellation()
            guard mayAct() else { throw ComputerUseTextEditError.interrupted }
            current = target.snapshot()
            if current?.targetID == edit.targetID { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard let current, current.targetID == edit.targetID,
              current.value.utf8.elementsEqual(expected.value.utf8),
              edit.mode != .insert || current.selection == expected.selection else {
            throw ComputerUseTextTaskError.staleTarget
        }
        var editor = ComputerUseTextEditor(
            read: { [target] in target.snapshot() },
            select: { [self] range in
                try injector.performHostEffectIfAllowed(ifAllowed: mayAct) { target.select(range) }
            },
            replaceSelectedText: { [self] text in
                try injector.performHostEffectIfAllowed(ifAllowed: mayAct) { target.replaceSelectedText(text) }
            },
            postUnicode: { [self] text in
                guard await injector.applyTextPaced(text, ifAllowed: mayAct) else {
                    throw ComputerUseTextEditError.interrupted
                }
            }, mayAct: mayAct)
        editor.replaceValue = { [self] value in
            try injector.performHostEffectIfAllowed(ifAllowed: mayAct) { target.replaceWebValue(value) }
        }
        try await editor.edit(edit.text, mode: edit.mode, expected: current)
    }
}

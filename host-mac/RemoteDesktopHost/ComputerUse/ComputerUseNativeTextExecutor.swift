import Foundation

/// Current-form text capability. Unsupported tasks cause no effects and remain
/// available to other reviewed capabilities. Interrupted tasks retain their
/// immutable contract instead of asking a model to reconstruct completed work.
@MainActor
final class ComputerUseNativeTextExecutor {
    enum Failure: Error, Equatable { case alreadyExecuting, invalidClarification }
    struct Clarification: Equatable, Sendable {
        let taskID: String
        let goal: ComputerUseUnresolvedTextGoal
        let question: String
        let scope: String
        let expiresAt: Date
    }
    private struct PendingClarification {
        let info: Clarification
        let browser: ComputerUseBrowserTextTarget
        let originatingTaskID: String?
        let expiryNonce: UUID
    }
    private struct PreparedClarification {
        let taskID: String
        let originatingTaskID: String
        let goal: ComputerUseUnresolvedTextGoal
        let browser: ComputerUseBrowserTextTarget
        let scope: String
        let expiresAt: Date
        let expiryNonce: UUID
    }
    private static let clarificationQuestion = "Which field should I edit, and what exact text should it contain?"
    private let target = ComputerUseAccessibilityTextTarget()
    private let injector: InputInjector
    private let mayAct: () -> Bool
    private let journalDirectory: URL
    private let planner: any ComputerUseTextGoalPlanning
    private let editOverride: ((ComputerUseTextPlanEdit, ComputerUseTextSnapshot) async throws -> Void)?
    private let browserTargetProvider: ((String) throws -> ComputerUseBrowserTextTarget?)?
    private let now: () -> Date
    private let clarificationLifetime: TimeInterval
    private var retainedTask: ComputerUseTextTask?
    private var retainedTaskOriginID: String?
    private var pendingClarification: PendingClarification?
    private var preparedClarification: PreparedClarification?
    private var isExecuting = false
    private var clarificationExpiryTask: Task<Void, Never>?

    init(injector: InputInjector, mayAct: @escaping () -> Bool,
         journalDirectory: URL = ComputerUseTextStepStore.defaultDirectory,
         planner: any ComputerUseTextGoalPlanning,
         editOverride: ((ComputerUseTextPlanEdit, ComputerUseTextSnapshot) async throws -> Void)? = nil,
         browserTargetProvider: ((String) throws -> ComputerUseBrowserTextTarget?)? = nil,
         now: @escaping () -> Date = Date.init, clarificationLifetime: TimeInterval = 600) {
        precondition(clarificationLifetime.isFinite && clarificationLifetime > 0 && clarificationLifetime <= 600)
        self.injector = injector
        self.mayAct = mayAct
        self.journalDirectory = journalDirectory
        self.planner = planner
        self.editOverride = editOverride
        self.browserTargetProvider = browserTargetProvider
        self.now = now
        self.clarificationLifetime = clarificationLifetime
    }

    deinit { clarificationExpiryTask?.cancel() }

    func execute(taskID: String, prompt: String,
                 verifiedStep: (Int, Int) -> Void = { _, _ in }, progress: (String) -> Void) async throws
        -> ComputerUseExecutionResult? {
        guard !isExecuting else { throw Failure.alreadyExecuting }
        isExecuting = true
        defer { isExecuting = false }
        if preparedClarification?.taskID == taskID {
            throw ComputerUseTextTaskError.journalMismatch
        }
        if let retainedTask, retainedTask.contract.taskID == taskID {
            guard retainedTaskOriginID == nil,
                  retainedTask.contract.promptDigest == ComputerUseTextTaskContract.digest(prompt) else {
                throw ComputerUseTextTaskError.journalMismatch
            }
            return try await run(retainedTask, verifiedStep: verifiedStep, progress: progress)
        }
        let goal = try ComputerUseUnresolvedTextGoal(userRequest: prompt)
        if let pending = pendingClarification, pending.info.taskID == taskID {
            guard pending.originatingTaskID == nil, pending.info.goal == goal else { throw Failure.invalidClarification }
            guard try clarification(taskID: taskID) != nil else { throw Failure.invalidClarification }
            return .clarificationRequired(pending.info.question)
        }
        retainedTask = nil
        retainedTaskOriginID = nil
        invalidateClarification()
        let browserTarget = try browserTargetProvider?(taskID)
        let fields: [ComputerUseTextField]
        if let browserTarget { fields = try await browserTarget.fields() }
        else { fields = target.fields() }
        return try await planAndRun(taskID: taskID, goal: goal, originatingTaskID: nil,
            browserTarget: browserTarget, fields: fields, verifiedStep: verifiedStep, progress: progress)
    }

    /// The manager may issue a controller/session-bound reference for this
    /// exact no-effect question. Native AX continuation needs a separate scope
    /// adapter; only retained owned-browser forms expose this capability.
    func clarification(taskID: String) throws -> Clarification? {
        guard let pending = pendingClarification, pending.info.taskID == taskID else { return nil }
        guard now() < pending.info.expiresAt else { invalidateClarification(); return nil }
        do {
            guard try pending.browser.clarificationScope() == pending.info.scope else { throw Failure.invalidClarification }
            return pending.info
        } catch { invalidateClarification(); throw error }
    }

    func invalidateClarification(taskID: String? = nil) {
        if taskID == nil || preparedClarification?.taskID == taskID {
            preparedClarification = nil
        }
        if taskID == nil || pendingClarification?.info.taskID == taskID {
            pendingClarification = nil
        }
        if pendingClarification == nil && preparedClarification == nil {
            clarificationExpiryTask?.cancel()
            clarificationExpiryTask = nil
        }
    }

    private func expireClarification(at expiry: Date, nonce: UUID) {
        clarificationExpiryTask?.cancel()
        let lifetime = max(0, expiry.timeIntervalSince(now()))
        clarificationExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(lifetime)) } catch { return }
            guard let self, self.pendingClarification?.expiryNonce == nonce
                    || self.preparedClarification?.expiryNonce == nonce else { return }
            self.invalidateClarification()
        }
    }

    /// Called only after the host claims the answer task and validates its
    /// explicit clarification reference. The full bounded goal is checked
    /// again here; an answer cannot replace the original or change its question.
    func continueClarification(taskID: String, originatingTaskID: String, goal: ComputerUseUnresolvedTextGoal,
                               verifiedStep: (Int, Int) -> Void = { _, _ in }, progress: (String) -> Void) async throws
        -> ComputerUseExecutionResult {
        guard !isExecuting else { throw Failure.alreadyExecuting }
        isExecuting = true
        defer { isExecuting = false }
        try Task.checkCancellation()
        guard mayAct() else { throw ComputerUseTextEditError.interrupted }
        guard !taskID.isEmpty, taskID != originatingTaskID else { throw Failure.invalidClarification }
        if let retainedTask, retainedTask.contract.taskID == taskID {
            guard retainedTaskOriginID == originatingTaskID,
                  retainedTask.contract.promptDigest == ComputerUseTextTaskContract.digest(goal.taskIdentityText) else {
                throw ComputerUseTextTaskError.journalMismatch
            }
            return try await run(retainedTask, verifiedStep: verifiedStep, progress: progress)
        }
        if let pending = pendingClarification, pending.info.taskID == taskID {
            guard pending.originatingTaskID == originatingTaskID, pending.info.goal == goal else { throw Failure.invalidClarification }
            guard try clarification(taskID: taskID) != nil else { throw Failure.invalidClarification }
            return .clarificationRequired(pending.info.question)
        }
        if preparedClarification == nil {
            guard let pending = pendingClarification, pending.info.taskID == originatingTaskID,
              let answer = goal.userTurns.last,
              try pending.info.goal.answering(pending.info.question, with: answer) == goal else { throw Failure.invalidClarification }
            guard try clarification(taskID: originatingTaskID) != nil else { throw Failure.invalidClarification }
            // Consume and retain ownership before any suspension. Only this
            // exact answer task may resume the observation or planning stage.
            invalidateClarification()
            retainedTask = nil
            retainedTaskOriginID = nil
            let next = try pending.browser.transferForClarification(taskID: taskID)
            let nonce = UUID()
            preparedClarification = PreparedClarification(taskID: taskID, originatingTaskID: originatingTaskID,
                goal: goal, browser: next, scope: pending.info.scope, expiresAt: pending.info.expiresAt, expiryNonce: nonce)
            expireClarification(at: pending.info.expiresAt, nonce: nonce)
        }
        guard let prepared = preparedClarification, prepared.taskID == taskID,
              prepared.originatingTaskID == originatingTaskID, prepared.goal == goal else { throw Failure.invalidClarification }
        do {
            guard now() < prepared.expiresAt,
                  try prepared.browser.clarificationScope() == prepared.scope else { throw Failure.invalidClarification }
            let fields = try await prepared.browser.reobserveRetainedFields()
            let result = try await planAndRun(taskID: taskID, goal: goal, originatingTaskID: originatingTaskID,
                browserTarget: prepared.browser, fields: fields, verifiedStep: verifiedStep, progress: progress)
                ?? .unableToComplete("I couldn't resolve this form edit from your answer. Start a new request with the field and exact text.")
            // A newly issued question has its own expiry and must survive.
            if preparedClarification?.expiryNonce == prepared.expiryNonce {
                invalidateClarification(taskID: taskID)
            }
            return result
        } catch {
            if !(error is CancellationError) && error as? ComputerUseTextEditError != .interrupted {
                invalidateClarification(taskID: taskID)
            }
            throw error
        }
    }

    private func planAndRun(taskID: String, goal: ComputerUseUnresolvedTextGoal, originatingTaskID: String?,
                            browserTarget: ComputerUseBrowserTextTarget?, fields: [ComputerUseTextField],
                            verifiedStep: (Int, Int) -> Void, progress: (String) -> Void) async throws
        -> ComputerUseExecutionResult? {
        let read: (String) async throws -> ComputerUseTextSnapshot? = { [target] id in
            if let browserTarget { return try await browserTarget.read(targetID: id) }
            return target.snapshot(targetID: id)
        }
        guard !fields.isEmpty else { return nil }
        try Task.checkCancellation()
        guard mayAct() else { throw ComputerUseTextEditError.interrupted }
        let proposal: ComputerUseTextGoalProposal
        if goal.userTurns.count == 1,
           let compiled = try ComputerUseQuotedTextRequest.compile(prompt: goal.userTurns[0], fields: fields) { proposal = compiled }
        else { proposal = try await planner.propose(goal: goal, fields: fields) }
        try Task.checkCancellation()
        guard mayAct() else { throw ComputerUseTextEditError.interrupted }
        let operations: [ComputerUseTextGoalOperation]
        let unchanged: [String]
        switch proposal {
        case .unsupported: return nil
        case .clarification:
            guard goal.userTurns.count < ComputerUseUnresolvedTextGoal.maximumUserTurns else {
                return .unableToComplete("I still couldn't determine the complete form edit. Start a new request with the field and exact text.")
            }
            if let browserTarget {
                let info = Clarification(taskID: taskID, goal: goal, question: Self.clarificationQuestion,
                    scope: try browserTarget.clarificationScope(), expiresAt: now().addingTimeInterval(clarificationLifetime))
                invalidateClarification()
                let nonce = UUID()
                pendingClarification = PendingClarification(info: info, browser: browserTarget,
                    originatingTaskID: originatingTaskID, expiryNonce: nonce)
                expireClarification(at: info.expiresAt, nonce: nonce)
            }
            return .clarificationRequired(Self.clarificationQuestion)
        case .edits(let edits, let retained):
            operations = edits.map(ComputerUseTextGoalOperation.enterText); unchanged = retained
        case .fieldOperations(let requested, let retained):
            operations = requested; unchanged = retained
        }
        // Recheck every discovered field after inference before any focus
        // or value change. Planning observations are never effect authority.
        for field in fields {
            guard try await read(field.snapshot.targetID) == field.snapshot else {
                throw ComputerUseTextTaskError.staleTarget
            }
        }
        if originatingTaskID != nil {
            guard let prepared = preparedClarification, prepared.taskID == taskID,
                  prepared.goal == goal, now() < prepared.expiresAt else { throw Failure.invalidClarification }
        }
        let contract = try ComputerUseTextTaskContract(taskID: taskID, prompt: goal.taskIdentityText,
                                                       fields: fields, operations: operations,
                                                       unchangedTargetIDs: unchanged)
        if let browserTarget {
            do { try await browserTarget.validateRepresentability(of: contract) }
            catch ComputerUseTextEditError.valueNotRepresentable {
                return .unableToComplete("A selected field cannot preserve the exact requested text. No fields were edited. Use a field that supports the text, or change the request.")
            }
        }
        try Task.checkCancellation()
        guard mayAct() else { throw ComputerUseTextEditError.interrupted }
        if originatingTaskID != nil {
            guard let prepared = preparedClarification, prepared.taskID == taskID,
                  prepared.goal == goal, now() < prepared.expiresAt else { throw Failure.invalidClarification }
        }
        let store = try ComputerUseTextStepStore(directory: journalDirectory)
        let task = try ComputerUseTextTask(contract: contract, recovered: store.load(taskID: taskID),
            read: read,
            apply: { [weak self] edit, expected in
                guard let self else { throw CancellationError() }
                if let editOverride { try await editOverride(edit, expected) }
                else { try await apply(edit, expected: expected) }
            },
            applyWithIdentity: browserTarget.map { target in
                { edit, expected, operationID in try await target.apply(edit, expected: expected, operationID: operationID) }
            },
            applyCopyWithIdentity: browserTarget.map { target in
                { edit, expected, source, operationID in
                    try await target.apply(edit, expected: expected, operationID: operationID, copySource: source)
                }
            },
            didDispatchInput: browserTarget.map { target in
                { operationID in try await target.didDispatchInput(operationID: operationID) }
            },
            persist: { try store.save($0) }, mayAct: mayAct)
        retainedTask = task
        retainedTaskOriginID = originatingTaskID
        invalidateClarification(taskID: taskID)
        return try await run(task, verifiedStep: verifiedStep, progress: progress)
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

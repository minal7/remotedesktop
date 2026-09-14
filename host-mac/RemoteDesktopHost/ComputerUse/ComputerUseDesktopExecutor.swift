import Foundation
import CoreGraphics

/// Shared native outcomes retain the provider's original response. A status
/// carries no invented answer, and manual handoff carries no invented input.
struct ComputerUseDesktopProposal: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        case action(ComputerUseFaraAction)
        case completionStatus(success: Bool)
        case handoff(String)
        case unsupported
    }
    let response: String
    let decision: Decision
    init(response: String, decision: Decision) { self.response = response; self.decision = decision }
    init(response: String, action: ComputerUseFaraAction) { self.init(response: response, decision: .action(action)) }
    init(_ proposal: ComputerUseFaraModel.Proposal) { self.init(response: proposal.response, action: proposal.action) }
    var action: ComputerUseFaraAction? { if case .action(let action) = decision { return action }; return nil }
}

/// Native image/action execution for trained computer-use providers. Provider
/// request profiles remain separate; this adapter admits shared native effects.
/// Not selected by the production loader until native model acceptance passes.
@MainActor
final class ComputerUseDesktopExecutor: ComputerUseTaskAwareExecuting, ComputerUseVisualApprovalContinuing {
    typealias Propose = @MainActor @Sendable (ComputerUseFaraModel.Input) async throws -> ComputerUseDesktopProposal
    enum Failure: Error, Equatable { case changedTask, recoveredTask, changedScreen, unsupportedAction, invalidApproval, stepLimit, authentication }
    private struct Observation {
        let image: ComputerUseDesktopImage
        let fingerprint: ComputerUsePlanningStateFingerprint
        let focusedTextFrame: CGRect?
        let focusedEditor: String?
        let focusedTextState: ComputerUseNativeTextState?
        let nativeControls: ComputerUseNativeControls?
    }
    private final class Approval {
        let continuation: ComputerUseVisualApprovalContinuation
        let proposal: ComputerUseDesktopProposal
        let action: ComputerUsePredictedAction
        let observation: Observation
        let fingerprint: ComputerUseApprovalFingerprint
        let message: String
        var performed = false
        init(taskID: String, proposal: ComputerUseDesktopProposal, action: ComputerUsePredictedAction,
             observation: Observation, fingerprint: ComputerUseApprovalFingerprint, message: String) {
            continuation = .init(taskID: taskID, nonce: UUID())
            self.proposal = proposal; self.action = action; self.observation = observation
            self.fingerprint = fingerprint; self.message = message
        }
        var result: ComputerUseExecutionResult { .approvalRequired(message: message, action: action, continuation: continuation) }
    }
    private final class Session {
        let taskID: String
        let goal: String
        var journal: ComputerUseTaskJournal
        var history: [ComputerUseFaraModel.Step] = []
        var turns = 0
        var rejected = 0
        var actionError: String?
        var approval: Approval?
        var terminal: ComputerUseExecutionResult?
        init(taskID: String, goal: String, journal: ComputerUseTaskJournal) {
            self.taskID = taskID; self.goal = goal; self.journal = journal
        }
    }
    private let store: ComputerUseTaskJournalStore
    private let propose: Propose
    private let finishRun: @MainActor @Sendable () async -> Void
    private let planning = ComputerUsePlanningWorker()
    private var session: Session?
    private var isExecuting = false
    private(set) var lastRevalidationDiagnostic: [String: String] = [:]
    /// Read-only access to the already bounded task history for opt-in
    /// diagnostics; reading it performs no capture, model request or input.
    var diagnosticHistory: [ComputerUseFaraModel.Step] { session?.history ?? [] }
    let isReady = true
    let requiresMacControlHelper = false
    let runtimeName = "Native desktop computer use"
    let readyDetail = "Native desktop execution is available"

    init(journalDirectory: URL, propose: @escaping Propose,
         finishRun: @escaping @MainActor @Sendable () async -> Void = {}) throws {
        store = try .init(directory: journalDirectory); self.propose = propose; self.finishRun = finishRun
    }

    func execute(prompt: String, tools: ComputerUseHostTools, progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        try await execute(taskID: UUID().uuidString, prompt: prompt, trustedUserPrompt: prompt, tools: tools, progress: progress)
    }

    func execute(taskID: String, prompt: String, trustedUserPrompt: String,
                 tools: ComputerUseHostTools, progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        guard !isExecuting else { throw ComputerUseTaskExecutionError.alreadyExecuting }
        isExecuting = true
        defer { isExecuting = false }
        do {
            let result: ComputerUseExecutionResult
            do { result = try await run(taskID: taskID, goal: trustedUserPrompt, tools: tools, progress: progress) }
            catch Failure.authentication { result = .userInterventionRequired("Complete sign-in or the system permission step, then choose Resume.") }
            await finishRun()
            return result
        } catch { await finishRun(); throw error }
    }

    private func checkAuthentication(_ tools: ComputerUseHostTools) throws {
        try Task.checkCancellation()
        if let context = try tools.currentAuthenticationContext(),
           ComputerUseAuthenticationBarrierDetector.requiresUserIntervention(context) { throw Failure.authentication }
        if let context = try tools.currentScreenCaptureConsentContext(),
           ComputerUseScreenCaptureConsentDetector.requiresUserIntervention(context) { throw Failure.authentication }
    }

    private func observe(_ tools: ComputerUseHostTools, includeControls: Bool = false) throws -> Observation {
        try checkAuthentication(tools)
        let before = tools.frontmostApplicationSnapshot()
        let screen = try tools.currentScreen()
        let after = tools.frontmostApplicationSnapshot()
        guard before.identity == after.identity, before.policyName == after.policyName,
              screen.frontmostWindowBounds != nil else { throw Failure.changedScreen }
        try checkAuthentication(tools)
        if try ComputerUseScreenCaptureConsentDetector.requiresUserIntervention(from: screen.image) { throw Failure.authentication }
        let editor = try tools.nativeFocusedEditorObservation()
        let controls = try includeControls ? tools.nativeControlObservation(displayBounds: screen.displayBounds, windowBounds: screen.frontmostWindowBounds!) : nil
        let finalApplication = tools.frontmostApplicationSnapshot()
        guard finalApplication.identity == after.identity, finalApplication.policyName == after.policyName else { throw Failure.changedScreen }
        return try Observation(image: ComputerUseDesktopImage(observation: screen),
            fingerprint: tools.planningStateFingerprint(for: screen, frontmostApplication: after.policyName,
                                                        frontmostApplicationIdentity: after.identity),
            focusedTextFrame: tools.nativeFocusedTextFrame(), focusedEditor: editor?.description, focusedTextState: editor?.textState,
            nativeControls: controls)
    }

    private func revalidate(_ expected: Observation, action: ComputerUsePredictedAction?, tools: ComputerUseHostTools) throws {
        let fresh = try observe(tools)
        let matches: Bool
        switch action {
        case .typeText?, .key?:
            if let action, try tools.focusedTypingTargetIsEditable(providerAction: action) {
                matches = expected.fingerprint.matchesFocusedEditableInputAuthority(fresh.fingerprint)
            } else { matches = expected.fingerprint == fresh.fingerprint }
        case .click(let x, let y, _, _)?:
            let target = try action.flatMap { try tools.nativePointerTargetFrame(for: $0) }
            if let window = expected.fingerprint.frontmostWindowBounds,
               let target, !target.isEmpty,
               window.contains(target), target.contains(CGPoint(x: x, y: y)) {
                let authorityMatches = expected.fingerprint.matchesPendingObservationAuthority(fresh.fingerprint)
                let pixelsMatch = try expected.image.matchesPixels(of: fresh.image, in: target.insetBy(dx: -40, dy: -40))
                matches = authorityMatches && pixelsMatch
                if !matches { lastRevalidationDiagnostic = ["pointerTargetFrame": String(describing: target),
                    "pointerPoint": "\(x),\(y)", "pointerAuthorityMatches": String(authorityMatches),
                    "pointerTargetPixelsMatch": String(pixelsMatch)] }
            } else {
                // A point outside the focused window was grounded in the full
                // desktop. Changes elsewhere cannot inherit window-only proof.
                matches = expected.fingerprint == fresh.fingerprint && expected.image.png == fresh.image.png
                if !matches { lastRevalidationDiagnostic = ["pointerTargetFrame": String(describing: target),
                    "pointerPoint": "\(x),\(y)", "pointerRequiresFullDisplayMatch": "true"] }
            }
        case .scroll(let x, let y, _, _)?:
            guard let window = expected.fingerprint.frontmostWindowBounds,
                  window.contains(CGPoint(x: x, y: y)) else { throw Failure.changedScreen }
            let scopeMatches = expected.fingerprint.matchesPendingObservationAuthority(fresh.fingerprint)
            if let field = expected.focusedTextFrame, field == fresh.focusedTextFrame, window.contains(field),
               expected.fingerprint.matchesFocusedEditableInputAuthority(fresh.fingerprint) {
                matches = try scopeMatches && expected.image.matchesInsertionPointPixels(of: fresh.image, window: window, field: field)
            } else {
                matches = try scopeMatches && expected.image.matchesPixels(of: fresh.image, in: window, wholePixelsOnly: true)
            }
        case nil:
            if let field = expected.focusedTextFrame, field == fresh.focusedTextFrame,
               let window = expected.fingerprint.frontmostWindowBounds, window.contains(field),
               expected.fingerprint.matchesFocusedEditableInputAuthority(fresh.fingerprint) {
                matches = try expected.image.matchesInsertionPointPixels(of: fresh.image, window: window, field: field,
                    onDifference: { changed, changedPixels, fieldPixels in
                        self.lastRevalidationDiagnostic = ["changedDisplayBounds": String(describing: changed),
                            "changedPixelBounds": String(describing: changedPixels), "fieldPixelBounds": String(describing: fieldPixels)]
                    })
            } else { matches = expected.fingerprint == fresh.fingerprint }
        default: matches = expected.fingerprint == fresh.fingerprint
        }
        guard matches else {
            lastRevalidationDiagnostic.merge(["screenMatches": String(expected.fingerprint.screenDigest == fresh.fingerprint.screenDigest),
                "focusMatches": String(expected.fingerprint.focusedAccessibilityIdentity == fresh.fingerprint.focusedAccessibilityIdentity),
                "editableAuthorityMatches": String(expected.fingerprint.matchesFocusedEditableInputAuthority(fresh.fingerprint)),
                "textFrameBefore": String(describing: expected.focusedTextFrame), "textFrameAfter": String(describing: fresh.focusedTextFrame),
                "window": String(describing: expected.fingerprint.frontmostWindowBounds)]) { _, value in value }
            throw Failure.changedScreen
        }
    }

    static func nativeAction(_ proposal: ComputerUseFaraAction, image: ComputerUseDesktopImage) throws -> ComputerUsePredictedAction? {
        switch proposal {
        case .pointer(let kind, let point):
            let count: Int, button: UInt8
            switch kind {
            case .leftClick: count = 1; button = 1
            case .rightClick: count = 1; button = 2
            case .doubleClick: count = 2; button = 1
            case .tripleClick: count = 3; button = 1
            default: throw Failure.unsupportedAction
            }
            let point = try image.displayPoint(normalizedX: point.x, normalizedY: point.y)
            return .click(x: point.x, y: point.y, button: button, count: count)
        case .typeText(let text): return .typeText(text)
        case .key(let keys): return try ComputerUseNativeKeyChord.action(keys)
        case .scrollAt(let horizontal, let pixels, let point):
            guard pixels.isFinite, abs(pixels) >= 1, abs(pixels) <= 10_000, pixels.rounded() == pixels else { throw Failure.unsupportedAction }
            let target = try image.displayPoint(normalizedX: point.x, normalizedY: point.y)
            let delta = Int(pixels)
            // Quartz wheel 1 is positive up; wheel 2 is positive left.
            return .scroll(x: target.x, y: target.y, dx: horizontal ? -delta : 0, dy: horizontal ? 0 : delta)
        case .wait, .remember, .reportCompletion: return nil
        default: throw Failure.unsupportedAction
        }
    }

    private func record(_ proposal: ComputerUseDesktopProposal, observation: Observation, session: Session) {
        session.turns += 1
        session.history.append(.init(screenshotPNG: observation.image.png, response: proposal.response,
            actionError: session.actionError, action: proposal.action, focusedEditor: observation.focusedEditor, focusedTextState: observation.focusedTextState))
        if session.history.count > 20 { session.history.removeFirst(session.history.count - 20) }
    }

    private func complete(_ answer: String, session: Session) throws -> ComputerUseExecutionResult {
        var completed = session.journal; completed.statuses = [.verified]
        try store.save(completed, replacing: session.journal); session.journal = completed
        session.terminal = .completed(answer)
        return .completed(answer)
    }

    private func run(taskID: String, goal: String, tools: ComputerUseHostTools, progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        try Task.checkCancellation()
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, goal.utf8.count <= 8192 else { throw Failure.changedTask }
        if let old = session, old.taskID == taskID {
            guard old.goal.utf8.elementsEqual(goal.utf8) else { throw Failure.changedTask }
            if let terminal = old.terminal { return terminal }
            if let approval = old.approval {
                guard !approval.performed else { throw Failure.invalidApproval }
                return approval.result
            }
        } else {
            let rootID = ComputerUseTaskContract.digest(["native-desktop-session-v1", taskID])
            guard try store.load(taskID: rootID) == nil else { throw Failure.recoveredTask }
            let journal = ComputerUseTaskJournal(taskID: rootID, promptDigest: ComputerUseTextTaskContract.digest(goal),
                contractDigest: ComputerUseTaskContract.digest([rootID, goal]), stepIDs: ["model-assessed-completion"], statuses: [.attempted])
            try store.save(journal, replacing: nil)
            session = Session(taskID: taskID, goal: goal, journal: journal)
        }
        guard let session else { throw Failure.changedTask }
        let lease = try store.acquireExecution(taskID: session.journal.taskID, expected: session.journal)
        defer { lease.release() }
        while session.turns < 64 {
            try Task.checkCancellation(); try lease.assertOwnership()
            let observation = try observe(tools, includeControls: true)
            let input = ComputerUseFaraModel.Input(goal: session.goal, screenshotPNG: observation.image.png,
                surface: .desktop, history: session.history, actionError: session.actionError, focusedEditor: observation.focusedEditor,
                focusedTextState: observation.focusedTextState, nativeControls: observation.nativeControls)
            let propose = self.propose
            let proposal = try await planning.perform(timeout: 45) { try await propose(input) }
            try Task.checkCancellation(); try lease.assertOwnership()
            do {
                let action = try proposal.action.flatMap { try Self.nativeAction($0, image: observation.image) }
                try revalidate(observation, action: action, tools: tools)
                if let action {
                    if case .typeText = action, try !tools.focusedTypingTargetIsEditable(providerAction: action) { throw Failure.changedScreen }
                    guard try !tools.actionIsObstructedByTransientSystemOverlay(action) else { throw Failure.changedScreen }
                    let fingerprint = try tools.prepareNativeActionFingerprint(for: action)
                    if let reason = tools.approvalReason(for: action) {
                        let pending = Approval(taskID: taskID, proposal: proposal, action: action,
                            observation: observation, fingerprint: fingerprint, message: reason)
                        session.approval = pending
                        return pending.result
                    }
                    progress("Using the desktop…")
                    try await dispatch(proposal, action: action, observation: observation, fingerprint: fingerprint,
                        session: session, tools: tools, assertOwnership: { try lease.assertOwnership() })
                } else {
                    switch proposal.decision {
                    case .completionStatus(let success):
                        if success { return try complete("The model reported completion.", session: session) }
                        let result = ComputerUseExecutionResult.unableToComplete("The model reported that it could not complete the task.")
                        session.terminal = result; return result
                    case .handoff(let message):
                        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              message.utf8.count <= 8192 else { throw Failure.unsupportedAction }
                        record(proposal, observation: observation, session: session)
                        session.actionError = nil; session.rejected = 0
                        return .userInterventionRequired(message)
                    case .action(.reportCompletion(let answer)): return try complete(answer, session: session)
                    case .action(.wait(let seconds)): try await Task.sleep(for: .seconds(seconds))
                    case .action(.remember): break
                    default: throw Failure.unsupportedAction
                    }
                }
                record(proposal, observation: observation, session: session)
                session.actionError = nil; session.rejected = 0
                // Retain the dispatched action before yielding to the other
                // process. Cancellation here must not lose its history or
                // reuse its journal ID after Resume.
                if action != nil { try await Task.sleep(for: .milliseconds(100)) }
            } catch Failure.changedScreen {
                record(proposal, observation: observation, session: session)
                session.actionError = "The desktop action was not performed: its observed screen, target or focus changed. Inspect the new screenshot before choosing another action."
                session.rejected += 1
            } catch Failure.unsupportedAction {
                record(proposal, observation: observation, session: session)
                if case .scroll? = proposal.action {
                    session.actionError = "Native scrolling requires an explicit coordinate inside the intended pane in the foreground window. No input was sent. Inspect the current screenshot and provide that coordinate."
                } else {
                    session.actionError = "That action is not supported by the native desktop adapter. No input was sent. Choose a supported native action."
                }
                session.rejected += 1
            }
            if session.rejected >= 3 { return .userInterventionRequired("I couldn't verify the next desktop action. Complete this step, then choose Resume.") }
        }
        throw Failure.stepLimit
    }

    private func dispatch(_ proposal: ComputerUseDesktopProposal, action: ComputerUsePredictedAction,
                          observation: Observation, fingerprint: ComputerUseApprovalFingerprint, session: Session,
                          tools: ComputerUseHostTools, approved: Bool = false, willBeginEffect: () -> Void = {},
                          assertOwnership: () throws -> Void) async throws {
        try revalidate(observation, action: action, tools: tools)
        let actionID = ComputerUseTaskContract.digest([session.journal.taskID, "native-dispatch", String(session.turns)])
        let lease = try store.acquireExecution(taskID: actionID, expected: nil)
        defer { lease.release() }
        let attempted = ComputerUseTaskJournal(taskID: actionID, promptDigest: session.journal.promptDigest,
            contractDigest: ComputerUseTaskContract.digest([proposal.response, observation.fingerprint.screenDigest]),
            stepIDs: ["native-dispatch-returned"], statuses: [.attempted])
        var began = false
        do {
            try await tools.performNativeAction(action, fingerprint: fingerprint, willBeginEffect: {
                try assertOwnership(); try lease.assertOwnership(); try self.checkAuthentication(tools)
                if !approved, tools.approvalReason(for: action) != nil { throw Failure.invalidApproval }
                try self.store.save(attempted, replacing: nil)
                began = true; willBeginEffect()
            })
            var verified = attempted; verified.statuses = [.verified]
            try store.save(verified, replacing: attempted)
        } catch {
            if began {
                var uncertain = attempted; uncertain.statuses = [.uncertain]
                try? store.save(uncertain, replacing: attempted)
                session.terminal = .unableToComplete("The last desktop action could not be confirmed. Check the app before starting another request.")
                if approved { throw ComputerUseHostTools.ToolError.approvedActionEffectMayHaveOccurred }
            }
            throw error
        }
    }

    func performApprovedVisualAction(_ continuation: ComputerUseVisualApprovalContinuation, action: ComputerUsePredictedAction,
        fingerprint: ComputerUseApprovalFingerprint, tools: ComputerUseHostTools, willBeginEffect: () -> Void) async throws {
        guard !isExecuting else { throw ComputerUseTaskExecutionError.alreadyExecuting }
        isExecuting = true; defer { isExecuting = false }
        guard let session, let pending = session.approval, pending.continuation == continuation,
              pending.action == action, pending.fingerprint == fingerprint, !pending.performed, session.terminal == nil else { throw Failure.invalidApproval }
        let lease = try store.acquireExecution(taskID: session.journal.taskID, expected: session.journal)
        defer { lease.release() }
        do {
            try await dispatch(pending.proposal, action: action, observation: pending.observation, fingerprint: fingerprint,
                session: session, tools: tools, approved: true, willBeginEffect: willBeginEffect,
                assertOwnership: { try lease.assertOwnership() })
            pending.performed = true
        } catch {
            // Once dispatch rejects a target, restoring its old appearance
            // cannot revive the user's approval for that observation.
            session.approval = nil
            throw error
        }
    }

    func continueAfterApprovedVisualAction(_ continuation: ComputerUseVisualApprovalContinuation, action: ComputerUsePredictedAction,
        tools: ComputerUseHostTools, progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        guard !isExecuting, let session, let pending = session.approval, pending.continuation == continuation,
              pending.action == action, pending.performed, session.terminal == nil else { throw Failure.invalidApproval }
        session.approval = nil
        record(pending.proposal, observation: pending.observation, session: session)
        return try await execute(taskID: session.taskID, prompt: session.goal, trustedUserPrompt: session.goal, tools: tools, progress: progress)
    }

    func cancelVisualApprovalContinuation(_ continuation: ComputerUseVisualApprovalContinuation) {
        guard let session, let pending = session.approval, pending.continuation == continuation else { return }
        session.approval = nil
        if pending.performed { session.terminal = .unableToComplete("The approved desktop action ran, but the remaining task was interrupted. Check the app before starting another request.") }
    }
}

enum ComputerUseNativeKeyChord {
    static func action(_ keys: [String]) throws -> ComputerUsePredictedAction {
        guard (1...8).contains(keys.count) else { throw ComputerUseDesktopExecutor.Failure.unsupportedAction }
        var modifiers: UInt16 = 0, usage: Int?
        let named: [String: Int] = ["enter": 0x28, "return": 0x28, "escape": 0x29, "esc": 0x29,
            "backspace": 0x2A, "tab": 0x2B, "space": 0x2C, "delete": 0x4C, "forwarddelete": 0x4C,
            "right": 0x4F, "arrowright": 0x4F, "left": 0x50, "arrowleft": 0x50,
            "down": 0x51, "arrowdown": 0x51, "up": 0x52, "arrowup": 0x52,
            "home": 0x4A, "end": 0x4D, "pageup": 0x4B, "page_up": 0x4B, "pagedown": 0x4E, "page_down": 0x4E]
        for source in keys {
            let key = source.lowercased(), bit: UInt16
            switch key {
            case "shift": bit = 1
            case "control", "ctrl": bit = 2
            case "option", "alt": bit = 4
            case "command", "cmd", "meta", "super": bit = 8
            default:
                guard usage == nil else { throw ComputerUseDesktopExecutor.Failure.unsupportedAction }
                if key.utf8.count == 1, let c = key.utf8.first, (97...122).contains(c) { usage = 0x04 + Int(c - 97) }
                else if key.utf8.count == 1, let c = key.utf8.first, (49...57).contains(c) { usage = 0x1E + Int(c - 49) }
                else if key == "0" { usage = 0x27 }
                else { usage = named[key] }
                guard usage != nil else { throw ComputerUseDesktopExecutor.Failure.unsupportedAction }
                continue
            }
            guard modifiers & bit == 0 else { throw ComputerUseDesktopExecutor.Failure.unsupportedAction }
            modifiers |= bit
        }
        guard let usage else { throw ComputerUseDesktopExecutor.Failure.unsupportedAction }
        return .key(usage: usage, modifiers: modifiers)
    }
}

import AppKit
import Foundation

/// Keyboard admission for a retained browser window. No shortcut here can
/// create, close, or switch a browser tab/window or application.
enum ComputerUseDefaultBrowserActionScope {
    static func permits(_ action: ComputerUsePredictedAction?, within bounds: CGRect) -> Bool {
        guard let action else { return true }
        switch action {
        case .click(let x, let y, _, _): return bounds.contains(CGPoint(x: x, y: y))
        case .drag(let x, let y, let tx, let ty): return bounds.contains(CGPoint(x: x, y: y)) && bounds.contains(CGPoint(x: tx, y: ty))
        case .scroll(let x, let y, _, _): return bounds.contains(CGPoint(x: x, y: y))
        case .typeText: return true
        case .key(let key, let modifiers):
            if modifiers == 0 || modifiers == 1 { return true } // ordinary keys and Shift variants
            if modifiers == 9 { return key == 0x1D } // Cmd-Shift-Z (redo)
            if modifiers == 8 { return [0x04, 0x06, 0x09, 0x0F, 0x19, 0x1B, 0x1D].contains(key) } // Cmd-A/C/F/L/V/X/Z
            return false // includes Ctrl-Tab/PageUp/PageDown and all other chords
        case .requestApproval(_, let nested): return permits(nested, within: bounds)
        case .wait, .done: return true
        }
    }
}

@MainActor
final class ComputerUseDefaultBrowserExecutor: ComputerUseTaskAwareExecuting, ComputerUseVisualApprovalContinuing {
    typealias CompletionCheck = @MainActor @Sendable (String) async throws -> Bool
    enum Failure: Error { case taskAlreadyBound, noRetainedWindow }

    @MainActor private final class Scope {
        let session: ComputerUseDefaultBrowserSession
        var window: ComputerUseDefaultBrowserSession.Window?
        var taskID: String?
        var goal: String?
        var attempted = false
        var tools: ComputerUseHostTools?
        init(session: ComputerUseDefaultBrowserSession) { self.session = session }
        func prepare(_ id: String, _ goal: String, _ tools: ComputerUseHostTools) async throws {
            self.tools = tools
            if let taskID, taskID != id { throw Failure.taskAlreadyBound }
            if let previousGoal = self.goal, !previousGoal.utf8.elementsEqual(goal.utf8) { throw Failure.taskAlreadyBound }
            taskID = id; self.goal = goal
            if window != nil {
                try session.validate(taskID: id, goal: goal, tools: tools)
                window = session.currentWindow
                return
            }
            guard !attempted else { throw ComputerUseDefaultBrowserSession.Failure.targetLost }
            attempted = true; window = try await session.ensure(taskID: id, goal: goal, tools: tools)
        }
        func check(_ action: ComputerUsePredictedAction?, _ tools: ComputerUseHostTools) throws {
            guard let taskID, let goal else { throw Failure.noRetainedWindow }
            try session.validate(taskID: taskID, goal: goal, tools: tools)
            guard let window = session.currentWindow else { throw Failure.noRetainedWindow }
            self.window = window
            guard ComputerUseDefaultBrowserActionScope.permits(action, within: window.identity.bounds) else {
                throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged
            }
        }
    }

    private let scope: Scope
    private let desktop: ComputerUseDesktopExecutor
    /// Optional task-specific verification supplements the model's decision
    /// from the fresh screenshot. Real-site acceptance checks outcomes separately.
    var retainedWindowForDiagnostics: ComputerUseDefaultBrowserSession.Window? { scope.window }
    private(set) var lastSessionFailureForDiagnostics: ComputerUseDefaultBrowserSession.Failure?
    var isReady: Bool { desktop.isReady }
    var runtimeName: String { "Default-browser desktop computer use" }
    var requiresMacControlHelper: Bool { desktop.requiresMacControlHelper }
    var hasAdditionalSetup: Bool { desktop.hasAdditionalSetup }
    var supportsNativeTextTasks: Bool { desktop.supportsNativeTextTasks }
    var readyDetail: String { desktop.readyDetail }

    init(journalDirectory: URL, propose: @escaping ComputerUseDesktopExecutor.Propose,
         finishRun: @escaping @MainActor @Sendable () async -> Void = {},
         completionCheck: CompletionCheck? = nil) throws {
        let scope = Scope(session: try ComputerUseDefaultBrowserSession(journalDirectory: journalDirectory))
        self.scope = scope
        desktop = try ComputerUseDesktopExecutor(journalDirectory: journalDirectory, propose: propose,
            surfaceScopeCheck: { action in
                guard let tools = scope.tools else { throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged }
                do { try scope.check(action, tools) }
                catch is CancellationError { throw CancellationError() }
                catch { throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged }
            }, completeCheck: completionCheck, finishRun: finishRun)
    }

    func execute(prompt: String, tools: ComputerUseHostTools, progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        try await execute(taskID: UUID().uuidString, prompt: prompt, trustedUserPrompt: prompt, tools: tools, progress: progress)
    }
    func execute(taskID: String, prompt: String, trustedUserPrompt: String, tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        lastSessionFailureForDiagnostics = nil
        do {
            try await scope.prepare(taskID, trustedUserPrompt, tools)
            return try await desktop.execute(taskID: taskID, prompt: prompt, trustedUserPrompt: trustedUserPrompt, tools: tools, progress: progress)
        } catch is CancellationError { throw CancellationError() }
        catch let failure as ComputerUseDefaultBrowserSession.Failure {
            lastSessionFailureForDiagnostics = failure
            if failure == .authenticationHandoff {
                return .userInterventionRequired("Complete sign-in or macOS permission in the intended browser window, then choose Resume.")
            }
            return .userInterventionRequired("The intended browser window changed or is unavailable. Restore it, then choose Resume.")
        }
        catch Failure.taskAlreadyBound { return .userInterventionRequired("This browser task is bound to its original goal. Resume that task to continue.") }
        catch Failure.noRetainedWindow { return .userInterventionRequired("The intended browser window changed or is unavailable. Restore it, then choose Resume.") }
        catch ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged {
            return .userInterventionRequired("The intended browser window changed or is unavailable. Restore it, then choose Resume.")
        }
        catch { throw error }
    }

    func performApprovedVisualAction(_ continuation: ComputerUseVisualApprovalContinuation, action: ComputerUsePredictedAction,
        fingerprint: ComputerUseApprovalFingerprint, tools: ComputerUseHostTools, willBeginEffect: () -> Void) async throws {
        do {
            scope.tools = tools
            try scope.check(action, tools)
            try await desktop.performApprovedVisualAction(continuation, action: action, fingerprint: fingerprint,
                                                         tools: tools, willBeginEffect: willBeginEffect)
        } catch is CancellationError { throw CancellationError() }
        catch ComputerUseHostTools.ToolError.approvedActionEffectMayHaveOccurred { throw ComputerUseHostTools.ToolError.approvedActionEffectMayHaveOccurred }
        catch {
            desktop.cancelVisualApprovalContinuation(continuation)
            throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged
        }
    }

    func continueAfterApprovedVisualAction(_ continuation: ComputerUseVisualApprovalContinuation, action: ComputerUsePredictedAction,
        tools: ComputerUseHostTools, progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        do {
            scope.tools = tools
            try scope.check(action, tools)
            return try await desktop.continueAfterApprovedVisualAction(continuation, action: action, tools: tools, progress: progress)
        } catch is CancellationError { throw CancellationError() }
        catch ComputerUseDefaultBrowserSession.Failure.authenticationHandoff { return .userInterventionRequired("Complete sign-in or macOS permission in the intended browser window, then choose Resume.") }
        catch { return .userInterventionRequired("The intended browser window changed or is unavailable. Restore it, then choose Resume.") }
    }

    func cancelVisualApprovalContinuation(_ continuation: ComputerUseVisualApprovalContinuation) {
        desktop.cancelVisualApprovalContinuation(continuation)
    }
}

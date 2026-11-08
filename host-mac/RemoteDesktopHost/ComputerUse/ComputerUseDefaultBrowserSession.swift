import AppKit
import ApplicationServices
import CoreImage
import Foundation

/// Opens the system HTTPS handler and retains one new task-owned AX window.
/// It owns only a signed app/window target; it does not identify a browser tab,
/// document, or page content.
@MainActor
final class ComputerUseDefaultBrowserSession {
    struct Window {
        let id: String
        let application: ComputerUseApplicationIdentity
        let accessibilityElement: AXUIElement
        let identity: ComputerUseFrontmostWindowCaptureIdentity
    }

    struct WindowSnapshot {
        let application: ComputerUseApplicationIdentity
        let windows: [Window]
        let focusedWindowID: String?
        let hasSheets: Bool
        let fileOpenPanel: FileOpenPanel?
        let hasUnrecognizedSheets: Bool

        init(application: ComputerUseApplicationIdentity, windows: [Window],
             focusedWindowID: String?, hasSheets: Bool,
             fileOpenPanel: FileOpenPanel? = nil, hasUnrecognizedSheets: Bool = false) {
            self.application = application
            self.windows = windows
            self.focusedWindowID = focusedWindowID
            self.hasSheets = hasSheets
            self.fileOpenPanel = fileOpenPanel
            self.hasUnrecognizedSheets = hasUnrecognizedSheets
        }
    }

    enum StartupWindowClassification: Equatable {
        case document
        case transientSurface
        case unknown
    }

    struct FileOpenPanel {
        let parentWindowID: String
        let parentWindowElement: AXUIElement
        let accessibilityElement: AXUIElement
        let bounds: CGRect
        let isFocused: Bool
        let goToFolderBounds: CGRect?
        let pathTextFieldElement: AXUIElement?
        let selectedFileURLs: [URL]
        let primaryActionElement: AXUIElement?
        let primaryActionBounds: CGRect?
        let primaryActionEnabled: Bool?
        var pathFieldIsFocused = false
        var pathFieldValue: String?
        var pathFieldSelection: NSRange?

        var actionBounds: CGRect { goToFolderBounds ?? bounds }
        var isNavigatingPath: Bool { goToFolderBounds != nil }
    }

    enum Failure: Error, Equatable {
        case changedTaskOrGoal, targetLost, ambiguousWindows, noNewFocusedWindow
        case existingWindowsChanged, interrupted, journalUncertain, authenticationHandoff, browserAutomationPermissionRequired
    }

    enum ValidationPhase: String { case capture, target, sheet, focus, complete }

    typealias ResolveHandler = @MainActor () throws -> ComputerUseDefaultBrowserTarget.Handler
    typealias LaunchApplication = @MainActor (ComputerUseDefaultBrowserTarget.Handler, @escaping @MainActor () throws -> Void) async throws -> ComputerUseApplicationIdentity
    typealias CaptureWindows = @MainActor (ComputerUseApplicationIdentity) throws -> WindowSnapshot
    typealias CaptureRetainedWindow = @MainActor (ComputerUseApplicationIdentity, Window) throws -> WindowSnapshot

    static let defaultNewWindowWaitBudget: Duration = .seconds(30)
    private static let nativeWindowCaptureBudget: Duration = .seconds(4)

    private final class RunState {
        let taskID: String
        let goalDigest: String
        let sessionTaskID: String
        let handler: ComputerUseDefaultBrowserTarget.Handler
        var app: ComputerUseApplicationIdentity?
        var before: WindowSnapshot?
        var target: Window?
        var saved: ComputerUseTaskJournal?
        var execution: ComputerUseTaskExecution?
        var busy = false
        var uncertain = false
        var currentFileOpenPanel: FileOpenPanel?
        var currentActionBounds: CGRect?
        var navigationDispatches: Set<String> = []
        var navigationReturnsCompleted: Set<String> = []

        init(taskID: String, goalDigest: String, sessionTaskID: String,
             handler: ComputerUseDefaultBrowserTarget.Handler) {
            self.taskID = taskID
            self.goalDigest = goalDigest
            self.sessionTaskID = sessionTaskID
            self.handler = handler
        }
    }

    @MainActor private final class CaptureDiagnosticState {
        var reason: String?
        var axErrorCode: Int?
        var elapsedMs: Int?
        var structureFailureAttribute: String?
        var structureFailureKind: String?
        var structureFailureAXErrorCode: Int?

        func reset() {
            reason = nil; axErrorCode = nil; elapsedMs = nil
            structureFailureAttribute = nil; structureFailureKind = nil; structureFailureAXErrorCode = nil
        }

        func record(_ message: String) {
            let token = message.split(separator: " ").first(where: { $0.hasPrefix("reason=") })
                .map { String($0.dropFirst("reason=".count)) }
                ?? (message.hasPrefix("phase=ax_attribute_read_failure") ? "bounds_ax_read_failure" : nil)
            let allowed: Set<String> = ["capture_cancelled", "frontmost_unavailable", "frontmost_process_mismatch",
                "frontmost_identity_mismatch", "windows_read", "windows_malformed", "windows_unconvertible",
                "focused_window_read", "focused_window_malformed", "focused_window_unconvertible",
                "capture_deadline", "final_frontmost_unavailable", "final_frontmost_changed",
                "retained_target_missing_or_ambiguous", "retained_target_pid", "pid", "bounds_read",
                "bounds_deadline", "bounds_type", "bounds_malformed", "focused_duplicate",
                "duplicate_id", "duplicate_element", "bounds_ax_read_failure",
                "startup_role_unclassified", "focused_transient_surface",
                "focused_retained_fallback_unverified", "focused_retained_metadata_read",
                "focused_retained_fallback_structure_unreadable", "focused_retained_structure_read"]
            if let token, allowed.contains(token) { reason = token }
            if let field = message.split(separator: " ").first(where: { $0.hasPrefix("ax_error=") }),
               let code = Int(field.dropFirst("ax_error=".count)), (-65_535...65_535).contains(code) {
                axErrorCode = code
            }
            if let field = message.split(separator: " ").first(where: { $0.hasPrefix("elapsed_ms=") }),
               let duration = Int(field.dropFirst("elapsed_ms=".count)), (0...2_000).contains(duration) {
                elapsedMs = duration
            }
            if structureFailureAttribute == nil,
               let field = message.split(separator: " ").first(where: { $0.hasPrefix("structure_attribute=") }) {
                let value = String(field.dropFirst("structure_attribute=".count))
                let allowed = ["AXRole", "AXSubrole", "AXPosition", "AXSize", "AXChildren", "AXSheets",
                    "AXParent", "AXIdentifier", "AXURL", "AXFocusedUIElement", "AXValue",
                    "AXSelectedTextRange", "AXEnabled", "AXSelectedRows", "AXSelectedChildren", "other"]
                if allowed.contains(value) { structureFailureAttribute = value }
                if let kind = message.split(separator: " ").first(where: { $0.hasPrefix("structure_kind=") }) {
                    let value = String(kind.dropFirst("structure_kind=".count))
                    if ["read_error", "type_mismatch"].contains(value) { structureFailureKind = value }
                }
                if let code = message.split(separator: " ").first(where: { $0.hasPrefix("structure_ax_error=") }),
                   let value = Int(code.dropFirst("structure_ax_error=".count)), (-65_535...65_535).contains(value) {
                    structureFailureAXErrorCode = value
                }
            }
        }
    }

    private let journalDirectory: URL
    private let resolveHandler: ResolveHandler
    private let launchApplication: LaunchApplication
    private let captureWindows: CaptureWindows
    private let captureRetainedWindow: CaptureRetainedWindow?
    private let makeStore: (URL) throws -> ComputerUseTaskJournalStore
    private let newWindowWaitBudget: Duration
    private let captureDiagnosticProvider: @MainActor () -> String?
    private let captureDiagnosticAXErrorProvider: @MainActor () -> Int?
    private let captureDiagnosticElapsedMsProvider: @MainActor () -> Int?
    private let captureDiagnosticStructureFailureProvider: @MainActor () -> (String?, String?, Int?)
    private let captureWindowsDiagnostic: @MainActor (String) -> Void
    private var runState: RunState?
    private(set) var lastValidationPhaseForDiagnostics: ValidationPhase?
    private(set) var lastWindowTransitionDiagnostic: String?
    /// Failure-only scalar evidence for the bounded Safari address-focus wait.
    /// Contains no page text, URL, AX label, or identifier.
    var currentWindow: Window? { runState?.target }
    var currentFileOpenPanel: FileOpenPanel? { runState?.currentFileOpenPanel }
    var currentActionBounds: CGRect? { runState?.currentActionBounds }
    var lastCaptureReasonForDiagnostics: String? { captureDiagnosticProvider() }
    var lastCaptureAXErrorCodeForDiagnostics: Int? { captureDiagnosticAXErrorProvider() }
    var lastCaptureElapsedMsForDiagnostics: Int? { captureDiagnosticElapsedMsProvider() }
    var lastCaptureStructureFailureForDiagnostics: (attribute: String?, kind: String?, axErrorCode: Int?) {
        let value = captureDiagnosticStructureFailureProvider()
        return (value.0, value.1, value.2)
    }

    convenience init(journalDirectory: URL,
                      captureWindowsDiagnostic: @escaping @MainActor (String) -> Void = { _ in }) throws {
        let captureDiagnosticState = CaptureDiagnosticState()
        let recordDiagnostic: @MainActor (String) -> Void = { message in
            captureDiagnosticState.record(message)
            captureWindowsDiagnostic(message)
        }
        try self.init(journalDirectory: journalDirectory,
            resolveHandler: {
                guard let handler = ComputerUseDefaultBrowserTarget.currentDefaultHTTPSHandler() else {
                    throw ComputerUseDefaultBrowserTarget.Failure.noDefaultHandler
                }
                return handler
            },
            launchApplication: Self.launchVerifiedHandler,
            captureWindows: { application in
                captureDiagnosticState.reset()
                return try Self.captureWindowsForApplication(application,
                    startupDocumentInventory: application.bundleIdentifier == "com.apple.Safari",
                    diagnostic: recordDiagnostic)
            },
            captureRetainedWindow: { application, target in
                captureDiagnosticState.reset()
                return try Self.captureWindowsForApplication(application, expectedWindow: target,
                    diagnostic: recordDiagnostic)
            }, captureDiagnosticProvider: { captureDiagnosticState.reason },
            captureDiagnosticAXErrorProvider: { captureDiagnosticState.axErrorCode },
            captureDiagnosticElapsedMsProvider: { captureDiagnosticState.elapsedMs },
            captureDiagnosticStructureFailureProvider: {
                (captureDiagnosticState.structureFailureAttribute, captureDiagnosticState.structureFailureKind,
                 captureDiagnosticState.structureFailureAXErrorCode)
            },
            captureWindowsDiagnostic: captureWindowsDiagnostic)
    }

    init(journalDirectory: URL,
         resolveHandler: @escaping ResolveHandler,
         launchApplication: @escaping LaunchApplication,
         captureWindows: @escaping CaptureWindows,
         makeStore: @escaping (URL) throws -> ComputerUseTaskJournalStore = { try .init(directory: $0) },
         newWindowWaitBudget: Duration = ComputerUseDefaultBrowserSession.defaultNewWindowWaitBudget,
         captureRetainedWindow: CaptureRetainedWindow? = nil,
         captureDiagnosticProvider: @escaping @MainActor () -> String? = { nil },
         captureDiagnosticAXErrorProvider: @escaping @MainActor () -> Int? = { nil },
         captureDiagnosticElapsedMsProvider: @escaping @MainActor () -> Int? = { nil },
         captureDiagnosticStructureFailureProvider: @escaping @MainActor () -> (String?, String?, Int?) = { (nil, nil, nil) },
         captureWindowsDiagnostic: @escaping @MainActor (String) -> Void = { _ in }) throws {
        self.journalDirectory = journalDirectory
        self.resolveHandler = resolveHandler
        self.launchApplication = launchApplication
        self.captureWindows = captureWindows
        self.captureRetainedWindow = captureRetainedWindow
        self.makeStore = makeStore
        self.newWindowWaitBudget = newWindowWaitBudget
        self.captureDiagnosticProvider = captureDiagnosticProvider
        self.captureDiagnosticAXErrorProvider = captureDiagnosticAXErrorProvider
        self.captureDiagnosticElapsedMsProvider = captureDiagnosticElapsedMsProvider
        self.captureDiagnosticStructureFailureProvider = captureDiagnosticStructureFailureProvider
        self.captureWindowsDiagnostic = captureWindowsDiagnostic
    }

    func ensure(taskID: String, goal: String, tools: ComputerUseHostTools) async throws -> Window {
        try Task.checkCancellation()
        try tools.requireActive()
        guard !taskID.isEmpty, !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.changedTaskOrGoal
        }
        let goalDigest = ComputerUseTaskJournalStore.digest(goal)
        if let runState {
            guard runState.taskID == taskID, runState.goalDigest == goalDigest else {
                throw Failure.changedTaskOrGoal
            }
            guard !runState.busy else { throw ComputerUseTaskExecutionError.alreadyExecuting }
            if runState.target != nil {
                try validate(taskID: taskID, goal: goal, tools: tools)
                guard let refreshed = runState.target else { throw Failure.targetLost }
                return refreshed
            }
            guard !runState.uncertain else { throw Failure.journalUncertain }
            guard let execution = runState.execution,
                  execution.journal.statuses.allSatisfy({ $0 == .planned }) else {
                throw Failure.journalUncertain
            }
            // No attempted action can return to planned, so this branch is
            // reachable only while the durable transaction proves no dispatch.
            runState.busy = true
            defer { runState.busy = false }
            return try await run(execution, state: runState, tools: tools)
        }

        let handler = try resolveHandler()
        try Task.checkCancellation()
        try tools.requireActive()
        let sessionTaskID = ComputerUseTaskContract.digest(["default-browser-session-v1", taskID])
        let state = RunState(taskID: taskID, goalDigest: goalDigest,
            sessionTaskID: sessionTaskID, handler: handler)
        runState = state
        do {
            try makeExecution(state: state, goalDigest: goalDigest, tools: tools)
        } catch {
            runState = nil
            if let error = error as? ComputerUseTaskExecutionError, error == .journalMismatch {
                throw Failure.changedTaskOrGoal
            }
            throw error
        }
        guard let execution = state.execution else { throw ComputerUseTaskExecutionError.invalidContract }
        if execution.journal.statuses.contains(where: { $0 != .planned }) {
            state.uncertain = true
            throw Failure.journalUncertain
        }
        state.busy = true
        defer { state.busy = false }
        do {
            return try await run(execution, state: state, tools: tools)
        } catch {
            if execution.journal.statuses.contains(where: { $0 != .planned }) { state.uncertain = true }
            throw error
        }
    }

    func validate(taskID: String, goal: String, tools: ComputerUseHostTools) throws {
        lastValidationPhaseForDiagnostics = nil
        try Task.checkCancellation()
        try tools.requireActive()
        guard let state = runState, state.taskID == taskID,
              state.goalDigest == ComputerUseTaskJournalStore.digest(goal),
              let expected = state.target, let app = state.app else {
            lastValidationPhaseForDiagnostics = .target
            throw Failure.changedTaskOrGoal
        }
        let current: WindowSnapshot
        lastValidationPhaseForDiagnostics = .capture
        current = try captureForValidation(application: app, target: expected,
            taskID: taskID, goalDigest: ComputerUseTaskJournalStore.digest(goal), tools: tools)
        lastValidationPhaseForDiagnostics = .target
        guard current.application == app,
              let focused = current.windows.first(where: { $0.id == expected.id }),
              Self.sameWindow(focused, expected) else {
            throw current.hasSheets ? Failure.authenticationHandoff : Failure.targetLost
        }
        let panel = current.fileOpenPanel
        lastValidationPhaseForDiagnostics = .sheet
        if current.hasSheets {
            guard !current.hasUnrecognizedSheets, let panel,
                  panel.parentWindowID == expected.id,
                  CFEqual(panel.parentWindowElement, expected.accessibilityElement) else {
                throw Failure.authenticationHandoff
            }
            lastValidationPhaseForDiagnostics = .focus
            guard current.focusedWindowID == expected.id || panel.isFocused else {
                throw Failure.authenticationHandoff
            }
        } else {
            guard !current.hasUnrecognizedSheets, panel == nil else { throw Failure.targetLost }
            lastValidationPhaseForDiagnostics = .focus
            guard current.focusedWindowID == expected.id else { throw Failure.targetLost }
        }
        state.target = focused // Refresh current geometry; bounds are not window authority.
        state.currentFileOpenPanel = panel
        state.currentActionBounds = panel?.actionBounds ?? focused.identity.bounds
        lastValidationPhaseForDiagnostics = .complete
    }

    private func isTransientValidationCaptureFailure(_ error: Error) -> Bool {
        guard lastValidationPhaseForDiagnostics == .capture,
              lastCaptureAXErrorCodeForDiagnostics == Int(AXError.cannotComplete.rawValue),
              let failure = error as? Failure,
              let reason = lastCaptureReasonForDiagnostics else { return false }
        switch (failure, reason) {
        case (.targetLost, "windows_read"), (.targetLost, "focused_window_read"),
             (.targetLost, "focused_retained_metadata_read"),
             (.targetLost, "focused_retained_structure_read"),
             (.ambiguousWindows, "bounds_read"):
            return true
        default:
            return false
        }
    }

    static func uniquelyListedRetainedWindow(_ target: AXUIElement,
                                             in windows: [AXUIElement]) -> Bool {
        windows.filter { CFEqual($0, target) }.count == 1
    }

    static func matchingCGWindowNumber(target: Window, windowInfo: [[String: Any]]) -> CGWindowID? {
        guard let firstOwnedAppWindow = windowInfo.first(where: { info in
            (info[kCGWindowOwnerPID as String] as? Int) == Int(target.application.processIdentifier)
                && (info[kCGWindowLayer as String] as? Int) == 0
        }),
              let number = firstOwnedAppWindow[kCGWindowNumber as String] as? NSNumber,
              let signedNumber = Int32(exactly: number.int64Value), signedNumber > 0,
              let rawBounds = firstOwnedAppWindow[kCGWindowBounds as String] as? [String: Any] else { return nil }
        var bounds = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(rawBounds as CFDictionary, &bounds),
              CGRectEqualToRect(bounds, target.identity.bounds) else { return nil }
        return CGWindowID(signedNumber)
    }

    private func run(_ execution: ComputerUseTaskExecution, state: RunState,
                     tools: ComputerUseHostTools) async throws -> Window {
        try Task.checkCancellation()
        try tools.requireActive()
        try await execution.run()
        guard state.target != nil else { throw Failure.noNewFocusedWindow }
        try validate(taskID: state.taskID, goalDigest: state.goalDigest, tools: tools)
        guard let refreshed = state.target else { throw Failure.targetLost }
        return refreshed
    }

    private func validate(taskID: String, goalDigest: String, tools: ComputerUseHostTools) throws {
        lastValidationPhaseForDiagnostics = nil
        guard let state = runState, state.taskID == taskID, state.goalDigest == goalDigest,
              let target = state.target, let app = state.app else {
            lastValidationPhaseForDiagnostics = .target
            throw Failure.targetLost
        }
        try tools.requireActive()
        let current: WindowSnapshot
        lastValidationPhaseForDiagnostics = .capture
        current = try captureForValidation(application: app, target: target,
            taskID: taskID, goalDigest: goalDigest, tools: tools)
        lastValidationPhaseForDiagnostics = .target
        guard current.application == app,
              let focused = current.windows.first(where: { $0.id == target.id }),
              Self.sameWindow(focused, target) else {
            throw current.hasSheets ? Failure.authenticationHandoff : Failure.targetLost
        }
        let panel = current.fileOpenPanel
        lastValidationPhaseForDiagnostics = .sheet
        if current.hasSheets {
            guard !current.hasUnrecognizedSheets, let panel,
                  panel.parentWindowID == target.id,
                  CFEqual(panel.parentWindowElement, target.accessibilityElement) else {
                throw Failure.authenticationHandoff
            }
            lastValidationPhaseForDiagnostics = .focus
            guard current.focusedWindowID == target.id || panel.isFocused else {
                throw Failure.authenticationHandoff
            }
        } else {
            guard !current.hasUnrecognizedSheets, panel == nil else { throw Failure.targetLost }
            lastValidationPhaseForDiagnostics = .focus
            guard current.focusedWindowID == target.id else { throw Failure.targetLost }
        }
        state.target = focused // Refresh current geometry; bounds are not window authority.
        state.currentFileOpenPanel = panel
        state.currentActionBounds = panel?.actionBounds ?? focused.identity.bounds
        lastValidationPhaseForDiagnostics = .complete
    }

    private func captureForValidation(application: ComputerUseApplicationIdentity,
                                      target: Window, taskID: String, goalDigest: String,
                                      tools: ComputerUseHostTools) throws -> WindowSnapshot {
        func capture() throws -> WindowSnapshot {
            if let captureRetainedWindow {
                return try captureRetainedWindow(application, target)
            }
            return try captureWindows(application)
        }
        var retryDeadline: ContinuousClock.Instant?
        for attempt in 0..<3 {
            let snapshot: WindowSnapshot
            do {
                snapshot = try capture()
            } catch {
                guard attempt < 2, isTransientValidationCaptureFailure(error) else {
                    throw error
                }
                try authorizeValidationRecapture(application: application, tools: tools,
                    deadline: &retryDeadline, originalError: error)
                continue
            }
            guard attempt < 2,
                  Self.isTransientUnfocusedRetainedWindowSnapshot(snapshot, application: application,
                    target: target) else { return snapshot }
            try authorizeValidationRecapture(application: application, tools: tools,
                deadline: &retryDeadline, originalError: Failure.targetLost)
        }
        throw Failure.targetLost
    }

    private static func isTransientUnfocusedRetainedWindowSnapshot(
        _ snapshot: WindowSnapshot,
        application: ComputerUseApplicationIdentity,
        target: Window
    ) -> Bool {
        guard snapshot.application == application,
              !snapshot.hasSheets, !snapshot.hasUnrecognizedSheets,
              snapshot.fileOpenPanel == nil,
              snapshot.focusedWindowID != target.id,
              uniqueWindows(snapshot.windows),
              snapshot.windows.filter({ sameWindow($0, target) }).count == 1 else { return false }
        return true
    }

    private func authorizeValidationRecapture(
        application: ComputerUseApplicationIdentity,
        tools: ComputerUseHostTools,
        deadline: inout ContinuousClock.Instant?,
        originalError: Error
    ) throws {
        let now = ContinuousClock.now
        let limit = deadline ?? now.advanced(by: .seconds(2))
        deadline = limit
        guard now < limit else { throw originalError }
        try Task.checkCancellation()
        try tools.requireActive()
        let frontmost = tools.frontmostApplicationSnapshot()
        guard frontmost.identityIsAuthoritative, frontmost.identity == application else {
            throw originalError
        }
        try Task.checkCancellation()
        try tools.requireActive()
        guard ContinuousClock.now < limit else { throw originalError }
    }

    private func makeExecution(state: RunState, goalDigest: String,
                               tools: ComputerUseHostTools) throws {
        let handlerDigest = ComputerUseTaskContract.digest([
            state.handler.bundleIdentifier,
            state.handler.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path,
        ])
        let authority = ComputerUseTaskContract.digest([state.taskID, goalDigest, handlerDigest])
        let contract = try ComputerUseTaskContract(
            taskID: state.sessionTaskID,
            promptDigest: goalDigest,
            entities: [.init(id: "browser", authorityDigest: authority)],
            predicates: [
                .init(id: "handler-current", entityID: "browser", kind: "https-handler", expectedDigest: handlerDigest),
                .init(id: "foreground-ready", entityID: "browser", kind: "signed-foreground-window-snapshot", expectedDigest: authority),
                .init(id: "new-window", entityID: "browser", kind: "focused-window", expectedDigest: authority),
            ],
            steps: [.init(id: "create-window", dependencies: [],
                operation: .init(capabilityID: "defaultBrowser.createWindow", entityID: "browser",
                    payloadDigest: authority, payloadVersion: 1),
                preconditions: ["handler-current", "foreground-ready"], postconditions: ["new-window"])],
            invariants: ["handler-current"], outcomes: ["new-window"])
        let store = try makeStore(journalDirectory)
        state.saved = try store.load(taskID: state.sessionTaskID)
        if let saved = state.saved, saved.promptDigest != goalDigest {
            throw ComputerUseTaskExecutionError.journalMismatch
        }
        let resolveHandler = self.resolveHandler
        let launchApplication = self.launchApplication
        let captureWindows = self.captureWindows
        let captureWindowsDiagnostic = self.captureWindowsDiagnostic
        let recordWindowTransition: @MainActor (String) -> Void = { [weak self] message in
            self?.lastWindowTransitionDiagnostic = message
            captureWindowsDiagnostic(message)
        }
        let execution = try ComputerUseTaskExecution(contract: contract, recovered: state.saved,
            observe: { [weak state] predicate in
                guard let state else { throw ComputerUseTaskExecutionError.invalidContract }
                try Task.checkCancellation()
                try tools.requireActive()
                switch predicate.id {
                case "handler-current": return try resolveHandler() == state.handler
                case "foreground-ready":
                    guard try resolveHandler() == state.handler else { throw Failure.interrupted }
                    let app = try await launchApplication(state.handler, {
                        try Task.checkCancellation()
                        try tools.requireActive()
                    })
                    try Task.checkCancellation()
                    try tools.requireActive()
                    try Self.validate(application: app, matches: state.handler)
                    state.app = app
                    if app.bundleIdentifier == "com.apple.Safari" {
                        recordWindowTransition("phase=startup_foreground_read")
                    }
                    let before = try await Self.waitForForegroundSnapshot(
                        app: app, tools: tools, captureWindows: captureWindows)
                    if app.bundleIdentifier == "com.apple.Safari" {
                        recordWindowTransition("phase=startup_foreground_ready")
                    }
                    state.before = before
                    return true
                case "new-window":
                    guard let app = state.app, let before = state.before, let target = state.target else { return false }
                    let current = try await Self.waitForNewFocusedWindow(
                        before: before, app: app, tools: tools, captureWindows: captureWindows,
                        budget: self.newWindowWaitBudget,
                        diagnostic: recordWindowTransition)
                    return Self.sameWindowReference(current, target, in: app)
                default: return false
                }
            }, perform: { [weak state] step, _ in
                guard let state else { throw ComputerUseTaskExecutionError.invalidContract }
                guard step.id == "create-window" else { throw ComputerUseTaskExecutionError.invalidContract }
                try Task.checkCancellation()
                try tools.requireActive()
                guard let app = state.app, let before = state.before else {
                    throw ComputerUseTaskExecutionError.preconditionFailed("foreground-ready")
                }
                try Task.checkCancellation()
                try tools.requireActive()
                guard try resolveHandler() == state.handler else { throw Failure.interrupted }
                try Self.validate(application: app, matches: state.handler)
                if app.bundleIdentifier == "com.apple.Safari" {
                    try tools.performNativeBrowserHostCommand(.newWindow,
                        expectedApplication: app) { [weak state, captureWindows] in
                            try Task.checkCancellation()
                            try tools.requireActive()
                            guard try resolveHandler() == state?.handler,
                                  let state, let currentApp = state.app, currentApp == app,
                                  let originalBefore = state.before else {
                                throw Failure.interrupted
                            }
                            recordWindowTransition("phase=startup_pre_effect_read")
                            try Self.requireSameStartupSnapshotAtEffectBoundary(
                                originalBefore, app: currentApp, handler: state.handler,
                                tools: tools, resolveHandler: resolveHandler, captureWindows: captureWindows)
                            recordWindowTransition("phase=startup_pre_effect_verified")
                        }
                    recordWindowTransition("phase=startup_cmd_n_returned")
                } else {
                    let action = ComputerUsePredictedAction.key(usage: 0x11, modifiers: 1 << 3)
                    var effectBegan = false
                    for attempt in 0..<2 {
                        try Task.checkCancellation()
                        try tools.requireActive()
                        guard try resolveHandler() == state.handler,
                              try Self.sameSnapshot(before, captureWindows(app)) else { throw Failure.interrupted }
                        do {
                            let fingerprint = try tools.prepareNativeActionFingerprint(for: action)
                            guard try Self.sameSnapshot(before, captureWindows(app)) else { throw Failure.interrupted }
                            try Task.checkCancellation()
                            try tools.requireActive()
                            try await tools.performNativeAction(action, fingerprint: fingerprint) { [weak state, captureWindows] in
                                try Task.checkCancellation()
                                try tools.requireActive()
                                guard let state, let app = state.app, let originalBefore = state.before else {
                                    throw Failure.interrupted
                                }
                                try Self.requireSameStartupSnapshotAtEffectBoundary(
                                    originalBefore, app: app, handler: state.handler,
                                    tools: tools, resolveHandler: resolveHandler, captureWindows: captureWindows)
                                effectBegan = true
                            }
                            break
                        } catch ComputerUseHostTools.ToolError.approvalTargetChanged {
                            try Task.checkCancellation()
                            try tools.requireActive()
                            guard !effectBegan, attempt == 0 else {
                                throw ComputerUseHostTools.ToolError.approvalTargetChanged
                            }
                            guard try resolveHandler() == state.handler,
                                  try Self.sameSnapshot(before, captureWindows(app)) else { throw Failure.interrupted }
                            await Task.yield()
                            try Task.checkCancellation()
                            try tools.requireActive()
                            guard try resolveHandler() == state.handler,
                                  try Self.sameSnapshot(before, captureWindows(app)) else { throw Failure.interrupted }
                        }
                    }
                }
                state.target = try await Self.waitForNewFocusedWindow(
                    before: before, app: app, tools: tools, captureWindows: captureWindows,
                    budget: self.newWindowWaitBudget,
                    diagnostic: recordWindowTransition)
            }, persist: { [weak state, store] journal in
                guard let state else { throw ComputerUseTaskExecutionError.invalidContract }
                try Task.checkCancellation()
                try store.save(journal, replacing: state.saved)
                state.saved = journal
            }, acquireExecutionLease: { [weak state, store] in
                guard let state else { throw ComputerUseTaskExecutionError.invalidContract }
                let current = try store.load(taskID: state.sessionTaskID)
                let lease = try store.acquireExecution(taskID: state.sessionTaskID, expected: current)
                state.saved = current
                return lease
            }, reloadJournal: { [weak state, store] in
                guard let state else { throw ComputerUseTaskExecutionError.invalidContract }
                let current = try store.load(taskID: state.sessionTaskID)
                if let current { try store.confirmRecoveredProgress(current) }
                state.saved = current
                return current
            }, assertOwnership: {
                try Task.checkCancellation()
                try tools.requireActive()
            })
        state.execution = execution
    }

    static func uniqueWindows(_ windows: [Window]) -> Bool {
        let identifiers = windows.map(\.id)
        guard identifiers.count == Set(identifiers).count else { return false }
        for index in windows.indices {
            for other in windows.indices where other > index {
                if CFEqual(windows[index].accessibilityElement, windows[other].accessibilityElement) { return false }
            }
        }
        return true
    }

    static func startupWindowClassification(role: String?, subrole: String?) -> StartupWindowClassification {
        guard let role else { return .unknown }
        if role == "AXWindow" {
            switch subrole {
            case "AXStandardWindow": return .document
            case "AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXSystemFloatingWindow":
                return .transientSurface
            default: return .unknown
            }
        }
        switch role {
        case "AXDialog", "AXPopover", "AXPopoverWindow", "AXSheet", "AXMenu", "AXMenuBar",
             "AXHelpTag", "AXSystemDialog", "AXScrollArea":
            // Safari can expose a non-document AXScrollArea in its AXWindows list.
            return .transientSurface
        default:
            return .unknown
        }
    }

    static func safariStableWindowID(processIdentifier: pid_t, accessibilityHash: CFHashCode,
                                     safariAXIdentifier: String?) -> String {
        if let uuid = parsedSafariWindowUUID(safariAXIdentifier) {
            return "\(processIdentifier):safari-uuid:\(uuid.uuidString.lowercased())"
        }
        return "\(processIdentifier):ax-hash:\(accessibilityHash)"
    }

    static func capturedWindowID(application: ComputerUseApplicationIdentity, element: AXUIElement,
                                 accessibilityHash: CFHashCode, safariAXIdentifier: String?,
                                 retainedWindow: Window?) -> String? {
        if let retainedWindow {
            var elementPID: pid_t = 0
            guard retainedWindow.application == application,
                  retainedWindow.identity.applicationProcessIdentifier == application.processIdentifier,
                  AXUIElementGetPid(element, &elementPID) == .success,
                  elementPID == application.processIdentifier,
                  CFEqual(retainedWindow.accessibilityElement, element) else { return nil }
            return retainedWindow.id
        }
        return safariStableWindowID(processIdentifier: application.processIdentifier,
            accessibilityHash: accessibilityHash, safariAXIdentifier: safariAXIdentifier)
    }

    private static func parsedSafariWindowUUID(_ identifier: String?) -> UUID? {
        guard let identifier, identifier.utf8.count <= 256,
              identifier.hasPrefix("SafariWindow?") else { return nil }
        let fields = identifier.dropFirst("SafariWindow?".count)
            .split(separator: "&", omittingEmptySubsequences: false)
        var secureValues: [String] = []
        var uuidValues: [String] = []
        for field in fields {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            switch pair[0] {
            case "IsSecure": secureValues.append(String(pair[1]))
            case "UUID": uuidValues.append(String(pair[1]))
            default: return nil
            }
        }
        guard secureValues.count == 1,
              ["true", "false"].contains(secureValues[0].lowercased()),
              uuidValues.count == 1, uuidValues[0].utf8.count == 36,
              let uuid = UUID(uuidString: uuidValues[0]),
              uuid.uuidString.caseInsensitiveCompare(uuidValues[0]) == .orderedSame else { return nil }
        return uuid
    }

    private static func sameWindow(_ lhs: Window, _ rhs: Window) -> Bool {
        // AX reference plus the exact app launch identifies the window. Bounds
        // are refreshed metadata and may change when the browser lays it out.
        lhs.id == rhs.id && lhs.application == rhs.application
            && CFEqual(lhs.accessibilityElement, rhs.accessibilityElement)
    }

    private static func sameWindowReference(_ lhs: Window, _ rhs: Window,
                                            in application: ComputerUseApplicationIdentity) -> Bool {
        lhs.application == application && rhs.application == application
            && lhs.identity.applicationProcessIdentifier == application.processIdentifier
            && rhs.identity.applicationProcessIdentifier == application.processIdentifier
            && CFEqual(lhs.accessibilityElement, rhs.accessibilityElement)
    }

    private static func sameSnapshot(_ lhs: WindowSnapshot, _ rhs: WindowSnapshot) throws -> Bool {
        guard lhs.application == rhs.application, !lhs.hasSheets, !rhs.hasSheets,
              uniqueWindows(lhs.windows), uniqueWindows(rhs.windows),
              lhs.windows.count == rhs.windows.count else { return false }
        if lhs.focusedWindowID == nil || rhs.focusedWindowID == nil {
            guard lhs.focusedWindowID == nil, rhs.focusedWindowID == nil else { return false }
        } else {
            guard let lhsFocused = lhs.windows.first(where: { $0.id == lhs.focusedWindowID }),
                  let rhsFocused = rhs.windows.first(where: { $0.id == rhs.focusedWindowID }),
                  sameWindowReference(lhsFocused, rhsFocused, in: lhs.application) else { return false }
        }
        return lhs.windows.allSatisfy { prior in
            rhs.windows.filter { sameWindowReference($0, prior, in: lhs.application) }.count == 1
        }
    }

    /// Reobserve once at the final effect boundary when Safari's AX window
    /// inventory is temporarily ambiguous. The retry is read-only and only
    /// proceeds after the signed foreground app and current default handler
    /// are revalidated; the exact original snapshot must still match.
    private static func requireSameStartupSnapshotAtEffectBoundary(
        _ before: WindowSnapshot,
        app: ComputerUseApplicationIdentity,
        handler: ComputerUseDefaultBrowserTarget.Handler,
        tools: ComputerUseHostTools,
        resolveHandler: ResolveHandler,
        captureWindows: CaptureWindows
    ) throws {
        do {
            guard try sameSnapshot(before, captureWindows(app)) else { throw Failure.interrupted }
        } catch Failure.ambiguousWindows {
            try Task.checkCancellation()
            try tools.requireActive()
            guard try resolveHandler() == handler else { throw Failure.interrupted }
            try validate(application: app, matches: handler)
            let frontmost = tools.frontmostApplicationSnapshot()
            guard frontmost.identityIsAuthoritative,
                  let current = frontmost.identity,
                  current == app,
                  current.codeIdentity == app.codeIdentity else { throw Failure.interrupted }
            let recaptured = try captureWindows(app)
            guard try sameSnapshot(before, recaptured) else { throw Failure.interrupted }
        }
    }

    private static func singleNewWindow(before: WindowSnapshot, after: WindowSnapshot) -> Window? {
        guard before.application == after.application, !before.hasSheets, !after.hasSheets,
              uniqueWindows(before.windows), uniqueWindows(after.windows),
              after.windows.count == before.windows.count + 1 else { return nil }
        for prior in before.windows {
            guard after.windows.filter({ sameWindowReference($0, prior, in: before.application) }).count == 1 else { return nil }
        }
        let added = after.windows.filter { candidate in
            !before.windows.contains(where: { sameWindowReference($0, candidate, in: before.application) })
        }
        return added.count == 1 ? added[0] : nil
    }

    private static func newFocusedWindow(before: WindowSnapshot, after: WindowSnapshot) -> Window? {
        guard let added = singleNewWindow(before: before, after: after),
              after.focusedWindowID == added.id else { return nil }
        return added
    }

    private static func isTransientMissingBaselineWindow(before: WindowSnapshot,
                                                          after: WindowSnapshot) -> Bool {
        guard before.application == after.application,
              !before.hasSheets, !after.hasSheets,
              !after.hasUnrecognizedSheets, after.fileOpenPanel == nil,
              before.windows.count > 1,
              after.windows.count == before.windows.count,
              uniqueWindows(before.windows), uniqueWindows(after.windows),
              let focused = after.windows.first(where: { $0.id == after.focusedWindowID }) else { return false }
        let added = after.windows.filter { candidate in
            !before.windows.contains(where: { sameWindowReference($0, candidate, in: before.application) })
        }
        guard added.count == 1, sameWindowReference(added[0], focused, in: before.application) else { return false }
        let removed = before.windows.filter { prior in
            !after.windows.contains(where: { sameWindowReference($0, prior, in: before.application) })
        }
        guard removed.count == 1 else { return false }
        return before.windows.filter { prior in
            after.windows.contains(where: { sameWindowReference($0, prior, in: before.application) })
        }.count == before.windows.count - 1
    }

    private static func isExactlyOneNewWindow(before: WindowSnapshot, after: WindowSnapshot, target: Window) -> Bool {
        guard let current = newFocusedWindow(before: before, after: after) else { return false }
        return sameWindowReference(current, target, in: before.application)
    }

    private static func validate(application: ComputerUseApplicationIdentity,
                                 matches handler: ComputerUseDefaultBrowserTarget.Handler) throws {
        let path = handler.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard application.bundleIdentifier == handler.bundleIdentifier else {
            throw ComputerUseDefaultBrowserTarget.Failure.handlerIdentityMismatch
        }
        guard let code = application.codeIdentity else {
            throw ComputerUseDefaultBrowserTarget.Failure.applicationNotCodeVerified
        }
        guard code.bundleIdentifier == handler.bundleIdentifier, code.canonicalBundlePath == path else {
            throw ComputerUseDefaultBrowserTarget.Failure.handlerIdentityMismatch
        }
    }

    private static func launchVerifiedHandler(
        _ handler: ComputerUseDefaultBrowserTarget.Handler,
        beforeOpen: @escaping @MainActor () throws -> Void
    ) async throws -> ComputerUseApplicationIdentity {
        let canonicalURL = handler.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalURL.isFileURL, canonicalURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              Bundle(url: canonicalURL)?.bundleIdentifier == handler.bundleIdentifier else {
            throw ComputerUseDefaultBrowserTarget.Failure.handlerIdentityMismatch
        }
        let reviewedIDs = ComputerUseApplicationIdentity.allReviewedBundleIdentifiers
        let pinned = reviewedIDs.contains(handler.bundleIdentifier)
            ? try ComputerUseReviewedApplicationCodeVerifier.verifyStatic(
                applicationURL: canonicalURL, expectedBundleIdentifiers: [handler.bundleIdentifier])
            : nil
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        return try await ComputerUseApplicationOpenOperation.run { complete in
            // Check task permission before taking the global open lease:
            // HostTools intentionally suspends ordinary input while it is held.
            try beforeOpen()
            let flight = try ComputerUseApplicationOpenOperation.beginNativeOpen()
            NSWorkspace.shared.openApplication(at: canonicalURL, configuration: configuration) { app, error in
                defer { ComputerUseApplicationOpenOperation.finishNativeOpen(flight) }
                guard error == nil, let app,
                      let proof = ComputerUseReviewedApplicationCodeVerifier
                        .proofForRunningApplication(runningApplication: app),
                      let identity = ComputerUseApplicationIdentity(runningApplication: app, codeIdentity: proof),
                      identity.bundleIdentifier == handler.bundleIdentifier,
                      proof.canonicalBundlePath == canonicalURL.path else {
                    complete(.failure(ComputerUseDefaultBrowserTarget.Failure.openFailed))
                    return
                }
                do {
                    if let pinned {
                        let pinnedProof = try ComputerUseReviewedApplicationCodeVerifier.verifyRunning(app, against: pinned)
                        guard pinnedProof == proof else { throw ComputerUseDefaultBrowserTarget.Failure.handlerIdentityMismatch }
                    }
                    complete(.success(identity))
                } catch { complete(.failure(error)) }
            }
        }
    }

    private static func waitForForegroundSnapshot(
        app: ComputerUseApplicationIdentity, tools: ComputerUseHostTools,
        captureWindows: @escaping CaptureWindows
    ) async throws -> WindowSnapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try tools.requireActive()
            do {
                let snapshot = try captureWindows(app)
                guard snapshot.application == app else { throw Failure.targetLost }
                guard !snapshot.hasSheets else { throw Failure.authenticationHandoff }
                guard Self.uniqueWindows(snapshot.windows) else { throw Failure.ambiguousWindows }
                if let focused = snapshot.focusedWindowID,
                   snapshot.windows.contains(where: { $0.id == focused }) { return snapshot }
            } catch Failure.targetLost {
                // NSWorkspace may report the launch before the app becomes frontmost.
            } catch Failure.ambiguousWindows {
                guard tools.frontmostApplicationSnapshot().identity == app else { throw Failure.targetLost }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        try tools.requireActive()
        throw Failure.targetLost
    }

    private static func waitForNewFocusedWindow(
        before: WindowSnapshot, app: ComputerUseApplicationIdentity, tools: ComputerUseHostTools,
        captureWindows: @escaping CaptureWindows,
        budget: Duration,
        diagnostic: @MainActor (String) -> Void = { _ in }
    ) async throws -> Window {
        // A capture can spend up to two seconds reading Safari's window list;
        // keep observing for a delayed Cmd+N result without ever replaying it.
        let deadline = ContinuousClock.now.advanced(by: budget)
        let startedAt = ContinuousClock.now
        let budgetParts = budget.components
        let budgetMilliseconds = max(0, budgetParts.seconds * 1_000
            + budgetParts.attoseconds / 1_000_000_000_000_000)
        var transitionDiagnostics = 0
        var successfulCaptureCount = 0
        var transientCaptureFailureCount = 0
        var lastCaptureMilliseconds = 0
        var maximumCaptureMilliseconds = 0
        var firstTransition: String?
        var lastTransition: String?
        func milliseconds(_ duration: Duration) -> Int {
            let components = duration.components
            let value = components.seconds * 1_000
                + components.attoseconds / 1_000_000_000_000_000
            return Int(min(60_000, max(0, value)))
        }
        func boundedCount(_ count: Int) -> Int { min(4_096, max(0, count)) }
        func transitionSummary(_ after: WindowSnapshot) -> String {
            let added = after.windows.filter { candidate in
                !before.windows.contains(where: { sameWindowReference($0, candidate, in: before.application) })
            }.count
            let removed = before.windows.filter { prior in
                !after.windows.contains(where: { sameWindowReference($0, prior, in: before.application) })
            }.count
            let focusedAdded = after.windows.first(where: { $0.id == after.focusedWindowID }).map { focused in
                before.windows.contains(where: { sameWindowReference($0, focused, in: before.application) }) ? 0 : 1
            } ?? 0
            return "\(boundedCount(before.windows.count)):\(boundedCount(after.windows.count)):\(boundedCount(added)):\(boundedCount(removed)):\(focusedAdded)"
        }
        func recordSummary(_ outcome: String) {
            let elapsed = milliseconds(startedAt.duration(to: ContinuousClock.now))
            let first = firstTransition ?? "none"
            let last = lastTransition ?? "none"
            diagnostic("phase=new_window_wait_\(outcome) elapsed_ms=\(elapsed) budget_ms=\(budgetMilliseconds) successful_capture_count=\(successfulCaptureCount) transient_capture_failure_count=\(transientCaptureFailureCount) last_capture_ms=\(lastCaptureMilliseconds) max_capture_ms=\(maximumCaptureMilliseconds) first_transition=\(first) last_transition=\(last)")
        }
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try tools.requireActive()
            let after: WindowSnapshot
            let captureStartedAt = ContinuousClock.now
            do {
                after = try captureWindows(app)
                lastCaptureMilliseconds = milliseconds(captureStartedAt.duration(to: ContinuousClock.now))
                maximumCaptureMilliseconds = max(maximumCaptureMilliseconds, lastCaptureMilliseconds)
                successfulCaptureCount += 1
            }
            catch Failure.targetLost, Failure.ambiguousWindows {
                lastCaptureMilliseconds = milliseconds(captureStartedAt.duration(to: ContinuousClock.now))
                maximumCaptureMilliseconds = max(maximumCaptureMilliseconds, lastCaptureMilliseconds)
                transientCaptureFailureCount += 1
                // AX can briefly omit or incompletely enumerate windows while the new window appears.
                guard tools.frontmostApplicationSnapshot().identity == app else { throw Failure.targetLost }
                try await Task.sleep(for: .milliseconds(50))
                continue
            }
            let currentTransition = transitionSummary(after)
            if firstTransition == nil { firstTransition = currentTransition }
            lastTransition = currentTransition
            if transitionDiagnostics < 8 {
                let addedExactCFEqualCount = after.windows.filter { candidate in
                    !before.windows.contains(where: { CFEqual($0.accessibilityElement, candidate.accessibilityElement) })
                }.count
                let removedExactCFEqualCount = before.windows.filter { prior in
                    !after.windows.contains(where: { CFEqual($0.accessibilityElement, prior.accessibilityElement) })
                }.count
                let changedIDorElementCount = before.windows.filter { prior in
                    after.windows.contains(where: { candidate in
                        (candidate.id == prior.id || CFEqual(candidate.accessibilityElement, prior.accessibilityElement))
                            && !sameWindow(candidate, prior)
                    })
                }.count
                let focusedIsAdded = after.windows.first(where: { $0.id == after.focusedWindowID }).map { focused in
                    !before.windows.contains(where: { CFEqual($0.accessibilityElement, focused.accessibilityElement) })
                } ?? false
                let removedWindows = before.windows.filter { prior in
                    !after.windows.contains(where: { sameWindowReference($0, prior, in: before.application) })
                }
                let addedWindows = after.windows.filter { candidate in
                    !before.windows.contains(where: { sameWindowReference($0, candidate, in: before.application) })
                }
                let removedWasBeforeFocused: Bool
                if removedWindows.count == 1,
                   let beforeFocused = before.windows.first(where: { $0.id == before.focusedWindowID }) {
                    removedWasBeforeFocused = sameWindowReference(beforeFocused, removedWindows[0], in: before.application)
                } else {
                    removedWasBeforeFocused = false
                }
                func diagnosticAttribute(_ window: Window, _ attribute: CFString,
                                         allowed: Set<String>) -> String {
                    AXUIElementSetMessagingTimeout(window.accessibilityElement, 0.1)
                    var value: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(window.accessibilityElement, attribute, &value) == .success,
                          let scalar = value as? String else { return "unavailable" }
                    return allowed.contains(scalar) ? scalar : "other"
                }
                let removedRole = removedWindows.count == 1
                    ? diagnosticAttribute(removedWindows[0], kAXRoleAttribute as CFString,
                        allowed: ["AXWindow", "AXDialog", "AXSheet", "AXPopover", "AXUnknown"])
                    : removedWindows.isEmpty ? "none" : "multiple"
                let removedSubrole = removedWindows.count == 1
                    ? diagnosticAttribute(removedWindows[0], kAXSubroleAttribute as CFString,
                        allowed: ["AXStandardWindow", "AXDialog", "AXSystemDialog", "AXFloatingWindow",
                                  "AXSecureWindow", "AXUnknown"])
                    : removedWindows.isEmpty ? "none" : "multiple"
                func safariUUID(from window: Window) -> UUID? {
                    let marker = ":safari-uuid:"
                    guard let range = window.id.range(of: marker) else { return nil }
                    return UUID(uuidString: String(window.id[range.upperBound...]))
                }
                let sameSafariUUIDReplacement = removedWindows.count == 1 && addedWindows.count == 1
                    && safariUUID(from: removedWindows[0]) != nil
                    && safariUUID(from: removedWindows[0]) == safariUUID(from: addedWindows[0])
                diagnostic("phase=new_window_transition before=\(before.windows.count) after=\(after.windows.count) added=\(addedExactCFEqualCount) removed=\(removedExactCFEqualCount) changed=\(changedIDorElementCount) focused_added=\(focusedIsAdded ? 1 : 0) unique_before=\(uniqueWindows(before.windows) ? 1 : 0) unique_after=\(uniqueWindows(after.windows) ? 1 : 0) removed_was_before_focused=\(removedWasBeforeFocused ? 1 : 0) removed_role=\(removedRole) removed_subrole=\(removedSubrole) same_safari_uuid_replacement=\(sameSafariUUIDReplacement ? 1 : 0)")
                transitionDiagnostics += 1
            }
            guard after.application == app else { throw Failure.targetLost }
            guard !after.hasSheets else { throw Failure.authenticationHandoff }
            guard Self.uniqueWindows(after.windows) else { throw Failure.ambiguousWindows }
            if let target = Self.newFocusedWindow(before: before, after: after) {
                recordSummary("accepted")
                return target
            }
            // One newly created but not yet focused AX window is a normal
            // browser startup transition; wait without sending another key.
            if Self.singleNewWindow(before: before, after: after) != nil {
                try await Task.sleep(for: .milliseconds(50))
                continue
            }
            if Self.isTransientMissingBaselineWindow(before: before, after: after) {
                // Safari can briefly omit one background AX reference as the new
                // window appears. Reobserve; ownership still requires the full
                // original exact-reference set plus the one new focused window.
                try await Task.sleep(for: .milliseconds(50))
                continue
            }
            guard try Self.sameSnapshot(before, after) else { throw Failure.noNewFocusedWindow }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        try tools.requireActive()
        recordSummary("timeout")
        throw Failure.noNewFocusedWindow
    }

    static func captureWindowsForApplication(
        _ application: ComputerUseApplicationIdentity,
        expectedWindow: Window? = nil,
        startupDocumentInventory: Bool = false,
        diagnostic: @MainActor (String) -> Void = { _ in }
    ) throws -> WindowSnapshot {
        guard !Task.isCancelled else {
            diagnostic("phase=capture_failure reason=capture_cancelled")
            throw CancellationError()
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication, !frontmost.isTerminated else {
            diagnostic("phase=capture_failure reason=frontmost_unavailable")
            throw Failure.targetLost
        }
        guard frontmost.processIdentifier == application.processIdentifier,
              frontmost.bundleIdentifier == application.bundleIdentifier else {
            diagnostic("phase=capture_failure reason=frontmost_process_mismatch")
            throw Failure.targetLost
        }
        guard let identity = ComputerUseApplicationIdentity(runningApplication: frontmost),
              identity == application else {
            diagnostic("phase=capture_failure reason=frontmost_identity_mismatch")
            throw Failure.targetLost
        }
        // The two application-level AX reads (windows and focused window) may each
        // take up to 1.5 seconds; share a four-second total budget with geometry.
        let deadline = ContinuousClock.now.advanced(by: Self.nativeWindowCaptureBudget)
        let root = AXUIElementCreateApplication(application.processIdentifier)
        var rootReadAXError: Int?
        func read(_ element: AXUIElement, _ attribute: CFString,
                  messagingTimeout: Float? = nil) -> CFTypeRef? {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            let isApplicationWindowRead = CFEqual(element, root)
                && (attribute == (kAXWindowsAttribute as CFString)
                    || attribute == (kAXFocusedWindowAttribute as CFString))
            let components = ContinuousClock.now.duration(to: deadline).components
            let remainingSeconds = Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
            guard remainingSeconds > 0 else { return nil }
            let requestedTimeout: Double = messagingTimeout.map(Double.init) ?? (isApplicationWindowRead ? 1.5 : 0.15)
            AXUIElementSetMessagingTimeout(element, Float(min(requestedTimeout, remainingSeconds)))
            var value: CFTypeRef?
            let readStarted = ContinuousClock.now
            let result = AXUIElementCopyAttributeValue(element, attribute, &value)
            guard result == .success else {
                let readDuration = readStarted.duration(to: .now).components
                let elapsedMs = max(0, min(2_000, Int(Double(readDuration.seconds) * 1_000
                    + Double(readDuration.attoseconds) / 1_000_000_000_000_000)))
                if CFEqual(element, root), attribute == (kAXWindowsAttribute as CFString) {
                    rootReadAXError = Int(result.rawValue)
                    diagnostic("phase=capture_failure reason=windows_read ax_error=\(result.rawValue) elapsed_ms=\(elapsedMs)")
                } else if CFEqual(element, root), attribute == (kAXFocusedWindowAttribute as CFString) {
                    rootReadAXError = Int(result.rawValue)
                    diagnostic("phase=capture_failure reason=focused_window_read ax_error=\(result.rawValue) elapsed_ms=\(elapsedMs)")
                }
                if let expectedWindow,
                   CFEqual(element, expectedWindow.accessibilityElement),
                   attribute == (kAXPositionAttribute as CFString) || attribute == (kAXSizeAttribute as CFString) {
                    let field = attribute == (kAXPositionAttribute as CFString) ? "position" : "size"
                    diagnostic("phase=ax_attribute_read_failure field=\(field) ax_error=\(result.rawValue) deadline=\(ContinuousClock.now >= deadline ? 1 : 0)")
                }
                return nil
            }
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            return value
        }
        func value<T>(_ element: AXUIElement, _ attribute: CFString, _ type: AXValueType, _ result: inout T) -> Bool {
            guard let raw = read(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return false }
            return AXValueGetValue(raw as! AXValue, type, &result)
        }
        guard let windowsValue = read(root, kAXWindowsAttribute as CFString) else {
            if Task.isCancelled { diagnostic("phase=capture_failure reason=capture_cancelled") }
            else if ContinuousClock.now >= deadline { diagnostic("phase=capture_failure reason=capture_deadline") }
            else if rootReadAXError == nil { diagnostic("phase=capture_failure reason=windows_read") }
            throw Failure.targetLost
        }
        guard CFGetTypeID(windowsValue) == CFArrayGetTypeID() else {
            diagnostic("phase=capture_failure reason=windows_malformed")
            throw Failure.targetLost
        }
        guard let listed = windowsValue as? [AXUIElement] else {
            diagnostic("phase=capture_failure reason=windows_unconvertible")
            throw Failure.targetLost
        }
        var elements = listed
        rootReadAXError = nil
        guard let focusedValue = read(root, kAXFocusedWindowAttribute as CFString) else {
            if Task.isCancelled { diagnostic("phase=capture_failure reason=capture_cancelled") }
            else if ContinuousClock.now >= deadline { diagnostic("phase=capture_failure reason=capture_deadline") }
            else if rootReadAXError == nil { diagnostic("phase=capture_failure reason=focused_window_read") }
            throw Failure.targetLost
        }
        guard CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            diagnostic("phase=capture_failure reason=focused_window_malformed")
            throw Failure.targetLost
        }
        let focusedElement = focusedValue as! AXUIElement
        if let expectedWindow {
            guard expectedWindow.application == application,
                  expectedWindow.identity.applicationProcessIdentifier == application.processIdentifier,
                  uniquelyListedRetainedWindow(expectedWindow.accessibilityElement, in: elements) else {
                diagnostic("phase=ax_window_validation reason=retained_target_missing_or_ambiguous count=\(elements.count) deadline=\(ContinuousClock.now >= deadline ? 1 : 0) role=unavailable")
                throw Failure.targetLost
            }
            var targetPID: pid_t = 0
            guard AXUIElementGetPid(expectedWindow.accessibilityElement, &targetPID) == .success,
                  targetPID == application.processIdentifier else {
                diagnostic("phase=ax_window_validation reason=retained_target_pid count=\(elements.count) deadline=\(ContinuousClock.now >= deadline ? 1 : 0) role=AXWindow")
                throw Failure.targetLost
            }
            elements = [expectedWindow.accessibilityElement]
        }
        func string(_ element: AXUIElement, _ attribute: CFString,
                    messagingTimeout: Float? = nil) -> String? {
            guard let raw = read(element, attribute, messagingTimeout: messagingTimeout) else { return nil }
            guard let value = raw as? String else { return nil }
            return value
        }
        func safeRole(_ element: AXUIElement) -> String {
            let role = string(element, kAXRoleAttribute as CFString) ?? "unavailable"
            return ["AXWindow", "AXSheet", "AXPopover", "AXUnknown", "unavailable"].contains(role)
                ? role : "other"
        }
        func windowFailure(_ reason: String, index: Int, element: AXUIElement) {
            diagnostic("phase=ax_window_validation reason=\(reason) index=\(index) count=\(elements.count) deadline=\(ContinuousClock.now >= deadline ? 1 : 0) role=\(safeRole(element))")
        }
        func checkedWindowBounds(_ element: AXUIElement) -> (CGRect?, String) {
            // Only retained/focused action-relevant windows reach this helper.
            // Their geometry can take longer to settle during Safari navigation.
            guard let rawPosition = read(element, kAXPositionAttribute as CFString, messagingTimeout: 0.5),
                  let rawSize = read(element, kAXSizeAttribute as CFString, messagingTimeout: 0.5) else {
                return (nil, ContinuousClock.now >= deadline ? "deadline" : "read")
            }
            guard CFGetTypeID(rawPosition) == AXValueGetTypeID(),
                  CFGetTypeID(rawSize) == AXValueGetTypeID() else { return (nil, "type") }
            var origin = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(rawPosition, to: AXValue.self), .cgPoint, &origin),
                  AXValueGetValue(unsafeBitCast(rawSize, to: AXValue.self), .cgSize, &size),
                  origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else { return (nil, "malformed") }
            return (CGRect(origin: origin, size: size), "ok")
        }
        func array(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
            guard let raw = read(element, attribute), CFGetTypeID(raw) == CFArrayGetTypeID(),
                  let values = raw as? [AXUIElement] else { return [] }
            return values
        }
        func bounds(_ element: AXUIElement) -> CGRect? {
            var origin = CGPoint.zero
            var size = CGSize.zero
            guard value(element, kAXPositionAttribute as CFString, .cgPoint, &origin),
                  value(element, kAXSizeAttribute as CFString, .cgSize, &size),
                  origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else { return nil }
            return CGRect(origin: origin, size: size)
        }
        func parent(_ element: AXUIElement) -> AXUIElement? {
            guard let raw = read(element, kAXParentAttribute as CFString),
                  CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return (raw as! AXUIElement)
        }
        func descendants(_ start: AXUIElement, limit: Int = 256) -> [AXUIElement]? {
            var found: [AXUIElement] = [start]
            var queue: [(AXUIElement, Int)] = [(start, 0)]
            while let (element, depth) = queue.first, found.count < limit {
                queue.removeFirst()
                guard depth < 6 else { continue }
                // Do not enumerate the file list. Its selected rows are read
                // separately below, after the panel shape has been verified.
                if string(element, "AXIdentifier" as CFString) == "ListView"
                    || ["AXOutline", "AXTable", "AXRow", "AXCell"].contains(string(element, kAXRoleAttribute as CFString) ?? "") {
                    continue
                }
                for child in array(element, "AXSheets" as CFString) + array(element, kAXChildrenAttribute as CFString) {
                    if !found.contains(where: { CFEqual($0, child) }) {
                        found.append(child)
                        queue.append((child, depth + 1))
                    }
                }
            }
            return queue.isEmpty ? found : nil
        }
        func selectedURLs(in list: AXUIElement) -> [URL] {
            var selectedRows: [AXUIElement] = []
            for row in array(list, "AXSelectedRows" as CFString) + array(list, "AXSelectedChildren" as CFString)
                where !selectedRows.contains(where: { CFEqual($0, row) }) {
                selectedRows.append(row)
            }
            guard selectedRows.count <= 8 else { return [] }
            var result: [URL] = []
            for row in selectedRows {
                var rowNodes = [row]
                var queue: [(AXUIElement, Int)] = [(row, 0)]
                var rowURLs: [URL] = []
                while let (node, depth) = queue.first, rowNodes.count <= 64 {
                    queue.removeFirst()
                    if let raw = read(node, "AXURL" as CFString) {
                        if let url = raw as? URL, url.isFileURL { rowURLs.append(url.standardizedFileURL) }
                        else if let value = raw as? String, let url = URL(string: value), url.isFileURL {
                            rowURLs.append(url.standardizedFileURL)
                        }
                    }
                    guard depth < 3 else { continue }
                    for child in array(node, kAXChildrenAttribute as CFString) where !rowNodes.contains(where: { CFEqual($0, child) }) {
                        rowNodes.append(child); queue.append((child, depth + 1))
                    }
                }
                guard queue.isEmpty else { return [] }
                var uniqueRowURLs: [URL] = []
                for url in rowURLs where !uniqueRowURLs.contains(url) { uniqueRowURLs.append(url) }
                guard uniqueRowURLs.count == 1 else { return [] }
                result.append(uniqueRowURLs[0])
            }
            return result
        }
        var focusedAncestry: [AXUIElement]?
        func focusedWithin(_ root: AXUIElement) -> Bool {
            // Preserve the direct focused-window match without an AXParent read.
            if CFEqual(focusedElement, root) { return true }
            if focusedAncestry == nil {
                var chain = [focusedElement]
                while chain.count < 12, let current = chain.last, let next = parent(current) {
                    if chain.contains(where: { CFEqual($0, next) }) { break }
                    chain.append(next)
                }
                focusedAncestry = chain
            }
            return focusedAncestry?.contains(where: { CFEqual($0, root) }) == true
        }
        func focusedUIWithin(_ focusedUI: AXUIElement, _ root: AXUIElement) -> Bool {
            var current: AXUIElement? = focusedUI
            for _ in 0..<12 {
                guard let element = current else { return false }
                if CFEqual(element, root) { return true }
                current = parent(element)
            }
            return false
        }
        var windows: [Window] = []
        var hasSheets = false
        var hasUnrecognizedSheets = false
        var panelCandidates: [(Window, AXUIElement)] = []
        for (index, element) in elements.enumerated() {
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid == application.processIdentifier else {
                windowFailure("pid", index: index, element: element)
                throw Failure.ambiguousWindows
            }
            if startupDocumentInventory, expectedWindow == nil {
                let role = string(element, kAXRoleAttribute as CFString, messagingTimeout: 0.05)
                let subrole = role == "AXWindow"
                    ? string(element, kAXSubroleAttribute as CFString, messagingTimeout: 0.05) : nil
                switch Self.startupWindowClassification(role: role, subrole: subrole) {
                case .document:
                    break
                case .transientSurface:
                    if CFEqual(focusedElement, element) {
                        diagnostic("phase=ax_window_validation reason=focused_transient_surface index=\(index) count=\(elements.count) deadline=\(ContinuousClock.now >= deadline ? 1 : 0) role=\(safeRole(element))")
                        throw Failure.authenticationHandoff
                    }
                    continue
                case .unknown:
                    diagnostic("phase=ax_window_validation reason=startup_role_unclassified index=\(index) count=\(elements.count) deadline=\(ContinuousClock.now >= deadline ? 1 : 0) role=\(safeRole(element))")
                    throw Failure.ambiguousWindows
                }
            }
            let containsNativeFocus = focusedWithin(element)
            let isRetainedTarget = expectedWindow.map { CFEqual(element, $0.accessibilityElement) } ?? false
            let requireBounds = expectedWindow != nil || containsNativeFocus
            let bounds: CGRect
            if requireBounds {
                let (windowBounds, boundsReason) = checkedWindowBounds(element)
                guard let windowBounds else {
                    windowFailure("bounds_\(boundsReason)", index: index, element: element)
                    throw Failure.ambiguousWindows
                }
                bounds = windowBounds
            } else {
                // Startup inventory preserves background AX identity only. This
                // metadata cannot become an action target: the focused/new target
                // has fresh bounds, and retained validation refreshes them again.
                bounds = .zero
            }
            let hash = CFHash(element)
            let windowIdentity = ComputerUseFrontmostWindowCaptureIdentity(
                applicationProcessIdentifier: pid, accessibilityWindowHash: hash, bounds: bounds)
            let id: String
            if let expectedWindow, isRetainedTarget {
                guard let retainedID = Self.capturedWindowID(application: application, element: element,
                    accessibilityHash: hash, safariAXIdentifier: nil, retainedWindow: expectedWindow) else {
                    windowFailure("retained_identity", index: index, element: element)
                    throw Failure.targetLost
                }
                id = retainedID
            } else {
                let safariIdentifier = application.bundleIdentifier == "com.apple.Safari"
                    ? read(element, "AXIdentifier" as CFString, messagingTimeout: 0.05) as? String : nil
                id = Self.capturedWindowID(application: application, element: element,
                    accessibilityHash: hash, safariAXIdentifier: safariIdentifier, retainedWindow: nil) ?? "\(pid):ax-hash:\(hash)"
            }
            let window = Window(id: id, application: application,
                accessibilityElement: element, identity: windowIdentity)
            windows.append(window)
            // Startup inventory inspects sheets only under native focus. A
            // retained-session capture also inspects this exact
            // retained window's sheets even when macOS reports a detached
            // Go To sheet as the focused window and its AXParent chain does
            // not lead back through the browser. Other background windows
            // remain excluded from sheet inspection.
            guard containsNativeFocus || (expectedWindow != nil && isRetainedTarget) else { continue }
            let axSheets = array(element, "AXSheets" as CFString)
            if !axSheets.isEmpty { hasSheets = true }
            for sheet in axSheets where string(sheet, kAXRoleAttribute as CFString) != "AXSheet" {
                hasUnrecognizedSheets = true
            }
            var sheets: [AXUIElement] = []
            for sheet in axSheets + array(element, kAXChildrenAttribute as CFString)
                where string(sheet, kAXRoleAttribute as CFString) == "AXSheet"
                    && !sheets.contains(where: { CFEqual($0, sheet) }) {
                sheets.append(sheet)
            }
            for child in sheets {
                hasSheets = true
                if string(child, "AXIdentifier" as CFString) == "open-panel",
                   let childParent = parent(child), CFEqual(childParent, element) {
                    panelCandidates.append((window, child))
                } else {
                    hasUnrecognizedSheets = true
                }
            }
            if string(element, kAXRoleAttribute as CFString) == "AXSheet" {
                hasSheets = true
                hasUnrecognizedSheets = true
            }
        }
        let focusedWindowMatches = windows.filter { CFEqual(focusedValue, $0.accessibilityElement) }
        guard uniqueWindows(windows), focusedWindowMatches.count <= 1 else {
            let reason = focusedWindowMatches.count > 1 ? "focused_duplicate" :
                (Set(windows.map(\.id)).count != windows.count ? "duplicate_id" : "duplicate_element")
            diagnostic("phase=ax_window_validation reason=\(reason) count=\(elements.count) deadline=\(ContinuousClock.now >= deadline ? 1 : 0) role=unavailable")
            throw Failure.ambiguousWindows
        }
        let focusedID = windows.first(where: { CFEqual(focusedValue, $0.accessibilityElement) })?.id
        var fileOpenPanel: FileOpenPanel?
        if panelCandidates.count == 1, let (parentWindow, panel) = panelCandidates.first {
            guard let nodes = descendants(panel) else { throw Failure.authenticationHandoff }
            let listViews = nodes.filter { string($0, "AXIdentifier" as CFString) == "ListView" }
            let cancelButtons = nodes.filter { string($0, "AXIdentifier" as CFString) == "CancelButton" }
            let primaryButtons = nodes.filter { string($0, "AXIdentifier" as CFString) == "OKButton" }
            let nestedSheets = nodes.filter { string($0, kAXRoleAttribute as CFString) == "AXSheet" && !CFEqual($0, panel) }
            guard bounds(panel) != nil, listViews.count == 1, cancelButtons.count == 1,
                  primaryButtons.count == 1,
                  string(cancelButtons[0], kAXRoleAttribute as CFString) == "AXButton",
                  string(primaryButtons[0], kAXRoleAttribute as CFString) == "AXButton",
                  nestedSheets.count <= 1 else {
                hasUnrecognizedSheets = true
                throw Failure.authenticationHandoff
            }
            var goToBounds: CGRect?
            var pathField: AXUIElement?
            var pathFocused = false
            var detachedGoToPathFieldFocused = false
            var pathValue: String?
            var pathSelection: NSRange?
            if let nested = nestedSheets.first {
                guard let nestedNodes = descendants(nested) else { throw Failure.authenticationHandoff }
                let fields = nestedNodes.filter { string($0, "AXIdentifier" as CFString) == "PathTextField" }
                let closeButtons = nestedNodes.filter { string($0, "AXIdentifier" as CFString) == "CloseButton" }
                guard string(nested, "AXIdentifier" as CFString) == "GoToWindow",
                      fields.count == 1, closeButtons.count == 1,
                      string(fields[0], kAXRoleAttribute as CFString) == "AXTextField",
                      string(closeButtons[0], kAXRoleAttribute as CFString) == "AXButton",
                      let nestedBounds = bounds(nested) else { throw Failure.authenticationHandoff }
                goToBounds = nestedBounds
                pathField = fields[0]
                if let focusedUIValue = read(root, kAXFocusedUIElementAttribute as CFString),
                   CFGetTypeID(focusedUIValue) == AXUIElementGetTypeID() {
                    let focusedUI = unsafeBitCast(focusedUIValue, to: AXUIElement.self)
                    pathFocused = CFEqual(focusedUI, focusedElement)
                        ? focusedWithin(fields[0]) : focusedUIWithin(focusedUI, fields[0])
                    if let expectedWindow {
                        detachedGoToPathFieldFocused = Self.isExactRetainedGoToPathFieldFocus(
                            retainedWindow: expectedWindow.accessibilityElement,
                            panelParentWindow: parentWindow.accessibilityElement,
                            focusedWindow: focusedElement, goToWindow: nested,
                            focusedUI: focusedUI, pathField: fields[0])
                    }
                }
                if let text = string(fields[0], kAXValueAttribute as CFString), text.utf8.count <= 32_768 {
                    pathValue = text
                    var range = CFRange()
                    if value(fields[0], kAXSelectedTextRangeAttribute as CFString, .cfRange, &range),
                       range.location >= 0, range.length >= 0,
                       range.location <= text.utf16.count, range.length <= text.utf16.count - range.location {
                        pathSelection = NSRange(location: range.location, length: range.length)
                    }
                }
            }
            var enabled: Bool?
            if let raw = read(primaryButtons[0], kAXEnabledAttribute as CFString), CFGetTypeID(raw) == CFBooleanGetTypeID() {
                enabled = raw as? Bool
            }
            fileOpenPanel = FileOpenPanel(parentWindowID: parentWindow.id,
                parentWindowElement: parentWindow.accessibilityElement, accessibilityElement: panel,
                bounds: bounds(panel)!, isFocused: focusedWithin(panel) || detachedGoToPathFieldFocused,
                goToFolderBounds: goToBounds, pathTextFieldElement: pathField,
                selectedFileURLs: selectedURLs(in: listViews[0]),
                primaryActionElement: primaryButtons[0], primaryActionBounds: bounds(primaryButtons[0]),
                primaryActionEnabled: enabled, pathFieldIsFocused: pathFocused,
                pathFieldValue: pathValue, pathFieldSelection: pathSelection)
        } else if hasSheets {
            hasUnrecognizedSheets = true
        }
        guard let after = NSWorkspace.shared.frontmostApplication, !after.isTerminated else {
            diagnostic("phase=capture_failure reason=final_frontmost_unavailable")
            throw Failure.targetLost
        }
        guard let afterIdentity = ComputerUseApplicationIdentity(runningApplication: after),
              afterIdentity == application else {
            diagnostic("phase=capture_failure reason=final_frontmost_changed")
            throw Failure.targetLost
        }
        guard !Task.isCancelled else {
            diagnostic("phase=capture_failure reason=capture_cancelled")
            throw Failure.targetLost
        }
        guard ContinuousClock.now < deadline else {
            diagnostic("phase=capture_failure reason=capture_deadline")
            throw Failure.targetLost
        }
        return WindowSnapshot(application: application, windows: windows,
            focusedWindowID: focusedID, hasSheets: hasSheets, fileOpenPanel: fileOpenPanel,
            hasUnrecognizedSheets: hasUnrecognizedSheets)
    }

    /// macOS may expose Safari's Go To sheet as AXFocusedWindow while its
    /// parent chain stops before the retained browser window. Admit that
    /// detached focus only when every participant is the exact unique object
    /// discovered under the retained open panel.
    static func isExactRetainedGoToPathFieldFocus(retainedWindow: AXUIElement,
        panelParentWindow: AXUIElement, focusedWindow: AXUIElement, goToWindow: AXUIElement,
        focusedUI: AXUIElement, pathField: AXUIElement) -> Bool {
        CFEqual(retainedWindow, panelParentWindow)
            && CFEqual(focusedWindow, goToWindow)
            && CFEqual(focusedUI, pathField)
    }
}

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

    struct SafariAddressBarCandidate {
        let element: AXUIElement
        let processIdentifier: pid_t
        let role: String
        let identifier: String
        let isEnabled: Bool
        let valueIsSettable: Bool
        let isSecure: Bool
        let isHidden: Bool
        let isProtected: Bool
    }

    struct SafariAddressBarAXAccess {
        let read: (String, AXUIElement) -> CFTypeRef?
        let processIdentifier: (AXUIElement) -> pid_t?
        let valueIsSettable: (AXUIElement) -> Bool
        let setValue: (CFTypeRef, AXUIElement) -> AXError

        static var live: SafariAddressBarAXAccess {
            func read(_ name: String, _ element: AXUIElement) -> CFTypeRef? {
                guard !Task.isCancelled else { return nil }
                AXUIElementSetMessagingTimeout(element, 0.1)
                var result: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success,
                      !Task.isCancelled else { return nil }
                return result
            }
            return SafariAddressBarAXAccess(read: read, processIdentifier: { element in
                var pid: pid_t = 0
                guard AXUIElementGetPid(element, &pid) == .success else { return nil }
                return pid
            }, valueIsSettable: { element in
                var settable = DarwinBoolean(false)
                return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
                    && settable.boolValue
            }, setValue: { value, element in
                AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value)
            })
        }
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
        var stableNavigationRetryConsumed: Set<String> = []
        var stableNavigationRetryPermits: Set<String> = []

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

        func reset() { reason = nil; axErrorCode = nil }

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
                "duplicate_id", "duplicate_element", "bounds_ax_read_failure"]
            if let token, allowed.contains(token) { reason = token }
            if let field = message.split(separator: " ").first(where: { $0.hasPrefix("ax_error=") }),
               let code = Int(field.dropFirst("ax_error=".count)), (-65_535...65_535).contains(code) {
                axErrorCode = code
            }
        }
    }

    private let journalDirectory: URL
    private let resolveHandler: ResolveHandler
    private let launchApplication: LaunchApplication
    private let captureWindows: CaptureWindows
    private let captureRetainedWindow: CaptureRetainedWindow?
    private let makeStore: (URL) throws -> ComputerUseTaskJournalStore
    private let safariAddressBarAX: SafariAddressBarAXAccess
    private let captureDiagnosticProvider: @MainActor () -> String?
    private let captureDiagnosticAXErrorProvider: @MainActor () -> Int?
    private let captureWindowsDiagnostic: @MainActor (String) -> Void
    private var runState: RunState?
    private(set) var lastValidationPhaseForDiagnostics: ValidationPhase?
    private(set) var lastWindowTransitionDiagnostic: String?
    /// Failure-only scalar evidence for the bounded Safari address-focus wait.
    /// Contains no page text, URL, AX label, or identifier.
    private(set) var lastAddressFocusWaitDiagnostic: [String: String] = [:]
    var currentWindow: Window? { runState?.target }
    var currentFileOpenPanel: FileOpenPanel? { runState?.currentFileOpenPanel }
    var currentActionBounds: CGRect? { runState?.currentActionBounds }
    var lastCaptureReasonForDiagnostics: String? { captureDiagnosticProvider() }
    var lastCaptureAXErrorCodeForDiagnostics: Int? { captureDiagnosticAXErrorProvider() }

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
                return try Self.captureWindowsForApplication(application, diagnostic: recordDiagnostic)
            },
            captureRetainedWindow: { application, target in
                captureDiagnosticState.reset()
                return try Self.captureWindowsForApplication(application, expectedWindow: target,
                    diagnostic: recordDiagnostic)
            }, captureDiagnosticProvider: { captureDiagnosticState.reason },
            captureDiagnosticAXErrorProvider: { captureDiagnosticState.axErrorCode },
            captureWindowsDiagnostic: captureWindowsDiagnostic)
    }

    init(journalDirectory: URL,
         resolveHandler: @escaping ResolveHandler,
         launchApplication: @escaping LaunchApplication,
         captureWindows: @escaping CaptureWindows,
         safariAddressBarAX: SafariAddressBarAXAccess = .live,
         makeStore: @escaping (URL) throws -> ComputerUseTaskJournalStore = { try .init(directory: $0) },
         captureRetainedWindow: CaptureRetainedWindow? = nil,
         captureDiagnosticProvider: @escaping @MainActor () -> String? = { nil },
         captureDiagnosticAXErrorProvider: @escaping @MainActor () -> Int? = { nil },
         captureWindowsDiagnostic: @escaping @MainActor (String) -> Void = { _ in }) throws {
        self.journalDirectory = journalDirectory
        self.resolveHandler = resolveHandler
        self.launchApplication = launchApplication
        self.captureWindows = captureWindows
        self.captureRetainedWindow = captureRetainedWindow
        self.safariAddressBarAX = safariAddressBarAX
        self.makeStore = makeStore
        self.captureDiagnosticProvider = captureDiagnosticProvider
        self.captureDiagnosticAXErrorProvider = captureDiagnosticAXErrorProvider
        self.captureWindowsDiagnostic = captureWindowsDiagnostic
    }

    func ensure(taskID: String, goal: String, tools: ComputerUseHostTools) async throws -> Window {
        try Task.checkCancellation()
        try tools.requireActive()
        guard !taskID.isEmpty, !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.changedTaskOrGoal
        }
        let goalDigest = ComputerUseTextTaskContract.digest(goal)
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
              state.goalDigest == ComputerUseTextTaskContract.digest(goal),
              let expected = state.target, let app = state.app else {
            lastValidationPhaseForDiagnostics = .target
            throw Failure.changedTaskOrGoal
        }
        let current: WindowSnapshot
        lastValidationPhaseForDiagnostics = .capture
        current = try captureForValidation(application: app, target: expected, tools: tools)
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

    /// Navigates through Safari's observed address field using only the
    /// already-authorized Accessibility and native input paths.
    func rearmStableGmailNavigationRetry(to targetURL: URL, observedPageURL: URL,
        accountIndex: Int, taskID: String, goal: String, tools: ComputerUseHostTools) throws -> Bool {
        try Task.checkCancellation()
        try tools.requireActive()
        try validate(taskID: taskID, goal: goal, tools: tools)
        guard let state = runState, let target = state.target,
              state.currentFileOpenPanel == nil,
              Self.isCanonicalStableGmailNavigationURL(targetURL, accountIndex: accountIndex),
              Self.isSameAccountGmailObservationURL(observedPageURL, accountIndex: accountIndex),
              observedPageURL.absoluteString != targetURL.absoluteString,
              state.navigationDispatches.contains(targetURL.absoluteString),
              state.navigationReturnsCompleted.contains(targetURL.absoluteString),
              !state.stableNavigationRetryConsumed.contains(targetURL.absoluteString),
              !state.stableNavigationRetryPermits.contains(targetURL.absoluteString),
              target.application.bundleIdentifier == "com.apple.Safari" else { return false }
        try Task.checkCancellation()
        try tools.requireActive()
        try validate(taskID: taskID, goal: goal, tools: tools)
        guard let current = runState?.target, Self.sameWindow(current, target),
              state.currentFileOpenPanel == nil else { return false }
        state.stableNavigationRetryConsumed.insert(targetURL.absoluteString)
        state.stableNavigationRetryPermits.insert(targetURL.absoluteString)
        return true
    }

    func navigateRetainedSafariTab(to url: URL, taskID: String, goal: String,
                                   tools: ComputerUseHostTools,
                                   diagnostic: @escaping @MainActor (String) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        try tools.requireActive()
        do { try validate(taskID: taskID, goal: goal, tools: tools) }
        catch { diagnostic("phase=pre_navigation_scope_validation_failed"); throw error }
        guard let state = runState, let target = state.target else {
            diagnostic("phase=retained_target_missing"); throw Failure.targetLost
        }
        guard target.application.bundleIdentifier == "com.apple.Safari" else {
            diagnostic("phase=unsupported_browser bundle=safari_required"); throw Failure.targetLost
        }
        guard Self.isSupportedGmailNavigationURL(url) else {
            diagnostic("phase=destination_rejected"); throw Failure.targetLost
        }
        if state.navigationDispatches.contains(url.absoluteString) {
            guard state.stableNavigationRetryPermits.remove(url.absoluteString) != nil else {
                diagnostic("phase=already_latched"); throw Failure.targetLost
            }
        }
        let initiallyObservedAddressField: AXUIElement
        do { initiallyObservedAddressField = try uniqueSafariAddressField(in: target, diagnostic: diagnostic) }
        catch { diagnostic("phase=address_field_not_found"); throw error }
        try Task.checkCancellation()
        try tools.requireActive()
        try validate(taskID: taskID, goal: goal, tools: tools)
        // AX focus can name Safari's address control before Cmd+L has
        // activated location editing, so always establish that native mode.
        do {
            try tools.performNativeBrowserHostCommand(.focusAddress,
                expectedApplication: target.application, willBeginEffect: {
                    try Task.checkCancellation()
                    try tools.requireActive()
                    try self.validate(taskID: taskID, goal: goal, tools: tools)
                    guard let currentState = self.runState, currentState.currentFileOpenPanel == nil,
                          let current = currentState.target, Self.sameWindow(current, target),
                          self.focusedSafariAddressField(in: current) != nil else { throw Failure.targetLost }
                })
        } catch { diagnostic("phase=address_field_focus_dispatch_failed"); throw error }
        diagnostic("phase=address_editing_activated")
        let addressField: AXUIElement
        do {
            addressField = try await waitForFocusedSafariAddressField(
                initiallyObserved: initiallyObservedAddressField, target: target,
                taskID: taskID, goal: goal, tools: tools, diagnostic: diagnostic)
        } catch {
            diagnostic("phase=address_field_not_focused_before_navigation")
            throw error
        }
        try Task.checkCancellation()
        try tools.requireActive()
        do { try validate(taskID: taskID, goal: goal, tools: tools) }
        catch { diagnostic("phase=pre_address_write_scope_validation_failed"); throw error }
        guard isCurrentSafariAddressField(addressField, target: target),
              focusedSafariAddressField(in: target).map({ CFEqual($0, addressField) }) == true else {
            diagnostic("phase=pre_address_write_focus_validation_failed")
            throw Failure.targetLost
        }
        let addressValue = safariAddressBarAX.read(kAXValueAttribute as String, addressField) as? String
        guard isCurrentSafariAddressField(addressField, target: target),
              focusedSafariAddressField(in: target).map({ CFEqual($0, addressField) }) == true,
              let addressValue else {
            diagnostic("phase=address_value_read_failed")
            throw Failure.targetLost
        }
        let typeAction = ComputerUsePredictedAction.typeText(url.absoluteString)
        var typeFingerprint: ComputerUseApprovalFingerprint?
        var typeFingerprintAttempts = 0
        var typeFingerprintRetryDeadline: ContinuousClock.Instant?
        while typeFingerprint == nil {
            if typeFingerprintAttempts > 0 {
                guard let deadline = typeFingerprintRetryDeadline, ContinuousClock.now < deadline else {
                    throw ComputerUseHostTools.ToolError.approvalTargetUnavailable
                }
                try Task.checkCancellation()
                try tools.requireActive()
                try await Task.sleep(for: .milliseconds(50))
                try Task.checkCancellation()
                try tools.requireActive()
                try validate(taskID: taskID, goal: goal, tools: tools)
                guard isCurrentSafariAddressField(addressField, target: target),
                      focusedSafariAddressField(in: target).map({ CFEqual($0, addressField) }) == true,
                      safariAddressBarAX.read(kAXValueAttribute as String, addressField) as? String == addressValue else {
                    throw Failure.targetLost
                }
                guard ContinuousClock.now < deadline else {
                    throw ComputerUseHostTools.ToolError.approvalTargetUnavailable
                }
            }
            try Task.checkCancellation()
            try tools.requireActive()
            typeFingerprintAttempts += 1
            do {
                typeFingerprint = try tools.prepareNativeActionFingerprint(for: typeAction)
            } catch ComputerUseHostTools.ToolError.approvalTargetUnavailable {
                typeFingerprintRetryDeadline = typeFingerprintRetryDeadline
                    ?? ContinuousClock.now.advanced(by: .seconds(2))
                guard typeFingerprintAttempts < 3 else {
                    throw ComputerUseHostTools.ToolError.approvalTargetUnavailable
                }
            } catch {
                throw error
            }
        }
        guard let typeFingerprint else { throw Failure.targetLost }
        let addressEntryScope = ComputerUseNativeBrowserAddressEntryScope(
            application: target.application,
            window: target.identity,
            retainedWindow: target.accessibilityElement,
            addressField: addressField)
        do {
            try await tools.performNativeBrowserAddressValueWrite(url.absoluteString, scope: addressEntryScope,
                fingerprint: typeFingerprint, willBeginEffect: {
                    try Task.checkCancellation()
                    try tools.requireActive()
                    try self.validate(taskID: taskID, goal: goal, tools: tools)
                    guard self.isCurrentSafariAddressField(addressField, target: target),
                          self.focusedSafariAddressField(in: target).map({ CFEqual($0, addressField) }) == true,
                          self.safariAddressBarAX.read(kAXValueAttribute as String, addressField) as? String == addressValue else {
                        throw Failure.targetLost
                    }
                    // A partial or uncertain AX write must never be replayed.
                    state.navigationDispatches.insert(url.absoluteString)
                    diagnostic("phase=ax_address_value_write_latched")
                }, writeValue: {
                    try Task.checkCancellation()
                    try tools.requireActive()
                    try self.validate(taskID: taskID, goal: goal, tools: tools)
                    guard self.isCurrentSafariAddressField(addressField, target: target),
                          self.focusedSafariAddressField(in: target).map({ CFEqual($0, addressField) }) == true,
                          self.safariAddressBarAX.read(kAXValueAttribute as String, addressField) as? String == addressValue else {
                        throw Failure.targetLost
                    }
                    let result = self.safariAddressBarAX.setValue(url.absoluteString as CFTypeRef, addressField)
                    diagnostic(result == .success
                        ? "phase=ax_address_value_write_completed"
                        : "phase=ax_address_value_write_status_uncertain")
                })
        } catch { diagnostic("phase=ax_address_value_write_failed"); throw error }
        let addressReadbackDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while true {
            try Task.checkCancellation()
            try tools.requireActive()
            guard ContinuousClock.now < addressReadbackDeadline else {
                diagnostic("phase=ax_address_value_readback_deadline")
                throw Failure.targetLost
            }
            do { try validate(taskID: taskID, goal: goal, tools: tools) }
            catch {
                guard isTransientValidationCaptureFailure(error),
                      ContinuousClock.now < addressReadbackDeadline else {
                    diagnostic("phase=ax_address_value_readback_scope_failed")
                    throw error
                }
                diagnostic("phase=ax_address_value_readback_scope_unavailable")
                try await Task.sleep(for: .milliseconds(50))
                continue
            }
            switch addressReadbackReadiness(field: addressField, target: target,
                                            url: url, previousValue: addressValue) {
            case .ready:
                guard ContinuousClock.now < addressReadbackDeadline else {
                    diagnostic("phase=ax_address_value_readback_deadline")
                    throw Failure.targetLost
                }
                diagnostic("phase=ax_address_value_readback_verified")
                break
            case .temporarilyUnavailable(let phase):
                guard ContinuousClock.now < addressReadbackDeadline else {
                    diagnostic("phase=ax_address_value_readback_deadline")
                    throw Failure.targetLost
                }
                diagnostic("phase=\(phase)")
                try await Task.sleep(for: .milliseconds(50))
                continue
            case .rejected(let phase):
                switch phase {
                case "return_field_process_changed", "return_field_role_changed", "return_field_identifier_changed",
                     "return_field_secure", "return_field_protected", "return_field_disabled",
                     "return_field_not_writable", "return_field_window_unconfirmed", "return_window_changed":
                    diagnostic("phase=ax_address_value_readback_field_unconfirmed_reason_\(phase)")
                case "return_focus_changed", "return_focus_unavailable":
                    diagnostic("phase=ax_address_value_readback_focus_unconfirmed")
                default:
                    diagnostic("phase=ax_address_value_readback_value_mismatch")
                }
                throw Failure.targetLost
            }
            break
        }
        let returnPreparationDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        var returnEffectReady = false
        var transientReturnFailure: String?
        var returnPreparationPhase: String?
        while true {
            try Task.checkCancellation()
            try tools.requireActive()
            guard ContinuousClock.now < returnPreparationDeadline else {
                diagnostic("phase=return_preparation_deadline")
                throw Failure.targetLost
            }
            returnEffectReady = false
            transientReturnFailure = nil
            returnPreparationPhase = nil
            do {
                try tools.performNativeBrowserHostCommand(.commitAddress,
                    expectedApplication: target.application, willBeginEffect: {
                    try Task.checkCancellation()
                    try tools.requireActive()
                    do {
                        try self.validate(taskID: taskID, goal: goal, tools: tools)
                    } catch {
                        guard self.isTransientValidationCaptureFailure(error) else {
                            returnPreparationPhase = "return_scope_changed"
                            diagnostic("phase=return_scope_changed")
                            throw error
                        }
                        transientReturnFailure = "return_scope_unavailable"
                        returnPreparationPhase = "return_scope_unavailable"
                        diagnostic("phase=return_scope_unavailable")
                        throw Failure.targetLost
                    }
                    switch self.returnPreparationReadiness(field: addressField, target: target, url: url) {
                    case .ready:
                        guard ContinuousClock.now < returnPreparationDeadline else {
                            transientReturnFailure = "return_preparation_deadline"
                            returnPreparationPhase = "return_preparation_deadline"
                            diagnostic("phase=return_preparation_deadline")
                            throw Failure.targetLost
                        }
                    case .temporarilyUnavailable(let phase):
                        transientReturnFailure = phase
                        returnPreparationPhase = phase
                        diagnostic("phase=\(phase)")
                        throw Failure.targetLost
                    case .rejected(let phase):
                        transientReturnFailure = nil
                        returnPreparationPhase = phase
                        diagnostic("phase=\(phase)")
                        throw Failure.targetLost
                    }
                    // This must remain the final statement after fresh scope, panel,
                    // exact field, focus, and exact URL checks. The host command
                    // performs its own app/gate check before posting Return.
                    returnEffectReady = true
                })
                break
            } catch {
                guard !returnEffectReady,
                      (error as? Failure) == .targetLost,
                      transientReturnFailure != nil else {
                    if returnPreparationPhase == nil { diagnostic("phase=return_dispatch_failed") }
                    throw error
                }
                try Task.checkCancellation()
                try tools.requireActive()
                guard ContinuousClock.now < returnPreparationDeadline else {
                    diagnostic("phase=return_preparation_deadline")
                    throw Failure.targetLost
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try Task.checkCancellation()
        try tools.requireActive()
        let postReturnValidationDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        var lastQualifyingCaptureFailure: Error?
        while true {
            try Task.checkCancellation()
            try tools.requireActive()
            guard ContinuousClock.now < postReturnValidationDeadline else {
                diagnostic("phase=post_navigation_scope_validation_failed")
                throw lastQualifyingCaptureFailure ?? Failure.targetLost
            }
            guard runState === state,
                  state.taskID == taskID,
                  state.goalDigest == ComputerUseTextTaskContract.digest(goal),
                  state.app == target.application,
                  let currentTarget = state.target,
                  Self.sameWindow(currentTarget, target) else {
                diagnostic("phase=post_navigation_scope_validation_failed")
                throw Failure.targetLost
            }
            let frontmost = tools.frontmostApplicationSnapshot()
            guard frontmost.identityIsAuthoritative,
                  frontmost.identity == target.application else {
                diagnostic("phase=post_navigation_scope_validation_failed")
                throw Failure.targetLost
            }
            do {
                try validate(taskID: taskID, goal: goal, tools: tools)
                break
            } catch {
                guard isTransientValidationCaptureFailure(error) else {
                    diagnostic("phase=post_navigation_scope_validation_failed")
                    throw error
                }
                lastQualifyingCaptureFailure = error
                guard ContinuousClock.now < postReturnValidationDeadline else {
                    diagnostic("phase=post_navigation_scope_validation_failed")
                    throw error
                }
                try Task.checkCancellation()
                try tools.requireActive()
                guard runState === state,
                      state.taskID == taskID,
                      state.goalDigest == ComputerUseTextTaskContract.digest(goal),
                      state.app == target.application,
                      let currentTarget = state.target,
                      Self.sameWindow(currentTarget, target) else {
                    diagnostic("phase=post_navigation_scope_validation_failed")
                    throw Failure.targetLost
                }
                let retryFrontmost = tools.frontmostApplicationSnapshot()
                guard retryFrontmost.identityIsAuthoritative,
                      retryFrontmost.identity == target.application else {
                    diagnostic("phase=post_navigation_scope_validation_failed")
                    throw Failure.targetLost
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        guard let after = state.target, after.id == target.id,
              after.application == target.application else {
            diagnostic("phase=post_navigation_identity_mismatch")
            throw Failure.targetLost
        }
        state.navigationReturnsCompleted.insert(url.absoluteString)
        diagnostic("phase=ax_navigation_dispatched")
    }

    private static func isCanonicalStableGmailNavigationURL(_ url: URL, accountIndex: Int) -> Bool {
        guard (0...9_999).contains(accountIndex),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "mail.google.com",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil,
              let parsedIndex = ComputerUseGmailAccountDirectory.accountIndex(from: url.absoluteString),
              parsedIndex == accountIndex,
              components.path == "/mail/u/\(accountIndex)/",
              components.fragment == "inbox" || components.fragment == "drafts" else {
            return false
        }
        return true
    }

    private static func isSameAccountGmailObservationURL(_ url: URL, accountIndex: Int) -> Bool {
        guard (0...9_999).contains(accountIndex),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "mail.google.com",
              components.user == nil, components.password == nil, components.port == nil,
              ComputerUseGmailAccountDirectory.accountIndex(from: url.absoluteString) == accountIndex,
              components.path == "/mail/u/\(accountIndex)" || components.path == "/mail/u/\(accountIndex)/" else {
            return false
        }
        return true
    }

    static func selectedSafariAddressBarCandidate(from candidates: [SafariAddressBarCandidate],
                                                   processIdentifier: pid_t) -> AXUIElement? {
        let matches = candidates.filter {
            $0.processIdentifier == processIdentifier
                && ($0.role == "AXTextField" || $0.role == "AXComboBox")
                && $0.identifier == "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"
                && $0.isEnabled && $0.valueIsSettable
                && !$0.isSecure && !$0.isHidden && !$0.isProtected
        }
        guard matches.count == 1 else { return nil }
        return matches[0].element
    }

    static func uniquelyListedRetainedWindow(_ target: AXUIElement,
                                             in windows: [AXUIElement]) -> Bool {
        windows.filter { CFEqual($0, target) }.count == 1
    }

    private func uniqueSafariAddressField(in target: Window,
                                          diagnostic: (String) -> Void = { _ in }) throws -> AXUIElement {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(750))
        var queue: [AXUIElement] = [target.accessibilityElement]
        var visited: [AXUIElement] = []
        var candidates: [SafariAddressBarCandidate] = []
        var foreignBranches = 0
        func failure(_ reason: String) -> Failure {
            diagnostic("phase=address_scan_failed reason=\(reason) nodes=\(visited.count) candidates=\(candidates.count) foreign_branches=\(foreignBranches)")
            return .targetLost
        }
        while !queue.isEmpty {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline, visited.count < 256 else { throw failure("time_or_node_bound") }
            let node = queue.removeFirst()
            guard !visited.contains(where: { CFEqual($0, node) }) else { continue }
            visited.append(node)
            func read(_ attribute: String, _ element: AXUIElement) throws -> CFTypeRef? {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw failure("attribute_read_time_bound") }
                return safariAddressBarAX.read(attribute, element)
            }
            guard let role = try read(kAXRoleAttribute as String, node) as? String else {
                throw failure("role_unavailable")
            }
            if role == "AXWebArea" { continue }
            guard safariAddressBarAX.processIdentifier(node) == target.application.processIdentifier else {
                foreignBranches += 1
                continue
            }
            let subrole = try read(kAXSubroleAttribute as String, node) as? String ?? ""
            let isSecure = role == "AXSecureTextField" || subrole == (kAXSecureTextFieldSubrole as String)
            let isHidden = (try read("AXHidden", node) as? NSNumber)?.boolValue == true
            let isProtected = (try read("AXProtectedContent", node) as? NSNumber)?.boolValue == true
            if isSecure || isHidden || isProtected { continue }
            if role == "AXTextField" || role == "AXComboBox" {
                let identifier = try read("AXIdentifier", node) as? String ?? ""
                if identifier.isEmpty { diagnostic("phase=address_candidate_metadata_missing field=identifier") }
                let enabledValue = try read(kAXEnabledAttribute as String, node) as? NSNumber
                let enabled = enabledValue?.boolValue == true
                if enabledValue == nil { diagnostic("phase=address_candidate_metadata_missing field=enabled") }
                let valueIsSettable = safariAddressBarAX.valueIsSettable(node)
                if !valueIsSettable { diagnostic("phase=address_candidate_not_writable") }
                candidates.append(.init(element: node,
                    processIdentifier: safariAddressBarAX.processIdentifier(node) ?? -1,
                    role: role, identifier: identifier, isEnabled: enabled,
                    valueIsSettable: valueIsSettable,
                    isSecure: isSecure, isHidden: isHidden, isProtected: isProtected))
            }
            let knownLeafRoles: Set<String> = ["AXTextField", "AXComboBox", "AXButton", "AXStaticText",
                "AXLink", "AXImage", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXSlider",
                "AXSeparator", "AXSplitter", "AXDisclosureTriangle", "AXProgressIndicator"]
            guard let childrenValue = try read(kAXChildrenAttribute as String, node) else {
                if knownLeafRoles.contains(role) { continue }
                let safeRole = ["AXApplication", "AXWindow", "AXToolbar", "AXGroup", "AXSplitGroup",
                    "AXTabGroup", "AXTab", "AXRadioButton"].contains(role) ? role : "other"
                throw failure("children_unavailable_container_role_\(safeRole)")
            }
            guard CFGetTypeID(childrenValue) == CFArrayGetTypeID(),
                  let children = childrenValue as? [AXUIElement],
                  visited.count + queue.count + children.count <= 256 else { throw failure("children_malformed_or_over_bound") }
            queue.append(contentsOf: children)
        }
        guard queue.isEmpty, ContinuousClock.now < deadline else { throw failure("incomplete_scan") }
        guard let field = Self.selectedSafariAddressBarCandidate(from: candidates,
                processIdentifier: target.application.processIdentifier) else {
            let exactIdentifierCount = candidates.filter {
                $0.processIdentifier == target.application.processIdentifier
                    && $0.identifier == "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"
            }.count
            throw failure(exactIdentifierCount > 1 ? "ambiguous_address_field" : "no_eligible_address_field")
        }
        guard addressFieldBelongsToRetainedWindow(field, target: target, deadline: deadline) else {
            throw failure("address_field_outside_retained_window")
        }
        return field
    }

    private func addressFieldBelongsToRetainedWindow(_ field: AXUIElement, target: Window,
                                                      deadline: ContinuousClock.Instant) -> Bool {
        var cursor: AXUIElement? = field
        var seen: [AXUIElement] = []
        for _ in 0..<16 {
            guard ContinuousClock.now < deadline, let current = cursor,
                  !seen.contains(where: { CFEqual($0, current) }),
                  safariAddressBarAX.processIdentifier(current) == target.application.processIdentifier else { return false }
            if CFEqual(current, target.accessibilityElement) { return true }
            seen.append(current)
            guard let role = safariAddressBarAX.read(kAXRoleAttribute as String, current) as? String,
                  role != "AXWebArea",
                  let parentValue = safariAddressBarAX.read(kAXParentAttribute as String, current),
                  CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { return false }
            cursor = unsafeBitCast(parentValue, to: AXUIElement.self)
        }
        return false
    }

    private func isCurrentSafariAddressField(_ field: AXUIElement, target: Window) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(750))
        func read(_ attribute: String) -> CFTypeRef? {
            guard ContinuousClock.now < deadline else { return nil }
            return safariAddressBarAX.read(attribute, field)
        }
        guard safariAddressBarAX.processIdentifier(field) == target.application.processIdentifier,
              let role = read(kAXRoleAttribute as String) as? String,
              role == "AXTextField" || role == "AXComboBox",
              read("AXIdentifier") as? String == "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD",
              role != "AXSecureTextField",
              (read(kAXSubroleAttribute as String) as? String) != (kAXSecureTextFieldSubrole as String),
              (read("AXHidden") as? NSNumber)?.boolValue != true,
              (read("AXProtectedContent") as? NSNumber)?.boolValue != true,
              (read(kAXEnabledAttribute as String) as? NSNumber)?.boolValue == true,
              ContinuousClock.now < deadline, safariAddressBarAX.valueIsSettable(field),
              ContinuousClock.now < deadline else { return false }
        return addressFieldBelongsToRetainedWindow(field, target: target, deadline: deadline)
    }

    private enum ReturnPreparationReadiness {
        case ready
        case temporarilyUnavailable(String)
        case rejected(String)
    }

    private func returnPreparationReadiness(field: AXUIElement, target: Window, url: URL) -> ReturnPreparationReadiness {
        addressReadbackReadiness(field: field, target: target, url: url, previousValue: nil)
    }

    private func addressReadbackReadiness(field: AXUIElement, target: Window, url: URL,
                                          previousValue: String?) -> ReturnPreparationReadiness {
        guard let state = runState, let current = state.target, Self.sameWindow(current, target) else {
            return .rejected("return_window_changed")
        }
        guard state.currentFileOpenPanel == nil else { return .rejected("return_picker_present") }
        let fieldReadiness = safariAddressFieldReadiness(field, target: current)
        guard case .ready = fieldReadiness else { return fieldReadiness }
        switch focusedSafariAddressFieldReadiness(in: current, expected: field) {
        case .ready: break
        case .temporarilyUnavailable(let reason): return .temporarilyUnavailable(reason)
        case .rejected(let reason): return .rejected(reason)
        }
        guard let valueValue = safariAddressBarAX.read(kAXValueAttribute as String, field) else {
            return .temporarilyUnavailable("return_value_unavailable")
        }
        guard let value = valueValue as? String else { return .rejected("return_value_changed") }
        guard value != url.absoluteString else { return .ready }
        if let previousValue, value == previousValue {
            return .temporarilyUnavailable("return_value_unavailable")
        }
        return .rejected("return_value_changed")
    }

    private func isTransientValidationCaptureFailure(_ error: Error) -> Bool {
        guard lastValidationPhaseForDiagnostics == .capture,
              lastCaptureAXErrorCodeForDiagnostics == Int(AXError.cannotComplete.rawValue),
              let failure = error as? Failure,
              let reason = lastCaptureReasonForDiagnostics else { return false }
        switch (failure, reason) {
        case (.targetLost, "windows_read"), (.targetLost, "focused_window_read"),
             (.ambiguousWindows, "bounds_read"):
            return true
        default:
            return false
        }
    }

    private func safariAddressFieldReadiness(_ field: AXUIElement, target: Window) -> ReturnPreparationReadiness {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(750))
        func read(_ attribute: String) -> CFTypeRef? {
            guard ContinuousClock.now < deadline else { return nil }
            return safariAddressBarAX.read(attribute, field)
        }
        guard safariAddressBarAX.processIdentifier(field) == target.application.processIdentifier else {
            return .rejected("return_field_process_changed")
        }
        guard let roleValue = read(kAXRoleAttribute as String) else {
            return .temporarilyUnavailable("return_field_metadata_unavailable")
        }
        guard let role = roleValue as? String else { return .rejected("return_field_metadata_malformed") }
        guard role == "AXTextField" || role == "AXComboBox" else {
            return .rejected("return_field_role_changed")
        }
        guard let identifierValue = read("AXIdentifier") else {
            return .temporarilyUnavailable("return_field_metadata_unavailable")
        }
        guard let identifier = identifierValue as? String else {
            return .rejected("return_field_metadata_malformed")
        }
        guard identifier == "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD" else {
            return .rejected("return_field_identifier_changed")
        }
        if (read(kAXSubroleAttribute as String) as? String) == (kAXSecureTextFieldSubrole as String) {
            return .rejected("return_field_secure")
        }
        if (read("AXHidden") as? NSNumber)?.boolValue == true
            || (read("AXProtectedContent") as? NSNumber)?.boolValue == true {
            return .rejected("return_field_protected")
        }
        guard let enabledValue = read(kAXEnabledAttribute as String) else {
            return .temporarilyUnavailable("return_field_metadata_unavailable")
        }
        guard let enabled = enabledValue as? NSNumber else {
            return .rejected("return_field_metadata_malformed")
        }
        guard enabled.boolValue else { return .rejected("return_field_disabled") }
        guard ContinuousClock.now < deadline else {
            return .temporarilyUnavailable("return_field_observation_deadline")
        }
        guard safariAddressBarAX.valueIsSettable(field) else {
            return .rejected("return_field_not_writable")
        }
        guard ContinuousClock.now < deadline else {
            return .temporarilyUnavailable("return_field_observation_deadline")
        }
        guard addressFieldBelongsToRetainedWindow(field, target: target, deadline: deadline) else {
            return ContinuousClock.now >= deadline
                ? .temporarilyUnavailable("return_field_observation_deadline")
                : .rejected("return_field_window_unconfirmed")
        }
        return .ready
    }

    private func focusedSafariAddressFieldReadiness(in target: Window,
                                                     expected: AXUIElement) -> ReturnPreparationReadiness {
        let root = AXUIElementCreateApplication(target.application.processIdentifier)
        guard let focusedWindowValue = safariAddressBarAX.read(kAXFocusedWindowAttribute as String, root) else {
            return .temporarilyUnavailable("return_focus_unavailable")
        }
        guard CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return .rejected("return_focus_changed")
        }
        let focusedWindow = unsafeBitCast(focusedWindowValue, to: AXUIElement.self)
        guard CFEqual(focusedWindow, target.accessibilityElement) else {
            return .rejected("return_focus_changed")
        }
        guard let focusedValue = safariAddressBarAX.read(kAXFocusedUIElementAttribute as String, root) else {
            return .temporarilyUnavailable("return_focus_unavailable")
        }
        guard CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return .rejected("return_focus_changed")
        }
        let focused = unsafeBitCast(focusedValue, to: AXUIElement.self)
        guard CFEqual(focused, expected) else { return .rejected("return_focus_changed") }
        return .ready
    }

    private func waitForFocusedSafariAddressField(initiallyObserved: AXUIElement, target: Window,
                                                  taskID: String, goal: String,
                                                  tools: ComputerUseHostTools,
                                                  diagnostic: (String) -> Void) async throws -> AXUIElement {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let started = ContinuousClock.now
        var validationCount = 0
        var focusCheckCount = 0
        var reacquisitionCount = 0
        var validationElapsed = Duration.zero
        var focusCheckElapsed = Duration.zero
        var reacquisitionElapsed = Duration.zero
        var sawFocusedUIElement = false
        var sawInitiallyObservedField = false
        var sawReacquiredCurrentField = false
        func elapsedMilliseconds(_ duration: Duration) -> String {
            let components = duration.components
            return String(components.seconds * 1_000
                + components.attoseconds / 1_000_000_000_000_000)
        }
        func recordFailure(_ reason: String) {
            lastAddressFocusWaitDiagnostic = [
                "reason": reason,
                "validation_count": String(validationCount),
                "validation_elapsed_ms": elapsedMilliseconds(validationElapsed),
                "focus_check_count": String(focusCheckCount),
                "focus_check_elapsed_ms": elapsedMilliseconds(focusCheckElapsed),
                "reacquisition_count": String(reacquisitionCount),
                "reacquisition_elapsed_ms": elapsedMilliseconds(reacquisitionElapsed),
                "elapsed_ms": elapsedMilliseconds(started.duration(to: ContinuousClock.now)),
                "saw_focused_ui_element": String(sawFocusedUIElement),
                "saw_initial_field": String(sawInitiallyObservedField),
                "saw_reacquired_current_field": String(sawReacquiredCurrentField),
            ]
        }
        lastAddressFocusWaitDiagnostic = [:]
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try tools.requireActive()
            let validationStarted = ContinuousClock.now
            do {
                try validate(taskID: taskID, goal: goal, tools: tools)
            } catch let failure as Failure {
                validationCount += 1
                validationElapsed += validationStarted.duration(to: ContinuousClock.now)
                guard isTransientValidationCaptureFailure(failure), ContinuousClock.now < deadline else {
                    recordFailure("validation_failed")
                    throw failure
                }
                try await Task.sleep(for: .milliseconds(50))
                continue
            }
            validationCount += 1
            validationElapsed += validationStarted.duration(to: ContinuousClock.now)
            let focusStarted = ContinuousClock.now
            let focused = focusedSafariAddressField(in: target)
            focusCheckCount += 1
            focusCheckElapsed += focusStarted.duration(to: ContinuousClock.now)
            if let focused {
                sawFocusedUIElement = true
                let isInitiallyObserved = CFEqual(focused, initiallyObserved)
                if isInitiallyObserved { sawInitiallyObservedField = true }
                if isInitiallyObserved,
                   isCurrentSafariAddressField(focused, target: target),
                   ContinuousClock.now < deadline { return focused }
                let reacquisitionStarted = ContinuousClock.now
                let reacquired = try? uniqueSafariAddressField(in: target, diagnostic: diagnostic)
                reacquisitionCount += 1
                reacquisitionElapsed += reacquisitionStarted.duration(to: ContinuousClock.now)
                if let reacquired,
                   ContinuousClock.now < deadline,
                   isCurrentSafariAddressField(reacquired, target: target),
                   let currentFocus = focusedSafariAddressField(in: target), CFEqual(currentFocus, reacquired) {
                    sawReacquiredCurrentField = true
                    if ContinuousClock.now < deadline { return reacquired }
                }
            }
            if ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        }
        try Task.checkCancellation()
        try tools.requireActive()
        try validate(taskID: taskID, goal: goal, tools: tools)
        recordFailure("focus_deadline")
        diagnostic("phase=address_focus_observation_timeout")
        throw Failure.targetLost
    }

    private func focusedSafariAddressField(in target: Window) -> AXUIElement? {
        let root = AXUIElementCreateApplication(target.application.processIdentifier)
        guard let focusedWindowValue = safariAddressBarAX.read(kAXFocusedWindowAttribute as String, root),
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else { return nil }
        let focusedWindow = unsafeBitCast(focusedWindowValue, to: AXUIElement.self)
        guard CFEqual(focusedWindow, target.accessibilityElement),
              let focusedValue = safariAddressBarAX.read(kAXFocusedUIElementAttribute as String, root),
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(focusedValue, to: AXUIElement.self)
    }

    static func isSupportedGmailNavigationURL(_ url: URL) -> Bool {
        ComputerUseGmailAccountDirectory.accountIndex(from: url.absoluteString) != nil
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
        current = try captureForValidation(application: app, target: target, tools: tools)
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
                                      target: Window,
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
                            let currentSnapshot = try captureWindows(currentApp)
                            guard try Self.sameSnapshot(originalBefore, currentSnapshot) else {
                                throw Failure.interrupted
                            }
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
                                guard let state, let app = state.app, let originalBefore = state.before,
                                      try Self.sameSnapshot(originalBefore, captureWindows(app)) else {
                                    throw Failure.interrupted
                                }
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
        diagnostic: @MainActor (String) -> Void = { _ in }
    ) async throws -> Window {
        // A capture can spend up to two seconds reading Safari's window list;
        // keep observing for a delayed Cmd+N result without ever replaying it.
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        var transitionDiagnostics = 0
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try tools.requireActive()
            let after: WindowSnapshot
            do { after = try captureWindows(app) }
            catch Failure.targetLost, Failure.ambiguousWindows {
                // AX can briefly omit or incompletely enumerate windows while the new window appears.
                guard tools.frontmostApplicationSnapshot().identity == app else { throw Failure.targetLost }
                try await Task.sleep(for: .milliseconds(50))
                continue
            }
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
            if let target = Self.newFocusedWindow(before: before, after: after) { return target }
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
        throw Failure.noNewFocusedWindow
    }

    static func captureWindowsForApplication(
        _ application: ComputerUseApplicationIdentity,
        expectedWindow: Window? = nil,
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let root = AXUIElementCreateApplication(application.processIdentifier)
        var rootReadAXError: Int?
        func read(_ element: AXUIElement, _ attribute: CFString,
                  messagingTimeout: Float? = nil) -> CFTypeRef? {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            let isApplicationWindowRead = CFEqual(element, root)
                && (attribute == (kAXWindowsAttribute as CFString)
                    || attribute == (kAXFocusedWindowAttribute as CFString))
            AXUIElementSetMessagingTimeout(element, messagingTimeout ?? (isApplicationWindowRead ? 0.5 : 0.15))
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute, &value)
            guard result == .success else {
                if CFEqual(element, root), attribute == (kAXWindowsAttribute as CFString) {
                    rootReadAXError = Int(result.rawValue)
                    diagnostic("phase=capture_failure reason=windows_read ax_error=\(result.rawValue)")
                } else if CFEqual(element, root), attribute == (kAXFocusedWindowAttribute as CFString) {
                    rootReadAXError = Int(result.rawValue)
                    diagnostic("phase=capture_failure reason=focused_window_read ax_error=\(result.rawValue)")
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
        guard var elements = windowsValue as? [AXUIElement] else {
            diagnostic("phase=capture_failure reason=windows_unconvertible")
            throw Failure.targetLost
        }
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
        func string(_ element: AXUIElement, _ attribute: CFString) -> String? {
            read(element, attribute) as? String
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
            guard let raw = read(element, attribute), CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
            return raw as? [AXUIElement] ?? []
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
        func focusedWithin(_ focused: AXUIElement, _ root: AXUIElement) -> Bool {
            var current: AXUIElement? = focused
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
            let containsNativeFocus = focusedWithin(focusedElement, element)
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
                    pathFocused = focusedWithin(focusedUI, fields[0])
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
                bounds: bounds(panel)!, isFocused: focusedWithin(focusedElement, panel) || detachedGoToPathFieldFocused,
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

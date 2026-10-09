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
        let setValue: (AXUIElement, String) -> AXError

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
            }, setValue: { element, value in AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) })
        }
    }

    enum Failure: Error, Equatable {
        case changedTaskOrGoal, targetLost, ambiguousWindows, noNewFocusedWindow
        case existingWindowsChanged, interrupted, journalUncertain, authenticationHandoff, browserAutomationPermissionRequired
    }

    typealias ResolveHandler = @MainActor () throws -> ComputerUseDefaultBrowserTarget.Handler
    typealias LaunchApplication = @MainActor (ComputerUseDefaultBrowserTarget.Handler, @escaping @MainActor () throws -> Void) async throws -> ComputerUseApplicationIdentity
    typealias CaptureWindows = @MainActor (ComputerUseApplicationIdentity) throws -> WindowSnapshot

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

        init(taskID: String, goalDigest: String, sessionTaskID: String,
             handler: ComputerUseDefaultBrowserTarget.Handler) {
            self.taskID = taskID
            self.goalDigest = goalDigest
            self.sessionTaskID = sessionTaskID
            self.handler = handler
        }
    }

    private let journalDirectory: URL
    private let resolveHandler: ResolveHandler
    private let launchApplication: LaunchApplication
    private let captureWindows: CaptureWindows
    private let makeStore: (URL) throws -> ComputerUseTaskJournalStore
    private let safariAddressBarAX: SafariAddressBarAXAccess
    private var runState: RunState?
    var currentWindow: Window? { runState?.target }
    var currentFileOpenPanel: FileOpenPanel? { runState?.currentFileOpenPanel }
    var currentActionBounds: CGRect? { runState?.currentActionBounds }

    convenience init(journalDirectory: URL) throws {
        try self.init(journalDirectory: journalDirectory,
            resolveHandler: {
                guard let handler = ComputerUseDefaultBrowserTarget.currentDefaultHTTPSHandler() else {
                    throw ComputerUseDefaultBrowserTarget.Failure.noDefaultHandler
                }
                return handler
            },
            launchApplication: Self.launchVerifiedHandler,
            captureWindows: Self.captureWindowsForApplication)
    }

    init(journalDirectory: URL,
         resolveHandler: @escaping ResolveHandler,
         launchApplication: @escaping LaunchApplication,
         captureWindows: @escaping CaptureWindows,
         safariAddressBarAX: SafariAddressBarAXAccess = .live,
         makeStore: @escaping (URL) throws -> ComputerUseTaskJournalStore = { try .init(directory: $0) }) throws {
        self.journalDirectory = journalDirectory
        self.resolveHandler = resolveHandler
        self.launchApplication = launchApplication
        self.captureWindows = captureWindows
        self.safariAddressBarAX = safariAddressBarAX
        self.makeStore = makeStore
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
        try Task.checkCancellation()
        try tools.requireActive()
        guard let state = runState, state.taskID == taskID,
              state.goalDigest == ComputerUseTextTaskContract.digest(goal),
              let expected = state.target, let app = state.app else {
            throw Failure.changedTaskOrGoal
        }
        let current = try captureWindows(app)
        guard current.application == app,
              let focused = current.windows.first(where: { $0.id == expected.id }),
              Self.sameWindow(focused, expected) else {
            throw current.hasSheets ? Failure.authenticationHandoff : Failure.targetLost
        }
        let panel = current.fileOpenPanel
        if current.hasSheets {
            guard !current.hasUnrecognizedSheets, let panel,
                  panel.parentWindowID == expected.id,
                  CFEqual(panel.parentWindowElement, expected.accessibilityElement),
                  current.focusedWindowID == expected.id || panel.isFocused else {
                throw Failure.authenticationHandoff
            }
        } else {
            guard !current.hasUnrecognizedSheets, panel == nil,
                  current.focusedWindowID == expected.id else { throw Failure.targetLost }
        }
        state.target = focused // Refresh current geometry; bounds are not window authority.
        state.currentFileOpenPanel = panel
        state.currentActionBounds = panel?.actionBounds ?? focused.identity.bounds
    }

    /// Navigates through Safari's observed address field using only the
    /// already-authorized Accessibility and native input paths.
    func navigateRetainedSafariTab(to url: URL, taskID: String, goal: String,
                                   tools: ComputerUseHostTools,
                                   diagnostic: @MainActor (String) -> Void = { _ in }) async throws {
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
        guard !state.navigationDispatches.contains(url.absoluteString) else {
            diagnostic("phase=already_latched"); throw Failure.targetLost
        }
        let addressField: AXUIElement
        do { addressField = try uniqueSafariAddressField(in: target, diagnostic: diagnostic) }
        catch { diagnostic("phase=address_field_not_found"); throw error }
        try Task.checkCancellation()
        try tools.requireActive()
        try validate(taskID: taskID, goal: goal, tools: tools)
        if focusedSafariAddressField(in: target).map({ CFEqual($0, addressField) }) != true {
            let focusAction = ComputerUsePredictedAction.key(usage: 0x0F, modifiers: 1 << 3) // Command+L
            let focusFingerprint = try tools.prepareNativeActionFingerprint(for: focusAction)
            do {
                try await tools.performNativeAction(focusAction, fingerprint: focusFingerprint, willBeginEffect: {
                    try Task.checkCancellation()
                    try tools.requireActive()
                    try self.validate(taskID: taskID, goal: goal, tools: tools)
                    guard self.focusedSafariAddressField(in: target) != nil else { throw Failure.targetLost }
                })
            } catch { diagnostic("phase=address_field_focus_dispatch_failed"); throw error }
        }
        try Task.checkCancellation()
        try tools.requireActive()
        try validate(taskID: taskID, goal: goal, tools: tools)
        guard isCurrentSafariAddressField(addressField, target: target),
              let focusedField = focusedSafariAddressField(in: target), CFEqual(focusedField, addressField) else {
            diagnostic("phase=address_field_not_focused_before_navigation")
            throw Failure.targetLost
        }
        // Focus-only failures are safe to retry. Once the destination write
        // begins, a partial write or uncertain Return must not be replayed.
        state.navigationDispatches.insert(url.absoluteString)
        diagnostic("phase=ax_navigation_latched")
        let writeStatus = safariAddressBarAX.setValue(addressField, url.absoluteString)
        guard writeStatus == .success else {
            diagnostic("phase=ax_address_value_write_failed status=\(writeStatus.rawValue)")
            throw Failure.targetLost
        }
        try Task.checkCancellation()
        try tools.requireActive()
        try validate(taskID: taskID, goal: goal, tools: tools)
        guard
              focusedSafariAddressField(in: target).map({ CFEqual($0, addressField) }) == true,
              safariAddressBarAX.read(kAXValueAttribute as String, addressField) as? String == url.absoluteString else {
            diagnostic("phase=ax_address_value_readback_or_focus_mismatch")
            throw Failure.targetLost
        }
        let returnAction = ComputerUsePredictedAction.key(usage: 0x28, modifiers: 0)
        let fingerprint = try tools.prepareNativeActionFingerprint(for: returnAction)
        do {
            try await tools.performNativeAction(returnAction, fingerprint: fingerprint, willBeginEffect: {
                try Task.checkCancellation()
                try tools.requireActive()
                try self.validate(taskID: taskID, goal: goal, tools: tools)
                guard self.isCurrentSafariAddressField(addressField, target: target),
                      self.focusedSafariAddressField(in: target).map({ CFEqual($0, addressField) }) == true,
                      self.safariAddressBarAX.read(kAXValueAttribute as String, addressField) as? String == url.absoluteString else {
                    throw Failure.targetLost
                }
            })
        } catch { diagnostic("phase=return_dispatch_failed"); throw error }
        try Task.checkCancellation()
        try tools.requireActive()
        do { try validate(taskID: taskID, goal: goal, tools: tools) }
        catch { diagnostic("phase=post_navigation_scope_validation_failed"); throw error }
        guard let after = state.target, after.id == target.id,
              after.application == target.application else {
            diagnostic("phase=post_navigation_identity_mismatch")
            throw Failure.targetLost
        }
        diagnostic("phase=ax_navigation_dispatched")
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
        guard let state = runState, state.taskID == taskID, state.goalDigest == goalDigest,
              let target = state.target, let app = state.app else { throw Failure.targetLost }
        try tools.requireActive()
        let current = try captureWindows(app)
        guard current.application == app,
              let focused = current.windows.first(where: { $0.id == target.id }),
              Self.sameWindow(focused, target) else {
            throw current.hasSheets ? Failure.authenticationHandoff : Failure.targetLost
        }
        let panel = current.fileOpenPanel
        if current.hasSheets {
            guard !current.hasUnrecognizedSheets, let panel,
                  panel.parentWindowID == target.id,
                  CFEqual(panel.parentWindowElement, target.accessibilityElement),
                  current.focusedWindowID == target.id || panel.isFocused else {
                throw Failure.authenticationHandoff
            }
        } else {
            guard !current.hasUnrecognizedSheets, panel == nil,
                  current.focusedWindowID == target.id else { throw Failure.targetLost }
        }
        state.target = focused // Refresh current geometry; bounds are not window authority.
        state.currentFileOpenPanel = panel
        state.currentActionBounds = panel?.actionBounds ?? focused.identity.bounds
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
                .init(id: "new-window", entityID: "browser", kind: "focused-window", expectedDigest: authority),
            ],
            steps: [.init(id: "create-window", dependencies: [],
                operation: .init(capabilityID: "defaultBrowser.createWindow", entityID: "browser",
                    payloadDigest: authority, payloadVersion: 1),
                preconditions: ["handler-current"], postconditions: ["new-window"])],
            invariants: ["handler-current"], outcomes: ["new-window"])
        let store = try makeStore(journalDirectory)
        state.saved = try store.load(taskID: state.sessionTaskID)
        if let saved = state.saved, saved.promptDigest != goalDigest {
            throw ComputerUseTaskExecutionError.journalMismatch
        }
        let resolveHandler = self.resolveHandler
        let launchApplication = self.launchApplication
        let captureWindows = self.captureWindows
        let execution = try ComputerUseTaskExecution(contract: contract, recovered: state.saved,
            observe: { [weak state] predicate in
                guard let state else { throw ComputerUseTaskExecutionError.invalidContract }
                try Task.checkCancellation()
                try tools.requireActive()
                switch predicate.id {
                case "handler-current": return try resolveHandler() == state.handler
                case "new-window":
                    guard let app = state.app, let before = state.before, let target = state.target else { return false }
                    let current = try await Self.waitForNewFocusedWindow(
                        before: before, app: app, tools: tools, captureWindows: captureWindows)
                    return Self.sameWindow(current, target)
                default: return false
                }
            }, perform: { [weak state] step, _ in
                guard let state else { throw ComputerUseTaskExecutionError.invalidContract }
                guard step.id == "create-window" else { throw ComputerUseTaskExecutionError.invalidContract }
                try Task.checkCancellation()
                try tools.requireActive()
                let app = try await launchApplication(state.handler, {
                    try Task.checkCancellation()
                    try tools.requireActive()
                })
                try Task.checkCancellation()
                try tools.requireActive()
                try Self.validate(application: app, matches: state.handler)
                state.app = app
                let before = try await Self.waitForForegroundSnapshot(
                    app: app, tools: tools, captureWindows: captureWindows)
                state.before = before
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
                state.target = try await Self.waitForNewFocusedWindow(
                    before: before, app: app, tools: tools, captureWindows: captureWindows)
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

    private static func uniqueWindows(_ windows: [Window]) -> Bool {
        let identifiers = windows.map(\.id)
        guard identifiers.count == Set(identifiers).count else { return false }
        for index in windows.indices {
            for other in windows.indices where other > index {
                if CFEqual(windows[index].accessibilityElement, windows[other].accessibilityElement) { return false }
            }
        }
        return true
    }

    private static func sameWindow(_ lhs: Window, _ rhs: Window) -> Bool {
        // AX reference plus the exact app launch identifies the window. Bounds
        // are refreshed metadata and may change when the browser lays it out.
        lhs.id == rhs.id && lhs.application == rhs.application
            && CFEqual(lhs.accessibilityElement, rhs.accessibilityElement)
    }

    private static func sameSnapshot(_ lhs: WindowSnapshot, _ rhs: WindowSnapshot) throws -> Bool {
        guard lhs.application == rhs.application, !lhs.hasSheets, !rhs.hasSheets,
              lhs.focusedWindowID == rhs.focusedWindowID,
              uniqueWindows(lhs.windows), uniqueWindows(rhs.windows),
              lhs.windows.count == rhs.windows.count else { return false }
        return lhs.windows.allSatisfy { prior in
            rhs.windows.filter { sameWindow($0, prior) }.count == 1
        }
    }

    private static func singleNewWindow(before: WindowSnapshot, after: WindowSnapshot) -> Window? {
        guard before.application == after.application, !before.hasSheets, !after.hasSheets,
              uniqueWindows(before.windows), uniqueWindows(after.windows),
              after.windows.count == before.windows.count + 1 else { return nil }
        for prior in before.windows {
            guard after.windows.filter({ sameWindow($0, prior) }).count == 1 else { return nil }
        }
        let added = after.windows.filter { candidate in !before.windows.contains(where: { sameWindow($0, candidate) }) }
        return added.count == 1 ? added[0] : nil
    }

    private static func newFocusedWindow(before: WindowSnapshot, after: WindowSnapshot) -> Window? {
        guard let added = singleNewWindow(before: before, after: after),
              after.focusedWindowID == added.id else { return nil }
        return added
    }

    private static func isExactlyOneNewWindow(before: WindowSnapshot, after: WindowSnapshot, target: Window) -> Bool {
        guard let current = newFocusedWindow(before: before, after: after) else { return false }
        return sameWindow(current, target)
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(1.5))
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
        captureWindows: @escaping CaptureWindows
    ) async throws -> Window {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1.5))
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
            guard try Self.sameSnapshot(before, after) else { throw Failure.noNewFocusedWindow }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        try tools.requireActive()
        throw Failure.noNewFocusedWindow
    }

    static func captureWindowsForApplication(
        _ application: ComputerUseApplicationIdentity
    ) throws -> WindowSnapshot {
        try Task.checkCancellation()
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              !frontmost.isTerminated, frontmost.processIdentifier == application.processIdentifier,
              frontmost.bundleIdentifier == application.bundleIdentifier,
              let identity = ComputerUseApplicationIdentity(runningApplication: frontmost),
              identity == application else { throw Failure.targetLost }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        func read(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.15)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
                  !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            return value
        }
        func value<T>(_ element: AXUIElement, _ attribute: CFString, _ type: AXValueType, _ result: inout T) -> Bool {
            guard let raw = read(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return false }
            return AXValueGetValue(raw as! AXValue, type, &result)
        }
        let root = AXUIElementCreateApplication(application.processIdentifier)
        guard let windowsValue = read(root, kAXWindowsAttribute as CFString),
              CFGetTypeID(windowsValue) == CFArrayGetTypeID(),
              let elements = windowsValue as? [AXUIElement],
              let focusedValue = read(root, kAXFocusedWindowAttribute as CFString),
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { throw Failure.targetLost }
        let focusedElement = focusedValue as! AXUIElement
        func string(_ element: AXUIElement, _ attribute: CFString) -> String? {
            read(element, attribute) as? String
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
        for element in elements {
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid == application.processIdentifier else {
                throw Failure.ambiguousWindows
            }
            var origin = CGPoint.zero
            var size = CGSize.zero
            guard value(element, kAXPositionAttribute as CFString, .cgPoint, &origin),
                  value(element, kAXSizeAttribute as CFString, .cgSize, &size),
                  origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else { throw Failure.ambiguousWindows }
            let bounds = CGRect(origin: origin, size: size)
            let hash = CFHash(element)
            let windowIdentity = ComputerUseFrontmostWindowCaptureIdentity(
                applicationProcessIdentifier: pid, accessibilityWindowHash: hash, bounds: bounds)
            let id = "\(pid):\(hash)"
            let window = Window(id: id, application: application,
                accessibilityElement: element, identity: windowIdentity)
            windows.append(window)
            // A background window's chooser or sign-in sheet does not own
            // input in this window. Keep all window identities for startup
            // comparison, but inspect sheets only under current native focus.
            guard focusedWithin(focusedElement, element) else { continue }
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
        guard uniqueWindows(windows),
              windows.filter({ CFEqual(focusedValue, $0.accessibilityElement) }).count <= 1 else {
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
                if let focusedUI = read(root, kAXFocusedUIElementAttribute as CFString),
                   CFGetTypeID(focusedUI) == AXUIElementGetTypeID() {
                    pathFocused = focusedWithin(focusedUI as! AXUIElement, fields[0])
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
                bounds: bounds(panel)!, isFocused: focusedWithin(focusedElement, panel),
                goToFolderBounds: goToBounds, pathTextFieldElement: pathField,
                selectedFileURLs: selectedURLs(in: listViews[0]),
                primaryActionElement: primaryButtons[0], primaryActionBounds: bounds(primaryButtons[0]),
                primaryActionEnabled: enabled, pathFieldIsFocused: pathFocused,
                pathFieldValue: pathValue, pathFieldSelection: pathSelection)
        } else if hasSheets {
            hasUnrecognizedSheets = true
        }
        guard let after = NSWorkspace.shared.frontmostApplication,
              !after.isTerminated,
              let afterIdentity = ComputerUseApplicationIdentity(runningApplication: after),
              afterIdentity == application, !Task.isCancelled, ContinuousClock.now < deadline else {
            throw Failure.targetLost
        }
        return WindowSnapshot(application: application, windows: windows,
            focusedWindowID: focusedID, hasSheets: hasSheets, fileOpenPanel: fileOpenPanel,
            hasUnrecognizedSheets: hasUnrecognizedSheets)
    }
}

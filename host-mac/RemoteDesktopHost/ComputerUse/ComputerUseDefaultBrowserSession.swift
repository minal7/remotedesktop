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
    }

    enum Failure: Error, Equatable {
        case changedTaskOrGoal, targetLost, ambiguousWindows, noNewFocusedWindow
        case existingWindowsChanged, interrupted, journalUncertain, authenticationHandoff
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
    private var runState: RunState?
    var currentWindow: Window? { runState?.target }

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
         makeStore: @escaping (URL) throws -> ComputerUseTaskJournalStore = { try .init(directory: $0) }) throws {
        self.journalDirectory = journalDirectory
        self.resolveHandler = resolveHandler
        self.launchApplication = launchApplication
        self.captureWindows = captureWindows
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
        guard current.application == app, !current.hasSheets,
              current.focusedWindowID == expected.id,
              let focused = current.windows.first(where: { $0.id == expected.id }),
              Self.sameWindow(focused, expected) else {
            throw current.hasSheets ? Failure.authenticationHandoff : Failure.targetLost
        }
        state.target = focused // Refresh current geometry; bounds are not window authority.
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
        guard current.application == app, !current.hasSheets,
              current.focusedWindowID == target.id,
              let focused = current.windows.first(where: { $0.id == target.id }),
              Self.sameWindow(focused, target) else {
            throw current.hasSheets ? Failure.authenticationHandoff : Failure.targetLost
        }
        state.target = focused // Refresh current geometry; bounds are not window authority.
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
                    let current = try captureWindows(app)
                    return current.application == app && !current.hasSheets
                        && current.focusedWindowID == target.id
                        && current.windows.contains(where: { Self.sameWindow($0, target) })
                        && Self.isExactlyOneNewWindow(before: before, after: current, target: target)
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
                try Task.checkCancellation()
                try tools.requireActive()
                let fingerprint = try tools.prepareNativeActionFingerprint(for: action)
                guard try Self.sameSnapshot(before, captureWindows(app)) else {
                    throw Failure.interrupted
                }
                try Task.checkCancellation()
                try tools.requireActive()
                try await tools.performNativeAction(action, fingerprint: fingerprint) { [weak state, captureWindows] in
                    try Task.checkCancellation()
                    try tools.requireActive()
                    guard let state, let app = state.app, let before = state.before,
                          try Self.sameSnapshot(before, captureWindows(app)) else {
                        throw Failure.interrupted
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

    private static func captureWindowsForApplication(
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
        var windows: [Window] = []
        var hasSheets = false
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
            if let sheetsValue = read(element, "AXSheets" as CFString),
               CFGetTypeID(sheetsValue) == CFArrayGetTypeID(), CFArrayGetCount(sheetsValue as! CFArray) > 0 {
                hasSheets = true
            }
            if let role = read(element, kAXRoleAttribute as CFString) as? String,
               role == "AXSheet" {
                hasSheets = true
            }
            let bounds = CGRect(origin: origin, size: size)
            let hash = CFHash(element)
            let windowIdentity = ComputerUseFrontmostWindowCaptureIdentity(
                applicationProcessIdentifier: pid, accessibilityWindowHash: hash, bounds: bounds)
            let id = "\(pid):\(hash)"
            windows.append(Window(id: id, application: application,
                accessibilityElement: element, identity: windowIdentity))
        }
        guard uniqueWindows(windows),
              windows.filter({ CFEqual(focusedValue, $0.accessibilityElement) }).count <= 1 else {
            throw Failure.ambiguousWindows
        }
        let focusedID = windows.first(where: { CFEqual(focusedValue, $0.accessibilityElement) })?.id
        guard let after = NSWorkspace.shared.frontmostApplication,
              !after.isTerminated,
              let afterIdentity = ComputerUseApplicationIdentity(runningApplication: after),
              afterIdentity == application, !Task.isCancelled, ContinuousClock.now < deadline else {
            throw Failure.targetLost
        }
        return WindowSnapshot(application: application, windows: windows,
            focusedWindowID: focusedID, hasSheets: hasSheets)
    }
}

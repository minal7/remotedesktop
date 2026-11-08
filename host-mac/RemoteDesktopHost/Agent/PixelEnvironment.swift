import AppKit
import ApplicationServices
import Foundation
import ImageIO
import OSLog
import ScreenCaptureKit
import UniformTypeIdentifiers

struct PixelEnvironmentReadiness {
    let ready: Bool
    let detail: String
    let activeBackend: String = "pixel"
}

@MainActor
final class PixelEnvironment: AgentEnvironment {
    private static let observationLog = Logger(subsystem: "com.threadmark.remotedesktop.host", category: "agent-observation")
    private func observationPhase(_ phase: String, since start: TimeInterval) {
        let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - start) * 1_000)
        Self.observationLog.notice("phase=\(phase, privacy: .public) elapsed_ms=\(elapsedMS, privacy: .public)")
    }
    typealias Picker = @MainActor ([String]) async throws -> String
    private enum PasteResult: Equatable { case matches, unchanged, unavailable }
    var followsFrontmostSurface: Bool { true }
    private let taskID: String
    private let injector: InputInjector
    private let registry: AgentAppRegistry
    private let directCandidate: AgentRegisteredApp?
    private let allowed: () -> Bool
    private let finder: AgentWebFileFinder?
    private let picker: Picker?
    let startURL: String?
    private let startApp: String?
    let requireCleanStart: Bool
    let expectedStartBundleID: String?
    private let capturePreference: PixelCapturePreference
    private let metadataURL: URL?
    private var snapshots: [String: Snapshot] = [:]
    private var stopped = false
    private var suspended = false
    private var didStart = false
    private var lastSnapshot: Snapshot?
    private var voiceOverlayDismissalNotePending = false
    private var voiceOverlayHistoryNotePending = false
    private var voiceOverlayEscapeSent = false
    private var voiceOverlayDetectedDuringCapture = false
#if DEBUG
    var firstObservation: AgentEvalFirstObservation?
#endif
    private(set) var actualCropMode: PixelCapturePreference

    init(taskID: String, injector: InputInjector, registry: AgentAppRegistry,
         allowed: @escaping () -> Bool, finder: AgentWebFileFinder? = nil, picker: Picker? = nil,
         directCandidate: AgentRegisteredApp? = nil, startURL: String? = nil, startApp: String? = nil,
         capturePreference: PixelCapturePreference = .frontmostWindow, metadataURL: URL? = nil,
         requireCleanStart: Bool = false) {
        self.taskID = taskID; self.injector = injector; self.registry = registry
        self.allowed = allowed; self.finder = finder; self.picker = picker; self.directCandidate = directCandidate
        self.startURL = startURL; self.startApp = startApp; self.requireCleanStart = requireCleanStart
#if DEBUG
        self.expectedStartBundleID = AgentEvalFirstObservation.expectedBundleID(
            startApp: startApp, startURL: startURL, registry: registry)
#else
        self.expectedStartBundleID = nil
#endif
        self.capturePreference = capturePreference; self.metadataURL = metadataURL
        actualCropMode = capturePreference
    }

    static func readiness() async -> PixelEnvironmentReadiness {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return .init(ready: false, detail: "No display is available for capture.") }
            var configuration = SCStreamConfiguration(); configuration.width = 2; configuration.height = 2
            configuration.showsCursor = false
            _ = try await SCScreenshotManager.captureImage(contentFilter: .init(display: display, excludingWindows: []), configuration: configuration)
            return .init(ready: true, detail: AXIsProcessTrusted() ? "Screenshot capture and Accessibility are available." : "Screenshot capture is available; Accessibility labels are unavailable.")
        } catch { return .init(ready: false, detail: "Screen capture is unavailable: \(error.localizedDescription)") }
    }

    static func captureNativeWindow(_ window: SCWindow, _ availableDisplays: [SCDisplay]? = nil) async throws -> NativeWindowCapture {
        let displays: [SCDisplay]
        if let availableDisplays { displays = availableDisplays }
        else { displays = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true).displays }
        guard let display = displays.first(where: { $0.frame.contains(window.frame) }) else { throw AgentEnvironmentError.unavailable("Window is not wholly on one display.") }
        let filter = SCContentFilter(display: display, including: [window]), info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)
        guard let plan = PixelGeometry.displayBoundWindowCaptureConfiguration(windowBounds: window.frame,
                displayBounds: displays.map(\.frame), pointPixelScale: scale) else { throw AgentEnvironmentError.unavailable("Exact window capture is unavailable.") }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: plan.configuration)
        guard image.width == plan.configuration.width, image.height == plan.configuration.height else { throw AgentEnvironmentError.unavailable("Captured pixels did not match window dimensions.") }
        return NativeWindowCapture(image: image,
            expectedPixelSize: CGSize(width: plan.configuration.width, height: plan.configuration.height),
            pointPixelScale: scale, contentRect: info.contentRect)
    }

    func observe(_ context: AgentObservationContext) async throws -> AgentFrame {
        let phaseStart = ProcessInfo.processInfo.systemUptime
        observationPhase("observe_begin", since: phaseStart)
        try checkActive()
#if DEBUG
        let validateStart = AgentEvalFirstObservation.requiresStartValidation(
            configured: requireCleanStart, isInitialObservation: !didStart)
#endif
        if !didStart { try await startIfNeeded(); didStart = true }
        observationPhase("startup_done", since: phaseStart)
        voiceOverlayEscapeSent = false
        voiceOverlayDetectedDuringCapture = false
        try await dismissSystemVoiceOverlayBeforeObservation()
        observationPhase("voice_overlay_done", since: phaseStart)
#if DEBUG
        let snapshot = try await (validateStart ? captureEvaluationStart() : captureSnapshotForObservation())
#else
        let snapshot = try await captureSnapshotForObservation()
#endif
        observationPhase("snapshot_done", since: phaseStart)
        try checkActive()
#if DEBUG
        if validateStart, firstObservation == nil {
            firstObservation = AgentEvalFirstObservation.capture(snapshot: snapshot,
                expectedBundleID: expectedStartBundleID, expectedURL: startURL)
        }
#endif
        try writeMetadata()
#if DEBUG
        let invalidStart = AgentEvalFirstObservation.isInvalidStart(validating: validateStart, receipt: firstObservation)
#else
        let invalidStart = requireCleanStart
#endif
        if invalidStart {
            throw AgentEnvironmentError.unavailable("Evaluation start state did not resolve to the requested app or URL in one frontmost window.")
        }
        lastSnapshot = snapshot
        snapshots[snapshot.identity] = snapshot
        if snapshots.count > 2, let old = snapshots.keys.first(where: { $0 != snapshot.identity }) { snapshots.removeValue(forKey: old) }
        let surface: AgentSurface = snapshot.url.map { .web(url: $0, title: snapshot.title) }
            ?? .app(bundleID: snapshot.bundleID, title: snapshot.title)
        let observation = AgentObservation(task: context.task, surface: surface,
            screenshot: snapshot.screenshot.base64EncodedString(), elements: snapshot.elements,
            focus: snapshot.focus, history: observationHistory(context.history), budget: context.budget)
        try observation.validate()
        observationPhase("observe_done", since: phaseStart)
        voiceOverlayHistoryNotePending = false
        let kind: AgentScope.Kind
        if case .web = surface { kind = .web } else { kind = .app }
        return .init(observation: observation, scope: .init(taskID: taskID, kind: kind, identity: snapshot.identity), defaultButtonEvidence: snapshot.marks?.defaultButtonEvidence ?? .unknown)
    }

    func resolve(_ action: AgentAction, in frame: AgentFrame) async throws -> AgentResolvedAction {
        try checkScope(frame.scope)
        let snapshot = snapshots[frame.scope.identity]
        var resolvedAction = action
        var resolutionNote: String?
        if case let .click(.point(x, y), _, _) = action,
           let snapshot,
           let screenPoint = Self.mapPoint(CGPoint(x: x, y: y),
                imageSize: CGSize(width: snapshot.image.width, height: snapshot.image.height),
                screenBounds: snapshot.screenBounds),
           let marks = snapshot.marks {
            let snap = PixelTargetSnapping.resolve(screenPoint, in: marks.marks,
                deadline: .now + .milliseconds(300))
            let resolved = PixelTargetSnapping.resolvedAction(action, originalPoint: screenPoint, snap: snap,
                imageSize: CGSize(width: snapshot.image.width, height: snapshot.image.height),
                screenBounds: snapshot.screenBounds)
            resolvedAction = resolved.action; resolutionNote = resolved.note
        }
        let targets = try AgentTargetBinding.targets(resolvedAction).compactMap { target -> AgentElement? in
            switch target {
            case let .element(id):
                guard let mark = frame.observation.elements.first(where: { $0.id == id }) else { throw AgentEnvironmentError.targetGone }
                try Self.requireSecure(mark); return mark
            case let .point(x, y):
                guard x.isFinite, y.isFinite else { throw AgentEnvironmentError.targetGone }
                if let hit = Self.hit(x: x, y: y, elements: frame.observation.elements) {
                    try Self.requireSecure(hit); return hit
                }
                return nil
            }
        }
        let label = PixelTargetContextLabel.resolveWithBoundaryContext(resolvedAction, targets: targets,
            imageSize: CGSize(width: snapshot?.image.width ?? 0, height: snapshot?.image.height ?? 0),
            screenBounds: snapshot?.screenBounds ?? .zero, marks: snapshot?.marks?.marks ?? []) { x, y in
                SystemBarriers.targetLabel(screenshot: frame.observation.screenshot, x: x, y: y)
            }
        let references = try Self.references(for: targets, marks: snapshot?.marks?.marks ?? [])
        return .init(action: resolvedAction, frame: frame, targets: targets, targetContextLabel: label,
            surfaceReadOnly: snapshot.map { AgentSafetyBoundary.readOnly(bundleID: $0.bundleID, appName: $0.appName) } ?? false,
            hostBinding: PixelResolvedTargets(references: references, resolutionNote: resolutionNote))
    }

    func rebind(_ resolved: AgentResolvedAction, in frame: AgentFrame) async throws -> AgentResolvedAction {
        try checkScope(frame.scope)
        let current = try resolved.targets.map { try PixelActionRebinding.rebind($0, in: frame.observation.elements) }
        let snapshot = snapshots[frame.scope.identity]
        var references: [Int: any PixelElementReference] = [:]
        for (expected, _) in zip(resolved.targets, current) {
            references[expected.id] = try PixelElementReferenceResolver.rebound(expected, in: snapshot?.marks?.marks ?? [])
        }
        let targetContextLabel = PixelTargetContextLabel.resolveWithBoundaryContext(resolved.action, targets: current,
            previous: resolved.targetContextLabel,
            imageSize: CGSize(width: snapshot?.image.width ?? 0, height: snapshot?.image.height ?? 0),
            screenBounds: snapshot?.screenBounds ?? .zero, marks: snapshot?.marks?.marks ?? []) { x, y in
                SystemBarriers.targetLabel(screenshot: frame.observation.screenshot, x: x, y: y)
            }
        let oldBindings = resolved.hostBinding as? PixelResolvedTargets
        return .init(action: resolved.action, frame: frame, targets: current,
            targetContextLabel: targetContextLabel,
            surfaceReadOnly: snapshot.map { AgentSafetyBoundary.readOnly(bundleID: $0.bundleID, appName: $0.appName) } ?? resolved.surfaceReadOnly,
            hostBinding: PixelResolvedTargets(references: references, resolutionNote: oldBindings?.resolutionNote))
    }

    static func requireDirectCandidate(_ name: String, expected: AgentRegisteredApp,
                                       registry: AgentAppRegistry, roots: [URL]) throws {
        let current = try registry.resolveDirect(name, roots: roots)
        guard current == expected else { throw AgentEnvironmentError.targetChanged }
    }

    func executeDirectOpen(_ resolved: AgentResolvedAction) async throws -> AgentExecutionResult {
        try checkScope(resolved.frame.scope)
        guard case let .openApp(name) = resolved.action, let directCandidate else { throw AgentEnvironmentError.unsupportedAction }
        let roots = AgentAppRegistry.directSearchRoots
        try Self.requireDirectCandidate(name, expected: directCandidate,
            registry: AgentAppRegistry(searchRoots: roots), roots: roots)
        try checkScope(resolved.frame.scope)
        let identity = try await ComputerUseHostTools.openInstalledApplication(
            named: name, mayAct: allowed, expectedURL: directCandidate.url)
        try checkActive()
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            try checkActive()
            if let frontmost = NSWorkspace.shared.frontmostApplication,
               frontmost.processIdentifier == identity.processIdentifier,
               frontmost.bundleIdentifier == identity.bundleIdentifier {
                lastSnapshot = nil
                return .init(status: .ok, result: "opened and verified app \(name)")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AgentEnvironmentError.unavailable("The app did not become frontmost.")
    }

    func execute(_ resolved: AgentResolvedAction) async throws -> AgentExecutionResult {
        try checkScope(resolved.frame.scope)
        let startWindow = await frontWindowIdentity()
        try checkActive()
        if let snapshot = snapshots[resolved.frame.scope.identity] { lastSnapshot = snapshot }
        let bindings = resolved.hostBinding as? PixelResolvedTargets
        var detail: String
        switch resolved.action {
        case let .click(target, button, count):
            try click(try screenPoint(target, frame: resolved.frame, targets: resolved.targets, bindings: bindings), button: button ?? .left, count: count ?? 1)
            detail = "clicked \(targetLabel(target, resolved: resolved))"
        case let .drag(from, to):
            try drag(try screenPoint(from, frame: resolved.frame, targets: resolved.targets, bindings: bindings), to: screenPoint(to, frame: resolved.frame, targets: resolved.targets, bindings: bindings))
            detail = "dragged \(targetLabel(from, resolved: resolved)) to \(targetLabel(to, resolved: resolved))"
        case let .scroll(target, direction, amount):
            let point = target.map { try? screenPoint($0, frame: resolved.frame, targets: resolved.targets, bindings: bindings) } ?? nil
            let origin = try point ?? screenPoint(.point(x: Double(lastSnapshot?.image.width ?? 0) / 2,
                y: Double(lastSnapshot?.image.height ?? 0) / 2), frame: resolved.frame, targets: resolved.targets, bindings: bindings)
            let distance = Int(min(amount, 10_000).rounded())
            let dx = direction == .right ? distance : direction == .left ? -distance : 0
            let dy = direction == .down ? -distance : direction == .up ? distance : 0
            try post(.scroll(x: Int(origin.x), y: Int(origin.y), dx: dx, dy: dy, phase: .changed))
            detail = "scrolled \(direction.rawValue) at \(target.map { targetLabel($0, resolved: resolved) } ?? "window center")"
        case let .type(target, text, mode):
            let result = try await type(text, mode: mode, target: target, frame: resolved.frame, targets: resolved.targets, bindings: bindings)
            detail = result
        case let .key(chord):
            let stroke = try AgentKeyStroke.parse(chord)
            try injector.applyHostKeyStroke(usage: stroke.usage, modifiers: stroke.modifiers,
                ifAllowed: inputAllowed, beforePosting: { _ = try ensureNonSecureFocus(activationStroke: stroke) })
            detail = "pressed \(chord)"
        case let .select(target, option):
            detail = try await select(option, target: target, frame: resolved.frame, targets: resolved.targets, bindings: bindings)
        case let .openURL(url):
            guard HostAgentAllowPolicy.isAllowedURL(url), let parsed = URL(string: url) else { throw AgentEnvironmentError.unsupportedAction }
            try hostEffect { _ = NSWorkspace.shared.open(parsed) }
            detail = "opened URL in the default browser"; lastSnapshot = nil
        case let .openApp(name):
            try await registry.open(registry.resolve(name)); detail = "opened app \(name)"; lastSnapshot = nil
        case let .findFiles(query, kind, modifiedAfter):
            guard let finder else { throw AgentEnvironmentError.unavailable("Local file search is unavailable.") }
            let candidates = try await finder(query, kind, modifiedAfter).prefix(8)
            try await Task.sleep(for: .milliseconds(300))
            try checkActive()
            return .init(status: .ok, result: resultLine(try AgentFileResults.render(Array(candidates))))
        case let .setFiles(target, ids):
            try click(try screenPoint(target, frame: resolved.frame, targets: resolved.targets, bindings: bindings), button: .left, count: 1)
            guard let picker else { throw AgentEnvironmentError.unavailable("The native file picker is unavailable.") }
            detail = try await picker(ids)
        case let .wait(seconds):
            try await Task.sleep(for: .seconds(min(10, max(0, seconds)))); detail = "waited \(seconds) seconds"
        case .askUser, .done, .fail: throw AgentEnvironmentError.unsupportedAction
        }
        try checkActive()
        try await Task.sleep(for: .milliseconds(300))
        try checkActive()
        let currentApplication = NSWorkspace.shared.frontmostApplication
        let sameApplication = snapshots[resolved.frame.scope.identity]?.application?.processIdentifier
            == currentApplication?.processIdentifier
        let afterAXState = currentAXState(for: snapshots[resolved.frame.scope.identity], sameApplication: sameApplication)
        let endWindow = await frontWindowIdentity()
        let changed = startWindow != endWindow ? "yes" : "no"
        if let note = bindings?.resolutionNote { detail = "\(note); \(detail)" }
        let diff = PixelAXDiff.describe(before: snapshots[resolved.frame.scope.identity]?.marks?.axState,
            after: afterAXState, sameApplication: sameApplication, windowChanged: changed == "yes")
        let summary = diff.isEmpty ? "window changed: \(changed)" : diff.joined(separator: "; ")
        return .init(status: .ok, result: resultLine("\(detail) → \(summary)"))
    }

    func suspend() async {
        suspended = true
        injector.stopAutomation {}
    }
    func resume() async throws { guard !stopped else { throw CancellationError() }; suspended = false }
    func stop() async {
        stopped = true
        injector.stopAutomation {}
    }

    func captureSnapshot() async throws -> Snapshot {
        let phaseStart = ProcessInfo.processInfo.systemUptime
        observationPhase("capture_begin", since: phaseStart)
        try checkActive()
        let app = NSWorkspace.shared.frontmostApplication
        guard !AgentSafetyBoundary.blocksAutomation(bundleID: app?.bundleIdentifier, appName: app?.localizedName) else {
            throw AgentEnvironmentError.unavailable("This app is outside the computer-use boundary.")
        }
        let appRoot = app.map { AXUIElementCreateApplication($0.processIdentifier) }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        observationPhase("shareable_content_done", since: phaseStart)
        let blockedWindows = content.windows.filter { window in
            AgentSafetyBoundary.blocksAutomation(bundleID: window.owningApplication?.bundleIdentifier,
                appName: window.owningApplication?.applicationName)
        }
        let appOwnedWindows = content.windows.filter { $0.owningApplication?.processID == app?.processIdentifier }
        let appWindows = appOwnedWindows.filter {
            $0.windowID != 0 && $0.windowLayer == 0 && $0.frame.width > 50 && $0.frame.height > 50
        }
        let axWindows = appRoot.flatMap(ElementMarks.applicationWindows)
        var visibleAppWindowCount = appWindows.count
        if let app, let axWindows {
            visibleAppWindowCount = 0
            for window in appWindows {
                let matching = axWindows.filter { axWindow in
                    guard let bounds = ElementMarks.bounds(axWindow) else { return false }
                    return AgentMacAccessibility.matchingWindowID(ownerPID: app.processIdentifier, bounds: bounds,
                        focusedTitle: ElementMarks.string(axWindow, kAXTitleAttribute)) == window.windowID
                }
                guard matching.count == 1 else { visibleAppWindowCount += 1; continue }
                switch ElementMarks.classifyAXWindow(matching[0], appPID: app.processIdentifier, cgWindowID: window.windowID) {
                case .window, .unknown: visibleAppWindowCount += 1
                case .notAppWindow: break
                case .systemOverlay:
                    let inputState = appRoot.map { ElementMarks.systemVoiceOverlayInputState(matching[0], appRoot: $0) } ?? .unknown
                    if inputState == .nonblocking { continue }
                    guard inputState == .blocking else { visibleAppWindowCount += 1; continue }
                    voiceOverlayDetectedDuringCapture = true
                    throw SystemVoiceOverlayFailure.detected
                }
            }
        }
        let focusSelection = PixelAttachedSheetOwner.resolve(appRoot.flatMap(ElementMarks.focusedWindow),
            appPID: app?.processIdentifier ?? 0, deadline: ContinuousClock.now + .milliseconds(120))
        let focusedSheet = focusSelection.sheet, selectedAXWindow = focusSelection.window
        let focusedBounds = selectedAXWindow.flatMap(ElementMarks.bounds)
        let target: SCWindow? = app.flatMap { application in
            guard let selectedAXWindow, let focusedBounds else { return nil }
            let title = ElementMarks.string(selectedAXWindow, kAXTitleAttribute)
            guard let windowID = AgentMacAccessibility.matchingWindowID(ownerPID: application.processIdentifier,
                bounds: focusedBounds, focusedTitle: title, requireUnique: focusedSheet != nil) else { return nil }
            return appWindows.first(where: { $0.windowID == windowID &&
                ElementMarks.focusedWindowMatches(focusedBounds, selectedBounds: $0.frame) })
        }
        let mainTarget: SCWindow? = {
            guard focusedSheet == nil, target == nil, let application = app, let appRoot, let mainWindow = ElementMarks.mainWindow(appRoot), let bounds = ElementMarks.bounds(mainWindow) else { return nil }
            let title = ElementMarks.string(mainWindow, kAXTitleAttribute)
            guard let windowID = AgentMacAccessibility.matchingWindowID(ownerPID: application.processIdentifier,
                bounds: bounds, focusedTitle: title, requireUnique: true) else { return nil }
            return appWindows.first { $0.windowID == windowID && ElementMarks.focusedWindowMatches(bounds, selectedBounds: $0.frame) }
        }()
        let actionTarget = target ?? mainTarget, usesMainFallback = (target == nil && mainTarget != nil) || focusedSheet != nil
        let displayForWindow = actionTarget.flatMap { window in
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            return content.displays.first(where: { $0.frame.contains(center) })
                ?? content.displays.max { lhs, rhs in
                    let left = lhs.frame.intersection(window.frame), right = rhs.frame.intersection(window.frame)
                    return left.width * left.height < right.width * right.height
                }
        }
        guard let display = displayForWindow ?? content.displays.first else {
            throw AgentEnvironmentError.unavailable("No display can be captured.")
        }
        var axWindow: AgentMacAccessibility.Window?
        if AXIsProcessTrusted(), let app, let target, let selectedAXWindow {
            axWindow = AgentMacAccessibility.Window(application: app, element: selectedAXWindow,
                bounds: target.frame, number: target.windowID, title: target.title ?? "")
        }
        let marks: PixelElementMarks?
        observationPhase("window_selection_done", since: phaseStart)
        if AXIsProcessTrusted(), let app, let appRoot {
            marks = ElementMarks.readCapture(window: axWindow, focusedWindowElement: selectedAXWindow,
                focusedBounds: axWindow == nil ? nil : focusedBounds, appRoot: appRoot, application: app,
                selectedBounds: target?.frame ?? display.frame)
        } else { marks = nil }
        observationPhase("accessibility_done", since: phaseStart)
        if marks?.requiresProtectedRegionHandoff == true {
            throw AgentEnvironmentError.systemHandoff(
                "A protected window surface could not be verified safely. Inspect the Mac and tap Resume.")
        }
        var image: CGImage
        var captureBounds: CGRect
        var identity: String
        var windowCapture = false
        if capturePreference == .frontmostWindow, let target, focusedSheet == nil {
            do {
                let captured = try await Self.captureNativeWindow(target, content.displays)
                image = captured.image
                captureBounds = target.frame; identity = axWindow?.identity ?? "window:\(target.windowID)"; windowCapture = true
            } catch {
                image = try await capture(display, excluding: blockedWindows); captureBounds = display.frame; identity = "display:\(display.displayID)"
            }
        } else {
            image = try await capture(display, excluding: blockedWindows); captureBounds = display.frame; identity = "display:\(display.displayID)"
        }
        observationPhase("screen_capture_done", since: phaseStart)
        var screenshotBounds = captureBounds
        if windowCapture, let resized = PixelGeometry.resize(image, width: 1280), let target {
            image = resized; screenshotBounds = target.frame; actualCropMode = .frontmostWindow
        } else if !usesMainFallback, capturePreference == .frontmostWindow, let rect = marks?.contentRect ?? target?.frame,
           let crop = PixelGeometry.cropWithBounds(image, screenRect: rect, captureBounds: captureBounds) {
            image = PixelGeometry.resize(crop.image, width: 1280) ?? crop.image
            screenshotBounds = crop.screenBounds; actualCropMode = .frontmostWindow
        } else if windowCapture { actualCropMode = .frontmostWindow }
        else { actualCropMode = .fullDisplay }
        try checkActive()
        let pixelSize = CGSize(width: image.width, height: image.height)
        let elements = (marks?.marks ?? []).compactMap { mark -> AgentElement? in
            guard let bbox = PixelGeometry.imageRect(mark.screenRect, captureBounds: screenshotBounds, imageSize: pixelSize) else {
                guard mark.state.contains("read_only") else { return nil }
                return AgentElement(id: mark.id, role: mark.role, name: mark.name, value: nil,
                    state: mark.state, bbox: .init(x: 0, y: 0, width: 0, height: 0), inView: false)
            }
            return AgentElement(id: mark.id, role: mark.role, name: mark.name, value: nil, state: mark.state,
                bbox: .init(x: bbox.minX, y: bbox.minY, width: bbox.width, height: bbox.height), inView: mark.inView)
        }
        let focus = marks?.focusedID.flatMap { id in elements.first(where: { $0.id == id }).map {
            AgentFocus(id: $0.id, role: $0.role, name: $0.name, valuePrefix: "", selection: .init(start: 0, end: 0))
        } }
        let secureRects = (marks?.secureScreenRects ?? []).compactMap { PixelGeometry.imageRect($0, captureBounds: screenshotBounds, imageSize: pixelSize) }
        let png = try encode(image, masking: secureRects)
        observationPhase("redacted_encoding_done", since: phaseStart)
        let handoffReason = try await SystemBarriers.handoffReason(
            screenshot: png, elements: elements, focus: focus)
        observationPhase("barrier_check_done", since: phaseStart)
        try checkActive()
        if let reason = handoffReason {
            throw AgentEnvironmentError.systemHandoff(reason)
        }
        return .init(window: axWindow, application: app, identity: identity, bundleID: app?.bundleIdentifier ?? "unknown",
            appName: app?.localizedName ?? "",
            title: actionTarget?.title ?? "Visible desktop", url: marks?.browserURL, image: image, screenshot: png,
            elements: elements, focus: focus, screenBounds: screenshotBounds,
            activeWindowBounds: actionTarget?.frame, activeWindowNumber: actionTarget?.windowID,
            activeWindowOwnerProcessID: actionTarget?.owningApplication?.processID,
            visibleWindowCount: visibleAppWindowCount, marks: marks,
            attachedSheetIdentity: focusedSheet.flatMap { target == nil ? nil : PixelTypingFocusBinding.identity($0) })
    }

    private func dismissSystemVoiceOverlayBeforeObservation() async throws {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return }
        // Observing protected/read-only apps is still handled by captureSnapshot;
        // never send a cleanup keystroke to them.
        if AgentSafetyBoundary.blocksAutomation(bundleID: app.bundleIdentifier, appName: app.localizedName) ||
            AgentSafetyBoundary.readOnly(bundleID: app.bundleIdentifier, appName: app.localizedName) { return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        do {
            if try await ElementMarks.dismissSystemVoiceOverlayIfPresent(app: app, appRoot: root,
                injector: injector, escapeAlreadySent: voiceOverlayEscapeSent,
                onEscapeSent: {
                    self.voiceOverlayEscapeSent = true
                }, canInject: {
                self.inputAllowed() && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
            }) {
                voiceOverlayDismissalNotePending = true
                voiceOverlayHistoryNotePending = true
                return
            }
        } catch is CancellationError { throw CancellationError() }
        catch let failure as SystemVoiceOverlayFailure {
            if case .persists = failure { try? writeMetadata() }
            throw failure.environmentError
        } catch {
            try? writeMetadata()
            throw AgentEnvironmentError.systemHandoff("The system overlay could not be safely dismissed; inspect the Mac and tap Resume")
        }
    }

    func captureSnapshotForObservation() async throws -> Snapshot {
        do { return try await captureSnapshot() }
        catch SystemVoiceOverlayFailure.detected {
            do {
                try await dismissSystemVoiceOverlayBeforeObservation()
                return try await captureSnapshot()
            } catch {
                try? writeMetadata()
                if let failure = error as? SystemVoiceOverlayFailure { throw failure.environmentError }
                throw error
            }
        }
    }

    private func observationHistory(_ history: [AgentHistoryItem]) -> [AgentHistoryItem] {
        guard voiceOverlayHistoryNotePending else { return history }
        return history + [.init(action: nil, result: "dismissed a system voice overlay")]
    }

    private func resultLine(_ value: String) -> String {
        guard voiceOverlayDismissalNotePending else { return value }
        voiceOverlayDismissalNotePending = false
        return "dismissed a system voice overlay; \(value)"
    }

    private func capture(_ display: SCDisplay, excluding windows: [SCWindow]) async throws -> CGImage {
        let height = max(1, Int(1280 * display.frame.height / display.frame.width)); guard let size = PixelGeometry.boundedPixelSize(width: 1280, height: height, maximumWidth: 1280) else { throw AgentEnvironmentError.unavailable("Could not bound the display capture size.") }
        var config = SCStreamConfiguration(); config.width = size.width; config.height = size.height; config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: .init(display: display, excludingWindows: windows), configuration: config)
    }

    private func type(_ text: String, mode: AgentTextMode, target: AgentTarget?, frame: AgentFrame,
                      targets: [AgentElement], bindings: PixelResolvedTargets?) async throws -> String {
        guard let snapshot = snapshots[frame.scope.identity] else { throw AgentEnvironmentError.targetGone }
        if let target { try click(screenPoint(target, frame: frame, targets: targets, bindings: bindings), button: .left, count: 1) }
        let (focused, typingBinding) = try PixelTypingFocusBinding.current(in: snapshot)
        guard typingBinding.attachedSheet == snapshot.attachedSheetIdentity else { throw AgentEnvironmentError.scopeChanged }
        let name = ElementMarks.label(focused)
        let expectedMark = targets.first ?? (target == nil ? frame.observation.focus.flatMap { focus in
            frame.observation.elements.first(where: { $0.id == focus.id })
        } : nil)
        if let expectedMark,
           AgentCredentialRule.isSensitive(role: expectedMark.role, name: expectedMark.name, state: expectedMark.state) {
            throw AgentEnvironmentError.credentialHandoff
        }
        let oldValue = ElementMarks.string(focused, kAXValueAttribute)
        let selection = PixelTextInsertion.selectedRange(focused, valueLength: oldValue?.utf16.count)
        let expectedValue = PixelTextInsertion.expectedValue(oldValue: oldValue, inserted: text,
            mode: mode, selection: selection)
        let pasted = try await paste(text, replace: mode == .replace, oldValue: oldValue,
            expectedValue: expectedValue, expectedFocus: focused, snapshot: snapshot, binding: typingBinding)
        let status = pasted == .matches ? "matches" : pasted == .unchanged ? "unchanged" : "unverified"
        return "typed \(text.count) chars\(name.isEmpty ? "" : " into \"\(name)\"") → read-back \(status)"
    }

    private func paste(_ text: String, replace: Bool, oldValue: String?, expectedValue: String?,
                       expectedFocus: AXUIElement, snapshot: Snapshot,
                       binding: PixelTypingFocusBinding) async throws -> PasteResult {
        guard text.utf8.count <= 65_536 else { throw AgentEnvironmentError.unsupportedAction }
        let lease = PixelClipboardLease(board: .general, text: text)
        defer { lease.restore() }
        if replace { try postClipboardKey("cmd+a", typingSnapshot: snapshot, binding: binding) }
        try postClipboardKey("cmd+v", typingSnapshot: snapshot, binding: binding)
        try await Task.sleep(for: .milliseconds(300))
        let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let processID, let currentFocus = ElementMarks.focusedElement(AXUIElementCreateApplication(processID)) {
            let currentRole = ElementMarks.string(currentFocus, kAXRoleAttribute) ?? "unknown"
            let currentName = ElementMarks.label(currentFocus)
            if ElementMarks.isSensitive(currentFocus, role: currentRole, name: currentName) { throw AgentEnvironmentError.credentialHandoff }
            guard CFEqual(currentFocus, expectedFocus) else { return .unavailable }
            let readback = PixelTextInsertion.readback(current: ElementMarks.string(currentFocus, kAXValueAttribute),
                oldValue: oldValue, expectedValue: expectedValue)
            switch readback {
            case .matches: return .matches
            case .unchanged: return .unchanged
            case .unverified: return .unavailable
            }
        }
        return .unavailable
    }

    private func postClipboardKey(_ chord: String, typingSnapshot: Snapshot? = nil, binding: PixelTypingFocusBinding? = nil) throws {
        let stroke = try AgentKeyStroke.parse(chord)
        try injector.applyHostKeyStroke(usage: stroke.usage, modifiers: stroke.modifiers,
            ifAllowed: inputAllowed, beforePosting: {
                if let typingSnapshot, let binding {
                    _ = try PixelTypingFocusBinding.current(in: typingSnapshot, binding: binding)
                } else {
                    _ = try ensureNonSecureFocus()
                }
            })
    }

    private func select(_ option: String, target: AgentTarget, frame: AgentFrame, targets: [AgentElement],
                        bindings: PixelResolvedTargets?) async throws -> String {
        guard let snapshot = snapshots[frame.scope.identity] else { throw AgentEnvironmentError.targetGone }
        let window = snapshot.window
        try click(screenPoint(target, frame: frame, targets: targets, bindings: bindings), button: .left, count: 1)
        let menu = window.map { ElementMarks.read(window: $0) }
        if let mark = menu?.marks.first(where: { $0.role == "AXMenuItem" && $0.name == option }),
           !mark.screenRect.isEmpty {
            try click(CGPoint(x: mark.screenRect.midX, y: mark.screenRect.midY), button: .left, count: 1); return "selected \"\(option)\""
        }
        let result = try await type(option, mode: .replace, target: nil, frame: frame, targets: [], bindings: bindings)
        try ensureNonSecureFocus()
        try postClipboardKey("enter")
        return "\(result); pressed Return"
    }

    private func screenPoint(_ target: AgentTarget, frame: AgentFrame, targets: [AgentElement],
                             bindings: PixelResolvedTargets?) throws -> CGPoint {
        guard let snapshot = snapshots[frame.scope.identity] else { throw AgentEnvironmentError.targetGone }
        guard let activeWindowBounds = snapshot.activeWindowBounds, !activeWindowBounds.isEmpty else {
            throw AgentEnvironmentError.unavailable("point is outside the active window \"\(snapshot.title)\"; use open_app to switch apps")
        }
        let size = CGSize(width: snapshot.image.width, height: snapshot.image.height)
        let pixel: CGPoint
        switch target {
        case let .element(id):
            guard let element = targets.first(where: { $0.id == id }) else { throw AgentEnvironmentError.targetGone }
            try Self.requireSecure(element)
            guard let application = snapshot.application,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
                throw AgentEnvironmentError.targetGone
            }
            guard let reference = bindings?.references[id] else { throw AgentEnvironmentError.targetGone }
            let dialogs = snapshot.marks?.overlayBounds ?? []
            let menuBar = (snapshot.marks?.marks.filter { $0.role == "AXMenuBarItem" }.map(\.screenRect) ?? [])
                + menuBarBounds()
            let expandedBounds = (dialogs + menuBar).reduce(activeWindowBounds) { $0.union($1) }
            let point = try PixelElementReferenceResolver.currentCentre(element, reference: reference,
                windowBounds: expandedBounds, note: { bindings?.appendResolutionNote($0) })
            try requireActiveWindowPoint(point, snapshot: snapshot, dialogs: dialogs, menuBar: menuBar)
            return point
        case let .point(x, y): pixel = CGPoint(x: x, y: y)
        }
        guard let mapped = Self.mapPoint(pixel, imageSize: size, screenBounds: snapshot.screenBounds) else {
            throw AgentEnvironmentError.targetGone
        }
        try requireActiveWindowPoint(mapped, snapshot: snapshot)
        return mapped
    }

    private func requireActiveWindowPoint(_ point: CGPoint, snapshot: Snapshot,
                                          dialogs: [CGRect]? = nil,
                                          menuBar suppliedMenuBar: [CGRect]? = nil) throws {
        guard let windowBounds = snapshot.activeWindowBounds else {
            throw AgentEnvironmentError.unavailable("point is outside the active window \"\(snapshot.title)\"; use open_app to switch apps")
        }
        let marks = snapshot.marks?.marks ?? []
        let menuBar = suppliedMenuBar ?? (marks.filter { $0.role == "AXMenuBarItem" }.map(\.screenRect) + menuBarBounds())
        let dialogBounds = dialogs ?? snapshot.marks?.overlayBounds ?? []
        guard PixelWindowActionBoundary.allows(point, windowBounds: windowBounds,
            menuBarBounds: menuBar, sameAppDialogBounds: dialogBounds) else {
            throw AgentEnvironmentError.unavailable("point is outside the active window \"\(snapshot.title)\"; use open_app to switch apps")
        }
    }

    private func menuBarBounds() -> [CGRect] {
        let screens = NSScreen.screens
        let mainID = CGMainDisplayID()
        let primaryMaxY = screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == mainID
        })?.frame.maxY ?? screens.first?.frame.maxY ?? 0
        return screens.compactMap { screen in
            let height = screen.frame.maxY - screen.visibleFrame.maxY
            guard height > 0 else { return nil }
            let appKitBar = CGRect(x: screen.frame.minX, y: screen.visibleFrame.maxY,
                width: screen.frame.width, height: height)
            return PixelGeometry.screenCaptureRect(fromAppKit: appKitBar, primaryScreenMaxY: primaryMaxY)
        }
    }

    private func click(_ point: CGPoint, button: AgentMouseButton, count: Int) throws {
        guard (1...3).contains(count) else { throw AgentEnvironmentError.unsupportedAction }
        guard inputAllowed() else { throw CancellationError() }
        let bit: UInt8 = button == .right ? 2 : button == .middle ? 4 : 1
        let path = PixelPersonalDataTargetGuard.descriptors(at: point)
        try PixelPersonalDataTargetGuard.performIfAllowed(path: path) {
            for _ in 0..<count {
                try post(.pointer(x: Int(point.x), y: Int(point.y), buttons: bit))
                try post(.pointer(x: Int(point.x), y: Int(point.y), buttons: 0))
            }
        }
    }

    private func drag(_ from: CGPoint, to: CGPoint) throws {
        let path = PixelPersonalDataTargetGuard.descriptors(at: from)
            + PixelPersonalDataTargetGuard.descriptors(at: to)
        try PixelPersonalDataTargetGuard.performIfAllowed(path: path) {
            try post(.pointer(x: Int(from.x), y: Int(from.y), buttons: 1))
            do {
                for step in 1...10 { let f = Double(step) / 10
                    try post(.pointer(x: Int(from.x + (to.x - from.x) * f), y: Int(from.y + (to.y - from.y) * f), buttons: 1))
                }
                try post(.pointer(x: Int(to.x), y: Int(to.y), buttons: 0))
            } catch { injector.releaseHeldInput(); throw error }
        }
    }

    private func targetLabel(_ target: AgentTarget, resolved: AgentResolvedAction) -> String {
        PixelExecutionDescription.targetLabel(target, resolvedTargets: resolved.targets,
            frameElements: resolved.frame.observation.elements)
    }

    private func currentAXState(for snapshot: Snapshot?, sameApplication: Bool) -> [PixelAXElementState]? {
        guard sameApplication, let snapshot, snapshot.marks != nil, AXIsProcessTrusted(),
              let window = snapshot.window else { return nil }
        let appRoot = AXUIElementCreateApplication(window.application.processIdentifier)
        guard let element = ElementMarks.focusedWindow(appRoot), let bounds = ElementMarks.bounds(element) else { return nil }
        return ElementMarks.read(window: .init(application: window.application, element: element, bounds: bounds,
            number: window.number, title: window.title)).axState
    }

    private func ensureNonSecureFocus(activationStroke: AgentKeyStroke? = nil) throws -> AXUIElement {
        let focused = try PixelFocusedRecipient.current(expectedPID: lastSnapshot?.application?.processIdentifier)
        let activationUsages: Set<Int> = [0x28, 0x2c]
        let shouldCheckRetrieval = activationStroke == nil || activationUsages.contains(activationStroke!.usage)
        if shouldCheckRetrieval {
            let path = PixelPersonalDataTargetGuard.descriptors(from: focused)
            try PixelPersonalDataTargetGuard.performIfAllowed(path: path) {}
        }
        return focused
    }

    private func startIfNeeded() async throws {
        if let startURL {
            guard let url = URL(string: startURL), HostAgentAllowPolicy.isAllowedURL(startURL) else { throw AgentEnvironmentError.unsupportedAction }
            try hostEffect { _ = NSWorkspace.shared.open(url) }
            try await Task.sleep(for: .milliseconds(300))
        }
        if let app = try startApp.map({ try registry.resolve($0) }), NSWorkspace.shared.frontmostApplication?.bundleIdentifier != app.bundleID { try await registry.open(app) }
    }

    private func frontWindowIdentity() async -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.owningApplication?.processID == app.processIdentifier }) else {
            return "pid:\(app.processIdentifier):\(app.launchDate?.timeIntervalSince1970 ?? 0)"
        }
        return "pid:\(app.processIdentifier):\(app.launchDate?.timeIntervalSince1970 ?? 0):window:\(window.windowID):\(window.title)"
    }

    private func writeMetadata() throws {
        guard let metadataURL else { return }
#if DEBUG
        try AgentEvalPixelMetadataRecord.write(to: metadataURL, cropMode: actualCropMode == .frontmostWindow ? "frontmost-window" : "full-display", firstObservation: firstObservation, escapeCount: voiceOverlayEscapeSent ? 1 : 0, detectedDuringCapture: voiceOverlayDetectedDuringCapture)
#endif
    }

    private func hostEffect(_ action: () throws -> Void) throws { try injector.performHostEffectIfAllowed(ifAllowed: inputAllowed, action) }
    private func post(_ event: ControlMessage) throws { guard injector.apply(event, ifAllowed: inputAllowed) else { throw CancellationError() } }
    private func inputAllowed() -> Bool {
        guard !stopped, !suspended, !Task.isCancelled, allowed() else { return false }
        if let application = lastSnapshot?.application {
            return NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
        }
        return true
    }
    func checkActive() throws { try Task.checkCancellation(); guard !stopped, !suspended, allowed() else { throw CancellationError() } }
    private func checkScope(_ scope: AgentScope) throws {
        try checkActive()
        guard scope.taskID == taskID, scope.kind == .app || scope.kind == .web else { throw AgentEnvironmentError.scopeChanged }
    }
    private func encode(_ image: CGImage, masking rects: [CGRect]) throws -> Data {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AgentEnvironmentError.unavailable("Could not encode screenshot.") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); context.setFillColor(CGColor(gray: 0, alpha: 1))
        for rect in rects { context.fill(CGRect(x: rect.minX, y: CGFloat(image.height) - rect.maxY, width: rect.width, height: rect.height)) }
        let data = NSMutableData(); guard let redacted = context.makeImage(), let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw AgentEnvironmentError.unavailable("Could not encode screenshot.") }
        CGImageDestinationAddImage(dest, redacted, nil); guard CGImageDestinationFinalize(dest) else { throw AgentEnvironmentError.unavailable("Could not encode screenshot.") }; return data as Data
    }

    private static func requireSecure(_ element: AgentElement) throws {
        guard !AgentContractValidation.isSecureRoleOrState(role: element.role, state: element.state) else { throw AgentEnvironmentError.credentialHandoff }
    }

    private static func references(for targets: [AgentElement], marks: [PixelElementMark]) throws -> [Int: any PixelElementReference] {
        var references: [Int: any PixelElementReference] = [:]
        for target in targets {
            references[target.id] = try PixelElementReferenceResolver.observed(target, in: marks)
        }
        return references
    }
    private static func requireSecure(role: String, name: String, state: [String]) throws {
        guard !AgentContractValidation.isSecureRoleOrState(role: role, state: state),
              !AgentCredentialRule.isSensitive(role: role, name: name, state: state) else {
            throw AgentEnvironmentError.credentialHandoff
        }
    }
    private static func hit(x: Double, y: Double, elements: [AgentElement]) -> AgentElement? {
        elements.filter { element in
            let box = element.bbox
            return x >= box.x && y >= box.y && x < box.x + box.width && y < box.y + box.height
        }.min { $0.bbox.width * $0.bbox.height < $1.bbox.width * $1.bbox.height }
    }
    static func mapPoint(_ pixel: CGPoint, imageSize: CGSize, screenBounds: CGRect) -> CGPoint? {
        guard pixel.x.isFinite, pixel.y.isFinite,
              imageSize.width.isFinite, imageSize.height.isFinite, imageSize.width > 0, imageSize.height > 0,
              screenBounds.minX.isFinite, screenBounds.minY.isFinite,
              screenBounds.width.isFinite, screenBounds.height.isFinite,
              screenBounds.width > 0, screenBounds.height > 0 else { return nil }
        return CGPoint(x: screenBounds.minX + pixel.x / imageSize.width * screenBounds.width,
            y: screenBounds.minY + pixel.y / imageSize.height * screenBounds.height)
    }
}

enum PixelActionRebinding {
    static func rebind(_ expected: AgentElement, in current: [AgentElement]) throws -> AgentElement {
        let matches = current.filter { $0.role == expected.role && $0.name == expected.name }
        guard matches.count == 1, let fresh = matches.first else {
            throw AgentEnvironmentError.targetGone
        }
        guard !AgentContractValidation.isSecureRoleOrState(role: fresh.role, state: fresh.state),
              !AgentCredentialRule.isSensitive(role: fresh.role, name: fresh.name, state: fresh.state) else {
            throw AgentEnvironmentError.credentialHandoff
        }
        return AgentElement(id: expected.id, role: expected.role, name: expected.name, value: nil,
            state: fresh.state, bbox: fresh.bbox, inView: fresh.inView)
    }
}

enum PixelScreenTargetResolver {
    static func point(for expected: AgentElement, in current: [PixelElementMark]) throws -> CGPoint {
        guard let mark = PixelTargetRebinding.find(expected, in: current) else {
            throw AgentEnvironmentError.targetGone
        }
        guard !AgentContractValidation.isSecureRoleOrState(role: mark.role, state: mark.state),
              !AgentCredentialRule.isSensitive(role: mark.role, name: mark.name, state: mark.state) else {
            throw AgentEnvironmentError.credentialHandoff
        }
        return CGPoint(x: mark.screenRect.midX, y: mark.screenRect.midY)
    }
}

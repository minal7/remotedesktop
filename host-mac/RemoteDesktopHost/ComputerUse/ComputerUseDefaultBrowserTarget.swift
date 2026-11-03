import AppKit
import ApplicationServices
import Foundation

/// Task-bound identity for one observed HTTPS handler process and AX window.
/// It deliberately does not identify a tab/document or prove page content.
@MainActor
struct ComputerUseDefaultBrowserTarget: Equatable {
    struct Handler: Equatable {
        let bundleURL: URL
        let bundleIdentifier: String
    }

    enum Failure: Error, Equatable {
        case invalidHTTPSURL, noDefaultHandler, openFailed
        case handlerIdentityMismatch, applicationNotCodeVerified
        case noUniqueFocusedWindow, staleTarget
    }

    let taskID: String
    let handler: Handler
    let application: ComputerUseApplicationIdentity
    let window: ComputerUseFrontmostWindowCaptureIdentity

    func validate(taskID: String, currentApplication: ComputerUseApplicationIdentity?,
                  currentWindow: ComputerUseFrontmostWindowCaptureIdentity?) throws {
        guard taskID == self.taskID, currentApplication == application,
              currentWindow == window,
              currentWindow?.applicationProcessIdentifier == application.processIdentifier else {
            throw Failure.staleTarget
        }
    }

    static func currentDefaultHTTPSHandler() -> Handler? {
        systemHTTPSHandler(URL(string: "https://example.invalid")!)
    }

    /// Read-only probe: no URL open, screenshot, or page-content read.
    static func currentDefaultHandlerForegroundWindow()
        -> (Handler, ComputerUseApplicationIdentity, ComputerUseFrontmostWindowCaptureIdentity)? {
        guard let handler = currentDefaultHTTPSHandler(),
              let running = NSWorkspace.shared.frontmostApplication,
              running.bundleIdentifier == handler.bundleIdentifier,
              let proof = ComputerUseReviewedApplicationCodeVerifier
                .proofForRunningApplication(runningApplication: running),
              proof.canonicalBundlePath == handler.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path,
              let identity = ComputerUseApplicationIdentity(
                runningApplication: running, codeIdentity: proof),
              let window = systemFocusedWindow(identity) else { return nil }
        return (handler, identity, window)
    }

    fileprivate static func systemHTTPSHandler(_ url: URL) -> Handler? {
        // Resolve the HTTPS browser using a neutral scheme probe, not a
        // destination that might have a site-specific application association.
        // Launch Services performs no network request for this lookup.
        guard url.scheme?.lowercased() == "https",
              let probe = URL(string: "https://example.invalid"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe)?
                .resolvingSymlinksInPath().standardizedFileURL,
              appURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              let identifier = Bundle(url: appURL)?.bundleIdentifier else { return nil }
        return Handler(bundleURL: appURL, bundleIdentifier: identifier)
    }

    fileprivate static func systemFocusedWindow(_ identity: ComputerUseApplicationIdentity)
        -> ComputerUseFrontmostWindowCaptureIdentity? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              !app.isTerminated, app.processIdentifier == identity.processIdentifier,
              app.bundleIdentifier == identity.bundleIdentifier else { return nil }
        guard let initialIdentity = ComputerUseApplicationIdentity(runningApplication: app),
              initialIdentity == identity else { return nil }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(750))
        func read(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.1)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
                  !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            return value
        }
        func frame(_ element: AXUIElement) -> CGRect? {
            guard let position = read(element, kAXPositionAttribute as CFString),
                  let sizeValue = read(element, kAXSizeAttribute as CFString),
                  CFGetTypeID(position) == AXValueGetTypeID(),
                  CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
                  AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
                  point.x.isFinite, point.y.isFinite,
                  size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else { return nil }
            return CGRect(origin: point, size: size)
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let windowsValue = read(root, kAXWindowsAttribute as CFString),
              CFGetTypeID(windowsValue) == CFArrayGetTypeID(),
              let windows = windowsValue as? [AXUIElement],
              let focused = read(root, kAXFocusedWindowAttribute as CFString),
              CFGetTypeID(focused) == AXUIElementGetTypeID(),
              let window = windows.first(where: { CFEqual(focused, $0) }),
              windows.filter({ CFEqual(focused, $0) }).count == 1,
              let bounds = frame(window),
              let finalFocused = read(root, kAXFocusedWindowAttribute as CFString),
              CFEqual(focused, finalFocused), frame(window) == bounds,
              let after = NSWorkspace.shared.frontmostApplication,
              !after.isTerminated,
              let finalIdentity = ComputerUseApplicationIdentity(runningApplication: after),
              finalIdentity == identity,
              !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
        return ComputerUseFrontmostWindowCaptureIdentity(
            applicationProcessIdentifier: app.processIdentifier,
            accessibilityWindowHash: CFHash(window), bounds: bounds)
    }
}

@MainActor
struct ComputerUseDefaultBrowserTargetResolver {
    typealias ResolveHandler = @MainActor (URL) -> ComputerUseDefaultBrowserTarget.Handler?
    typealias Launch = @MainActor (URL, ComputerUseDefaultBrowserTarget.Handler) async throws -> ComputerUseApplicationIdentity?
    typealias FocusedWindow = @MainActor (ComputerUseApplicationIdentity) -> ComputerUseFrontmostWindowCaptureIdentity?

    private let resolveHandler: ResolveHandler
    private let launch: Launch
    private let focusedWindow: FocusedWindow

    init(resolveHandler: @escaping ResolveHandler = ComputerUseDefaultBrowserTarget.systemHTTPSHandler,
         launch: @escaping Launch,
         focusedWindow: @escaping FocusedWindow = ComputerUseDefaultBrowserTarget.systemFocusedWindow) {
        self.resolveHandler = resolveHandler
        self.launch = launch
        self.focusedWindow = focusedWindow
    }

    func open(taskID: String, url: URL) async throws -> ComputerUseDefaultBrowserTarget {
        try Task.checkCancellation()
        guard !taskID.isEmpty, url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil else {
            throw ComputerUseDefaultBrowserTarget.Failure.invalidHTTPSURL
        }
        guard let handler = resolveHandler(url), handler.bundleURL.isFileURL,
              handler.bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            throw ComputerUseDefaultBrowserTarget.Failure.noDefaultHandler
        }
        try Task.checkCancellation()
        guard let application = try await launch(url, handler) else {
            throw ComputerUseDefaultBrowserTarget.Failure.openFailed
        }
        try Task.checkCancellation()
        let expectedPath = handler.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard application.bundleIdentifier == handler.bundleIdentifier else {
            throw ComputerUseDefaultBrowserTarget.Failure.handlerIdentityMismatch
        }
        guard let proof = application.codeIdentity else {
            throw ComputerUseDefaultBrowserTarget.Failure.applicationNotCodeVerified
        }
        guard proof.bundleIdentifier == handler.bundleIdentifier,
              proof.canonicalBundlePath == expectedPath else {
            throw ComputerUseDefaultBrowserTarget.Failure.handlerIdentityMismatch
        }
        guard let window = focusedWindow(application),
              window.applicationProcessIdentifier == application.processIdentifier else {
            throw ComputerUseDefaultBrowserTarget.Failure.noUniqueFocusedWindow
        }
        try Task.checkCancellation()
        return ComputerUseDefaultBrowserTarget(taskID: taskID, handler: handler,
            application: application, window: window)
    }

}

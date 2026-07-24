import AppKit
import CloudKit
import Darwin
import Foundation
import ServiceManagement
import SwiftUI

/// Detects app-hosted XCTest runs before the host starts any production-only
/// services. Xcode's test launcher does not consistently provide
/// `XCTestConfigurationFilePath`, so relying on that one environment variable
/// can let a test host advertise, register login items, or read the Keychain.
enum HostRuntimeContext {
    static var isRunningUnitTests: Bool {
        detectsUnitTests(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments,
            loadedBundlePaths: (Bundle.allBundles + Bundle.allFrameworks).map(\.bundlePath),
            xctestRuntimeAvailable: NSClassFromString("XCTestCase") != nil
                || NSClassFromString("XCTest.XCTestCase") != nil)
    }

    /// App-hosted XCTest must remain visually inert. Even an `NSStatusItem`
    /// is a real on-screen surface owned by Control Center, so creating the
    /// normal host chrome would make hidden model acceptance visibly mutate
    /// the user's menu bar.
    static var shouldInstallVisibleChrome: Bool {
        !isRunningUnitTests
    }

    static func detectsUnitTests(
        environment: [String: String],
        arguments: [String],
        loadedBundlePaths: [String],
        xctestRuntimeAvailable: Bool
    ) -> Bool {
        if xctestRuntimeAvailable {
            return true
        }

        let injectionKeys = [
            "XCTestConfigurationFilePath",
            "XCTestBundlePath",
            "XCTestSessionIdentifier",
            "XCInjectBundle",
            "XCInjectBundleInto",
        ]
        if injectionKeys.contains(where: { environment[$0] != nil }) {
            return true
        }

        if environment["DYLD_INSERT_LIBRARIES"]?.localizedCaseInsensitiveContains("XCTest") == true {
            return true
        }

        let hasXCTestLaunchMarker = arguments.contains { argument in
            let marker = argument.lowercased()
            return marker == "-xctest"
                || marker.hasPrefix("-xctest")
                || marker.hasSuffix(".xctest")
                || marker.contains(".xctest/")
        }
        if hasXCTestLaunchMarker {
            return true
        }

        return loadedBundlePaths.contains { path in
            let marker = path.lowercased()
            return marker.hasSuffix(".xctest")
                || marker.contains(".xctest/")
                || marker.hasSuffix("/xctest.framework")
                || marker.contains("/xctest.framework/")
        }
    }
}

/// Owns the ordering contract for an in-app relaunch. A replacement host uses
/// the same stable CloudKit sender identity as the old process, so it must not
/// launch until the old signaling run has deleted its records and returned.
enum HostTerminationSequence {
    @MainActor
    static func finish(
        session: HostSession,
        relaunchAfterShutdown: Bool,
        launchReplacement: () -> Void
    ) async {
        await session.shutdown()
        if relaunchAfterShutdown {
            launchReplacement()
        }
    }
}

@main
struct RemoteDesktopHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if let exitCode = HostCommandLine.runIfNeeded() {
            Darwin.exit(exitCode)
        }
    }

    var body: some Scene {
        // The everyday UI lives in an NSStatusItem popover; AppDelegate opens
        // the dedicated setup window only when needed. Keeping `Settings` here
        // prevents SwiftUI from also creating an unrelated main window.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum TerminationState {
        case idle
        case shuttingDown
        case readyToTerminate
    }

    // XCTest is injected after the application delegate is created. Defer the
    // session (and therefore the local model manager) until AppKit begins
    // launching so HostRuntimeContext can see that injection reliably.
    private(set) lazy var session = HostSession()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var setupWindowController: NSWindowController?
    private var settingsWindowController: NSWindowController?
    private var activationObserver: NSObjectProtocol?
    private var cloudAccountObserver: NSObjectProtocol?
    private var launchPermissionTask: Task<Void, Never>?
    private var permissionRefreshTask: Task<Void, Never>?
    private var terminationSignalSource: DispatchSourceSignal?
    private var terminationTask: Task<Void, Never>?
    private var terminationState: TerminationState = .idle
    private var relaunchAfterShutdown = false
    private(set) var didEnterProductionLaunchPath = false
    private(set) var didInstallStatusItem = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard HostRuntimeContext.shouldInstallVisibleChrome else {
            // XCTest still needs the application process as its bundle host,
            // but it must not create a status item, popover, setup window, or
            // activate on the user's desktop.
            NSApp.setActivationPolicy(.prohibited)
            return
        }
        didEnterProductionLaunchPath = true
        NSApp.setActivationPolicy(.accessory)
        configureTerminationSignalHandling()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        didInstallStatusItem = true
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "display",
                accessibilityDescription: "Remote Desktop Host")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 460)
        popover.contentViewController = NSHostingController(
            rootView: MenuContent(openSetup: { [weak self] in
                self?.showSetupWindow()
            }, openSettings: { [weak self] in
                self?.showSettingsWindow()
            }).environmentObject(session))

        // Re-read permissions whenever the app regains focus — this
        // is what picks up the user returning from System Settings
        // after toggling Accessibility / Screen Recording. TCC does
        // not always propagate grants to already-running processes
        // without a nudge, so we poll on activation.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshPermissionsAfterActivation()
                }
            }

        cloudAccountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.session.handleCloudAccountChanged()
                }
            }

        // Refresh permissions on first show so the UI reflects reality.
        session.refreshPermissions()
        configureStartAtLogin()
        resolveLaunchPermissionState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard HostRuntimeContext.shouldInstallVisibleChrome else { return }
        terminationSignalSource?.cancel()
        terminationSignalSource = nil
        Darwin.signal(SIGTERM, SIG_DFL)
        if let obs = activationObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = cloudAccountObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        cancelPermissionTasks()
        session.stop()
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard HostRuntimeContext.shouldInstallVisibleChrome else {
            return .terminateNow
        }
        switch terminationState {
        case .readyToTerminate:
            return .terminateNow
        case .shuttingDown:
            return .terminateCancel
        case .idle:
            break
        }

        // AppKit waits in a nested termination loop after `.terminateLater`.
        // A shutdown task isolated to MainActor cannot run inside that loop,
        // leaving the local model process orphaned. Cancel this first request
        // so `terminate(_:)` unwinds, complete bounded async teardown, then
        // issue a second request that returns `.terminateNow`.
        terminationState = .shuttingDown
        cancelPermissionTasks()
        terminationTask = Task { @MainActor in
            await HostTerminationSequence.finish(
                session: self.session,
                relaunchAfterShutdown: self.relaunchAfterShutdown,
                launchReplacement: { self.launchReplacementHost() })
            self.terminationState = .readyToTerminate
            sender.terminate(nil)
        }
        return .terminateCancel
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            refreshPermissionsAndApplyState(presentSetupIfMissing: false)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func refreshPermissionsAfterActivation() {
        guard terminationState == .idle else { return }
        refreshPermissionsAndApplyState(presentSetupIfMissing: false)
        permissionRefreshTask?.cancel()
        permissionRefreshTask = Task { @MainActor [weak self] in
            // TCC occasionally publishes a just-changed grant shortly after
            // System Settings returns focus. One bounded recheck avoids making
            // the user press Check Again or restart for that propagation lag.
            do {
                try await Task.sleep(for: .milliseconds(750))
            } catch {
                return
            }
            guard let self, self.terminationState == .idle else { return }
            self.refreshPermissionsAndApplyState(presentSetupIfMissing: false)
        }
    }

    private func resolveLaunchPermissionState() {
        launchPermissionTask?.cancel()
        launchPermissionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.session.permissions.coreReady {
                // A new GUI process can briefly observe the pre-relaunch TCC
                // snapshot even when the same signed host already owns both
                // grants. Recheck once before deciding to show onboarding.
                do {
                    try await Task.sleep(for: .milliseconds(750))
                } catch {
                    return
                }
                self.session.refreshPermissions()
            }

            guard self.terminationState == .idle else { return }
            self.applyPermissionState(presentSetupIfMissing: true)
        }
    }

    private func refreshPermissionsAndApplyState(presentSetupIfMissing: Bool) {
        guard terminationState == .idle else { return }
        session.refreshPermissions()
        applyPermissionState(presentSetupIfMissing: presentSetupIfMissing)
    }

    private func applyPermissionState(presentSetupIfMissing: Bool) {
        guard terminationState == .idle else { return }
        HostSetupPreferences.reconcileExistingGrants(
            permissions: session.permissions)
        configureHeadlessMode()

        if session.permissions.coreReady {
            // Existing grants are resolved before a setup window is created.
            // If the window is already visible, the person is actively moving
            // through setup; leave it open so SwiftUI can advance to optional
            // audio and the final Ready guidance instead of disappearing.
            return
        }

        if presentSetupIfMissing,
           HostSetupPreferences.shouldPresent(permissions: session.permissions) {
            showSetupWindow()
        }
    }

    private func cancelPermissionTasks() {
        launchPermissionTask?.cancel()
        launchPermissionTask = nil
        permissionRefreshTask?.cancel()
        permissionRefreshTask = nil
    }

    private func showSetupWindow() {
        if let window = setupWindowController?.window {
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = HostSetupView(
            session: session,
            onFinish: { [weak self] in self?.finishSetup() },
            onRestart: { [weak self] in self?.restartHost() },
            onCorePermissionsReady: { [weak self] in
                self?.applyPermissionState(presentSetupIfMissing: false)
            })
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Remote Desktop Host Setup"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let controller = NSWindowController(window: window)
        setupWindowController = controller

        NSApp.setActivationPolicy(.regular)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showSettingsWindow() {
        if let window = settingsWindowController?.window {
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = HostSettingsView(
            session: session,
            openSetup: { [weak self] in self?.showSetupWindow() })
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Remote Desktop Host Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let controller = NSWindowController(window: window)
        settingsWindowController = controller

        NSApp.setActivationPolicy(.regular)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finishSetup() {
        session.refreshPermissions()
        guard session.permissions.coreReady else { return }
        HostSetupPreferences.markCompleted()
        if HeadlessHostSettings.startListeningOnLaunch {
            session.start()
        }
        setupWindowController?.close()
    }

    private func restartHost() {
        relaunchAfterShutdown = true
        NSApp.terminate(nil)
    }

    private func launchReplacementHost() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath]
        do {
            try process.run()
        } catch {
            NSLog("RemoteDesktopHost could not restart itself: \(error.localizedDescription)")
        }
    }

    private func configureTerminationSignalHandling() {
        // Build/run tooling stops the app with SIGTERM. Dispatching that
        // signal through AppKit makes it use applicationShouldTerminate's
        // awaited shutdown instead of letting the child model become orphaned.
        Darwin.signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            NSApp.terminate(nil)
        }
        source.resume()
        terminationSignalSource = source
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === setupWindowController?.window
                || closingWindow === settingsWindowController?.window else { return }

        let otherWindowIsVisible: Bool
        if closingWindow === setupWindowController?.window {
            otherWindowIsVisible = settingsWindowController?.window?.isVisible == true
        } else {
            otherWindowIsVisible = setupWindowController?.window?.isVisible == true
        }
        if !otherWindowIsVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func configureHeadlessMode() {
        HeadlessHostSettings.removeLegacyManualPairingArtifacts()

        guard !HostRuntimeContext.isRunningUnitTests else { return }
        guard HeadlessHostSettings.startListeningOnLaunch else { return }
        guard session.permissions.coreReady else { return }
        session.start()
    }

    private func configureStartAtLogin() {
        guard !HostRuntimeContext.isRunningUnitTests else { return }
        guard !isRunningFromDerivedData else { return }
        guard HeadlessHostSettings.startAtLogin else { return }
        guard !legacyLaunchAgentExists else { return }

        let service = SMAppService.mainApp
        switch service.status {
        case .notRegistered:
            do {
                try service.register()
            } catch {
                NSLog("RemoteDesktopHost could not register login item: \(error.localizedDescription)")
            }
        case .enabled, .requiresApproval, .notFound:
            break
        @unknown default:
            break
        }
    }

    private var legacyLaunchAgentExists: Bool {
        let launchAgent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.threadmark.remotedesktop.host.plist")
        return FileManager.default.fileExists(atPath: launchAgent.path)
    }

    private var isRunningFromDerivedData: Bool {
        Bundle.main.bundleURL.path.contains("/DerivedData/")
    }

}

import AppKit
import Combine
import Darwin
import Foundation
import ServiceManagement
import SwiftUI

@main
struct RemoteDesktopHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if let exitCode = HostCommandLine.runIfNeeded() {
            Darwin.exit(exitCode)
        }
    }

    var body: some Scene {
        // Empty scene — UI lives in an NSStatusItem popover managed
        // by the app delegate. Keeping `Settings` here (instead of
        // `WindowGroup`) prevents AppKit from opening a main window.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let session = HostSession()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var activationObserver: NSObjectProtocol?
    private var stateObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
        popover.contentSize = NSSize(width: 340, height: 420)
        popover.contentViewController = NSHostingController(
            rootView: MenuContent().environmentObject(session))

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
                    self?.session.refreshPermissions()
                }
            }

        // Refresh permissions on first show so the UI reflects reality.
        session.refreshPermissions()
        configureStartAtLogin()
        configureHeadlessMode()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = activationObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        stateObserver?.cancel()
        clearPairingCodeFile()
        session.stop()
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            session.refreshPermissions()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func configureHeadlessMode() {
        stateObserver = session.$state.sink { [weak self] state in
            self?.syncPairingCodeFile(for: state)
        }

        guard !isRunningUnitTests else { return }
        guard HeadlessHostSettings.startListeningOnLaunch else { return }
        session.start()
    }

    private func configureStartAtLogin() {
        guard !isRunningUnitTests else { return }
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

    private var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private var isRunningFromDerivedData: Bool {
        Bundle.main.bundleURL.path.contains("/DerivedData/")
    }

    private func syncPairingCodeFile(for state: HostSession.State) {
        switch state {
        case .advertising(let code):
            writePairingCodeFile(code)
        case .idle, .starting, .paired(_), .error(_):
            clearPairingCodeFile()
        }
    }

    private func writePairingCodeFile(_ code: String) {
        guard let url = HeadlessHostSettings.pairingCodeFileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try "\(code)\n".write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("RemoteDesktopHost could not write pairing code file: \(error.localizedDescription)")
        }
    }

    private func clearPairingCodeFile() {
        guard let url = HeadlessHostSettings.pairingCodeFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

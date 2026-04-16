import AppKit
import SwiftUI

@main
struct RemoteDesktopHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = activationObserver {
            NotificationCenter.default.removeObserver(obs)
        }
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
}

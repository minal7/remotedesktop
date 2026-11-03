import AppKit
import Foundation

final class ClockWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() }
        else { super.keyDown(with: event) }
    }
}

@MainActor
final class ClockApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var timer: Timer?
    private let unixLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let title = NSTextField(labelWithString: "LOCAL MAC CLOCK")
        title.font = .monospacedSystemFont(ofSize: 24, weight: .semibold)
        unixLabel.font = .monospacedDigitSystemFont(ofSize: 58, weight: .bold)
        dateLabel.font = .monospacedDigitSystemFont(ofSize: 21, weight: .regular)
        for label in [title, unixLabel, dateLabel] {
            label.alignment = .center
            label.textColor = .white
        }
        let content = NSStackView(views: [title, unixLabel, dateLabel])
        content.orientation = .vertical
        content.alignment = .centerX
        content.distribution = .fill
        content.spacing = 20
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        }) else { NSApp.terminate(nil); return }
        let background = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
        let window = ClockWindow(contentRect: screen.frame, styleMask: [.borderless],
                                 backing: .buffered, defer: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = background
        window.makeKeyAndOrderFront(nil)
        self.window = window
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func update() {
        let now = Date()
        let millis = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        unixLabel.stringValue = String(format: "%lld.%03lld", millis / 1000, millis % 1000)
        dateLabel.stringValue = formatter.string(from: now) + " UTC"
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = ClockApp()
    app.delegate = delegate
    app.run()
}

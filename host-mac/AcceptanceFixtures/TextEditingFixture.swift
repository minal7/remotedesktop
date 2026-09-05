import AppKit

// Deliberately separate from the host: integration tests must cross the real
// Accessibility/event boundary and independently read this app's final state.
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    let stateURL: URL
    let window = NSWindow(contentRect: NSRect(x: 220, y: 260, width: 640, height: 300),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let origin = NSTextView(frame: .zero)
    let destination = NSTextView(frame: .zero)
    var timer: Timer?

    init(stateURL: URL) { self.stateURL = stateURL }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "Remote Desktop text verification fixture"
        let view = window.contentView!
        for (field, label, y) in [(origin, "Origin", 190.0), (destination, "Destination", 110.0)] {
            let title = NSTextField(labelWithString: label)
            title.frame = NSRect(x: 24, y: y + 36, width: 560, height: 24)
            field.frame = NSRect(x: 24, y: y, width: 580, height: 30)
            field.setAccessibilityIdentifier(label.lowercased())
            field.setAccessibilityLabel(label)
            field.font = .systemFont(ofSize: 16)
            field.isRichText = false
            field.isAutomaticQuoteSubstitutionEnabled = false
            field.isAutomaticDashSubstitutionEnabled = false
            field.isAutomaticTextReplacementEnabled = false
            field.isAutomaticSpellingCorrectionEnabled = false
            view.addSubview(title)
            view.addSubview(field)
        }
        let note = NSTextField(labelWithString: "Local test fields only. This fixture performs no external actions.")
        note.frame = NSRect(x: 24, y: 30, width: 590, height: 24)
        view.addSubview(note)
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(origin)
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
            self?.writeState()
        }
        writeState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func writeState() {
        let state: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                    "origin": origin.string,
                                    "destination": destination.string]
        guard let data = try? JSONSerialization.data(withJSONObject: state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }
}

guard CommandLine.arguments.count == 2 else { fatalError("Expected fixture state path") }
let delegate = FixtureDelegate(stateURL: URL(fileURLWithPath: CommandLine.arguments[1]))
let application = NSApplication.shared
application.delegate = delegate
application.run()

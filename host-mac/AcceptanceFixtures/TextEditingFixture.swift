import AppKit
import WebKit

// Deliberately separate from the host: integration tests must cross the real
// Accessibility/event boundary and independently read this app's final state.
final class FixtureDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    let stateURL: URL
    let window = NSWindow(contentRect: NSRect(x: 220, y: 260, width: 640, height: 300),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let origin = NSTextView(frame: .zero)
    var destination = NSTextView(frame: .zero)
    var timer: Timer?
    var webView: WKWebView?
    var lastCommand: String?
    var generation = 0

    init(stateURL: URL) { self.stateURL = stateURL }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "Remote Desktop text verification fixture"
        let view = window.contentView!
        if CommandLine.arguments.contains("--browser") {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let browser = WKWebView(frame: view.bounds, configuration: configuration)
            browser.autoresizingMask = [.width, .height]
            browser.navigationDelegate = self
            view.addSubview(browser)
            webView = browser
            browser.loadHTMLString("""
                <!doctype html><html lang="en"><meta charset="utf-8"><title>Local text form</title>
                <style>body{font:16px system-ui;padding:16px}label{display:block;margin:12px 0}textarea{display:block;width:95%;height:45px}</style>
                <label for="origin">Origin</label><textarea id="origin" aria-label="Origin" spellcheck="false"></textarea>
                <label for="destination">Destination</label><textarea id="destination" aria-label="Destination" spellcheck="false"></textarea>
                <script>window.formState={origin:'',destination:''};for(const id of ['origin','destination'])document.getElementById(id).addEventListener('input',e=>{window.formState[id]=e.target.value})</script>
                <p>Disposable local form. No submission or external resources.</p></html>
                """, baseURL: nil)
        } else {
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
        }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        if webView == nil { window.makeFirstResponder(origin) }
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
            self?.consumeCommand()
            self?.writeState()
        }
        writeState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        window.makeFirstResponder(webView)
        webView.evaluateJavaScript("document.getElementById('origin').focus()")
    }

    func writeState() {
        if let webView {
            webView.evaluateJavaScript("({...window.formState,rawOrigin:document.getElementById('origin').value,rawDestination:document.getElementById('destination').value})") { [weak self] result, _ in
                guard let self, var state = result as? [String: Any] else { return }
                state["pid"] = ProcessInfo.processInfo.processIdentifier
                state["generation"] = self.generation
                if let data = try? JSONSerialization.data(withJSONObject: state) {
                    try? data.write(to: self.stateURL, options: .atomic)
                }
            }
            return
        }
        let state: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                    "generation": generation,
                                    "origin": origin.string,
                                    "destination": destination.string]
        guard let data = try? JSONSerialization.data(withJSONObject: state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    /// Test-only, fixed operation in the private fixture directory. Replacing
    /// a control keeps its value, label and geometry so identity checks cannot
    /// pass merely because those visible properties still match.
    func consumeCommand() {
        let commandURL = stateURL.appendingPathExtension("command")
        guard let command = try? String(contentsOf: commandURL, encoding: .utf8),
              command != lastCommand, command == "replace-destination" else { return }
        lastCommand = command
        if let webView {
            webView.evaluateJavaScript("""
                (()=>{const old=document.getElementById('destination');const next=old.cloneNode(true);
                next.value=old.value;const start=old.selectionStart,end=old.selectionEnd;
                next.addEventListener('input',e=>{window.formState.destination=e.target.value});
                old.replaceWith(next);next.focus();next.setSelectionRange(start,end);return true})()
                """) { [weak self] result, error in
                    if error == nil, result as? Bool == true { self?.generation += 1 }
                }
        } else {
            let next = NSTextView(frame: destination.frame)
            next.string = destination.string
            next.setAccessibilityIdentifier("destination")
            next.setAccessibilityLabel("Destination")
            next.font = destination.font
            next.isRichText = false
            next.isAutomaticQuoteSubstitutionEnabled = false
            next.isAutomaticDashSubstitutionEnabled = false
            next.isAutomaticTextReplacementEnabled = false
            next.isAutomaticSpellingCorrectionEnabled = false
            next.setSelectedRange(destination.selectedRange())
            destination.superview?.replaceSubview(destination, with: next)
            destination = next
            window.makeFirstResponder(next)
            generation += 1
        }
    }
}

guard CommandLine.arguments.count >= 2 else { fatalError("Expected fixture state path") }
let delegate = FixtureDelegate(stateURL: URL(fileURLWithPath: CommandLine.arguments[1]))
let application = NSApplication.shared
application.delegate = delegate
application.run()

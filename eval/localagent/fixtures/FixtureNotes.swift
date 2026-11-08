// A small, ordinary native app with real menus and a real system save panel, kept
// apart from the owner's documents. Used only by the local agent evaluation.
import AppKit
import UniformTypeIdentifiers

final class Controller: NSObject {
    let textView = NSTextView()
    var window: NSWindow!
    @objc func save(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Untitled.txt"
        // Starts inside the test area, so a save that skips choosing a folder stays there.
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("LocalAgentEval")
        panel.allowedContentTypes = [.plainText]
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else { return }
            try? textView.string.write(to: url, atomically: true, encoding: .utf8)
            window.title = url.lastPathComponent
        }
    }
    @objc func clear(_ sender: Any?) { textView.string = "" }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = Controller()
let mainMenu = NSMenu()
let appItem = NSMenuItem(); mainMenu.addItem(appItem)
let appMenu = NSMenu(); appMenu.addItem(withTitle: "Quit Fixture Notes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appItem.submenu = appMenu
let fileItem = NSMenuItem(); mainMenu.addItem(fileItem)
let fileMenu = NSMenu(title: "File")
let saveItem = fileMenu.addItem(withTitle: "Save…", action: #selector(Controller.save(_:)), keyEquivalent: "s"); saveItem.target = controller
fileItem.submenu = fileMenu
let editItem = NSMenuItem(); mainMenu.addItem(editItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editItem.submenu = editMenu
app.mainMenu = mainMenu
let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 620, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "Fixture Notes"
controller.window = window
let scroll = NSScrollView(frame: window.contentView!.bounds)
scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
controller.textView.frame = scroll.bounds; controller.textView.autoresizingMask = [.width]
controller.textView.font = .systemFont(ofSize: 14); controller.textView.isAutomaticQuoteSubstitutionEnabled = false
controller.textView.setAccessibilityLabel("Note text")
scroll.documentView = controller.textView
window.contentView!.addSubview(scroll)
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(controller.textView)
app.activate(ignoringOtherApps: true)
app.run()

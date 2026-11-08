// A small word processor with real find and replace, save and PDF panels, standing in for Word or
// Pages. Used only by the local agent evaluation.
import AppKit
import UniformTypeIdentifiers

let evalFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("LocalAgentEval")

final class Writer: NSObject {
    let text = NSTextView()
    var window: NSWindow!
    var current: URL?

    func load(_ url: URL) {
        guard let body = try? String(contentsOf: url, encoding: .utf8) else { return }
        text.string = body; current = url; window.title = url.lastPathComponent
    }
    @objc func newDocument(_ sender: Any?) { text.string = ""; current = nil; window.title = "Untitled" }
    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel(); panel.directoryURL = current?.deletingLastPathComponent() ?? evalFolder
        panel.beginSheetModal(for: window) { [self] in if $0 == .OK, let url = panel.url { load(url) } }
    }
    @objc func saveDocument(_ sender: Any?) {
        if let current { try? text.string.write(to: current, atomically: true, encoding: .utf8); window.title = current.lastPathComponent } else { saveAs(sender) }
    }
    @objc func saveAs(_ sender: Any?) {
        let panel = NSSavePanel(); panel.directoryURL = current?.deletingLastPathComponent() ?? evalFolder
        panel.nameFieldStringValue = current?.lastPathComponent ?? "Untitled.txt"; panel.allowedContentTypes = [.plainText]
        panel.beginSheetModal(for: window) { [self] in
            guard $0 == .OK, let url = panel.url else { return }
            try? text.string.write(to: url, atomically: true, encoding: .utf8); current = url; window.title = url.lastPathComponent
        }
    }
    @objc func exportPDF(_ sender: Any?) {
        let panel = NSSavePanel(); panel.directoryURL = current?.deletingLastPathComponent() ?? evalFolder
        panel.nameFieldStringValue = ((current?.lastPathComponent ?? "Untitled") as NSString).deletingPathExtension + ".pdf"; panel.allowedContentTypes = [.pdf]
        panel.beginSheetModal(for: window) { [self] in
            guard $0 == .OK, let url = panel.url else { return }
            try? text.dataWithPDF(inside: text.bounds).write(to: url)
        }
    }
    @objc func printDocument(_ sender: Any?) { NSPrintOperation(view: text).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) }
}

let writer = Writer()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let menu = NSMenu()
let first = NSMenuItem(); first.submenu = NSMenu(); menu.addItem(first)
first.submenu?.addItem(withTitle: "Quit WriteDoc", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let file = NSMenuItem(); file.submenu = NSMenu(title: "File"); menu.addItem(file)
for (title, selector, key, shift) in [("New", #selector(Writer.newDocument(_:)), "n", false), ("Open...", #selector(Writer.openDocument(_:)), "o", false), ("Save", #selector(Writer.saveDocument(_:)), "s", false),
                                      ("Save As...", #selector(Writer.saveAs(_:)), "s", true), ("Export as PDF...", #selector(Writer.exportPDF(_:)), "e", false), ("Print...", #selector(Writer.printDocument(_:)), "p", false)] {
    let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.target = writer
    if shift { item.keyEquivalentModifierMask = [.command, .shift] }
    file.submenu?.addItem(item)
}
let edit = NSMenuItem(); edit.submenu = NSMenu(title: "Edit"); menu.addItem(edit)
edit.submenu?.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
for (title, selector, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
    edit.submenu?.addItem(withTitle: title, action: selector, keyEquivalent: key)
}
for (title, action, key, modifiers) in [("Find...", NSTextFinder.Action.showFindInterface, "f", NSEvent.ModifierFlags.command), ("Find and Replace...", NSTextFinder.Action.showReplaceInterface, "f", [.command, .option])] {
    let item = NSMenuItem(title: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
    item.tag = action.rawValue; item.keyEquivalentModifierMask = modifiers
    edit.submenu?.addItem(item)
}
app.mainMenu = menu

let window = NSWindow(contentRect: NSRect(x: 220, y: 120, width: 760, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
window.title = "Untitled"
writer.window = window
let scroll = NSScrollView(frame: window.contentView!.bounds); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
writer.text.frame = scroll.bounds; writer.text.autoresizingMask = [.width]; writer.text.isVerticallyResizable = true
writer.text.isRichText = false; writer.text.usesFindBar = true; writer.text.isIncrementalSearchingEnabled = true; writer.text.allowsUndo = true
writer.text.font = NSFont.systemFont(ofSize: 15); writer.text.textContainerInset = NSSize(width: 16, height: 16)
writer.text.isAutomaticQuoteSubstitutionEnabled = false; writer.text.isAutomaticDashSubstitutionEnabled = false; writer.text.isAutomaticSpellingCorrectionEnabled = false
scroll.documentView = writer.text; window.contentView = scroll
if let path = ProcessInfo.processInfo.environment["OPEN_DOCUMENT"] { writer.load(URL(fileURLWithPath: path)) }
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(writer.text)
app.activate(ignoringOtherApps: true)
app.run()

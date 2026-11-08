// A contacts app laid out unlike the other test apps: a list on the left and a form on the right.
// It's only used by the held-out tasks, so nothing in the harness has been tuned on it.
import AppKit
import UniformTypeIdentifiers

final class Book: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var people: [[String]] = [
        ["Omar Haddad", "555-0142", "omar@example.test", "Porto"],
        ["Priya Nair", "555-0177", "priya@example.test", "Austin"],
        ["Lena Roy", "555-0120", "lena@example.test", "Oslo"],
        ["Tomas Berg", "555-0163", "tomas@example.test", "Riga"],
        ["Mei Tan", "555-0191", "mei@example.test", "Perth"],
    ]
    var shown: [Int] = []
    let table = NSTableView()
    let search = NSSearchField()
    let status = NSTextField(labelWithString: "")
    let fields = [NSTextField(), NSTextField(), NSTextField()]
    var window: NSWindow!
    var selected: Int?

    func refresh() {
        let wanted = search.stringValue.lowercased()
        shown = people.indices.filter { wanted.isEmpty || people[$0][0].lowercased().contains(wanted) }
        table.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: people[shown[row]][0])
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, table.selectedRow < shown.count else { return }
        selected = shown[table.selectedRow]
        for (index, field) in fields.enumerated() { field.stringValue = people[selected!][index + 1] }
        status.stringValue = ""
    }
    func controlTextDidChange(_ note: Notification) { if note.object as? NSSearchField === search { refresh() } }
    @objc func saveCard(_ sender: Any?) {
        window.makeFirstResponder(nil)
        guard let selected else { status.stringValue = "Choose a person first"; return }
        for (index, field) in fields.enumerated() { people[selected][index + 1] = field.stringValue }
        status.stringValue = "Saved \(people[selected][0])"
    }
    @objc func export(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("LocalAgentEval")
        panel.nameFieldStringValue = "Contacts.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.beginSheetModal(for: window) { [self] in
            guard $0 == .OK, let url = panel.url else { return }
            let lines = [["Name", "Phone", "Email", "City"]] + people
            try? (lines.map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            status.stringValue = "Exported \(url.lastPathComponent)"
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let book = Book()
let bar = NSMenu()
let first = NSMenuItem(); bar.addItem(first); first.submenu = NSMenu()
first.submenu?.addItem(withTitle: "Quit ContactBook", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let fileItem = NSMenuItem(); bar.addItem(fileItem)
let file = NSMenu(title: "File"); fileItem.submenu = file
let exportItem = file.addItem(withTitle: "Export All...", action: #selector(Book.export(_:)), keyEquivalent: "e"); exportItem.target = book
let close = file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"); _ = close
let editItem = NSMenuItem(); bar.addItem(editItem)
let edit = NSMenu(title: "Edit"); editItem.submenu = edit
for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
    edit.addItem(withTitle: title, action: action, keyEquivalent: key)
}
app.mainMenu = bar

let window = NSWindow(contentRect: NSRect(x: 260, y: 160, width: 680, height: 460), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
window.title = "ContactBook"
book.window = window
let content = window.contentView!
book.search.frame = NSRect(x: 16, y: 416, width: 220, height: 28); book.search.placeholderString = "Search people"; book.search.delegate = book
content.addSubview(book.search)
let column = NSTableColumn(identifier: .init("name")); column.title = "People"; column.width = 200
book.table.addTableColumn(column); book.table.dataSource = book; book.table.delegate = book
let list = NSScrollView(frame: NSRect(x: 16, y: 16, width: 220, height: 390)); list.documentView = book.table; list.hasVerticalScroller = true
content.addSubview(list)
for (index, name) in ["Phone", "Email", "City"].enumerated() {
    let y = CGFloat(380 - index * 48)
    let label = NSTextField(labelWithString: name); label.frame = NSRect(x: 260, y: y + 4, width: 60, height: 20)
    book.fields[index].frame = NSRect(x: 324, y: y, width: 320, height: 26)
    content.addSubview(label); content.addSubview(book.fields[index])
}
let saveButton = NSButton(title: "Save Card", target: book, action: #selector(Book.saveCard(_:))); saveButton.frame = NSRect(x: 320, y: 220, width: 120, height: 32)
content.addSubview(saveButton)
book.status.frame = NSRect(x: 260, y: 180, width: 380, height: 22); content.addSubview(book.status)
book.refresh()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()

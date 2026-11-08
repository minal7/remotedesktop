// A plain file manager kept inside ~/LocalAgentEval/files, standing in for Finder so a test can
// organize files without any way of reaching the owner's. Used only by the local agent evaluation.
import AppKit

let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("LocalAgentEval/files").standardizedFileURL
let trash = root.deletingLastPathComponent().appendingPathComponent("trash")

final class Cabinet: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var folder = root
    var items: [URL] = []
    let table = NSTableView()
    let place = NSTextField(labelWithString: "")
    let status = NSTextField(labelWithString: "")
    let search = NSSearchField()
    var window: NSWindow!
    let fm = FileManager.default

    func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
    func isFolder(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    func inside(_ url: URL) -> Bool { url.standardizedFileURL.path.hasPrefix(root.path) }

    func reload() {
        let term = search.stringValue.lowercased()
        if term.isEmpty {
            items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        } else {
            let all = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)?.allObjects as? [URL] ?? []
            items = all.filter { $0.lastPathComponent.lowercased().contains(term) }
        }
        let key = table.sortDescriptors.first?.key ?? "name"; let up = table.sortDescriptors.first?.ascending ?? true
        items.sort {
            let before = key == "size" ? size($0) < size($1) : $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased()
            return up ? before : !before
        }
        place.stringValue = "Location: files" + folder.path.dropFirst(root.path.count)
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let url = items[row]; let id = column?.identifier.rawValue
        let text: String
        if id == "name" { text = term(url) } else if id == "kind" { text = isFolder(url) ? "Folder" : url.pathExtension.uppercased() + " file" }
        else { text = isFolder(url) ? "--" : ByteCountFormatter.string(fromByteCount: Int64(size(url)), countStyle: .file) }
        return NSTextField(labelWithString: text)
    }
    func term(_ url: URL) -> String { search.stringValue.isEmpty ? url.lastPathComponent : String(url.path.dropFirst(root.path.count + 1)) }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) { reload() }
    func controlTextDidChange(_ note: Notification) { reload() }

    var selected: [URL] { table.selectedRowIndexes.map { items[$0] } }

    @objc func open(_ sender: Any?) {
        guard table.clickedRow >= 0 || table.selectedRow >= 0 else { return }
        let url = items[table.clickedRow >= 0 ? table.clickedRow : table.selectedRow]
        if isFolder(url) { folder = url; search.stringValue = ""; reload() } else { status.stringValue = "\(url.lastPathComponent) is at files\(url.path.dropFirst(root.path.count))" }
    }
    @objc func up(_ sender: Any?) { if folder != root { folder = folder.deletingLastPathComponent().standardizedFileURL; reload() } }

    func ask(_ title: String, value: String = "", then: @escaping (String) -> Void) {
        let alert = NSAlert(); alert.messageText = title
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { then(field.stringValue.trimmingCharacters(in: .whitespaces)) } }
    }
    @objc func newFolder(_ sender: Any?) {
        ask("Name for the new folder") { [self] name in
            guard !name.isEmpty else { return }
            try? fm.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true); status.stringValue = "Created \(name)"; reload()
        }
    }
    @objc func rename(_ sender: Any?) {
        guard let url = selected.first else { status.stringValue = "Select a file first"; return }
        ask("New name", value: url.lastPathComponent) { [self] name in
            guard !name.isEmpty else { return }
            try? fm.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent(name)); status.stringValue = "Renamed to \(name)"; reload()
        }
    }
    func transfer(_ copying: Bool) {
        let chosen = selected
        guard !chosen.isEmpty else { status.stringValue = "Select files first"; return }
        ask("\(copying ? "Copy" : "Move") \(chosen.count) item(s) to which folder? (path inside files, such as Documents)") { [self] path in
            let target = root.appendingPathComponent(path).standardizedFileURL
            guard inside(target) else { status.stringValue = "That folder isn't in files"; return }
            try? fm.createDirectory(at: target, withIntermediateDirectories: true)
            for url in chosen {
                let to = target.appendingPathComponent(url.lastPathComponent)
                if copying { try? fm.copyItem(at: url, to: to) } else { try? fm.moveItem(at: url, to: to) }
            }
            status.stringValue = "\(copying ? "Copied" : "Moved") \(chosen.count) item(s) to \(path)"; reload()
        }
    }
    @objc func move(_ sender: Any?) { transfer(false) }
    @objc func copyTo(_ sender: Any?) { transfer(true) }
    @objc func compress(_ sender: Any?) {
        guard let url = selected.first else { status.stringValue = "Select something first"; return }
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--keepParent", url.path, url.path + ".zip"]
        try? zip.run(); zip.waitUntilExit(); status.stringValue = "Created \(url.lastPathComponent).zip"; reload()
    }
    @objc func toTrash(_ sender: Any?) {
        try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
        for url in selected { try? fm.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent)) }
        status.stringValue = "Moved to Trash"; reload()
    }
}

let cabinet = Cabinet()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let menu = NSMenu()
let first = NSMenuItem(); first.submenu = NSMenu(); menu.addItem(first)
first.submenu?.addItem(withTitle: "Quit FileCabinet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let edit = NSMenuItem(); edit.submenu = NSMenu(title: "Edit"); menu.addItem(edit)
for (title, selector, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
    edit.submenu?.addItem(withTitle: title, action: selector, keyEquivalent: key)
}
app.mainMenu = menu

let window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 820, height: 560), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
window.title = "FileCabinet"
cabinet.window = window
let content = window.contentView!
var x: CGFloat = 12
for (title, selector) in [("Up", #selector(Cabinet.up(_:))), ("New Folder", #selector(Cabinet.newFolder(_:))), ("Rename", #selector(Cabinet.rename(_:))), ("Move To", #selector(Cabinet.move(_:))),
                          ("Copy To", #selector(Cabinet.copyTo(_:))), ("Compress", #selector(Cabinet.compress(_:))), ("Move to Trash", #selector(Cabinet.toTrash(_:)))] {
    let button = NSButton(title: title, target: cabinet, action: selector); button.frame = NSRect(x: x, y: 516, width: title.count > 9 ? 112 : 88, height: 30); button.autoresizingMask = [.minYMargin]
    content.addSubview(button); x += button.frame.width + 4
}
cabinet.search.frame = NSRect(x: 12, y: 482, width: 300, height: 26); cabinet.search.placeholderString = "Search all files"; cabinet.search.delegate = cabinet
cabinet.search.autoresizingMask = [.minYMargin]; content.addSubview(cabinet.search)
cabinet.place.frame = NSRect(x: 324, y: 484, width: 480, height: 22); cabinet.place.autoresizingMask = [.minYMargin]; content.addSubview(cabinet.place)
let scroll = NSScrollView(frame: NSRect(x: 12, y: 36, width: 796, height: 438)); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
for (id, title, width) in [("name", "Name", 480.0), ("kind", "Kind", 130.0), ("size", "Size", 130.0)] {
    let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width
    column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id != "size")
    cabinet.table.addTableColumn(column)
}
cabinet.table.allowsMultipleSelection = true
cabinet.table.dataSource = cabinet; cabinet.table.delegate = cabinet
cabinet.table.target = cabinet; cabinet.table.doubleAction = #selector(Cabinet.open(_:))
scroll.documentView = cabinet.table; content.addSubview(scroll)
cabinet.status.frame = NSRect(x: 12, y: 8, width: 796, height: 22); cabinet.status.autoresizingMask = [.width]; content.addSubview(cabinet.status)
cabinet.reload()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()

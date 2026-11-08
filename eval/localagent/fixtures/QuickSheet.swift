// A small spreadsheet with CSV import and export and the system print sheet, standing in for
// Excel or Numbers. Used only by the local agent evaluation.
import AppKit
import UniformTypeIdentifiers

let evalFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("LocalAgentEval")

final class Sheet: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var headers = ["A", "B", "C"]
    var rows: [[String]] = [["", "", ""], ["", "", ""], ["", "", ""]]
    var shown: [Int] = [0, 1, 2]
    let table = NSTableView()
    let picker = NSPopUpButton()
    let filter = NSSearchField()
    let status = NSTextField(labelWithString: "Ready")
    var window: NSWindow!

    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false
        for character in text {
            if quoted { if character == "\"" { quoted = false } else { cell.append(character) } }
            else if character == "\"" { quoted = true }
            else if character == "," { row.append(cell); cell = "" }
            else if character.isNewline { row.append(cell); cell = ""; rows.append(row); row = [] }
            else { cell.append(character) }
        }
        if !cell.isEmpty || !row.isEmpty { row.append(cell); rows.append(row) }
        return rows.filter { !$0.allSatisfy(\.isEmpty) }
    }

    func rebuild() {
        table.tableColumns.forEach(table.removeTableColumn)
        for (index, header) in headers.enumerated() {
            let column = NSTableColumn(identifier: .init("\(index)")); column.title = header; column.width = 170
            table.addTableColumn(column)
        }
        picker.removeAllItems(); picker.addItems(withTitles: headers)
        refresh()
    }
    func refresh() {
        let term = filter.stringValue.lowercased()
        shown = rows.indices.filter { term.isEmpty || rows[$0].contains { $0.lowercased().contains(term) } }
        table.reloadData()
        window?.title = "QuickSheet - \(rows.count) rows"
    }
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let index = Int(column?.identifier.rawValue ?? "0") ?? 0
        let values = rows[shown[row]]
        let field = NSTextField(string: index < values.count ? values[index] : "")
        field.isBordered = false; field.drawsBackground = false; field.delegate = self
        field.tag = shown[row] * 1000 + index
        return field
    }
    func controlTextDidEndEditing(_ note: Notification) {
        guard let field = note.object as? NSTextField, field !== filter else { return }
        let row = field.tag / 1000, column = field.tag % 1000
        guard row < rows.count else { return }
        while rows[row].count <= column { rows[row].append("") }
        rows[row][column] = field.stringValue
    }
    func controlTextDidChange(_ note: Notification) { if note.object as? NSSearchField === filter { refresh() } }

    @objc func importCSV(_ sender: Any?) {
        let panel = NSOpenPanel(); panel.directoryURL = evalFolder; panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.beginSheetModal(for: window) { [self] in
            guard $0 == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            let parsed = Self.parse(text)
            guard let first = parsed.first else { return }
            headers = first; rows = Array(parsed.dropFirst()); rebuild(); status.stringValue = "Imported \(rows.count) rows from \(url.lastPathComponent)"
        }
    }
    @objc func exportCSV(_ sender: Any?) {
        window.makeFirstResponder(nil)
        let panel = NSSavePanel(); panel.directoryURL = evalFolder; panel.nameFieldStringValue = "Sheet.csv"; panel.allowedContentTypes = [.commaSeparatedText]
        panel.beginSheetModal(for: window) { [self] in
            guard $0 == .OK, let url = panel.url else { return }
            let lines = ([headers] + rows).map { $0.map { $0.contains(",") ? "\"\($0)\"" : $0 }.joined(separator: ",") }
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            status.stringValue = "Exported \(url.lastPathComponent)"
        }
    }
    @objc func printSheet(_ sender: Any?) { NSPrintOperation(view: table).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) }
    var column: Int { max(0, picker.indexOfSelectedItem) }
    @objc func sort(_ sender: Any?) {
        let index = column
        rows.sort { a, b in
            let x = index < a.count ? a[index] : "", y = index < b.count ? b[index] : ""
            if let m = Double(x.filter { $0.isNumber || $0 == "." }), let n = Double(y.filter { $0.isNumber || $0 == "." }), !x.contains(where: \.isLetter) { return m < n }
            return x.lowercased() < y.lowercased()
        }
        refresh(); status.stringValue = "Sorted by \(headers[index])"
    }
    @objc func dedupe(_ sender: Any?) {
        var seen = Set<String>(); let before = rows.count
        rows = rows.filter { seen.insert($0.joined(separator: "\u{1}").lowercased()).inserted }
        refresh(); status.stringValue = "Removed \(before - rows.count) duplicate rows"
    }
    @objc func sum(_ sender: Any?) {
        let index = column
        let total = shown.compactMap { index < rows[$0].count ? Double(rows[$0][index].filter { $0.isNumber || $0 == "." || $0 == "-" }) : nil }.reduce(0, +)
        status.stringValue = String(format: "Sum of %@ in %d rows shown: %.2f", headers[index], shown.count, total)
    }
    @objc func addRow(_ sender: Any?) { rows.append(Array(repeating: "", count: headers.count)); refresh() }
    @objc func deleteRow(_ sender: Any?) {
        guard table.selectedRow >= 0 else { status.stringValue = "Select a row first"; return }
        rows.remove(at: shown[table.selectedRow]); refresh()
    }
}

let sheet = Sheet()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let menu = NSMenu()
let first = NSMenuItem(); first.submenu = NSMenu(); menu.addItem(first)
first.submenu?.addItem(withTitle: "Quit QuickSheet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let file = NSMenuItem(); file.submenu = NSMenu(title: "File"); menu.addItem(file)
for (title, selector, key) in [("Import CSV...", #selector(Sheet.importCSV(_:)), "o"), ("Export CSV...", #selector(Sheet.exportCSV(_:)), "s"), ("Print...", #selector(Sheet.printSheet(_:)), "p")] {
    let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.target = sheet; file.submenu?.addItem(item)
}
let edit = NSMenuItem(); edit.submenu = NSMenu(title: "Edit"); menu.addItem(edit)
for (title, selector, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
    edit.submenu?.addItem(withTitle: title, action: selector, keyEquivalent: key)
}
app.mainMenu = menu

let window = NSWindow(contentRect: NSRect(x: 180, y: 140, width: 860, height: 560), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
sheet.window = window
let content = window.contentView!
let label = NSTextField(labelWithString: "Column:"); label.frame = NSRect(x: 12, y: 522, width: 60, height: 22); label.autoresizingMask = [.minYMargin]; content.addSubview(label)
sheet.picker.frame = NSRect(x: 72, y: 518, width: 150, height: 28); sheet.picker.autoresizingMask = [.minYMargin]; content.addSubview(sheet.picker)
var x: CGFloat = 230
for (title, selector) in [("Sort", #selector(Sheet.sort(_:))), ("Sum", #selector(Sheet.sum(_:))), ("Remove Duplicates", #selector(Sheet.dedupe(_:))), ("Add Row", #selector(Sheet.addRow(_:))), ("Delete Row", #selector(Sheet.deleteRow(_:)))] {
    let button = NSButton(title: title, target: sheet, action: selector); button.frame = NSRect(x: x, y: 516, width: title.count > 10 ? 150 : 92, height: 30); button.autoresizingMask = [.minYMargin]
    content.addSubview(button); x += button.frame.width + 4
}
sheet.filter.frame = NSRect(x: 12, y: 484, width: 300, height: 26); sheet.filter.placeholderString = "Show only rows containing"; sheet.filter.delegate = sheet; sheet.filter.autoresizingMask = [.minYMargin]
content.addSubview(sheet.filter)
let scroll = NSScrollView(frame: NSRect(x: 12, y: 36, width: 836, height: 440)); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
sheet.table.dataSource = sheet; sheet.table.delegate = sheet
scroll.documentView = sheet.table; content.addSubview(scroll)
sheet.status.frame = NSRect(x: 12, y: 8, width: 836, height: 22); sheet.status.autoresizingMask = [.width]; content.addSubview(sheet.status)
sheet.rebuild()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()

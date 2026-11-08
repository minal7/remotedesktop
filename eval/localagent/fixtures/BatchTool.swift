// Merges PDFs and shrinks photos, the small jobs people hunt for a tool to do. Real output files,
// through real file panels. Used only by the local agent evaluation.
import AppKit
import PDFKit
import UniformTypeIdentifiers

let evalFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("LocalAgentEval")

final class Tool: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var files: [URL] = []
    let table = NSTableView()
    let width = NSTextField(string: "1600")
    let status = NSTextField(labelWithString: "Add files to begin")
    var window: NSWindow!

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let size = (try? files[row].resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return NSTextField(labelWithString: "\(row + 1). \(files[row].lastPathComponent)  (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))")
    }
    @objc func add(_ sender: Any?) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.directoryURL = evalFolder
        panel.beginSheetModal(for: window) { [self] in
            if $0 == .OK { files += panel.urls; table.reloadData(); status.stringValue = "\(files.count) files" }
        }
    }
    @objc func remove(_ sender: Any?) { if table.selectedRow >= 0 { files.remove(at: table.selectedRow); table.reloadData() } }
    func shift(_ by: Int) {
        let from = table.selectedRow, to = from + by
        guard from >= 0, files.indices.contains(to) else { return }
        files.swapAt(from, to); table.reloadData(); table.selectRowIndexes([to], byExtendingSelection: false)
    }
    @objc func moveUp(_ sender: Any?) { shift(-1) }
    @objc func moveDown(_ sender: Any?) { shift(1) }
    @objc func merge(_ sender: Any?) {
        guard !files.isEmpty else { status.stringValue = "Add files first"; return }
        let panel = NSSavePanel(); panel.directoryURL = evalFolder; panel.nameFieldStringValue = "Merged.pdf"; panel.allowedContentTypes = [.pdf]
        panel.beginSheetModal(for: window) { [self] in
            guard $0 == .OK, let url = panel.url else { return }
            let out = PDFDocument()
            for file in files {
                guard let doc = PDFDocument(url: file) else { continue }
                for index in 0..<doc.pageCount { if let page = doc.page(at: index) { out.insert(page, at: out.pageCount) } }
            }
            out.write(to: url); status.stringValue = "Merged \(out.pageCount) pages into \(url.lastPathComponent)"
        }
    }
    @objc func resize(_ sender: Any?) {
        guard !files.isEmpty else { status.stringValue = "Add files first"; return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = evalFolder; panel.prompt = "Save Here"
        panel.beginSheetModal(for: window) { [self] in
            guard $0 == .OK, let folder = panel.url else { return }
            let target = CGFloat(width.integerValue)
            for file in files {
                guard target > 0, let image = NSImage(contentsOf: file), let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) else { continue }
                let scale = min(1, target / CGFloat(bitmap.pixelsWide))
                let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(CGFloat(bitmap.pixelsWide) * scale), pixelsHigh: Int(CGFloat(bitmap.pixelsHigh) * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
                bitmap.draw(in: NSRect(x: 0, y: 0, width: out.pixelsWide, height: out.pixelsHigh)); NSGraphicsContext.restoreGraphicsState()
                let name = (file.lastPathComponent as NSString).deletingPathExtension + "-small.jpg"
                try? out.representation(using: .jpeg, properties: [.compressionFactor: 0.7])?.write(to: folder.appendingPathComponent(name))
            }
            status.stringValue = "Saved \(files.count) smaller photos in \(folder.lastPathComponent)"
        }
    }
}

let tool = Tool()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let menu = NSMenu()
let first = NSMenuItem(); first.submenu = NSMenu(); menu.addItem(first)
first.submenu?.addItem(withTitle: "Quit BatchTool", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let edit = NSMenuItem(); edit.submenu = NSMenu(title: "Edit"); menu.addItem(edit)
for (title, selector, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
    edit.submenu?.addItem(withTitle: title, action: selector, keyEquivalent: key)
}
app.mainMenu = menu
let window = NSWindow(contentRect: NSRect(x: 240, y: 180, width: 700, height: 460), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
window.title = "BatchTool"
tool.window = window
let content = window.contentView!
var x: CGFloat = 12
for (title, selector) in [("Add Files", #selector(Tool.add(_:))), ("Remove", #selector(Tool.remove(_:))), ("Move Up", #selector(Tool.moveUp(_:))), ("Move Down", #selector(Tool.moveDown(_:)))] {
    let button = NSButton(title: title, target: tool, action: selector); button.frame = NSRect(x: x, y: 418, width: 104, height: 30); content.addSubview(button); x += 108
}
let scroll = NSScrollView(frame: NSRect(x: 12, y: 96, width: 676, height: 314)); scroll.hasVerticalScroller = true
let column = NSTableColumn(identifier: .init("file")); column.title = "Files, in order"; column.width = 640; tool.table.addTableColumn(column)
tool.table.dataSource = tool; tool.table.delegate = tool; scroll.documentView = tool.table; content.addSubview(scroll)
let merge = NSButton(title: "Merge PDFs", target: tool, action: #selector(Tool.merge(_:))); merge.frame = NSRect(x: 12, y: 54, width: 130, height: 30); content.addSubview(merge)
let shrink = NSButton(title: "Shrink Photos", target: tool, action: #selector(Tool.resize(_:))); shrink.frame = NSRect(x: 150, y: 54, width: 130, height: 30); content.addSubview(shrink)
let label = NSTextField(labelWithString: "Photo width in pixels:"); label.frame = NSRect(x: 292, y: 58, width: 150, height: 22); content.addSubview(label)
tool.width.frame = NSRect(x: 444, y: 56, width: 90, height: 26); content.addSubview(tool.width)
tool.status.frame = NSRect(x: 12, y: 16, width: 676, height: 22); content.addSubview(tool.status)
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()

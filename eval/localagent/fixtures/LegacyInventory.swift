// A deliberately inaccessible app: everything is drawn by hand in one view, so
// the accessibility tree is empty and only pixels show what's there, like old
// Java, Qt and remote-session software. Used only by the local agent evaluation.
import AppKit

let outputPath = (NSHomeDirectory() as NSString).appendingPathComponent("LocalAgentEval/legacy/records.txt")

final class Canvas: NSView {
    struct Box { let name: String; let rect: NSRect }
    var customer = "", quantity = "", records: [String] = [], focus = "", status = "No changes yet"
    let boxes = [
        Box(name: "customer", rect: NSRect(x: 150, y: 70, width: 280, height: 30)),
        Box(name: "quantity", rect: NSRect(x: 150, y: 115, width: 120, height: 30)),
        Box(name: "Add Record", rect: NSRect(x: 150, y: 160, width: 120, height: 32)),
        Box(name: "Save All", rect: NSRect(x: 285, y: 160, width: 120, height: 32)),
    ]
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    private func draw(_ text: String, at point: NSPoint, size: CGFloat = 15, bold: Bool = false) {
        (text as NSString).draw(at: point, withAttributes: [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black])
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.93, alpha: 1).setFill(); bounds.fill()
        draw("INVENTORY SYSTEM v2.1", at: NSPoint(x: 20, y: 22), size: 18, bold: true)
        draw("Customer:", at: NSPoint(x: 40, y: 76))
        draw("Quantity:", at: NSPoint(x: 40, y: 121))
        for box in boxes {
            let isField = box.name == "customer" || box.name == "quantity"
            (isField ? NSColor.white : NSColor(white: 0.8, alpha: 1)).setFill(); box.rect.fill()
            (focus == box.name ? NSColor.blue : NSColor.darkGray).setStroke()
            let path = NSBezierPath(rect: box.rect); path.lineWidth = focus == box.name ? 2 : 1; path.stroke()
            if isField { draw(box.name == "customer" ? customer : quantity, at: NSPoint(x: box.rect.minX + 6, y: box.rect.minY + 6)) }
            else { draw(box.name, at: NSPoint(x: box.rect.minX + 18, y: box.rect.minY + 7), bold: true) }
        }
        draw("Records:", at: NSPoint(x: 40, y: 215), bold: true)
        for (index, record) in records.enumerated() { draw(record, at: NSPoint(x: 60, y: 240 + CGFloat(index) * 22)) }
        draw("Status: \(status)", at: NSPoint(x: 40, y: 420))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let box = boxes.first(where: { $0.rect.contains(point) }) else { return }
        switch box.name {
        case "Add Record":
            guard !customer.isEmpty, !quantity.isEmpty else { status = "Fill in both fields"; break }
            records.append("\(customer),\(quantity)"); customer = ""; quantity = ""; focus = ""; status = "Unsaved changes"
        case "Save All":
            try? FileManager.default.createDirectory(atPath: (outputPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? records.joined(separator: "\n").write(toFile: outputPath, atomically: true, encoding: .utf8)
            status = "Saved \(records.count) records"
        default: focus = box.name
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard focus == "customer" || focus == "quantity", let characters = event.characters else { return }
        for character in characters {
            if character == "\u{7F}" || character == "\u{8}" {
                if focus == "customer" { _ = customer.popLast() } else { _ = quantity.popLast() }
            } else if character == "\t" { focus = focus == "customer" ? "quantity" : "customer" }
            else if !character.isNewline {
                if focus == "customer" { customer.append(character) } else { quantity.append(character) }
            }
        }
        needsDisplay = true
    }
}

let canvas = Canvas()

// The real system print sheet, with its PDF menu and save panel, as any old app gets it.
final class Printing: NSObject {
    @objc func printRecords(_ sender: Any?) {
        guard let window = canvas.window else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .spool
        NSPrintOperation(view: canvas, printInfo: info).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}
let printing = Printing()

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let mainMenu = NSMenu()
let appItem = NSMenuItem(); appItem.submenu = NSMenu(); mainMenu.addItem(appItem)
appItem.submenu?.addItem(withTitle: "Quit Legacy Inventory", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let fileItem = NSMenuItem(); fileItem.submenu = NSMenu(title: "File"); mainMenu.addItem(fileItem)
let printItem = NSMenuItem(title: "Print...", action: #selector(Printing.printRecords(_:)), keyEquivalent: "p")
printItem.target = printing
fileItem.submenu?.addItem(printItem)
app.mainMenu = mainMenu
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 560, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Legacy Inventory"
window.contentView = canvas
let seed = (outputPath as NSString).deletingLastPathComponent + "/seed.txt"
if let text = try? String(contentsOfFile: seed, encoding: .utf8) { canvas.records = text.split(separator: "\n").map(String.init) }
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(canvas)
app.activate(ignoringOtherApps: true)
app.run()

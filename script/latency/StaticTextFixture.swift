import AppKit
import Foundation

// Synthetic-only reference: never captures the desktop or another window.
final class TextFixture: NSView {
    let headerFont: NSFont
    let textFonts: [NSFont]
    init(frame: CGRect, headerFont: NSFont, textFonts: [NSFont]) {
        self.headerFont = headerFont; self.textFonts = textFonts
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("Created programmatically") }
    override var isFlipped: Bool { true }
    var fontCrops: [CGRect] {
        [CGRect(x: 60, y: 120, width: 460, height: 108),
         CGRect(x: 60, y: 242, width: 460, height: 114),
         CGRect(x: 60, y: 370, width: 460, height: 120)]
    }
    var textCrop: CGRect { fontCrops.reduce(CGRect.null) { $0.union($1) } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        let crop = textCrop
        NSColor.black.setStroke()
        let border = NSBezierPath(rect: crop.insetBy(dx: -4, dy: -4)); border.lineWidth = 2; border.stroke()
        let title: [NSAttributedString.Key: Any] = [.font: headerFont, .foregroundColor: NSColor.black]
        ("LATENCY SHARPNESS FIXTURE" as NSString)
            .draw(at: NSPoint(x: 48, y: 44), withAttributes: title)
        let lines = ["let readableText = 1234567890; // Remote Desktop",
                     "func render(_ frame: VideoFrame) -> Result {",
                     "    guard frame.isValid else { return .unavailable }",
                     "    return .presented(frame.width, frame.height)",
                     "}",
                     "Aa Bb Cc Dd Ee Ff Gg Hh Ii Jj  0123456789 !@#$%"]
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: crop).addClip()
        for (index, size) in [11.0, 12.0, 13.0].enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: textFonts[index],
                .foregroundColor: NSColor.black]
            var y = fontCrops[index].minY
            for line in lines {
                (("\(Int(size))pt  " + line) as NSString).draw(at: NSPoint(x: crop.minX, y: y), withAttributes: attributes)
                y += size + 7
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class FixtureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { NSApp.terminate(nil) } else { super.keyDown(with: event) }
    }
}

final class FixtureApp: NSObject, NSApplicationDelegate {
    let output: URL
    let lifetime: TimeInterval
    var window: NSWindow?
    init(output: URL, lifetime: TimeInterval) { self.output = output; self.lifetime = lifetime }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let displayID = CGMainDisplayID()
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
            }) else { throw Failure.message("Main display unavailable") }
            let rect = screen.frame
            guard rect.width >= 600, rect.height >= 600 else { throw Failure.message("Display too small for fixture") }
            guard let headerFont = NSFont(name: "Menlo-Bold", size: 20),
                  let font11 = NSFont(name: "Menlo-Regular", size: 11),
                  let font12 = NSFont(name: "Menlo-Regular", size: 12),
                  let font13 = NSFont(name: "Menlo-Regular", size: 13) else {
                throw Failure.message("Required Menlo fonts are unavailable")
            }
            let view = TextFixture(frame: CGRect(origin: .zero, size: rect.size),
                                   headerFont: headerFont, textFonts: [font11, font12, font13])
            let window = FixtureWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            self.window = window; window.contentView = view; window.level = .screenSaver
            window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure.message("Cannot allocate fixture bitmap") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure.message("Cannot encode fixture bitmap") }
            try png.write(to: output.appendingPathComponent("reference.png"), options: .atomic)
            let sx = Double(bitmap.pixelsWide) / view.bounds.width, sy = Double(bitmap.pixelsHigh) / view.bounds.height
            let crop = view.textCrop
            func pixels(_ rect: CGRect) -> [Int] {
                [Int((rect.minX * sx).rounded()), Int((rect.minY * sy).rounded()),
                 Int((rect.width * sx).rounded()), Int((rect.height * sy).rounded())]
            }
            let metadata: [String: Any] = ["fixture": "synthetic_static_text", "origin": "top_left",
                "image_pixels": [bitmap.pixelsWide, bitmap.pixelsHigh], "source_display_pixels": [CGDisplayPixelsWide(displayID), CGDisplayPixelsHigh(displayID)],
                "view_points": [view.bounds.width, view.bounds.height],
                "crop_points": [crop.minX, crop.minY, crop.width, crop.height],
                "crop_pixels": pixels(crop),
                "font_crops_pixels": Dictionary(uniqueKeysWithValues: zip(["11pt", "12pt", "13pt"], view.fontCrops.map(pixels))),
                "reference": "reference.png", "font": "Menlo-Regular 11, 12, 13 pt"]
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("geometry.json"), options: .atomic)
            print("FIXTURE_READY \(output.path)"); fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { NSApp.terminate(nil) }
        } catch { fputs("Fixture failed: \(error)\n", stderr); exit(1) }
    }
}

enum Failure: Error { case message(String) }
let arguments = CommandLine.arguments
guard arguments.count == 3, let seconds = Double(arguments[2]), seconds.isFinite, seconds > 0, seconds <= 600 else {
    fputs("Usage: StaticTextFixture NEW_OUTPUT_DIRECTORY SECONDS(1..600)\n", stderr); exit(2)
}
let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
guard !FileManager.default.fileExists(atPath: output.path) else {
    fputs("Output directory already exists\n", stderr); exit(1)
}
do { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false) }
catch { fputs("Output must be a new directory: \(error)\n", stderr); exit(1) }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = FixtureApp(output: output, lifetime: seconds)
app.delegate = delegate
app.run()

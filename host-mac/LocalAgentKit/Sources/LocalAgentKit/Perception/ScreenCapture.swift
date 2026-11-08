import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// One captured region of the screen. `rect` is global display points; `image`
/// holds device pixels. The signature is a tiny grayscale thumbnail used to tell
/// "did anything change" without comparing whole frames or asking the model.
public struct ScreenFrame: @unchecked Sendable {
    public let image: CGImage
    public let rect: CGRect
    public let signature: [UInt8]

    public static let signatureSide = 160

    public init(image: CGImage, rect: CGRect) {
        self.image = image
        self.rect = rect
        self.signature = Self.makeSignature(image)
    }

    static func makeSignature(_ image: CGImage) -> [UInt8] {
        let side = signatureSide
        var buffer = [UInt8](repeating: 0, count: side * side)
        buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return buffer
    }

    /// Fraction of thumbnail cells that visibly differ, 0...1.
    public static func distance(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var changed = 0
        for index in a.indices where abs(Int(a[index]) - Int(b[index])) > 6 { changed += 1 }
        return Double(changed) / Double(a.count)
    }

    /// Scans right from a point for the next drawn edge, such as the border of an
    /// input box beside its label. Returns the x position in global points.
    public func firstEdge(rightOf point: CGPoint, within distance: CGFloat) -> CGFloat? {
        guard rect.width > 0, rect.contains(point) else { return nil }
        let scale = CGFloat(image.width) / rect.width
        let startX = Int((point.x - rect.minX) * scale), y = Int((point.y - rect.minY) * scale)
        let length = min(Int(distance * scale), image.width - startX)
        guard length > 2, y >= 0, y < image.height,
              let row = image.cropping(to: CGRect(x: startX, y: y, width: length, height: 1)) else { return nil }
        var pixels = [UInt8](repeating: 0, count: length)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: length, height: 1, bitsPerComponent: 8, bytesPerRow: length,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(row, in: CGRect(x: 0, y: 0, width: length, height: 1))
            return true
        }
        guard drawn else { return nil }
        let background = Int(pixels[0])
        for index in 1..<length where abs(Int(pixels[index]) - background) > 24 {
            return point.x + CGFloat(index) / scale
        }
        return nil
    }

    /// JPEG for the model, longest side capped. Returns the bytes and the pixel size sent.
    public func encodedForModel(maxSide: Int, marks: [ImageMark] = [], quality: Double = 0.8) -> (data: Data, size: CGSize)? {
        let width = image.width, height = image.height
        let scale = min(1, Double(maxSide) / Double(max(width, height)))
        let outWidth = max(1, Int(Double(width) * scale)), outHeight = max(1, Int(Double(height) * scale))
        guard let context = CGContext(data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
        Self.draw(marks, in: context, source: rect, outSize: CGSize(width: outWidth, height: outHeight))
        guard let scaled = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data, CGSize(width: outWidth, height: outHeight))
    }

    /// Crop of a global-points region, for `zoom`.
    public func cropped(to region: CGRect) -> ScreenFrame? {
        let clipped = region.intersection(rect)
        guard !clipped.isNull, clipped.width > 1, clipped.height > 1, rect.width > 0 else { return nil }
        let scale = Double(image.width) / rect.width
        let pixelRect = CGRect(x: (clipped.minX - rect.minX) * scale, y: (clipped.minY - rect.minY) * scale,
                               width: clipped.width * scale, height: clipped.height * scale)
        guard let cropped = image.cropping(to: pixelRect) else { return nil }
        return ScreenFrame(image: cropped, rect: clipped)
    }

    private static func draw(_ marks: [ImageMark], in context: CGContext, source: CGRect, outSize: CGSize) {
        guard source.width > 0, source.height > 0 else { return }
        let sx = outSize.width / source.width, sy = outSize.height / source.height
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 11, nil)
        for mark in marks {
            // CoreGraphics is bottom-left origin; screen coordinates are top-left.
            let x = (mark.frame.minX - source.minX) * sx
            let y = outSize.height - (mark.frame.minY - source.minY) * sy
            let text = "\(mark.id)"
            let attributed = NSAttributedString(string: text, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            let box = CGRect(x: x, y: y - 13, width: width + 5, height: 13)
            context.setFillColor(CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 0.9))
            context.fill(box)
            context.textPosition = CGPoint(x: box.minX + 2.5, y: box.minY + 3)
            CTLineDraw(line, context)
        }
    }
}

public struct ImageMark: Sendable {
    public let id: Int
    public let frame: CGRect
    public init(id: Int, frame: CGRect) { self.id = id; self.frame = frame }
}

public enum ScreenCapturer {
    public enum CaptureError: Error { case noDisplay, notPermitted }

    /// Captures what is actually visible in `rect` (global points), including any
    /// dialog or popup floating above the target window. That is what the person
    /// sees on the live view and what clicks will land on.
    public static func capture(rect: CGRect) async throws -> ScreenFrame {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let clipped = rect.isEmpty ? display.frame : rect.intersection(display.frame)
        let target = clipped.isNull || clipped.isEmpty ? display.frame : clipped
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: target.minX - display.frame.minX, y: target.minY - display.frame.minY,
                                          width: target.width, height: target.height)
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(target.width * scale)
        configuration.height = Int(target.height * scale)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return ScreenFrame(image: image, rect: target)
    }

    public static func mainDisplayRect() -> CGRect { CGDisplayBounds(CGMainDisplayID()) }

    /// System panels that draw on an app's behalf, such as the sandboxed save dialog.
    private static let helperBundles: Set<String> = [
        "com.apple.appkit.xpc.openAndSavePanelService", "com.apple.quicklook.QuickLookUIService",
    ]

    /// Drawn as part of the desktop itself: the menu bar and its status items.
    private static let desktopFurniture: Set<String> = ["com.apple.WindowServer", "com.apple.controlcenter", "com.apple.systemuiserver"]

    /// The whole display as it would look with only this app running: a plain backdrop
    /// and the app's windows where they really are, so coordinates on the image are true
    /// screen positions. A desktop-trained model sees the kind of screen it learned on, and
    /// no other app's contents reach it. `regions` are the places it may click, in global points.
    public static func captureApp(pid: pid_t, near rect: CGRect) async throws -> (frame: ScreenFrame, regions: [CGRect])? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        func isTarget(_ app: SCRunningApplication) -> Bool { app.processID == pid || helperBundles.contains(app.bundleIdentifier) }
        let windows = content.windows.filter { window in
            guard window.isOnScreen, window.frame.width > 1, window.frame.height > 1, window.frame.intersects(display.frame) else { return false }
            return window.owningApplication.map(isTarget) ?? false
        }
        guard !windows.isEmpty else { return nil }
        // Leaving out by window, not by app: an app filter goes by bundle ID and would take a
        // second copy of the same app with it. This keeps every remaining window in place.
        let others = content.windows.filter { window in
            guard let owner = window.owningApplication, !isTarget(owner) else { return false }
            return !desktopFurniture.contains(owner.bundleIdentifier)
        }
        let filter = SCContentFilter(display: display, excludingWindows: others)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(display.frame.width * scale)
        configuration.height = Int(display.frame.height * scale)
        configuration.showsCursor = false
        let captured = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        // Leaving out other apps' windows still leaves the desktop: its icons are the person's
        // files, and they send a model off looking for things to open. The menu bar's items
        // don't draw in this capture at all, so menus reach the model as text instead.
        let shown = windows.map(\.frame)
        let image = masked(captured, keeping: shown, display: display.frame) ?? captured
        return (ScreenFrame(image: image, rect: display.frame), shown)
    }

    /// The image with everything outside `regions` (global points) painted one plain colour.
    static func masked(_ image: CGImage, keeping regions: [CGRect], display: CGRect) -> CGImage? {
        guard display.width > 0, let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let scale = CGFloat(image.width) / display.width
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1))
        context.fill(bounds)
        // Screen coordinates start at the top; CoreGraphics starts at the bottom.
        context.clip(to: regions.map {
            CGRect(x: ($0.minX - display.minX) * scale, y: CGFloat(image.height) - ($0.maxY - display.minY) * scale, width: $0.width * scale, height: $0.height * scale)
        })
        context.draw(image, in: bounds)
        return context.makeImage()
    }

    /// The app's own menus: not the Apple menu on the left, which can restart or log out,
    /// and not the status items on the right.
    public static func appMenuStrip(display: CGRect, menuBarHeight: CGFloat) -> CGRect {
        CGRect(x: display.minX + 40, y: display.minY, width: display.width / 2 - 40, height: max(0, menuBarHeight))
    }
}

/// Rules for keeping test runs inside their own apps.
public enum TestRunFence {
    /// A Dock window covering the whole display is see-through, apart from the bar of icons itself.
    /// If the bar can't be located, the point is treated as the Dock's.
    public static func dockPassesThrough(window: CGRect, display: CGRect, bar: CGRect?, point: CGPoint) -> Bool {
        guard let bar, window.contains(display) else { return false }
        return !bar.contains(point)
    }
}

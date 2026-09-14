import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Opaque, task-scoped authority to resume the exact visual execution that
/// produced an approval request. The nonce prevents a delayed or duplicate
/// approval response from being applied to a later visual session.
struct ComputerUseVisualApprovalContinuation: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let taskID: String
    let nonce: UUID
    /// Process-local evidence from the proposal, never part of the phone's
    /// approval payload. The host must validate it before posting the action.
    let browserPageEvidence: ComputerUseBrowserPageEvidence?
    let nativeBrowserTarget: ComputerUseOwnedBrowser.AgentTarget?

    init(taskID: String, nonce: UUID, browserPageEvidence: ComputerUseBrowserPageEvidence? = nil,
         nativeBrowserTarget: ComputerUseOwnedBrowser.AgentTarget? = nil) {
        self.taskID = taskID
        self.nonce = nonce
        self.browserPageEvidence = browserPageEvidence
        self.nativeBrowserTarget = nativeBrowserTarget
    }

    var description: String { "ComputerUseVisualApprovalContinuation(browserBound: \(browserPageEvidence != nil))" }
    var debugDescription: String { description }
}

/// A screen image paired with the global-display coordinates used by the
/// intervention-safe input injector.
struct ComputerUseScreenObservation: Sendable {
    let image: CIImage
    let displayBounds: CGRect
    /// Global Accessibility bounds for the focused window captured with this
    /// display image. Read-only screen extractors use this to ignore coherent
    /// but stale content in other visible windows. A missing bound must be
    /// treated as unavailable evidence, never as permission to scan another
    /// application's pixels.
    let frontmostWindowBounds: CGRect?

    init(
        image: CIImage,
        displayBounds: CGRect,
        frontmostWindowBounds: CGRect? = nil
    ) {
        self.image = image
        self.displayBounds = displayBounds
        self.frontmostWindowBounds = frontmostWindowBounds
    }

    /// Converts top-left global AX window coordinates into the bottom-left,
    /// unit-space convention used by Vision text observations.
    var normalizedFrontmostWindowBounds: CGRect? {
        guard let frontmostWindowBounds,
              displayBounds.width.isFinite,
              displayBounds.height.isFinite,
              displayBounds.width > 0,
              displayBounds.height > 0 else {
            return nil
        }
        let visible = frontmostWindowBounds.intersection(displayBounds)
        guard !visible.isNull,
              !visible.isEmpty,
              visible.width.isFinite,
              visible.height.isFinite else {
            return nil
        }
        return CGRect(
            x: (visible.minX - displayBounds.minX) / displayBounds.width,
            y: 1 - (visible.maxY - displayBounds.minY) / displayBounds.height,
            width: visible.width / displayBounds.width,
            height: visible.height / displayBounds.height)
    }
}

/// Common transport bounds for the supported local vision models.
enum ComputerUseModelImagePolicy {
    static let maximumPNGBytes = 2 * 1_024 * 1_024
    static func validatePNG(_ data: Data) throws {
        guard data.count <= maximumPNGBytes,
              data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              (1...4096).contains(width), (1...4096).contains(height), width * height <= 4_194_304 else {
            throw OSAtlasLlamaRuntimeError.invalidVisionInput
        }
    }
}

/// Explicit, bounded native UI data for choosing the next action. Verification
/// snapshots and target authority remain local; protected values never project.
struct ComputerUseNativeTextState: Equatable, Sendable {
    static let maximumPrefixBytes = 512
    let valuePrefix: String
    let valueUTF8Bytes: Int
    let valueUTF16Units: Int
    let selection: NSRange
    let truncated: Bool

    init?(snapshot: ComputerUseTextSnapshot) {
        guard snapshot.isEditable, !snapshot.isSecure else { return nil }
        let bytes = snapshot.value.utf8.count, units = snapshot.value.utf16.count
        guard bytes <= ComputerUseTextEditor.maximumObservedValueBytes,
              snapshot.selection.location >= 0, snapshot.selection.length >= 0,
              snapshot.selection.location <= units, snapshot.selection.length <= units - snapshot.selection.location else { return nil }
        var prefix = "", prefixBytes = 0
        for character in snapshot.value {
            let text = String(character), size = String(character).utf8.count
            guard prefixBytes + size <= Self.maximumPrefixBytes else { break }
            prefix += text; prefixBytes += size
        }
        valuePrefix = prefix; valueUTF8Bytes = bytes; valueUTF16Units = units
        selection = snapshot.selection; truncated = prefixBytes != bytes
    }

    var jsonObject: [String: Any] {
        ["value_prefix": valuePrefix, "value_utf8_bytes": valueUTF8Bytes, "value_utf16_units": valueUTF16Units,
         "value_truncated": truncated, "selection_utf16": ["location": selection.location, "length": selection.length]]
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.valuePrefix.utf8.elementsEqual(rhs.valuePrefix.utf8) && lhs.valueUTF8Bytes == rhs.valueUTF8Bytes
            && lhs.valueUTF16Units == rhs.valueUTF16Units && lhs.selection == rhs.selection && lhs.truncated == rhs.truncated
    }
}

/// Read-only hints for the current screenshot. They do not identify an input
/// recipient or authorize effects, and the list need not cover every control.
struct ComputerUseNativeControls: Equatable, Sendable {
    static let maximumItems = 16
    /// AX metadata describes only this focused window. A false modal flag
    /// does not rule out a sheet, web dialog or overlay elsewhere in the UI.
    struct Window: Equatable, Sendable {
        let role: String?
        let subrole: String?
        let title: String?
        let modal: Bool?
        let truncated: Bool

        init(role: String?, subrole: String?, title: String?, modal: Bool?) {
            var clipped = false
            func identifier(_ value: String?) -> String? {
                guard let value, !value.isEmpty else { return nil }
                guard value.utf8.count <= 128 else { clipped = true; return nil }
                return value
            }
            self.role = identifier(role); self.subrole = identifier(subrole)
            if let title {
                var prefix = "", bytes = 0
                for character in title {
                    let next = String(character)
                    guard bytes + next.utf8.count <= 384 else { break }
                    prefix += next; bytes += next.utf8.count
                }
                self.title = prefix; clipped = clipped || bytes < title.utf8.count
            } else { self.title = nil }
            self.modal = modal; truncated = clipped
        }
        var jsonObject: [String: Any] {
            ["role": role as Any? ?? NSNull(), "subrole": subrole as Any? ?? NSNull(),
             "title": title as Any? ?? NSNull(), "modal": modal as Any? ?? NSNull(), "truncated": truncated]
        }
        static func == (lhs: Self, rhs: Self) -> Bool {
            func exact(_ a: String?, _ b: String?) -> Bool {
                switch (a, b) {
                case (nil, nil): return true
                case (let a?, let b?): return a.utf8.elementsEqual(b.utf8)
                default: return false
                }
            }
            return exact(lhs.role, rhs.role) && exact(lhs.subrole, rhs.subrole) && exact(lhs.title, rhs.title)
                && lhs.modal == rhs.modal && lhs.truncated == rhs.truncated
        }
    }
    struct Item: Equatable, Sendable {
        let description: String
        let bounds1000: [Double]
        let enabled: Bool?

        init?(description: String, frame: CGRect, enabled: Bool?, displayBounds: CGRect) {
            guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  description.utf8.count <= 512, Self.valid(frame), Self.valid(displayBounds),
                  displayBounds.contains(frame) else { return nil }
            self.description = description; self.enabled = enabled
            bounds1000 = [(frame.minX - displayBounds.minX) / displayBounds.width * 1000,
                          (frame.minY - displayBounds.minY) / displayBounds.height * 1000,
                          frame.width / displayBounds.width * 1000, frame.height / displayBounds.height * 1000]
        }
        private static func valid(_ frame: CGRect) -> Bool {
            [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy { $0.isFinite && abs($0) <= 1_000_000 }
                && frame.size.width > 0 && frame.size.height > 0
        }
        var jsonObject: [String: Any] {
            ["description": description, "bounds_1000": bounds1000, "enabled": enabled as Any? ?? NSNull()]
        }
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.description.utf8.elementsEqual(rhs.description.utf8) && lhs.bounds1000 == rhs.bounds1000 && lhs.enabled == rhs.enabled
        }
    }
    let items: [Item]
    let truncated: Bool
    let window: Window?
    init?(items: [Item], truncated: Bool, window: Window? = nil) {
        guard items.count <= Self.maximumItems else { return nil }
        self.items = items; self.truncated = truncated; self.window = window
    }
    var jsonObject: [String: Any] {
        ["items": items.map(\.jsonObject), "truncated": truncated, "window": window?.jsonObject as Any? ?? NSNull()]
    }
}

/// A bounded full-display image. This is geometry and model input only, never
/// authority to dispatch: native admission must still revalidate the screen,
/// frontmost application, focus, authentication and task ownership.
struct ComputerUseDesktopImage: Sendable {
    let png: Data
    let pixelWidth: Int
    let pixelHeight: Int
    let displayBounds: CGRect

    init(observation: ComputerUseScreenObservation) throws {
        let bounds = observation.displayBounds, extent = observation.image.extent
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              abs(bounds.origin.x) <= 1_000_000, abs(bounds.origin.y) <= 1_000_000,
              (1...1_000_000).contains(bounds.width), (1...1_000_000).contains(bounds.height),
              bounds == bounds.integral,
              extent.origin.x.isFinite, extent.origin.y.isFinite,
              (1...65_536).contains(extent.width), (1...65_536).contains(extent.height),
              extent == extent.integral,
              abs(extent.width - bounds.width * extent.height / bounds.height) <= 1,
              abs(extent.height - bounds.height * extent.width / bounds.width) <= 1 else {
            throw OSAtlasLlamaRuntimeError.invalidVisionInput
        }
        let encoded: (Data, Int, Int) = try autoreleasepool {
            let context = CIContext(options: [.cacheIntermediates: false])
            defer { context.clearCaches() }
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
                throw OSAtlasLlamaRuntimeError.invalidVisionInput
            }
            let image = observation.image.cropped(to: extent).transformed(by:
                CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            var scale = min(1, 2048 / max(extent.width, extent.height))
            // PNG is lossless. Busy desktops can exceed the byte cap even at
            // valid dimensions; reduce the entire image in a finite loop.
            for _ in 0..<6 {
                let width = max(1, Int(floor(extent.width * scale)))
                let height = max(1, Int(floor(extent.height * scale)))
                let resized = image.transformed(by: CGAffineTransform(
                    scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
                    .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
                guard let png = context.pngRepresentation(of: resized, format: .RGBA8,
                    colorSpace: colorSpace) else { throw OSAtlasLlamaRuntimeError.invalidVisionInput }
                if png.count <= ComputerUseModelImagePolicy.maximumPNGBytes {
                    try ComputerUseModelImagePolicy.validatePNG(png)
                    return (png, width, height)
                }
                scale *= 0.75
            }
            throw OSAtlasLlamaRuntimeError.invalidVisionInput
        }
        png = encoded.0; pixelWidth = encoded.1; pixelHeight = encoded.2
        displayBounds = bounds
    }

    /// Models use top-left 0...1000 coordinates over the submitted full image.
    /// Map through the original display, not its AX window or downscaled pixels.
    /// The inclusive 1000 edge selects the final in-display input cell.
    func displayPoint(normalizedX x: Double, normalizedY y: Double) throws -> (x: Int, y: Int) {
        guard x.isFinite, y.isFinite, (0...1000).contains(x), (0...1000).contains(y) else {
            throw OSAtlasLlamaRuntimeError.invalidVisionInput
        }
        return (Int(displayBounds.minX) + min(Int(displayBounds.width) - 1, Int(floor(x / 1000 * displayBounds.width))),
                Int(displayBounds.minY) + min(Int(displayBounds.height) - 1, Int(floor(y / 1000 * displayBounds.height))))
    }

    /// Compare the complete visible target plus surrounding label context.
    func matchesPixels(of other: Self, in displayRect: CGRect, wholePixelsOnly: Bool = false) throws -> Bool {
        guard displayBounds == other.displayBounds, pixelWidth == other.pixelWidth, pixelHeight == other.pixelHeight,
              let rect = imageRect(for: displayRect, wholePixelsOnly: wholePixelsOnly) else { return false }
        return try Self.pixels(png, in: rect) == Self.pixels(other.png, in: rect)
    }

    /// The caller supplies a focused field only after separately verifying
    /// unchanged editable text, collapsed selection and signed app authority.
    func matchesPointerPixels(of other: Self, window: CGRect, target: CGRect, unchangedFocusedField: CGRect? = nil,
        onInsertionPointDifference: ((CGRect, CGRect, CGRect) -> Void)? = nil) throws -> Bool {
        guard !target.isEmpty, window.contains(target) else { return false }
        if unchangedFocusedField == target {
            return try matchesInsertionPointPixels(of: other, window: window, field: target,
                onDifference: onInsertionPointDifference)
        }
        // Surrounding context belongs to this window. Padding an edge control
        // must not import another application's pixels or partial edge cells.
        return try matchesPixels(of: other, in: target.insetBy(dx: -40, dy: -40).intersection(window), wholePixelsOnly: true)
    }

    /// This is only valid with separately verified, unchanged editable text,
    /// collapsed selection, application/window identity and native field bounds.
    /// Allow a narrow vertical insertion-point change inside that field, while
    /// requiring every other pixel in the focused window to remain unchanged.
    func matchesInsertionPointPixels(of other: Self, window: CGRect, field: CGRect,
        onDifference: ((CGRect, CGRect, CGRect) -> Void)? = nil) throws -> Bool {
        guard displayBounds == other.displayBounds, pixelWidth == other.pixelWidth, pixelHeight == other.pixelHeight,
              window.contains(field), !field.isEmpty, let rect = imageRect(for: window, wholePixelsOnly: true),
              let fieldPixels = imageRect(for: field) else { return false }
        let a = try Self.pixels(png, in: rect), b = try Self.pixels(other.png, in: rect)
        let width = Int(rect.width), height = Int(rect.height)
        var left = width, top = height, right = -1, bottom = -1
        a.withUnsafeBytes { (first: UnsafeRawBufferPointer) in
            b.withUnsafeBytes { (second: UnsafeRawBufferPointer) in
                for y in 0..<height {
                    for x in 0..<width {
                        let i = (y * width + x) * 4
                        if (0..<4).contains(where: { first[i + $0] != second[i + $0] }) {
                            left = min(left, x); top = min(top, y); right = max(right, x); bottom = max(bottom, y)
                        }
                    }
                }
            }
        }
        if right < 0 { return true }
        let changed = CGRect(x: displayBounds.minX + (rect.minX + CGFloat(left)) * displayBounds.width / CGFloat(pixelWidth),
            y: displayBounds.minY + (rect.minY + CGFloat(top)) * displayBounds.height / CGFloat(pixelHeight),
            width: CGFloat(right - left + 1) * displayBounds.width / CGFloat(pixelWidth),
            height: CGFloat(bottom - top + 1) * displayBounds.height / CGFloat(pixelHeight))
        // AX uses logical points; a resized image contains whole pixel cells.
        // Compare containment in the same outward-rounded pixel space so an
        // edge cell is not rejected for extending a fraction of a point.
        let changedPixels = CGRect(x: rect.minX + CGFloat(left), y: rect.minY + CGFloat(top),
            width: CGFloat(right - left + 1), height: CGFloat(bottom - top + 1))
        onDifference?(changed, changedPixels, fieldPixels)
        // Downsampling can paint one antialiased image pixel beyond the AX
        // field footprint. Keep that allowance in image pixels, not points.
        let paintFootprint = fieldPixels.insetBy(dx: -1, dy: -1).intersection(rect)
        return paintFootprint.contains(changedPixels) && changed.width <= 4 && changed.height >= changed.width * 2
    }

    private func imageRect(for displayRect: CGRect, wholePixelsOnly: Bool = false) -> CGRect? {
        guard displayRect.origin.x.isFinite, displayRect.origin.y.isFinite,
              displayRect.width.isFinite, displayRect.height.isFinite, !displayRect.isEmpty else { return nil }
        let clipped = displayRect.intersection(displayBounds)
        guard !clipped.isEmpty, !clipped.isNull else { return nil }
        let scaled = CGRect(x: (clipped.minX - displayBounds.minX) * CGFloat(pixelWidth) / displayBounds.width,
            y: (clipped.minY - displayBounds.minY) * CGFloat(pixelHeight) / displayBounds.height,
            width: clipped.width * CGFloat(pixelWidth) / displayBounds.width,
            height: clipped.height * CGFloat(pixelHeight) / displayBounds.height)
        // Window-only proof must not import an adjacent surface through an
        // outward-rounded, partially covered pixel. Pointer/field footprints
        // still round outward to include their full rendered target/context.
        let rounded = wholePixelsOnly
            ? CGRect(x: ceil(scaled.minX), y: ceil(scaled.minY),
                     width: floor(scaled.maxX) - ceil(scaled.minX), height: floor(scaled.maxY) - ceil(scaled.minY))
            : scaled.integral
        guard rounded.width > 0, rounded.height > 0 else { return nil }
        return rounded
            .intersection(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    }

    private static func pixels(_ png: Data, in rect: CGRect) throws -> Data {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)?.cropping(to: rect) else {
            throw OSAtlasLlamaRuntimeError.invalidVisionInput
        }
        let width = Int(rect.width), height = Int(rect.height)
        var data = Data(count: width * height * 4)
        let rendered = data.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        guard rendered else { throw OSAtlasLlamaRuntimeError.invalidVisionInput }
        return data
    }

}

/// Runtime-neutral action vocabulary shared by the OS-Atlas visual fallback,
/// deterministic safety policy, approval fingerprinting, and input injector.
/// Keeping it outside any model adapter prevents a removed model backend from
/// silently owning the host's safety boundary.
indirect enum ComputerUsePredictedAction: Equatable {
    case click(x: Int, y: Int, button: UInt8, count: Int)
    case drag(fromX: Int, fromY: Int, toX: Int, toY: Int)
    case scroll(x: Int, y: Int, dx: Int, dy: Int)
    case key(usage: Int, modifiers: UInt16)
    case typeText(String)
    case requestApproval(message: String, action: ComputerUsePredictedAction)
    case wait
    case done
}

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

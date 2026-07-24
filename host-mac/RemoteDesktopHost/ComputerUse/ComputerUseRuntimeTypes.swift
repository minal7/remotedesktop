import CoreGraphics
import CoreImage
import Foundation

/// Opaque, task-scoped authority to resume the exact visual execution that
/// produced an approval request. The nonce prevents a delayed or duplicate
/// approval response from being applied to a later visual session.
struct ComputerUseVisualApprovalContinuation: Equatable, Sendable {
    let taskID: String
    let nonce: UUID
}

/// A screen image paired with the global-display coordinates used by the
/// intervention-safe input injector.
struct ComputerUseScreenObservation {
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

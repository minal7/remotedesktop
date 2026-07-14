import CoreGraphics
import CoreImage
import Foundation

/// A screen image paired with the global-display coordinates used by the
/// intervention-safe input injector.
struct ComputerUseScreenObservation {
    let image: CIImage
    let displayBounds: CGRect
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

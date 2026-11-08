import UIKit

/// Floating cursor drawn on a `CALayer`. In touch-cursor mode, finger
/// deltas nudge the cursor at a small gain — not 1:1 with the finger.
/// This matches the iPadOS trackpad-simulator pattern, which is the
/// right metaphor for manipulating a desktop on a tablet.
final class TouchCursorLayer: CALayer {
    private let dot = CALayer()
    private let gain: CGFloat = 1.2
    private var hasPosition = false

    override init() {
        super.init()
        isHidden = true
        dot.backgroundColor = UIColor.white.cgColor
        dot.borderColor = UIColor.black.withAlphaComponent(0.5).cgColor
        dot.borderWidth = 1
        dot.frame = CGRect(x: 0, y: 0, width: 14, height: 14)
        dot.cornerRadius = 7
        dot.shadowOpacity = 0.45
        dot.shadowRadius = 4
        dot.shadowOffset = .zero
        addSublayer(dot)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    /// Center of the cursor dot in this layer's coordinate space.
    /// `.zero` if the cursor hasn't been positioned yet.
    var cursorCenter: CGPoint {
        guard hasPosition else { return .zero }
        return dot.position
    }

    var positionedCenter: CGPoint? { hasPosition ? dot.position : nil }

    func show(at p: CGPoint, within rect: CGRect) {
        guard RemoteScreenGeometry.isFiniteRectangle(rect), p.x.isFinite, p.y.isFinite else { hide(); return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.position = clampedCenter(for: p, within: rect)
        isHidden = false
        hasPosition = true
        CATransaction.commit()
    }

    func move(by delta: CGPoint, within rect: CGRect) {
        guard RemoteScreenGeometry.isFiniteRectangle(rect), delta.x.isFinite, delta.y.isFinite else { return }
        if isHidden {
            show(at: CGPoint(x: rect.midX, y: rect.midY), within: rect)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let next = CGPoint(x: dot.position.x + delta.x * gain, y: dot.position.y + delta.y * gain)
        if next.x.isFinite, next.y.isFinite { dot.position = clampedCenter(for: next, within: rect) }
        CATransaction.commit()
    }

    func clamp(to rect: CGRect) {
        guard hasPosition, RemoteScreenGeometry.isFiniteRectangle(rect) else { hide(); return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.position = clampedCenter(for: cursorCenter, within: rect)
        CATransaction.commit()
    }

    func hide() {
        if !isHidden { isHidden = true }
    }

    private func clampedCenter(for center: CGPoint, within rect: CGRect) -> CGPoint {
        return CGPoint(
            x: max(rect.minX, min(rect.maxX.nextDown, center.x)),
            y: max(rect.minY, min(rect.maxY.nextDown, center.y)))
    }
}

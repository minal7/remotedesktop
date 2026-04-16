import SwiftUI
import UIKit
import LiveKitWebRTC

/// The capture surface for the remote session: renders incoming video
/// (placeholder for now) and routes every input channel back to the
/// session's transport.
///
/// Three input modes share this view:
///
/// 1. **Indirect pointer** (iPad trackpad / Magic Mouse / Pencil hover)
///    — hover gestures drive absolute pointer position; the iOS-native
///    pointer is hidden so the host's cursor is the only one visible.
/// 2. **Indirect scroll** — `UIPanGestureRecognizer` with
///    `allowedScrollTypesMask = [.discrete, .continuous]` and
///    `maximumNumberOfTouches = 0` captures wheel / trackpad scroll only.
/// 3. **Touch cursor** (no accessories) — finger deltas nudge a floating
///    cursor at 1.2× gain; tap = left click, long press = right click,
///    two-finger pan = scroll. This matches the iPadOS trackpad-simulator
///    pattern and is the right metaphor for desktop control on a tablet.
struct RemoteScreenView: UIViewRepresentable {
    @EnvironmentObject private var session: SessionModel
    @ObservedObject var accessories: AccessoryMonitor

    func makeUIView(context: Context) -> RemoteScreenUIView {
        let v = RemoteScreenUIView()
        v.bindSession(session)
        v.accessories = accessories
        return v
    }

    func updateUIView(_ uiView: RemoteScreenUIView, context: Context) {
        uiView.bindSession(session)
        uiView.accessories = accessories
        uiView.applyDisplay(session.display)
    }
}

final class RemoteScreenUIView: UIView, UIPointerInteractionDelegate, UIGestureRecognizerDelegate {
    weak var session: SessionModel?
    weak var accessories: AccessoryMonitor?

    private let videoView = RTCMTLVideoView(frame: .zero)
    private let cursorLayer = TouchCursorLayer()
    private var remoteDisplay: DisplayInfo?
    private weak var boundSession: SessionModel?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        videoView.videoContentMode = .scaleAspectFit
        videoView.backgroundColor = UIColor(white: 0.05, alpha: 1)
        addSubview(videoView)
        layer.addSublayer(cursorLayer)

        // Indirect pointer (trackpad / Magic Mouse / Pencil hover).
        addInteraction(UIPointerInteraction(delegate: self))
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))
        addGestureRecognizer(hover)

        // Indirect scroll only — excludes direct touches via
        // `maximumNumberOfTouches = 0`.
        let indirectScroll = UIPanGestureRecognizer(
            target: self, action: #selector(onIndirectScroll(_:)))
        indirectScroll.allowedScrollTypesMask = [.discrete, .continuous]
        indirectScroll.maximumNumberOfTouches = 0
        indirectScroll.delegate = self
        addGestureRecognizer(indirectScroll)

        // Two-finger touch scroll for touch-cursor mode.
        let touchScroll = UIPanGestureRecognizer(
            target: self, action: #selector(onTouchScroll(_:)))
        touchScroll.minimumNumberOfTouches = 2
        touchScroll.maximumNumberOfTouches = 2
        touchScroll.delegate = self
        addGestureRecognizer(touchScroll)

        // Long-press = right click in touch-cursor mode.
        let longPress = UILongPressGestureRecognizer(
            target: self, action: #selector(onLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        longPress.allowableMovement = 10
        longPress.delegate = self
        addGestureRecognizer(longPress)

        // Mouse buttons on indirect pointers (right-click, middle-click)
        // arrive as UIPress / scroll events on iPadOS 13.4+. We listen
        // for buttonMask via a dedicated recognizer.
        let buttonTracker = IndirectButtonTracker(target: self, action: #selector(onIndirectButtons(_:)))
        buttonTracker.delegate = self
        addGestureRecognizer(buttonTracker)

        isMultipleTouchEnabled = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        videoView.frame = bounds
        cursorLayer.frame = bounds
        cursorLayer.clamp(to: geometry.interactiveRect)
    }

    func applyDisplay(_ d: DisplayInfo?) {
        remoteDisplay = d
        cursorLayer.clamp(to: geometry.interactiveRect)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        rebindRendererIfNeeded()
    }

    func bindSession(_ session: SessionModel?) {
        self.session = session
        rebindRendererIfNeeded()
    }

    private func rebindRendererIfNeeded() {
        if let previous = boundSession, previous !== session {
            previous.detachVideoRenderer(videoView)
            boundSession = nil
        }

        guard window != nil, let session else { return }
        if boundSession !== session {
            session.attachVideoRenderer(videoView)
            boundSession = session
        }
    }

    // MARK: - Pointer style

    func pointerInteraction(_ interaction: UIPointerInteraction,
                            styleFor region: UIPointerRegion) -> UIPointerStyle? {
        // Hide the iOS-native pointer — the host's own cursor is the
        // source of truth.
        return .hidden()
    }

    // MARK: - Hover (indirect pointer position)

    private var lastPointerButtons: UInt8 = 0
    private var lastPointerLocation: CGPoint = .zero

    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            accessories?.noteIndirectPointer(active: true)
            cursorLayer.hide()
            let p = g.location(in: self)
            lastPointerLocation = p
            sendPointer(at: p, buttons: lastPointerButtons)
        case .ended, .cancelled, .failed:
            accessories?.noteIndirectPointer(active: false)
        default: break
        }
    }

    // MARK: - Indirect scroll (trackpad / wheel)

    @objc private func onIndirectScroll(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        if t == .zero && g.state == .changed { return }
        g.setTranslation(.zero, in: self)

        let phase: InputScrollPhase = {
            switch g.state {
            case .began: return .begin
            case .changed: return .changed
            case .ended, .cancelled: return .end
            default: return .changed
            }
        }()
        sendScroll(at: lastPointerLocation, dx: t.x, dy: t.y, phase: phase)
    }

    // MARK: - Indirect buttons

    @objc private func onIndirectButtons(_ g: IndirectButtonTracker) {
        // Button state changed on an indirect pointer device. Use the
        // tracker's captured location (the touch that caused the change)
        // and fall back to the last hover position if unset.
        lastPointerButtons = g.currentButtons
        let p = g.currentLocation == .zero ? lastPointerLocation : g.currentLocation
        sendPointer(at: p, buttons: lastPointerButtons)
    }

    // MARK: - Touch cursor mode

    private var activeTouch: UITouch?
    private var touchStart: CGPoint?
    private var touchStartedAt: CFTimeInterval = 0
    private var isDragging = false
    private var rightClickFired = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard accessories?.hasIndirectPointer != true,
              touches.count == 1,
              let t = touches.first else {
            super.touchesBegan(touches, with: event)
            return
        }
        activeTouch = t
        touchStart = t.location(in: self)
        touchStartedAt = CACurrentMediaTime()
        isDragging = TouchCursorPolicy.beginsDrag(tapCount: t.tapCount)
        rightClickFired = false
        let cursor = cursorLayer.cursorCenter == .zero
            ? CGPoint(x: geometry.interactiveRect.midX, y: geometry.interactiveRect.midY)
            : geometry.clampedLocalPoint(cursorLayer.cursorCenter)
        cursorLayer.show(at: cursor, within: geometry.interactiveRect)
        if isDragging {
            sendPointer(at: cursor, buttons: 0b001)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t), touchStart != nil else { return }
        let prev = t.previousLocation(in: self)
        let now = t.location(in: self)
        let delta = CGPoint(x: now.x - prev.x, y: now.y - prev.y)
        cursorLayer.move(by: delta, within: geometry.interactiveRect)
        let cursor = cursorLayer.cursorCenter
        sendPointer(at: cursor, buttons: isDragging ? 0b001 : 0)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        let duration = CACurrentMediaTime() - touchStartedAt
        let cursor = cursorLayer.cursorCenter
        for buttons in TouchCursorPolicy.endButtonSequence(
            duration: duration,
            isDragging: isDragging,
            rightClickFired: rightClickFired
        ) {
            sendPointer(at: cursor, buttons: buttons)
        }
        activeTouch = nil
        touchStart = nil
        isDragging = false
        rightClickFired = false
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isDragging {
            sendPointer(at: cursorLayer.cursorCenter, buttons: 0)
        }
        activeTouch = nil
        touchStart = nil
        isDragging = false
        rightClickFired = false
    }

    @objc private func onLongPress(_ g: UILongPressGestureRecognizer) {
        guard accessories?.hasIndirectPointer != true, g.state == .began, !isDragging else { return }
        rightClickFired = true
        let cursor = cursorLayer.cursorCenter
        sendPointer(at: cursor, buttons: 0b010)
        sendPointer(at: cursor, buttons: 0)
    }

    @objc private func onTouchScroll(_ g: UIPanGestureRecognizer) {
        guard accessories?.hasIndirectPointer != true else { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        let phase: InputScrollPhase = {
            switch g.state {
            case .began: return .begin
            case .changed: return .changed
            case .ended, .cancelled: return .end
            default: return .changed
            }
        }()
        sendScroll(at: cursorLayer.cursorCenter, dx: t.x, dy: t.y, phase: phase)
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Hover + scroll should not block each other.
        return true
    }

    // MARK: - Coordinate mapping

    private var lastSentPointer: (Int, Int, UInt8)?

    private func sendPointer(at p: CGPoint, buttons: UInt8) {
        let remote = geometry.localToRemote(p)
        let key = (remote.x, remote.y, buttons)
        if let last = lastSentPointer, last == key { return }   // dedup
        lastSentPointer = key
        session?.send(.pointer(x: remote.x, y: remote.y, buttons: buttons))
    }

    private func sendScroll(at p: CGPoint, dx: CGFloat, dy: CGFloat, phase: InputScrollPhase) {
        let ix = Int(dx.rounded()), iy = Int(dy.rounded())
        if ix == 0 && iy == 0 && phase == .changed { return }   // skip sub-pixel noise
        let remote = geometry.localToRemote(p)
        session?.send(.scroll(x: remote.x, y: remote.y,
                              dx: ix, dy: iy, phase: phase))
    }

    private var geometry: RemoteScreenGeometry {
        RemoteScreenGeometry(bounds: bounds, display: remoteDisplay)
    }
}

struct RemoteScreenGeometry {
    let bounds: CGRect
    let display: DisplayInfo?

    var interactiveRect: CGRect {
        guard let display, bounds.width > 0, bounds.height > 0,
              display.w > 0, display.h > 0 else {
            return bounds
        }

        let displayAspect = CGFloat(display.w) / CGFloat(display.h)
        let boundsAspect = bounds.width / bounds.height

        if displayAspect > boundsAspect {
            let height = bounds.width / displayAspect
            return CGRect(x: bounds.minX,
                          y: bounds.midY - height / 2,
                          width: bounds.width,
                          height: height)
        }

        let width = bounds.height * displayAspect
        return CGRect(x: bounds.midX - width / 2,
                      y: bounds.minY,
                      width: width,
                      height: bounds.height)
    }

    func clampedLocalPoint(_ point: CGPoint) -> CGPoint {
        let rect = interactiveRect
        return CGPoint(
            x: max(rect.minX, min(rect.maxX, point.x)),
            y: max(rect.minY, min(rect.maxY, point.y)))
    }

    func localToRemote(_ point: CGPoint) -> (x: Int, y: Int) {
        guard let display, display.w > 0, display.h > 0 else {
            return (Int(point.x.rounded()), Int(point.y.rounded()))
        }

        let rect = interactiveRect
        let clamped = clampedLocalPoint(point)
        let nx = rect.width > 0 ? (clamped.x - rect.minX) / rect.width : 0
        let ny = rect.height > 0 ? (clamped.y - rect.minY) / rect.height : 0
        let maxX = max(display.w - 1, 0)
        let maxY = max(display.h - 1, 0)
        return (
            x: Int((nx * CGFloat(maxX)).rounded()),
            y: Int((ny * CGFloat(maxY)).rounded())
        )
    }
}

enum TouchCursorPolicy {
    static func beginsDrag(tapCount: Int) -> Bool {
        tapCount >= 2
    }

    static func endButtonSequence(
        duration: CFTimeInterval,
        isDragging: Bool,
        rightClickFired: Bool
    ) -> [UInt8] {
        if rightClickFired {
            return []
        }
        if isDragging {
            return [0]
        }
        if duration < 0.25 {
            return [0b001, 0]
        }
        return []
    }
}

// MARK: - IndirectButtonTracker

/// Captures mouse-button state from indirect pointing devices (Magic
/// Mouse right/middle click, trackpad physical click). Two things kept
/// this honest:
///
/// 1. `allowedTouchTypes = [.indirectPointer]` so direct finger taps
///    and Pencil input don't get funneled here — those are handled by
///    the view's own touch handlers.
/// 2. The recognizer only advances its state (and therefore only
///    triggers its action) when the button bitmask *changes*. Without
///    that, every single move in a press reports the same buttons at
///    60+ Hz.
///
/// `currentLocation` is captured from the touch itself so the handler
/// doesn't have to rely on a cached hover position that may be stale.
private final class IndirectButtonTracker: UIGestureRecognizer {
    var currentButtons: UInt8 = 0
    var currentLocation: CGPoint = .zero

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        captureLocation(touches)
        if updateButtons(from: event) { state = .began }
        else { state = .failed }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        captureLocation(touches)
        if updateButtons(from: event) { state = .changed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        captureLocation(touches)
        _ = updateButtons(from: event)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }

    private func captureLocation(_ touches: Set<UITouch>) {
        guard let v = view, let t = touches.first else { return }
        currentLocation = t.location(in: v)
    }

    /// Update `currentButtons` from the event's buttonMask.
    /// Returns true iff it actually changed — callers gate state
    /// transitions on this to suppress redundant action fires.
    private func updateButtons(from event: UIEvent) -> Bool {
        let mask = event.buttonMask
        var out: UInt8 = 0
        if mask.contains(.primary)   { out |= 0b001 }
        if mask.contains(.secondary) { out |= 0b010 }
        if mask.rawValue & (1 << 2) != 0 { out |= 0b100 } // middle, best-effort
        guard out != currentButtons else { return false }
        currentButtons = out
        return true
    }
}

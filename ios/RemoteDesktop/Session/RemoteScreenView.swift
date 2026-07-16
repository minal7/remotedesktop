import SwiftUI
import UIKit
import LiveKitWebRTC
import Metal

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
    @ObservedObject var zoom: RemoteScreenZoomController

    func makeUIView(context: Context) -> RemoteScreenUIView {
        let v = RemoteScreenUIView()
        v.bindSession(session)
        v.bindZoomController(zoom)
        v.accessories = accessories
        return v
    }

    func updateUIView(_ uiView: RemoteScreenUIView, context: Context) {
        uiView.bindSession(session)
        uiView.bindZoomController(zoom)
        uiView.accessories = accessories
        uiView.applyDisplay(session.display)
    }
}

@MainActor
final class RemoteScreenZoomController: ObservableObject {
    enum Command {
        case increase
        case decrease
        case reset
    }

    @Published private(set) var scale: CGFloat = 1
    @Published var moveScreenEnabled = false {
        didSet {
            guard oldValue != moveScreenEnabled else { return }
            interactionModeHandler?(moveScreenEnabled)
        }
    }
    fileprivate var commandHandler: ((Command) -> Void)?
    fileprivate var interactionModeHandler: ((Bool) -> Void)?

    var isZoomed: Bool { scale > 1.01 }

    func zoomIn() { commandHandler?(.increase) }
    func zoomOut() { commandHandler?(.decrease) }
    func reset() { commandHandler?(.reset) }

    fileprivate func report(scale: CGFloat) {
        guard abs(self.scale - scale) > 0.005 else { return }
        self.scale = scale
    }
}

struct RemoteScreenZoomControls: View {
    @ObservedObject var zoom: RemoteScreenZoomController

    var body: some View {
        HStack(spacing: 2) {
            Button(action: zoom.zoomOut) {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 44, height: 44)
            }
            .disabled(!zoom.isZoomed)
            .accessibilityLabel("Zoom out")

            Button(action: zoom.reset) {
                Text(zoom.isZoomed ? "\(Int((zoom.scale * 100).rounded()))%" : "Fit")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!zoom.isZoomed)
            .accessibilityLabel("Fit screen")
            .accessibilityValue("\(Int((zoom.scale * 100).rounded())) percent")

            Button(action: zoom.zoomIn) {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 44, height: 44)
            }
            .disabled(zoom.scale >= RemoteZoomPolicy.maximumScale)
            .accessibilityLabel("Zoom in")

            Divider()
                .frame(height: 24)
                .padding(.horizontal, 3)

            Toggle(isOn: $zoom.moveScreenEnabled) {
                Label("Zoom & move", systemImage: "hand.draw")
                .font(.caption.weight(.semibold))
                .frame(minHeight: 44)
                .padding(.horizontal, 6)
            }
            .toggleStyle(.button)
            .foregroundStyle(zoom.moveScreenEnabled ? Color.white : Color.primary)
            .background(
                zoom.moveScreenEnabled ? Color.accentColor : Color.clear,
                in: Capsule())
            .accessibilityIdentifier("moveScreenToggle")
            .accessibilityLabel("Zoom and move screen")
            .accessibilityValue(zoom.moveScreenEnabled ? "On" : "Off")
            .accessibilityHint(zoom.moveScreenEnabled
                ? "Touches zoom and move the view without controlling the remote computer"
                : "Dragging controls the remote computer and two fingers scroll it")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(Color.primary.opacity(0.1)) }
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        .accessibilityIdentifier("remoteScreenZoomControls")
    }
}

final class RemoteScreenUIView: UIView, UIPointerInteractionDelegate, UIGestureRecognizerDelegate {
    weak var session: SessionModel?
    weak var accessories: AccessoryMonitor?

    private let contentView = UIView(frame: .zero)
    private let videoView = MetalSafeRTCVideoView(frame: .zero)
    private let cursorLayer = TouchCursorLayer()
    private var remoteDisplay: DisplayInfo?
    private weak var boundSession: SessionModel?
    private weak var zoomController: RemoteScreenZoomController?
    private let touchScroll = UIPanGestureRecognizer()
    private let indirectScroll = UIPanGestureRecognizer()
    private let hover = UIHoverGestureRecognizer()
    private let zoomPan = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    private let longPress = UILongPressGestureRecognizer()
    private var zoomScale: CGFloat = 1
    private var zoomOffset: CGPoint = .zero
    private var pinchStartScale: CGFloat = 1
    private var pinchAnchor: CGPoint = .zero
    private var panStartOffset: CGPoint = .zero

    var interactionState: RemoteScreenInteractionState {
        RemoteScreenInteractionState(
            remoteScrollEnabled: touchScroll.isEnabled,
            remoteLongPressEnabled: longPress.isEnabled,
            remoteIndirectInputEnabled: hover.isEnabled && indirectScroll.isEnabled,
            viewportPinchEnabled: pinch.isEnabled,
            viewportPanEnabled: zoomPan.isEnabled)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true

        videoView.videoContentMode = .scaleAspectFit
        videoView.backgroundColor = UIColor(white: 0.05, alpha: 1)
        contentView.addSubview(videoView)
        contentView.layer.addSublayer(cursorLayer)
        addSubview(contentView)

        // Indirect pointer (trackpad / Magic Mouse / Pencil hover).
        addInteraction(UIPointerInteraction(delegate: self))
        hover.addTarget(self, action: #selector(onHover(_:)))
        addGestureRecognizer(hover)

        // Indirect scroll only — excludes direct touches via
        // `maximumNumberOfTouches = 0`.
        indirectScroll.addTarget(self, action: #selector(onIndirectScroll(_:)))
        indirectScroll.allowedScrollTypesMask = [.discrete, .continuous]
        indirectScroll.maximumNumberOfTouches = 0
        indirectScroll.delegate = self
        addGestureRecognizer(indirectScroll)

        // Two-finger touch scroll for touch-cursor mode.
        touchScroll.addTarget(self, action: #selector(onTouchScroll(_:)))
        touchScroll.minimumNumberOfTouches = 2
        touchScroll.maximumNumberOfTouches = 2
        touchScroll.delegate = self
        addGestureRecognizer(touchScroll)

        // Move Screen mode owns pinch and viewport panning. Control mode owns
        // direct cursor input and two-finger remote scrolling.
        pinch.addTarget(self, action: #selector(onPinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        zoomPan.addTarget(self, action: #selector(onZoomPan(_:)))
        zoomPan.minimumNumberOfTouches = 1
        zoomPan.maximumNumberOfTouches = 2
        zoomPan.delegate = self
        addGestureRecognizer(zoomPan)

        // Long-press = right click in touch-cursor mode.
        longPress.addTarget(self, action: #selector(onLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        longPress.allowableMovement = 10
        longPress.delegate = self
        addGestureRecognizer(longPress)

        isMultipleTouchEnabled = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.bounds = CGRect(origin: .zero, size: bounds.size)
        videoView.frame = contentView.bounds
        cursorLayer.frame = contentView.bounds
        clampZoomOffset()
        applyZoomTransform()
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

    func bindZoomController(_ controller: RemoteScreenZoomController) {
        guard zoomController !== controller else { return }
        zoomController?.commandHandler = nil
        zoomController?.interactionModeHandler = nil
        zoomController = controller
        controller.commandHandler = { [weak self] command in
            self?.handleZoomCommand(command)
        }
        controller.interactionModeHandler = { [weak self] enabled in
            self?.applyInteractionMode(moveScreenEnabled: enabled)
        }
        controller.report(scale: zoomScale)
        applyInteractionMode(moveScreenEnabled: controller.moveScreenEnabled)
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
    private var isTrackingIndirectClick = false

    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            accessories?.noteIndirectPointer(active: true)
            cursorLayer.hide()
            let p = g.location(in: self)
            let point = contentPoint(from: p)
            lastPointerLocation = point
            guard RemoteTouchRoutingPolicy.routesTouchesToComputer(
                moveScreenEnabled: zoomController?.moveScreenEnabled ?? false) else {
                return
            }
            sendPointer(at: point, buttons: lastPointerButtons)
        case .ended, .cancelled, .failed:
            accessories?.noteIndirectPointer(active: false)
        default: break
        }
    }

    // MARK: - Indirect scroll (trackpad / wheel)

    @objc private func onIndirectScroll(_ g: UIPanGestureRecognizer) {
        guard RemoteTouchRoutingPolicy.routesTouchesToComputer(
            moveScreenEnabled: zoomController?.moveScreenEnabled ?? false) else {
            g.setTranslation(.zero, in: self)
            return
        }
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

    // MARK: - Touch cursor mode

    private var activeTouch: UITouch?
    private var touchStart: CGPoint?
    private var touchStartedAt: CFTimeInterval = 0
    private var isDragging = false
    private var rightClickFired = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if handleIndirectPointerTouches(touches, with: event, phase: .began) {
            return
        }

        guard accessories?.hasIndirectPointer != true,
              RemoteTouchRoutingPolicy.routesTouchesToComputer(
                moveScreenEnabled: zoomController?.moveScreenEnabled ?? false),
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
        if handleIndirectPointerTouches(touches, with: event, phase: .moved) {
            return
        }

        guard let t = activeTouch, touches.contains(t), touchStart != nil else { return }
        let prev = t.previousLocation(in: self)
        let now = t.location(in: self)
        let delta = CGPoint(x: now.x - prev.x, y: now.y - prev.y)
        cursorLayer.move(
            by: CGPoint(x: delta.x / zoomScale, y: delta.y / zoomScale),
            within: geometry.interactiveRect)
        let cursor = cursorLayer.cursorCenter
        sendPointer(at: cursor, buttons: isDragging ? 0b001 : 0)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if handleIndirectPointerTouches(touches, with: event, phase: .ended) {
            return
        }

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
        if handleIndirectPointerTouches(touches, with: event, phase: .cancelled) {
            return
        }

        if isDragging {
            sendPointer(at: cursorLayer.cursorCenter, buttons: 0)
        }
        activeTouch = nil
        touchStart = nil
        isDragging = false
        rightClickFired = false
    }

    // MARK: - Indirect buttons

    private func handleIndirectPointerTouches(
        _ touches: Set<UITouch>,
        with event: UIEvent?,
        phase: IndirectPointerClickPolicy.Phase
    ) -> Bool {
        guard let touch = touches.first(where: { $0.type == .indirectPointer }) else {
            return false
        }

        accessories?.noteIndirectPointer(active: true)
        cursorLayer.hide()

        let location = contentPoint(from: touch.location(in: self))
        lastPointerLocation = location

        guard RemoteTouchRoutingPolicy.routesTouchesToComputer(
            moveScreenEnabled: zoomController?.moveScreenEnabled ?? false) else {
            isTrackingIndirectClick = false
            lastPointerButtons = 0
            return true
        }

        let buttons = IndirectPointerClickPolicy.buttons(
            for: event?.buttonMask ?? UIEvent.ButtonMask(),
            phase: phase,
            previousButtons: lastPointerButtons
        )

        switch phase {
        case .began:
            isTrackingIndirectClick = true
            lastPointerButtons = buttons
            sendPointer(at: location, buttons: buttons)
        case .moved:
            lastPointerButtons = buttons
            sendPointer(at: location, buttons: buttons)
        case .ended, .cancelled:
            if isTrackingIndirectClick || lastPointerButtons != 0 {
                sendPointer(at: location, buttons: 0)
            }
            isTrackingIndirectClick = false
            lastPointerButtons = 0
        }

        return true
    }

    @objc private func onLongPress(_ g: UILongPressGestureRecognizer) {
        guard accessories?.hasIndirectPointer != true,
              RemoteTouchRoutingPolicy.routesTouchesToComputer(
                moveScreenEnabled: zoomController?.moveScreenEnabled ?? false),
              g.state == .began,
              !isDragging else { return }
        rightClickFired = true
        let cursor = cursorLayer.cursorCenter
        sendPointer(at: cursor, buttons: 0b010)
        sendPointer(at: cursor, buttons: 0)
    }

    @objc private func onTouchScroll(_ g: UIPanGestureRecognizer) {
        guard accessories?.hasIndirectPointer != true,
              RemoteTouchRoutingPolicy.routesTouchesToComputer(
                moveScreenEnabled: zoomController?.moveScreenEnabled ?? false) else { return }
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

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === zoomPan {
            return RemoteTouchRoutingPolicy.movesViewport(
                moveScreenEnabled: zoomController?.moveScreenEnabled ?? false,
                scale: zoomScale)
        }
        if gestureRecognizer === touchScroll {
            return accessories?.hasIndirectPointer != true
                && RemoteTouchRoutingPolicy.routesTouchesToComputer(
                    moveScreenEnabled: zoomController?.moveScreenEnabled ?? false)
        }
        if gestureRecognizer === indirectScroll || gestureRecognizer === hover {
            return RemoteTouchRoutingPolicy.routesTouchesToComputer(
                moveScreenEnabled: zoomController?.moveScreenEnabled ?? false)
        }
        if gestureRecognizer === pinch {
            return RemoteTouchRoutingPolicy.allowsViewportZoom(
                moveScreenEnabled: zoomController?.moveScreenEnabled ?? false)
        }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Viewport navigation and remote scrolling can never recognize the
        // same drag.
        if (g === zoomPan && other === touchScroll)
            || (g === touchScroll && other === zoomPan) {
            return false
        }
        // Pinch can still adjust scale while the selected pan gesture tracks.
        return true
    }

    // MARK: - Zoom

    @objc private func onPinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            cancelActiveTouch()
            pinchStartScale = zoomScale
            pinchAnchor = contentPoint(from: gesture.location(in: self))
        case .changed:
            let newScale = RemoteZoomPolicy.clampedScale(pinchStartScale * gesture.scale)
            let location = gesture.location(in: self)
            let baseCenter = CGPoint(x: bounds.midX, y: bounds.midY)
            zoomScale = newScale
            zoomOffset = CGPoint(
                x: location.x - baseCenter.x - (pinchAnchor.x - baseCenter.x) * newScale,
                y: location.y - baseCenter.y - (pinchAnchor.y - baseCenter.y) * newScale)
            clampZoomOffset()
            applyZoomTransform()
        case .ended, .cancelled, .failed:
            if zoomScale < 1.04 { resetZoom(animated: true) }
        default:
            break
        }
    }

    @objc private func onZoomPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            cancelActiveTouch()
            panStartOffset = zoomOffset
        case .changed:
            let translation = gesture.translation(in: self)
            zoomOffset = CGPoint(
                x: panStartOffset.x + translation.x,
                y: panStartOffset.y + translation.y)
            clampZoomOffset()
            applyZoomTransform()
        default:
            break
        }
    }

    private func handleZoomCommand(_ command: RemoteScreenZoomController.Command) {
        switch command {
        case .increase:
            setZoom(RemoteZoomPolicy.nextScale(after: zoomScale), animated: true)
        case .decrease:
            setZoom(RemoteZoomPolicy.previousScale(before: zoomScale), animated: true)
        case .reset:
            resetZoom(animated: true)
        }
    }

    private func applyInteractionMode(moveScreenEnabled: Bool) {
        if moveScreenEnabled {
            cancelActiveTouch()
            if isTrackingIndirectClick || lastPointerButtons != 0 {
                sendPointer(at: lastPointerLocation, buttons: 0)
            }
            isTrackingIndirectClick = false
            lastPointerButtons = 0
            if touchScroll.state == .began || touchScroll.state == .changed {
                sendScroll(
                    at: cursorLayer.cursorCenter,
                    dx: 0,
                    dy: 0,
                    phase: .end)
            }
        }
        touchScroll.isEnabled = !moveScreenEnabled
        longPress.isEnabled = !moveScreenEnabled
        hover.isEnabled = !moveScreenEnabled
        indirectScroll.isEnabled = !moveScreenEnabled
        pinch.isEnabled = moveScreenEnabled
        zoomPan.isEnabled = moveScreenEnabled
    }

    private func setZoom(_ requestedScale: CGFloat, animated: Bool) {
        zoomScale = RemoteZoomPolicy.clampedScale(requestedScale)
        if !RemoteZoomPolicy.isZoomed(zoomScale) { zoomOffset = .zero }
        clampZoomOffset()
        let changes = { self.applyZoomTransform() }
        if animated {
            UIView.animate(
                withDuration: 0.22,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseInOut],
                animations: changes)
        } else {
            changes()
        }
    }

    private func resetZoom(animated: Bool) {
        zoomScale = 1
        zoomOffset = .zero
        setZoom(1, animated: animated)
    }

    private func clampZoomOffset() {
        zoomOffset = RemoteZoomPolicy.clampedOffset(
            zoomOffset,
            scale: zoomScale,
            viewport: bounds.size)
    }

    private func applyZoomTransform() {
        contentView.transform = CGAffineTransform(scaleX: zoomScale, y: zoomScale)
        contentView.center = CGPoint(
            x: bounds.midX + zoomOffset.x,
            y: bounds.midY + zoomOffset.y)
        zoomController?.report(scale: zoomScale)
    }

    private func contentPoint(from viewPoint: CGPoint) -> CGPoint {
        contentView.convert(viewPoint, from: self)
    }

    private func cancelActiveTouch() {
        if isDragging {
            sendPointer(at: cursorLayer.cursorCenter, buttons: 0)
        }
        activeTouch = nil
        touchStart = nil
        isDragging = false
        rightClickFired = false
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

/// LiveKit's `RTCMTLVideoView` treats the pixel dimensions delivered to
/// `RTCVideoRenderer.setSize(_:)` as points, then multiplies them by the iOS
/// screen scale when sizing its `MTKView` drawable. A 3456-pixel Retina frame
/// therefore requests a 10,368-pixel texture on an @3x iPhone, exceeding the
/// 8192-pixel Metal limit exposed by Simulator.
///
/// Keep decoding the negotiated frame at full quality, but bound only the
/// renderer's drawable request. The aspect ratio is retained, so LiveKit's
/// aspect-fit layout and the separately signaled remote input geometry remain
/// unchanged.
private final class MetalSafeRTCVideoView: RTCMTLVideoView {
    /// WebRTC invokes `setSize(_:)` on its renderer queue, so that callback
    /// must not consult `UIView.window`, `UIWindow.screen`, or trait state.
    /// Capture the immutable sizing inputs while UIKit constructs the view on
    /// the main thread and use only those values from the renderer callback.
    private let rendererDisplayScale: CGFloat
    private let rendererMaximumTextureDimension: Int

    override init(frame: CGRect) {
        rendererDisplayScale = UIScreen.main.scale
        rendererMaximumTextureDimension = MetalVideoRenderSizing
            .maximumTextureDimension2D(for: MTLCreateSystemDefaultDevice())
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MetalSafeRTCVideoView is created programmatically")
    }

    override func setSize(_ size: CGSize) {
        super.setSize(MetalVideoRenderSizing.rendererFrameSize(
            size,
            displayScale: rendererDisplayScale,
            maximumTextureDimension: rendererMaximumTextureDimension))
    }
}

enum MetalVideoRenderSizing {
    /// Metal does not expose a public `maxTextureDimension2D` property. The
    /// limit is instead specified by GPU family. Apple3 and later permit a
    /// 16K 2D texture; the portable fallback is 8K. Simulator needs the 8K
    /// ceiling explicitly because its MTLSimDevice reports that validation
    /// limit even when the host Mac belongs to a newer family.
    static func maximumTextureDimension2D(for device: MTLDevice?) -> Int {
#if targetEnvironment(simulator)
        _ = device
        return 8_192
#else
        guard let device else { return 8_192 }
        return device.supportsFamily(.apple3) ? 16_384 : 8_192
#endif
    }

    static func rendererFrameSize(
        _ frameSize: CGSize,
        displayScale: CGFloat,
        maximumTextureDimension: Int
    ) -> CGSize {
        guard frameSize.width.isFinite,
              frameSize.height.isFinite,
              frameSize.width > 0,
              frameSize.height > 0 else {
            return frameSize
        }

        let safeDisplayScale = displayScale.isFinite && displayScale > 0
            ? displayScale
            : 1
        let maximumPointDimension = floor(
            CGFloat(max(1, maximumTextureDimension)) / safeDisplayScale)
        let downscale = min(
            1,
            maximumPointDimension / frameSize.width,
            maximumPointDimension / frameSize.height)

        guard downscale < 1 else { return frameSize }
        return CGSize(
            width: max(1, floor(frameSize.width * downscale)),
            height: max(1, floor(frameSize.height * downscale)))
    }
}

enum RemoteZoomPolicy {
    static let minimumScale: CGFloat = 1
    static let maximumScale: CGFloat = 4
    static let steps: [CGFloat] = [1, 1.5, 2, 3, 4]

    static func isZoomed(_ scale: CGFloat) -> Bool { scale > 1.01 }

    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(maximumScale, max(minimumScale, scale))
    }

    static func nextScale(after scale: CGFloat) -> CGFloat {
        steps.first(where: { $0 > scale + 0.01 }) ?? maximumScale
    }

    static func previousScale(before scale: CGFloat) -> CGFloat {
        steps.last(where: { $0 < scale - 0.01 }) ?? minimumScale
    }

    static func clampedOffset(_ offset: CGPoint, scale: CGFloat, viewport: CGSize) -> CGPoint {
        guard isZoomed(scale), viewport.width > 0, viewport.height > 0 else { return .zero }
        let maxX = viewport.width * (scale - 1) / 2
        let maxY = viewport.height * (scale - 1) / 2
        return CGPoint(
            x: min(max(offset.x, -maxX), maxX),
            y: min(max(offset.y, -maxY), maxY))
    }
}

enum RemoteTouchRoutingPolicy {
    static func routesTouchesToComputer(moveScreenEnabled: Bool) -> Bool {
        !moveScreenEnabled
    }

    static func allowsViewportZoom(moveScreenEnabled: Bool) -> Bool {
        moveScreenEnabled
    }

    static func movesViewport(moveScreenEnabled: Bool, scale: CGFloat) -> Bool {
        moveScreenEnabled && RemoteZoomPolicy.isZoomed(scale)
    }
}

struct RemoteScreenInteractionState: Equatable {
    let remoteScrollEnabled: Bool
    let remoteLongPressEnabled: Bool
    let remoteIndirectInputEnabled: Bool
    let viewportPinchEnabled: Bool
    let viewportPanEnabled: Bool
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

enum IndirectPointerClickPolicy {
    enum Phase {
        case began
        case moved
        case ended
        case cancelled
    }

    static func buttons(from mask: UIEvent.ButtonMask) -> UInt8 {
        var out: UInt8 = 0
        if mask.contains(.primary)   { out |= 0b001 }
        if mask.contains(.secondary) { out |= 0b010 }
        if mask.rawValue & (1 << 2) != 0 { out |= 0b100 } // middle, best-effort
        return out
    }

    static func buttons(
        for mask: UIEvent.ButtonMask,
        phase: Phase,
        previousButtons: UInt8
    ) -> UInt8 {
        let mapped = buttons(from: mask)

        switch phase {
        case .began:
            return mapped == 0 ? 0b001 : mapped
        case .moved:
            return mapped == 0 ? previousButtons : mapped
        case .ended, .cancelled:
            return 0
        }
    }
}

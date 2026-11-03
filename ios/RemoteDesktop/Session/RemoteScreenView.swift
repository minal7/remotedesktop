import SwiftUI
import UIKit
import LiveKitWebRTC

/// The capture surface for the remote session: renders incoming video
/// and routes every input channel back to the
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
    #if DEBUG
    var onLatencyGesture: (() -> Void)? = nil
    #endif

    func makeUIView(context: Context) -> RemoteScreenUIView {
        let v = RemoteScreenUIView()
        v.bindSession(session)
        v.bindZoomController(zoom)
        v.accessories = accessories
        #if DEBUG
        v.onLatencyGesture = onLatencyGesture
        #endif
        return v
    }

    func updateUIView(_ uiView: RemoteScreenUIView, context: Context) {
        uiView.bindSession(session)
        uiView.bindZoomController(zoom)
        uiView.accessories = accessories
        #if DEBUG
        uiView.onLatencyGesture = onLatencyGesture
        #endif
        uiView.applyDisplay(session.display)
    }

    static func dismantleUIView(_ uiView: RemoteScreenUIView, coordinator: ()) {
        uiView.stopCapture()
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
    @Published private(set) var interactionRevision = 0
    @Published var moveScreenEnabled = false {
        didSet {
            guard oldValue != moveScreenEnabled else { return }
            interactionModeHandler?(moveScreenEnabled)
        }
    }
    fileprivate var commandHandler: ((Command) -> Void)?
    fileprivate var interactionModeHandler: ((Bool) -> Void)?
    fileprivate weak var captureView: RemoteScreenUIView?

    var isZoomed: Bool { scale > 1.01 }

    func zoomIn() { commandHandler?(.increase) }
    func zoomOut() { commandHandler?(.decrease) }
    func reset() { commandHandler?(.reset) }

    fileprivate func notePinchInteraction() { interactionRevision &+= 1 }

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
    #if DEBUG
    var onLatencyGesture: (() -> Void)?
    @objc private func latencyTapped(_ gesture: UITapGestureRecognizer) {
        if gesture.state == .recognized { onLatencyGesture?() }
    }
    #endif
    private(set) weak var session: SessionModel?
    weak var accessories: AccessoryMonitor?

    private let contentView = UIView(frame: .zero)
    private let videoView = RemoteVideoSurfaceView(frame: .zero)
    private let cursorLayer = TouchCursorLayer()
    private var remoteDisplay: DisplayInfo?
    private let rendererBinding = RemoteVideoRendererBinding()
    private var visibilityObserver: UUID?
    private var sessionBindingRequest = UUID()
    private var visibilityOwner: UUID?
    private weak var inputOwnershipSession: SessionModel?
    private var isReconcilingVisibility = false
    private var visibilityReconciliationPending = false
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
    private var inputGeneration: UUID?
    private var inputSource: RemoteInputSourceLease?
    private var detached = false
    private var stopped = false
    private var inputAvailable = false
    private var scrollGenerations: [ObjectIdentifier: UUID] = [:]
    private var inputRouting = RemoteScreenInputRouting()

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
        #if DEBUG
        let latencyTap = UITapGestureRecognizer(target: self, action: #selector(latencyTapped(_:)))
        latencyTap.numberOfTouchesRequired = 3
        latencyTap.numberOfTapsRequired = 3
        latencyTap.cancelsTouchesInView = false
        latencyTap.delegate = self
        addGestureRecognizer(latencyTap)
        #endif
        rendererBinding.attach(videoView)
        videoView.isHidden = true
        backgroundColor = .black
        clipsToBounds = true

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
        applyVideoSurfaceLayout()
        cursorLayer.frame = contentView.bounds
        clampZoomOffset()
        applyZoomTransform()
        cursorLayer.clamp(to: visibleContentRect)
    }

    func applyDisplay(_ d: DisplayInfo?) {
        let changed = remoteDisplay != d
        if changed { retireInputSource() }
        remoteDisplay = d
        applyVideoSurfaceLayout()
        setNeedsLayout()
        cursorLayer.clamp(to: visibleContentRect)
        if changed { synchronizeInputAvailability(allowSourceBinding: true) }
    }

    private func applyVideoSurfaceLayout() {
        videoView.frame = contentView.bounds
        videoView.setNeedsLayout()
        videoView.layoutIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        detached = window == nil
        if detached { retireInputSource() }
        synchronizeInputAvailability(allowSourceBinding: !detached)
        rebindRendererIfNeeded()
    }

    func bindSession(_ session: SessionModel?) {
        guard !stopped else { return }
        let request = UUID()
        sessionBindingRequest = request
        if self.session !== session {
            if let visibilityObserver { self.session?.removeRemoteScreenVisibilityObserver(visibilityObserver) }
            visibilityObserver = nil
            visibilityOwner = nil
            retireInputSource()
            guard !stopped, sessionBindingRequest == request else { return }
            self.session = session
            inputOwnershipSession?.releaseRemoteScreenInput(owner: self)
            inputOwnershipSession = session
            session?.claimRemoteScreenInput(owner: self)
        }
        if visibilityOwner == nil, let session = self.session {
            let owner = UUID()
            visibilityOwner = owner
            let observer = session.observeRemoteScreenVisibility(owner: self) { [weak self, weak session] in
                guard let self, let session, self.session === session,
                      self.visibilityOwner == owner, !self.stopped else { return }
                self.rebindRendererIfNeeded()
            }
            if self.session === session && visibilityOwner == owner && !stopped { visibilityObserver = observer }
            else { session.removeRemoteScreenVisibilityObserver(observer) }
        }
        synchronizeInputAvailability(allowSourceBinding: true)
        rebindRendererIfNeeded()
    }

    @discardableResult
    private func synchronizeInputAvailability(allowSourceBinding: Bool = false) -> Bool {
        let generation = session?.remoteInputGeneration
        if generation != inputGeneration
            || inputSource.map({ session?.isRemoteInputSourceCurrent($0) != true }) == true {
            retireInputSource()
        }
        // Event callbacks may discard old state, but only an explicit UI
        // binding/window attachment can acquire the next registration.
        let ownsScreenInput = session?.ownsRemoteScreenInput(owner: self) == true
        if allowSourceBinding, ownsScreenInput, !stopped, !detached, inputSource == nil,
           let session, session.hasInteractiveRemoteScreen, let generation {
            inputSource = session.beginRemoteInputSource(.pointer, expectedInputGeneration: generation)
        }
        let available = ownsScreenInput && !stopped && !detached && inputSource.map {
            session?.isRemoteInputSourceCurrent($0) == true
        } == true
        if generation != inputGeneration || available != inputAvailable {
            inputGeneration = generation
            inputAvailable = available
            activeTouch = nil; touchStart = nil; isDragging = false; rightClickFired = false
            isTrackingIndirectClick = false; lastPointerButtons = 0; lastPointerLocation = nil
            inputRouting = RemoteScreenInputRouting()
            scrollGenerations.removeAll()
            cursorLayer.hide()
            // Reset recognizers even if a complete recovery occurred between
            // SwiftUI updates. Cancel callbacks carry no current scroll lease.
            for gesture: UIGestureRecognizer in [touchScroll, indirectScroll, hover, longPress] { gesture.isEnabled = false }
            applyInteractionMode(moveScreenEnabled: zoomController?.moveScreenEnabled ?? false)
        }
        return available
    }

    private func retireInputSource() {
        let source = inputSource
        inputSource = nil
        inputRouting = RemoteScreenInputRouting()
        activeTouch = nil; touchStart = nil; isDragging = false; rightClickFired = false
        isTrackingIndirectClick = false; lastPointerButtons = 0; lastPointerLocation = nil
        scrollGenerations.removeAll()
        if let source { session?.endRemoteInputSource(source) }
    }

    func stopCapture() {
        stopped = true
        sessionBindingRequest = UUID()
        visibilityOwner = nil
        if let visibilityObserver { session?.removeRemoteScreenVisibilityObserver(visibilityObserver) }
        visibilityObserver = nil
        retireInputSource()
        inputOwnershipSession?.releaseRemoteScreenInput(owner: self)
        inputOwnershipSession = nil
        session = nil
        synchronizeInputAvailability()
        rebindRendererIfNeeded()
        if zoomController?.captureView === self {
            zoomController?.commandHandler = nil
            zoomController?.interactionModeHandler = nil
            zoomController?.captureView = nil
        }
        zoomController = nil
        accessories = nil
    }

    func bindZoomController(_ controller: RemoteScreenZoomController) {
        guard !stopped, zoomController !== controller else { return }
        if zoomController?.captureView === self {
            zoomController?.commandHandler = nil
            zoomController?.interactionModeHandler = nil
            zoomController?.captureView = nil
        }
        zoomController = controller
        controller.captureView = self
        controller.commandHandler = { [weak self] command in
            guard let self, self.zoomController?.captureView === self, !self.stopped else { return }
            self.handleZoomCommand(command)
        }
        controller.interactionModeHandler = { [weak self] enabled in
            guard let self, self.zoomController?.captureView === self, !self.stopped else { return }
            self.applyInteractionMode(moveScreenEnabled: enabled)
        }
        controller.report(scale: zoomScale)
        applyInteractionMode(moveScreenEnabled: controller.moveScreenEnabled)
    }

    private func rebindRendererIfNeeded() {
        visibilityReconciliationPending = true
        guard !isReconcilingVisibility else {
            let visible = !stopped && window != nil && session?.mayRevealRemoteScreenPixels == true
            videoView.isHidden = !visible
            if !visible { cursorLayer.hide() }
            // Publish the newest desired target to the binding while its old
            // detach is still joined; don't briefly attach an obsolete owner.
            rendererBinding.bind(visible ? session : nil)
            return
        }
        isReconcilingVisibility = true
        defer { isReconcilingVisibility = false }
        while visibilityReconciliationPending {
            visibilityReconciliationPending = false
            let visible = !stopped && window != nil && session?.mayRevealRemoteScreenPixels == true
            videoView.isHidden = !visible
            if !visible { cursorLayer.hide() }
            // The binding joins the old exact detach before installing the
            // latest target. Reveal receives a new native sink/subscription;
            // a hidden RTC view's cached frame is never reused for readiness.
            rendererBinding.bind(visible ? session : nil)
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
    // Retain the observed view point; project it through the current zoom
    // when scrolling instead of reusing an old content-space coordinate.
    private var lastPointerLocation: CGPoint?
    private var lastPointerContentPoint: CGPoint? { lastPointerLocation.map { contentPoint(from: $0) } }
    private var isTrackingIndirectClick = false

    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        guard synchronizeInputAvailability() else { return }
        switch g.state {
        case .began, .changed:
            activateIndirectPointer()
            let p = g.location(in: self)
            let point = contentPoint(from: p)
            lastPointerLocation = p
            guard RemoteTouchRoutingPolicy.routesTouchesToComputer(
                moveScreenEnabled: zoomController?.moveScreenEnabled ?? false) else {
                return
            }
            sendPointer(at: point, buttons: lastPointerButtons, allowsNewButtons: false)
        case .ended, .cancelled, .failed:
            accessories?.noteIndirectPointer(active: false)
        default: break
        }
    }

    // MARK: - Indirect scroll (trackpad / wheel)

    @objc private func onIndirectScroll(_ g: UIPanGestureRecognizer) {
        guard acceptsScrollEvent(g) else { return }
        guard RemoteTouchRoutingPolicy.routesTouchesToComputer(
            moveScreenEnabled: zoomController?.moveScreenEnabled ?? false) else {
            g.setTranslation(.zero, in: self)
            return
        }
        if g.state == .began { activateIndirectPointer() }
        let t = g.translation(in: self)
        if t == .zero && g.state == .changed { return }
        g.setTranslation(.zero, in: self)

        let phase: InputScrollPhase = {
            switch g.state {
            case .began: return .begin
            case .changed: return .changed
            case .ended, .cancelled, .failed: return .end
            default: return .changed
            }
        }()
        sendScroll(at: lastPointerContentPoint, dx: t.x, dy: t.y, phase: phase, source: .indirect)
    }

    // MARK: - Touch cursor mode

    private var activeTouch: UITouch?
    private var touchStart: CGPoint?
    private var touchStartedAt: CFTimeInterval = 0
    private var isDragging = false
    private var rightClickFired = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard synchronizeInputAvailability() else { return }
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
        positionTouchCursor()
        let cursor = cursorLayer.cursorCenter
        if isDragging {
            sendPointer(at: cursor, buttons: 0b001)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard synchronizeInputAvailability() else { return }
        if handleIndirectPointerTouches(touches, with: event, phase: .moved) {
            return
        }

        guard let t = activeTouch, touches.contains(t), touchStart != nil else { return }
        let prev = t.previousLocation(in: self)
        let now = t.location(in: self)
        let delta = CGPoint(x: now.x - prev.x, y: now.y - prev.y)
        cursorLayer.move(
            by: CGPoint(x: delta.x / zoomScale, y: delta.y / zoomScale),
            within: visibleContentRect)
        let cursor = cursorLayer.cursorCenter
        sendPointer(at: cursor, buttons: isDragging ? 0b001 : 0, allowsNewButtons: false)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard synchronizeInputAvailability() else { return }
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
        guard synchronizeInputAvailability() else { return }
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

        activateIndirectPointer()

        let viewLocation = touch.location(in: self)
        let location = contentPoint(from: viewLocation)
        lastPointerLocation = viewLocation

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
            sendPointer(at: location, buttons: buttons)
            lastPointerButtons = inputRouting.pointerButtons
            isTrackingIndirectClick = lastPointerButtons != 0
        case .moved:
            guard isTrackingIndirectClick else { return true }
            sendPointer(at: location, buttons: buttons, allowsNewButtons: false)
            lastPointerButtons = inputRouting.pointerButtons
            isTrackingIndirectClick = lastPointerButtons != 0
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
        guard synchronizeInputAvailability(), activeTouch != nil,
              accessories?.hasIndirectPointer != true,
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
        guard acceptsScrollEvent(g), accessories?.hasIndirectPointer != true,
              RemoteTouchRoutingPolicy.routesTouchesToComputer(
                moveScreenEnabled: zoomController?.moveScreenEnabled ?? false) else { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        let phase: InputScrollPhase = {
            switch g.state {
            case .began: return .begin
            case .changed: return .changed
            case .ended, .cancelled, .failed: return .end
            default: return .changed
            }
        }()
        if phase == .begin { positionTouchCursor() }
        sendScroll(at: cursorLayer.cursorCenter, dx: t.x, dy: t.y, phase: phase, source: .touch)
    }

    // MARK: - UIGestureRecognizerDelegate

    private func acceptsScrollEvent(_ gesture: UIPanGestureRecognizer) -> Bool {
        guard synchronizeInputAvailability(), let inputGeneration else { return false }
        let id = ObjectIdentifier(gesture)
        switch gesture.state {
        case .began:
            scrollGenerations[id] = inputGeneration
            return true
        case .changed, .ended, .cancelled, .failed:
            guard scrollGenerations[id] == inputGeneration else { return false }
            if gesture.state != .changed { scrollGenerations[id] = nil }
            return true
        default: return false
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let available = synchronizeInputAvailability()
        if gestureRecognizer === zoomPan {
            return RemoteTouchRoutingPolicy.movesViewport(
                moveScreenEnabled: zoomController?.moveScreenEnabled ?? false,
                scale: zoomScale)
        }
        if gestureRecognizer === touchScroll {
            return available && accessories?.hasIndirectPointer != true
                && RemoteTouchRoutingPolicy.routesTouchesToComputer(
                    moveScreenEnabled: zoomController?.moveScreenEnabled ?? false)
        }
        if gestureRecognizer === indirectScroll || gestureRecognizer === hover {
            return available && RemoteTouchRoutingPolicy.routesTouchesToComputer(
                moveScreenEnabled: zoomController?.moveScreenEnabled ?? false)
        }
        if gestureRecognizer === pinch {
            return RemoteTouchRoutingPolicy.allowsViewportZoom(
                moveScreenEnabled: zoomController?.moveScreenEnabled ?? false)
        }
        return available
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
            if zoomController?.captureView === self { zoomController?.notePinchInteraction() }
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
            if zoomController?.captureView === self { zoomController?.notePinchInteraction() }
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
                sendPointer(at: lastPointerContentPoint, buttons: 0)
            }
            isTrackingIndirectClick = false
            lastPointerButtons = 0
            if synchronizeInputAvailability(), let inputSource,
               let end = inputRouting.endScroll() {
                session?.send(end, from: inputSource)
            }
        }
        if moveScreenEnabled { scrollGenerations.removeAll() }
        touchScroll.isEnabled = !moveScreenEnabled && inputAvailable
        longPress.isEnabled = !moveScreenEnabled && inputAvailable
        hover.isEnabled = !moveScreenEnabled && inputAvailable
        indirectScroll.isEnabled = !moveScreenEnabled && inputAvailable
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
        videoView.updateViewport(contentView.convert(bounds, from: self))
        cursorLayer.clamp(to: visibleContentRect)
        if zoomController?.captureView === self { zoomController?.report(scale: zoomScale) }
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

    private func activateIndirectPointer() {
        // Finish the previous finger gesture before this modality can own
        // buttons or scrolling. Its later callbacks retain no gesture lease.
        cancelActiveTouch()
        sendScroll(at: nil, dx: 0, dy: 0, phase: .end, source: .touch)
        scrollGenerations[ObjectIdentifier(touchScroll)] = nil
        accessories?.noteIndirectPointer(active: true)
        cursorLayer.hide()
    }

    private func sendPointer(at p: CGPoint?, buttons: UInt8, allowsNewButtons: Bool = true) {
        guard synchronizeInputAvailability(), let inputSource else { return }
        let previousButtons = inputRouting.pointerButtons
        guard let message = inputRouting.pointer(at: p, buttons: buttons, allowsNewButtons: allowsNewButtons,
                geometry: geometry, viewport: visibleContentRect) else { return }
        if inputRouting.pointerButtons & ~previousButtons != 0, let session, let inputGeneration {
            RemoteHardwareKeyboardCapture.requestFocus(in: session, expectedInputGeneration: inputGeneration)
        }
        session?.send(message, from: inputSource)
    }

    private func sendScroll(at p: CGPoint?, dx: CGFloat, dy: CGFloat, phase: InputScrollPhase,
                            source: RemoteScreenInputRouting.ScrollSource) {
        guard synchronizeInputAvailability(), let inputSource,
              let message = inputRouting.scroll(at: p, dx: dx, dy: dy, phase: phase, source: source,
                geometry: geometry, viewport: visibleContentRect) else { return }
        session?.send(message, from: inputSource)
    }

    private func positionTouchCursor() {
        let rect = visibleContentRect
        let position = cursorLayer.positionedCenter.flatMap {
            RemoteScreenGeometry.contains($0, in: rect) ? $0 : nil
        } ?? CGPoint(x: rect.midX, y: rect.midY)
        cursorLayer.show(at: position, within: rect)
    }

    private var visibleContentRect: CGRect {
        geometry.visibleRect(in: contentView.convert(bounds, from: self))
    }

    private var geometry: RemoteScreenGeometry {
        RemoteScreenGeometry(bounds: contentView.bounds, display: remoteDisplay)
    }
}

/// The container survives transport recovery; its driver and Metal layer are
/// fresh for every attachment. Removed attachments cannot present into a successor.
private final class RemoteVideoSurfaceView: UIView, RemoteVideoSurface {
    private var viewport: CGRect?
    private lazy var lifetime = RemoteVideoSurfaceLifetime<RemoteVideoPresentationSurface>(
        make: { RemoteVideoPresentationSurface.make() },
        install: { [weak self] renderer, display in
            guard let self else { return }
            renderer.view.backgroundColor = UIColor(white: 0.05, alpha: 1)
            self.addSubview(renderer.view)
            self.layout(renderer, display: display)
        },
        remove: { renderer in
            renderer.retire()
            renderer.view.removeFromSuperview()
        },
        presentation: { $0.presentation })

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Created programmatically") }

    func makeVideoAttachment(display: DisplayInfo) -> RemoteVideoSurfaceAttachment? {
        lifetime.prepare(display: display)
    }

    func updateViewport(_ viewport: CGRect) {
        self.viewport = viewport
        if let renderer = lifetime.renderer, let display = lifetime.display { layout(renderer, display: display) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let renderer = lifetime.renderer, let display = lifetime.display { layout(renderer, display: display) }
    }

    private func layout(_ renderer: RemoteVideoPresentationSurface, display: DisplayInfo) {
        let layout = RemoteScreenRenderingLayout(bounds: bounds, display: display)
        renderer.view.frame = layout.videoRect
        let visible = renderer.view.convert(viewport ?? bounds, from: self).intersection(renderer.view.bounds)
        renderer.configure(mode: layout.contentMode == .scaleAspectFit ? .aspectFit : .fill, viewport: visible)
        renderer.view.setNeedsLayout()
        renderer.view.layoutIfNeeded()
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

struct RemoteScreenRenderingLayout {
    let videoRect: CGRect
    let contentMode: UIView.ContentMode

    init(bounds: CGRect, display: DisplayInfo?) {
        if display?.fullDisplaySurface == true {
            videoRect = RemoteScreenGeometry(bounds: bounds, display: display).interactiveRect
            contentMode = .scaleToFill
        } else {
            videoRect = bounds
            contentMode = .scaleAspectFit
        }
    }
}

struct RemoteScreenGeometry {
    let bounds: CGRect
    let display: DisplayInfo?

    var interactiveRect: CGRect {
        guard let display, Self.isFiniteRectangle(bounds),
              display.w > 0, display.h > 0,
              display.w <= Int(Int32.max), display.h <= Int(Int32.max),
              display.scale.isFinite, (1...4).contains(display.scale) else {
            return .zero
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

    static func isFiniteRectangle(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.size.width > 0 && rect.size.height > 0 && rect.maxX.isFinite && rect.maxY.isFinite
    }

    static func contains(_ point: CGPoint, in rect: CGRect) -> Bool {
        isFiniteRectangle(rect) && point.x.isFinite && point.y.isFinite
            && point.x >= rect.minX && point.y >= rect.minY && point.x < rect.maxX && point.y < rect.maxY
    }

    func visibleRect(in viewport: CGRect) -> CGRect {
        let rect = interactiveRect
        guard Self.isFiniteRectangle(rect), Self.isFiniteRectangle(viewport) else { return .zero }
        let visible = rect.intersection(viewport)
        return Self.isFiniteRectangle(visible) ? visible : .zero
    }

    func localToRemote(_ point: CGPoint, clamping: Bool = false) -> (x: Int, y: Int)? {
        let rect = interactiveRect
        guard let display, Self.isFiniteRectangle(rect), point.x.isFinite, point.y.isFinite,
              clamping || Self.contains(point, in: rect) else { return nil }
        let nx = max(0, min(1, (point.x - rect.minX) / rect.width))
        let ny = max(0, min(1, (point.y - rect.minY) / rect.height))
        // The full surface represents w by h logical cells. Multiplying by
        // w-1/h-1 instead would shift the cells across the displayed surface.
        return (min(display.w - 1, Int((nx * CGFloat(display.w)).rounded(.down))),
                min(display.h - 1, Int((ny * CGFloat(display.h)).rounded(.down))))
    }
}

/// Gesture intent is separate from coordinate clamping. This state belongs
/// to one view's input-source lease and is discarded when that lease retires.
struct RemoteScreenInputRouting {
    enum ScrollSource: Equatable { case touch, indirect }
    private struct Pointer: Equatable { let x: Int; let y: Int; let buttons: UInt8 }
    private var lastPointer: Pointer?
    private var activeScroll: (source: ScrollSource, x: Int, y: Int)?
    var pointerButtons: UInt8 { lastPointer?.buttons ?? 0 }

    mutating func pointer(at point: CGPoint?, buttons: UInt8, allowsNewButtons: Bool = true,
                          geometry: RemoteScreenGeometry, viewport: CGRect) -> ControlMessage? {
        guard buttons & ~UInt8(0b111) == 0 else { return nil }
        let visible = geometry.visibleRect(in: viewport)
        let inside = point.map { RemoteScreenGeometry.contains($0, in: visible) } ?? false
        let previous = pointerButtons
        guard inside || previous != 0 else { return nil }
        let admitted = inside && allowsNewButtons ? buttons : buttons & previous
        let remote: (x: Int, y: Int)
        if !inside, admitted != previous, let lastPointer {
            // Releases outside the surface (even with invalid coordinates)
            // use the last admitted point; they cannot add a button or move.
            remote = (lastPointer.x, lastPointer.y)
        } else {
            guard let point, RemoteScreenGeometry.isFiniteRectangle(visible), point.x.isFinite, point.y.isFinite else { return nil }
            let clipped = CGPoint(x: max(visible.minX, min(visible.maxX.nextDown, point.x)),
                                  y: max(visible.minY, min(visible.maxY.nextDown, point.y)))
            guard let mapped = geometry.localToRemote(clipped, clamping: !inside) else { return nil }
            remote = mapped
        }
        let next = Pointer(x: remote.x, y: remote.y, buttons: admitted)
        guard next != lastPointer else { return nil }
        lastPointer = next
        return .pointer(x: next.x, y: next.y, buttons: next.buttons)
    }

    mutating func scroll(at point: CGPoint?, dx: CGFloat, dy: CGFloat, phase: InputScrollPhase,
                         source: ScrollSource, geometry: RemoteScreenGeometry, viewport: CGRect) -> ControlMessage? {
        if phase == .end { return activeScroll?.source == source ? endScroll() : nil }
        if phase == .begin { guard activeScroll == nil else { return nil } }
        else { guard activeScroll?.source == source else { return nil } }
        guard let point, RemoteScreenGeometry.contains(point, in: geometry.visibleRect(in: viewport)),
              let remote = geometry.localToRemote(point),
              let ix = Int32(exactly: dx.rounded()), let iy = Int32(exactly: dy.rounded()) else {
            return activeScroll?.source == source ? endScroll() : nil
        }
        if ix == 0 && iy == 0 && phase != .begin { return nil }
        activeScroll = (source, remote.x, remote.y)
        return .scroll(x: remote.x, y: remote.y, dx: Int(ix), dy: Int(iy), phase: phase)
    }

    mutating func endScroll() -> ControlMessage? {
        guard let previous = activeScroll else { return nil }
        activeScroll = nil
        return .scroll(x: previous.x, y: previous.y, dx: 0, dy: 0, phase: .end)
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

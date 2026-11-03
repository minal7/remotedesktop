import Foundation
import LiveKitWebRTC
import Metal
import OSLog
import QuartzCore
import UIKit

/// A fresh native surface for one transport attachment. WebRTC callbacks only
/// replace a bounded mailbox; UIKit and encoding stay on MainActor.
@MainActor
final class RemoteVideoPresentationSurface: NSObject, RTCVideoRenderer {
    let view: RemoteVideoMetalView
    let presentation: RemoteVideoSurfacePresentation
    private let producer: RemoteVideoPresentationProducer
    private let log = Logger(subsystem: "com.threadmark.remotedesktop", category: "video-presentation")
    nonisolated private let mailbox = RemoteVideoLatestFrameMailbox<RTCVideoFrame>()
    private var active = true
    private var contentMode: RemoteVideoPresentationProducer.ContentMode = .fill
    private var viewport = CGRect.zero
    private struct Layout: Equatable {
        let window: ObjectIdentifier
        let rect: CGRect
        let viewport: CGRect
        let size: CGSize
        let mode: RemoteVideoPresentationProducer.ContentMode
    }
    private var layout: Layout?
    private weak var layoutWindow: UIWindow?
    private enum Phase: Equatable { case idle, acquiring(UUID), submitted(UUID) }
    private var phase = Phase.idle
    private var retry: Task<Void, Never>?
    private var retryID: UUID?
    private var deadline: Task<Void, Never>?
    private var deadlineID: UUID?
    private var failedAttempts = 0
    private var failedRetryFrameID: UUID?
    private var layoutChangeCount = 0
    private var lastLayoutWasContinuous = false
    private var lastLayoutHadPendingFrame = false
    private enum FailureCategory: String { case unsupportedFrame, presentationExpired, retryExhausted, deadline }

    private var phaseCategory: String {
        switch phase {
        case .idle: "idle"
        case .acquiring: "acquiring"
        case .submitted: "submitted"
        }
    }

    static func make() -> RemoteVideoPresentationSurface? {
        let view = RemoteVideoMetalView(frame: .zero)
        guard let producer = RemoteVideoPresentationProducer(layer: view.metalLayer) else { return nil }
        return RemoteVideoPresentationSurface(view: view, producer: producer)
    }

    private init(view: RemoteVideoMetalView, producer: RemoteVideoPresentationProducer) {
        self.view = view; self.producer = producer
        presentation = RemoteVideoSurfacePresentation(context: producer.contextID)
        super.init()
        view.isUserInteractionEnabled = false
        view.onGeometryChange = { [weak self] in self?.refreshLayout() }
        mailbox.setWakeHandler { [weak self] wake in
            Task { @MainActor [weak self] in
                guard let self, self.mailbox.accepts(wake) else { return }
                self.requestNext()
            }
        }
    }

    nonisolated func setSize(_ size: CGSize) {
        // Frame geometry comes from the retained RTCVideoFrame. Drawable size
        // comes from the owned UIKit view, never a renderer-thread UI read.
    }

    nonisolated func renderFrame(_ frame: RTCVideoFrame?) {
        if let frame { mailbox.offer(frame) }
    }

    func configure(mode: RemoteVideoPresentationProducer.ContentMode, viewport: CGRect) {
        guard active else { return }
        contentMode = mode; self.viewport = viewport
        refreshLayout()
    }

    func retire() {
        presentation.retire()
        guard active else { return }
        active = false; layout = nil; layoutWindow = nil; phase = .idle
        cancelWaits(); mailbox.replaceContext(nil); producer.retire()
        view.onGeometryChange = nil; view.isHidden = true
    }

    private func refreshLayout() {
        guard active else { return }
        let next: Layout?
        let nextWindow: UIWindow?
        if let window = view.window, !view.isHidden,
           viewport.intersection(view.bounds).width > 0, viewport.intersection(view.bounds).height > 0,
           let size = RemoteVideoDrawableSizing.size(bounds: view.bounds.size, scale: window.screen.scale) {
            next = Layout(window: ObjectIdentifier(window), rect: view.convert(view.bounds, to: window),
                          viewport: viewport, size: size, mode: contentMode)
            nextWindow = window
        } else { next = nil; nextWindow = nil }
        guard layout != next || layoutWindow !== nextWindow else { return }
        let previousContext = producer.contextID
        let continuous = layout != nil && next != nil && layoutWindow === nextWindow
        layout = next; layoutWindow = nextWindow; phase = .idle
        // A pan/resize does not create another source image requirement or
        // replenish a failing surface's time/attempt budget. Hidden/windowless
        // or changed-window transitions cannot carry the retained image.
        if !continuous { cancelWaits(); failedAttempts = 0 }
        producer.replaceContext()
        let context = producer.contextID
        mailbox.replaceContext(next == nil ? nil : context,
                               preservingLatestFrom: continuous ? previousContext : nil,
                               excludingFrameID: failedRetryFrameID)
        failedRetryFrameID = nil
        presentation.begin(context: context)
        layoutChangeCount = min(layoutChangeCount + 1, 17)
        lastLayoutWasContinuous = continuous
        lastLayoutHadPendingFrame = mailbox.hasPending(context: context)
        if layoutChangeCount <= 16 {
            log.notice("layout changed visible=\(next != nil, privacy: .public) continuous=\(continuous, privacy: .public) pending=\(self.lastLayoutHadPendingFrame, privacy: .public)")
        }
        guard isCurrent(context), layout != nil else { return }
        ensureDeadline(context)
        requestNext()
    }

    private func isCurrent(_ context: UUID) -> Bool { active && producer.contextID == context }

    private func requestNext() {
        guard active, phase == .idle, retry == nil, let layout else { return }
        let context = producer.contextID
        guard mailbox.hasPending(context: context) else { return }
        ensureDeadline(context)
        let request = UUID(); phase = .acquiring(request)
        let admitted = RemoteVideoDrawableAcquirer.shared.request(layer: view.metalLayer, size: layout.size) { [weak self] drawable in
            guard let self, self.isCurrent(context), self.phase == .acquiring(request) else { return }
            self.phase = .idle
            self.refreshLayout()
            guard self.isCurrent(context), self.layout == layout else { return }
            guard let drawable else { self.retryLater(context); return }
            guard let entry = self.mailbox.takeLatest(context: context) else { return }
            let admission = self.producer.submit(frame: entry.frame, frameID: entry.id, drawable: drawable, contentMode: layout.mode) { [weak self] frame, result in
                self?.received(result, frame: frame, entry: entry, context: context)
            }
            guard self.isCurrent(context) else { return }
            switch admission {
            case .submitted: self.phase = .submitted(entry.id)
            case .busy, .unavailable, .preparationFailed, .encodingFailed:
                self.mailbox.restoreUnlessNewer(entry)
                self.retryLater(context)
            case .unsupportedFrame:
                self.fail(context, message: "This remote screen format is not supported. Reconnect to try again.", category: .unsupportedFrame)
            }
        }
        if !admitted { phase = .idle; retryLater(context) }
    }

    private func received(_ result: RemoteVideoPresentationLedger.Result, frame: UUID,
                          entry: RemoteVideoLatestFrameMailbox<RTCVideoFrame>.Entry, context: UUID) {
        guard isCurrent(context), phase == .submitted(frame) else { return }
        phase = .idle
        // Observe a current failure before refreshing geometry. Otherwise a
        // layout discovered by this callback could transfer the failed image
        // and suppress the failure as belonging to the replaced context.
        switch result {
        case .skipped, .failed: failedRetryFrameID = frame
        case .expired:
            fail(context, message: "The remote screen stopped refreshing. Reconnect to try again.", category: .presentationExpired)
            return
        case .presented, .rendered: break
        }
        refreshLayout()
        guard isCurrent(context), layout != nil else { return }
        switch result {
        case .presented(let time), .rendered(let time):
            cancelWaits(); failedAttempts = 0; failedRetryFrameID = nil
            if case .presented = result { presentation.present(context: context, frame: frame, time: time) }
            else { presentation.render(context: context, frame: frame, time: time) }
            if isCurrent(context) { requestNext() }
        case .skipped, .failed:
            // Retry the exact latest frame on a fresh drawable. A newer
            // decode wins; failed images never cross a layout context.
            mailbox.restoreUnlessNewer(entry)
            retryLater(context)
        case .expired:
            break // Handled before layout refresh.
        }
    }

    private func retryLater(_ context: UUID) {
        guard isCurrent(context), layout != nil else { return }
        failedAttempts += 1
        guard failedAttempts <= 30 else {
            fail(context, message: "The remote screen could not be refreshed. Reconnect to try again.", category: .retryExhausted); return
        }
        presentation.wait(context: context)
        guard isCurrent(context) else { return }
        ensureDeadline(context)
        guard retry == nil else { return }
        let id = UUID(); retryID = id
        let retryAt = ContinuousClock.now.advanced(by: .milliseconds(100))
        retry = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: retryAt, clock: .continuous) } catch { return }
            guard let self, self.active, self.layout != nil, self.retryID == id else { return }
            self.retry = nil; self.retryID = nil
            self.requestNext()
        }
    }

    private func ensureDeadline(_ context: UUID) {
        guard isCurrent(context), layout != nil, deadline == nil else { return }
        let id = UUID(); deadlineID = id
        let expiresAt = ContinuousClock.now.advanced(by: .seconds(5))
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: expiresAt, clock: .continuous) } catch { return }
            guard let self, self.active, self.layout != nil, self.deadlineID == id else { return }
            // The same recovery episode spans continuous layout contexts.
            // Its original timer must still fail the current context.
            self.fail(self.producer.contextID, message: "The remote screen could not be refreshed. Reconnect to try again.", category: .deadline)
        }
    }

    private func cancelWaits() {
        cancelRetry(); cancelDeadline()
    }

    private func cancelRetry() {
        retry?.cancel(); retry = nil; retryID = nil
    }

    private func cancelDeadline() {
        deadline?.cancel(); deadline = nil; deadlineID = nil
    }

    private func fail(_ context: UUID, message: String, category: FailureCategory) {
        guard isCurrent(context) else { return }
        log.notice("presentation failed category=\(category.rawValue, privacy: .public) phase=\(self.phaseCategory, privacy: .public) pending=\(self.mailbox.hasPending(context: context), privacy: .public) attempts=\(self.failedAttempts, privacy: .public) layoutChanges=\(self.layoutChangeCount, privacy: .public) lastLayoutContinuous=\(self.lastLayoutWasContinuous, privacy: .public) lastLayoutPending=\(self.lastLayoutHadPendingFrame, privacy: .public)")
        active = false; layout = nil; layoutWindow = nil; phase = .idle
        cancelWaits(); mailbox.replaceContext(nil); producer.retire()
        view.onGeometryChange = nil; view.isHidden = true
        presentation.fail(context: context, message: message)
    }
}

@MainActor
final class RemoteVideoMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    var onGeometryChange: (@MainActor () -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); onGeometryChange?() }
    override func didMoveToWindow() { super.didMoveToWindow(); onGeometryChange?() }
}

enum RemoteVideoDrawableSizing {
    static func size(bounds: CGSize, scale: CGFloat) -> CGSize? {
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
              scale.isFinite, scale > 0 else { return nil }
        var width = bounds.width * scale, height = bounds.height * scale
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let dimensionScale = min(1, 8_192 / max(width, height))
        width *= dimensionScale; height *= dimensionScale
        let areaScale = min(1, sqrt(16_777_216 / (width * height)))
        let w = max(1, Int((width * areaScale).rounded(.down)))
        let h = max(1, Int((height * areaScale).rounded(.down)))
        guard RemoteVideoPresentationProducer.validDestination(width: w, height: h) else { return nil }
        return CGSize(width: w, height: h)
    }
}

/// One process-wide native acquisition, without an unbounded dispatch backlog.
/// nextDrawable can wait for the layer's one-second native timeout. Its worker
/// does not read UIKit or hold decoded frames. Retirement discards its result;
/// it does not pretend to cancel the native call or free its occupied slot.
@MainActor
private final class RemoteVideoDrawableAcquirer {
    static let shared = RemoteVideoDrawableAcquirer()
    private let queue = DispatchQueue(label: "com.threadmark.remote-video.drawable", qos: .userInitiated)
    private var inFlight = false
    func request(layer: CAMetalLayer, size: CGSize, completion: @escaping @MainActor (CAMetalDrawable?) -> Void) -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        let request = RemoteVideoDrawableRequest(layer: layer, size: size)
        queue.async { [weak self] in
            let result = autoreleasepool {
                request.layer.drawableSize = request.size
                return RemoteVideoDrawableResult(request.layer.nextDrawable())
            }
            Task { @MainActor in
                guard let self else { return }
                self.inFlight = false
                completion(result.drawable)
            }
        }
        return true
    }
}

private final class RemoteVideoDrawableRequest: @unchecked Sendable {
    let layer: CAMetalLayer; let size: CGSize
    init(layer: CAMetalLayer, size: CGSize) { self.layer = layer; self.size = size }
}

private final class RemoteVideoDrawableResult: @unchecked Sendable {
    let drawable: CAMetalDrawable?
    init(_ drawable: CAMetalDrawable?) { self.drawable = drawable }
}

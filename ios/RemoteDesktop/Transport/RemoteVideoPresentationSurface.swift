import Foundation
import LiveKitWebRTC
import Metal
import QuartzCore
import UIKit

/// A fresh native surface for one transport attachment. WebRTC callbacks only
/// replace a bounded mailbox; UIKit and encoding stay on MainActor.
@MainActor
final class RemoteVideoPresentationSurface: NSObject, RTCVideoRenderer {
    let view: RemoteVideoMetalView
    let presentation: RemoteVideoSurfacePresentation
    private let producer: RemoteVideoPresentationProducer
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
    private enum Phase: Equatable { case idle, acquiring(UUID), submitted(UUID) }
    private var phase = Phase.idle
    private var retry: Task<Void, Never>?
    private var retryID: UUID?
    private var deadline: Task<Void, Never>?
    private var deadlineID: UUID?
    private var failedAttempts = 0

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
        active = false; layout = nil; phase = .idle
        cancelWaits(); mailbox.replaceContext(nil); producer.retire()
        view.onGeometryChange = nil; view.isHidden = true
    }

    private func refreshLayout() {
        guard active else { return }
        let next: Layout?
        if let window = view.window, !view.isHidden,
           viewport.intersection(view.bounds).width > 0, viewport.intersection(view.bounds).height > 0,
           let size = RemoteVideoDrawableSizing.size(bounds: view.bounds.size, scale: window.screen.scale) {
            next = Layout(window: ObjectIdentifier(window), rect: view.convert(view.bounds, to: window),
                          viewport: viewport, size: size, mode: contentMode)
        } else { next = nil }
        guard layout != next else { return }
        layout = next; phase = .idle; failedAttempts = 0
        cancelWaits(); producer.replaceContext()
        let context = producer.contextID
        mailbox.replaceContext(next == nil ? nil : context)
        presentation.begin(context: context)
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
                self?.received(result, frame: frame, context: context)
            }
            guard self.isCurrent(context) else { return }
            switch admission {
            case .submitted: self.phase = .submitted(entry.id)
            case .busy, .unavailable, .preparationFailed, .encodingFailed:
                self.mailbox.restoreUnlessNewer(entry)
                self.retryLater(context)
            case .unsupportedFrame:
                self.fail(context, message: "This remote screen format is not supported. Reconnect to try again.")
            }
        }
        if !admitted { phase = .idle; retryLater(context) }
    }

    private func received(_ result: RemoteVideoPresentationLedger.Result, frame: UUID, context: UUID) {
        guard isCurrent(context), phase == .submitted(frame) else { return }
        phase = .idle
        refreshLayout()
        guard isCurrent(context), layout != nil else { return }
        switch result {
        case .presented(let time):
            cancelWaits(); failedAttempts = 0
            presentation.present(context: context, frame: frame, time: time)
            if isCurrent(context) { requestNext() }
        case .skipped, .failed:
            // A committed drawable/frame is never submitted again. Only a
            // newer mailbox entry may recover a failed presentation.
            retryLater(context)
        case .expired:
            fail(context, message: "The remote screen stopped refreshing. Reconnect to try again.")
        }
    }

    private func retryLater(_ context: UUID) {
        guard isCurrent(context), layout != nil else { return }
        failedAttempts += 1
        guard failedAttempts <= 30 else {
            fail(context, message: "The remote screen could not be refreshed. Reconnect to try again."); return
        }
        presentation.wait(context: context)
        guard isCurrent(context) else { return }
        ensureDeadline(context)
        guard retry == nil else { return }
        let id = UUID(); retryID = id
        retry = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self, self.isCurrent(context), self.retryID == id else { return }
            self.retry = nil; self.retryID = nil
            self.requestNext()
        }
    }

    private func ensureDeadline(_ context: UUID) {
        guard deadline == nil else { return }
        let id = UUID(); deadlineID = id
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.isCurrent(context), self.deadlineID == id else { return }
            self.fail(context, message: "The remote screen could not be refreshed. Reconnect to try again.")
        }
    }

    private func cancelWaits() {
        retry?.cancel(); retry = nil; retryID = nil
        deadline?.cancel(); deadline = nil; deadlineID = nil
    }

    private func fail(_ context: UUID, message: String) {
        guard isCurrent(context) else { return }
        active = false; layout = nil; phase = .idle
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

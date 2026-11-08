#if DEBUG
import CoreImage
import Foundation
import LiveKitWebRTC
import Metal
import QuartzCore

/// All F4 attachments share one serial queue and one presentation ledger. In
/// particular, retiring an attachment cannot release a GPU permit early.
final class RemoteVideoF4Renderer: @unchecked Sendable {
    typealias Mailbox = RemoteVideoLatestFrameMailbox<RTCVideoFrame>
    enum FailureReason: Sendable { case unsupportedFrame, presentationExpired, retryExhausted, deadline }
    enum Event: Sendable {
        case ready(UUID, UUID, TimeInterval, Bool)
        case waiting(UUID)
        case failed(UUID, String, FailureReason)
    }
    struct Layout {
        let context: UUID
        let size: CGSize
        let mode: RemoteVideoPresentationProducer.ContentMode
    }
    private static let queue = DispatchQueue(label: "com.threadmark.remote-video.f4", qos: .userInteractive)
    // GPU permits are independent of observation receipts. A late presented
    // callback may occupy a bounded ledger entry but never a GPU permit.
    private static var ledger = RemoteVideoPresentationLedger(capacity: 16)
    private let layer: CAMetalLayer
    private let mailbox: Mailbox
    private let metal: RemoteVideoF4Metal
    private let commandQueue: MTLCommandQueue
    private let ci: CIContext
    private let colorSpace: CGColorSpace
    private let notify: @Sendable (UInt64, Event) -> Void
    private var eventSerial: UInt64 = 0
    private let generationLock = NSLock()
    private var generation: UUID?
    // Accessed only by the shared render queue.
    private var layout: Layout?
    private var active = true
    private var retryID: UUID?
    private var attempts = 0
    private var deadline: TimeInterval?
    private var deadlineTimer: DispatchSourceTimer?
    private var ready = false
    private var lastDrawableID: Int?
    private var lastPresentation: TimeInterval = 0
    private var lastReceiptDrawableID: Int?
    private var samples: [UUID: RemoteVideoLatencyProbe.FrameSample] = [:]
    private var loggedMetalPath = false
    private var loggedFallbackPath = false
    private var ticketDeadlines: [UUID: (RemoteVideoPresentationTicket, TimeInterval)] = [:]
    private var ticketTimer: DispatchSourceTimer?
    private var receiptLifetime: RemoteVideoF4Renderer?

    init?(layer: CAMetalLayer, mailbox: Mailbox, notify: @escaping @Sendable (UInt64, Event) -> Void) {
        guard let device = layer.device, let queue = device.makeCommandQueue(),
              let metal = RemoteVideoF4Metal(device: device),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        self.layer = layer; self.mailbox = mailbox; self.notify = notify
        self.metal = metal; self.commandQueue = queue; self.colorSpace = colorSpace
        self.ci = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false])
    }

    func configure(_ next: Layout?, preservingRecovery: Bool) {
        generationLock.lock(); generation = next?.context; generationLock.unlock()
        Self.queue.async { [self] in
            guard currentGeneration(next?.context) else { return }
            if let old = layout?.context { apply(Self.ledger.retire(context: old)) }
            layout = next; ready = false; lastPresentation = 0; lastReceiptDrawableID = nil
            if !preservingRecovery { attempts = 0; clearDeadline(); retryID = nil }
            guard let next, active else { return }
            ensureDeadline(next.context)
            drain()
        }
    }
    func retire() {
        generationLock.lock(); generation = nil; generationLock.unlock()
        Self.queue.async { [self] in
            active = false
            if let context = layout?.context { apply(Self.ledger.retire(context: context)) }
            layout = nil; deadline = nil
            deadlineTimer?.cancel(); deadlineTimer = nil
            ticketTimer?.cancel(); ticketTimer = nil
        }
    }
    func wake() { Self.queue.async { [weak self] in self?.drain() } }
    private func send(_ event: Event) {
        eventSerial &+= 1
        notify(eventSerial, event)
    }
    private func currentGeneration(_ context: UUID?) -> Bool {
        generationLock.lock(); defer { generationLock.unlock() }
        return generation == context
    }
    private func current(_ context: UUID) -> Bool { currentGeneration(context) }
    private func ensureDeadline(_ context: UUID) {
        guard deadline == nil else { return }
        deadline = CACurrentMediaTime() + 5
        if deadlineTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: Self.queue)
            timer.setEventHandler { [weak self] in
                guard let self, self.active, let deadline = self.deadline,
                      CACurrentMediaTime() >= deadline, let layout = self.layout,
                      self.current(layout.context) else { return }
                self.fail(layout.context, "The remote screen could not be refreshed. Reconnect to try again.", reason: .deadline)
            }
            deadlineTimer = timer
            timer.resume()
        }
        deadlineTimer?.schedule(deadline: .now() + 5)
    }
    private func clearDeadline() {
        deadline = nil
        deadlineTimer?.schedule(deadline: .distantFuture)
    }
    private func retry(_ context: UUID) {
        guard current(context), active, retryID == nil else { return }
        attempts += 1
        guard attempts <= 30 else { fail(context, "The remote screen could not be refreshed. Reconnect to try again.", reason: .retryExhausted); return }
        ensureDeadline(context)
        ready = false
        send(.waiting(context))
        scheduleRetry()
    }
    private func scheduleRetry() {
        guard retryID == nil else { return }
        let id = UUID(); retryID = id
        Self.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.retryID == id else { return }
            self.retryID = nil; self.drain()
        }
    }
    private func fail(_ context: UUID, _ message: String, reason: FailureReason) {
        guard current(context), active else { return }
        active = false; clearDeadline()
        apply(Self.ledger.retire(context: context))
        send(.failed(context, message, reason))
    }
    private func drain() {
        guard active, retryID == nil, let layout, current(layout.context), mailbox.hasPending(context: layout.context) else { return }
        ensureDeadline(layout.context)
        // A full ledger is normal backpressure, not a rendering failure.
        guard Self.ledger.count < Self.ledger.capacity else { scheduleRetry(); return }
        // Never enqueue more than one acquisition; this shared serial queue owns it.
        layer.drawableSize = layout.size
        guard let drawable = layer.nextDrawable(), current(layout.context) else { retry(layout.context); return }
        guard let entry = mailbox.takeLatest(context: layout.context) else { return }
        #if targetEnvironment(simulator)
        guard lastDrawableID != Int.max else { mailbox.restoreUnlessNewer(entry); retry(layout.context); return }
        let drawableID = (lastDrawableID ?? -1) + 1
        let needsPresentation = false
        #else
        guard drawable.presentedTime == 0, let drawableID = Int(exactly: drawable.drawableID),
              lastDrawableID.map({ drawableID > $0 }) ?? true else { mailbox.restoreUnlessNewer(entry); retry(layout.context); return }
        let needsPresentation = true
        #endif
        guard let gpuPermit = RemoteVideoGPUAdmission.shared.acquire() else {
            mailbox.restoreUnlessNewer(entry); scheduleRetry(); return
        }
        var gpuCommitted = false
        defer { if !gpuCommitted { gpuPermit.release() } }
        guard let ticket = Self.ledger.reserve(context: layout.context, frame: entry.id, drawable: ObjectIdentifier(drawable),
                                                drawableID: drawableID, requiresPresentationCallback: needsPresentation) else {
            mailbox.restoreUnlessNewer(entry); retry(layout.context); return
        }
        let prepared: RemoteVideoFrameImage
        switch RemoteVideoFrameImage.prepare(entry.frame) {
        case .ready(let image): prepared = image
        case .unsupported:
            apply(Self.ledger.abandonUncommitted(ticket))
            fail(layout.context, "This remote screen format is not supported. Reconnect to try again.", reason: .unsupportedFrame); return
        case .resourceFailure:
            apply(Self.ledger.abandonUncommitted(ticket)); mailbox.restoreUnlessNewer(entry); retry(layout.context); return
        }
        guard let command = commandQueue.makeCommandBuffer() else {
            apply(Self.ledger.abandonUncommitted(ticket)); mailbox.restoreUnlessNewer(entry); retry(layout.context); return
        }
        // RGB native buffers keep the established CI conversion fallback.
        let metalResources = metal.encode(prepared: prepared, destination: drawable.texture, command: command, mode: layout.mode)
        var ciResources: (CIImage, CIRenderTask)?
        if metalResources == nil {
            let bounds = CGRect(x: 0, y: 0, width: drawable.texture.width, height: drawable.texture.height)
            let image = Self.place(prepared.image, in: bounds, mode: layout.mode)
            let destination = CIRenderDestination(mtlTexture: drawable.texture, commandBuffer: command)
            destination.colorSpace = colorSpace; destination.alphaMode = .none; destination.isFlipped = true
            guard let task = try? ci.startTask(toRender: image, to: destination) else {
                apply(Self.ledger.abandonUncommitted(ticket)); mailbox.restoreUnlessNewer(entry); retry(layout.context); return
            }
            ciResources = (image, task)
        }
        // Synchronize the final context check through command submission with
        // retirement, so a detached surface cannot commit a new drawable.
        generationLock.lock()
        guard generation == layout.context, Self.ledger.commit(ticket) else {
            generationLock.unlock()
            apply(Self.ledger.abandonUncommitted(ticket)); return
        }
        lastDrawableID = drawableID
        if let sample = entry.latency { samples[ticket.id] = sample }
        let resources = Resources(frame: entry.frame, prepared: prepared, metal: metalResources, ci: ciResources)
        command.addCompletedHandler { [self, resources] command in
            gpuPermit.release()
            let succeeded = command.status == .completed, time = CACurrentMediaTime()
            Self.queue.async { [self] in
                if succeeded && current(ticket.context) { retryID = nil }
                apply(Self.ledger.completeGPU(ticket, succeeded: succeeded, completionTime: time))
                drain()
            }
            withExtendedLifetime(resources) {}
        }
        #if !targetEnvironment(simulator)
        drawable.addPresentedHandler { [weak self] drawable in
            let object = ObjectIdentifier(drawable), time = drawable.presentedTime
            guard let self, let id = Int(exactly: drawable.drawableID) else { return }
            Self.queue.async { [self] in
                if self.current(ticket.context) { self.retryID = nil }
                self.apply(Self.ledger.presented(ticket, drawable: object, drawableID: id, time: time))
                self.drain()
            }
        }
        #endif
        command.present(drawable)
        entry.latency?.submittedTime = CACurrentMediaTime()
        command.commit()
        gpuCommitted = true
        generationLock.unlock()
        if LatencyStatsCollector.enabled {
            if metalResources != nil, !loggedMetalPath {
                loggedMetalPath = true
                RemoteVideoLatencyProbe.shared.collector.trace(["type": "f4_render_path", "path": "metal", "time": CACurrentMediaTime()])
            } else if metalResources == nil, !loggedFallbackPath {
                loggedFallbackPath = true
                RemoteVideoLatencyProbe.shared.collector.trace(["type": "f4_render_path", "path": "core_image_fallback", "time": CACurrentMediaTime()])
            }
        }
        // An expiry silences observations but cannot release pending GPU work.
        ticketDeadlines[ticket.id] = (ticket, CACurrentMediaTime() + 5)
        receiptLifetime = self
        scheduleTicketTimer()
        if mailbox.hasPending(context: layout.context) { wake() }
    }
    private func apply(_ change: RemoteVideoPresentationLedger.Change) {
        for (ticket, result) in change.results {
            ticketDeadlines.removeValue(forKey: ticket.id)
            let sample = samples.removeValue(forKey: ticket.id)
            guard active, current(ticket.context), layout?.context == ticket.context,
                  lastReceiptDrawableID.map({ ticket.drawableID > $0 }) ?? true else { continue }
            switch result {
            case .presented(let time), .rendered(let time):
                guard time >= lastPresentation else { continue }
                mailbox.clearFailed(frame: ticket.frame, context: ticket.context)
                lastPresentation = time; lastReceiptDrawableID = ticket.drawableID
                attempts = 0; clearDeadline()
                if case .presented = result, let sample { RemoteVideoLatencyProbe.shared.presented(sample, time: time) }
                if !ready {
                    ready = true
                    if case .presented = result { send(.ready(ticket.context, ticket.frame, time, true)) }
                    else { send(.ready(ticket.context, ticket.frame, time, false)) }
                }
            case .failed, .skipped:
                mailbox.restoreFailed(frame: ticket.frame, context: ticket.context)
                retry(ticket.context)
            case .expired:
                fail(ticket.context, "The remote screen stopped refreshing. Reconnect to try again.", reason: .presentationExpired)
            }
        }
        for ticket in change.released + change.silenced {
            samples.removeValue(forKey: ticket.id)
            ticketDeadlines.removeValue(forKey: ticket.id)
        }
        scheduleTicketTimer()
    }
    private func scheduleTicketTimer() {
        guard let earliest = ticketDeadlines.values.map({ $0.1 }).min() else {
            ticketTimer?.schedule(deadline: .distantFuture)
            receiptLifetime = nil
            return
        }
        if ticketTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: Self.queue)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let now = CACurrentMediaTime()
                let expired = self.ticketDeadlines.values.filter { $0.1 <= now }.map { $0.0 }
                for ticket in expired { self.apply(Self.ledger.expire(ticket)) }
                self.scheduleTicketTimer()
            }
            ticketTimer = timer; timer.resume()
        }
        ticketTimer?.schedule(deadline: .now() + max(0, earliest - CACurrentMediaTime()))
    }
    private static func place(_ image: CIImage, in bounds: CGRect, mode: RemoteVideoPresentationProducer.ContentMode) -> CIImage {
        var sx = bounds.width / image.extent.width, sy = bounds.height / image.extent.height
        if mode == .aspectFit { sx = min(sx, sy); sy = sx }
        let scaled = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let positioned = scaled.transformed(by: CGAffineTransform(translationX: (bounds.width - scaled.extent.width) / 2, y: (bounds.height - scaled.extent.height) / 2))
        return positioned.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: bounds)).cropped(to: bounds)
    }
    private final class Resources: @unchecked Sendable {
        let frame: RTCVideoFrame; let prepared: RemoteVideoFrameImage
        let metal: RemoteVideoF4Metal.Resources?; let ci: (CIImage, CIRenderTask)?
        init(frame: RTCVideoFrame, prepared: RemoteVideoFrameImage, metal: RemoteVideoF4Metal.Resources?, ci: (CIImage, CIRenderTask)?) {
            self.frame = frame; self.prepared = prepared; self.metal = metal; self.ci = ci
        }
    }
}
#endif

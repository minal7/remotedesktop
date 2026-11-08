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
    #if DEBUG
    private var submittedLatency: (frame: UUID, sample: RemoteVideoLatencyProbe.FrameSample)?
    nonisolated private let labInstrumentation: Bool
    private let labRetryDiagnostics: Bool
    private let labNonserial: Bool
    private var labSkipRetry: Bool
    private var labSkipRecovery = LabSkipRecovery()
    private var labSkipNotice: Task<Void, Never>?
    private var labSkipNoticeID: UUID?
    private var labPending: [UUID: RemoteVideoLatestFrameMailbox<RTCVideoFrame>.Entry] = [:]
    private var labGate = LabNonserialGate()
    private var retryTraceGeneration = 0
    #endif
    #if DEBUG
    private var f4: RemoteVideoF4Renderer?
    private var f4EventSerial: UInt64 = 0
    private var highRefreshLink: CADisplayLink?
    private var highRefreshMode: LabHintMode?
    private var labHintTraceForTesting: (([String: Any]) -> Void)?
    private let highRefreshTarget = RemoteVideoHighRefreshTarget()
    private var labRefreshEnvironmentOverride: [String: String]?
    var labRefreshLinkIdentityForTesting: ObjectIdentifier? { highRefreshLink.map(ObjectIdentifier.init) }
    var labRefreshRangeForTesting: CAFrameRateRange? { highRefreshLink?.preferredFrameRateRange }
    func setLabRefreshEnvironmentForTesting(_ environment: [String: String]) {
        labRefreshEnvironmentOverride = environment
    }
    func setLabHintTraceForTesting(_ trace: @escaping ([String: Any]) -> Void) {
        labHintTraceForTesting = trace
    }
    #endif
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
    private static let retriesBeforeWaiting = 3
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

    static func make(allowF4: Bool = false) -> RemoteVideoPresentationSurface? {
        let view = RemoteVideoMetalView(frame: .zero)
        guard let producer = RemoteVideoPresentationProducer(layer: view.metalLayer, labAdmission: allowF4) else { return nil }
        return RemoteVideoPresentationSurface(view: view, producer: producer, allowF4: allowF4)
    }

    private init?(view: RemoteVideoMetalView, producer: RemoteVideoPresentationProducer, allowF4: Bool) {
        self.view = view; self.producer = producer
        #if DEBUG
        self.labInstrumentation = allowF4
        self.labRetryDiagnostics = Self.retryDiagnosticsEnabled(labAdmitted: allowF4,
            environment: ProcessInfo.processInfo.environment)
        self.labNonserial = Self.labNonserialEnabled(labAdmitted: allowF4,
            f4: LatencyLabConfiguration.current.f4Renderer, environment: ProcessInfo.processInfo.environment)
        self.labSkipRetry = Self.labSkipRetryEnabled(labAdmitted: allowF4,
            f4: LatencyLabConfiguration.current.f4Renderer, environment: ProcessInfo.processInfo.environment)
        #endif
        presentation = RemoteVideoSurfacePresentation(context: producer.contextID)
        super.init()
        view.isUserInteractionEnabled = false
        view.onGeometryChange = { [weak self] in self?.refreshLayout() }
        #if DEBUG
        view.onLabVisibilityChange = { [weak self] in
            guard let self else { return }
            if self.labSkipRetry { self.refreshLayout(); return }
            guard self.f4 == nil,
                  Self.labRefreshHintAction(labAdmitted: self.labInstrumentation, visible: true, hasLink: false,
                    environment: self.labRefreshEnvironmentOverride ?? ProcessInfo.processInfo.environment) != .stop else { return }
            self.refreshLayout()
        }
        if allowF4 && LatencyLabConfiguration.current.f4Renderer {
            guard let renderer = RemoteVideoF4Renderer(layer: view.metalLayer, mailbox: mailbox, notify: { [weak self] serial, event in
                Task { @MainActor [weak self] in self?.receiveF4(event, serial: serial) }
            }) else { return nil }
            f4 = renderer
        }
        if let f4 {
            mailbox.setWakeHandler { [weak f4] _ in f4?.wake() }
            return
        }
        #endif
        #if DEBUG
        if labNonserial {
            if LatencyStatsCollector.enabled {
                RemoteVideoLatencyProbe.shared.collector.trace(["type": "render_pipeline", "mode": "gpu_before_receipt",
                                                                "time": CACurrentMediaTime()])
            }
            producer.onLabGPUComplete = { [weak self] context, frame, success in
                self?.labGPUCompleted(context: context, frame: frame, succeeded: success)
            }
            producer.onLabDiscarded = { [weak self] context, frame in
                self?.labDiscarded(context: context, frame: frame)
            }
        }
        #endif
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
        if let frame {
            #if DEBUG
            if labInstrumentation && LatencyStatsCollector.enabled {
                let decodedTime = CACurrentMediaTime()
                let sample = RemoteVideoLatencyProbe.shared.capture(frame, decodedAt: decodedTime)
                mailbox.offer(frame, latency: sample)
            } else { mailbox.offer(frame) }
            #else
            mailbox.offer(frame)
            #endif
        }
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
        #if DEBUG
        stopHighRefresh(); f4?.retire()
        cancelLabSkipNotice(); labSkipRecovery.reset()
        view.onLabVisibilityChange = nil
        submittedLatency = nil
        labPending.removeAll(); labGate.reset()
        #endif
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
        #if DEBUG
        updateHighRefresh(streaming: next != nil)
        #endif
        guard layout != next || layoutWindow !== nextWindow else { return }
        let previousContext = producer.contextID
        let continuous = layout != nil && next != nil && layoutWindow === nextWindow
        layout = next; layoutWindow = nextWindow; phase = .idle
        #if DEBUG
        submittedLatency = nil
        labPending.removeAll(); labGate.reset()
        cancelLabSkipNotice(); labSkipRecovery.reset()
        #endif
        // A pan/resize does not create another source image requirement or
        // replenish a failing surface's time/attempt budget. Hidden/windowless
        // or changed-window transitions cannot carry the retained image.
        if !continuous { cancelWaits(); failedAttempts = 0 }
        producer.replaceContext()
        #if DEBUG
        if labRetryDiagnostics { retryTraceGeneration = min(retryTraceGeneration + 1, 1_000_000) }
        #endif
        let context = producer.contextID
        mailbox.replaceContext(next == nil ? nil : context,
                               preservingLatestFrom: continuous ? previousContext : nil,
                               excludingFrameID: failedRetryFrameID)
        failedRetryFrameID = nil
        presentation.begin(context: context, keepingScreenReady: continuous)
        #if DEBUG
        if labSkipRetry, next != nil { labSkipRecovery.begin(context: context, time: CACurrentMediaTime()) }
        #endif
        layoutChangeCount = min(layoutChangeCount + 1, 17)
        lastLayoutWasContinuous = continuous
        lastLayoutHadPendingFrame = mailbox.hasPending(context: context)
        if layoutChangeCount <= 16 {
            log.notice("layout changed visible=\(next != nil, privacy: .public) continuous=\(continuous, privacy: .public) pending=\(self.lastLayoutHadPendingFrame, privacy: .public)")
        }
        #if DEBUG
        if let f4 {
            f4.configure(next.map { .init(context: context, size: $0.size, mode: $0.mode) }, preservingRecovery: continuous)
            return
        }
        #endif
        guard isCurrent(context), layout != nil else { return }
        ensureDeadline(context)
        requestNext()
    }

    #if DEBUG
    private func receiveF4(_ event: RemoteVideoF4Renderer.Event, serial: UInt64) {
        guard serial > f4EventSerial else { return }
        f4EventSerial = serial
        switch event {
        case let .ready(context, frame, time, presented):
            guard isCurrent(context) else { return }
            if presented { presentation.present(context: context, frame: frame, time: time) }
            else { presentation.render(context: context, frame: frame, time: time) }
        case let .waiting(context):
            guard isCurrent(context) else { return }
            presentation.wait(context: context)
        case let .failed(context, message, reason):
            let category: FailureCategory
            switch reason {
            case .unsupportedFrame: category = .unsupportedFrame
            case .presentationExpired: category = .presentationExpired
            case .retryExhausted: category = .retryExhausted
            case .deadline: category = .deadline
            }
            fail(context, message: message, category: category)
        }
    }

    enum LabRefreshHintAction: Equatable { case start, keep, stop }
    enum LabHintMode: String { case fixed60, f4 }
    enum LabHintState: String { case started, stopped }

    static func labHintRecord(state: LabHintState, mode: LabHintMode, time: Double,
                              range: CAFrameRateRange? = nil, screenMaximumFps: Int? = nil) -> [String: Any]? {
        guard time.isFinite, time >= 0 else { return nil }
        var record: [String: Any] = ["type": "render_hint", "state": state.rawValue,
                                     "mode": mode.rawValue, "time": time]
        if state == .started {
            guard let range, let preferred = range.preferred, let screenMaximumFps, (1...1000).contains(screenMaximumFps),
                  range.minimum.isFinite, range.maximum.isFinite, preferred.isFinite,
                  range.minimum > 0, range.minimum <= range.maximum,
                  range.maximum <= Float(screenMaximumFps),
                  preferred >= range.minimum, preferred <= range.maximum else { return nil }
            record["minimumFps"] = Double(range.minimum)
            record["maximumFps"] = Double(range.maximum)
            record["preferredFps"] = Double(preferred)
            record["screenMaximumFps"] = screenMaximumFps
        }
        return record
    }

    private func traceLabHint(state: LabHintState, mode: LabHintMode,
                              range: CAFrameRateRange? = nil, screenMaximumFps: Int? = nil) {
        let environment = labRefreshEnvironmentOverride ?? ProcessInfo.processInfo.environment
        guard labInstrumentation, environment["LATENCY_LAB"] == "1",
              let record = Self.labHintRecord(state: state, mode: mode, time: CACurrentMediaTime(),
                                              range: range, screenMaximumFps: screenMaximumFps) else { return }
        labHintTraceForTesting?(record)
        if LatencyStatsCollector.enabled { RemoteVideoLatencyProbe.shared.collector.trace(record) }
    }

    static func labRefreshHintAction(labAdmitted: Bool, visible: Bool, hasLink: Bool,
                                     environment: [String: String]) -> LabRefreshHintAction {
        guard labAdmitted, visible, environment["LATENCY_LAB"] == "1",
              environment["LATENCY_RENDER_HINT_60"] == "1" else { return .stop }
        return hasLink ? .keep : .start
    }

    private func updateHighRefresh(streaming: Bool) {
        guard streaming, let screen = view.window?.screen else {
            stopHighRefresh(); return
        }
        let isF4 = f4 != nil
        if !isF4 {
            let action = Self.labRefreshHintAction(labAdmitted: labInstrumentation,
                visible: streaming, hasLink: highRefreshLink != nil,
                environment: labRefreshEnvironmentOverride ?? ProcessInfo.processInfo.environment)
            guard action != .stop else { stopHighRefresh(); return }
        }
        let maximum = Float(max(1, min(isF4 ? 120 : 60, screen.maximumFramesPerSecond)))
        let minimum = isF4 ? min(80, maximum) : maximum
        let range = CAFrameRateRange(minimum: minimum, maximum: maximum, preferred: maximum)
        if let highRefreshLink {
            highRefreshLink.preferredFrameRateRange = range
            return
        }
        let link = CADisplayLink(target: highRefreshTarget, selector: #selector(RemoteVideoHighRefreshTarget.tick))
        link.preferredFrameRateRange = range
        link.add(to: .main, forMode: .common)
        highRefreshLink = link
        let mode: LabHintMode = isF4 ? .f4 : .fixed60
        highRefreshMode = mode
        traceLabHint(state: .started, mode: mode, range: link.preferredFrameRateRange,
                     screenMaximumFps: screen.maximumFramesPerSecond)
    }

    private func stopHighRefresh() {
        guard let link = highRefreshLink else { return }
        link.invalidate()
        highRefreshLink = nil
        if let mode = highRefreshMode { traceLabHint(state: .stopped, mode: mode) }
        highRefreshMode = nil
    }
    #endif

    #if DEBUG
    static func labSkipRetryEnabled(labAdmitted: Bool, f4: Bool, environment: [String: String]) -> Bool {
        labAdmitted && !f4 && environment["LATENCY_LAB"] == "1" && environment["LATENCY_SKIP_RETRY"] == "1"
    }

    /// A context-scoped clock; only a genuine presentation resets the notice deadline.
    struct LabSkipRecovery {
        private(set) var context: UUID?
        private(set) var referenceTime: TimeInterval = 0
        mutating func begin(context: UUID, time: TimeInterval) {
            guard time.isFinite, time >= 0 else { reset(); return }
            self.context = context; referenceTime = time
        }
        mutating func presented(context: UUID, time: TimeInterval) -> Bool {
            guard self.context == context, time.isFinite, time >= referenceTime else { return false }
            referenceTime = time; return true
        }
        func deadline(context: UUID) -> TimeInterval? {
            guard self.context == context else { return nil }
            return referenceTime + 1
        }
        func shouldWait(context: UUID, time: TimeInterval) -> Bool {
            guard time.isFinite, let deadline = deadline(context: context) else { return false }
            return time >= deadline
        }
        mutating func reset() { context = nil; referenceTime = 0 }
    }

    // Test seams exercise the real receipt handler with a synthetic receipt;
    // they do not create or claim a native presentation.
    func labEnableSkipRetryForTesting() {
        guard labInstrumentation, f4 == nil else { return }
        labSkipRetry = true
    }
    var labRetryScheduledForTesting: Bool { retry != nil }
    var labNoticeScheduledForTesting: Bool { labSkipNotice != nil }
    var labFailedAttemptsForTesting: Int { failedAttempts }
    var labContextForTesting: UUID { producer.contextID }
    var labDeadlineIDForTesting: UUID? { deadlineID }
    var labPendingForTesting: Bool { mailbox.hasPending(context: producer.contextID) }
    var labRequestCountForTesting = 0
    var labSuppressAcquisitionForTesting = false
    func labReceiveForTesting(_ result: RemoteVideoPresentationLedger.Result, frame: RTCVideoFrame, newer: RTCVideoFrame? = nil) {
        guard labSkipRetry, active, layout != nil, !labNonserial else { return }
        let context = producer.contextID
        mailbox.offer(frame)
        guard let entry = mailbox.takeLatest(context: context) else { return }
        if let newer { mailbox.offer(newer) }
        phase = .submitted(entry.id)
        received(result, frame: entry.id, entry: entry, context: context)
    }

    private func cancelLabSkipNotice() {
        labSkipNotice?.cancel(); labSkipNotice = nil; labSkipNoticeID = nil
    }

    private func labPresented(context: UUID, time: TimeInterval) {
        guard labSkipRetry, isCurrent(context), labSkipRecovery.presented(context: context, time: time) else { return }
        cancelLabSkipNotice()
    }

    private func labSkipped(context: UUID) {
        guard labSkipRetry, isCurrent(context), layout != nil,
              let deadline = labSkipRecovery.deadline(context: context) else { return }
        failedRetryFrameID = nil
        traceRetry(.skipImmediate)
        ensureDeadline(context)
        if labSkipNotice == nil {
            let id = UUID(); labSkipNoticeID = id
            labSkipNotice = Task { @MainActor [weak self] in
                while true {
                    let delay = max(0, deadline - CACurrentMediaTime())
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    guard let self, self.labSkipNoticeID == id, self.isCurrent(context), self.layout != nil else { return }
                    if self.labSkipRecovery.shouldWait(context: context, time: CACurrentMediaTime()) { break }
                }
                guard let self, self.labSkipNoticeID == id, self.isCurrent(context), self.layout != nil else { return }
                self.labSkipNotice = nil; self.labSkipNoticeID = nil
                self.presentation.wait(context: context)
            }
        }
        requestNext()
    }

    static func labNonserialEnabled(labAdmitted: Bool, f4: Bool, environment: [String: String]) -> Bool {
        labAdmitted && !f4 && environment["LATENCY_LAB"] == "1" && environment["LATENCY_GPU_PIPELINE"] == "1"
    }

    /// Scheduling state only; the shared ledger remains the authority for permits and receipts.
    struct LabNonserialGate {
        private var inFlight: [UUID: Bool] = [:]
        var canSubmit: Bool { inFlight.count < 2 && inFlight.values.allSatisfy { $0 } }
        var count: Int { inFlight.count }
        mutating func submit(_ frame: UUID) -> Bool {
            guard canSubmit, inFlight[frame] == nil else { return false }
            inFlight[frame] = false; return true
        }
        mutating func completedGPU(_ frame: UUID, succeeded: Bool) -> Bool {
            guard succeeded, inFlight[frame] == false else { return false }
            inFlight[frame] = true; return true
        }
        enum Disposition: Equatable {
            case presented(TimeInterval), rendered(TimeInterval), skipped, retry, expired
        }
        mutating func settle(_ frame: UUID, result: RemoteVideoPresentationLedger.Result) -> Disposition? {
            guard inFlight.removeValue(forKey: frame) != nil else { return nil }
            switch result {
            case .presented(let time): return .presented(time)
            case .rendered(let time): return .rendered(time)
            case .skipped: return .skipped
            case .failed: return .retry
            case .expired: return .expired
            }
        }
        mutating func discard(_ frame: UUID) -> Bool { inFlight.removeValue(forKey: frame) != nil }
        mutating func reset() { inFlight.removeAll() }
    }

    enum RetryDiagnosticReason: String, CaseIterable {
        case acquirerRejected = "acquirer_rejected", drawableNil = "drawable_nil"
        case producerBusy = "producer_busy", producerUnavailable = "producer_unavailable"
        case preparationFailed = "preparation_failed", encodingFailed = "encoding_failed"
        case receiptSkipped = "receipt_skipped", receiptFailed = "receipt_failed", skipImmediate = "skip_immediate"
        case receiptExpired = "receipt_expired", retryScheduled = "retry_scheduled"
    }

    static func retryDiagnosticsEnabled(labAdmitted: Bool, environment: [String: String]) -> Bool {
        labAdmitted && environment["LATENCY_LAB"] == "1" && environment["LATENCY_RENDER_DIAGNOSTICS"] == "1"
    }

    static func retryDiagnosticRecord(reason: RetryDiagnosticReason, time: Double, attempt: Int,
                                      contextGeneration: Int, acquisitionMs: Double? = nil) -> [String: Any]? {
        guard time.isFinite, time >= 0, (0...30).contains(attempt),
              (0...1_000_000).contains(contextGeneration) else { return nil }
        var record: [String: Any] = ["type": "render_retry", "reason": reason.rawValue,
            "time": time, "attempt": attempt, "contextGeneration": contextGeneration]
        if reason == .drawableNil, let acquisitionMs, acquisitionMs.isFinite,
           acquisitionMs >= 0, acquisitionMs <= 60_000 { record["acquisitionMs"] = acquisitionMs }
        return record
    }

    static func retryReason(for admission: RemoteVideoPresentationProducer.Admission) -> RetryDiagnosticReason? {
        switch admission {
        case .busy: return .producerBusy
        case .unavailable: return .producerUnavailable
        case .preparationFailed: return .preparationFailed
        case .encodingFailed: return .encodingFailed
        case .submitted, .unsupportedFrame: return nil
        }
    }

    static func retryReason(for result: RemoteVideoPresentationLedger.Result) -> RetryDiagnosticReason? {
        switch result {
        case .skipped: return .receiptSkipped
        case .failed: return .receiptFailed
        case .expired: return .receiptExpired
        case .presented, .rendered: return nil
        }
    }

    private func traceRetry(_ reason: RetryDiagnosticReason, acquisitionMs: Double? = nil) {
        guard labRetryDiagnostics,
              let record = Self.retryDiagnosticRecord(reason: reason, time: CACurrentMediaTime(),
                  attempt: min(failedAttempts, 30), contextGeneration: retryTraceGeneration,
                  acquisitionMs: acquisitionMs) else { return }
        RemoteVideoLatencyProbe.shared.collector.trace(record)
    }
    #endif

    private func isCurrent(_ context: UUID) -> Bool { active && producer.contextID == context }

    private func requestNext() {
        guard active, phase == .idle, retry == nil, let layout else { return }
        let context = producer.contextID
        guard mailbox.hasPending(context: context) else { return }
        #if DEBUG
        if labSuppressAcquisitionForTesting { labRequestCountForTesting += 1; return }
        if labNonserial && !labGate.canSubmit { return }
        #endif
        ensureDeadline(context)
        let request = UUID(); phase = .acquiring(request)
        #if DEBUG
        let acquisitionRequestedTime = CACurrentMediaTime()
        #endif
        let admitted = RemoteVideoDrawableAcquirer.shared.request(layer: view.metalLayer, size: layout.size) { [weak self] drawable in
            #if DEBUG
            let acquisitionReturnedTime = CACurrentMediaTime()
            #endif
            guard let self, self.isCurrent(context), self.phase == .acquiring(request) else { return }
            self.phase = .idle
            self.refreshLayout()
            guard self.isCurrent(context), self.layout == layout else { return }
            guard let drawable else {
                #if DEBUG
                self.traceRetry(.drawableNil, acquisitionMs: (acquisitionReturnedTime - acquisitionRequestedTime) * 1000)
                #endif
                self.retryLater(context); return
            }
            guard let entry = self.mailbox.takeLatest(context: context) else { return }
            #if DEBUG
            let latency = entry.latency
            if let latency {
                latency.acquisitionRequestedTime = acquisitionRequestedTime
                latency.acquisitionReturnedTime = acquisitionReturnedTime
            }
            if let latency { self.producer.onLatencySubmit = { latency.submittedTime = CACurrentMediaTime() } }
            else { self.producer.onLatencySubmit = nil }
            #endif
            let admission = self.producer.submit(frame: entry.frame, frameID: entry.id, drawable: drawable, contentMode: layout.mode) { [weak self] frame, result in
                self?.received(result, frame: frame, entry: entry, context: context)
            }
            #if DEBUG
            self.producer.onLatencySubmit = nil
            #endif
            guard self.isCurrent(context) else { return }
            switch admission {
            case .submitted:
                self.phase = .submitted(entry.id)
                #if DEBUG
                if self.labNonserial {
                    guard self.labGate.submit(entry.id) else {
                        self.fail(context, message: "The remote screen could not be refreshed. Reconnect to try again.", category: .deadline)
                        return
                    }
                    self.labPending[entry.id] = entry
                } else if let latency { self.submittedLatency = (entry.id, latency) }
                else { self.submittedLatency = nil }
                #endif
            case .busy, .unavailable, .preparationFailed, .encodingFailed:
                #if DEBUG
                if self.labRetryDiagnostics, let reason = Self.retryReason(for: admission) { self.traceRetry(reason) }
                #endif
                self.mailbox.restoreUnlessNewer(entry)
                let realFailure: Bool
                switch admission {
                case .preparationFailed, .encodingFailed: realFailure = true
                default: realFailure = false
                }
                self.retryLater(context, realFailure: realFailure)
            case .unsupportedFrame:
                self.fail(context, message: "This remote screen format is not supported. Reconnect to try again.", category: .unsupportedFrame)
            }
        }
        if !admitted {
            #if DEBUG
            traceRetry(.acquirerRejected)
            #endif
            phase = .idle; retryLater(context, realFailure: false)
        }
    }

    private func received(_ result: RemoteVideoPresentationLedger.Result, frame: UUID,
                          entry: RemoteVideoLatestFrameMailbox<RTCVideoFrame>.Entry, context: UUID) {
        #if DEBUG
        if labNonserial {
            labReceived(result, frame: frame, entry: entry, context: context)
            return
        }
        #endif
        guard isCurrent(context), phase == .submitted(frame) else { return }
        #if DEBUG
        let receiptDeliveryTime = CACurrentMediaTime()
        #endif
        phase = .idle
        #if DEBUG
        if labRetryDiagnostics, let reason = Self.retryReason(for: result) { traceRetry(reason) }
        #endif
        #if DEBUG
        if labSkipRetry, case .skipped = result { mailbox.discard(frame: frame, context: context) }
        #endif
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
            #if DEBUG
            if case .presented = result, let latency = submittedLatency, latency.frame == frame {
                latency.sample.receiptDeliveryTime = receiptDeliveryTime
                RemoteVideoLatencyProbe.shared.presented(latency.sample, time: time)
            }
            submittedLatency = nil
            #endif
            cancelWaits(); failedAttempts = 0; failedRetryFrameID = nil
            if case .presented = result {
                presentation.present(context: context, frame: frame, time: time)
                #if DEBUG
                if presentation.state == .presented(context: context, frame: frame, time: time) { labPresented(context: context, time: time) }
                #endif
            } else {
                presentation.render(context: context, frame: frame, time: time)
                #if DEBUG
                if labSkipRetry { cancelLabSkipNotice() }
                #endif
            }
            if isCurrent(context) { requestNext() }
        case .skipped, .failed:
            #if DEBUG
            if labSkipRetry, case .skipped = result {
                submittedLatency = nil
                labSkipped(context: context)
                return
            }
            #endif
            // Retry the exact latest frame on a fresh drawable. A newer
            // decode wins; failed images never cross a layout context.
            mailbox.restoreUnlessNewer(entry)
            var realFailure = false
            if case .failed = result { realFailure = true }
            retryLater(context, realFailure: realFailure)
        case .expired:
            break // Handled before layout refresh.
        }
    }

    #if DEBUG
    private func labGPUCompleted(context: UUID, frame: UUID, succeeded: Bool) {
        guard labNonserial, isCurrent(context), labGate.completedGPU(frame, succeeded: succeeded) else { return }
        if phase == .submitted(frame) { phase = .idle }
        requestNext()
    }

    private func labDiscarded(context: UUID, frame: UUID) {
        guard labNonserial, isCurrent(context), labGate.discard(frame) else { return }
        labPending.removeValue(forKey: frame)
        if phase == .submitted(frame) { phase = .idle }
        requestNext()
    }

    private func labReceived(_ result: RemoteVideoPresentationLedger.Result, frame: UUID,
                             entry: RemoteVideoLatestFrameMailbox<RTCVideoFrame>.Entry, context: UUID) {
        guard isCurrent(context), labPending[frame]?.id == entry.id,
              let disposition = labGate.settle(frame, result: result) else { return }
        labPending.removeValue(forKey: frame)
        if phase == .submitted(frame) { phase = .idle }
        let receiptDeliveryTime = CACurrentMediaTime()
        if labRetryDiagnostics, let reason = Self.retryReason(for: result) { traceRetry(reason) }
        if labSkipRetry, case .skipped = disposition { mailbox.discard(frame: frame, context: context) }
        switch disposition {
        case .retry, .skipped: failedRetryFrameID = frame
        case .expired:
            fail(context, message: "The remote screen stopped refreshing. Reconnect to try again.", category: .presentationExpired)
            return
        case .presented, .rendered: break
        }
        refreshLayout()
        guard isCurrent(context), layout != nil else { return }
        switch disposition {
        case .presented(let time), .rendered(let time):
            if case .presented = disposition, let latency = entry.latency {
                latency.receiptDeliveryTime = receiptDeliveryTime
                RemoteVideoLatencyProbe.shared.presented(latency, time: time)
            }
            cancelWaits(); failedAttempts = 0; failedRetryFrameID = nil
            if case .presented = disposition {
                presentation.present(context: context, frame: frame, time: time)
                if presentation.state == .presented(context: context, frame: frame, time: time) { labPresented(context: context, time: time) }
            } else {
                presentation.render(context: context, frame: frame, time: time)
                if labSkipRetry { cancelLabSkipNotice() }
            }
            if isCurrent(context) { requestNext() }
        case .skipped:
            if labSkipRetry { labSkipped(context: context) }
            else { mailbox.restoreUnlessNewer(entry); retryLater(context) }
        case .retry:
            mailbox.restoreUnlessNewer(entry)
            retryLater(context)
        case .expired: break
        }
    }
    #endif

    private func retryLater(_ context: UUID, realFailure: Bool = true) {
        guard isCurrent(context), layout != nil else { return }
        #if DEBUG
        if labSkipRetry { cancelLabSkipNotice() }
        #endif
        failedAttempts += 1
        guard failedAttempts <= 30 else {
            fail(context, message: "The remote screen could not be refreshed. Reconnect to try again.", category: .retryExhausted); return
        }
        // A missed drawable or two, common during zoom, is not an interruption: the
        // last picture is still on screen. The deadline still catches a real stall.
        if realFailure || failedAttempts > Self.retriesBeforeWaiting { presentation.wait(context: context) }
        guard isCurrent(context) else { return }
        ensureDeadline(context)
        guard retry == nil else { return }
        #if DEBUG
        traceRetry(.retryScheduled)
        #endif
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
        #if DEBUG
        stopHighRefresh(); f4?.retire()
        cancelLabSkipNotice(); labSkipRecovery.reset()
        view.onLabVisibilityChange = nil
        submittedLatency = nil
        labPending.removeAll(); labGate.reset()
        #endif
        cancelWaits(); mailbox.replaceContext(nil); producer.retire()
        view.onGeometryChange = nil; view.isHidden = true
        presentation.fail(context: context, message: message)
    }
}

#if DEBUG
/// This display link requests the screen refresh rate; frames are still presented on arrival.
private final class RemoteVideoHighRefreshTarget: NSObject {
    @objc func tick() {}
}
#endif

@MainActor
final class RemoteVideoMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    var onGeometryChange: (@MainActor () -> Void)?
    #if DEBUG
    var onLabVisibilityChange: (@MainActor () -> Void)?
    override var isHidden: Bool { didSet { if oldValue != isHidden { onLabVisibilityChange?() } } }
    #endif
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

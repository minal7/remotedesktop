import AVFoundation
import CoreMedia
import Darwin
import Foundation
import ScreenCaptureKit
import os

/// Capture-clock evidence stays separate from delivery time and media time.
/// The display ticks are supplied by WindowServer, not sampled when a queued
/// callback eventually reaches this process.
struct CaptureVideoFrameMetadata: Equatable {
    let displayTimeHostTicks: UInt64
    let captureTimeNanoseconds: Int64
    let presentationTimeNanoseconds: Int64?
    let width: Int
    let height: Int

    static func read(status: Int?, displayTimeHostTicks: UInt64?,
                     presentationTime: CMTime, width: Int, height: Int,
                     observedAtHostTime: UInt64) -> Self? {
        guard status == SCFrameStatus.complete.rawValue,
              let displayTimeHostTicks, displayTimeHostTicks > 0,
              displayTimeHostTicks <= observedAtHostTime,
              width > 0, height > 0,
              let captureTimeNanoseconds = nanoseconds(
                CMClockMakeHostTimeFromSystemUnits(displayTimeHostTicks)) else { return nil }
        return Self(displayTimeHostTicks: displayTimeHostTicks,
                    captureTimeNanoseconds: captureTimeNanoseconds,
                    presentationTimeNanoseconds: nanoseconds(presentationTime),
                    width: width, height: height)
    }

    private static func nanoseconds(_ time: CMTime) -> Int64? {
        guard time.isValid, time.isNumeric, time.epoch == 0,
              time.timescale > 0, time.value >= 0 else { return nil }
        let converted = CMTimeConvertScale(time, timescale: 1_000_000_000, method: .roundTowardZero)
        guard converted.isNumeric, converted.timescale == 1_000_000_000,
              converted.value >= 0 else { return nil }
        return converted.value
    }
}

struct CapturedVideoFrame {
    let imageBuffer: CVPixelBuffer
    let metadata: CaptureVideoFrameMetadata

    init?(sampleBuffer: CMSampleBuffer, observedAtHostTime: UInt64) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let rows = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]], let attachments = rows.first,
              let rawStatus = attachments[.status] as? NSNumber,
              CFGetTypeID(rawStatus) != CFBooleanGetTypeID(),
              let rawDisplayTime = attachments[.displayTime] as? NSNumber,
              CFGetTypeID(rawDisplayTime) != CFBooleanGetTypeID(),
              let status = rawStatus as? Int, rawStatus == NSNumber(value: status),
              let displayTime = rawDisplayTime as? UInt64, rawDisplayTime == NSNumber(value: displayTime),
              let metadata = CaptureVideoFrameMetadata.read(
                status: status, displayTimeHostTicks: displayTime,
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                width: CVPixelBufferGetWidth(imageBuffer), height: CVPixelBufferGetHeight(imageBuffer),
                observedAtHostTime: observedAtHostTime) else { return nil }
        self.imageBuffer = imageBuffer
        self.metadata = metadata
    }
}

/// Used only on ScreenCapture's serial video queue. A delayed or repeated
/// complete sample cannot make the media timeline move backward.
struct CaptureVideoFrameOrder {
    private var last: CaptureVideoFrameMetadata?

    mutating func admit(_ metadata: CaptureVideoFrameMetadata) -> Bool {
        if let last {
            guard metadata.displayTimeHostTicks > last.displayTimeHostTicks,
                  metadata.captureTimeNanoseconds > last.captureTimeNanoseconds else { return false }
        }
        last = metadata
        return true
    }
}

/// Status-only events need no image buffer. In particular, idle means no
/// display change, while blank/suspended explicitly withdraw usable output.
enum CaptureVideoStatus: Equatable {
    case complete, idle, started, blank, suspended, stopped, invalid

    static func read(_ value: Any?) -> Self {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let raw = number as? Int, number == NSNumber(value: raw) else { return .invalid }
        switch raw {
        case SCFrameStatus.complete.rawValue: return .complete
        case SCFrameStatus.idle.rawValue: return .idle
        case SCFrameStatus.started.rawValue: return .started
        case SCFrameStatus.blank.rawValue: return .blank
        case SCFrameStatus.suspended.rawValue: return .suspended
        case SCFrameStatus.stopped.rawValue: return .stopped
        default: return .invalid
        }
    }

    static func read(sampleBuffer: CMSampleBuffer) -> Self {
        guard sampleBuffer.isValid,
              let rows = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]], let row = rows.first else { return .invalid }
        return read(row[.status])
    }
}

/// All accesses occur inside the capture lifecycle gate, including delegate
/// stop callbacks. The observation boundary is conservative: a queued frame
/// captured before a reported loss cannot restore source availability.
struct CaptureVideoAvailability {
    private var attempt: CaptureAttemptLease?
    private var hasDeliveredFrame = false
    private var reportedUnavailable = false
    private var resumeAfterHostTicks: UInt64?

    mutating func recordUnavailable(from attempt: CaptureAttemptLease,
                                    observedAtHostTime: UInt64) -> Bool {
        adopt(attempt)
        let notify = !reportedUnavailable
        reportedUnavailable = true
        resumeAfterHostTicks = max(resumeAfterHostTicks ?? 0, observedAtHostTime)
        return notify
    }

    /// The initial started marker is normal startup. A started marker after
    /// established output withdraws the old image until a new complete frame.
    mutating func recordStarted(from attempt: CaptureAttemptLease,
                                observedAtHostTime: UInt64) -> Bool {
        adopt(attempt)
        guard hasDeliveredFrame else { return false }
        return recordUnavailable(from: attempt, observedAtHostTime: observedAtHostTime)
    }

    func isAvailable(for attempt: CaptureAttemptLease) -> Bool {
        self.attempt == attempt && hasDeliveredFrame && !reportedUnavailable
    }

    func permits(_ metadata: CaptureVideoFrameMetadata) -> Bool {
        resumeAfterHostTicks.map { metadata.displayTimeHostTicks > $0 } ?? true
    }

    mutating func recordDeliveredFrame(from attempt: CaptureAttemptLease) {
        adopt(attempt)
        hasDeliveredFrame = true
        reportedUnavailable = false
    }

    private mutating func adopt(_ attempt: CaptureAttemptLease) {
        guard self.attempt != attempt else { return }
        self.attempt = attempt
        hasDeliveredFrame = false
        reportedUnavailable = false
        // Keep the clock boundary across native stream replacement. An old
        // display image is not made fresh by creating a new SCStream object.
    }
}

enum CaptureSizing {
    static let targetFramesPerSecond = Int32(DesktopVideoQuality.targetFramesPerSecond)

    static func normalized(width: Int, height: Int) -> (width: Int, height: Int) {
        (normalize(width), normalize(height))
    }

    static func backingPixelSize(
        widthInPoints: Double,
        heightInPoints: Double,
        pointPixelScale: Double
    ) -> (width: Int, height: Int) {
        let scale = max(1, pointPixelScale)
        return normalized(
            width: Int((widthInPoints * scale).rounded()),
            height: Int((heightInPoints * scale).rounded()))
    }

    /// Returns the largest even-sized rectangle with the source aspect ratio
    /// that fits the negotiated codec. Searching the small macroblock grid
    /// avoids accidentally crossing an H.264 level limit after 16-pixel
    /// alignment.
    static func encoderSafe(
        width: Int,
        height: Int,
        maximumMacroblocksPerFrame: Int
    ) -> (width: Int, height: Int) {
        let source = normalized(width: width, height: height)
        guard macroblockCount(width: source.width, height: source.height)
                > maximumMacroblocksPerFrame
                || source.width > DesktopVideoQuality.maximumEncodedDimension
                || source.height > DesktopVideoQuality.maximumEncodedDimension else {
            return source
        }

        var best = (width: 2, height: 2)
        var bestArea = 4

        for macroblockHeight in 1...maximumMacroblocksPerFrame {
            let macroblockWidth = maximumMacroblocksPerFrame / macroblockHeight
            guard macroblockWidth > 0 else { continue }

            let scale = min(
                1,
                Double(macroblockWidth * 16) / Double(source.width),
                Double(macroblockHeight * 16) / Double(source.height),
                Double(DesktopVideoQuality.maximumEncodedDimension) / Double(source.width),
                Double(DesktopVideoQuality.maximumEncodedDimension) / Double(source.height))
            let candidate = normalized(
                width: Int((Double(source.width) * scale).rounded(.down)),
                height: Int((Double(source.height) * scale).rounded(.down)))
            let area = candidate.width * candidate.height

            guard macroblockCount(width: candidate.width, height: candidate.height)
                    <= maximumMacroblocksPerFrame,
                  area > bestArea else {
                continue
            }
            best = candidate
            bestArea = area
        }

        return best
    }

    static func macroblockCount(width: Int, height: Int) -> Int {
        ((max(1, width) + 15) / 16) * ((max(1, height) + 15) / 16)
    }

    private static func normalize(_ value: Int) -> Int {
        let even = value & ~1
        return max(2, even == 0 ? 2 : even)
    }
}

/// A peer and each native start have separate identities. Neither can be
/// reconstructed from a stream timestamp or a delayed callback.
struct CaptureOwnerLease: Equatable, Sendable {
    fileprivate let id = UUID()
    fileprivate let retirement = CaptureOwnerRetirement()
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// Retained by the lease so a late close can join its own barrier without
/// waiting for a successor's teardown or retaining an unbounded owner map.
fileprivate final class CaptureOwnerRetirement: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    func finish(with task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        if self.task == nil { self.task = task }
    }
    func barrier() -> Task<Void, Never> {
        lock.lock(); defer { lock.unlock() }
        return task ?? Task {}
    }
}
struct CaptureAttemptLease: Equatable, Sendable { fileprivate let id = UUID(); init() {} }
struct CaptureStopReceipt: Equatable, Sendable {
    fileprivate let owner: CaptureOwnerLease
    fileprivate let attempt: CaptureAttemptLease
}

struct CaptureStreamTeardownFailure: Error {
    let underlying: Error
}

/// Serializes admission with retirement without holding a lock across a native
/// await. The synchronous consumer runs inside the gate: retiring a stream
/// cannot return while that stream is still entering its consumer. Consumers
/// must not synchronously wait for asynchronous start/stop work.
final class CaptureStreamLifecycle<Stream: AnyObject, Context: Sendable>: @unchecked Sendable {
    private final class Attempt: @unchecked Sendable {
        let id = CaptureAttemptLease()
        let owner: CaptureOwnerLease
        var stream: Stream?
        var task: Task<Void, Error>!
        var running = false
        init(owner: CaptureOwnerLease) { self.owner = owner }
    }

    // Recursive only for synchronous consumer-driven retirement on this thread.
    private let lock = NSRecursiveLock()
    private var owner: CaptureOwnerLease?
    private var context: Context?
    private var active: Attempt?
    private var lastStop: CaptureStopReceipt?
    private var teardown: Task<Void, Never>?
    private let stopStream: @Sendable (Stream) async throws -> Void
    private var teardownFailure: Error?

    init(stopStream: @escaping @Sendable (Stream) async throws -> Void) {
        self.stopStream = stopStream
    }

    func beginOwner(context: Context) -> CaptureOwnerLease {
        locked {
            retireOwner()
            let lease = CaptureOwnerLease()
            owner = lease
            self.context = context
            lastStop = nil
            return lease
        }
    }

    /// Concurrent requests from this owner join the same preparation/start.
    /// A replacement waits for its predecessor's native teardown before preparing.
    /// Preparation must create a new stream object for every attempt.
    func start(for owner: CaptureOwnerLease,
               prepare: @escaping @Sendable () async throws -> Stream,
               startStream: @escaping @Sendable (Stream) async throws -> Void) throws -> Task<Void, Error> {
        try locked {
            guard self.owner == owner else { throw CancellationError() }
            if let active { return active.task }
            let attempt = Attempt(owner: owner)
            let predecessor = teardown
            active = attempt
            lastStop = nil
            attempt.task = Task { [self] in
                await predecessor?.value
                do {
                    try requireCurrent(attempt)
                    let stream = try await prepare()
                    try install(stream, for: attempt)
                    // Install before the native await: early output belongs to
                    // this attempt, and retirement must join this call even if
                    // cancellation happens between install and startStream.
                    try await startStream(stream)
                    try finishStart(attempt)
                } catch {
                    retireIfCurrent(attempt)
                    throw error
                }
            }
            return attempt.task
        }
    }

    func endOwner(_ owner: CaptureOwnerLease) -> Task<Void, Never> {
        locked {
            if self.owner == owner { retireOwner() }
            return owner.retirement.barrier()
        }
    }

    func endAll() -> Task<Void, Never> {
        locked {
            retireOwner()
            return teardown ?? Task {}
        }
    }

    private func retireOwner() {
        guard let owner else { return }
        self.owner = nil
        context = nil
        lastStop = nil
        retireAttempt()
        owner.retirement.finish(with: teardown ?? Task {})
    }

    func isRunning(for owner: CaptureOwnerLease) -> Bool {
        withRunningOwner(owner) { _ in }
    }

    @discardableResult
    func withRunningOwner(_ owner: CaptureOwnerLease, _ body: (CaptureAttemptLease) -> Void) -> Bool {
        locked {
            guard self.owner == owner, let active, active.running else { return false }
            body(active.id)
            return true
        }
    }

    @discardableResult
    func withStream(_ stream: Stream, _ body: (Context, CaptureAttemptLease) -> Void) -> Bool {
        locked {
            guard let active, active.owner == owner, active.stream === stream,
                  let context else { return false }
            body(context, active.id)
            return true
        }
    }

    /// Retire before notifying. Deferred handlers need the one-use receipt,
    /// which a new attempt or owner invalidates before starting any native work.
    @discardableResult
    func streamStopped(_ stream: Stream, _ body: (Context, CaptureStopReceipt) -> Void) -> Bool {
        locked {
            guard let active, active.owner == owner, active.stream === stream,
                  let context else { return false }
            let receipt = CaptureStopReceipt(owner: active.owner, attempt: active.id)
            retireAttempt()
            lastStop = receipt
            body(context, receipt)
            return true
        }
    }

    func consumeStop(_ receipt: CaptureStopReceipt, _ body: () -> Void = {}) -> Bool {
        locked {
            guard owner == receipt.owner, active == nil, lastStop == receipt else { return false }
            lastStop = nil
            body()
            return true
        }
    }

    private func requireCurrent(_ attempt: Attempt) throws {
        try locked {
            try Task.checkCancellation()
            guard active === attempt, owner == attempt.owner else { throw CancellationError() }
            // A failed native stop is not a completed resource barrier. Keep
            // replacement capture closed instead of accumulating live streams.
            if let teardownFailure { throw CaptureStreamTeardownFailure(underlying: teardownFailure) }
        }
    }

    private func install(_ stream: Stream, for attempt: Attempt) throws {
        try locked {
            // Retain the prepared stream even on retirement so its outputs are
            // cleaned up by the exact teardown job after this task finishes.
            attempt.stream = stream
            try requireCurrent(attempt)
        }
    }

    private func finishStart(_ attempt: Attempt) throws {
        try locked {
            try requireCurrent(attempt)
            attempt.running = true
        }
    }

    private func retireIfCurrent(_ attempt: Attempt) {
        locked {
            if active === attempt { retireAttempt() }
        }
    }

    /// Must be called under lock. Only this transition schedules native stop.
    /// The join includes preparation and start even when they ignore cancellation.
    private func retireAttempt() {
        guard let attempt = active else { return }
        active = nil
        attempt.task.cancel()
        let task = attempt.task!
        teardown = Task { [self] in
            _ = await task.result
            if let stream = locked({ attempt.stream }) {
                do { try await stopStream(stream) }
                catch { locked { teardownFailure = error } }
            }
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// One availability episode, including initial startup, spans failed starts
/// and starts that produce no usable video. A native await does not extend
/// the deadline or reset the attempt cap.
struct CaptureRecoveryEpisode {
    static let maximumAttempts = 5
    static let timeoutSeconds = DirectInputWire.captureRecoveryTimeoutSeconds
    static let timeout: Duration = .seconds(timeoutSeconds)
    private static let retryDelays: [Duration] = [.milliseconds(250), .seconds(1), .seconds(2), .seconds(5)]

    let id = UUID()
    let deadline: ContinuousClock.Instant
    private let continuingStream: CaptureAttemptLease?
    private(set) var attempts = 0

    init(now: ContinuousClock.Instant, waitingForOutputFrom continuingStream: CaptureAttemptLease? = nil) {
        deadline = now.advanced(by: Self.timeout)
        self.continuingStream = continuingStream
    }

    enum Failure: Equatable {
        case timedOut, attemptsExhausted
        var message: String {
            switch self {
            case .timedOut:
                return "Screen capture did not become available within \(CaptureRecoveryEpisode.timeoutSeconds) seconds. Reconnect to try again."
            case .attemptsExhausted:
                return "Screen capture did not become available after \(CaptureRecoveryEpisode.maximumAttempts) attempts. Reconnect to try again."
            }
        }
    }

    func permitsRecovery(at now: ContinuousClock.Instant) -> Bool { now < deadline }

    func failure(at now: ContinuousClock.Instant) -> Failure? {
        if !permitsRecovery(at: now) { return .timedOut }
        return attempts >= Self.maximumAttempts ? .attemptsExhausted : nil
    }

    func acceptsFrame(lastOutput: CaptureAttemptLease?, running: CaptureAttemptLease,
                      at now: ContinuousClock.Instant) -> Bool {
        (attempts > 0 || continuingStream == running) && permitsRecovery(at: now) && lastOutput == running
    }

    mutating func reserveAttempt(at now: ContinuousClock.Instant) -> Bool {
        guard permitsRecovery(at: now), attempts < Self.maximumAttempts else { return false }
        attempts += 1
        return true
    }

    func retryDelay(at now: ContinuousClock.Instant) -> Duration? {
        guard permitsRecovery(at: now), attempts > 0, attempts < Self.maximumAttempts else { return nil }
        return min(Self.retryDelays[attempts - 1], now.duration(to: deadline))
    }
}

/// Captures the main display as validated video frames and, when opted in,
/// system audio as sample buffers. Consumers handle their own encoder
/// marshalling on the capture queues.
///
/// Not `@MainActor`: callbacks fire on the capture queue and we don't
/// want a per-frame actor hop at 30 fps.
final class ScreenCapture: NSObject, @unchecked Sendable {
    private let videoQueue = DispatchQueue(
        label: "com.threadmark.remotedesktop.host.capture.video",
        qos: .userInteractive)
    private let audioQueue = DispatchQueue(
        label: "com.threadmark.remotedesktop.host.capture.audio",
        qos: .userInteractive)
    private let log = Logger(subsystem: "com.threadmark.remotedesktop.host", category: "capture")
    private var loggedFirstVideoAttempt: CaptureAttemptLease?
    private var loggedFirstAudioAttempt: CaptureAttemptLease?
    private var videoFrameOrder = CaptureVideoFrameOrder()
    private var videoAvailability = CaptureVideoAvailability()

    struct Callbacks: Sendable {
        /// Synchronous consumers run inside the stream ownership gate.
        let onVideoFrame: @Sendable (CapturedVideoFrame, CaptureAttemptLease) -> Void
        let onAudioSample: (@Sendable (CMSampleBuffer) -> Void)?
        let onVideoUnavailable: @Sendable (CaptureAttemptLease) -> Void
        let onStopped: @Sendable (CaptureStopReceipt, Error) -> Void
    }

    private let lifecycle = CaptureStreamLifecycle<SCStream, Callbacks> { stream in
        do { try await stream.stopCapture() }
        catch {
            guard !ScreenCapture.isAlreadyStopped(error) else { return }
            Logger(subsystem: "com.threadmark.remotedesktop.host", category: "capture")
                .error("stop failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    func beginSession(callbacks: Callbacks) -> CaptureOwnerLease {
        lifecycle.beginOwner(context: callbacks)
    }

    func endSession(_ owner: CaptureOwnerLease) -> Task<Void, Never> {
        lifecycle.endOwner(owner)
    }

    @discardableResult
    func consumeStop(_ receipt: CaptureStopReceipt, _ body: () -> Void) -> Bool {
        lifecycle.consumeStop(receipt, body)
    }

    @discardableResult
    func withRunningSession(_ owner: CaptureOwnerLease, _ body: (CaptureAttemptLease, Bool) -> Void) -> Bool {
        lifecycle.withRunningOwner(owner) { attempt in
            body(attempt, videoAvailability.isAvailable(for: attempt))
        }
    }

    enum CaptureError: Error { case noDisplay, outputStopped }

    /// Picks the display containing the menu bar and starts capturing
    /// at up to 30 fps, adding system audio only when enabled. Throws if ScreenCaptureKit
    /// can't start (typically: missing TCC approval).
    func start(
        for owner: CaptureOwnerLease,
        audioEnabled: Bool,
        maximumMacroblocksPerFrame: Int
    ) async throws {
        let task = try lifecycle.start(for: owner, prepare: { [self] in
            try await makeStream(audioEnabled: audioEnabled,
                                 maximumMacroblocksPerFrame: maximumMacroblocksPerFrame)
        }, startStream: { stream in
            try await stream.startCapture()
        })
        try await task.value
        guard lifecycle.isRunning(for: owner) else { throw CancellationError() }
    }

    private func makeStream(audioEnabled: Bool, maximumMacroblocksPerFrame: Int) async throws -> SCStream {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: {
            $0.displayID == CGMainDisplayID()
        }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: [])
        let contentInfo = SCShareableContent.info(for: filter)
        let sourceSize = CaptureSizing.backingPixelSize(
            widthInPoints: Double(contentInfo.contentRect.width),
            heightInPoints: Double(contentInfo.contentRect.height),
            pointPixelScale: Double(contentInfo.pointPixelScale))
        let captureSize = CaptureSizing.encoderSafe(
            width: sourceSize.width,
            height: sourceSize.height,
            maximumMacroblocksPerFrame: maximumMacroblocksPerFrame)

        let config = Self.streamConfiguration(
            width: captureSize.width,
            height: captureSize.height,
            audioEnabled: audioEnabled)

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if audioEnabled {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }

        log.info(
            "capture configured points=\(display.width, privacy: .public)x\(display.height, privacy: .public) backing=\(sourceSize.width, privacy: .public)x\(sourceSize.height, privacy: .public) output=\(captureSize.width, privacy: .public)x\(captureSize.height, privacy: .public) macroblockLimit=\(maximumMacroblocksPerFrame, privacy: .public) fps=\(CaptureSizing.targetFramesPerSecond, privacy: .public) audio=\(audioEnabled, privacy: .public)")
        return s
    }

    func stop() async {
        await lifecycle.endAll().value
    }
}

extension ScreenCapture {
    /// Kept as a pure configuration factory so tests can prove that declining
    /// optional microphone access also disables ScreenCaptureKit audio capture.
    static func streamConfiguration(
        width: Int,
        height: Int,
        audioEnabled: Bool
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CaptureSizing.targetFramesPerSecond)
        config.queueDepth = DesktopVideoQuality.captureQueueDepth
        config.showsCursor = true
        config.capturesAudio = audioEnabled
        if audioEnabled {
            config.sampleRate = 48_000
            config.channelCount = 2
        }
        return config
    }
}

extension ScreenCapture: SCStreamDelegate, SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        lifecycle.withStream(stream) { callbacks, attempt in
            switch type {
            case .screen:
                let observedAt = mach_absolute_time()
                switch CaptureVideoStatus.read(sampleBuffer: sampleBuffer) {
                case .idle: return
                case .started:
                    if videoAvailability.recordStarted(from: attempt, observedAtHostTime: observedAt) {
                        callbacks.onVideoUnavailable(attempt)
                    }
                    return
                case .blank, .suspended, .invalid:
                    reportVideoUnavailable(attempt, observedAtHostTime: observedAt, callbacks: callbacks)
                    return
                case .stopped:
                    log.warning("capture output reported stopped")
                    _ = videoAvailability.recordUnavailable(from: attempt, observedAtHostTime: observedAt)
                    lifecycle.streamStopped(stream) { callbacks, receipt in
                        callbacks.onStopped(receipt, CaptureError.outputStopped)
                    }
                    return
                case .complete: break
                }
                guard let frame = CapturedVideoFrame(sampleBuffer: sampleBuffer, observedAtHostTime: observedAt) else {
                    reportVideoUnavailable(attempt, observedAtHostTime: observedAt, callbacks: callbacks)
                    return
                }
                guard videoAvailability.permits(frame.metadata), videoFrameOrder.admit(frame.metadata) else { return }
                videoAvailability.recordDeliveredFrame(from: attempt)
                if loggedFirstVideoAttempt != attempt {
                    loggedFirstVideoAttempt = attempt
                    let pixelFormat = CVPixelBufferGetPixelFormatType(frame.imageBuffer)
                    let macroblocks = CaptureSizing.macroblockCount(width: frame.metadata.width, height: frame.metadata.height)
                    log.info(
                        "received first video sample effective=\(frame.metadata.width, privacy: .public)x\(frame.metadata.height, privacy: .public) macroblocks=\(macroblocks, privacy: .public) pixelFormat=\(pixelFormat, privacy: .public)")
                }
                callbacks.onVideoFrame(frame, attempt)
            case .audio:
                guard sampleBuffer.isValid else { return }
                if loggedFirstAudioAttempt != attempt,
                   let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
                    loggedFirstAudioAttempt = attempt
                    let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
                    log.info(
                        "received first system audio sample sr=\(format.sampleRate, privacy: .public) ch=\(format.channelCount, privacy: .public) frames=\(CMSampleBufferGetNumSamples(sampleBuffer), privacy: .public)")
                }
                callbacks.onAudioSample?(sampleBuffer)
            case .microphone: break
            @unknown default: break
            }
        }
    }

    private func reportVideoUnavailable(_ attempt: CaptureAttemptLease,
                                        observedAtHostTime: UInt64, callbacks: Callbacks) {
        guard videoAvailability.recordUnavailable(from: attempt, observedAtHostTime: observedAtHostTime) else { return }
        log.warning("capture output unavailable; waiting for a new complete frame")
        callbacks.onVideoUnavailable(attempt)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lifecycle.streamStopped(stream) { callbacks, receipt in
            _ = videoAvailability.recordUnavailable(from: receipt.attempt, observedAtHostTime: mach_absolute_time())
            if Self.isSystemStopped(error) {
                log.warning("stream stopped by the system: \(String(describing: error), privacy: .public)")
            } else {
                log.error("stream stopped: \(String(describing: error), privacy: .public)")
            }
            // Intentional stop and foreign streams are already outside the
            // gate. Even an unexpected 'already stopped' must retire readiness.
            callbacks.onStopped(receipt, error)
        }
    }
}

extension ScreenCapture {
    static func isAlreadyStopped(_ error: Error) -> Bool {
        let nsError = error as NSError
        return isStreamError(nsError, code: -3808)
    }

    static func isRecoverableStop(_ error: Error) -> Bool {
        if let captureError = error as? CaptureError, case .outputStopped = captureError { return true }
        return isSystemStopped(error)
    }

    static func isSystemStopped(_ error: Error) -> Bool {
        let nsError = error as NSError
        return isStreamError(nsError, code: -3821)
    }

    private static func isStreamError(_ error: NSError, code: Int) -> Bool {
        error.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && error.code == code
    }
}

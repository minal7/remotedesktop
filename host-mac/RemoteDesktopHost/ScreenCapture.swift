import AVFoundation
import CoreMedia
import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit
import os

/// A reported configuration change is a boundary even when native dimensions
/// later return to their old values. Native getters run outside this lock.
final class CaptureDisplayChangeFence: @unchecked Sendable {
    private let lock = NSLock()
    private var registered = false
    private var failed = false
    private var generation = UUID()
    private var changingDisplays: Set<CGDirectDisplayID> = []
    private static let maximumPendingDisplays = 64

    func completeRegistration(succeeded: Bool) {
        lock.withLock {
            guard !registered, !failed else { return }
            registered = succeeded; failed = !succeeded
            generation = UUID()
        }
    }

    func record(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        lock.withLock {
            guard !failed else { return }
            generation = UUID()
            guard display != kCGNullDirectDisplay else { failed = true; return }
            if flags.contains(.beginConfigurationFlag) {
                guard changingDisplays.contains(display) || changingDisplays.count < Self.maximumPendingDisplays else {
                    failed = true; changingDisplays.removeAll(); return
                }
                changingDisplays.insert(display)
            } else { changingDisplays.remove(display) }
        }
    }

    var current: UUID? {
        lock.withLock { registered && !failed && changingDisplays.isEmpty ? generation : nil }
    }

    func isCurrent(_ expected: UUID) -> Bool { current == expected }

    func sample<Value>(_ read: (UUID) -> Value?) -> Value? {
        guard let before = current, let value = read(before), isCurrent(before) else { return nil }
        return value
    }
}

private let captureDisplayReconfigurationCallback: CGDisplayReconfigurationCallBack = { display, flags, context in
    guard let context else { return }
    Unmanaged<CaptureDisplayChangeMonitor>.fromOpaque(context).takeUnretainedValue()
        .record(display: display, flags: flags)
}

/// One process-lifetime registration keeps the C callback context alive. Each
/// capturer owns only a removable weak subscription. Delivery is coalesced and
/// never calls capture/injection code on the native reconfiguration callback.
private final class CaptureDisplayChangeMonitor: @unchecked Sendable {
    static let shared = CaptureDisplayChangeMonitor()
    let fence = CaptureDisplayChangeFence()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.threadmark.remotedesktop.host.display-change")
    private var observers: [UUID: @Sendable () -> Void] = [:]
    private var deliveryScheduled = false

    private init() {
        let result = CGDisplayRegisterReconfigurationCallback(captureDisplayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque())
        fence.completeRegistration(succeeded: result == .success)
    }

    final class Observation {
        private let monitor: CaptureDisplayChangeMonitor
        private let id: UUID
        fileprivate init(monitor: CaptureDisplayChangeMonitor, id: UUID) { self.monitor = monitor; self.id = id }
        deinit { monitor.remove(id) }
    }

    func observe(_ callback: @escaping @Sendable () -> Void) -> Observation {
        let id = UUID()
        lock.withLock { observers[id] = callback }
        return Observation(monitor: self, id: id)
    }

    private func remove(_ id: UUID) { _ = lock.withLock { observers.removeValue(forKey: id) } }

    func record(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        fence.record(display: display, flags: flags)
        let schedule = lock.withLock {
            guard !deliveryScheduled else { return false }
            deliveryScheduled = true
            return true
        }
        if schedule { queue.async { [self] in deliver() } }
    }

    private func deliver() {
        let pending = lock.withLock {
            deliveryScheduled = false
            return Array(observers.values)
        }
        for callback in pending { callback() }
    }
}

/// One native display snapshot, independent of AppKit's key-window screen.
/// Integer logical bounds make the wire-to-global transform exact.
struct CaptureDisplayState: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let originX: Int
    let originY: Int
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let rotation: Double
    let configuration: UUID?

    init?(displayID: CGDirectDisplayID, bounds: CGRect, pixelWidth: Int, pixelHeight: Int, rotation: Double,
          configuration: UUID? = nil) {
        guard displayID != kCGNullDirectDisplay,
              let x = Int32(exactly: bounds.origin.x), let y = Int32(exactly: bounds.origin.y),
              let width = Int32(exactly: bounds.width), let height = Int32(exactly: bounds.height),
              width > 0, height > 0, pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= Int(Int32.max), pixelHeight <= Int(Int32.max),
              rotation.isFinite, [0.0, 90, 180, 270].contains(rotation) else { return nil }
        self.displayID = displayID
        originX = Int(x); originY = Int(y); self.width = Int(width); self.height = Int(height)
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.rotation = rotation
        self.configuration = configuration
    }

    static func read(_ displayID: CGDirectDisplayID) -> Self? {
        CaptureDisplayChangeMonitor.shared.fence.sample { configuration in
            guard CGDisplayIsOnline(displayID) != 0, let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
            return Self(displayID: displayID, bounds: CGDisplayBounds(displayID),
                        pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, rotation: CGDisplayRotation(displayID),
                        configuration: configuration)
        }
    }
}

struct CaptureDisplayGeometry: Equatable, Sendable {
    /// One descriptor instance per native attempt, even if a later display
    /// has identical dimensions. Late invalidation cannot retire that successor.
    let id = UUID()
    let state: CaptureDisplayState
    let backingScale: Double
    let backingWidth: Int
    let backingHeight: Int

    init?(state: CaptureDisplayState, contentSizeInPoints: CGSize, backingScale: Double) {
        guard contentSizeInPoints.width == CGFloat(state.width), contentSizeInPoints.height == CGFloat(state.height),
              backingScale.isFinite, (1...4).contains(backingScale) else { return nil }
        let width = Double(state.width) * backingScale, height = Double(state.height) * backingScale
        guard width <= Double(Int32.max), height <= Double(Int32.max) else { return nil }
        self.state = state; self.backingScale = backingScale
        backingWidth = Int(width.rounded()); backingHeight = Int(height.rounded())
    }

    func matches(_ current: CaptureDisplayState?) -> Bool { current == state }

    /// The phone sends coordinates within the advertised logical display.
    /// Native rotation is already reflected in the global logical bounds.
    func map(_ message: ControlMessage) -> ControlMessage? {
        switch message {
        case .pointer(let x, let y, let buttons):
            guard contains(x: x, y: y) else { return nil }
            return .pointer(x: state.originX + x, y: state.originY + y, buttons: buttons)
        case .scroll(let x, let y, let dx, let dy, let phase):
            guard contains(x: x, y: y) else { return nil }
            return .scroll(x: state.originX + x, y: state.originY + y, dx: dx, dy: dy, phase: phase)
        case .key, .text: return message
        case .hello, .qos, .bye: return nil
        }
    }

    private func contains(x: Int, y: Int) -> Bool {
        x >= 0 && x < state.width && y >= 0 && y < state.height
    }
}

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

/// ScreenCaptureKit reports contentRect in surface points. scaleFactor
/// converts those points to pixels; contentScale describes source scaling
/// and must not be multiplied into that already placed rectangle again.
struct CaptureVideoPlacement: Equatable {
    let contentRect: CGRect
    let scaleFactor: Double
    let contentScale: Double
    let presenterOverlayRect: CGRect?

    private init(contentRect: CGRect, scaleFactor: Double, contentScale: Double, presenterOverlayRect: CGRect?) {
        self.contentRect = contentRect; self.scaleFactor = scaleFactor
        self.contentScale = contentScale; self.presenterOverlayRect = presenterOverlayRect
    }

    static func read(_ attachments: [SCStreamFrameInfo: Any]) -> Self? {
        guard let rect = rectangle(attachments[.contentRect]), rect.size.width > 0, rect.size.height > 0,
              let scale = number(attachments[.scaleFactor]), (1...4).contains(scale),
              let contentScale = number(attachments[.contentScale]), contentScale > 0 else { return nil }
        var overlay: CGRect?
        if #available(macOS 14.2, *), let raw = attachments[.presenterOverlayContentRect] {
            // ScreenCaptureKit uses CGRect.null when no presenter overlay is
            // present. Its infinite origin is a sentinel, not content geometry.
            if !isNullRectangle(raw) {
                guard let value = rectangle(raw), value.size.width >= 0, value.size.height >= 0 else { return nil }
                overlay = value
            }
        }
        return Self(contentRect: rect, scaleFactor: scale, contentScale: contentScale, presenterOverlayRect: overlay)
    }

    /// Full-display input currently supports a full output surface. Reject
    /// padding, crop/overlay placement and mismatched source density before
    /// such a frame can authorize input or reach the encoder.
    func coversFullDisplaySurface(width: Int, height: Int, displayScale: Double) -> Bool {
        guard width > 0, height > 0, displayScale.isFinite,
              abs(scaleFactor - displayScale) <= 0.000001,
              presenterOverlayRect == nil || presenterOverlayRect == .zero else { return false }
        let pixels = [Double(contentRect.origin.x) * scaleFactor,
                      Double(contentRect.origin.y) * scaleFactor,
                      Double(contentRect.width) * scaleFactor,
                      Double(contentRect.height) * scaleFactor]
        let expected = [0.0, 0.0, Double(width), Double(height)]
        // Allow subpixel floating-point serialization error, not a pixel of
        // hidden padding. Native metadata behavior still needs qualification.
        return zip(pixels, expected).allSatisfy { actual, wanted in
            actual.isFinite && abs(actual - wanted) <= 0.001
        }
    }

    private static func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func rectangle(_ raw: Any?) -> CGRect? {
        guard let dictionary = raw as? [String: Any], !dictionary.isEmpty,
              dictionary.values.allSatisfy({ number($0) != nil }),
              let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite else { return nil }
        return rect
    }

    private static func isNullRectangle(_ raw: Any) -> Bool {
        guard let dictionary = raw as? [String: Any],
              Set(dictionary.keys) == Set(["X", "Y", "Width", "Height"]) else { return false }
        let values = ["X", "Y", "Width", "Height"].compactMap { key -> Double? in
            guard let value = dictionary[key] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return value.doubleValue
        }
        return values == [Double.infinity, Double.infinity, 0, 0]
    }
}

struct CapturedVideoFrame {
    let imageBuffer: CVPixelBuffer
    let metadata: CaptureVideoFrameMetadata
    let placement: CaptureVideoPlacement
    #if DEBUG
    var latencyDisplaySize: (width: Int, height: Int)? = nil
    #endif

    /// A complete native sample can arrive just before its WindowServer
    /// display time. Wait on the serial capture queue until that time instead
    /// of accepting future evidence or discarding the only initial frame.
    init?(sampleBuffer: CMSampleBuffer) {
        guard CaptureVideoStatus.read(sampleBuffer: sampleBuffer) == .complete,
              let rows = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = rows.first?[.displayTime] as? NSNumber,
              CFGetTypeID(raw) != CFBooleanGetTypeID(),
              let displayTime = raw as? UInt64, raw == NSNumber(value: displayTime),
              let observedAt = CaptureVideoPresentationAdmission.observationTime(
                displayTimeHostTicks: displayTime,
                now: { mach_absolute_time() },
                waitUntil: { mach_wait_until($0) == KERN_SUCCESS }) else { return nil }
        self.init(sampleBuffer: sampleBuffer, observedAtHostTime: observedAt)
    }

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
                observedAtHostTime: observedAtHostTime),
              let placement = CaptureVideoPlacement.read(attachments) else { return nil }
        self.imageBuffer = imageBuffer
        self.metadata = metadata
        self.placement = placement
    }
}

enum CaptureVideoPresentationAdmission {
    // At most one 60 Hz display interval. This bounds queue blocking; it does
    // not allow the existing metadata validator to accept a future timestamp.
    static let maximumLeadTicks = CMClockConvertHostTimeToSystemUnits(CMTime(value: 1, timescale: 60))

    static func observationTime(displayTimeHostTicks: UInt64, now: () -> UInt64,
                                waitUntil: (UInt64) -> Bool) -> UInt64? {
        guard displayTimeHostTicks > 0 else { return nil }
        let arrivedAt = now()
        if displayTimeHostTicks > arrivedAt {
            guard displayTimeHostTicks - arrivedAt <= maximumLeadTicks,
                  waitUntil(displayTimeHostTicks) else { return nil }
        }
        let observedAt = now()
        guard observedAt >= arrivedAt, displayTimeHostTicks <= observedAt else { return nil }
        return observedAt
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
    let attempt: CaptureAttemptLease
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
    func withRunningStream(_ owner: CaptureOwnerLease, _ body: (CaptureAttemptLease, Stream) -> Void) -> Bool {
        locked {
            guard self.owner == owner, let active, active.running, let stream = active.stream else { return false }
            body(active.id, stream)
            return true
        }
    }

    /// A lookup is not admission. Consumers must recheck the returned object
    /// through withStream/streamStopped before acting on its context.
    func stream(matching predicate: (Stream) -> Bool) -> Stream? {
        locked {
            guard let active, active.owner == owner, let stream = active.stream,
                  predicate(stream) else { return nil }
            return stream
        }
    }

    @discardableResult
    func withCurrentStream(_ body: (Context, CaptureAttemptLease, Stream) -> Void) -> Bool {
        locked {
            guard let active, active.owner == owner, let stream = active.stream, let context else { return false }
            body(context, active.id, stream)
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
    private final class NativeStream: @unchecked Sendable {
        let stream: SCStream
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        let display: CaptureDisplayGeometry
        init(stream: SCStream, filter: SCContentFilter, configuration: SCStreamConfiguration, display: CaptureDisplayGeometry) {
            self.stream = stream; self.filter = filter; self.configuration = configuration; self.display = display
        }
    }

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
    private var displayObservation: CaptureDisplayChangeMonitor.Observation?

    override init() {
        super.init()
        // Ordinary host-session fixtures must not register desktop observers.
        // Actual native capture still requires the native fence in read().
        if !HostRuntimeContext.isRunningUnitTests {
            displayObservation = CaptureDisplayChangeMonitor.shared.observe { [weak self] in
                self?.handleDisplayConfigurationChange()
            }
        }
    }

    struct Callbacks: Sendable {
        /// Synchronous consumers run inside the stream ownership gate.
        let onVideoFrame: @Sendable (CapturedVideoFrame, CaptureAttemptLease) -> Void
        let onAudioSample: (@Sendable (CMSampleBuffer) -> Void)?
        let onVideoUnavailable: @Sendable (CaptureAttemptLease) -> Void
        let onStopped: @Sendable (CaptureStopReceipt, Error) -> Void
    }

    private let lifecycle = CaptureStreamLifecycle<NativeStream, Callbacks> { native in
        do { try await native.stream.stopCapture() }
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
    func withRunningSession(_ owner: CaptureOwnerLease, _ body: (CaptureAttemptLease, Bool, CaptureDisplayGeometry) -> Void) -> Bool {
        lifecycle.withRunningStream(owner) { attempt, native in
            guard native.display.matches(CaptureDisplayState.read(native.display.state.displayID)) else {
                retireChangedDisplay(native, attempt: attempt)
                return
            }
            body(attempt, videoAvailability.isAvailable(for: attempt), native.display)
        }
    }

    /// Also called before direct-input admission. Posting independently
    /// resamples this same display, without acquiring the capture gate.
    func invalidateChangedDisplay(for owner: CaptureOwnerLease) {
        withRunningSession(owner) { _, _, _ in }
    }

    func invalidateDisplay(for owner: CaptureOwnerLease, matching display: CaptureDisplayGeometry) {
        lifecycle.withRunningStream(owner) { attempt, native in
            guard native.display == display else { return }
            retireChangedDisplay(native, attempt: attempt)
        }
    }

    enum CaptureError: Error { case noDisplay, invalidDisplayGeometry, displayChanged, outputStopped }

    /// Picks the display containing the menu bar and starts capturing
    /// at the requested rate, adding system audio only when enabled. Throws if ScreenCaptureKit
    /// can't start (typically: missing TCC approval).
    func start(
        for owner: CaptureOwnerLease,
        audioEnabled: Bool,
        maximumMacroblocksPerFrame: Int,
        framesPerSecond: Int32 = CaptureSizing.targetFramesPerSecond
    ) async throws {
        let task = try lifecycle.start(for: owner, prepare: { [self] in
            try await makeStream(audioEnabled: audioEnabled,
                                 maximumMacroblocksPerFrame: maximumMacroblocksPerFrame,
                                 framesPerSecond: framesPerSecond)
        }, startStream: { native in
            guard native.display.matches(CaptureDisplayState.read(native.display.state.displayID)) else {
                throw CaptureError.displayChanged
            }
            try await native.stream.startCapture()
        })
        try await task.value
        guard lifecycle.isRunning(for: owner) else { throw CancellationError() }
    }

    private func makeStream(audioEnabled: Bool, maximumMacroblocksPerFrame: Int, framesPerSecond: Int32) async throws -> NativeStream {
        let fence = CaptureDisplayChangeMonitor.shared.fence
        guard let configuration = fence.current else { throw CaptureError.invalidDisplayGeometry }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        guard fence.isCurrent(configuration) else { throw CaptureError.displayChanged }
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
        guard let state = CaptureDisplayState.read(display.displayID), state.configuration == configuration,
              let geometry = CaptureDisplayGeometry(state: state, contentSizeInPoints: contentInfo.contentRect.size,
                                                     backingScale: Double(contentInfo.pointPixelScale)) else {
            throw CaptureError.invalidDisplayGeometry
        }
        let sourceSize = CaptureSizing.normalized(width: geometry.backingWidth, height: geometry.backingHeight)
        let captureSize = CaptureSizing.encoderSafe(
            width: sourceSize.width,
            height: sourceSize.height,
            maximumMacroblocksPerFrame: maximumMacroblocksPerFrame)

        let config = Self.streamConfiguration(
            width: captureSize.width,
            height: captureSize.height,
            audioEnabled: audioEnabled, framesPerSecond: framesPerSecond)

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if audioEnabled {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }

        log.info(
            "capture configured points=\(display.width, privacy: .public)x\(display.height, privacy: .public) backing=\(sourceSize.width, privacy: .public)x\(sourceSize.height, privacy: .public) output=\(captureSize.width, privacy: .public)x\(captureSize.height, privacy: .public) macroblockLimit=\(maximumMacroblocksPerFrame, privacy: .public) fps=\(framesPerSecond, privacy: .public) audio=\(audioEnabled, privacy: .public)")
        return NativeStream(stream: s, filter: filter, configuration: config, display: geometry)
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
        audioEnabled: Bool,
        framesPerSecond: Int32 = CaptureSizing.targetFramesPerSecond
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.scalesToFit = true
        // Even codec sizes can differ slightly from the logical display's
        // aspect ratio. Fill the surface; the phone restores the logical
        // aspect ratio inside its shared video/input rectangle.
        config.preservesAspectRatio = false
        config.destinationRect = CGRect(x: 0, y: 0, width: width, height: height)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.minimumFrameInterval = CMTime(
            value: 1,
            timescale: framesPerSecond)
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
        guard let native = lifecycle.stream(matching: { $0.stream === stream }) else { return }
        lifecycle.withStream(native) { callbacks, attempt in
            switch type {
            case .screen:
                guard native.display.matches(CaptureDisplayState.read(native.display.state.displayID)) else {
                    retireChangedDisplay(native, attempt: attempt)
                    return
                }
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
                    lifecycle.streamStopped(native) { callbacks, receipt in
                        callbacks.onStopped(receipt, CaptureError.outputStopped)
                    }
                    return
                case .complete: break
                }
                guard var frame = CapturedVideoFrame(sampleBuffer: sampleBuffer),
                      frame.metadata.width == native.configuration.width,
                      frame.metadata.height == native.configuration.height,
                      frame.placement.coversFullDisplaySurface(width: frame.metadata.width,
                        height: frame.metadata.height, displayScale: native.display.backingScale) else {
                    reportVideoUnavailable(attempt, observedAtHostTime: observedAt, callbacks: callbacks)
                    return
                }
                #if DEBUG
                if LatencyStatsCollector.enabled, native.display.state.displayID == CGMainDisplayID() {
                    frame.latencyDisplaySize = (native.display.state.width, native.display.state.height)
                }
                #endif
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

    private func retireChangedDisplay(_ native: NativeStream, attempt: CaptureAttemptLease) {
        _ = videoAvailability.recordUnavailable(from: attempt, observedAtHostTime: mach_absolute_time())
        lifecycle.streamStopped(native) { callbacks, receipt in
            callbacks.onStopped(receipt, CaptureError.displayChanged)
        }
    }

    private func handleDisplayConfigurationChange() {
        lifecycle.withCurrentStream { _, attempt, native in
            // A queued notification rechecks the latest token. It cannot
            // retire a replacement already prepared under that configuration.
            guard !native.display.matches(CaptureDisplayState.read(native.display.state.displayID)) else { return }
            retireChangedDisplay(native, attempt: attempt)
        }
    }

    private func reportVideoUnavailable(_ attempt: CaptureAttemptLease,
                                        observedAtHostTime: UInt64, callbacks: Callbacks) {
        guard videoAvailability.recordUnavailable(from: attempt, observedAtHostTime: observedAtHostTime) else { return }
        log.warning("capture output unavailable; waiting for a new complete frame")
        callbacks.onVideoUnavailable(attempt)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard let native = lifecycle.stream(matching: { $0.stream === stream }) else { return }
        lifecycle.streamStopped(native) { callbacks, receipt in
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
        if let captureError = error as? CaptureError {
            switch captureError {
            case .outputStopped, .displayChanged: return true
            case .noDisplay, .invalidDisplayGeometry: return false
            }
        }
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

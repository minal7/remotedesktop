#if DEBUG
import CoreVideo
import Foundation
import LiveKitWebRTC
import UIKit

/// The monitoring switch is process-wide, so overlapping probes share a lease.
@MainActor
final class LatencyBatteryMonitoringLease {
    static let shared = LatencyBatteryMonitoringLease(
        get: { UIDevice.current.isBatteryMonitoringEnabled },
        set: { UIDevice.current.isBatteryMonitoringEnabled = $0 })

    private let get: () -> Bool
    private let set: (Bool) -> Void
    private var tokens: Set<UUID> = []
    private var enabledByLease = false

    init(get: @escaping () -> Bool, set: @escaping (Bool) -> Void) {
        self.get = get; self.set = set
    }

    func acquire() -> UUID {
        if tokens.isEmpty {
            enabledByLease = !get()
            if enabledByLease { set(true) }
        }
        let token = UUID()
        tokens.insert(token)
        return token
    }

    func release(_ token: UUID) {
        guard tokens.remove(token) != nil, tokens.isEmpty else { return }
        if enabledByLease { set(false) }
        enabledByLease = false
    }
}

/// Debug probe stores only timestamps and the synthetic counter, never pixels.
final class RemoteVideoLatencyProbe: @unchecked Sendable {
    static let shared = RemoteVideoLatencyProbe()
    private static let processMarkerSamplingEnabled = markerSamplingEnabled(environment: ProcessInfo.processInfo.environment)
    private let lock = NSLock()
    final class FrameSample: @unchecked Sendable {
        let session: UUID
        let collector: LatencyStatsCollector
        let displayGeneration: UUID
        let decodeTime: Double
        let marker: Int?
        var submittedTime: Double?
        var acquisitionRequestedTime: Double?
        var acquisitionReturnedTime: Double?
        var receiptDeliveryTime: Double?
        init(session: UUID, collector: LatencyStatsCollector, displayGeneration: UUID, decodeTime: Double, marker: Int?) {
            self.session = session; self.collector = collector; self.displayGeneration = displayGeneration
            self.decodeTime = decodeTime; self.marker = marker
        }
    }
    private var session = UUID()
    private var storedCollector = LatencyStatsCollector(side: "client")
    var collector: LatencyStatsCollector { lock.lock(); defer { lock.unlock() }; return storedCollector }
    func reset() {
        let nextSession = UUID()
        lock.lock(); let previousCollector = storedCollector; session = nextSession; displayGeneration = UUID(); storedCollector = LatencyStatsCollector(side: "client"); let nextCollector = storedCollector; displayPoints = nil; renderSamples.removeAll(); clockReady = false; lastMarker = nil; lastMarkerPresentation = nil; lock.unlock()
        let now = ProcessInfo.processInfo.systemUptime
        previousCollector.trace(["type": "collector_reset", "time": now, "boundary": "old", "nextSession": nextSession.uuidString])
        nextCollector.trace(["type": "collector_reset", "time": now, "boundary": "new", "nextSession": nextSession.uuidString])
    }
    private var displayPoints: (Double, Double)?
    private var displayGeneration = UUID()
    private var renderSamples: [Double] = []
    private var clockReady = false
    private var lastMarker: Int?
    private var lastMarkerPresentation: Double?
    func hasRecentMarker(now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let time = lastMarkerPresentation, now >= time else { return false }
        return now - time < 0.5
    }
    func markClockReady() { lock.lock(); clockReady = true; lock.unlock() }

    func setDisplay(_ display: DisplayInfo) {
        let valid = display.fullDisplaySurface && display.scale.isFinite && display.scale > 0 && display.w > 0 && display.h > 0
        let next: (Double, Double)? = valid ? (Double(display.w), Double(display.h)) : nil
        lock.lock(); defer { lock.unlock() }
        let unchanged = next != nil && displayPoints?.0 == next?.0 && displayPoints?.1 == next?.1
        guard !unchanged else { return }
        displayPoints = next
        displayGeneration = UUID()
        lastMarker = nil
        lastMarkerPresentation = nil
    }

    static func markerSamplingEnabled(environment: [String: String]) -> Bool {
        !(environment["LATENCY_LAB"] == "1" && environment["LATENCY_SKIP_MARKER_SAMPLING"] == "1")
    }

    func capture(_ frame: RTCVideoFrame, decodedAt: Double) -> FrameSample {
        lock.lock()
        let capturedSession = session, capturedCollector = storedCollector
        let generation = displayGeneration, dimensions = displayPoints
        lock.unlock()
        let marker: Int?
        if LatencyStatsCollector.enabled, Self.processMarkerSamplingEnabled,
           frame.rotation.rawValue == 0,
           let native = frame.buffer as? RTCCVPixelBuffer, let (width, height) = dimensions {
            marker = Self.sampleMarker(pixelBuffer: native.pixelBuffer,
                cropX: Int(native.cropX), cropY: Int(native.cropY),
                cropWidth: Int(native.cropWidth), cropHeight: Int(native.cropHeight),
                screenWidth: width, screenHeight: height)
        } else { marker = nil }
        return FrameSample(session: capturedSession, collector: capturedCollector,
                           displayGeneration: generation, decodeTime: decodedAt, marker: marker)
    }

    func snapshot(decodedAt: Double, marker: Int?) -> FrameSample {
        lock.lock(); defer { lock.unlock() }
        return FrameSample(session: session, collector: storedCollector, displayGeneration: displayGeneration,
                           decodeTime: decodedAt, marker: marker)
    }

    func isCurrent(_ sample: FrameSample) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sample.session == session && sample.collector === storedCollector && sample.displayGeneration == displayGeneration
    }

    static func sampleMarker(pixelBuffer: CVPixelBuffer, cropX: Int, cropY: Int,
                             cropWidth: Int, cropHeight: Int,
                             screenWidth: Double, screenHeight: Double) -> Int? {
        LatencyMarkerSampler.sample(pixelBuffer: pixelBuffer, cropX: cropX, cropY: cropY,
            cropWidth: cropWidth, cropHeight: cropHeight, screenWidth: screenWidth, screenHeight: screenHeight)
    }

    func presented(_ sample: FrameSample, time: Double) {
        guard let submitted = sample.submittedTime, time > 0,
              time >= sample.decodeTime, submitted >= sample.decodeTime else { return }
        lock.lock()
        guard sample.session == session, sample.collector === storedCollector,
              sample.displayGeneration == displayGeneration else { lock.unlock(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if sample.marker != nil, now >= sample.decodeTime, now - sample.decodeTime < 0.5 {
            lastMarkerPresentation = now
        }
        let newMarker: Int?
        if clockReady, let marker = sample.marker, marker != lastMarker { lastMarker = marker; newMarker = marker }
        else { newMarker = nil }
        renderSamples.append((time - sample.decodeTime) * 1000)
        if renderSamples.count > 600 { renderSamples.removeFirst(renderSamples.count - 600) }
        lock.unlock()
        sample.collector.trace(Self.renderRecord(sample, submitted: submitted, presented: time))
        if let newMarker { sample.collector.trace(["type": "marker", "marker_id": newMarker, "decodeTime": sample.decodeTime, "presentedTime": time]) }
    }

    static func renderRecord(_ sample: FrameSample, submitted: Double, presented: Double) -> [String: Any] {
        var record: [String: Any] = ["type": "render", "decodeTime": sample.decodeTime,
                                     "submittedTime": submitted, "presentedTime": presented]
        if let value = sample.acquisitionRequestedTime, value.isFinite { record["acquisitionRequestedTime"] = value }
        if let value = sample.acquisitionReturnedTime, value.isFinite { record["acquisitionReturnedTime"] = value }
        if let value = sample.receiptDeliveryTime, value.isFinite { record["receiptDeliveryTime"] = value }
        return record
    }

    func renderPercentiles() -> (Double, Double)? {
        lock.lock(); let values = renderSamples.sorted(); lock.unlock()
        guard !values.isEmpty else { return nil }
        return (values[Int(Double(values.count - 1) * 0.50)], values[Int(Double(values.count - 1) * 0.95)])
    }
}
struct LatencyClockEstimate {
    let offset: Double
    let rtt: Double
    let uncertainty: Double
    static func calculate(_ samples: [(rtt: Double, offset: Double)]) -> LatencyClockEstimate? {
        guard samples.count == 50, samples.allSatisfy({ $0.rtt.isFinite && $0.rtt >= 0 && $0.offset.isFinite }) else { return nil }
        let selected = samples.sorted { $0.rtt < $1.rtt }.prefix(13)
        let offset = selected.map(\.offset).reduce(0, +) / Double(selected.count)
        let rtt = selected.map(\.rtt).reduce(0, +) / Double(selected.count)
        let spread = selected.map { abs($0.offset - offset) }.max() ?? 0
        return LatencyClockEstimate(offset: offset, rtt: rtt, uncertainty: rtt / 2 + spread)
    }
}
#endif

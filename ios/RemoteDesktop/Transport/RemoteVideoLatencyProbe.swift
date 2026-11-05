#if DEBUG
import CoreVideo
import Accelerate
import CryptoKit
import Foundation
import LiveKitWebRTC
import QuartzCore
import UIKit

/// Synthetic fixture reference; the client never persists decoded pixels.
struct LatencyTextReference: Decodable {
    let version: Int, screenWidth: Int, screenHeight: Int
    let width: Int, height: Int, x: Int, y: Int, scale: Int
    let luma: Data

    var valid: Bool {
        version == 1 && width == 512 && height == 128 && x == 64 && y == 144 && scale == 2 &&
        screenWidth >= 320 && screenWidth <= 16_384 && screenHeight >= 208 && screenHeight <= 16_384 &&
        luma.count == width * height
    }
    var fingerprint: UInt32 {
        SHA256.hash(data: luma).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    static func load(environment: [String: String], arguments: [String], url: URL?) -> Self? {
        guard environment["LATENCY_LAB"] == "1", environment["LATENCY_TEXT_PSNR"] == "1",
              arguments.contains("LatencyProbe"), let url,
              let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 200_001), data.count <= 200_000,
              let result = try? JSONDecoder().decode(Self.self, from: data), result.valid,
              let minimum = result.luma.min(), let maximum = result.luma.max(),
              minimum < 32, maximum > 223 else { return nil }
        return result
    }
}

/// Bilinear reconstruction onto the single full-resolution synthetic reference grid.
enum LatencyTextPSNR {
    struct Result { let psnr: Double?; let exact: Bool; let elapsedMs: Double }
    static func score(buffer: CVPixelBuffer, cropX: Int, cropY: Int, cropWidth: Int, cropHeight: Int,
                      screenWidth: Double, screenHeight: Double, rotation: Int,
                      reference: LatencyTextReference) -> Result? {
        let begin = CACurrentMediaTime(), format = CVPixelBufferGetPixelFormatType(buffer)
        guard reference.valid, rotation == 0, screenWidth == Double(reference.screenWidth),
              screenHeight == Double(reference.screenHeight),
              format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferIsPlanar(buffer), CVPixelBufferGetPlaneCount(buffer) >= 1,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard cropX >= 0, cropY >= 0, cropWidth > 0, cropHeight > 0,
              cropX <= width, cropY <= height, cropWidth <= width - cropX, cropHeight <= height - cropY,
              stride >= width else { return nil }
        let sx = Double(cropWidth) / screenWidth / Double(reference.scale)
        let sy = Double(cropHeight) / screenHeight / Double(reference.scale)
        let firstX = Double(cropX) + Double(reference.x) / screenWidth * Double(cropWidth)
        let firstY = Double(cropY) + Double(reference.y) / screenHeight * Double(cropHeight)
        let endX = cropX + cropWidth - 1, endY = cropY + cropHeight - 1
        let rawFirstX = max(Double(cropX), min(Double(endX), firstX + 0.5 * sx - 0.5))
        let rawLastX = max(Double(cropX), min(Double(endX), firstX + (Double(reference.width) - 0.5) * sx - 0.5))
        let startX = Int(rawFirstX), lastX = min(endX, Int(rawLastX) + 1)
        let sourceCount = lastX - startX + 1
        // Reject malformed/extreme geometry before allocating; this is one small ROI, not a frame copy.
        guard sourceCount > 0, sourceCount <= 2048 else { return nil }
        let n = reference.width, count = vDSP_Length(n)
        let positions: [Float] = (0..<n).map { x in
            Float(max(Double(cropX), min(Double(endX), firstX + (Double(x) + 0.5) * sx - 0.5)) - Double(startX))
        }
        var source0 = [Float](repeating: 0, count: sourceCount + 1), source1 = source0
        var row0 = [Float](repeating: 0, count: n), row1 = row0, combined = row0, scratch = row0
        var expected = row0, difference = row0, squared = row0
        var sum = 0.0
        reference.luma.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let ref = raw.bindMemory(to: UInt8.self)
            guard let refBase = ref.baseAddress else { return }
            for y in 0..<reference.height {
                let fy = max(Double(cropY), min(Double(endY), firstY + (Double(y) + 0.5) * sy - 0.5))
                let y0 = Int(fy), y1 = min(y0 + 1, endY)
                var bottom = Float(fy - Double(y0)), top: Float = 1 - bottom
                vDSP_vfltu8(base.advanced(by: y0 * stride + startX), 1, &source0, 1, vDSP_Length(sourceCount))
                vDSP_vfltu8(base.advanced(by: y1 * stride + startX), 1, &source1, 1, vDSP_Length(sourceCount))
                source0[sourceCount] = source0[sourceCount - 1]; source1[sourceCount] = source1[sourceCount - 1]
                vDSP_vlint(source0, positions, 1, &row0, 1, count, vDSP_Length(sourceCount + 1))
                vDSP_vlint(source1, positions, 1, &row1, 1, count, vDSP_Length(sourceCount + 1))
                vDSP_vsmul(row0, 1, &top, &combined, 1, count)
                vDSP_vsma(row1, 1, &bottom, combined, 1, &scratch, 1, count)
                swap(&combined, &scratch)
                if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
                    var offset: Float = -16, multiplier: Float = 255 / 219, low: Float = 0, high: Float = 255
                    vDSP_vsadd(combined, 1, &offset, &scratch, 1, count)
                    vDSP_vsmul(scratch, 1, &multiplier, &combined, 1, count)
                    vDSP_vclip(combined, 1, &low, &high, &scratch, 1, count)
                    swap(&combined, &scratch)
                }
                vDSP_vfltu8(refBase.advanced(by: y * n), 1, &expected, 1, count)
                vDSP_vsub(combined, 1, expected, 1, &difference, 1, count)
                vDSP_vsq(difference, 1, &squared, 1, count)
                var rowSum: Float = 0; vDSP_sve(squared, 1, &rowSum, count); sum += Double(rowSum)
            }
        }
        let mse = sum / Double(reference.width * reference.height)
        return Result(psnr: mse > 0 ? 10 * log10(255 * 255 / mse) : nil, exact: mse == 0,
                      elapsedMs: (CACurrentMediaTime() - begin) * 1_000)
    }

}

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
    private static let textQualityEnabled = ProcessInfo.processInfo.environment["LATENCY_LAB"] == "1" &&
        ProcessInfo.processInfo.environment["LATENCY_TEXT_PSNR"] == "1" &&
        ProcessInfo.processInfo.arguments.contains("LatencyProbe")
    private static let textReference: LatencyTextReference? = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return LatencyTextReference.load(environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments,
            url: base?.appendingPathComponent("RemoteDesktopHost/Latency/text-reference.json"))
    }()
    private static let textFingerprint = textReference?.fingerprint
    private var textScoring = false
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
        var textScore: LatencyTextPSNR.Result?
        var textStatus: Int = 0 // 0 disabled, 1 scored, 2 unavailable, 3 busy
        var textReferenceFingerprint: UInt32?
        var textDecodedWidth: Int?
        var textDecodedHeight: Int?
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
        let sample = FrameSample(session: capturedSession, collector: capturedCollector,
                                 displayGeneration: generation, decodeTime: decodedAt, marker: marker)
        if Self.textQualityEnabled {
            guard let reference = Self.textReference else { sample.textStatus = 2; return sample }
            sample.textReferenceFingerprint = Self.textFingerprint
            if let native = frame.buffer as? RTCCVPixelBuffer {
                sample.textDecodedWidth = Int(native.cropWidth); sample.textDecodedHeight = Int(native.cropHeight)
            }
            lock.lock(); let available = !textScoring; if available { textScoring = true }; lock.unlock()
            if !available { sample.textStatus = 3 }
            else {
                defer { lock.lock(); textScoring = false; lock.unlock() }
                if marker != nil, let native = frame.buffer as? RTCCVPixelBuffer, let dimensions {
                    sample.textScore = LatencyTextPSNR.score(buffer: native.pixelBuffer,
                        cropX: Int(native.cropX), cropY: Int(native.cropY), cropWidth: Int(native.cropWidth),
                        cropHeight: Int(native.cropHeight), screenWidth: dimensions.0, screenHeight: dimensions.1,
                        rotation: Int(frame.rotation.rawValue), reference: reference)
                }
                sample.textStatus = sample.textScore == nil ? 2 : 1
            }
        }
        return sample
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
        if let row = textQualityRecord(sample, presented: time) { sample.collector.trace(row) }
        if let newMarker { sample.collector.trace(["type": "marker", "marker_id": newMarker, "decodeTime": sample.decodeTime, "presentedTime": time]) }
    }

    func textQualityRecord(_ sample: FrameSample, presented: Double) -> [String: Any]? {
        guard sample.textStatus != 0, isCurrent(sample), presented.isFinite, presented > 0,
              presented >= sample.decodeTime, let submitted = sample.submittedTime,
              submitted >= sample.decodeTime else { return nil }
        var row: [String: Any] = ["type": "text_quality", "presentedTime": presented,
            "decodeTime": sample.decodeTime, "status": sample.textStatus]
        if let marker = sample.marker { row["marker"] = marker }
        if let fingerprint = sample.textReferenceFingerprint { row["referenceFingerprint"] = fingerprint }
        if let width = sample.textDecodedWidth, let height = sample.textDecodedHeight {
            row["decodedWidth"] = width; row["decodedHeight"] = height
        }
        if let score = sample.textScore {
            row["scoreMs"] = score.elapsedMs; row["exact"] = score.exact ? 1 : 0
            if let psnr = score.psnr, psnr.isFinite { row["psnrDB"] = psnr }
        }
        return row
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

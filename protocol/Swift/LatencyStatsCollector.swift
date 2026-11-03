import Foundation
#if DEBUG
import OSLog
#endif

#if DEBUG && os(macOS)
import Darwin

/// CPU time is process-wide; 100 percent means one fully occupied core.
struct LatencyProcessCPUSampler {
    private var previous: (time: Double, cpu: Double)?

    mutating func percentage(time: Double, cpu: Double) -> Double? {
        guard time.isFinite, cpu.isFinite, time >= 0, cpu >= 0 else { return nil }
        guard let old = previous else { previous = (time, cpu); return nil }
        if time < old.time || cpu < old.cpu { previous = (time, cpu); return nil }
        guard time > old.time else { return nil }
        previous = (time, cpu)
        return (cpu - old.cpu) / (time - old.time) * 100
    }

    mutating func sample(at time: Double) -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return percentage(time: time, cpu: cpu)
    }
}
#endif

struct LatencyStatsReport {
    let id: String
    let type: String
    let values: [String: Any]
}

/// Debug-only bounded, pixel-free telemetry. Cumulative values are differenced
/// independently for each WebRTC statistics object, never across object IDs.
// Shared counters are locked; file state is confined to the serial writer.
final class LatencyStatsCollector: @unchecked Sendable {
    static var enabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("LatencyProbe")
        #else
        return false
        #endif
    }
    static var resourcesOnly: Bool {
        #if DEBUG
        return enabled && ProcessInfo.processInfo.arguments.contains("LatencyProbeResourcesOnly")
        #else
        return false
        #endif
    }
    private let lock = NSLock()
    private let side: String
    private let active: Bool
    private var previous: [String: [String: Double]] = [:]
    private var latest: [String: Double] = [:]
    private var bytes = 0 // accessed only on writer
    private var truncated = false // accessed only on writer
    private var writeFailed = false // accessed only on writer
    private var pending = 0
    private var overflowed = false
    private let writer: DispatchQueue?
    private let limit = 1_000_000
    private let url: URL?

    init(side: String, enabled: Bool = LatencyStatsCollector.enabled, traceURL: URL? = nil) {
        self.side = side
        self.active = enabled
        self.writer = enabled ? DispatchQueue(label: "latency.trace.writer") : nil
        #if DEBUG
        if let traceURL { url = traceURL }
        else if enabled, let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = base.appendingPathComponent("RemoteDesktopHost/Latency", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent("\(side)-\(UUID().uuidString).jsonl")
        } else { url = nil }
        #else
        url = nil
        #endif
        #if DEBUG
        if enabled && Self.resourcesOnly {
            trace(["type": "resource_mode", "side": side, "time": ProcessInfo.processInfo.systemUptime,
                   "resourceCadenceSeconds": 1, "statsCadenceSeconds": 10])
        }
        #endif
    }

    func ingest(_ reports: [LatencyStatsReport], at time: Double) {
        guard active else { return }
        lock.lock()
        var values: [String: Any] = [:]
        let pairs = [("totalEncodeTime", "framesEncoded", "encodeMs"),
                     ("totalPacketSendDelay", "packetsSent", "packetSendMs"),
                     ("jitterBufferDelay", "jitterBufferEmittedCount", "jitterBufferMs"),
                     ("totalDecodeTime", "framesDecoded", "decodeMs"),
                     ("totalProcessingDelay", "framesDecoded", "processingMs")]
        let relevant = Set(["framesEncoded", "totalEncodeTime", "totalPacketSendDelay", "packetsSent", "targetBitrate", "qualityLimitationReason", "frameWidth", "frameHeight", "framesPerSecond", "jitterBufferDelay", "jitterBufferEmittedCount", "totalDecodeTime", "totalProcessingDelay", "framesDecoded", "framesDropped", "freezeCount", "jitter", "packetsLost", "nackCount", "pliCount", "currentRoundTripTime", "availableOutgoingBitrate", "localCandidateType", "remoteCandidateType"])
        var next: [String: [String: Double]] = [:]
        var weighted: [String: (Double, Double)] = [:]
        var perID: [String: [String: Any]] = [:]
        let byID = Dictionary(reports.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let selectedID = reports.first(where: { $0.type == "transport" })?.values["selectedCandidatePairId"] as? String
        for report in reports {
            guard ["outbound-rtp", "inbound-rtp", "candidate-pair"].contains(report.type) else { continue }
            if report.type == "candidate-pair" {
                if let selectedID, report.id != selectedID { continue }
                if selectedID == nil, (report.values["nominated"] as? NSNumber)?.boolValue != true { continue }
                for (idKey, result) in [("localCandidateId", "localCandidateType"), ("remoteCandidateId", "remoteCandidateType")] {
                    if let id = report.values[idKey] as? String,
                       let type = byID[id]?.values["candidateType"] as? String { values[result] = type }
                }
            }
            if report.type != "candidate-pair", let kind = (report.values["kind"] ?? report.values["mediaType"]) as? String, kind != "video" { continue }
            var numbers: [String: Double] = [:]
            var reportValues: [String: Any] = [:]
            for (key, value) in report.values where relevant.contains(key) {
                if let number = value as? NSNumber, number.doubleValue.isFinite {
                    numbers[key] = number.doubleValue
                    reportValues[key] = number.doubleValue
                } else if let string = value as? String { reportValues[key] = string }
            }
            for key in ["framesEncoded", "packetsSent", "jitterBufferEmittedCount", "framesDecoded", "framesDropped", "freezeCount", "packetsLost", "nackCount", "pliCount"] {
                if let current = numbers[key], let old = previous[report.id]?[key], current >= old {
                    reportValues[key + "Delta"] = current - old
                }
            }
            for (total, count, result) in pairs {
                if let old = previous[report.id], let t = numbers[total], let c = numbers[count],
                   let ot = old[total], let oc = old[count], t >= ot, c > oc {
                    let deltaTotal = t - ot, deltaCount = c - oc
                    reportValues[result] = deltaTotal / deltaCount * 1000
                    let oldWeighted = weighted[result] ?? (0, 0)
                    weighted[result] = (oldWeighted.0 + deltaTotal, oldWeighted.1 + deltaCount)
                }
            }
            if report.type == "candidate-pair" {
                values.merge(reportValues) { _, new in new }
            } else {
                perID[report.id] = reportValues
            }
            next[report.id] = numbers
        }
        for (key, value) in weighted where value.1 > 0 { values[key] = value.0 / value.1 * 1000 }
        if perID.count == 1, let only = perID.values.first {
            values.merge(only) { old, _ in old }
        }
        previous = next
        latest = values.compactMapValues { ($0 as? NSNumber)?.doubleValue }
        writeLocked(["type": "stats", "time": time, "side": side, "values": values, "reports": perID])
        lock.unlock()
    }
    func snapshot() -> [String: Double] { lock.lock(); defer { lock.unlock() }; return latest }
    func trace(_ fields: [String: Any]) {
        guard active else { return }
        if Self.resourcesOnly, let type = fields["type"] as? String,
           !["resource_mode", "resource", "clock", "collector_reset", "latency_loop_start",
             "latency_loop_exit", "transport_close", "peer_state", "data_channel_state",
             "app_lifecycle"].contains(type) { return }
        lock.lock(); defer { lock.unlock() }; writeLocked(fields)
    }
    // Caller holds lock. The bounded queue keeps capture, decode and input
    // callbacks away from JSON encoding and disk I/O.
    private func writeLocked(_ fields: [String: Any]) {
        guard let url, let writer, !overflowed else { return }
        if pending >= 256 {
            overflowed = true
            writer.async { [self] in writeRecord(["type": "truncated"], to: url, forceMarker: true) }
            return
        }
        pending += 1
        writer.async { [self] in
            writeRecord(fields, to: url)
            lock.lock(); pending -= 1; lock.unlock()
        }
    }
    private func writeRecord(_ fields: [String: Any], to url: URL, forceMarker: Bool = false) {
        guard !truncated, !writeFailed else { return }
        guard JSONSerialization.isValidJSONObject(fields) else {
            recordWriteFailure(operation: "encode", error: nil)
            return
        }
        var data: Data
        do { data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) }
        catch { recordWriteFailure(operation: "encode", error: error); return }
        data.append(10)
        let marker = Data("{\"type\":\"truncated\"}\n".utf8)
        if forceMarker || bytes + data.count + marker.count > limit {
            truncated = true
            lock.lock(); overflowed = true; lock.unlock()
            data = marker
        }
        guard bytes + data.count <= limit else { return }
        if !FileManager.default.fileExists(atPath: url.path),
           !FileManager.default.createFile(atPath: url.path, contents: nil) {
            recordWriteFailure(operation: "create", error: nil)
            return
        }
        do {
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: data)
            bytes += data.count
        } catch { recordWriteFailure(operation: "append", error: error) }
    }
    private func recordWriteFailure(operation: String, error: Error?) {
        // End this trace rather than silently resuming after lost records. The
        // independent system log still explains an incomplete trace export.
        writeFailed = true
        lock.lock(); overflowed = true; lock.unlock()
        #if DEBUG
        let code = (error as NSError?)?.code ?? 0
        Logger(subsystem: "com.threadmark.remotedesktop", category: "LatencyTrace")
            .error("Latency trace stopped: side=\(self.side, privacy: .public) operation=\(operation, privacy: .public) errorCode=\(code, privacy: .public)")
        #endif
    }
    func flush() { writer?.sync {} }
}

#if DEBUG
import CoreVideo

/// Reads only the synthetic marker's luminance cells; no pixels are retained.
enum LatencyMarkerSampler {
    static func sample(pixelBuffer buffer: CVPixelBuffer, cropX: Int, cropY: Int,
                       cropWidth: Int, cropHeight: Int,
                       screenWidth: Double, screenHeight: Double) -> Int? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
              format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              screenWidth.isFinite, screenHeight.isFinite, screenWidth >= 100, screenHeight > 390,
              screenWidth <= Double(Int32.max), screenHeight <= Double(Int32.max),
              CVPixelBufferIsPlanar(buffer), CVPixelBufferGetPlaneCount(buffer) >= 1,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard cropX >= 0, cropY >= 0, cropWidth > 0, cropHeight > 0,
              cropX <= width, cropY <= height, cropWidth <= width - cropX, cropHeight <= height - cropY else { return nil }
        let cell = floor(screenWidth * 0.42 / 32)
        guard cell >= 1 else { return nil }
        let y = cropY + Int((390 / screenHeight * Double(cropHeight)).rounded(.down))
        guard y > 0, y + 1 < height else { return nil }
        var bits: UInt32 = 0
        for bit in 0..<32 {
            let x = cropX + Int(((36 + (Double(bit) + 0.5) * cell) / screenWidth * Double(cropWidth)).rounded(.down))
            guard x > 0, x + 1 < width else { return nil }
            var sum = 0
            for dy in -1...1 { for dx in -1...1 { sum += Int(base[(y + dy) * stride + x + dx]) } }
            let luminance = sum / 9
            guard luminance > 185 || luminance < 65 else { return nil }
            if luminance > 185 { bits |= UInt32(1) << bit }
        }
        let value = bits & 0xffff
        guard value > 0, (bits >> 16) == (value ^ 0xffff) else { return nil }
        return Int(value)
    }
}
#endif

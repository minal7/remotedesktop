import Foundation
#if DEBUG
import OSLog

extension LatencyLabConfiguration {
    static func pairedFixes(_ value: String) -> Set<String>? {
        let parts = value.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let fixes = Set(parts)
        guard !fixes.isEmpty, fixes.count == parts.count,
              fixes.isSubset(of: ["F1", "F2", "F3", "F4"]),
              fixes.sorted().joined(separator: "+") == value else { return nil }
        return fixes
    }
}
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

#if DEBUG && os(macOS)
/// All state is owned by the peer lock; a canceled generation cannot complete.
struct LabSendPollGate {
    private var active = true
    private var pending: UInt64?
    private var serial: UInt64 = 0
    mutating func begin() -> UInt64? {
        guard active, pending == nil else { return nil }
        serial &+= 1; pending = serial; return serial
    }
    mutating func finish(_ token: UInt64) -> Bool {
        guard active, pending == token else { return false }
        pending = nil; return true
    }
    mutating func cancel() { active = false; pending = nil }
}

/// Per-peer numerical observations only. WebRTC object identities never leave this state.
struct LabSendIntervalSampler {
    private var previousID: String?
    private var previousReportTime: Double?
    private var previousOutboundTime: Double?
    private var previousPairID: String?
    private var previousPairTime: Double?
    private var counters: [String: Double] = [:]

    static func enabled(labAdmitted: Bool, ordinaryPeer: Bool, resourcesOnly: Bool,
                        arguments: [String], environment: [String: String]) -> Bool {
        guard labAdmitted, ordinaryPeer, !resourcesOnly,
              Array(arguments.dropFirst()) == ["--debug-latency-host"],
              environment["LATENCY_LAB"] == "1", environment["LATENCY_SEND_TRACE_10HZ"] == "1",
              environment["REMOTE_DESKTOP_R0_HOST_ID"] == nil,
              let id = environment["REMOTE_DESKTOP_LATENCY_HOST_ID"], id.utf8.count == 36,
              UUID(uuidString: id) != nil else { return false }
        return true
    }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue >= 0 else { return nil }
        return n.doubleValue
    }
    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }; return value
    }
    mutating func sample(request: Double, completion: Double, reportTimestampUs: Double?,
                         reports: [LatencyStatsReport], times: [String: Double]) -> [String: Any] {
        var row: [String: Any] = ["type": "send_10hz", "requestTime": request, "completionTime": completion]
        let reportTime = Self.positive(reportTimestampUs)
        if let reportTime { row["reportTimestampUs"] = reportTime }
        if reportTime == nil { row["reportStatus"] = "missing_timestamp" }
        else if let previousReportTime { row["reportStatus"] = reportTime! > previousReportTime ? "advanced_timestamp" : "stale_timestamp" }
        else { row["reportStatus"] = "baseline" }
        let selectedIDs = Set(reports.filter { $0.type == "transport" }.compactMap { $0.values["selectedCandidatePairId"] as? String })
        let pairs = reports.filter { $0.type == "candidate-pair" && selectedIDs.contains($0.id) }
        if selectedIDs.count == 1, pairs.count == 1, let pair = pairs.first {
            let pairTime = Self.positive(times[pair.id])
            if let pairTime { row["pairTimestampUs"] = pairTime }
            let pairSame = previousPairID == pair.id
            row["pairStatus"] = pairTime == nil ? "missing_timestamp" :
                (pairSame && previousPairTime != nil && pairTime! <= previousPairTime! ? "stale_timestamp" : (pairSame ? "advanced_timestamp" : "baseline"))
            if let estimate = Self.number(pair.values["availableOutgoingBitrate"]) {
                row["estimateStatus"] = "available"; row["availableOutgoingBitrateBps"] = estimate
            } else { row["estimateStatus"] = "missing" }
            if !pairSame || previousPairTime == nil || (pairTime != nil && pairTime! > previousPairTime!) {
                previousPairID = pair.id; previousPairTime = pairTime
            }
        } else {
            row["pairStatus"] = "unavailable"; row["estimateStatus"] = "missing"
            previousPairID = nil; previousPairTime = nil
        }
        let video = reports.filter { $0.type == "outbound-rtp" &&
            ($0.values["kind"] as? String ?? $0.values["mediaType"] as? String) == "video" }
        guard video.count == 1, let outbound = video.first else {
            previousID = nil; previousReportTime = nil; previousOutboundTime = nil; counters.removeAll()
            row["outboundStatus"] = video.isEmpty ? "missing" : "ambiguous"
            row["bytesStatus"] = "missing"; row["packetsStatus"] = "missing"; row["delayStatus"] = "missing"
            row["targetStatus"] = "missing"
            return row
        }
        let outboundTime = Self.positive(times[outbound.id])
        if let outboundTime { row["outboundTimestampUs"] = outboundTime }
        let same = previousID == outbound.id
        let comparable = same && reportTime != nil && outboundTime != nil && previousReportTime != nil && previousOutboundTime != nil
        let stale = comparable && (reportTime! <= previousReportTime! || outboundTime! <= previousOutboundTime!)
        row["outboundStatus"] = reportTime == nil || outboundTime == nil ? "missing_timestamp" : (stale ? "stale_timestamp" : (comparable ? "advanced_timestamp" : "baseline"))
        if comparable && !stale { row["intervalSeconds"] = (outboundTime! - previousOutboundTime!) / 1_000_000 }
        for (source, status, delta) in [("bytesSent", "bytesStatus", "bytesSentDelta"),
                                         ("packetsSent", "packetsStatus", "packetsSentDelta"),
                                         ("totalPacketSendDelay", "delayStatus", "packetSendDelaySecondsDelta")] {
            guard let value = Self.number(outbound.values[source]) else { row[status] = "missing"; counters.removeValue(forKey: source); continue }
            if stale { row[status] = "stale"; continue }
            if reportTime == nil || outboundTime == nil { row[status] = "missing_timestamp"; counters.removeValue(forKey: source); continue }
            if same, let old = counters[source] {
                if value >= old { row[status] = "ok"; row[delta] = value - old }
                else { row[status] = "reset" }
            } else { row[status] = "baseline" }
            counters[source] = value
        }
        if !stale {
            if !same { // Do not compare new identities against the preceding stream.
                counters = counters.filter { outbound.values[$0.key] != nil }
            }
            previousID = outbound.id; previousReportTime = reportTime; previousOutboundTime = outboundTime
        }
        if let d = row["packetSendDelaySecondsDelta"] as? Double,
           let p = row["packetsSentDelta"] as? Double, p > 0 {
            row["packetSendIntervalMeanMs"] = d / p * 1_000
        }
        if let target = Self.number(outbound.values["targetBitrate"]) {
            row["targetStatus"] = "available"; row["targetBitrateBps"] = target
        } else { row["targetStatus"] = "missing" }
        return row
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
        let lab = LatencyLabConfiguration.current
        return ProcessInfo.processInfo.arguments.contains("LatencyProbe")
            || ProcessInfo.processInfo.arguments.contains("LatencyLab")
            || ProcessInfo.processInfo.environment["LATENCY_LAB"] == "1"
            || lab.f1Playout || lab.f2Encoder || lab.f3Sender || lab.f4Renderer
        #else
        return false
        #endif
    }
    static var resourcesOnly: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        #if os(macOS)
        return enabled && (arguments.contains("LatencyProbeResourcesOnly") || isolatedHostResourcesOnly(
            arguments: arguments, environment: ProcessInfo.processInfo.environment))
        #else
        return enabled && arguments.contains("LatencyProbeResourcesOnly")
        #endif
        #else
        return false
        #endif
    }
    #if DEBUG && os(macOS)
    /// This environment opt-in is valid only for the isolated latency host;
    /// ordinary hosts and the separately isolated R0 host cannot inherit it.
    static func isolatedHostResourcesOnly(arguments: [String], environment: [String: String]) -> Bool {
        guard Array(arguments.dropFirst()) == ["--debug-latency-host"],
              environment["LATENCY_LAB_RESOURCES_ONLY"] == "1",
              environment["REMOTE_DESKTOP_R0_HOST_ID"] == nil,
              let id = environment["REMOTE_DESKTOP_LATENCY_HOST_ID"],
              id.utf8.count == 36, UUID(uuidString: id) != nil else { return false }
        return true
    }
    #endif
    #if DEBUG && os(iOS)
    static func traceLimit(arguments: [String]) -> Int {
        traceLimit(arguments: arguments, environment: ProcessInfo.processInfo.environment)
    }

    static func traceLimit(arguments: [String], environment: [String: String]) -> Int {
        guard arguments.contains("LatencyProbe") else { return 1_000_000 }
        if let index = arguments.firstIndex(of: "LatencyLabPairFix") {
            guard arguments.indices.contains(index + 1),
                  LatencyLabConfiguration.pairedFixes(arguments[index + 1]) != nil else { return 1_000_000 }
            return 8_000_000
        }
        // Standalone extended traces require both explicit, exact lab opt-ins.
        guard environment["LATENCY_LAB"] == "1",
              arguments.filter({ $0 == "LatencyLabExtendedTrace" }).count == 1 else { return 1_000_000 }
        return 8_000_000
    }
    #endif
    private let lock = NSLock()
    private let side: String
    private let active: Bool
    private var previous: [String: [String: Double]] = [:]
    private var latest: [String: Double] = [:]
    private var rttFloorMs: Double?
    private var captureSize: (Int, Int)?
    private var encodedSizes: [Int] = []
    private var encodedSizeOverflow = false
    private var encodedWindowStart: Double?
    private var bytes = 0 // accessed only on writer
    private var truncated = false // accessed only on writer
    private var writeFailed = false // accessed only on writer
    private var pending = 0
    private var overflowed = false
    private let writer: DispatchQueue?
    private let limit: Int
    private let url: URL?

    init(side: String, enabled: Bool = LatencyStatsCollector.enabled, traceURL: URL? = nil) {
        self.side = side
        self.active = enabled
        self.writer = enabled ? DispatchQueue(label: "latency.trace.writer") : nil
        #if DEBUG && os(iOS)
        // Paired runs and explicitly opted-in standalone lab probes use the
        // extended bound; ordinary clients and every host peer retain 1 MB.
        self.limit = Self.traceLimit(arguments: ProcessInfo.processInfo.arguments)
        #else
        self.limit = 1_000_000
        #endif
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
        if enabled {
            trace(["type": "lab_configuration", "side": side,
                   "time": ProcessInfo.processInfo.systemUptime,
                   "settings": LatencyLabConfiguration.current.traceValues])
        }
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
                     ("jitterBufferTargetDelay", "jitterBufferEmittedCount", "jitterBufferTargetMs"),
                     ("totalDecodeTime", "framesDecoded", "decodeMs"),
                     ("totalProcessingDelay", "framesDecoded", "processingMs")]
        #if DEBUG
        let numericTrafficCounters = Set(["bytesSent", "bytesReceived", "packetsReceived",
                                          "retransmittedPacketsSent", "retransmittedBytesSent"])
        #else
        let numericTrafficCounters = Set<String>()
        #endif
        let relevant = numericTrafficCounters.union(["encoderImplementation", "codecId", "framesEncoded", "totalEncodeTime", "totalPacketSendDelay", "packetsSent", "targetBitrate", "qualityLimitationReason", "frameWidth", "frameHeight", "framesPerSecond", "jitterBufferDelay", "jitterBufferTargetDelay", "jitterBufferEmittedCount", "totalDecodeTime", "totalProcessingDelay", "framesDecoded", "framesDropped", "freezeCount", "totalFreezesDuration", "keyFramesEncoded", "keyFramesDecoded", "jitter", "packetsLost", "nackCount", "pliCount", "currentRoundTripTime", "availableOutgoingBitrate"])
        var next: [String: [String: Double]] = [:]
        var weighted: [String: (Double, Double)] = [:]
        var perID: [String: [String: Any]] = [:]
        let byID = Dictionary(reports.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let nominated = reports.filter { $0.type == "candidate-pair" && ($0.values["nominated"] as? NSNumber)?.boolValue == true }
        let selectedID = (reports.first(where: { $0.type == "transport" })?.values["selectedCandidatePairId"] as? String)
            ?? (nominated.count == 1 ? nominated.first?.id : nil)
        for report in reports {
            guard ["outbound-rtp", "inbound-rtp", "candidate-pair"].contains(report.type) else { continue }
            if report.type == "candidate-pair" {
                guard let selectedID, report.id == selectedID else { continue }
                for (idKey, prefix) in [("localCandidateId", "localCandidate"), ("remoteCandidateId", "remoteCandidate")] {
                    guard let id = report.values[idKey] as? String, let candidate = byID[id] else { continue }
                    values[prefix + "Type"] = ICECandidateDiagnostics.kind(candidate.values["candidateType"] as? String)
                    if let address = (candidate.values["address"] ?? candidate.values["ip"]) as? String {
                        values[prefix + "Family"] = ICECandidateDiagnostics.family(address)
                    }
                    if prefix == "localCandidate" {
                        values["candidateProtocol"] = ICECandidateDiagnostics.transport(candidate.values["protocol"] as? String)
                    }
                }
                if let rtt = (report.values["currentRoundTripTime"] as? NSNumber)?.doubleValue, rtt.isFinite, rtt > 0 {
                    rttFloorMs = min(rttFloorMs ?? rtt * 1000, rtt * 1000)
                }
            }
            if report.type != "candidate-pair", let kind = (report.values["kind"] ?? report.values["mediaType"]) as? String, kind != "video" { continue }
            var numbers: [String: Double] = [:]
            var reportValues: [String: Any] = [:]
            for (key, value) in report.values where relevant.contains(key) {
                if let number = value as? NSNumber, number.doubleValue.isFinite {
                    numbers[key] = number.doubleValue
                    reportValues[key] = number.doubleValue
                } else if !numericTrafficCounters.contains(key), let string = value as? String { reportValues[key] = string }
            }
            if let codecID = report.values["codecId"] as? String,
               let codec = byID[codecID], codec.type == "codec" {
                for key in ["mimeType", "sdpFmtpLine"] {
                    if let value = codec.values[key] as? String {
                        reportValues["codec_" + key] = value
                    }
                }
            }
            for key in ["framesEncoded", "packetsSent", "jitterBufferEmittedCount", "framesDecoded", "framesDropped", "freezeCount", "totalFreezesDuration", "keyFramesEncoded", "keyFramesDecoded", "packetsLost", "nackCount", "pliCount"] + numericTrafficCounters.sorted() {
                if let current = numbers[key], let old = previous[report.id]?[key], current >= old {
                    reportValues[key + "Delta"] = current - old
                    if ["freezeCount", "keyFramesEncoded", "pliCount"].contains(key), current > old {
                        writeLocked(["type": "stream_event", "side": side, "time": time,
                                     "event": key, "delta": current - old,
                                     "timing": "observed_at_stats_poll"])
                    }
                }
            }
            for metric in ["targetBitrate", "availableOutgoingBitrate"] {
                if let current = numbers[metric], let old = previous[report.id]?[metric],
                   old > 0, current < old * 0.75 {
                    writeLocked(["type": "stream_event", "side": side, "time": time,
                                 "event": "bandwidth_estimate_drop", "metric": metric,
                                 "beforeBps": old, "afterBps": current,
                                 "timing": "observed_at_stats_poll"])
                }
            }
            if let current = numbers["currentRoundTripTime"], current > 0.150,
               (previous[report.id]?["currentRoundTripTime"] ?? 0) <= 0.150 {
                writeLocked(["type": "stream_event", "side": side, "time": time,
                             "event": "rtt_spike", "rttMs": current * 1000,
                             "timing": "observed_at_stats_poll"])
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
        if let rttFloorMs { values["rttFloorMs"] = rttFloorMs }
        if let captureSize { values["captureWidth"] = captureSize.0; values["captureHeight"] = captureSize.1 }
        previous = next
        latest = values.compactMapValues { ($0 as? NSNumber)?.doubleValue }
        writeLocked(["type": "stats", "time": time, "side": side, "values": values, "reports": perID])
        lock.unlock()
    }
    func recordCaptureSize(width: Int, height: Int) {
        guard active, width > 0, height > 0 else { return }
        lock.lock(); captureSize = (width, height); lock.unlock()
    }
    func recordEncodedFrameBytes(_ count: Int) {
        guard active, count > 0 else { return }
        lock.lock()
        if encodedWindowStart == nil { encodedWindowStart = ProcessInfo.processInfo.systemUptime }
        if encodedSizes.count < 512 { encodedSizes.append(count) } else { encodedSizeOverflow = true }
        lock.unlock()
    }
    func flushEncodedFrameSizes(at time: Double) {
        guard active, time.isFinite else { return }
        lock.lock()
        let sorted = encodedSizes.sorted(), overflow = encodedSizeOverflow
        let start = min(encodedWindowStart ?? time, time)
        encodedSizes.removeAll(keepingCapacity: true); encodedSizeOverflow = false; encodedWindowStart = time
        if !sorted.isEmpty {
            func percentile(_ p: Double) -> Int { sorted[max(0, Int(ceil(Double(sorted.count) * p)) - 1)] }
            writeLocked(["type": "encoded_frame_sizes", "side": side, "time": time,
                         "intervalStart": start, "intervalSeconds": time - start,
                         "count": sorted.count, "p50Bytes": percentile(0.5), "p95Bytes": percentile(0.95),
                         "maxBytes": sorted.last!, "complete": !overflow])
        }
        lock.unlock()
    }
    func snapshot() -> [String: Double] { lock.lock(); defer { lock.unlock() }; return latest }
    func trace(_ fields: [String: Any]) {
        guard active else { return }
        if Self.resourcesOnly, let type = fields["type"] as? String,
           !["lab_configuration", "f1_playout", "resource_mode", "resource", "clock", "collector_reset", "latency_loop_start",
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

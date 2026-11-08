import Foundation

#if DEBUG
enum LatencyLabSenderPolicy {
    struct Path: Equatable {
        let id: String
        let localType: String
        let remoteType: String
        var isLAN: Bool { localType == "host" && remoteType == "host" }
        var minimumBitrate: Int { isLAN ? 2_500_000 : 0 }
        var startingBitrate: Int { isLAN ? 10_000_000 : 4_000_000 }
        let maximumBitrate = 30_000_000
    }

    static func stage2Allowed(labInstrumentation: Bool, ordinaryPeer: Bool,
                              arguments: [String], environment: [String: String]) -> Bool {
        guard labInstrumentation, ordinaryPeer,
              Array(arguments.dropFirst()) == ["--debug-latency-host"],
              environment["LATENCY_LAB"] == "1", environment["LATENCY_STAGE2_FLOOR"] == "1",
              environment["REMOTE_DESKTOP_R0_HOST_ID"] == nil,
              let rawID = environment["REMOTE_DESKTOP_LATENCY_HOST_ID"],
              rawID.utf8.count == 36, UUID(uuidString: rawID) != nil else { return false }
        return true
    }

    /// Isolated Stage 2 trial state. IDs are used only for local continuity,
    /// never emitted into diagnostic records.
    struct Stage2Sample {
        let time: Double
        let path: Path
        let outboundID: String
        let remoteID: String?
        let captureFrames: UInt64
        let framesEncoded: Double
        let rttSeconds: Double?
        let rttResponses: Double?
        let fractionLost: Double?
        let lossTimestampUs: Double?
        let reportTimestampUs: Double?
        let targetBitrate: Double?
    }

    struct Stage2Action: Equatable {
        enum Reason: String { case initial, quality, congestion, recovery, rttProbe, stall, pathUnavailable, codecUnavailable }
        let reason: Reason
        let floor: Int
        let current: Int?
    }

    struct Stage2State {
        let candidate: Bool
        private(set) var floor = 0
        private var previous: Stage2Sample?
        private var activePath: Path?
        private var lastSampleTime: Double?
        private var history: [(Double, Double)] = []
        private var lastRTTTime: Double?
        private var lastRTTValue: Double?
        private var lastRTTHigh: Bool?
        private var lastLossTimestampUs: Double?
        private var lastLossHigh: Bool?
        private var rttCongested = 0.0
        private var lossCongested = 0.0
        private var healthyLossSeconds = 0.0
        private var healthyRTTSeconds = 0.0
        private var qualityStart: Double?
        private var qualityQualified = false
        private var stallLatched = false
        private var stallSeconds = 0.0
        private let floorStep = 100_000

        init(candidate: Bool) { self.candidate = candidate }
        func accepts(time: Double) -> Bool {
            time.isFinite && time >= 0 && (lastSampleTime.map { time > $0 } ?? true)
        }
        private mutating func clearObservations() {
            qualityStart = nil
            previous = nil; history.removeAll(); lastRTTTime = nil; lastRTTValue = nil; lastRTTHigh = nil
            lastLossTimestampUs = nil; lastLossHigh = nil
            rttCongested = 0; lossCongested = 0; healthyLossSeconds = 0; healthyRTTSeconds = 0; stallSeconds = 0
        }
        mutating func reset() {
            floor = 0; activePath = nil; lastSampleTime = nil; stallLatched = false; qualityQualified = false; clearObservations()
        }
        mutating func unavailable(at time: Double, reason: Stage2Action.Reason,
                                  using update: (Stage2Action) -> Bool) -> (action: Stage2Action, applied: Bool)? {
            guard accepts(time: time) else { return nil }
            let action = Stage2Action(reason: reason, floor: 0, current: nil)
            guard floor > 0 else { reset(); lastSampleTime = time; return nil }
            let applied = update(action)
            if applied { reset() }
            lastSampleTime = time // Fence older callbacks even when the SDK rejects a change.
            return (action, applied)
        }
        /// Commit policy transitions only after the SDK accepts the change.
        mutating func apply(_ sample: Stage2Sample, using update: (Stage2Action) -> Bool)
            -> (action: Stage2Action, applied: Bool)? {
            var next = self
            guard let action = next.ingest(sample) else { self = next; return nil }
            let applied = update(action)
            if applied { self = next } else { lastSampleTime = sample.time }
            return (action, applied)
        }
        mutating func ingest(_ sample: Stage2Sample) -> Stage2Action? {
            guard accepts(time: sample.time) else { return nil }
            guard sample.framesEncoded.isFinite, sample.framesEncoded >= 0,
                  sample.framesEncoded.rounded() == sample.framesEncoded, !sample.outboundID.isEmpty else {
                clearObservations(); lastSampleTime = sample.time; return nil
            }
            lastSampleTime = sample.time
            let maximum = candidate ? (qualityQualified ? 4_000_000 : 1_500_000) : 0
            if activePath != sample.path {
                reset(); lastSampleTime = sample.time; activePath = sample.path; floor = candidate ? 1_500_000 : 0; previous = sample
                if let rtt = sample.rttSeconds, rtt.isFinite, rtt > 0,
                   let responses = sample.rttResponses, responses.isFinite, responses > 0 {
                    history.append((sample.time, rtt)); lastRTTTime = sample.time; lastRTTValue = rtt; lastRTTHigh = false
                    if rtt <= 0.020 { qualityStart = sample.time }
                }
                if let ts = sample.lossTimestampUs, let report = sample.reportTimestampUs,
                   let fraction = sample.fractionLost, ts.isFinite, report.isFinite, fraction.isFinite,
                   ts > 0, report >= ts, report - ts <= 2_500_000, (0...1).contains(fraction) {
                    lastLossTimestampUs = ts; lastLossHigh = fraction > 0.02
                }
                return Stage2Action(reason: .initial, floor: floor, current: nil)
            }
            guard let old = previous else { previous = sample; return nil }
            let dt = sample.time - old.time
            if old.outboundID != sample.outboundID {
                clearObservations(); stallLatched = false; previous = sample
                return nil
            }
            guard old.remoteID == sample.remoteID, dt >= 0.5, dt <= 1.5,
                  sample.captureFrames >= old.captureFrames, sample.framesEncoded >= old.framesEncoded else {
                clearObservations(); previous = sample; return nil
            }
            previous = sample
            let encodedDelta = sample.framesEncoded - old.framesEncoded
            if encodedDelta > 0 { stallLatched = false; stallSeconds = 0 }
            else if sample.captureFrames > old.captureFrames { stallSeconds += dt }
            else { stallSeconds = 0 }
            let shouldRecoverStall = candidate && stallSeconds >= 1 && !stallLatched

            history.removeAll { sample.time - $0.0 > 60 }
            let rtt = sample.rttSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let baseline = history.map(\.1).min()
            var newRTT = false
            if let count = sample.rttResponses, let oldCount = old.rttResponses,
               count.isFinite, oldCount.isFinite, count >= 0, count.rounded() == count,
               oldCount >= 0, oldCount.rounded() == oldCount, rtt != nil {
                if count < oldCount { lastRTTTime = nil; lastRTTValue = nil; lastRTTHigh = nil; rttCongested = 0; history.removeAll() }
                else { newRTT = count > oldCount }
            } else { lastRTTTime = nil; lastRTTValue = nil; lastRTTHigh = nil; rttCongested = 0 }
            let previousRTTTime = lastRTTTime
            let previousRTTHigh = lastRTTHigh
            let wasFresh = lastRTTTime.map { sample.time - $0 <= 2.5 } == true
            if !wasFresh { healthyRTTSeconds = 0 }
            let observedRTT = newRTT ? rtt : (wasFresh ? lastRTTValue : nil)
            let rttHigh = observedRTT.flatMap { value in baseline.map { value > $0 + max(0.050, $0 * 0.5) } }
            if newRTT {
                if let high = rttHigh {
                    if high && lastRTTHigh == true, let previousTime = lastRTTTime, sample.time - previousTime <= 2.5 {
                        rttCongested += sample.time - previousTime
                    } else { rttCongested = 0 }
                    lastRTTHigh = high
                }
                lastRTTTime = sample.time; lastRTTValue = rtt
            }
            if let value = rtt, newRTT { history.append((sample.time, value)) }
            if rttHigh == true { healthyRTTSeconds = 0; healthyLossSeconds = 0 }
            else if rttHigh == false {
                if newRTT, previousRTTHigh == false, let previousRTTTime, sample.time - previousRTTTime <= 2.5 {
                    healthyRTTSeconds += sample.time - previousRTTTime
                }
            } else { rttCongested = 0; healthyRTTSeconds = 0; healthyLossSeconds = 0 }

            var freshLossHigh: Bool?
            if let ts = sample.lossTimestampUs, let report = sample.reportTimestampUs,
               let fraction = sample.fractionLost, ts.isFinite, report.isFinite, fraction.isFinite,
               ts > 0, report >= ts, report - ts <= 2_500_000, (0...1).contains(fraction) {
                if let oldTS = lastLossTimestampUs, ts > oldTS {
                    let gap = (ts - oldTS) / 1_000_000
                    let high = fraction > 0.02
                    if gap <= 2.5 {
                        if high { lossCongested = lastLossHigh == true ? lossCongested + gap : 0 }
                        else { lossCongested = 0 }
                        if !high && lastLossHigh == false && rttHigh == false { healthyLossSeconds += gap }
                        else { healthyLossSeconds = 0 }
                    } else { lossCongested = 0; healthyLossSeconds = 0 }
                    lastLossTimestampUs = ts; lastLossHigh = high; freshLossHigh = high
                } else if lastLossTimestampUs == nil {
                    lastLossTimestampUs = ts; lastLossHigh = fraction > 0.02; freshLossHigh = lastLossHigh
                } else if ts < lastLossTimestampUs! {
                    lastLossTimestampUs = nil; lastLossHigh = nil; lossCongested = 0; healthyLossSeconds = 0
                }
            } else {
                lastLossTimestampUs = nil; lastLossHigh = nil; lossCongested = 0; healthyLossSeconds = 0
            }
            // Qualification requires separate fresh RTT measurements and recent
            // low RTCP loss, independent of ICE candidate type.
            if newRTT {
                if let current = rtt, current <= 0.020, let start = qualityStart,
                   sample.time - start <= 6 {
                    // Preserve the initial low-RTT observation.
                } else if let current = rtt, current <= 0.020 {
                    qualityStart = sample.time
                } else { qualityStart = nil }
            } else if !wasFresh { qualityStart = nil }
            let lossFreshAndLow = sample.reportTimestampUs.flatMap { report in
                lastLossTimestampUs.map { report.isFinite && report >= $0 && report - $0 <= 2_500_000 }
            } == true && lastLossHigh == false
            if !lossFreshAndLow || rttHigh == true || lossCongested > 0 { qualityStart = nil }
            if shouldRecoverStall {
                stallLatched = true
                let target = sample.targetBitrate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                let current = target.map { Int(min(Double(sample.path.maximumBitrate), max(Double(floor), $0))) }
                return Stage2Action(reason: .stall, floor: floor, current: current)
            }
            if candidate && !qualityQualified && newRTT, let start = qualityStart,
               sample.time - start >= 2, lossFreshAndLow, lossCongested == 0,
               floor == 1_500_000 {
                qualityQualified = true; floor = 4_000_000
                return Stage2Action(reason: .quality, floor: floor, current: nil)
            }
            if candidate && (rttCongested >= 2 || lossCongested >= 2) && floor > 0 {
                floor = floor <= floorStep ? 0 : floor / 2
                rttCongested = 0; lossCongested = 0; healthyLossSeconds = 0; healthyRTTSeconds = 0
                return Stage2Action(reason: .congestion, floor: floor, current: nil)
            }
            let lossStillFresh = sample.reportTimestampUs.flatMap { report in
                lastLossTimestampUs.map { report.isFinite && report >= $0 && report - $0 <= 2_500_000 }
            } == true
            let knownHighLoss = freshLossHigh == true || (lossStillFresh && lastLossHigh == true)
            if candidate && floor == 0 && healthyRTTSeconds >= 10 && !knownHighLoss {
                floor = min(maximum, floorStep); healthyRTTSeconds = 0; healthyLossSeconds = 0
                return Stage2Action(reason: .rttProbe, floor: floor, current: nil)
            }
            if candidate && healthyLossSeconds >= 10 && healthyRTTSeconds >= 10 && floor < maximum {
                floor = min(maximum, max(floorStep, floor * 2)); healthyLossSeconds = 0; healthyRTTSeconds = 0
                return Stage2Action(reason: .recovery, floor: floor, current: nil)
            }
            return nil
        }
    }

    /// A nominated-but-not-selected pair must never reset the active estimate.
    static func selectedPath(in reports: [LatencyStatsReport]) -> Path? {
        let byID = Dictionary(reports.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(reports.filter { $0.type == "transport" }
            .compactMap { $0.values["selectedCandidatePairId"] as? String })
        guard ids.count == 1, let id = ids.first, let pair = byID[id],
              pair.type == "candidate-pair", pair.values["state"] as? String == "succeeded",
              let localID = pair.values["localCandidateId"] as? String,
              let remoteID = pair.values["remoteCandidateId"] as? String,
              let local = byID[localID]?.values["candidateType"] as? String,
              let remote = byID[remoteID]?.values["candidateType"] as? String,
              ["host", "srflx", "prflx", "relay"].contains(local),
              ["host", "srflx", "prflx", "relay"].contains(remote) else { return nil }
        return Path(id: id, localType: local, remoteType: remote)
    }
}
#endif

#if DEBUG
import Foundation

/// Controls only the lab settings and segment boundaries. The caller owns
/// readiness, trace delivery and the existing transport handoff.
struct LatencyLabPairRun {
    enum Action {
        case apply(LatencyLabConfiguration)
        case trace([String: Any])
    }
    private enum Phase {
        case initial
        case waiting(requestedAt: Double, readySince: Double?)
        case measuring(end: Double)
        case finished
    }

    private let fix: String
    private let baseline: LatencyLabConfiguration
    private let runID = UUID()
    private var phase: Phase = .initial
    private var trial = 1
    private var previousTick: Double?
    private(set) var configuration: LatencyLabConfiguration
    var finished: Bool { if case .finished = phase { return true }; return false }

    init?(fix: String, maximumDelayMs: Int) {
        guard ["F1", "F2", "F3", "F4"].contains(fix), [0, 10, 20].contains(maximumDelayMs) else { return nil }
        var baseline = LatencyLabConfiguration()
        baseline.f1MaximumDelayMs = maximumDelayMs
        self.fix = fix; self.baseline = baseline; self.configuration = baseline
    }

    /// Only the explicitly requested launch argument pair opts in.
    static func make(arguments: [String], maximumDelayMs: Int) -> LatencyLabPairRun? {
        guard arguments.contains("LatencyProbe"),
              let index = arguments.firstIndex(of: "LatencyLabPairFix"),
              arguments.indices.contains(index + 1) else { return nil }
        return LatencyLabPairRun(fix: arguments[index + 1], maximumDelayMs: maximumDelayMs)
    }

    mutating func tick(now: Double, ready: Bool, currentConfiguration: LatencyLabConfiguration) -> [Action] {
        guard !finished else { return [] }
        guard now.isFinite, now >= 0, previousTick.map({ now >= $0 }) ?? true else {
            return abort(at: previousTick ?? 0, reason: "invalid_clock")
        }
        previousTick = now
        if case .initial = phase {
            configuration = baseline
            phase = .waiting(requestedAt: now, readySince: nil)
            return [.apply(configuration), trace(stage: "requested", time: now)]
        }
        guard currentConfiguration == configuration else { return abort(at: now, reason: "configuration_changed") }
        switch phase {
        case .waiting(let requestedAt, let readySince):
            guard now - requestedAt < 45 else { return abort(at: now, reason: "readiness_timeout") }
            guard ready else {
                phase = .waiting(requestedAt: requestedAt, readySince: nil)
                return []
            }
            guard let readySince else {
                phase = .waiting(requestedAt: requestedAt, readySince: now)
                return []
            }
            guard now - readySince >= 5 else { return [] }
            phase = .measuring(end: now + 30)
            return [trace(stage: "begin", time: now)]
        case .measuring(let end):
            guard now >= end else { return [] }
            let endTrace = trace(stage: "end", time: end)
            guard trial < 8 else {
                phase = .finished
                let complete = trace(stage: "complete", time: end)
                configuration = baseline
                return [endTrace, complete, .apply(baseline)]
            }
            trial += 1
            configuration = requestedConfiguration(for: trial)
            phase = .waiting(requestedAt: now, readySince: nil)
            return [endTrace, .apply(configuration), trace(stage: "requested", time: now)]
        case .initial, .finished:
            return []
        }
    }

    private func requestedConfiguration(for trial: Int) -> LatencyLabConfiguration {
        var result = baseline
        guard trial.isMultiple(of: 2) else { return result }
        switch fix {
        case "F1": result.f1Playout = true
        case "F2": result.f2Encoder = true
        case "F3": result.f3Sender = true
        case "F4": result.f4Renderer = true
        default: break
        }
        return result
    }

    private func trace(stage: String, time: Double, reason: String? = nil) -> Action {
        var fields: [String: Any] = ["type": "lab_pair", "run": runID.uuidString, "fix": fix,
            "trial": trial, "pair": (trial + 1) / 2, "arm": trial.isMultiple(of: 2) ? "B" : "A",
            "stage": stage, "time": time, "settings": configuration.traceValues]
        if let reason { fields["reason"] = reason }
        return .trace(fields)
    }

    private mutating func abort(at time: Double, reason: String) -> [Action] {
        let event = trace(stage: "aborted", time: time, reason: reason)
        phase = .finished
        configuration = baseline
        return [event, .apply(baseline)]
    }
}
#endif

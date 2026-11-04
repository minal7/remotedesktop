import Foundation

/// Experimental settings are read at connection/surface creation. Reconnect
/// after changing them; Release always uses the shipping path.
struct LatencyLabConfiguration: Equatable, Sendable {
    private final class RuntimeState: @unchecked Sendable {
        let lock = NSLock()
        var value: LatencyLabConfiguration?
    }
    private static let runtime = RuntimeState()
    var f1Playout = false
    var f1MaximumDelayMs = 0
    var f2Encoder = false
    var f3Sender = false
    var f4Renderer = false

    static var current: Self {
        #if DEBUG
        runtime.lock.lock()
        let override = runtime.value
        runtime.lock.unlock()
        if let override { return override }
        let environment = ProcessInfo.processInfo.environment
        let arguments = ProcessInfo.processInfo.arguments
        let labOptIn = arguments.contains("LatencyProbe") || arguments.contains("LatencyLab")
            || environment["LATENCY_LAB"] == "1"
        func flag(_ key: String, environmentKey: String) -> Bool {
            if let value = environment[environmentKey] { return value == "1" }
            return arguments.contains(key) || UserDefaults.standard.bool(forKey: key)
        }
        let requestedDelay = environment["LATENCY_LAB_F1_MAX_MS"].flatMap(Int.init)
            ?? (UserDefaults.standard.object(forKey: "LatencyLabF1MaxMs") == nil
                ? (labOptIn ? 10 : 0) : UserDefaults.standard.integer(forKey: "LatencyLabF1MaxMs"))
        let f1Enabled: Bool
        if let value = environment["LATENCY_LAB_F1"] {
            f1Enabled = value == "1"
        } else if arguments.contains("LatencyLabF1") {
            f1Enabled = true
        } else if UserDefaults.standard.object(forKey: "LatencyLabF1") != nil {
            f1Enabled = UserDefaults.standard.bool(forKey: "LatencyLabF1")
        } else {
            f1Enabled = labOptIn
        }
        return Self(
            f1Playout: f1Enabled,
            f1MaximumDelayMs: [0, 10, 20].contains(requestedDelay) ? requestedDelay : 0,
            f2Encoder: flag("LatencyLabF2", environmentKey: "LATENCY_LAB_F2"),
            f3Sender: flag("LatencyLabF3", environmentKey: "LATENCY_LAB_F3"),
            f4Renderer: flag("LatencyLabF4", environmentKey: "LATENCY_LAB_F4"))
        #else
        return Self()
        #endif
    }

    static func setRuntime(_ configuration: Self) {
        #if DEBUG
        var valid = configuration
        if ![0, 10, 20].contains(valid.f1MaximumDelayMs) { valid.f1MaximumDelayMs = 0 }
        runtime.lock.lock()
        runtime.value = valid
        runtime.lock.unlock()
        NotificationCenter.default.post(name: .latencyLabConfigurationDidChange, object: nil)
        #endif
    }

    var traceValues: [String: Any] {
        ["f1Playout": f1Playout, "f1MaximumDelayMs": f1MaximumDelayMs,
         "f2Encoder": f2Encoder, "f3Sender": f3Sender, "f4Renderer": f4Renderer]
    }
}

extension Notification.Name {
    static let latencyLabConfigurationDidChange = Notification.Name("LatencyLabConfigurationDidChange")
}

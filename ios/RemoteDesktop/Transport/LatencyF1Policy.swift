#if DEBUG
struct LatencyLabSelection: Equatable {
    var f1MaximumDelayMs: Int?
    var f2: Bool
    var f3: Bool
    var f4: Bool
}

enum LatencyF1Policy {
    static func shouldRequest(enabled: Bool, ordinaryRemoteSession: Bool, hostCapability: Int,
                              maximumDelayMs: Int) -> Bool {
        enabled && ordinaryRemoteSession && hostCapability == 1 && [0, 10, 20].contains(maximumDelayMs)
    }

    static func shouldRequestF2(enabled: Bool, ordinaryRemoteSession: Bool,
                                handoffCapability: Int, hostF2Capability: Int) -> Bool {
        enabled && ordinaryRemoteSession && handoffCapability == 1 && hostF2Capability == 1
    }

    static func needsNewFactory(currentMaximumMs: Int?, desiredMaximumMs: Int?) -> Bool {
        currentMaximumMs != desiredMaximumMs
    }

    static func acceptsSignaling(activeNonce: String?, messageNonce: String?) -> Bool {
        return activeNonce == messageNonce
    }

    static func selection(configuration: LatencyLabConfiguration, hello: HostHello) -> LatencyLabSelection {
        let f1 = shouldRequest(enabled: configuration.f1Playout, ordinaryRemoteSession: true,
                               hostCapability: hello.latencyF1Playout, maximumDelayMs: configuration.f1MaximumDelayMs)
        let f2 = shouldRequestF2(enabled: configuration.f2Encoder, ordinaryRemoteSession: true,
                                 handoffCapability: hello.latencyF1Playout, hostF2Capability: hello.latencyF2Encoder)
        let f3 = configuration.f3Sender && hello.latencyF1Playout == 1 && hello.latencyF3Sender == 1
        return LatencyLabSelection(f1MaximumDelayMs: f1 ? configuration.f1MaximumDelayMs : nil,
                                   f2: f2, f3: f3, f4: configuration.f4Renderer)
    }
}
#endif

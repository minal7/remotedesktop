import Foundation

@MainActor
protocol AgentRecording: AnyObject {
    func record(_ step: AgentEpisodeStep) throws
    func finish(_ footer: AgentEpisodeFooter) throws
}

/// Same durable attempted/verified/uncertain semantics as the existing task journal.
@MainActor
protocol AgentEffectJournaling: AnyObject {
    func begin(step: Int, fingerprint: String) throws
    func verify(step: Int, fingerprint: String) throws
    func markUncertain(step: Int, fingerprint: String) throws
    func assertMayContinue() throws
}

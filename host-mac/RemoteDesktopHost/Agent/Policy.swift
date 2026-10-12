import Foundation

struct AgentPolicyOutput {
    let rawOutput: String
    let action: AgentAction?
    let rejectionReason: String?
}

@MainActor
protocol AgentPolicy: AnyObject {
    var promptVersion: String { get }
    func propose(_ observation: AgentObservation) async throws -> AgentPolicyOutput
    func suspend() async
    func resume() async throws
    func stop() async
}

extension AgentPolicy {
    func suspend() async { await stop() }
    func resume() async throws {}
}

import Foundation

struct AgentPolicyOutput {
    let rawOutput: String
    let action: AgentAction?
    let rejectionReason: String?
    let resultLineNote: String?
    let progressText: String?

    init(rawOutput: String, action: AgentAction?, rejectionReason: String?,
         resultLineNote: String? = nil, progressText: String? = nil) {
        self.rawOutput = rawOutput; self.action = action; self.rejectionReason = rejectionReason
        self.resultLineNote = resultLineNote; self.progressText = progressText
    }
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

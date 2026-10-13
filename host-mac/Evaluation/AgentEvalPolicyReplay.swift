#if DEBUG
import Foundation

struct AgentEvalPolicyReplayRequest: Decodable {
    let observation: AgentObservation

    static func decodeStrict(_ data: Data) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["operation", "policy", "observation"],
              object["operation"] as? String == "policy_replay",
              object["policy"] as? String == AgentPolicyModel.fara15_4b.rawValue else {
            throw AgentEvalWireError.invalidRequest
        }
        let request = try JSONDecoder().decode(Self.self, from: data)
        try request.observation.validate()
        return request
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case operation, policy, observation }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases) else { throw AgentEvalWireError.invalidRequest }
        guard try container.decode(String.self, forKey: .operation) == "policy_replay",
              try container.decode(String.self, forKey: .policy) == AgentPolicyModel.fara15_4b.rawValue else {
            throw AgentEvalWireError.invalidRequest
        }
        observation = try container.decode(AgentObservation.self, forKey: .observation)
    }
}

struct AgentEvalPolicyReplayResponse: Encodable {
    let operation = "policy_replay"
    let policy = AgentPolicyModel.fara15_4b.rawValue
    let executed = false
    let rawModelOutput: String
    let action: AgentAction?
    let rejectionReason: String?
    let promptVersion: String

    private enum CodingKeys: String, CodingKey {
        case operation, policy, executed, action
        case rawModelOutput = "raw_model_output"
        case rejectionReason = "rejection_reason"
        case promptVersion = "prompt_version"
    }
}

@MainActor
enum AgentEvalPolicyReplay {
    static func run(_ request: AgentEvalPolicyReplayRequest) async throws -> AgentEvalPolicyReplayResponse {
        let inputs = try await AgentEvalPreflight.resolveRuntimeInputs(model: .fara15_4b)
        let policy = try LlamaVLMPolicy(runtimeInputs: inputs)
        do {
            let output = try await policy.propose(request.observation)
            await policy.stop()
            return AgentEvalPolicyReplayResponse(rawModelOutput: output.rawOutput,
                action: output.action, rejectionReason: output.rejectionReason,
                promptVersion: policy.promptVersion)
        } catch {
            await policy.stop()
            await OSAtlasLlamaRuntime.shared.shutdown()
            throw error
        }
    }
}
#endif

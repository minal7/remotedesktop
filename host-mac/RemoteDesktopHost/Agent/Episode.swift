import Foundation

public enum AgentGateDecision: String, Codable { case allowed, needsApproval = "needs_approval", rejected }
public enum AgentExecutionStatus: String, Codable { case ok, rejected, error, notExecuted = "not_executed" }

public struct AgentGateResult: Equatable, Codable {
    public let decision: AgentGateDecision
    public let reason: String
    public let fingerprint: String?
    public let scopeIdentity: String?
    public let riskTier: String?

    public init(decision: AgentGateDecision, reason: String, fingerprint: String? = nil,
                scopeIdentity: String? = nil, riskTier: String? = nil) {
        self.decision = decision; self.reason = reason; self.fingerprint = fingerprint
        self.scopeIdentity = scopeIdentity; self.riskTier = riskTier
    }

    private func validate() throws {
        if let fingerprint {
            try AgentContractValidation.require(fingerprint.utf8.count == 64 && fingerprint.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }, "gate.fingerprint must be a SHA-256 digest")
        }
        if let scopeIdentity { try AgentContractValidation.requireNonEmpty(scopeIdentity, "gate.scope_identity") }
        if let riskTier { try AgentContractValidation.require(["low", "medium", "high"].contains(riskTier), "invalid risk tier") }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AgentCodingKey.self)
        try container.requireKeys(["decision", "reason"], optional: ["fingerprint", "scope_identity", "risk_tier"])
        decision = try container.decodeRequired(AgentGateDecision.self, "decision")
        reason = try container.decodeRequired(String.self, "reason")
        fingerprint = try container.decodeOptionalValue(String.self, "fingerprint")
        scopeIdentity = try container.decodeOptionalValue(String.self, "scope_identity")
        riskTier = try container.decodeOptionalValue(String.self, "risk_tier")
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: AgentCodingKey.self)
        try container.encodeRequired(decision, "decision"); try container.encodeRequired(reason, "reason")
        try container.encodeIfPresent(fingerprint, forKey: AgentCodingKey("fingerprint"))
        try container.encodeIfPresent(scopeIdentity, forKey: AgentCodingKey("scope_identity"))
        try container.encodeIfPresent(riskTier, forKey: AgentCodingKey("risk_tier"))
    }
}

public struct AgentExecutionResult: Equatable, Codable {
    public let status: AgentExecutionStatus
    public let result: String

    public init(status: AgentExecutionStatus, result: String) { self.status = status; self.result = result }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AgentCodingKey.self)
        try container.requireKeys(["status", "result"])
        status = try container.decodeRequired(AgentExecutionStatus.self, "status"); result = try container.decodeRequired(String.self, "result")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AgentCodingKey.self)
        try container.encodeRequired(status, "status"); try container.encodeRequired(result, "result")
    }
}

public struct AgentTimings: Equatable, Codable {
    public let observationMS: Int
    public let policyMS: Int
    public let gateMS: Int
    public let executionMS: Int
    public let recordMS: Int
    public let totalMS: Int

    public init(observationMS: Int, policyMS: Int, gateMS: Int,
                executionMS: Int, recordMS: Int, totalMS: Int) {
        self.observationMS = observationMS; self.policyMS = policyMS; self.gateMS = gateMS
        self.executionMS = executionMS; self.recordMS = recordMS; self.totalMS = totalMS
    }

    public func validate() throws {
        let values = [observationMS, policyMS, gateMS, executionMS, recordMS, totalMS]
        try AgentContractValidation.require(values.allSatisfy { $0 >= 0 }, "timing values must be nonnegative")
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AgentCodingKey.self)
        let keys: Set<String> = ["observation_ms", "policy_ms", "gate_ms", "execution_ms", "record_ms", "total_ms"]
        try container.requireKeys(keys)
        observationMS = try container.decodeRequired(Int.self, "observation_ms")
        policyMS = try container.decodeRequired(Int.self, "policy_ms")
        gateMS = try container.decodeRequired(Int.self, "gate_ms")
        executionMS = try container.decodeRequired(Int.self, "execution_ms")
        recordMS = try container.decodeRequired(Int.self, "record_ms")
        totalMS = try container.decodeRequired(Int.self, "total_ms")
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: AgentCodingKey.self)
        try container.encodeRequired(observationMS, "observation_ms")
        try container.encodeRequired(policyMS, "policy_ms")
        try container.encodeRequired(gateMS, "gate_ms")
        try container.encodeRequired(executionMS, "execution_ms")
        try container.encodeRequired(recordMS, "record_ms")
        try container.encodeRequired(totalMS, "total_ms")
    }
}

public struct AgentEpisodeStep: Equatable, Codable {
    public let episodeID: String
    public let step: Int
    public let observation: AgentObservation
    public let promptVersion: String
    public let rawModelOutput: String
    public let action: AgentAction?
    public let gate: AgentGateResult
    public let execution: AgentExecutionResult
    public let timings: AgentTimings

    public init(episodeID: String, step: Int, observation: AgentObservation, promptVersion: String,
                rawModelOutput: String, action: AgentAction?, gate: AgentGateResult,
                execution: AgentExecutionResult, timings: AgentTimings) {
        self.episodeID = episodeID; self.step = step; self.observation = observation; self.promptVersion = promptVersion
        self.rawModelOutput = rawModelOutput; self.action = action; self.gate = gate; self.execution = execution; self.timings = timings
    }

    public func validate() throws {
        try AgentContractValidation.requireNonEmpty(episodeID, "episode_id")
        try AgentContractValidation.require(step >= 0, "step must be nonnegative")
        try AgentContractValidation.requireNonEmpty(promptVersion, "prompt_version")
        try observation.validate(); try action?.validate(); try timings.validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AgentCodingKey.self)
        try container.requireKeys(["type", "episode_id", "step", "observation", "prompt_version", "raw_model_output", "action", "gate", "execution", "timings"])
        let recordType = try container.decodeRequired(String.self, "type")
        try AgentContractValidation.require(recordType == "step", "episode record type must be step")
        episodeID = try container.decodeRequired(String.self, "episode_id"); step = try container.decodeRequired(Int.self, "step")
        observation = try container.decodeRequired(AgentObservation.self, "observation")
        promptVersion = try container.decodeRequired(String.self, "prompt_version"); rawModelOutput = try container.decodeRequired(String.self, "raw_model_output")
        action = try container.decodeNullable(AgentAction.self, "action"); gate = try container.decodeRequired(AgentGateResult.self, "gate")
        execution = try container.decodeRequired(AgentExecutionResult.self, "execution"); timings = try container.decodeRequired(AgentTimings.self, "timings")
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: AgentCodingKey.self)
        try container.encodeRequired("step", "type"); try container.encodeRequired(episodeID, "episode_id"); try container.encodeRequired(step, "step")
        try container.encodeRequired(observation, "observation"); try container.encodeRequired(promptVersion, "prompt_version")
        try container.encodeRequired(rawModelOutput, "raw_model_output"); try container.encodeNullable(action, "action")
        try container.encodeRequired(gate, "gate"); try container.encodeRequired(execution, "execution"); try container.encodeRequired(timings, "timings")
    }
}

public struct AgentEpisodeFooter: Equatable, Codable {
    public let episodeID: String
    public let outcome: String
    public let approvals: [String]
    public let corrections: [String]
    public let checkerVerdict: String?

    public init(episodeID: String, outcome: String, approvals: [String], corrections: [String], checkerVerdict: String? = nil) {
        self.episodeID = episodeID; self.outcome = outcome; self.approvals = approvals
        self.corrections = corrections; self.checkerVerdict = checkerVerdict
    }

    public func validate() throws {
        try AgentContractValidation.requireNonEmpty(episodeID, "episode_id")
        try AgentContractValidation.requireNonEmpty(outcome, "outcome")
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AgentCodingKey.self)
        try container.requireKeys(["type", "episode_id", "outcome", "approvals", "corrections"], optional: ["checker_verdict"])
        let recordType = try container.decodeRequired(String.self, "type")
        try AgentContractValidation.require(recordType == "footer", "episode record type must be footer")
        episodeID = try container.decodeRequired(String.self, "episode_id"); outcome = try container.decodeRequired(String.self, "outcome")
        approvals = try container.decodeRequired([String].self, "approvals"); corrections = try container.decodeRequired([String].self, "corrections")
        checkerVerdict = try container.decodeOptionalValue(String.self, "checker_verdict"); try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: AgentCodingKey.self)
        try container.encodeRequired("footer", "type"); try container.encodeRequired(episodeID, "episode_id"); try container.encodeRequired(outcome, "outcome")
        try container.encodeRequired(approvals, "approvals"); try container.encodeRequired(corrections, "corrections")
        try container.encodeIfPresent(checkerVerdict, forKey: AgentCodingKey("checker_verdict"))
    }
}

public enum AgentEpisodeRecord: Equatable, Codable {
    case step(AgentEpisodeStep)
    case footer(AgentEpisodeFooter)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AgentCodingKey.self)
        switch try container.decodeRequired(String.self, "type") {
        case "step": self = .step(try AgentEpisodeStep(from: decoder))
        case "footer": self = .footer(try AgentEpisodeFooter(from: decoder))
        default: throw AgentContractError.invalid("episode record type must be step or footer")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .step(value): try value.encode(to: encoder)
        case let .footer(value): try value.encode(to: encoder)
        }
    }
}

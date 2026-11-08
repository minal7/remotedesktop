#if DEBUG
import Darwin
import Foundation

struct AgentEvalPolicyReplayRequest: Decodable {
    let observations: [AgentObservation]
    let isSequence: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable { case operation, policy, observation, observations }

    static func decodeStrict(_ data: Data) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).contains("operation"), Set(object.keys).contains("policy"),
              object["operation"] as? String == "policy_replay",
              object["policy"] as? String == AgentPolicyModel.fara15_4b.rawValue else {
            throw AgentEvalWireError.invalidRequest
        }
        let keys = Set(object.keys)
        guard keys == ["operation", "policy", "observation"] ||
              keys == ["operation", "policy", "observations"] else {
            throw AgentEvalWireError.invalidRequest
        }
        let request = try JSONDecoder().decode(Self.self, from: data)
        guard (1...10).contains(request.observations.count) else { throw AgentEvalWireError.invalidRequest }
        try request.observations.forEach { try $0.validate() }
        guard let first = request.observations.first,
              request.observations.allSatisfy({ $0.task == first.task && $0.surface == first.surface }),
              zip(request.observations, request.observations.dropFirst()).allSatisfy({
                  $0.0.budget.step < $0.1.budget.step
              }) else {
            throw AgentEvalWireError.invalidRequest
        }
        return request
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keys = Set(container.allKeys)
        guard keys == [.operation, .policy, .observation] ||
              keys == [.operation, .policy, .observations] else { throw AgentEvalWireError.invalidRequest }
        guard try container.decode(String.self, forKey: .operation) == "policy_replay",
              try container.decode(String.self, forKey: .policy) == AgentPolicyModel.fara15_4b.rawValue else {
            throw AgentEvalWireError.invalidRequest
        }
        if keys.contains(.observation) {
            observations = [try container.decode(AgentObservation.self, forKey: .observation)]
            isSequence = false
        } else {
            observations = try container.decode([AgentObservation].self, forKey: .observations)
            isSequence = true
        }
    }
}

struct AgentEvalPolicyReplayCall: Encodable {
    let index: Int
    let observationStep: Int
    let rawModelOutput: String
    let action: AgentAction?
    let rejectionReason: String?
    let promptVersion: String

    private enum CodingKeys: String, CodingKey {
        case index, action
        case observationStep = "observation_step"
        case rawModelOutput = "raw_model_output"
        case rejectionReason = "rejection_reason"
        case promptVersion = "prompt_version"
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
    let calls: [AgentEvalPolicyReplayCall]?
    let resultSemantics: String?

    private enum CodingKeys: String, CodingKey {
        case operation, policy, executed, action
        case rawModelOutput = "raw_model_output"
        case rejectionReason = "rejection_reason"
        case promptVersion = "prompt_version"
        case calls
        case resultSemantics = "result_semantics"
    }
}

@MainActor
enum AgentEvalPolicyReplay {
    static func run(_ request: AgentEvalPolicyReplayRequest) async throws -> AgentEvalPolicyReplayResponse {
        let inputs = try await AgentEvalPreflight.resolveRuntimeInputs(model: .fara15_4b)
        let capture = try FaraExchangeCapture.fromEnvironment()
        let runtime = capture.map { OSAtlasLlamaRuntime(inspectFaraExchange: $0.record) } ?? .shared
        let policy = try LlamaVLMPolicy(runtimeInputs: inputs, runtime: runtime)
        do {
            var calls: [AgentEvalPolicyReplayCall] = []
            calls.reserveCapacity(request.observations.count)
            for (index, observation) in request.observations.enumerated() {
                let output = try await policy.propose(observation)
                calls.append(AgentEvalPolicyReplayCall(index: index,
                    observationStep: observation.budget.step, rawModelOutput: output.rawOutput,
                    action: output.action, rejectionReason: output.rejectionReason,
                    promptVersion: policy.promptVersion))
            }
            guard let last = calls.last else { throw AgentEvalWireError.invalidRequest }
            try capture?.requireCapture(expectedCount: request.observations.count)
            await policy.stop()
            if capture != nil { await runtime.shutdown() }
            return AgentEvalPolicyReplayResponse(rawModelOutput: last.rawModelOutput,
                action: last.action, rejectionReason: last.rejectionReason,
                promptVersion: policy.promptVersion,
                calls: request.isSequence ? calls : nil,
                resultSemantics: request.isSequence ? "newly_generated_outputs_with_saved_observation_feedback" : nil)
        } catch {
            await policy.stop()
            // The legacy replay path already shut down the shared runtime on
            // errors; capture mode also tears down its dedicated runtime.
            await runtime.shutdown()
            throw error
        }
    }
}

/// Optional, DEBUG-only exchange capture for execution-free policy replay. The
/// callback receives HTTP bodies only; authentication headers are never stored.
private final class FaraExchangeCapture: @unchecked Sendable {
    private let directoryPath: String
    private let lock = NSLock()
    private var nextIndex = 0
    private var failed = false
    private var capturedCount = 0

    private init(directoryPath: String) {
        self.directoryPath = directoryPath
    }

    static func fromEnvironment() throws -> FaraExchangeCapture? {
        let key = "REMOTE_DESKTOP_FARA_CAPTURE_DIR"
        guard let path = ProcessInfo.processInfo.environment[key] else { return nil }
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4_096 else {
            throw AgentEvalWireError.invalidRequest
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path == path, url.resolvingSymlinksInPath().standardizedFileURL.path == path else {
            throw AgentEvalWireError.invalidRequest
        }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw AgentEvalWireError.bootstrapFailure }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & 0o777 == 0o700 else {
            throw AgentEvalWireError.invalidRequest
        }
        return FaraExchangeCapture(directoryPath: path)
    }

    func record(_ request: Data, _ response: Data) {
        guard let payload = try? JSONSerialization.data(withJSONObject: [
            "request_base64": request.base64EncodedString(),
            "response_base64": response.base64EncodedString(),
        ], options: [.sortedKeys]) else {
            markFailed()
            return
        }
        let index = lock.withLock { defer { nextIndex += 1 }; return nextIndex }
        let directory = open(directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { markFailed(); return }
        defer { close(directory) }
        var metadata = stat()
        guard fstat(directory, &metadata) == 0,
              metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & 0o777 == 0o700 else {
            markFailed()
            return
        }
        let name = String(format: "%03d.exchange.json", index)
        let descriptor = openat(directory, name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { markFailed(); return }
        defer { close(descriptor) }
        do {
            try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: payload)
            guard fsync(descriptor) == 0 else { throw AgentEvalWireError.bootstrapFailure }
            lock.withLock { capturedCount += 1 }
        } catch {
            _ = unlinkat(directory, name, 0)
            markFailed()
        }
    }

    func requireCapture(expectedCount: Int) throws {
        let result = lock.withLock { (capturedCount, failed) }
        guard result.0 == expectedCount, !result.1 else { throw AgentEvalWireError.bootstrapFailure }
    }

    private func markFailed() {
        lock.withLock { failed = true }
    }
}
#endif

import Foundation

struct AgentVLMRequestInput: Sendable {
    let prompt: String
    let observationJSON: String
    let screenshotPNG: Data
    let actionSchema: Data
}

@MainActor
protocol AgentVLMTransport: AnyObject {
    func complete(_ input: AgentVLMRequestInput) async throws -> String
    func stop() async
}

@MainActor
final class LlamaVLMPolicy: AgentPolicy {
    let promptVersion = "v1"

    private let transport: any AgentVLMTransport
    private let prompt: String
    private let actionSchema: Data

    init(transport: any AgentVLMTransport, prompt: String, actionSchema: Data) throws {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let schema = try? JSONSerialization.jsonObject(with: actionSchema) as? [String: Any],
              schema["$schema"] as? String == "https://json-schema.org/draft/2020-12/schema",
              schema["$ref"] as? String == "#/$defs/action",
              schema["$defs"] as? [String: Any] != nil else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        self.transport = transport
        self.prompt = prompt
        self.actionSchema = actionSchema
    }

    convenience init(
        runtimeInputs: ComputerUseFaraRuntimeInputs,
        runtime: OSAtlasLlamaRuntime = .shared,
        bundle: Bundle = .main
    ) throws {
        let promptURL = try Self.resourceURL(bundle: bundle, name: "v1", extension: "txt", subdirectory: "policy/prompts")
        let schemaURL = try Self.resourceURL(bundle: bundle, name: "action.schema", extension: "json", subdirectory: "Schemas")
        let prompt = try String(contentsOf: promptURL, encoding: .utf8)
        let schema = try Data(contentsOf: schemaURL)
        try self.init(transport: RuntimeAgentVLMTransport(inputs: runtimeInputs, runtime: runtime),
                      prompt: prompt, actionSchema: schema)
    }

    func propose(_ observation: AgentObservation) async throws -> AgentPolicyOutput {
        try observation.validate()
        guard let screenshot = Data(base64Encoded: observation.screenshot) else {
            throw OSAtlasLlamaRuntimeError.invalidVisionInput
        }
        try ComputerUseFaraModel.validatePNG(screenshot)
        let requestInput = AgentVLMRequestInput(prompt: prompt,
            observationJSON: try Self.observationJSON(observation),
            screenshotPNG: screenshot, actionSchema: actionSchema)
        let transport = self.transport
        let raw = try await withTaskCancellationHandler {
            try await transport.complete(requestInput)
        } onCancel: {
            Task { @MainActor in await transport.stop() }
        }
        guard let actionJSON = try? FaraPolicyAdapter.actionJSON(fromCompletion: raw),
              actionJSON.utf8.count <= 32_768,
              let data = actionJSON.data(using: .utf8),
              let action = try? JSONDecoder().decode(AgentAction.self, from: data) else {
            return .init(rawOutput: raw, action: nil, rejectionReason: "Model output was not one valid computer-use action.")
        }
        return .init(rawOutput: raw, action: action, rejectionReason: nil)
    }

    func stop() async {
        await transport.stop()
    }

    static func observationJSON(_ observation: AgentObservation) throws -> String {
        try observation.validate()
        let encoded = try JSONEncoder().encode(observation)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw OSAtlasLlamaRuntimeError.invalidResponse
        }
        object["screenshot"] = "[attached PNG image]"
        let data = try JSONSerialization.data(withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func resourceURL(bundle: Bundle, name: String, extension fileExtension: String,
                                    subdirectory: String) throws -> URL {
        guard let url = bundle.url(forResource: name, withExtension: fileExtension,
                                   subdirectory: subdirectory) else {
            throw OSAtlasLlamaRuntimeError.invalidLocalInstallation
        }
        return url
    }
}

@MainActor
private final class RuntimeAgentVLMTransport: AgentVLMTransport {
    private let inputs: ComputerUseFaraRuntimeInputs
    private let runtime: OSAtlasLlamaRuntime
    private var endpoint: OSAtlasLlamaEndpoint?

    init(inputs: ComputerUseFaraRuntimeInputs, runtime: OSAtlasLlamaRuntime) {
        self.inputs = inputs
        self.runtime = runtime
    }

    func complete(_ input: AgentVLMRequestInput) async throws -> String {
        try Task.checkCancellation()
        let currentEndpoint = try await runtime.activateFara(inputs)
        endpoint = currentEndpoint
        return try await runtime.completeAgentAction(endpoint: currentEndpoint, input: input)
    }

    func stop() async {
        guard let endpoint else { return }
        self.endpoint = nil
        await runtime.cancel(endpoint: endpoint)
    }
}

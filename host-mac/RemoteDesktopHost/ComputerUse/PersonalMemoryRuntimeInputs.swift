import Foundation
import MemoryStoreKit

/// Verified data and the signed executable for the local embedding worker.
/// The resolver owns model hash and size verification plus executable containment checks.
struct PersonalMemoryRuntimeInputs: Equatable, Sendable {
    static let modelFileName = "nomic-embed-text-v1.5.Q8_0.gguf"
    static let modelIdentity = "nomic-ai/nomic-embed-text-v1.5-GGUF@0188c9bf409793f810680a5a431e7b899c46104c:nomic-embed-text-v1.5.Q8_0.gguf"
    static let modelSHA256 = "3e24342164b3d94991ba9692fdc0dd08e3fd7362e0aacc396a9a5c54a544c3b7"
    static let modelByteCount = 146_146_432
    static let embeddingDimensions = 768
    static let contextTokens = 8_192
    static let maximumEmbeddingInputTokens = 512
    static let llamaServerBuildInfo = "b9992-6eddde06a"

    let modelURL: URL
    let llamaServerURL: URL

    init(modelURL: URL, llamaServerURL: URL) {
        self.modelURL = modelURL.standardizedFileURL
        self.llamaServerURL = llamaServerURL.standardizedFileURL
    }
}

/// Runtime-scoped client contract. The client never owns lifecycle or a process;
/// every call is made while OSAtlasLlamaRuntime holds its model-access lease.
protocol PersonalMemoryRuntimeClient: Sendable {
    func embed(endpoint: LlamaCppLocalEndpoint, text: String,
                purpose: MemoryEmbeddingPurpose) async throws -> [Float]
    func countTokens(endpoint: LlamaCppLocalEndpoint, context: String,
                     tokenizer: LlamaCppTokenizerIdentity) async throws -> Int
}

struct LocalPersonalMemoryRuntimeClient: PersonalMemoryRuntimeClient {
    func embed(endpoint: LlamaCppLocalEndpoint, text: String,
                purpose: MemoryEmbeddingPurpose) async throws -> [Float] {
        try await LlamaCppMemoryEmbeddingProvider(
            endpoint: endpoint,
            maximumInputTokens: PersonalMemoryRuntimeInputs.maximumEmbeddingInputTokens)
            .embed(text, purpose: purpose)
    }

    func countTokens(endpoint: LlamaCppLocalEndpoint, context: String,
                     tokenizer: LlamaCppTokenizerIdentity) async throws -> Int {
        try await LlamaCppMemoryTokenCounter(endpoint: endpoint, tokenizer: tokenizer)
            .countTokens(in: context)
    }
}

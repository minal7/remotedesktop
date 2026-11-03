import Foundation

protocol ComputerUseTextModelTransport: Sendable {
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int
    func complete(request: URLRequest) async throws -> Data
}

/// Connection authority is supplied by the host's runtime owner, never by a
/// task or model response. Installation/process qualification is a separate
/// prerequisite; this adapter alone does not make a runtime trusted or ready.
struct ComputerUseTextModelConnection: Sendable {
    let baseURL: URL
    let bearerToken: String
    let modelAlias: String

    init(baseURL: URL, bearerToken: String, modelAlias: String) throws {
        try OSAtlasLlamaRuntime.validateLoopbackEndpoint(baseURL)
        guard let port = baseURL.port, (1...65_535).contains(port),
              baseURL.path.isEmpty || baseURL.path == "/",
              (16...256).contains(bearerToken.utf8.count),
              bearerToken.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }),
              !modelAlias.isEmpty, modelAlias.utf8.count <= 128,
              modelAlias.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains($0)
              }) else { throw OSAtlasLlamaRuntimeError.invalidEndpoint }
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.modelAlias = modelAlias
    }
}

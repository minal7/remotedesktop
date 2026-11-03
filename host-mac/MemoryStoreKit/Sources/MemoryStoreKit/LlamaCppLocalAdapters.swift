import Foundation
import CoreFoundation

/// Endpoint material is supplied by an owner-controlled runtime. This adapter never starts a
/// process, resolves a hostname, downloads a model, or chooses a port.
public struct LlamaCppLocalEndpoint: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let baseURL: URL
    private let bearerToken: String

    public init(baseURL: URL, bearerToken: String) throws {
        guard let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              parts.scheme == "http", parts.host == "127.0.0.1",
              let port = parts.port, (1...65_535).contains(port),
              parts.user == nil, parts.password == nil, parts.query == nil,
              parts.fragment == nil, parts.path.isEmpty,
              !bearerToken.isEmpty, bearerToken.utf8.count <= 512,
              !bearerToken.utf8.contains(0), !bearerToken.contains("\r"),
              !bearerToken.contains("\n") else {
            throw LlamaCppAdapterError.invalidConfiguration
        }
        self.baseURL = baseURL
        self.bearerToken = bearerToken
    }

    public var description: String { "LlamaCppLocalEndpoint(127.0.0.1:<port>, credential:redacted)" }
    public var debugDescription: String { description }

    fileprivate func authorizationValue() -> String { "Bearer \(bearerToken)" }
    fileprivate func url(path: String) -> URL { baseURL.appendingPathComponent(path) }
}

public enum LlamaCppAdapterError: Error, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    case invalidConfiguration
    case inputTooLarge
    case responseTooLarge
    case transportFailure
    case rejectedResponse
    case invalidResponse
    case invalidEmbedding
    case cancellation

    public var description: String {
        switch self {
        case .invalidConfiguration: "Local model adapter configuration is invalid."
        case .inputTooLarge: "Local model adapter input exceeds its limit."
        case .responseTooLarge: "Local model adapter response exceeds its limit."
        case .transportFailure: "Local model adapter request failed."
        case .rejectedResponse: "Local model runtime rejected the request."
        case .invalidResponse: "Local model runtime returned an invalid response."
        case .invalidEmbedding: "Local model runtime returned an invalid embedding."
        case .cancellation: "Local model adapter request was cancelled."
        }
    }
    public var debugDescription: String { description }
}

/// The embedding tokenizer is explicit because this model's tokenizer must not be assumed to
/// match a future planner model. `addSpecialTokens` defaults false per the pinned server API;
/// callers must choose `parseSpecialTokens` for the planner's exact serialization contract.
public struct LlamaCppTokenizerIdentity: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let value: String
    public let addSpecialTokens: Bool
    public let parseSpecialTokens: Bool

    public init(value: String, addSpecialTokens: Bool = false, parseSpecialTokens: Bool) throws {
        guard !value.isEmpty, value.utf8.count <= 256, !value.utf8.contains(0) else {
            throw LlamaCppAdapterError.invalidConfiguration
        }
        self.value = value
        self.addSpecialTokens = addSpecialTokens
        self.parseSpecialTokens = parseSpecialTokens
    }

    public var description: String { "LlamaCppTokenizerIdentity(configured, special-token settings explicit)" }
    public var debugDescription: String { description }
}

public struct LlamaCppMemoryEmbeddingProvider: LocalMemoryEmbeddingProvider, Sendable {
    public static let pinnedModelIdentity =
        "nomic-ai/nomic-embed-text-v1.5-GGUF@0188c9bf409793f810680a5a431e7b899c46104c:nomic-embed-text-v1.5.Q8_0.gguf"
    public static let pinnedQ8SHA256 =
        "3e24342164b3d94991ba9692fdc0dd08e3fd7362e0aacc396a9a5c54a544c3b7"
    public let identity = Self.pinnedModelIdentity
    public let dimensions = 768
    private let endpoint: LlamaCppLocalEndpoint
    private let transport: any LlamaCppHTTPTransport
    private let maximumInputTokens: Int?

    public init(endpoint: LlamaCppLocalEndpoint, maximumInputTokens: Int? = nil) {
        self.endpoint = endpoint
        self.transport = URLSessionLlamaCppTransport()
        self.maximumInputTokens = maximumInputTokens
    }

    init(endpoint: LlamaCppLocalEndpoint, transport: any LlamaCppHTTPTransport,
         maximumInputTokens: Int? = nil) {
        self.endpoint = endpoint
        self.transport = transport
        self.maximumInputTokens = maximumInputTokens
    }

    public func embed(_ text: String, purpose: MemoryEmbeddingPurpose) async throws -> [Float] {
        try Task.checkCancellation()
        guard !text.isEmpty, text.utf8.count <= 32_768, !text.utf8.contains(0) else {
            throw LlamaCppAdapterError.inputTooLarge
        }
        let prefix: String
        switch purpose {
        case .query: prefix = "search_query: "
        case .document: prefix = "search_document: "
        }
        let input = prefix + text
        if let maximumInputTokens {
            guard (1...8_192).contains(maximumInputTokens) else {
                throw LlamaCppAdapterError.invalidConfiguration
            }
            let tokenizer = try LlamaCppTokenizerIdentity(value: Self.pinnedModelIdentity,
                addSpecialTokens: true, parseSpecialTokens: true)
            let count = try await LlamaCppMemoryTokenCounter(endpoint: endpoint,
                tokenizer: tokenizer, transport: transport).countTokens(in: input)
            try Task.checkCancellation()
            guard count <= maximumInputTokens else { throw LlamaCppAdapterError.inputTooLarge }
        }
        // llama.cpp ignores this field in single-model mode but routes by it in router mode.
        // Composition must bind this client to the intended already-loaded local model.
        let body = try encodeJSON(["input": input, "model": Self.pinnedModelIdentity,
                                  "encoding_format": "float"])
        let request = LlamaCppHTTPRequest(url: endpoint.url(path: "v1/embeddings"), body: body,
            authorization: endpoint.authorizationValue(), maxResponseBytes: 65_536)
        let response = try await perform(request, transport: transport)
        guard (200...299).contains(response.statusCode) else { throw LlamaCppAdapterError.rejectedResponse }
        guard let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let data = root["data"] as? [[String: Any]], data.count == 1,
              let row = data.first, let index = row["index"] as? NSNumber,
              isIntegerNumber(index), index.doubleValue == 0,
              let raw = row["embedding"] as? [NSNumber], raw.count == dimensions,
              raw.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() }) else {
            throw LlamaCppAdapterError.invalidResponse
        }
        let vector = raw.map { $0.floatValue }
        guard vector.allSatisfy({ $0.isFinite }), vector.contains(where: { $0 != 0 }) else {
            throw LlamaCppAdapterError.invalidEmbedding
        }
        return vector
    }
}

public struct LlamaCppMemoryTokenCounter: MemoryExactTokenCounter, Sendable {
    private static let maximumRequestJSONBytes = 8 * 1_048_576
    public let tokenizer: LlamaCppTokenizerIdentity
    private let endpoint: LlamaCppLocalEndpoint
    private let transport: any LlamaCppHTTPTransport

    public init(endpoint: LlamaCppLocalEndpoint, tokenizer: LlamaCppTokenizerIdentity) {
        self.endpoint = endpoint
        self.tokenizer = tokenizer
        self.transport = URLSessionLlamaCppTransport()
    }

    init(endpoint: LlamaCppLocalEndpoint, tokenizer: LlamaCppTokenizerIdentity,
         transport: any LlamaCppHTTPTransport) {
        self.endpoint = endpoint
        self.tokenizer = tokenizer
        self.transport = transport
    }

    public func countTokens(in completeContext: String) async throws -> Int {
        try Task.checkCancellation()
        guard completeContext.utf8.count <= 1_048_576, !completeContext.utf8.contains(0) else {
            throw LlamaCppAdapterError.inputTooLarge
        }
        let body = try encodeJSON(["content": completeContext,
            "add_special": tokenizer.addSpecialTokens,
            "parse_special": tokenizer.parseSpecialTokens,
            "with_pieces": false])
        guard body.count <= Self.maximumRequestJSONBytes else { throw LlamaCppAdapterError.inputTooLarge }
        let request = LlamaCppHTTPRequest(url: endpoint.url(path: "tokenize"), body: body,
            authorization: endpoint.authorizationValue(), maxResponseBytes: 4 * 1_048_576)
        let response = try await perform(request, transport: transport)
        guard (200...299).contains(response.statusCode) else { throw LlamaCppAdapterError.rejectedResponse }
        guard let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let tokens = root["tokens"] as? [Any], tokens.count <= 1_000_000,
              tokens.allSatisfy({ isIntegerToken($0, maximum: Int(Int32.max)) }) else {
            throw LlamaCppAdapterError.invalidResponse
        }
        return tokens.count
    }
}

private func isIntegerToken(_ value: Any, maximum: Int) -> Bool {
    guard let number = value as? NSNumber,
          isIntegerNumber(number) else { return false }
    return number.doubleValue.isFinite && number.doubleValue >= 0 &&
        number.doubleValue <= Double(maximum) &&
        number.doubleValue.rounded(.towardZero) == number.doubleValue
}

private func isIntegerNumber(_ number: NSNumber) -> Bool {
    guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
    return ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"]
        .contains(String(cString: number.objCType))
}

private func encodeJSON(_ object: [String: Any]) throws -> Data {
    do { return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    catch { throw LlamaCppAdapterError.invalidConfiguration }
}

private func perform(_ request: LlamaCppHTTPRequest,
                     transport: any LlamaCppHTTPTransport) async throws -> LlamaCppHTTPResponse {
    do {
        let response = try await transport.send(request)
        try Task.checkCancellation()
        guard response.body.count <= request.maxResponseBytes else { throw LlamaCppAdapterError.responseTooLarge }
        return response
    }
    catch is CancellationError { throw CancellationError() }
    catch let error as URLError where error.code == .cancelled && Task.isCancelled {
        throw CancellationError()
    }
    catch let error as LlamaCppAdapterError { throw error }
    catch { throw LlamaCppAdapterError.transportFailure }
}

struct LlamaCppHTTPRequest: Sendable {
    let url: URL
    let body: Data
    let authorization: String
    let maxResponseBytes: Int
}

extension LlamaCppHTTPRequest: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "LlamaCppHTTPRequest(method:POST, endpoint:local, body:redacted, credential:redacted)" }
    var debugDescription: String { description }
}

struct LlamaCppHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
}

protocol LlamaCppHTTPTransport: Sendable {
    func send(_ request: LlamaCppHTTPRequest) async throws -> LlamaCppHTTPResponse
}

/// Production transport uses an ephemeral session, refuses redirects and bounds bytes while
/// streaming. HTTP proxy settings are disabled explicitly; endpoint validation restricts it to
/// literal IPv4 loopback, so this adapter never performs DNS resolution.
struct URLSessionLlamaCppTransport: LlamaCppHTTPTransport {
    func send(_ request: LlamaCppHTTPRequest) async throws -> LlamaCppHTTPResponse {
        try Task.checkCancellation()
        var urlRequest = URLRequest(url: request.url, timeoutInterval: 20)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(request.authorization, forHTTPHeaderField: "Authorization")
        let configuration = Self.makeConfiguration()
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw LlamaCppAdapterError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < request.maxResponseBytes else { throw LlamaCppAdapterError.responseTooLarge }
                data.append(byte)
            }
            return LlamaCppHTTPResponse(statusCode: http.statusCode, body: data)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        }
        catch let error as LlamaCppAdapterError { throw error }
        catch { throw LlamaCppAdapterError.transportFailure }
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = [:]
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
            "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0
        ]
        return configuration
    }
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

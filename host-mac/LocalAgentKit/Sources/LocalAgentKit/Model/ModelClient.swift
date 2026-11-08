import Foundation

public struct ModelMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case system, user, assistant }
    public var role: Role
    public var text: String
    public var imageJPEG: Data?

    public init(role: Role, text: String, imageJPEG: Data? = nil) {
        self.role = role; self.text = text; self.imageJPEG = imageJPEG
    }
}

public struct ModelRequest: Sendable {
    public var messages: [ModelMessage]
    /// JSON schema the output must match. Enforced by grammar in the runtime, so
    /// a malformed reply cannot happen and no retry budget is spent on parsing.
    public var schema: String?
    public var maxTokens: Int
    public var temperature: Double
    public var timeout: TimeInterval

    public init(messages: [ModelMessage], schema: String?, maxTokens: Int = 220,
                temperature: Double = 0.1, timeout: TimeInterval = 90) {
        self.messages = messages; self.schema = schema; self.maxTokens = maxTokens
        self.temperature = temperature; self.timeout = timeout
    }
}

public struct ModelReply: Sendable {
    public var text: String
    public var promptTokens: Int
    public var cachedTokens: Int
    public var outputTokens: Int
    public var seconds: Double

    public init(text: String, promptTokens: Int = 0, cachedTokens: Int = 0, outputTokens: Int = 0, seconds: Double = 0) {
        self.text = text; self.promptTokens = promptTokens; self.cachedTokens = cachedTokens
        self.outputTokens = outputTokens; self.seconds = seconds
    }
}

public enum ModelError: Error, CustomStringConvertible, Equatable {
    case notRunning
    case timeout
    case http(Int, String)
    case badResponse(String)
    case startupFailed(String)
    case contextOverflow

    public var description: String {
        switch self {
        case .notRunning: return "the local model isn't running"
        case .timeout: return "the local model took too long to answer"
        case .http(let code, let message): return "the local model returned \(code): \(message.prefix(200))"
        case .badResponse(let detail): return "the local model gave an unreadable response: \(detail.prefix(200))"
        case .startupFailed(let detail): return "the local model could not start: \(detail.prefix(300))"
        case .contextOverflow: return "the prompt was larger than the model's context"
        }
    }
}

/// The harness only needs this one call. Tests script it; production uses llama.cpp.
public protocol ModelClient: AnyObject, Sendable {
    func complete(_ request: ModelRequest) async throws -> ModelReply
    func cancelInFlight()
    /// Exact token count where the runtime can provide it.
    func countTokens(_ text: String) async -> Int?
}

public extension ModelClient {
    func countTokens(_ text: String) async -> Int? { nil }
    func cancelInFlight() {}
}

import Foundation

/// Reads the single native computer_use tool call returned by Fara's chat
/// completion API. The function arguments remain the canonical AgentAction
/// JSON; this adapter only unwraps the model's native tool-call envelope.
enum FaraPolicyAdapter {
    static let maximumCompletionBytes = 1_048_576
    static let maximumActionBytes = 32_768

    static func actionJSON(fromCompletion raw: String) throws -> String {
        guard raw.utf8.count <= maximumCompletionBytes,
              let data = raw.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["model"] as? String == ComputerUseFaraRuntimeInputs.modelAlias,
              let choices = root["choices"] as? [[String: Any]], choices.count == 1,
              let choice = choices.first,
              Set(choice.keys).isSubset(of: ["index", "message", "finish_reason", "logprobs"]),
              choice["finish_reason"] as? String == "tool_calls",
              let message = choice["message"] as? [String: Any],
              Set(message.keys).isSubset(of: ["role", "content", "tool_calls", "reasoning_content"]),
              message["role"] as? String == "assistant",
              validContent(message["content"]),
              let calls = message["tool_calls"] as? [[String: Any]], calls.count == 1,
              let call = calls.first, validToolCall(call),
              let function = call["function"] as? [String: Any],
              function["name"] as? String == "computer_use",
              let arguments = function["arguments"] as? String,
              !arguments.isEmpty, arguments.utf8.count <= maximumActionBytes else {
            throw Failure.invalidCompletion
        }
        return arguments
    }

    private static func validContent(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return true }
        guard let content = value as? String else { return false }
        return content.utf8.count <= maximumActionBytes
    }

    private static func validToolCall(_ call: [String: Any]) -> Bool {
        let keys = Set(call.keys)
        guard keys == ["type", "function"] || keys == ["id", "type", "function"],
              call["type"] as? String == "function",
              let function = call["function"] as? [String: Any] else { return false }
        return Set(function.keys) == ["name", "arguments"]
    }

    enum Failure: Error { case invalidCompletion }
}

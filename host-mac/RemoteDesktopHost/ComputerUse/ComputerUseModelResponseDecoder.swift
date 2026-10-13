import Foundation

enum ComputerUseModelResponseError: Error, Equatable {
    case invalidResponse
}

/// Strictly decodes one plain assistant completion from the existing local runtime.
enum ComputerUseModelResponseDecoder {
    static func content(_ data: Data, modelAlias: String) throws -> String {
        guard !data.isEmpty, data.count <= 256 * 1_024, let source = String(data: data, encoding: .utf8) else {
            throw ComputerUseModelResponseError.invalidResponse
        }
        var parser = StrictSemanticJSONParser(source, maximumValueCount: 512)
        guard case .object(let root) = try parser.parse(), root["error"] == nil, root["model"] == .string(modelAlias),
              case .array(let choices)? = root["choices"], choices.count == 1,
              case .object(let choice) = choices[0], choice["finish_reason"] == .string("stop"),
              case .object(let message)? = choice["message"], message["role"] == .string("assistant"),
              case .string(let content)? = message["content"],
              message["tool_calls"] == nil || message["tool_calls"] == .null || message["tool_calls"] == .array([]),
              message["function_call"] == nil || message["function_call"] == .null,
              message["refusal"] == nil || message["refusal"] == .null || message["refusal"] == .string("") else {
            throw ComputerUseModelResponseError.invalidResponse
        }
        return content
    }
}

enum ComputerUseValidatedWebURL {
    nonisolated static func validatedURL(_ url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              url.absoluteString.utf8.count <= 8_192,
              !url.absoluteString.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let result = components.url else { return nil }
        return result
    }
}

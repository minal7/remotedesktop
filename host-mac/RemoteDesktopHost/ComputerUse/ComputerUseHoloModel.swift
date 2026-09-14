import Foundation

/// Holo's OpenAI tool protocol. The existing browser executor admits effects.
enum ComputerUseHoloModel {
    static let modelAlias = "holo-browser-v1"

    static func makeRequest(endpoint: OSAtlasLlamaEndpoint, input: ComputerUseFaraModel.Input) throws -> URLRequest {
        try OSAtlasLlamaRuntime.validateLoopbackEndpoint(endpoint.baseURL)
        try input.validateSurfaceContext()
        guard endpoint.variant == nil, !endpoint.bearerToken.isEmpty,
              !input.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.goal.utf8.count <= 8_192, input.history.count <= 20,
              input.pageReading == nil, input.history.allSatisfy({ $0.pageReading == nil }) else { throw invalid }
        var messages: [[String: Any]] = [["role": "system", "content": input.goal]]
        let earliestImage = max(0, input.history.count - 2)
        var bytes = input.goal.utf8.count, callIDs = Set<String>()
        func checkedText(_ value: String?, maximum: Int) throws -> String? {
            guard let value else { return nil }
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= maximum else { throw invalid }
            bytes += value.utf8.count; return value
        }
        func source(_ url: URL?) throws -> String? {
            guard let url else { return nil }
            guard ComputerUseOwnedBrowser.validatedURL(url) == url else { throw invalid }
            return try checkedText(url.absoluteString, maximum: 8_192)
        }
        var observations: [(url: String?, error: String?, reply: String?, editor: String?, state: ComputerUseNativeTextState?)] = []
        for index in 0...input.history.count {
            let old = index < input.history.count ? input.history[index] : nil
            observations.append(try (source(old?.currentURL ?? (old == nil ? input.currentURL : nil)),
                checkedText(old?.actionError ?? (old == nil ? input.actionError : nil), maximum: 16_384),
                checkedText(old?.userResponse ?? (old == nil ? input.userResponse : nil), maximum: 8_192),
                checkedText(old?.focusedEditor ?? (old == nil ? input.focusedEditor : nil), maximum: 1_024),
                old?.focusedTextState ?? (old == nil ? input.focusedTextState : nil)))
        }
        for index in 0...input.history.count {
            let observation = observations[index]
            var content: [[String: Any]] = [["type": "text", "text": "<observation>\n"]]
            if index >= earliestImage {
                let png = index == input.history.count ? input.screenshotPNG : input.history[index].screenshotPNG
                try ComputerUseFaraModel.validatePNG(png)
                content.append(["type": "image_url", "image_url": ["url": "data:image/png;base64," + png.base64EncodedString()]])
            } else { content.append(["type": "text", "text": "[screenshot evicted]"]) }
            var text = observation.url.map { "\nCurrent URL: " + $0 } ?? ""
            if input.surface == .desktop {
                let focus = try ComputerUseFaraModel.nativeFocusJSON(observation.editor, state: observation.state)
                bytes += focus.utf8.count; text += "\n" + focus
                if index == input.history.count {
                    let controls = try ComputerUseFaraModel.nativeControlsJSON(input.nativeControls)
                    bytes += controls.utf8.count; text += "\n" + controls
                }
            }
            if index == 0 {
                if let error = observation.error { text += "\nError: " + error }
                if let reply = observation.reply { text += "\nUser response: " + reply }
            }
            content.append(["type": "text", "text": text + "\n</observation>"])
            messages.append(["role": "user", "content": content])
            if index < input.history.count {
                let response = input.history[index].response
                guard response.utf8.count <= 32_768 else { throw invalid }
                bytes += response.utf8.count
                var parser = StrictSemanticJSONParser(response)
                let decoded = try decodeMessage(parser.parse())
                let canonical = try encode(decoded.message)
                messages.append(try JSONSerialization.jsonObject(with: Data(canonical.utf8)) as! [String: Any])
                if let id = decoded.callID {
                    guard callIDs.insert(id).inserted else { throw invalid }
                    // History pruning may remove the original next step.
                    // Use the result captured before pruning, not its successor.
                    var next = observations[index + 1]
                    if let captured = input.history[index].resultObservation {
                        next = try (source(captured.currentURL), checkedText(captured.actionError, maximum: 16_384),
                            checkedText(captured.userResponse, maximum: 8_192), checkedText(captured.focusedEditor, maximum: 1_024), captured.focusedTextState)
                    }
                    var result: [String: Any] = [:]
                    if input.surface == .desktop { result = ComputerUseFaraModel.nativeFocusObject(next.editor, state: next.state) }
                    if let url = next.url { result["observed_url"] = url }
                    if let error = next.error { result["error"] = error }
                    if let reply = next.reply { result["user_response"] = reply }
                    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
                    if input.surface == .desktop { bytes += data.count }
                    messages.append(["role": "tool", "tool_call_id": id, "content": String(decoding: data, as: UTF8.self)])
                }
            }
        }
        guard bytes <= 65_536 else { throw invalid }
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"; request.timeoutInterval = 40
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + endpoint.bearerToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": modelAlias, "messages": messages,
            "tools": tools(surface: input.surface), "tool_choice": "required", "parallel_tool_calls": false,
            "temperature": 0.8, "max_tokens": 1024, "stream": false,
            "chat_template_kwargs": ["enable_thinking": true], "reasoning_format": "deepseek"], options: [.sortedKeys, .withoutEscapingSlashes])
        guard request.httpBody!.count <= 9 * 1_024 * 1_024 else { throw invalid }
        return request
    }

    /// Click/answer use Holo's published schemas. The other tools describe this
    /// app's existing actions, including exact insertion without implicit keys.
    private static func tools(surface: ComputerUseFaraModel.Input.Surface) -> [[String: Any]] {
        func tool(_ name: String, _ description: String, _ properties: [String: Any]) -> [String: Any] {
            ["type": "function", "function": ["name": name, "description": description,
                "parameters": ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]]]
        }
        let string = ["type": "string"]
        let declared = [
            tool("click", "Click at (x, y) coordinates", [
                "element": ["type": "string", "description": "Detailed description of the target UI element"],
                "x": ["type": "integer", "description": "X coordinate as integer in [0, 1000]"],
                "y": ["type": "integer", "description": "Y coordinate as integer in [0, 1000]"]]),
            tool("answer", "Provide a final answer", ["content": ["type": "string", "description": "The answer content"]]),
            tool("type", surface == .desktop ? "Insert exact text into the focused native editable field using its current selection. Preserve whitespace and Unicode. This does not add Enter or select-all. " + ComputerUseFaraModel.desktopFocusDescription : "Insert the supplied text into the currently focused editor using its existing selection. In the Find bar, typing updates the page search. This does not add Enter or select-all.", ["text": string]),
            tool("key", surface == .desktop ? ComputerUseFaraModel.desktopKeyDescription : "Perform the explicitly supplied key or key chord through the browser adapter. Control+f opens the native Find bar. Do not add other keys.", ["keys": ["type": "array", "items": string, "minItems": 1]]),
            tool("scroll", "Scroll in the explicit direction by an unsigned distance. A distance of 1000 is one viewport height for up/down or one viewport width for left/right.", [
                "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                "distance": ["type": "number", "minimum": 0, "maximum": 10_000]]),
            tool("wait", "Wait for the supplied time in seconds, from 0 to 30.", ["time": ["type": "number"]]),
            tool("web_search", "Search the web for the supplied query.", ["query": string]),
            tool("visit_url", "Navigate the owned browser to an HTTP or HTTPS URL.", ["url": string]),
            tool("history_back", "Go back one page in this browser's history.", [:]),
            tool("ask_user", "Pause the task and ask the user for missing information. The bound reply will be returned as this tool's result.", ["question": string])]
        guard surface == .desktop else { return declared }
        return declared.filter { tool in
            guard let function = tool["function"] as? [String: Any], let name = function["name"] as? String else { return false }
            return ["click", "type", "key", "wait", "answer"].contains(name)
        }
    }

    static func decode(_ data: Data) throws -> ComputerUseFaraModel.Proposal {
        do {
            guard data.count <= 1_048_576, let source = String(data: data, encoding: .utf8) else { throw invalid }
            var parser = StrictSemanticJSONParser(source)
            guard case .object(let root) = try parser.parse(), root["model"] == .string(modelAlias),
                  case .array(let choices)? = root["choices"], choices.count == 1,
                  case .object(let choice) = choices[0], let message = choice["message"] else { throw invalid }
            let decoded = try decodeMessage(message)
            guard choice["finish_reason"] == .string(decoded.callID == nil ? "stop" : "tool_calls") else { throw invalid }
            return .init(response: try encode(decoded.message), action: decoded.action)
        } catch { throw invalid }
    }

    private static var invalid: OSAtlasLlamaRuntimeError { .invalidResponse }
    private struct Message {
        let message: MCPJSONValue
        let callID: String?
        let action: ComputerUseFaraAction
    }

    private static func encode(_ value: MCPJSONValue) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= 32_768, let text = String(data: data, encoding: .utf8) else { throw invalid }
        return text
    }

    private static func decodeMessage(_ value: MCPJSONValue) throws -> Message {
        guard case .object(let message) = value, message["role"] == .string("assistant"),
              Set(message.keys).isSubset(of: ["role", "content", "tool_calls", "reasoning", "reasoning_content", "refusal"]),
              message["refusal"] == nil || message["refusal"] == .null else { throw invalid }
        let content: String
        switch message["content"] {
        case .string(let text): content = text
        case nil, .null: content = ""
        default: throw invalid
        }
        guard content.utf8.count <= 16_384 else { throw invalid }
        var retained: [String: MCPJSONValue] = ["role": .string("assistant"), "content": .string(content)]
        let calls: [MCPJSONValue]
        switch message["tool_calls"] {
        case .array(let values): calls = values
        case nil, .null: calls = []
        default: throw invalid
        }
        if calls.isEmpty {
            // The shared executor's zero-duration wait requests another fresh
            // observation within its turn bound. Do not invent a tool call.
            return .init(message: .object(retained), callID: nil, action: .wait(0))
        }
        guard calls.count == 1, case .object(let call) = calls[0], Set(call.keys) == ["id", "type", "function"],
              call["type"] == .string("function"), case .string(let id)? = call["id"],
              !id.isEmpty, id.utf8.count <= 256, !id.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains),
              case .object(let function)? = call["function"], Set(function.keys) == ["name", "arguments"],
              case .string(let name)? = function["name"], case .string(let arguments)? = function["arguments"],
              arguments.utf8.count <= 16_384 else { throw invalid }
        var parser = StrictSemanticJSONParser(arguments)
        guard case .object(let args) = try parser.parse() else { throw invalid }
        func keys(_ fields: String...) throws { guard Set(args.keys) == Set(fields) else { throw invalid } }
        func text(_ field: String, allowsEmpty: Bool = false) throws -> String {
            guard case .string(let value)? = args[field], allowsEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid }
            return value
        }
        func number(_ field: String) throws -> Double {
            let result: Double
            switch args[field] { case .integer(let n): result = Double(n); case .double(let n): result = n; default: throw invalid }
            guard result.isFinite else { throw invalid }; return result
        }
        let action: ComputerUseFaraAction
        switch name {
        case "click":
            try keys("element", "x", "y"); _ = try text("element")
            guard let x = args["x"]?.exactInteger, let y = args["y"]?.exactInteger,
                  (0...1000).contains(x), (0...1000).contains(y) else { throw invalid }
            action = .pointer(.leftClick, .init(x: Double(x), y: Double(y)))
        case "type": try keys("text"); action = try .typeText(text("text", allowsEmpty: true))
        case "answer": try keys("content"); action = try .reportCompletion(text("content"))
        case "ask_user": try keys("question"); action = try .askUser(text("question"))
        case "web_search": try keys("query"); action = try .webSearch(text("query"))
        case "visit_url":
            try keys("url")
            guard let url = URL(string: try text("url")), ComputerUseOwnedBrowser.validatedURL(url) == url else { throw invalid }
            action = .visitURL(url)
        case "history_back": try keys(); action = .historyBack
        case "wait":
            try keys("time"); let seconds = try number("time")
            guard (0...30).contains(seconds) else { throw invalid }; action = .wait(seconds)
        case "scroll":
            try keys("direction", "distance")
            let direction = try text("direction"), distance = try number("distance")
            guard ["up", "down", "left", "right"].contains(direction), (0...10_000).contains(distance) else { throw invalid }
            action = .scroll(horizontal: direction == "left" || direction == "right",
                pixels: (direction == "down" || direction == "left") ? -distance : distance)
        case "key":
            try keys("keys")
            guard case .array(let values)? = args["keys"], (1...8).contains(values.count) else { throw invalid }
            let names = try values.map { value -> String in
                guard case .string(let key) = value, !key.isEmpty, key.utf8.count <= 32,
                      !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw invalid }
                return key
            }
            guard Set(names).count == names.count else { throw invalid }
            action = .key(names)
        default: throw invalid
        }
        retained["tool_calls"] = .array(calls)
        return .init(message: .object(retained), callID: id, action: action)
    }
}

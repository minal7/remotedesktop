import Foundation

/// Converts the model-native computer_use arguments into the single host
/// AgentAction contract. Raw completion bytes remain owned by the episode.
enum FaraPolicyAdapter {
    static let maximumCompletionBytes = 1_048_576
    static let maximumActionBytes = 32_768

    static func canonicalActionJSON(fromCompletion raw: String, imageSize: (width: Int, height: Int)) throws -> String {
        let arguments = try NativeToolEnvelope.arguments(raw, expectedModel: ComputerUseFaraRuntimeInputs.modelAlias)
        return try AgentPolicyActionSchema.canonicalJSON(arguments, imageSize: imageSize)
    }

    static func actionJSON(fromCompletion raw: String) throws -> String {
        // Kept as a strict compatibility entry point for tests without coordinates.
        try canonicalActionJSON(fromCompletion: raw, imageSize: (16_384, 16_384))
    }

    enum Failure: Error { case invalidCompletion }
}

private enum NativeToolEnvelope {
    static func arguments(_ raw: String, expectedModel: String) throws -> [String: Any] {
        guard raw.utf8.count <= FaraPolicyAdapter.maximumCompletionBytes,
              let data = raw.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["model"] as? String == expectedModel,
              let choices = root["choices"] as? [[String: Any]], choices.count == 1,
              let choice = choices.first, choice["finish_reason"] as? String == "tool_calls",
              Set(choice.keys).isSubset(of: ["index", "message", "finish_reason", "logprobs"]),
              let message = choice["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              Set(message.keys).isSubset(of: ["role", "content", "tool_calls", "reasoning_content"]),
              validContent(message["content"]),
              let calls = message["tool_calls"] as? [[String: Any]], calls.count == 1,
              let call = calls.first, validToolCall(call),
              let function = call["function"] as? [String: Any],
              function["name"] as? String == "computer_use",
              let arguments = function["arguments"] as? String,
              !arguments.isEmpty, arguments.utf8.count <= FaraPolicyAdapter.maximumActionBytes,
              let argumentData = arguments.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: argumentData) as? [String: Any] else {
            throw FaraPolicyAdapter.Failure.invalidCompletion
        }
        return object
    }

    private static func validContent(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return true }
        guard let content = value as? String else { return false }
        return content.utf8.count <= FaraPolicyAdapter.maximumActionBytes
    }

    private static func validToolCall(_ call: [String: Any]) -> Bool {
        let keys = Set(call.keys)
        guard keys == ["type", "function"] || keys == ["id", "type", "function"],
              call["type"] as? String == "function",
              let function = call["function"] as? [String: Any] else { return false }
        return Set(function.keys) == ["name", "arguments"]
    }
}

enum AgentPolicyActionSchema {
    static func schema(for model: AgentPolicyModel) throws -> Data {
        let actions = model == .fara15_4b ? faraActions : uiTarsActions
        let coord: [String: Any] = ["type": "array", "minItems": 2, "maxItems": 2,
                                    "items": ["type": "number", "minimum": 0, "exclusiveMaximum": 1000]]
        let text: [String: Any] = ["type": "string"]
        let actionBranches: [[String: Any]] = actions.map { action in
            let fields = properties(for: action, coordinateSchema: coord, stringSchema: text)
            var props: [String: Any] = ["action": ["const": action, "type": "string"]]
            props.merge(fields.properties) { _, new in new }
            return ["type": "object", "additionalProperties": false,
                    "required": ["action"] + fields.required, "properties": props]
        }
        return try JSONSerialization.data(withJSONObject: ["type": "object", "oneOf": actionBranches],
                                           options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func properties(for action: String, coordinateSchema: [String: Any], stringSchema: [String: Any])
        -> (properties: [String: Any], required: [String]) {
        let choices: [String: Any] = ["type": "array", "items": stringSchema]
        let files: [String: Any] = ["type": "array", "minItems": 1, "items": ["type": "string", "minLength": 1]]
        switch action {
        case "left_click", "right_click", "middle_click", "double_click", "triple_click", "click": return (["coordinate": coordinateSchema], ["coordinate"])
        case "left_click_drag", "drag": return (["coordinate": coordinateSchema, "start_coordinate": coordinateSchema], ["coordinate", "start_coordinate"])
        case "type": return (["text": stringSchema, "coordinate": coordinateSchema,
                              "mode": ["type": "string", "enum": ["replace", "append"]]], ["text"])
        case "key": return (["keys": ["type": "array", "minItems": 1, "items": ["type": "string", "minLength": 1]]], ["keys"])
        case "hotkey": return (["key": stringSchema], ["key"])
        case "scroll", "hscroll": return (["pixels": ["type": "number", "minimum": -1000, "maximum": 1000], "coordinate": coordinateSchema], ["pixels"])
        case "visit_url", "open_url": return (["url": ["type": "string", "minLength": 1]], ["url"])
        case "history_back": return ([:], [])
        case "wait": return (["time": ["type": "number", "exclusiveMinimum": 0, "maximum": 10]], ["time"])
        case "terminate": return (["answer": stringSchema], ["answer"])
        case "finished": return (["content": stringSchema], ["content"])
        case "ask_user_question": return (["question": stringSchema, "choices": choices], ["question"])
        case "call_user", "ask_user": return (["content": stringSchema, "choices": choices], ["content"])
        case "open_app": return (["name": ["type": "string", "minLength": 1]], ["name"])
        case "find_files": return (["query": stringSchema, "kind": stringSchema, "modified_after": ["type": "string", "format": "date-time"]], ["query"])
        case "set_files": return (["coordinate": coordinateSchema, "file_ids": files], ["coordinate", "file_ids"])
        case "select_option", "select": return (["coordinate": coordinateSchema, "option": stringSchema], ["coordinate", "option"])
        case "web_search": return (["query": stringSchema], ["query"])
        case "fail": return (["reason": ["type": "string", "minLength": 1]], ["reason"])
        default: return ([:], [])
        }
    }

    static func canonicalJSON(_ args: [String: Any], imageSize: (width: Int, height: Int)) throws -> String {
        guard let action = args["action"] as? String else { throw FaraPolicyAdapter.Failure.invalidCompletion }
        try validateArguments(args, action: action)
        let json: [String: Any]
        switch action {
        case "left_click", "right_click", "middle_click", "double_click", "triple_click", "click":
            let button = action == "right_click" ? "right" : (action == "middle_click" ? "middle" : nil)
            let count = action == "double_click" ? 2 : (action == "triple_click" ? 3 : nil)
            let p = try point(args["coordinate"], imageSize: imageSize)
            var click: [String: Any] = ["type": "click", "target": p]
            click["button"] = button; click["count"] = count
            json = click.compactMapValues { $0 }
        case "type":
            guard let text = (args["text"] ?? args["content"]) as? String else { throw FaraPolicyAdapter.Failure.invalidCompletion }
            let mode = args["mode"] as? String ?? "append"
            guard ["replace", "append"].contains(mode) else { throw FaraPolicyAdapter.Failure.invalidCompletion }
            var value: [String: Any] = ["type": "type", "text": text, "mode": mode]
            if let coordinate = args["coordinate"] { value["target"] = try point(coordinate, imageSize: imageSize) }
            json = value
        case "key", "hotkey":
            let chord: String
            if let key = args["key"] as? String { chord = key }
            else if let keys = args["keys"] as? [String], !keys.isEmpty { chord = keys.joined(separator: "+") }
            else { throw FaraPolicyAdapter.Failure.invalidCompletion }
            json = ["type": "key", "chord": chord]
        case "scroll", "hscroll":
            guard let raw = args["pixels"] as? NSNumber, raw.doubleValue.isFinite,
                  raw.doubleValue != 0, abs(raw.doubleValue) <= 1000 else { throw FaraPolicyAdapter.Failure.invalidCompletion }
            let value = raw.doubleValue
            let horizontal = action == "hscroll"
            let dimension = horizontal ? imageSize.width : imageSize.height
            let amount = abs(value) / 1000 * Double(dimension)
            guard amount.isFinite, amount > 0 else { throw FaraPolicyAdapter.Failure.invalidCompletion }
            let dir = horizontal ? (value > 0 ? "right" : "left") : (value > 0 ? "up" : "down")
            var result: [String: Any] = ["type": "scroll", "direction": dir, "amount": amount]
            if let coordinate = args["coordinate"] { result["target"] = try point(coordinate, imageSize: imageSize) }
            json = result
        case "left_click_drag", "drag":
            let start = try point(args["start_coordinate"], imageSize: imageSize)
            let end = try point(args["coordinate"], imageSize: imageSize)
            json = ["type": "drag", "from": start, "to": end]
        case "select_option", "select":
            guard let option = args["option"] as? String else { throw FaraPolicyAdapter.Failure.invalidCompletion }
            json = ["type": "select", "target": try point(args["coordinate"], imageSize: imageSize), "option": option]
        case "visit_url", "open_url":
            guard let url = args["url"] as? String else { throw FaraPolicyAdapter.Failure.invalidCompletion }
            json = ["type": "open_url", "url": url]
        case "open_app":
            guard let name = args["name"] as? String else { throw FaraPolicyAdapter.Failure.invalidCompletion }
            json = ["type": "open_app", "name": name]
        case "find_files":
            guard let query = args["query"] as? String else { throw FaraPolicyAdapter.Failure.invalidCompletion }
            var value: [String: Any] = ["type": "find_files", "query": query]
            value["kind"] = args["kind"]; value["modified_after"] = args["modified_after"]
            json = value.compactMapValues { $0 }
        case "set_files":
            guard let ids = args["file_ids"] as? [String] else { throw FaraPolicyAdapter.Failure.invalidCompletion }
            json = ["type": "set_files", "target": try point(args["coordinate"], imageSize: imageSize), "file_ids": ids]
        case "wait":
            guard let seconds = (args["time"] ?? args["seconds"]) as? NSNumber else { throw FaraPolicyAdapter.Failure.invalidCompletion }
            json = ["type": "wait", "seconds": seconds]
        case "ask_user_question", "call_user", "ask_user":
            guard let question = (args["question"] ?? args["text"] ?? args["content"]) as? String else { throw FaraPolicyAdapter.Failure.invalidCompletion }
            var value: [String: Any] = ["type": "ask_user", "question": question]
            value["choices"] = args["choices"]
            json = value.compactMapValues { $0 }
        case "terminate", "finished", "done":
            json = ["type": "done", "answer": args["answer"] as? String ?? "Task complete."]
        case "fail":
            guard let reason = args["reason"] as? String else { throw FaraPolicyAdapter.Failure.invalidCompletion }
            json = ["type": "fail", "reason": reason]
        case "history_back":
            json = ["type": "key", "chord": "cmd+[" ]
        case "web_search":
            json = ["type": "fail", "reason": "The native search action is not available in the generic action contract."]
        default: throw FaraPolicyAdapter.Failure.invalidCompletion
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static var faraActions: [String] { ["left_click", "right_click", "middle_click", "double_click", "triple_click", "left_click_drag", "type", "key", "scroll", "hscroll", "visit_url", "history_back", "web_search", "ask_user_question", "wait", "terminate", "select_option", "open_app", "find_files", "set_files", "fail"] }
    private static var uiTarsActions: [String] { ["click", "type", "hotkey", "scroll", "drag", "wait", "finished", "call_user", "select_option", "open_url", "open_app", "find_files", "set_files", "fail"] }

    private static func validateArguments(_ args: [String: Any], action: String) throws {
        let keys = Set(args.keys)
        let allowed: Set<String>
        let required: Set<String>
        switch action {
        case "left_click", "right_click", "middle_click", "double_click", "triple_click", "click": allowed = ["action", "coordinate"]; required = allowed
        case "left_click_drag", "drag": allowed = ["action", "coordinate", "start_coordinate"]; required = allowed
        case "type":
            allowed = ["action", "text", "mode", "coordinate"]
            required = ["action", "text"]
        case "key": allowed = ["action", "keys"]; required = allowed
        case "hotkey": allowed = ["action", "key"]; required = allowed
        case "scroll", "hscroll": allowed = ["action", "pixels", "coordinate"]; required = ["action", "pixels"]
        case "visit_url", "open_url": allowed = ["action", "url"]; required = allowed
        case "history_back": allowed = ["action"]; required = allowed
        case "wait": allowed = ["action", "time"]; required = allowed
        case "terminate": allowed = ["action", "answer"]; required = allowed
        case "finished": allowed = ["action", "content"]; required = allowed
        case "ask_user_question": allowed = ["action", "question", "choices"]; required = ["action", "question"]
        case "call_user", "ask_user": allowed = ["action", "content", "choices"]; required = ["action", "content"]
        case "open_app": allowed = ["action", "name"]; required = allowed
        case "find_files": allowed = ["action", "query", "kind", "modified_after"]; required = ["action", "query"]
        case "set_files": allowed = ["action", "coordinate", "file_ids"]; required = allowed
        case "select_option", "select": allowed = ["action", "coordinate", "option"]; required = allowed
        case "fail": allowed = ["action", "reason"]; required = allowed
        case "web_search": allowed = ["action", "query"]; required = allowed
        default: throw FaraPolicyAdapter.Failure.invalidCompletion
        }
        guard keys.isSubset(of: allowed), required.isSubset(of: keys) else { throw FaraPolicyAdapter.Failure.invalidCompletion }
    }

    private static func point(_ value: Any?, imageSize: (width: Int, height: Int)) throws -> [String: Double] {
        guard let coordinates = value as? [NSNumber], coordinates.count == 2 else { throw FaraPolicyAdapter.Failure.invalidCompletion }
        let x = coordinates[0].doubleValue, y = coordinates[1].doubleValue
        guard imageSize.width > 0, imageSize.height > 0,
              x.isFinite, y.isFinite, x >= 0, y >= 0, x < 1000, y < 1000 else {
            throw FaraPolicyAdapter.Failure.invalidCompletion
        }
        return ["x": x / 1000 * Double(imageSize.width), "y": y / 1000 * Double(imageSize.height)]
    }
}

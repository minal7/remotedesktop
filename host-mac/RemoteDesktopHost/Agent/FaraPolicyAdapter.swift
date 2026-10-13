import Foundation

/// Converts the model-native computer_use arguments into the single host
/// AgentAction contract. Raw completion bytes remain owned by the episode.
enum FaraPolicyAdapter {
    static let maximumCompletionBytes = 1_048_576
    static let maximumActionBytes = 32_768

    static func canonicalActionJSON(fromCompletion raw: String, imageSize: (width: Int, height: Int)) throws -> String {
        guard raw.utf8.count <= maximumCompletionBytes,
              imageSize.width > 0, imageSize.height > 0 else { throw Failure.invalidCompletion }
        let proposal: ComputerUseFaraAction
        do { proposal = try ComputerUseFaraAction.decodeNativeMessage(raw) }
        catch { throw Failure.invalidCompletion }
        let action = try canonicalAction(proposal, imageSize: imageSize)
        let data = try JSONEncoder().encode(action)
        guard data.count <= maximumActionBytes else { throw Failure.invalidCompletion }
        return String(decoding: data, as: UTF8.self)
    }

    static func actionJSON(fromCompletion raw: String) throws -> String {
        // Kept as a strict compatibility entry point for tests without coordinates.
        try canonicalActionJSON(fromCompletion: raw, imageSize: (16_384, 16_384))
    }

    enum Failure: Error { case invalidCompletion }

    private static func canonicalAction(_ proposal: ComputerUseFaraAction,
                                        imageSize: (width: Int, height: Int)) throws -> AgentAction {
        func point(_ point: ComputerUseFaraAction.Point) throws -> AgentTarget {
            let pixel = try point.pixel(width: imageSize.width, height: imageSize.height)
            return .point(x: Double(pixel.x), y: Double(pixel.y))
        }
        func scroll(_ horizontal: Bool, _ pixels: Double, _ target: AgentTarget? = nil) throws -> AgentAction {
            guard pixels.isFinite, pixels != 0, abs(pixels) <= 1_000 else { throw Failure.invalidCompletion }
            let scale = Double(horizontal ? imageSize.width : imageSize.height) / 1_000
            let amount = abs(pixels) * scale
            guard amount.isFinite, amount > 0 else { throw Failure.invalidCompletion }
            let direction: AgentScrollDirection = horizontal
                ? (pixels > 0 ? .right : .left) : (pixels > 0 ? .up : .down)
            return .scroll(target: target, direction: direction, amount: amount)
        }
        switch proposal {
        case let .pointer(kind, position):
            let target = try point(position)
            switch kind {
            case .leftClick: return .click(target: target, button: nil, count: nil)
            case .rightClick: return .click(target: target, button: .right, count: nil)
            case .doubleClick: return .click(target: target, button: nil, count: 2)
            case .tripleClick: return .click(target: target, button: nil, count: 3)
            case .drag:
                return .fail(reason: "This host action contract requires both drag endpoints; Fara supplied only the destination.")
            case .mouseMove:
                return .fail(reason: "Moving the pointer without a click is not available in this host action contract.")
            }
        case .typeText(let text): return .type(target: nil, text: text, mode: .append)
        case .key(let keys): return .key(chord: keys.joined(separator: "+"))
        case let .scroll(horizontal, pixels): return try scroll(horizontal, pixels)
        case let .scrollAt(horizontal, pixels, position):
            return try scroll(horizontal, pixels, point(position))
        case .visitURL(let url): return .openURL(url: url.absoluteString)
        case .unsupportedNavigation:
            return .fail(reason: "Only absolute HTTP and HTTPS URLs are supported.")
        case .historyBack: return .key(chord: "cmd+[")
        case .webSearch:
            return .fail(reason: "Search is unavailable in the current computer-use action contract.")
        case .readPageQuestion:
            return .fail(reason: "Page-reading actions are unavailable in the current computer-use action contract.")
        case .remember:
            return .fail(reason: "Memory actions are unavailable in the current computer-use action contract.")
        case .askUser(let question): return .askUser(question: question, choices: nil)
        case .localFileOperation(let operation):
            switch operation {
            case let .listFiles(query, _):
                return .findFiles(query: query.nameContains, kind: query.fileKind.rawValue, modifiedAfter: nil)
            case let .askFile(question, candidates):
                return .askUser(question: question, choices: candidates)
            case .selectFile, .selectLocalFile:
                return .fail(reason: "Select the file through the visible host-provided file control.")
            }
        case .wait(let seconds):
            guard seconds > 0, seconds <= 10 else { throw Failure.invalidCompletion }
            return .wait(seconds: seconds)
        case .reportCompletion(let answer): return .done(answer: answer)
        }
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

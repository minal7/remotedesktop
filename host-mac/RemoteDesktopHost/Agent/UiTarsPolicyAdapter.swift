import Foundation

enum UiTarsPolicyAdapter {
    static func canonicalActionJSON(fromCompletion raw: String, imageSize: (width: Int, height: Int)) throws -> String {
        guard raw.utf8.count <= FaraPolicyAdapter.maximumCompletionBytes,
              let data = raw.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["model"] as? String == "ui-tars15-7b-v1",
              let choices = root["choices"] as? [[String: Any]], choices.count == 1,
              let choice = choices.first, choice["finish_reason"] as? String == "stop",
              Set(choice.keys).isSubset(of: ["index", "message", "finish_reason", "logprobs"]),
              let message = choice["message"] as? [String: Any], message["role"] as? String == "assistant",
              Set(message.keys).isSubset(of: ["role", "content", "reasoning_content"]),
              let content = message["content"] as? String else { throw FaraPolicyAdapter.Failure.invalidCompletion }
        return try UIActionTextParser.canonicalJSON(content, imageSize: imageSize)
    }
}

enum UIActionTextParser {
    static func canonicalJSON(_ response: String, imageSize: (width: Int, height: Int)) throws -> String {
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: .newlines)
        let contentLines = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let actionLines = lines.filter { $0.hasPrefix("Action: ") }
        guard text.utf8.count <= 32_768, contentLines.count >= 2,
              contentLines[0].hasPrefix("Thought:"), actionLines.count == 1,
              contentLines.last == actionLines[0], actionLines[0].hasPrefix("Action: ") else {
            throw FaraPolicyAdapter.Failure.invalidCompletion
        }
        let line = String(actionLines[0].dropFirst("Action: ".count))
        let resized = try resizedSize(for: imageSize)
        let object: [String: Any]
        if let match = capture(line, pattern: #"^(click|left_double|right_single)\(start_box='(?:<\|box_start\|>)?\(([-+0-9.]+),\s*([-+0-9.]+)\)(?:<\|box_end\|>)?'\)$"#),
           let x = Double(match[2]), let y = Double(match[3]) {
            let target = try scaledPoint(x, y, resized: resized, original: imageSize)
            let button = match[1] == "right_single" ? "right" : nil
            let count = match[1] == "left_double" ? 2 : nil
            var click: [String: Any] = ["type": "click", "target": target]
            click["button"] = button; click["count"] = count
            object = click.compactMapValues { $0 }
        } else if let match = capture(line, pattern: #"^drag\(start_box='(?:<\|box_start\|>)?\(([-+0-9.]+),\s*([-+0-9.]+)\)(?:<\|box_end\|>)?',\s*end_box='(?:<\|box_start\|>)?\(([-+0-9.]+),\s*([-+0-9.]+)\)(?:<\|box_end\|>)?'\)$"#),
                  let x1 = Double(match[1]), let y1 = Double(match[2]),
                  let x2 = Double(match[3]), let y2 = Double(match[4]) {
            object = ["type": "drag", "from": try scaledPoint(x1, y1, resized: resized, original: imageSize),
                      "to": try scaledPoint(x2, y2, resized: resized, original: imageSize)]
        } else if let match = capture(line, pattern: #"^hotkey\(key='((?:\\.|[^'])*)'\)$"#) {
            object = ["type": "key", "chord": try decodePythonString(match[1])]
        } else if let match = capture(line, pattern: #"^type\(content='((?:\\.|[^'])*)'(?:,\s*mode='(replace|append)')?\)$"#) {
            let mode = match.count > 2 && !match[2].isEmpty ? match[2] : "append"
            object = ["type": "type", "text": try decodePythonString(match[1]), "mode": mode]
        } else if let match = capture(line, pattern: #"^scroll\(start_box='(?:<\|box_start\|>)?\(([-+0-9.]+),\s*([-+0-9.]+)\)(?:<\|box_end\|>)?',\s*direction='(up|down|left|right)'\)$"#),
                  let x = Double(match[1]), let y = Double(match[2]) {
            object = ["type": "scroll", "direction": match[3], "amount": max(1, imageSize.height / 2),
                      "target": try scaledPoint(x, y, resized: resized, original: imageSize)]
        } else if line == "wait()" {
            object = ["type": "wait", "seconds": 5]
        } else if let match = capture(line, pattern: #"^finished\(content='((?:\\.|[^'])*)'\)$"#) {
            object = ["type": "done", "answer": try decodePythonString(match[1])]
        } else if let match = capture(line, pattern: #"^call_user\(content='((?:\\.|[^'])*)'\)$"#) {
            object = ["type": "ask_user", "question": try decodePythonString(match[1])]
        } else if let match = capture(line, pattern: #"^open_url\(url='((?:\\.|[^'])*)'\)$"#) {
            object = ["type": "open_url", "url": try decodePythonString(match[1])]
        } else if let match = capture(line, pattern: #"^open_app\(name='((?:\\.|[^'])*)'\)$"#) {
            object = ["type": "open_app", "name": try decodePythonString(match[1])]
        } else if let match = capture(line, pattern: #"^find_files\(query='((?:\\.|[^'])*)'(?:,\s*kind='((?:\\.|[^'])*)')?(?:,\s*modified_after='((?:\\.|[^'])*)')?\)$"#) {
            var value: [String: Any] = ["type": "find_files", "query": try decodePythonString(match[1])]
            if !match[2].isEmpty { value["kind"] = try decodePythonString(match[2]) }
            if !match[3].isEmpty { value["modified_after"] = try decodePythonString(match[3]) }
            object = value
        } else if let match = capture(line, pattern: #"^select_option\(start_box='(?:<\|box_start\|>)?\(([-+0-9.]+),\s*([-+0-9.]+)\)(?:<\|box_end\|>)?',\s*option='((?:\\.|[^'])*)'\)$"#),
                  let x = Double(match[1]), let y = Double(match[2]) {
            object = ["type": "select", "target": try scaledPoint(x, y, resized: resized, original: imageSize),
                      "option": try decodePythonString(match[3])]
        } else if let match = capture(line, pattern: #"^set_files\(start_box='(?:<\|box_start\|>)?\(([-+0-9.]+),\s*([-+0-9.]+)\)(?:<\|box_end\|>)?',\s*file_ids='((?:\\.|[^'])*)'\)$"#),
                  let x = Double(match[1]), let y = Double(match[2]) {
            let json = try decodePythonString(match[3])
            guard let data = json.data(using: .utf8),
                  let ids = try JSONSerialization.jsonObject(with: data) as? [String], !ids.isEmpty,
                  ids.count <= 16, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("/") && !$0.contains("\\") }) else {
                throw FaraPolicyAdapter.Failure.invalidCompletion
            }
            object = ["type": "set_files", "target": try scaledPoint(x, y, resized: resized, original: imageSize),
                      "file_ids": ids]
        } else if let match = capture(line, pattern: #"^fail\(reason='((?:\\.|[^'])*)'\)$"#) {
            object = ["type": "fail", "reason": try decodePythonString(match[1])]
        } else {
            throw FaraPolicyAdapter.Failure.invalidCompletion
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func resizedSize(for original: (width: Int, height: Int)) throws -> (width: Int, height: Int) {
        guard original.width > 0, original.height > 0,
              Double(max(original.width, original.height)) / Double(min(original.width, original.height)) <= 200 else {
            throw FaraPolicyAdapter.Failure.invalidCompletion
        }
        let factor = 28.0, minPixels = 8.0 * factor * factor, maxPixels = 1_536.0 * factor * factor
        var height = max(28, Int((Double(original.height) / factor).rounded(.toNearestOrAwayFromZero)) * 28)
        var width = max(28, Int((Double(original.width) / factor).rounded(.toNearestOrAwayFromZero)) * 28)
        if Double(height * width) > maxPixels {
            let scale = sqrt(Double(original.height * original.width) / maxPixels)
            height = max(28, Int(floor(Double(original.height) / scale / factor)) * 28)
            width = max(28, Int(floor(Double(original.width) / scale / factor)) * 28)
        } else if Double(height * width) < minPixels {
            let scale = sqrt(minPixels / Double(original.height * original.width))
            height = max(28, Int(ceil(Double(original.height) * scale / factor)) * 28)
            width = max(28, Int(ceil(Double(original.width) * scale / factor)) * 28)
        }
        return (width, height)
    }

    private static func capture(_ source: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              match.range.location == 0, match.range.length == source.utf16.count else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: source).map { String(source[$0]) } ?? ""
        }
    }

    private static func decodePythonString(_ escaped: String) throws -> String {
        var result = "", index = escaped.startIndex
        while index < escaped.endIndex {
            let character = escaped[index]
            index = escaped.index(after: index)
            guard character == "\\" else { result.append(character); continue }
            guard index < escaped.endIndex else { throw FaraPolicyAdapter.Failure.invalidCompletion }
            let next = escaped[index]; index = escaped.index(after: index)
            switch next {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "\\", "'", "\"": result.append(next)
            default: throw FaraPolicyAdapter.Failure.invalidCompletion
            }
        }
        return result
    }

    private static func scaledPoint(_ x: Double, _ y: Double, resized: (width: Int, height: Int),
                                    original: (width: Int, height: Int)) throws -> [String: Double] {
        guard x.isFinite, y.isFinite, x >= 0, y >= 0,
              x < Double(resized.width), y < Double(resized.height) else { throw FaraPolicyAdapter.Failure.invalidCompletion }
        return ["x": x / Double(resized.width) * Double(original.width),
                "y": y / Double(resized.height) * Double(original.height)]
    }
}

import Foundation
import CoreGraphics

enum GUIOwlPolicyAdapter {
    static let maximumCompletionBytes = 32_768
    static let maximumActionBytes = 32_768
    static let maximumWheelNotches = 10_000
    private static let maximumHostScrollAmount = 10_000.0

    enum Failure: Error { case invalidCompletion }

    static func canonicalActionJSON(
        fromCompletion raw: String,
        imageSize: (width: Int, height: Int)
    ) throws -> String {
        guard raw.utf8.count <= maximumCompletionBytes,
              imageSize.width > 0, imageSize.height > 0 else { throw Failure.invalidCompletion }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lineEnd = trimmed.firstIndex(of: "\n") else { throw Failure.invalidCompletion }
        let actionLine = String(trimmed[..<lineEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard actionLine.hasPrefix("Action: "), actionLine.count > "Action: ".count,
              !actionLine.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw Failure.invalidCompletion
        }
        let remainder = trimmed[trimmed.index(after: lineEnd)...].trimmingCharacters(in: .whitespacesAndNewlines)
        let open = "<tool_call>"
        let close = "</tool_call>"
        guard remainder.hasPrefix(open), let closing = remainder.range(of: close, options: .backwards),
              remainder[closing.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.invalidCompletion
        }
        let body = String(remainder.dropFirst(open.count).prefix(upTo: closing.lowerBound))
        var parser = StrictSemanticJSONParser(body)
        guard case .object(let envelope) = try parser.parse(), Set(envelope.keys) == ["name", "arguments"],
              envelope["name"] == .string("computer_use"),
              case .object(let arguments)? = envelope["arguments"],
              case .string(let name)? = arguments["action"] else { throw Failure.invalidCompletion }
        let action = try canonicalAction(name, arguments: arguments, imageSize: imageSize)
        try action.validate()
        let encoded = try JSONEncoder().encode(action)
        guard encoded.count <= maximumActionBytes else { throw Failure.invalidCompletion }
        return String(decoding: encoded, as: UTF8.self)
    }

    static func nativeWheelPixelAmount(forNotches notches: Int) throws -> Double {
        guard notches != 0, (-maximumWheelNotches...maximumWheelNotches).contains(notches),
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                  wheelCount: 1, wheel1: Int32(notches), wheel2: 0, wheel3: 0) else {
            throw Failure.invalidCompletion
        }
        let delta = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let magnitude = abs(delta)
        guard delta.isFinite, magnitude > 0, magnitude <= maximumHostScrollAmount else {
            throw Failure.invalidCompletion
        }
        return magnitude
    }

    private static func canonicalAction(
        _ name: String,
        arguments: [String: JSONValue],
        imageSize: (width: Int, height: Int)
    ) throws -> AgentAction {
        func requireKeys(_ required: [String], optional: [String] = []) throws {
            let supplied = Set(arguments.keys)
            guard Set(required).isSubset(of: supplied), supplied.isSubset(of: Set(required + optional)) else {
                throw Failure.invalidCompletion
            }
        }
        func text(_ field: String, allowEmpty: Bool = false) throws -> String {
            guard case .string(let value)? = arguments[field],
                  (allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                  value.utf8.count <= maximumActionBytes else { throw Failure.invalidCompletion }
            return value
        }
        func number(_ value: JSONValue?) throws -> Double {
            let result: Double
            switch value {
            case .integer(let integer): result = Double(integer)
            case .double(let double): result = double
            default: throw Failure.invalidCompletion
            }
            guard result.isFinite else { throw Failure.invalidCompletion }
            return result
        }
        func point() throws -> AgentTarget {
            guard case .array(let values)? = arguments["coordinate"], values.count == 2 else {
                throw Failure.invalidCompletion
            }
            let x = try number(values[0]), y = try number(values[1])
            guard (0...1000).contains(x), (0...1000).contains(y) else { throw Failure.invalidCompletion }
            let pixelX = min(imageSize.width - 1, Int(x / 1000 * Double(imageSize.width)))
            let pixelY = min(imageSize.height - 1, Int(y / 1000 * Double(imageSize.height)))
            return .point(x: Double(pixelX), y: Double(pixelY))
        }

        switch name {
        case "click", "left_click", "right_click", "middle_click", "double_click", "triple_click":
            try requireKeys(["action", "coordinate"])
            let button: AgentMouseButton? = name == "right_click" ? .right : name == "middle_click" ? .middle : nil
            let count = name == "double_click" ? 2 : name == "triple_click" ? 3 : nil
            return .click(target: try point(), button: button, count: count)
        case "type":
            try requireKeys(["action", "text"])
            return .type(target: nil, text: try text("text", allowEmpty: true), mode: .append)
        case "key", "hotkey":
            try requireKeys(["action", "keys"])
            let values: [JSONValue]
            switch arguments["keys"] {
            case .array(let supplied): values = supplied
            case .string(let supplied): values = [.string(supplied)]
            default: throw Failure.invalidCompletion
            }
            guard (1...8).contains(values.count) else { throw Failure.invalidCompletion }
            let aliases = ["arrowleft": "left", "arrowright": "right", "arrowup": "up", "arrowdown": "down"]
            let keys = try values.map { value -> String in
                guard case .string(let key) = value, !key.isEmpty, key.utf8.count <= 32,
                      !key.contains("+"), !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    throw Failure.invalidCompletion
                }
                return aliases[key.lowercased()] ?? key
            }
            guard Set(keys.map { $0.lowercased() }).count == keys.count else { throw Failure.invalidCompletion }
            let chord = keys.joined(separator: "+")
            do { _ = try AgentKeyStroke.parse(chord) }
            catch { return .fail(reason: "This key combination is not supported by the host.") }
            return .key(chord: chord)
        case "scroll":
            try requireKeys(["action", "pixels"], optional: ["coordinate"])
            let raw = try number(arguments["pixels"])
            guard let notches = Int(exactly: raw), notches != 0,
                  (-maximumWheelNotches...maximumWheelNotches).contains(notches) else { throw Failure.invalidCompletion }
            let target = arguments["coordinate"] == nil ? nil : try point()
            let direction: AgentScrollDirection = notches > 0 ? .up : .down
            return .scroll(target: target, direction: direction,
                amount: try nativeWheelPixelAmount(forNotches: notches))
        case "wait":
            try requireKeys(["action"], optional: ["time"])
            let seconds = arguments["time"] == nil ? 2 : try number(arguments["time"])
            guard seconds > 0, seconds <= 10 else { throw Failure.invalidCompletion }
            return .wait(seconds: seconds)
        case "answer":
            try requireKeys(["action", "text"])
            return .done(answer: try text("text"))
        case "terminate":
            try requireKeys(["action"], optional: ["status"])
            let status = arguments["status"] == nil ? "success" : try text("status")
            guard status == "success" || status == "failure" else { throw Failure.invalidCompletion }
            return status == "success" ? .done(answer: "Completed.") : .fail(reason: "The model reported task failure.")
        case "interact":
            try requireKeys(["action"], optional: ["text"])
            let prompt = arguments["text"] == nil ? "Please interact with the dialog." : try text("text")
            return .askUser(question: prompt, choices: nil)
        case "call_user":
            try requireKeys(["action"])
            return .askUser(question: "Please perform the requested manual operation.", choices: nil)
        case "mouse_move":
            try requireKeys(["action", "coordinate"])
            _ = try point()
            return .fail(reason: "Moving the pointer without a click is unavailable in the host action contract.")
        case "left_click_drag":
            try requireKeys(["action", "coordinate"])
            _ = try point()
            return .fail(reason: "The host action contract requires both drag endpoints; GUI-Owl supplied only a destination.")
        case "hscroll":
            try requireKeys(["action", "pixels"])
            let pixels = try number(arguments["pixels"])
            guard pixels.isFinite, abs(pixels) <= Double(maximumWheelNotches) else { throw Failure.invalidCompletion }
            return .fail(reason: "Horizontal scrolling is unsupported by the pinned GUI-Owl PC runner.")
        default:
            throw Failure.invalidCompletion
        }
    }
}

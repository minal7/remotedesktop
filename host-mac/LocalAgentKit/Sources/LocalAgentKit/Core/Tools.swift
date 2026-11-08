import CoreGraphics
import Foundation

/// The closed set of things the model may ask for.
public enum ToolCall: Sendable, Equatable {
    case click(id: Int, right: Bool, double: Bool)
    case clickAt(x: Double, y: Double)
    case type(id: Int?, text: String, clear: Bool, submit: Bool)
    case key(String)
    case menu(String)
    case scroll(direction: String, id: Int?, amount: Int)
    case drag(fromID: Int, toID: Int)
    case openApp(String)
    case openURL(String)
    case find(String)
    case look
    case zoom(id: Int)
    case read(String)
    case note(String)
    case wait(Double)
    case askUser(question: String, choices: [String])
    case done(String)
    case fail(String)
    // Spoken by computer-use-trained models, which point at the screen and type at
    // the focus rather than naming elements. Coordinates run 0...1000 on the frame shown.
    case pointAt(x: Double, y: Double, right: Bool, count: Int)
    case moveTo(x: Double, y: Double)
    case dragAt(fromX: Double, fromY: Double, toX: Double, toY: Double)
    case scrollBy(pixels: Double, horizontal: Bool, x: Double?, y: Double?)
    case typeAtFocus(String)

    public var name: String {
        switch self {
        case .click: return "click"
        case .clickAt: return "click_at"
        case .type: return "type"
        case .key: return "key"
        case .menu: return "menu"
        case .scroll: return "scroll"
        case .drag: return "drag"
        case .openApp: return "open_app"
        case .openURL: return "open_url"
        case .find: return "find"
        case .look: return "look"
        case .zoom: return "zoom"
        case .read: return "read"
        case .note: return "note"
        case .wait: return "wait"
        case .askUser: return "ask_user"
        case .done: return "done"
        case .fail: return "fail"
        case .pointAt: return "point_at"
        case .moveTo: return "move_to"
        case .dragAt: return "drag_at"
        case .scrollBy: return "scroll_by"
        case .typeAtFocus: return "type_at_focus"
        }
    }

    /// Identifies "the same action again", the raw material of stuck detection.
    public var fingerprint: String {
        switch self {
        case let .click(id, right, double): return "click:\(id):\(right):\(double)"
        case let .clickAt(x, y): return "click_at:\(Int(x / 20)):\(Int(y / 20))"
        case let .type(id, text, _, _): return "type:\(id ?? -1):\(text)"
        case let .key(chord): return "key:\(chord.lowercased())"
        case let .menu(path): return "menu:\(path.lowercased())"
        case let .scroll(direction, id, _): return "scroll:\(direction):\(id ?? -1)"
        case let .drag(from, to): return "drag:\(from):\(to)"
        case let .openApp(name): return "open_app:\(name.lowercased())"
        case let .openURL(url): return "open_url:\(url.lowercased())"
        case let .find(text): return "find:\(text.lowercased())"
        case .look: return "look"
        case let .zoom(id): return "zoom:\(id)"
        case let .read(question): return "read:\(question.lowercased())"
        case let .note(text): return "note:\(text.lowercased())"
        case .wait: return "wait"
        case let .askUser(question, _): return "ask:\(question.lowercased())"
        case let .done(answer): return "done:\(answer.prefix(40))"
        case let .fail(reason): return "fail:\(reason.prefix(40))"
        case let .pointAt(x, y, right, count): return "point_at:\(Int(x / 20)):\(Int(y / 20)):\(right):\(count)"
        case let .moveTo(x, y): return "move_to:\(Int(x / 20)):\(Int(y / 20))"
        case let .dragAt(a, b, c, d): return "drag_at:\(Int(a / 20)):\(Int(b / 20)):\(Int(c / 20)):\(Int(d / 20))"
        case let .scrollBy(pixels, horizontal, _, _): return "scroll_by:\(pixels > 0):\(horizontal)"
        case let .typeAtFocus(text): return "type_at_focus:\(text)"
        }
    }

    /// Tools that only gather information and can't change anything on the computer.
    public var isObservational: Bool {
        switch self {
        case .find, .look, .zoom, .read, .note, .wait: return true
        default: return false
        }
    }
}

/// One decoded model decision.
public struct AgentDecision: Sendable, Equatable {
    public var thought: String
    /// The plan step the model says it's on. Earlier steps then count as finished.
    public var planStep: Int?
    public var call: ToolCall
    /// The model didn't say whether to replace existing text.
    public var clearUnspecified = false
}

/// Actions the harness can take without asking the model, when the goal itself
/// names exactly where to start. It saves a step and removes a common way to go wrong.
extension ToolCall {
    var isPointerClick: Bool {
        if case .pointAt = self { return true }
        return false
    }
}

public enum Preflight {
    public static func firstAction(for goal: String, currentURL: String?, openApps: [String] = [], appExists: (String) -> Bool) -> ToolCall? {
        // "Print this from Legacy Inventory, then email it from my mail at https://..." starts in the app.
        let named = firstNamedApp(in: goal, oneOf: openApps)
        if let url = firstURL(in: goal) {
            if let named, named.position < (goal.range(of: url).map { goal.distance(from: goal.startIndex, to: $0.lowerBound) } ?? Int.max) { return .openApp(named.app) }
            return currentURL?.hasPrefix(url) == true ? nil : .openURL(url)
        }
        if let named { return .openApp(named.app) }
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["please open ", "open ", "launch ", "start "] where trimmed.lowercased().hasPrefix(prefix) {
            let rest = trimmed.dropFirst(prefix.count)
            // "Open Calculator and add these" or "Open Disk Utility."
            var name = String(rest)
            for separator in [" and ", ", ", " then ", ".", " to "] {
                if let range = name.range(of: separator, options: .caseInsensitive) { name = String(name[..<range.lowerBound]) }
            }
            name = name.trimmingCharacters(in: .whitespaces)
            if name.lowercased().hasSuffix(" app") { name = String(name.dropLast(4)) }
            if !name.isEmpty, name.split(separator: " ").count <= 4, appExists(name) { return .openApp(name) }
        }
        return nil
    }

    /// The app mentioned earliest, by its exact name, spaced or not: "Legacy Inventory" is
    /// LegacyInventory. Capitals count, so "my mail" doesn't mean the Mail app.
    static func firstNamedApp(in text: String, oneOf apps: [String]) -> (app: String, position: Int)? {
        var best: (app: String, position: Int)?
        for app in apps where app.count >= 3 {
            let spaced = app.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            for spelling in Set([app, spaced]) {
                let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: spelling) + "(?![\\p{L}\\p{N}])"
                guard let range = text.range(of: pattern, options: .regularExpression) else { continue }
                let position = text.distance(from: text.startIndex, to: range.lowerBound)
                if position < best?.position ?? Int.max { best = (app, position) }
            }
        }
        return best
    }

    static func firstURL(in text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            if let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return url.absoluteString
            }
        }
        return nil
    }
}

public enum ToolSchema {
    /// Grammar-enforced output shape. Flat on purpose: small models fill a flat
    /// object far more reliably than nested per-tool arguments, and an enum
    /// constrains the tool name to the real set.
    ///
    /// `ids` restricts element numbers to ones that exist and haven't just failed,
    /// and `allowed` can take a tool away. The grammar makes those choices impossible,
    /// which works where telling a small model "don't do that again" doesn't.
    public static func decisionSchema(allowed: [String] = allTools, ids: [Int]? = nil) -> String {
        let tools = allowed.map { "\"\($0)\"" }.joined(separator: ",")
        let idSchema: String
        if let ids, !ids.isEmpty {
            idSchema = "{\"enum\":[\(ids.map(String.init).joined(separator: ","))]}"
        } else {
            idSchema = "{\"type\":\"integer\"}"
        }
        return """
        {"type":"object","properties":{\
        "step":{"type":"integer"},\
        "thought":{"type":"string","maxLength":200},\
        "tool":{"enum":[\(tools)]},\
        "id":\(idSchema),\
        "to_id":\(idSchema),\
        "x":{"type":"number"},\
        "y":{"type":"number"},\
        "text":{"type":"string","maxLength":1500},\
        "clear":{"type":"boolean"},\
        "submit":{"type":"boolean"},\
        "direction":{"enum":["up","down","left","right"]},\
        "right":{"type":"boolean"},\
        "double":{"type":"boolean"},\
        "choices":{"type":"array","items":{"type":"string","maxLength":60},"maxItems":5}\
        },"required":["step","thought","tool"]}
        """
    }

    public static let allTools = [
        "click", "click_at", "type", "key", "menu", "scroll", "drag", "open_app", "open_url", "find", "look", "zoom",
        "read", "note", "wait", "ask_user", "done", "fail",
    ]

    public static let planSchema = """
    {"type":"object","properties":{"steps":{"type":"array","items":{"type":"string","maxLength":160},"minItems":1,"maxItems":6}},"required":["steps"]}
    """

    public static let verdictSchema = """
    {"type":"object","properties":{"finished":{"type":"boolean"},"missing":{"type":"string","maxLength":160},"cannot_tell":{"type":"boolean"}},"required":["finished","missing","cannot_tell"]}
    """

    /// Per-tool decode. On a problem the error text goes straight back to the
    /// model, so it can self-correct on the next step at the cost of one step.
    public static func decode(_ text: String) throws -> AgentDecision {
        guard let data = Self.firstJSONObject(in: text).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DecodeError.problem("Reply was not a JSON object.")
        }
        let tool = (object["tool"] as? String) ?? ""
        func integer(_ key: String) -> Int? {
            if let value = object[key] as? Int { return value }
            if let value = object[key] as? Double { return Int(value) }
            if let value = object[key] as? String { return Int(value.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))) }
            return nil
        }
        func string(_ key: String) -> String { (object[key] as? String) ?? "" }
        func bool(_ key: String) -> Bool { (object[key] as? Bool) ?? false }
        func require(_ value: String, _ what: String) throws -> String {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecodeError.problem("\(tool) needs \(what).")
            }
            return value
        }
        func needID() throws -> Int {
            guard let id = integer("id") else { throw DecodeError.problem("\(tool) needs \"id\", the number of an element on screen.") }
            return id
        }

        let call: ToolCall
        switch tool {
        case "click": call = .click(id: try needID(), right: bool("right"), double: bool("double"))
        case "click_at":
            guard let x = object["x"] as? Double ?? (object["x"] as? Int).map(Double.init),
                  let y = object["y"] as? Double ?? (object["y"] as? Int).map(Double.init) else {
                throw DecodeError.problem("click_at needs x and y from 0 to 1000 over the screenshot.")
            }
            call = .clickAt(x: x, y: y)
        case "type": call = .type(id: integer("id"), text: try require(string("text"), "\"text\""), clear: bool("clear"), submit: bool("submit"))
        case "key": call = .key(try require(string("text"), "\"text\" with the keys, like cmd+s"))
        case "menu": call = .menu(string("text"))
        case "scroll": call = .scroll(direction: string("direction").isEmpty ? "down" : string("direction"), id: integer("id"), amount: integer("x") ?? 5)
        case "drag":
            guard let to = integer("to_id") else { throw DecodeError.problem("drag needs \"id\" and \"to_id\".") }
            call = .drag(fromID: try needID(), toID: to)
        case "open_app": call = .openApp(try require(string("text"), "\"text\" with the app name"))
        case "open_url": call = .openURL(try require(string("text"), "\"text\" with the address"))
        case "find": call = .find(try require(string("text"), "\"text\" to look for"))
        case "look": call = .look
        case "zoom": call = .zoom(id: try needID())
        case "read": call = .read(try require(string("text"), "\"text\" with the question to answer from this screen"))
        case "note": call = .note(try require(string("text"), "\"text\" with the fact to keep"))
        case "wait": call = .wait(min(10, max(0.5, (object["x"] as? Double) ?? (object["x"] as? Int).map(Double.init) ?? 2)))
        case "ask_user": call = .askUser(question: try require(string("text"), "\"text\" with the question"), choices: (object["choices"] as? [String]) ?? [])
        case "done": call = .done(string("text"))
        case "fail": call = .fail(try require(string("text"), "\"text\" with the reason"))
        default: throw DecodeError.problem("Unknown tool \"\(tool)\".")
        }
        return AgentDecision(thought: string("thought"), planStep: integer("step"), call: call, clearUnspecified: object["clear"] == nil)
    }

    public static func decodePlan(_ text: String) -> [String] {
        guard let data = firstJSONObject(in: text).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = object["steps"] as? [String] else { return [] }
        return steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    public static func decodeVerdict(_ text: String) -> (finished: Bool, missing: String, cannotTell: Bool)? {
        guard let data = firstJSONObject(in: text).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let finished = object["finished"] as? Bool else { return nil }
        return (finished, (object["missing"] as? String) ?? "", (object["cannot_tell"] as? Bool) ?? false)
    }

    /// Tolerates code fences or stray text. The grammar should prevent these, but
    /// not every runtime configuration applies one.
    static func firstJSONObject(in text: String) -> String {
        guard let start = text.firstIndex(of: "{") else { return text }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" { inString = true }
            else if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
            index = text.index(after: index)
        }
        return String(text[start...])
    }

    public enum DecodeError: Error, CustomStringConvertible {
        case problem(String)
        public var description: String {
            switch self { case .problem(let text): return text }
        }
    }
}

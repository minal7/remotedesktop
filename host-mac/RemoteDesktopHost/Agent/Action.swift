import Foundation

public enum AgentTarget: Equatable, Codable {
    case element(id: Int)
    case point(x: Double, y: Double)

    public func validate() throws {
        switch self {
        case let .element(id): try AgentContractValidation.require(id >= 0, "target.id must be nonnegative")
        case let .point(x, y):
            try AgentContractValidation.requireFinite(x, "target.x")
            try AgentContractValidation.requireFinite(y, "target.y")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AgentCodingKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        switch keys {
        case ["id"]:
            self = .element(id: try container.decodeRequired(Int.self, "id"))
        case ["x", "y"]:
            self = .point(x: try container.decodeRequired(Double.self, "x"), y: try container.decodeRequired(Double.self, "y"))
        default: throw AgentContractError.invalid("target must contain exactly id or x and y")
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: AgentCodingKey.self)
        switch self {
        case let .element(id): try container.encodeRequired(id, "id")
        case let .point(x, y):
            try container.encodeRequired(x, "x")
            try container.encodeRequired(y, "y")
        }
    }
}

public enum AgentMouseButton: String, Codable { case left, middle, right }
public enum AgentTextMode: String, Codable { case replace, append }
public enum AgentScrollDirection: String, Codable { case up, down, left, right }

public enum AgentAction: Equatable, Codable {
    case click(target: AgentTarget, button: AgentMouseButton?, count: Int?)
    case type(target: AgentTarget?, text: String, mode: AgentTextMode)
    case key(chord: String)
    case scroll(target: AgentTarget?, direction: AgentScrollDirection, amount: Double)
    case select(target: AgentTarget, option: String)
    case drag(from: AgentTarget, to: AgentTarget)
    case openURL(url: String)
    case openApp(name: String)
    case findFiles(query: String, kind: String?, modifiedAfter: String?)
    case setFiles(target: AgentTarget, fileIDs: [String])
    case wait(seconds: Double)
    case askUser(question: String, choices: [String]?)
    case done(answer: String)
    case fail(reason: String)

    public var type: String {
        switch self {
        case .click: "click"
        case .type: "type"
        case .key: "key"
        case .scroll: "scroll"
        case .select: "select"
        case .drag: "drag"
        case .openURL: "open_url"
        case .openApp: "open_app"
        case .findFiles: "find_files"
        case .setFiles: "set_files"
        case .wait: "wait"
        case .askUser: "ask_user"
        case .done: "done"
        case .fail: "fail"
        }
    }

    public func validate() throws {
        switch self {
        case let .click(target, _, count):
            try target.validate()
            if let count { try AgentContractValidation.require(count >= 1, "click.count must be at least 1") }
        case let .type(target, _, _): try target?.validate()
        case let .key(chord): try AgentContractValidation.requireNonEmpty(chord, "key.chord")
        case let .scroll(target, _, amount):
            try target?.validate()
            try AgentContractValidation.requireFinite(amount, "scroll.amount")
            try AgentContractValidation.require(amount > 0, "scroll.amount must be greater than zero")
        case let .select(target, _): try target.validate()
        case let .drag(from, to): try from.validate(); try to.validate()
        case let .openURL(url):
            try AgentContractValidation.requireNonEmpty(url, "open_url.url")
            try AgentContractValidation.require(AgentContractValidation.isAbsoluteURI(url), "open_url.url must be an absolute URI")
        case let .openApp(name): try AgentContractValidation.requireNonEmpty(name, "open_app.name")
        case let .findFiles(_, _, modifiedAfter):
            if let modifiedAfter {
                let formatters: [ISO8601DateFormatter] = [
                    ISO8601DateFormatter(),
                    ISO8601DateFormatter()
                ]
                formatters[0].formatOptions = [.withInternetDateTime]
                formatters[1].formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                try AgentContractValidation.require(formatters.contains { $0.date(from: modifiedAfter) != nil }, "find_files.modified_after must be an ISO-8601 date-time")
            }
        case let .setFiles(target, fileIDs):
            try target.validate()
            try AgentContractValidation.require(!fileIDs.isEmpty, "set_files.file_ids must contain at least one id")
            try fileIDs.forEach { try AgentContractValidation.requireNonEmpty($0, "set_files.file_ids item") }
        case let .wait(seconds):
            try AgentContractValidation.requireFinite(seconds, "wait.seconds")
            try AgentContractValidation.require(seconds > 0 && seconds <= 10, "wait.seconds must be in (0, 10]")
        case let .askUser(question, _): try AgentContractValidation.requireNonEmpty(question, "ask_user.question")
        case .done: break
        case let .fail(reason): try AgentContractValidation.requireNonEmpty(reason, "fail.reason")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AgentCodingKey.self)
        let kind = try container.decodeRequired(String.self, "type")
        switch kind {
        case "click":
            try container.requireKeys(["type", "target"], optional: ["button", "count"])
            self = .click(target: try container.decodeRequired(AgentTarget.self, "target"),
                          button: try container.decodeOptionalValue(AgentMouseButton.self, "button"),
                          count: try container.decodeOptionalValue(Int.self, "count"))
        case "type":
            try container.requireKeys(["type", "text", "mode"], optional: ["target"])
            self = .type(target: try container.decodeOptionalValue(AgentTarget.self, "target"),
                         text: try container.decodeRequired(String.self, "text"),
                         mode: try container.decodeRequired(AgentTextMode.self, "mode"))
        case "key":
            try container.requireKeys(["type", "chord"])
            self = .key(chord: try container.decodeRequired(String.self, "chord"))
        case "scroll":
            try container.requireKeys(["type", "direction", "amount"], optional: ["target"])
            self = .scroll(target: try container.decodeOptionalValue(AgentTarget.self, "target"),
                           direction: try container.decodeRequired(AgentScrollDirection.self, "direction"),
                           amount: try container.decodeRequired(Double.self, "amount"))
        case "select":
            try container.requireKeys(["type", "target", "option"])
            self = .select(target: try container.decodeRequired(AgentTarget.self, "target"), option: try container.decodeRequired(String.self, "option"))
        case "drag":
            try container.requireKeys(["type", "from", "to"])
            self = .drag(from: try container.decodeRequired(AgentTarget.self, "from"), to: try container.decodeRequired(AgentTarget.self, "to"))
        case "open_url":
            try container.requireKeys(["type", "url"])
            self = .openURL(url: try container.decodeRequired(String.self, "url"))
        case "open_app":
            try container.requireKeys(["type", "name"])
            self = .openApp(name: try container.decodeRequired(String.self, "name"))
        case "find_files":
            try container.requireKeys(["type", "query"], optional: ["kind", "modified_after"])
            self = .findFiles(query: try container.decodeRequired(String.self, "query"),
                              kind: try container.decodeOptionalValue(String.self, "kind"),
                              modifiedAfter: try container.decodeOptionalValue(String.self, "modified_after"))
        case "set_files":
            try container.requireKeys(["type", "target", "file_ids"])
            self = .setFiles(target: try container.decodeRequired(AgentTarget.self, "target"), fileIDs: try container.decodeRequired([String].self, "file_ids"))
        case "wait":
            try container.requireKeys(["type", "seconds"])
            self = .wait(seconds: try container.decodeRequired(Double.self, "seconds"))
        case "ask_user":
            try container.requireKeys(["type", "question"], optional: ["choices"])
            self = .askUser(question: try container.decodeRequired(String.self, "question"), choices: try container.decodeOptionalValue([String].self, "choices"))
        case "done":
            try container.requireKeys(["type", "answer"])
            self = .done(answer: try container.decodeRequired(String.self, "answer"))
        case "fail":
            try container.requireKeys(["type", "reason"])
            self = .fail(reason: try container.decodeRequired(String.self, "reason"))
        default: throw AgentContractError.invalid("unknown action type \(kind)")
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: AgentCodingKey.self)
        try container.encodeRequired(type, "type")
        switch self {
        case let .click(target, button, count):
            try container.encodeRequired(target, "target")
            try container.encodeIfPresent(button, forKey: AgentCodingKey("button"))
            try container.encodeIfPresent(count, forKey: AgentCodingKey("count"))
        case let .type(target, text, mode):
            try container.encodeIfPresent(target, forKey: AgentCodingKey("target"))
            try container.encodeRequired(text, "text"); try container.encodeRequired(mode, "mode")
        case let .key(chord): try container.encodeRequired(chord, "chord")
        case let .scroll(target, direction, amount):
            try container.encodeIfPresent(target, forKey: AgentCodingKey("target"))
            try container.encodeRequired(direction, "direction"); try container.encodeRequired(amount, "amount")
        case let .select(target, option): try container.encodeRequired(target, "target"); try container.encodeRequired(option, "option")
        case let .drag(from, to): try container.encodeRequired(from, "from"); try container.encodeRequired(to, "to")
        case let .openURL(url): try container.encodeRequired(url, "url")
        case let .openApp(name): try container.encodeRequired(name, "name")
        case let .findFiles(query, kind, modifiedAfter):
            try container.encodeRequired(query, "query"); try container.encodeIfPresent(kind, forKey: AgentCodingKey("kind"))
            try container.encodeIfPresent(modifiedAfter, forKey: AgentCodingKey("modified_after"))
        case let .setFiles(target, fileIDs): try container.encodeRequired(target, "target"); try container.encodeRequired(fileIDs, "file_ids")
        case let .wait(seconds): try container.encodeRequired(seconds, "seconds")
        case let .askUser(question, choices):
            try container.encodeRequired(question, "question"); try container.encodeIfPresent(choices, forKey: AgentCodingKey("choices"))
        case let .done(answer): try container.encodeRequired(answer, "answer")
        case let .fail(reason): try container.encodeRequired(reason, "reason")
        }
    }
}

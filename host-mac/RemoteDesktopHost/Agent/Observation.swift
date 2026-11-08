import Foundation

public enum AgentSurface: Equatable, Codable {
    case web(url: String, title: String?)
    case app(bundleID: String, title: String?)

    public var title: String? {
        switch self { case .web(_, let title), .app(_, let title): title }
    }

    public func validate() throws {
        switch self {
        case let .web(url, _): try AgentContractValidation.requireNonEmpty(url, "surface.url")
        case let .app(bundleID, _): try AgentContractValidation.requireNonEmpty(bundleID, "surface.app")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AgentCodingKey.self)
        let kind = try container.decodeRequired(String.self, "kind")
        switch kind {
        case "web":
            try container.requireKeys(["kind", "url"], optional: ["title"])
            self = .web(url: try container.decodeRequired(String.self, "url"), title: try container.decodeOptionalValue(String.self, "title"))
        case "app":
            try container.requireKeys(["kind", "app"], optional: ["title"])
            self = .app(bundleID: try container.decodeRequired(String.self, "app"), title: try container.decodeOptionalValue(String.self, "title"))
        default: throw AgentContractError.invalid("surface.kind must be web or app")
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: AgentCodingKey.self)
        switch self {
        case let .web(url, title):
            try container.encodeRequired("web", "kind"); try container.encodeRequired(url, "url")
            try container.encodeIfPresent(title, forKey: AgentCodingKey("title"))
        case let .app(bundleID, title):
            try container.encodeRequired("app", "kind"); try container.encodeRequired(bundleID, "app")
            try container.encodeIfPresent(title, forKey: AgentCodingKey("title"))
        }
    }
}

public struct AgentBoundingBox: Equatable, Codable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public func validate() throws {
        try AgentContractValidation.requireFinite(x, "bbox.x"); try AgentContractValidation.requireFinite(y, "bbox.y")
        try AgentContractValidation.requireFinite(width, "bbox.width"); try AgentContractValidation.requireFinite(height, "bbox.height")
        try AgentContractValidation.require(width >= 0 && height >= 0, "bbox dimensions must be nonnegative")
    }

    public init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        guard values.count == 4 else { throw AgentContractError.invalid("bbox must contain exactly four numbers") }
        x = try values.decode(Double.self); y = try values.decode(Double.self)
        width = try values.decode(Double.self); height = try values.decode(Double.self)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.unkeyedContainer()
        try values.encode(x); try values.encode(y); try values.encode(width); try values.encode(height)
    }
}

public struct AgentSelection: Equatable, Codable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) { self.start = start; self.end = end }

    public func validate() throws {
        try AgentContractValidation.require(start >= 0 && end >= start, "selection offsets must be nonnegative and ordered")
    }

    public init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        guard values.count == 2 else { throw AgentContractError.invalid("selection must contain exactly two integers") }
        start = try values.decode(Int.self); end = try values.decode(Int.self); try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.unkeyedContainer(); try values.encode(start); try values.encode(end)
    }
}

public struct AgentElement: Equatable, Codable {
    public let id: Int
    public let role: String
    public let name: String
    public let value: String?
    public let state: [String]
    public let bbox: AgentBoundingBox
    public let inView: Bool

    public init(id: Int, role: String, name: String, value: String?, state: [String], bbox: AgentBoundingBox, inView: Bool) {
        self.id = id; self.role = role; self.name = name; self.value = value
        self.state = state; self.bbox = bbox; self.inView = inView
    }

    public func validate() throws {
        try AgentContractValidation.require(id >= 0, "element.id must be nonnegative")
        try bbox.validate()
        if AgentContractValidation.isSecureRoleOrState(role: role, state: state) {
            try AgentContractValidation.require(value == nil, "secure element values must be null")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AgentCodingKey.self)
        try container.requireKeys(["id", "role", "name", "value", "state", "bbox", "in_view"])
        id = try container.decodeRequired(Int.self, "id"); role = try container.decodeRequired(String.self, "role")
        name = try container.decodeRequired(String.self, "name"); value = try container.decodeNullable(String.self, "value")
        state = try container.decodeRequired([String].self, "state"); bbox = try container.decodeRequired(AgentBoundingBox.self, "bbox")
        inView = try container.decodeRequired(Bool.self, "in_view"); try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: AgentCodingKey.self)
        try container.encodeRequired(id, "id"); try container.encodeRequired(role, "role"); try container.encodeRequired(name, "name")
        try container.encodeNullable(value, "value"); try container.encodeRequired(state, "state")
        try container.encodeRequired(bbox, "bbox"); try container.encodeRequired(inView, "in_view")
    }
}

public struct AgentFocus: Equatable, Codable {
    public let id: Int
    public let role: String
    public let name: String
    public let valuePrefix: String
    public let selection: AgentSelection

    public init(id: Int, role: String, name: String, valuePrefix: String, selection: AgentSelection) {
        self.id = id; self.role = role; self.name = name; self.valuePrefix = valuePrefix; self.selection = selection
    }

    public func validate() throws {
        try AgentContractValidation.require(id >= 0, "focus.id must be nonnegative"); try selection.validate()
        if AgentContractValidation.isSecureRoleOrState(role: role, state: []) {
            try AgentContractValidation.require(valuePrefix.isEmpty, "secure focus value_prefix must be empty")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AgentCodingKey.self)
        try container.requireKeys(["id", "role", "name", "value_prefix", "selection"])
        id = try container.decodeRequired(Int.self, "id"); role = try container.decodeRequired(String.self, "role")
        name = try container.decodeRequired(String.self, "name"); valuePrefix = try container.decodeRequired(String.self, "value_prefix")
        selection = try container.decodeRequired(AgentSelection.self, "selection"); try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: AgentCodingKey.self)
        try container.encodeRequired(id, "id"); try container.encodeRequired(role, "role"); try container.encodeRequired(name, "name")
        try container.encodeRequired(valuePrefix, "value_prefix"); try container.encodeRequired(selection, "selection")
    }
}

public struct AgentHistoryItem: Equatable, Codable {
    public let action: AgentAction?
    public let result: String

    public init(action: AgentAction?, result: String) { self.action = action; self.result = result }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AgentCodingKey.self)
        try container.requireKeys(["action", "result"])
        action = try container.decodeNullable(AgentAction.self, "action"); result = try container.decodeRequired(String.self, "result")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AgentCodingKey.self)
        try container.encodeNullable(action, "action"); try container.encodeRequired(result, "result")
    }
}

public struct AgentStepBudget: Equatable, Codable {
    public let step: Int
    public let maxSteps: Int

    public init(step: Int, maxSteps: Int) { self.step = step; self.maxSteps = maxSteps }
    public func validate() throws {
        try AgentContractValidation.require(step >= 0, "budget.step must be nonnegative")
        try AgentContractValidation.require(maxSteps >= 1, "budget.max_steps must be positive")
        try AgentContractValidation.require(step <= maxSteps, "budget.step must not exceed max_steps")
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AgentCodingKey.self)
        try container.requireKeys(["step", "max_steps"])
        step = try container.decodeRequired(Int.self, "step"); maxSteps = try container.decodeRequired(Int.self, "max_steps"); try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: AgentCodingKey.self)
        try container.encodeRequired(step, "step"); try container.encodeRequired(maxSteps, "max_steps")
    }
}

public struct AgentObservation: Equatable, Codable {
    public let task: String
    public let surface: AgentSurface
    public let screenshot: String
    public let elements: [AgentElement]
    public let focus: AgentFocus?
    public let history: [AgentHistoryItem]
    public let budget: AgentStepBudget

    public init(task: String, surface: AgentSurface, screenshot: String, elements: [AgentElement], focus: AgentFocus?, history: [AgentHistoryItem], budget: AgentStepBudget) {
        self.task = task; self.surface = surface; self.screenshot = screenshot; self.elements = elements
        self.focus = focus; self.history = history; self.budget = budget
    }

    public func validate() throws {
        try surface.validate(); try AgentContractValidation.requireNonEmpty(screenshot, "screenshot")
        try elements.forEach { try $0.validate() }
        try AgentContractValidation.require(Set(elements.map(\.id)).count == elements.count, "element ids must be unique")
        try focus?.validate()
        if let focus, let focusedElement = elements.first(where: { $0.id == focus.id }),
           AgentContractValidation.isSecureRoleOrState(role: focusedElement.role, state: focusedElement.state) {
            try AgentContractValidation.require(focus.valuePrefix.isEmpty, "focused secure element value_prefix must be empty")
        }
        try budget.validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AgentCodingKey.self)
        try container.requireKeys(["task", "surface", "screenshot", "elements", "focus", "history", "budget"])
        task = try container.decodeRequired(String.self, "task"); surface = try container.decodeRequired(AgentSurface.self, "surface")
        screenshot = try container.decodeRequired(String.self, "screenshot"); elements = try container.decodeRequired([AgentElement].self, "elements")
        focus = try container.decodeNullable(AgentFocus.self, "focus"); history = try container.decodeRequired([AgentHistoryItem].self, "history")
        budget = try container.decodeRequired(AgentStepBudget.self, "budget"); try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: AgentCodingKey.self)
        try container.encodeRequired(task, "task"); try container.encodeRequired(surface, "surface"); try container.encodeRequired(screenshot, "screenshot")
        try container.encodeRequired(elements, "elements"); try container.encodeNullable(focus, "focus")
        try container.encodeRequired(history, "history"); try container.encodeRequired(budget, "budget")
    }
}

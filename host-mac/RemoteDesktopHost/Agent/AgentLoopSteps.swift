import Foundation

enum AgentProgressNarration {
    static func hasSensitiveContext(_ observation: AgentObservation) -> Bool {
        observation.elements.contains {
            AgentCredentialRule.isSensitive(role: $0.role, name: $0.name, state: $0.state)
        } || observation.focus.map {
            AgentCredentialRule.isSensitive(role: $0.role, name: $0.name, state: [])
        } == true
    }

    static func text(modelText: String?, action: AgentAction?, observation: AgentObservation,
                     afterSensitiveContext: Bool = false) -> String {
        if afterSensitiveContext || hasSensitiveContext(observation) {
            return "I’m handling a sensitive control carefully."
        }
        guard let modelText = modelText?.trimmingCharacters(in: .whitespacesAndNewlines), !modelText.isEmpty else {
            return fallback(for: action)
        }
        let end = modelText.firstIndex { ".!?\n".contains($0) } ?? modelText.endIndex
        let sentence = String(modelText[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return String((sentence.isEmpty ? fallback(for: action) : sentence).prefix(120))
    }

    private static func fallback(for action: AgentAction?) -> String {
        switch action {
        case .click: "Selecting the requested control."
        case .type: "Entering the requested text."
        case .key: "Using the requested keyboard shortcut."
        case .scroll: "Scrolling the current view."
        case .openURL, .openApp: "Opening the requested destination."
        case .done: "Checking the task result."
        default: "Working on the task."
        }
    }
}

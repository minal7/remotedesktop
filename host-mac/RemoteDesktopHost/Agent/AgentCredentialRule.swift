import Foundation

enum AgentCredentialRule {
    static let personalDataRetrievalDeniedReason =
        "Personal-data retrieval is blocked. Ask the user for missing non-secret task information."

    static func isPersonalDataRetrievalControl(role: String, name: String, state: [String]) -> Bool {
        let searchable = ([role, name] + state).joined(separator: " ").lowercased()
        let compact = searchable.filter { $0.isLetter || $0.isNumber }
        if compact.contains("autofill") { return true }

        let words = searchable.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let hasSavedMarker = words.contains { ["saved", "stored"].contains($0) }
        let hasPersonalSource = words.contains {
            ["password", "passwords", "contact", "contacts", "card", "cards", "payment",
             "address", "addresses", "phone", "telephone"].contains($0)
        }
        if hasSavedMarker && hasPersonalSource { return true }

        return compact.contains("passwordmanager")
    }

    static func isSensitive(role: String, name: String, state: [String]) -> Bool {
        if AgentContractValidation.isSecureRoleOrState(role: role, state: state) { return true }
        let normalized = role.lowercased().filter(\.isLetter)
        guard ["textfield", "textbox", "textarea", "combobox", "editor"].contains(where: normalized.contains) else { return false }
        let pattern = #"\b(credentials?|password|passcode|username|one[\s-]*time\s*(?:code|password)|(?:verification|authentication|security)\s*code|otp)\b"#
        return name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

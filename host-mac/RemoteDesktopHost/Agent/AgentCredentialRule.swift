import Foundation

enum AgentCredentialRule {
    static func isSensitive(role: String, name: String, state: [String]) -> Bool {
        if AgentContractValidation.isSecureRoleOrState(role: role, state: state) { return true }
        let normalized = role.lowercased().filter(\.isLetter)
        guard ["textfield", "textbox", "textarea", "combobox", "editor"].contains(where: normalized.contains) else { return false }
        let pattern = #"\b(password|passcode|username|one[\s-]*time\s*(?:code|password)|(?:verification|authentication|security)\s*code|otp)\b"#
        return name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

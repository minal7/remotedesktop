import Foundation

/// Deterministic host-side checks that do not depend on the model choosing to
/// ask. Semantic confirmation from the model remains useful, but these rules
/// independently catch common commit, deletion, payment, account, and secret
/// entry actions using macOS Accessibility context.
enum ComputerUseActionSafetyPolicy {
    static func approvalReason(
        for action: ComputerUsePredictedAction,
        accessibilityContext: String,
        forceConfirmation: Bool = false
    ) -> String? {
        let context = accessibilityContext.lowercased()

        switch action {
        case .requestApproval(_, let proposedAction):
            return approvalReason(
                for: proposedAction,
                accessibilityContext: accessibilityContext,
                forceConfirmation: true)

        case .click:
            if containsAny(highImpactKeywords, in: context) {
                return described(
                    "Click a control that may send, purchase, save, delete, share, or change an account",
                    context: accessibilityContext)
            }
            if context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Click an unidentified item. The host could not verify its label, so your approval is required"
            }
            // A role by itself is not enough evidence to act, but a clearly
            // labelled neutral control should not turn ordinary navigation
            // into an approval loop. Consequential labels are caught above;
            // keep only genuinely unidentified controls gated here.
            if isUnidentifiedCommitCapableContext(context) {
                return described(
                    "Click an unidentified control",
                    context: accessibilityContext)
            }
            return forceConfirmation
                ? described("Click this exact item", context: accessibilityContext)
                : nil

        case .drag:
            return described(
                "Drag this item or selection to a new location",
                context: accessibilityContext)

        case .key(let usage, let modifiers):
            if usage == 0x4C {
                return "Press Delete, which may permanently remove the selected item"
            }
            if usage == 0x28 {
                if context.contains("search") {
                    return nil
                }
                return described(
                    "Press Return, which may submit the current form or message",
                    context: accessibilityContext)
            }
            if modifiers & (1 << 3) != 0,
               riskyCommandUsages.contains(usage) {
                return "Use a Command shortcut that may save, close, quit, cut, paste, or reload current work"
            }
            return forceConfirmation
                ? described("Press \(keyName(for: usage))", context: accessibilityContext)
                : nil

        case .typeText(let text):
            if containsAny(sensitiveFieldKeywords, in: context) {
                return described(
                    "Enter sensitive information into this field",
                    context: accessibilityContext)
            }
            let digits = text.filter(\.isNumber)
            let nonSeparators = text.filter {
                !$0.isNumber && !$0.isWhitespace && $0 != "-"
            }
            if nonSeparators.isEmpty,
               digits.count == 6 || (13 ... 19).contains(digits.count) {
                return "Enter a value that looks like a one-time code or payment-card number"
            }
            return forceConfirmation
                ? described(
                    "Type \(text.count) characters into this exact field",
                    context: accessibilityContext)
                : nil

        case .scroll:
            return forceConfirmation ? "Scroll the current screen" : nil

        case .wait, .done:
            return nil
        }
    }

    private static func described(_ fallback: String, context: String) -> String {
        let clean = context
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return fallback }
        return "\(fallback): “\(String(clean.prefix(120)))”"
    }

    private static let highImpactKeywords = [
        "send", "submit", "buy", "purchase", "place order", "checkout",
        "pay", "transfer", "delete", "remove", "erase", "reset", "confirm",
        "publish", "post", "share", "upload", "install", "uninstall",
        "save changes", "accept", "agree", "authorize", "subscribe", "book",
        "reserve", "finish", "create account", "sign in", "sign out", "log out",
        "security", "privacy", "password", "allow", "grant", "disable", "enable",
    ]

    private static let sensitiveFieldKeywords = [
        "secure text", "password", "passcode", "one-time", "verification code",
        "security code", "credit card", "card number", "cvv", "payment",
        "social security", "private key", "recovery key", "secret",
    ]

    private static let commitCapableRoles = [
        "axbutton", "axmenuitem", "axcheckbox", "axradiobutton",
        "axpopupbutton", "axcombobox", "axincrementor", "axslider",
        "axswitch", "axcell",
    ]

    private static func isUnidentifiedCommitCapableContext(
        _ context: String
    ) -> Bool {
        let words = normalized(context).split(separator: " ").map(String.init)
        guard words.contains(where: commitCapableRoles.contains) else {
            return false
        }
        return words.allSatisfy { word in
            commitCapableRoles.contains(word)
                || ["role", "subrole"].contains(word)
        }
    }

    private static let riskyCommandUsages: Set<Int> = [
        0x14, // Q
        0x15, // R
        0x16, // S
        0x1A, // W
        0x1B, // X
        0x19, // V
    ]

    private static func containsAny(_ keywords: [String], in text: String) -> Bool {
        let normalizedText = " \(normalized(text)) "
        return keywords.contains {
            normalizedText.contains(" \(normalized($0)) ")
        }
    }

    private static func normalized(_ value: String) -> String {
        let mapped = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(mapped)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func keyName(for usage: Int) -> String {
        switch usage {
        case 0x28: return "Return"
        case 0x29: return "Escape"
        case 0x2A: return "Backspace"
        case 0x2B: return "Tab"
        case 0x2C: return "Space"
        case 0x4C: return "Delete"
        default: return "this key"
        }
    }
}

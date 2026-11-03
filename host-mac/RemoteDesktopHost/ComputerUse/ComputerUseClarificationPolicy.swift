import Foundation

/// Recognizes prior host-authored Mail questions when scoping legacy chat
/// history. New task clarification belongs to the semantic executor.
enum ComputerUseClarificationPolicy {
    static func isMailClarification(_ value: String) -> Bool {
        let question = normalized(value)
        let knownQuestions: Set<String> = [
            "who should receive the email and what should it say",
            "who should receive the email please give me their name or email address",
            "what email address should i use for the to recipient",
            "what should the email say",
            "should i send the email now or create a draft for review",
        ]
        if knownQuestions.contains(question) { return true }
        return question.hasPrefix("which recipient field should i use for ")
            && question.hasSuffix(" to cc or bcc")
    }

    private static func normalized(_ value: String) -> String {
        let mapped = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(mapped)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

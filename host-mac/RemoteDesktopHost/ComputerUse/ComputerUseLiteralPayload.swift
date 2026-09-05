import Foundation
import CryptoKit

/// Exact user-authored data resolved by the host. Model schemas carry the ID
/// for large/whitespace-only literals instead of regenerating or truncating
/// their contents. The task itself remains the source of truth.
struct ComputerUseLiteralPayload: Equatable, Sendable {
    let id: String
    let text: String

    static func singleQuotedPayload(in task: String) -> Self? {
        var payloads: [Self] = []
        var cursor = task.startIndex
        while cursor < task.endIndex {
            let opening = task[cursor]
            guard opening == "\"" || opening == "“" else {
                cursor = task.index(after: cursor)
                continue
            }
            let closing: Character = opening == "“" ? "”" : "\""
            let start = task.index(after: cursor)
            var end = start
            while end < task.endIndex {
                let character = task[end]
                // Natural-language quotation is not a JSON/string-literal
                // escape grammar. In particular, a trailing path separator
                // must not consume the closing quotation mark.
                if character == closing { break }
                end = task.index(after: end)
            }
            guard end < task.endIndex else { return nil }
            let text = String(task[start ..< end])
            guard !text.isEmpty, text.utf8.count <= ComputerUseTextEditor.maximumPayloadBytes else {
                return nil
            }
            let digest = SHA256.hash(data: Data(text.utf8))
                .map { String(format: "%02x", $0) }.joined()
            payloads.append(Self(id: "literal-\(digest)", text: text))
            guard payloads.count == 1 else { return nil }
            cursor = task.index(after: end)
        }
        return payloads.first
    }

    static func resolve(_ id: String, in task: String) -> String? {
        guard let payload = singleQuotedPayload(in: task), payload.id == id else { return nil }
        return payload.text
    }
}

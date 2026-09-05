import Foundation

/// Compiles the complete literal grammar `set "field" to "value"` and
/// ordered repetitions. A quoted target is not an input payload. This path
/// needs no model interpretation, and never executes a recognized prefix of
/// a mixed request. Other phrasing remains with the local goal planner.
enum ComputerUseQuotedTextRequest {
    static func compile(prompt: String, fields: [ComputerUseTextField]) throws -> ComputerUseTextGoalProposal? {
        let catalog = try ComputerUseTextPayloadCatalog(prompt)
        let text = catalog.projectedTask as NSString
        let pattern = #"\[exact quoted payload (p\d+)\]\s+to\s+\[exact quoted payload (p\d+)\]"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let matches = regex.matches(in: catalog.projectedTask, range: NSRange(location: 0, length: text.length))
        guard !matches.isEmpty, matches.count <= 8 else { return nil }
        var clauses: [(String, String)] = []
        var offset = 0
        for (index, match) in matches.enumerated() {
            var separator = text.substring(with: NSRange(location: offset, length: match.range.location - offset))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            if index == 0 {
                guard ["set", "please set"].contains(separator) else { return nil }
            } else {
                if separator.hasSuffix(" set") { separator.removeLast(4) }
                guard [",", "and", "then", "and then", ", and", ", then", ", and then", "; then"].contains(separator) else { return nil }
            }
            guard let target = catalog.payloads[text.substring(with: match.range(at: 1))],
                  let value = catalog.payloads[text.substring(with: match.range(at: 2))] else { return nil }
            clauses.append((target, value))
            offset = NSMaxRange(match.range)
        }
        let suffix = text.substring(from: offset).trimmingCharacters(in: .whitespacesAndNewlines)
        guard suffix.isEmpty || suffix == "." else { return nil }

        // Resolve only after the entire command has been consumed. Even a
        // missing target in an earlier clause cannot discard a later action.
        var edits: [ComputerUseTextPlanEdit] = []
        for (name, value) in clauses {
            let targets = fields.filter { $0.label.caseInsensitiveCompare(name) == .orderedSame }
            guard targets.count == 1, let target = targets.first,
                  target.snapshot.isEditable, !target.snapshot.isSecure else { return .clarification }
            edits.append(.init(targetID: target.snapshot.targetID, mode: .replaceAll, text: value))
        }
        let edited = Set(edits.map(\.targetID))
        return .edits(edits, unchangedTargetIDs: fields.map { $0.snapshot.targetID }.filter { !edited.contains($0) })
    }
}

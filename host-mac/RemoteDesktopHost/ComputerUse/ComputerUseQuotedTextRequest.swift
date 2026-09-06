import Foundation

/// Compiles complete explicit text operations. Literal bytes, field references
/// and copied values have distinct roles before any target lookup. A matched
/// prefix of an unsupported or mixed request never becomes a partial task.
enum ComputerUseQuotedTextRequest {
    private enum Token: Equatable {
        case word(String), quoted(String), punctuation(Character)
    }
    private enum FieldReference {
        case named(String), previousTarget
    }
    private enum Payload {
        case literal(String), currentField(FieldReference)
    }
    private struct Command {
        let target: FieldReference
        let payload: Payload
        let mode: ComputerUseTextEditMode
        let allowsFollowingImplicitSet: Bool
        let targetFollowsPayload: Bool
    }

    static func compile(prompt: String, fields: [ComputerUseTextField]) throws -> ComputerUseTextGoalProposal? {
        var parser = Parser(tokens: try tokenize(prompt))
        guard let commands = parser.commands(), !commands.isEmpty else { return nil }
        var operations: [ComputerUseTextGoalOperation] = []
        var previousTarget: String?
        func resolve(_ reference: FieldReference) -> String? {
            switch reference {
            case .previousTarget:
                return previousTarget
            case .named(let name):
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                let matches = fields.filter { $0.label.caseInsensitiveCompare(name) == .orderedSame }
                guard matches.count == 1, let field = matches.first,
                      field.snapshot.isEditable, !field.snapshot.isSecure else { return nil }
                return field.snapshot.targetID
            }
        }
        // Resolve only after every command and connector was consumed. A
        // missing early field must not discard a later unsupported operation.
        for command in commands {
            guard let target = resolve(command.target) else { return .clarification }
            switch command.payload {
            case .literal(let text):
                operations.append(.enterText(.init(targetID: target, mode: command.mode, text: text)))
            case .currentField(let reference):
                guard let source = resolve(reference) else { return .clarification }
                if command.targetFollowsPayload, case .previousTarget = command.target,
                   source != target {
                    // A newly mentioned source competes with the earlier
                    // destination as the referent of "the same field".
                    return .clarification
                }
                operations.append(.copyField(sourceTargetID: source, targetID: target, mode: command.mode))
            }
            previousTarget = target
        }
        let edited = Set(operations.map(\.targetID))
        let unchanged = fields.map { $0.snapshot.targetID }.filter { !edited.contains($0) }
        let literalEdits = operations.compactMap { operation -> ComputerUseTextPlanEdit? in
            guard case .enterText(let edit) = operation else { return nil }
            return edit
        }
        if literalEdits.count == operations.count { return .edits(literalEdits, unchangedTargetIDs: unchanged) }
        return .fieldOperations(operations, unchangedTargetIDs: unchanged)
    }

    /// Reads original source, not model-facing payload markers. Natural-language
    /// quotes preserve bytes and treat backslashes literally. Eight operations
    /// may use sixteen target/value quotes without widening the model catalog.
    private static func tokenize(_ source: String) throws -> [Token] {
        guard source.utf8.count <= 32 * 1_024 else { throw ComputerUseTextTaskError.invalidPlan }
        var tokens: [Token] = []
        var cursor = source.startIndex
        while cursor < source.endIndex {
            let character = source[cursor]
            if character.isWhitespace { cursor = source.index(after: cursor); continue }
            if character == "\"" || character == "“" {
                let closing: Character = character == "“" ? "”" : "\""
                let start = source.index(after: cursor)
                guard let end = source[start...].firstIndex(of: closing) else {
                    throw ComputerUseTextTaskError.invalidPlan
                }
                let text = String(source[start..<end])
                guard text.utf8.count <= ComputerUseTextEditor.maximumPayloadBytes else {
                    throw ComputerUseTextTaskError.invalidPlan
                }
                tokens.append(.quoted(text))
                cursor = source.index(after: end)
            } else if [",", ";", "."].contains(character) {
                tokens.append(.punctuation(character))
                cursor = source.index(after: cursor)
            } else {
                let start = cursor
                while cursor < source.endIndex,
                      !source[cursor].isWhitespace,
                      !["\"", "“", ",", ";", "."].contains(source[cursor]) {
                    cursor = source.index(after: cursor)
                }
                tokens.append(.word(String(source[start..<cursor]).lowercased()))
            }
            guard tokens.count <= 256 else { throw ComputerUseTextTaskError.invalidPlan }
        }
        return tokens
    }

    private struct Parser {
        let tokens: [Token]
        var index = 0

        mutating func commands() -> [Command]? {
            var result: [Command] = []
            var allowsImplicitSet = false
            while index < tokens.count {
                guard let command = self.command(allowsImplicitSet: allowsImplicitSet),
                      let count = repetitionCount(), result.count + count <= 8 else { return nil }
                result.append(contentsOf: Array(repeating: command, count: count))
                allowsImplicitSet = command.allowsFollowingImplicitSet
                if index == tokens.count { return result }
                if take(.punctuation(".")) {
                    if index == tokens.count { return result }
                    _ = word("and"); _ = word("then")
                } else if take(.punctuation(",")) || take(.punctuation(";")) {
                    _ = word("and"); _ = word("then")
                } else if word("and") { _ = word("then") }
                else if !word("then") { return nil }
                guard index < tokens.count else { return nil }
            }
            return nil
        }

        mutating func command(allowsImplicitSet: Bool) -> Command? {
            _ = word("please")
            let isSet = word("set")
            if isSet || (allowsImplicitSet && isQuoted) {
                guard let target = field(allowPrevious: true), word("to"), let payload = self.payload() else { return nil }
                return .init(target: target, payload: payload, mode: .replaceAll,
                    allowsFollowingImplicitSet: true, targetFollowsPayload: false)
            }
            if word("replace") {
                guard let target = field(allowPrevious: true), word("with"), let payload = self.payload() else { return nil }
                return .init(target: target, payload: payload, mode: .replaceAll,
                    allowsFollowingImplicitSet: false, targetFollowsPayload: false)
            }
            if word("append") {
                guard let payload = self.payload(), word("to"), let target = field(allowPrevious: true) else { return nil }
                return .init(target: target, payload: payload, mode: .append,
                    allowsFollowingImplicitSet: false, targetFollowsPayload: true)
            }
            if word("insert") || word("type") {
                guard let payload = self.payload(), word("into") || word("in"),
                      let target = field(allowPrevious: true) else { return nil }
                return .init(target: target, payload: payload, mode: .insert,
                    allowsFollowingImplicitSet: false, targetFollowsPayload: true)
            }
            if word("copy") {
                let copied: Payload
                if let literal = introducedLiteral() { copied = .literal(literal) }
                else if let value = currentFieldValue() { copied = .currentField(value) }
                else if let source = field(allowPrevious: false, requiresFieldWord: true) { copied = .currentField(source) }
                else { return nil }
                guard word("into") || word("to"), let target = field(allowPrevious: true) else { return nil }
                return .init(target: target, payload: copied, mode: .replaceAll,
                    allowsFollowingImplicitSet: false, targetFollowsPayload: true)
            }
            return nil
        }

        mutating func payload() -> Payload? {
            if let value = quoted() { return .literal(value) }
            if let value = introducedLiteral() { return .literal(value) }
            if let reference = currentFieldValue() { return .currentField(reference) }
            return nil
        }

        mutating func introducedLiteral() -> String? {
            let saved = index
            _ = word("the")
            _ = word("exact") || word("literal")
            guard word("text") || word("words") || word("string"), let value = quoted() else {
                index = saved
                return nil
            }
            return value
        }

        mutating func currentFieldValue() -> FieldReference? {
            let saved = index
            _ = word("the")
            _ = word("current")
            guard word("value"), word("of"), let reference = field(allowPrevious: false) else {
                index = saved
                return nil
            }
            return reference
        }

        mutating func field(allowPrevious: Bool, requiresFieldWord: Bool = false) -> FieldReference? {
            let saved = index
            _ = word("the")
            if allowPrevious, word("same") {
                guard word("field") else { index = saved; return nil }
                return .previousTarget
            }
            let hasPrefix = word("field")
            if hasPrefix { _ = word("named") || word("labeled") }
            guard let name = quoted() else { index = saved; return nil }
            let hasSuffix = word("field")
            guard !requiresFieldWord || hasPrefix || hasSuffix else { index = saved; return nil }
            return .named(name)
        }

        mutating func repetitionCount() -> Int? {
            let saved = index
            _ = word("exactly")
            if word("once") { return 1 }
            if word("twice") { return 2 }
            let names = ["one": 1, "two": 2, "three": 3, "four": 4,
                         "five": 5, "six": 6, "seven": 7, "eight": 8]
            if index < tokens.count, case .word(let number) = tokens[index],
               let count = names[number] ?? Int(number) {
                index += 1
                guard (1...8).contains(count), word("times") else { return nil }
                return count
            }
            index = saved
            return 1
        }

        var isQuoted: Bool {
            guard index < tokens.count else { return false }
            if case .quoted = tokens[index] { return true }
            return false
        }
        mutating func quoted() -> String? {
            guard index < tokens.count, case .quoted(let value) = tokens[index] else { return nil }
            index += 1
            return value
        }
        mutating func word(_ word: String) -> Bool { take(.word(word)) }
        mutating func take(_ token: Token) -> Bool {
            guard index < tokens.count, tokens[index] == token else { return false }
            index += 1
            return true
        }
    }
}

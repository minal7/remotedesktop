import Foundation

/// A proposed form stage beneath the complete research goal. Source binding
/// proves where payloads came from, not that a field/option means what the model
/// thinks it means. No requirement becomes fulfilled by this proposal.
struct ComputerUseBrowserFormProposal: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Payload: Equatable, Sendable {
        case text(ComputerUseBrowserSearchQuery)
        case normalized(ComputerUseBrowserResearchFormInput.Normalization)
        case choice(id: String, requirementIndex: Int)
    }
    struct Edit: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let field: String
        let payload: Payload
        var description: String { "BrowserFormEdit" }
        var debugDescription: String { description }
    }
    struct Question: Equatable, Sendable {
        let topic: ComputerUseBrowserClarificationTopic
        let requirementIDs: [String]
    }
    struct Preservation: Equatable, Sendable {
        let field: String
        let source: ComputerUseBrowserFormSource
    }
    private let input: ComputerUseBrowserResearchFormInput
    let edits: [Edit]
    let question: Question?
    let preserved: [Preservation]
    var isUnavailable: Bool { edits.isEmpty && question == nil }
    private init(input: ComputerUseBrowserResearchFormInput, edits: [Edit] = [], question: Question? = nil, preserved: [Preservation] = []) {
        self.input = input; self.edits = edits; self.question = question; self.preserved = preserved
    }

    static func decode(content: String, input: ComputerUseBrowserResearchFormInput) throws -> Self {
        let invalid = ComputerUseBrowserResearchFormError.invalidProposal
        do {
            guard content.utf8.count <= 16 * 1_024 else { throw invalid }
            var parser = StrictSemanticJSONParser(content, maximumValueCount: 1_024)
            guard case .object(let root) = try parser.parse() else { throw invalid }
            if Set(root.keys) == ["unavailable"], case .bool(true)? = root["unavailable"] { return .init(input: input) }
            if Set(root.keys) == ["question"] {
                guard case .object(let value)? = root["question"], Set(value.keys) == ["topic", "requirements"],
                      case .string(let name)? = value["topic"], let topic = ComputerUseBrowserClarificationTopic(rawValue: name),
                      case .array(let rows)? = value["requirements"], (1...8).contains(rows.count) else { throw invalid }
                let indices = try rows.map { try requirementIndex($0, input: input) }
                guard Set(indices).count == indices.count else { throw invalid }
                let requirements = indices.map { input.interpretation.requirements[$0] }
                guard requirements.allSatisfy(topic.accepts) else { throw invalid }
                return .init(input: input, question: .init(topic: topic, requirementIDs: requirements.map(\.id)))
            }
            guard Set(root.keys) == ["edits", "preserve"], case .array(let rows)? = root["edits"], (1...8).contains(rows.count),
                  case .array(let preservationRows)? = root["preserve"], preservationRows.count <= 16 else { throw invalid }
            var edits: [Edit] = [], usedFields: Set<String> = []
            for row in rows {
                guard case .object(let item) = row, case .string(let alias)? = item["field"], input.editableFieldAliases.contains(alias), usedFields.insert(alias).inserted else { throw invalid }
                let field = try input.field(for: alias), payload: Payload
                if Set(item.keys) == ["field", "terms"] {
                    guard ["text", "search", "url", "tel", "email", "textarea"].contains(field.control.kind),
                          case .array(let values)? = item["terms"], !values.isEmpty else { throw invalid }
                    let terms: [[String: Any]] = try values.map { value in
                        guard case .object(let term) = value, Set(term.keys) == ["requirement", "text"],
                              let reference = term["requirement"], case .string(let text)? = term["text"] else { throw invalid }
                        return ["requirement":try requirementIndex(reference, input: input), "text":text]
                    }
                    // Reuse exact source ordering, UTF-8 identity, whole-turn
                    // provenance and non-prohibited-role checks from queries.
                    let content = String(decoding: try JSONSerialization.data(withJSONObject: ["terms":terms]), as: UTF8.self)
                    payload = .text(try .decode(content: content, interpretation: input.interpretation))
                } else if Set(item.keys) == ["field", "normalized"] {
                    guard case .string(let id)? = item["normalized"], let normalized = input.normalizations.first(where: { $0.id == id }),
                          (normalized.kind == .date && field.control.kind == "date")
                            || (normalized.kind == .partySize && field.control.kind == "number") else { throw invalid }
                    payload = .normalized(normalized)
                } else if Set(item.keys) == ["field", "choice", "requirement"] {
                    guard field.control.kind == "select", case .string(let id)? = item["choice"],
                          field.control.options.contains(where: { $0.id == id && !$0.disabled && !$0.hidden }),
                          let reference = item["requirement"] else { throw invalid }
                    let index = try requirementIndex(reference, input: input), requirement = input.interpretation.requirements[index]
                    guard requirement.role == .outcome || requirement.role == .condition else { throw invalid }
                    payload = .choice(id: id, requirementIndex: index)
                } else { throw invalid }
                edits.append(.init(field: alias, payload: payload))
            }
            // A changed historical criterion cannot become an unchanged
            // invariant at its newly observed value. Repair every such field
            // with a new goal-backed operation before this stage can run.
            guard Set(input.requiredRepairFieldAliases).isSubset(of: usedFields) else { throw invalid }
            var preserved = input.requiredPreservation
            for row in preservationRows {
                guard case .object(let value) = row, Set(value.keys) == ["field", "requirement"],
                      case .string(let alias)? = value["field"], usedFields.insert(alias).inserted,
                      let reference = value["requirement"] else { throw invalid }
                _ = try input.field(for: alias)
                let index = try requirementIndex(reference, input: input)
                guard [.outcome, .condition, .prohibition].contains(input.interpretation.requirements[index].role) else { throw invalid }
                if let required = preserved.first(where: { $0.field == alias }) {
                    guard try required.source.indices(in: input.interpretation).contains(index) else { throw invalid }
                } else { preserved.append(.init(field: alias, source: try .init(index: index, interpretation: input.interpretation))) }
            }
            return .init(input: input, edits: edits, preserved: preserved)
        } catch { throw invalid }
    }

    private static func requirementIndex(_ value: MCPJSONValue, input: ComputerUseBrowserResearchFormInput) throws -> Int {
        guard case .number(let number) = value, let index = Int(exactly: number),
              input.interpretation.requirements.indices.contains(index) else { throw ComputerUseBrowserResearchFormError.invalidProposal }
        return index
    }

    func validate(for current: ComputerUseBrowserResearchFormInput) throws {
        guard input == current else { throw ComputerUseBrowserResearchFormError.inputChanged }
    }

    /// An exact edit contract for native representability/preflight and later
    /// parent-stage execution. Creating it performs no effect and persists no
    /// journal. The parent must retain it before dispatch, never regenerate it
    /// to recover an attempted stage. Only user-scoped preservation becomes
    /// an invariant; ordinary unedited fields may react to the site's events.
    func textContract(for current: ComputerUseBrowserResearchFormInput, stageID: String? = nil) throws -> ComputerUseTextTaskContract? {
        try validate(for: current)
        if let stageID {
            guard stageID.utf8.count == 64, stageID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw ComputerUseBrowserResearchFormError.invalidInput
            }
        }
        guard !edits.isEmpty else { return nil }
        let operations: [ComputerUseTextGoalOperation] = try edits.map { edit in
            let field = try input.field(for: edit.field), targetID = field.editable.snapshot.targetID
            switch edit.payload {
            case .text(let query):
                guard let text = query.query else { throw ComputerUseBrowserResearchFormError.invalidProposal }
                return .enterText(.init(targetID: targetID, mode: .replaceAll, text: text))
            case .normalized(let value): return .enterText(.init(targetID: targetID, mode: .replaceAll, text: value.value))
            case .choice(let id, _): return .selectChoice(targetID: targetID, choiceID: id)
            }
        }
        let fields = input.evidence.fields.map(\.editable)
        let edited = Set(operations.map(\.targetID))
        let explicit = try preserved.map { try input.field(for: $0.field).editable.snapshot.targetID }
        let inherited = Set(input.previous?.finalValues.keys.map { $0 } ?? []).subtracting(edited)
        let unchanged = Set(explicit).union(inherited).sorted()
        let identity = stageID.map { ComputerUseTaskContract.digest(["browser-research-form-contract-v2", $0, input.contextJSON,
            input.previous?.digest ?? ""]) } ?? input.contextJSON
        return try .init(taskID: input.interpretation.input.taskID, prompt: identity, fields: fields, operations: operations,
            unchangedTargetIDs: unchanged)
    }

    func questionRequest(for current: ComputerUseBrowserResearchFormInput) throws -> ComputerUseBrowserQuestionRequest? {
        try validate(for: current)
        return question.map { .init(taskID: input.interpretation.input.taskID, inputDigest: input.interpretation.input.digest,
            topic: $0.topic, requirementIDs: $0.requirementIDs) }
    }
    var description: String { "BrowserFormProposal(edits: \(edits.count), question: \(question != nil))" }
    var debugDescription: String { description }
}

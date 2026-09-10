import Foundation

/// Each source message keeps the clock used to interpret its relative dates.
/// Neither a later message, a page nor a model may rewrite an earlier clock.
struct ComputerUseBrowserGoalInput: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    struct DateContext: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        static let maximumSeconds: TimeInterval = 253_402_300_800
        let referenceMilliseconds: Int64
        let timeZoneIdentifier: String
        init(referenceDate: Date, timeZoneIdentifier: String) throws {
            let seconds = referenceDate.timeIntervalSince1970
            guard seconds.isFinite, seconds >= 0, seconds < Self.maximumSeconds,
                  timeZoneIdentifier.utf8.count <= 128, TimeZone(identifier: timeZoneIdentifier) != nil else {
                throw ComputerUseBrowserGoalPlanError.invalidInput
            }
            referenceMilliseconds = Int64((seconds * 1_000).rounded(.towardZero))
            self.timeZoneIdentifier = timeZoneIdentifier
        }
        var plannerContext: [String: Any] {
            ["referenceUnixMilliseconds":referenceMilliseconds, "timeZone":timeZoneIdentifier]
        }
        var civilDateLabel: String {
            var calendar = Calendar(identifier: .gregorian)
            // Construction has already validated this fixed zone.
            calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
            let date = Date(timeIntervalSince1970: Double(referenceMilliseconds) / 1_000)
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        }
        var description: String { "BrowserDateContext" }
        var debugDescription: String { description }
    }
    /// Enough turns to collect several task details and explicit corrections.
    /// The complete input must still fit the independent byte/model budgets.
    static let maximumUserTurns = 16
    static let maximumUserBytes = 32 * 1_024
    static let maximumAnswerBytes = 8 * 1_024
    let taskID: String
    let prompt: String
    let rootDateContext: DateContext
    var referenceMilliseconds: Int64 { rootDateContext.referenceMilliseconds }
    var timeZoneIdentifier: String { rootDateContext.timeZoneIdentifier }
    let rootDigest: String
    let clarifications: [ComputerUseBrowserGoalClarificationTurn]
    let digest: String
    var userTurns: [String] { [prompt] + clarifications.map(\.answer) }
    var userByteCount: Int { prompt.utf8.count + clarifications.reduce(0) { $0 + $1.answer.utf8.count } }
    var remainingAnswerCount: Int { max(0, Self.maximumUserTurns - 1 - clarifications.count) }
    var nextAnswerByteLimit: Int { min(Self.maximumAnswerBytes, max(0, Self.maximumUserBytes - userByteCount)) }
    var clarificationLimitMessage: String? {
        guard remainingAnswerCount == 0 || nextAnswerByteLimit == 0 else { return nil }
        return "This request has reached its clarification limit. The original request and previous answers remain in this task. You can continue manually; Resume does not reset this limit."
    }
    func dateContext(forTurn turn: Int) -> DateContext? {
        guard userTurns.indices.contains(turn) else { return nil }
        return turn == 0 ? rootDateContext : clarifications[turn - 1].dateContext
    }

    /// A bounded source slice, not proof that the requirement belongs to an
    /// interpretation. Callers must separately retain that native provenance.
    func source(of requirement: ComputerUseBrowserGoalProposal.Requirement) -> String? {
        guard userTurns.indices.contains(requirement.sourceTurnIndex) else { return nil }
        let bytes = Data(userTurns[requirement.sourceTurnIndex].utf8)
        let start = requirement.sourceByteOffset, count = requirement.sourceByteCount
        guard start >= 0, count > 0, start <= bytes.count, count <= bytes.count - start else { return nil }
        return String(data: bytes.subdata(in: start..<(start + count)), encoding: .utf8)
    }

    init(taskID: String, prompt: String, referenceDate: Date, timeZoneIdentifier: String) throws {
        guard !taskID.isEmpty, taskID.utf8.count <= 256,
              !taskID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= Self.maximumUserBytes else {
            throw ComputerUseBrowserGoalPlanError.invalidInput
        }
        self.taskID = taskID; self.prompt = prompt
        let dateContext = try DateContext(referenceDate: referenceDate, timeZoneIdentifier: timeZoneIdentifier)
        rootDateContext = dateContext
        rootDigest = ComputerUseTaskContract.digest(["browser-goal-input-v1", taskID, prompt,
            String(dateContext.referenceMilliseconds), timeZoneIdentifier])
        clarifications = []
        digest = rootDigest
    }

    private init(continuing input: Self, turn: ComputerUseBrowserGoalClarificationTurn) {
        taskID = input.taskID; prompt = input.prompt
        rootDateContext = input.rootDateContext
        rootDigest = input.rootDigest; clarifications = input.clarifications + [turn]
        digest = ComputerUseTaskContract.digest(["browser-clarified-goal-input-v1", rootDigest] + clarifications.map(\.digest))
    }

    private init(prefixOf input: Self, answerCount: Int) {
        taskID = input.taskID; prompt = input.prompt; rootDateContext = input.rootDateContext; rootDigest = input.rootDigest
        clarifications = Array(input.clarifications.prefix(answerCount))
        digest = clarifications.isEmpty ? rootDigest
            : ComputerUseTaskContract.digest(["browser-clarified-goal-input-v1", rootDigest] + clarifications.map(\.digest))
    }

    /// Recover an actual accepted prefix without reparsing timestamps or
    /// admitting an arbitrary sibling revision with the same root task.
    func inputBeforeAnswer(at index: Int) -> Self? {
        guard clarifications.indices.contains(index) else { return nil }
        let earlier = Self(prefixOf: self, answerCount: index)
        guard earlier.digest == clarifications[index].inputDigest, continues(earlier) else { return nil }
        return earlier
    }

    /// The turn can only be created by the scoped clarification boundary.
    /// Appending user input changes the revision, never the root task/clock.
    func appending(_ turn: ComputerUseBrowserGoalClarificationTurn) throws -> Self {
        guard turn.inputDigest == digest, remainingAnswerCount > 0,
              turn.dateContext.timeZoneIdentifier == timeZoneIdentifier,
              !turn.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              turn.answer.utf8.count <= nextAnswerByteLimit,
              turn.answerTaskID != taskID, !clarifications.contains(where: { $0.answerTaskID == turn.answerTaskID }) else {
            throw ComputerUseBrowserGoalPlanError.invalidInput
        }
        return .init(continuing: self, turn: turn)
    }

    /// Only this exact root and an unchanged prefix of accepted answers may
    /// continue historical native work. A sibling answer is a different path.
    func continues(_ earlier: Self) -> Bool {
        taskID == earlier.taskID && rootDigest == earlier.rootDigest
            && prompt.utf8.elementsEqual(earlier.prompt.utf8)
            && referenceMilliseconds == earlier.referenceMilliseconds
            && timeZoneIdentifier.utf8.elementsEqual(earlier.timeZoneIdentifier.utf8)
            && clarifications.count >= earlier.clarifications.count
            && Array(clarifications.prefix(earlier.clarifications.count)) == earlier.clarifications
    }

    /// Shared structured user input for proposal-only browser planners.
    /// Transport/session identities and revision hashes stay host-side.
    var plannerContext: [String: Any] {
        plannerContext(sourceForTurn: { _, text in text })
    }

    fileprivate func plannerContext(sourceForTurn: (Int, String) -> Any) -> [String: Any] {
        let turns: [[String: Any]] = clarifications.enumerated().map { index, turn in
            ["turn":index + 1, "answer":sourceForTurn(index + 1, turn.answer), "question":turn.topic.question,
             "dateContext":turn.dateContext.plannerContext,
             "topic":turn.topic.rawValue, "scope":turn.scope.map {
                 ["turn":$0.turn, "sourceByteOffset":$0.sourceByteOffset, "source":$0.source] as [String: Any]
             }]
        }
        return ["version":clarifications.isEmpty ? 2 : 4, "request":sourceForTurn(0, prompt), "clarifications":turns,
            "referenceUnixMilliseconds":referenceMilliseconds, "timeZone":timeZoneIdentifier]
    }

    var description: String { "BrowserGoalInput(turns: \(userTurns.count), bytes: \(userTurns.reduce(0, { $0 + $1.utf8.count })))" }
    var debugDescription: String { description }
}

enum ComputerUseBrowserGoalPlanError: Error, Equatable, LocalizedError {
    case invalidInput, contextLimit, invalidResponse
    var errorDescription: String? {
        switch self {
        case .invalidInput: return "The browser request or its date context is not valid."
        case .contextLimit: return "The complete browser request does not fit the local planner."
        case .invalidResponse: return "The local planner did not return a complete, valid browser plan."
        }
    }
}

/// Source ownership stays native. Numbered lexical pieces let a proposal end a
/// clause without retyping user text or calculating Unicode offsets. These are
/// reference boundaries only: they do not establish meaning or authorization.
struct ComputerUseBrowserGoalSourceCatalogue: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let input: ComputerUseBrowserGoalInput
    let turns: [[String]]

    init(_ input: ComputerUseBrowserGoalInput) {
        self.input = input
        turns = input.userTurns.map { source in
            // Use nonlocalized word boundaries, retaining every separator and
            // any leading nonword text. Never cut a composed character. Pieces
            // are fixed for the lifetime of this exact completion request.
            let characterBoundaries = Set(source.indices)
            var boundaries: Set<String.Index> = [source.startIndex, source.endIndex]
            source.enumerateSubstrings(in: source.startIndex..<source.endIndex,
                options: [.byWords, .substringNotRequired]) { _, range, _, _ in
                if characterBoundaries.contains(range.lowerBound) { boundaries.insert(range.lowerBound) }
            }
            let ordered = boundaries.sorted()
            return zip(ordered, ordered.dropFirst()).map { String(source[$0.0..<$0.1]) }
        }
    }

    func source(turn: Int, from start: Int, through end: Int) -> String? {
        guard turns.indices.contains(turn), start >= 0, end >= start,
              turns[turn].indices.contains(end) else { return nil }
        return turns[turn][start...end].joined()
    }

    var plannerContext: [String: Any] {
        // Other browser planners retain their existing literal input contract.
        // Here each [id, text] pair replaces, rather than duplicates, user text.
        let numbered: [[[Any]]] = turns.map { pieces in pieces.enumerated().map { [$0.offset, $0.element] as [Any] } }
        var result = input.plannerContext(sourceForTurn: { turn, _ in numbered[turn] })
        result["version"] = 5
        return result
    }

    var description: String { "BrowserGoalSourceCatalogue(turns: \(turns.count), pieces: \(turns.reduce(0) { $0 + $1.count }))" }
    var debugDescription: String { description }
}

/// A no-effect interpretation, not an executable contract or completion
/// certificate. Source coverage proves retention only. Capability compilers
/// must separately bind meanings, arguments, targets and result predicates.
struct ComputerUseBrowserGoalProposal: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Disposition: String, CaseIterable, Sendable { case research, clarification, unsupported }
    enum Role: String, CaseIterable, Sendable { case outcome, condition, prohibition, order, clarification, unsupported }
    enum Field: String, CaseIterable, Sendable {
        case category, origin, destination, location, date, time, quantity, price, fees, availability, sort
        case source, navigationSource, answerSource, other
    }
    enum Relation: String, CaseIterable, Sendable {
        case unspecified, equal, notEqual, atMost, below, atLeast, above, between, include, exclude, earlier, later
    }
    struct Requirement: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let id: String
        let sourceTurnIndex: Int
        let sourceByteOffset: Int
        let sourceByteCount: Int
        let role: Role
        let field: Field
        let relation: Relation
        /// Verbatim hints from this source fragment. They do not authorize
        /// typing, establish a date/amount, or prove this field assignment.
        let values: [String]
        var description: String { "BrowserGoalRequirement(role: \(role.rawValue), field: \(field.rawValue))" }
        var debugDescription: String { description }
    }
    struct Question: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let topic: ComputerUseBrowserClarificationTopic
        let requirementIDs: [String]
        fileprivate init(topic: ComputerUseBrowserClarificationTopic, requirementIDs: [String]) {
            self.topic = topic; self.requirementIDs = requirementIDs
        }
        var description: String { "BrowserQuestionProposal(topic: \(topic.rawValue), requirements: \(requirementIDs.count))" }
        var debugDescription: String { description }
    }
    let input: ComputerUseBrowserGoalInput
    let disposition: Disposition
    let requirements: [Requirement]
    /// A proposed host topic and source scope, never model-authored display
    /// text. Only the retained owner can issue a live question/reference.
    let question: Question?
    let digest: String

    private init(input: ComputerUseBrowserGoalInput, disposition: Disposition,
                 requirements: [Requirement], question: Question?) {
        self.input = input; self.disposition = disposition; self.requirements = requirements; self.question = question
        digest = ComputerUseTaskContract.digest(["browser-goal-proposal-v4", input.digest, disposition.rawValue,
            question?.topic.rawValue ?? "none"] + (question?.requirementIDs ?? []) + requirements.map(\.id))
    }

    /// Only the complete interpretation sealed by a native question can be
    /// restored. This is historical context, not authority for new effects.
    static func interpretationBeforeAnswer(at index: Int, in input: ComputerUseBrowserGoalInput) -> Self? {
        guard let earlier = input.inputBeforeAnswer(at: index) else { return nil }
        let turn = input.clarifications[index]
        let proposal = Self(input: earlier, disposition: turn.priorDisposition,
            requirements: turn.priorRequirements, question: turn.priorQuestion)
        guard proposal.digest == turn.priorInterpretationDigest,
              proposal.requirements.allSatisfy({ earlier.source(of: $0) != nil }) else { return nil }
        return proposal
    }

    func source(of requirement: Requirement) -> String? {
        guard requirements.contains(requirement) else { return nil }
        return input.source(of: requirement)
    }

    /// Shared admission for proposed and live questions. Native interpretation
    /// here checks only the topic/source relation; it never changes the actual
    /// proposal disposition or grants research/action/completion authority.
    func permitsQuestion(topic: ComputerUseBrowserClarificationTopic, requirements selected: [Requirement]) -> Bool {
        guard disposition != .unsupported, (1...8).contains(selected.count),
              Set(selected.map(\.id)).count == selected.count, selected.allSatisfy({ requirements.contains($0) }) else { return false }
        let native: ComputerUseBrowserScalarRequirements?
        if topic.isDateTopic || topic.isQuantityTopic || input.clarifications.contains(where: { $0.topic.isReplacement }) {
            native = .init(proposal: .init(input: input, disposition: .research, requirements: requirements, question: nil))
        } else { native = nil }
        if let native {
            guard topic.isDateTopic || !selected.contains(where: native.hasDateOrigin) else { return false }
            guard topic.isQuantityTopic || !selected.contains(where: native.hasQuantityOrigin) else { return false }
            let retired = Set(native.entries.compactMap { entry -> String? in
                switch entry.resolution {
                case .superseded: return entry.requirementID
                case .clarification(let binding) where !binding.supersededDateTargetIDs.isEmpty: return entry.requirementID
                default: return nil
                }
            })
            guard selected.allSatisfy({ !retired.contains($0.id) }) else { return false }
        }
        if topic == .replaceDate { return native?.permitsDateReplacementScope(selected) == true }
        if topic.isQuantityReplacement { return native?.quantityReplacementTargets(for: selected, topic: topic) != nil }
        guard selected.allSatisfy({ topic.accepts($0)
            || (topic == .date && native?.permitsDateQuestion($0) == true)
            || (topic == .quantity && native?.permitsQuantityQuestion($0) == true) }) else { return false }
        return topic != .date || native?.permitsDateQuestionScope(selected) == true
    }

    /// Historical source text remains readable, but cannot justify a new
    /// action after explicit requirement replacement. A partly superseded shared
    /// answer also needs the still-active origin, not its ambiguous old scope.
    var retiredTaskPurposeRequirementIDs: Set<String> {
        Set(ComputerUseBrowserScalarRequirements(proposal: self).entries.compactMap { entry in
            switch entry.resolution {
            case .superseded: return entry.requirementID
            case .clarification(let binding) where !binding.supersededDateTargetIDs.isEmpty: return entry.requirementID
            default: return nil
            }
        })
    }
    func permitsTaskPurpose(_ requirement: Requirement) -> Bool {
        disposition == .research && requirements.contains(requirement) && !hasUncompiledRequirementReplacements
            && !retiredTaskPurposeRequirementIDs.contains(requirement.id)
    }
    var hasUncompiledDateReplacements: Bool { ComputerUseBrowserScalarRequirements(proposal: self).hasUncompiledDateReplacements }
    var hasUncompiledQuantityReplacements: Bool { ComputerUseBrowserScalarRequirements(proposal: self).hasUncompiledQuantityReplacements }
    var hasUncompiledRequirementReplacements: Bool { ComputerUseBrowserScalarRequirements(proposal: self).hasUncompiledRequirementReplacements }
    var quantityReplacementContexts: [ComputerUseBrowserScalarRequirements.ReplacementContext] {
        ComputerUseBrowserScalarRequirements(proposal: self).quantityReplacementContexts
    }
    func quantityReplacementTargets(for selected: [Requirement], topic: ComputerUseBrowserClarificationTopic = .replaceQuantity) -> [Requirement]? {
        let native = ComputerUseBrowserScalarRequirements(proposal: .init(input: input, disposition: .research, requirements: requirements, question: nil))
        return native.quantityReplacementTargets(for: selected, topic: topic)
    }
    var dateReplacementContexts: [ComputerUseBrowserScalarRequirements.ReplacementContext] {
        ComputerUseBrowserScalarRequirements(proposal: self).dateReplacementContexts
    }
    func dateReplacementTargets(for selected: [Requirement]) -> [Requirement]? {
        let native = ComputerUseBrowserScalarRequirements(proposal: .init(input: input, disposition: .research, requirements: requirements, question: nil))
        return native.dateReplacementTargets(for: selected)
    }

    var description: String { "BrowserGoalProposal(disposition: \(disposition.rawValue), requirements: \(requirements.count))" }
    var debugDescription: String { description }

    /// Literal-source admission for direct callers. The local model transport
    /// uses only decodeReferences and never guesses a response format.
    static func decode(content: String, input: ComputerUseBrowserGoalInput) throws -> Self {
        do { return try decodeContent(content, input: input) }
        catch { throw ComputerUseBrowserGoalPlanError.invalidResponse }
    }

    static func decodeReferences(content: String, catalogue: ComputerUseBrowserGoalSourceCatalogue) throws -> Self {
        do { return try decodeContent(content, input: catalogue.input, catalogue: catalogue) }
        catch { throw ComputerUseBrowserGoalPlanError.invalidResponse }
    }

    private static func decodeContent(_ content: String, input: ComputerUseBrowserGoalInput,
                                      catalogue: ComputerUseBrowserGoalSourceCatalogue? = nil) throws -> Self {
        guard content.utf8.count <= 16 * 1_024 else { throw ComputerUseBrowserGoalPlanError.invalidResponse }
        var parser = StrictSemanticJSONParser(content, maximumValueCount: 1_024)
        guard case .object(let root) = try parser.parse(), Set(root.keys) == ["disposition", "requirements", "question"],
              case .string(let dispositionValue)? = root["disposition"], let disposition = Disposition(rawValue: dispositionValue),
              case .object(let questionObject)? = root["question"], Set(questionObject.keys) == ["topic", "requirements"],
              case .string(let topicName)? = questionObject["topic"],
              case .array(let questionIndices)? = questionObject["requirements"], questionIndices.count <= 8,
              case .array(let rows)? = root["requirements"], (1...32).contains(rows.count) else {
            throw ComputerUseBrowserGoalPlanError.invalidResponse
        }
        let userTurns = input.userTurns
        var sources = Array(repeating: [String](), count: userTurns.count)
        var offsets = Array(repeating: 0, count: userTurns.count)
        var nextPieces = Array(repeating: 0, count: userTurns.count)
        let sourceKey = catalogue == nil ? "source" : "through"
        var requirements: [Requirement] = [], previousTurn = 0
        for (index, row) in rows.enumerated() {
            guard case .object(let item) = row, Set(item.keys) == ["turn", sourceKey, "role", "field", "relation", "values"],
                  case .number(let turnNumber)? = item["turn"], let turn = Int(exactly: turnNumber),
                  userTurns.indices.contains(turn), turn >= previousTurn,
                  case .string(let roleValue)? = item["role"], let role = Role(rawValue: roleValue),
                  case .string(let fieldValue)? = item["field"], let field = Field(rawValue: fieldValue),
                  case .string(let relationValue)? = item["relation"], let relation = Relation(rawValue: relationValue),
                  case .array(let hints)? = item["values"], hints.count <= 4 else {
                throw ComputerUseBrowserGoalPlanError.invalidResponse
            }
            let source: String
            if let catalogue {
                guard case .number(let number)? = item["through"], let end = Int(exactly: number),
                      let retained = catalogue.source(turn: turn, from: nextPieces[turn], through: end) else {
                    throw ComputerUseBrowserGoalPlanError.invalidResponse
                }
                // The next row starts at the next piece. There is no model
                // supplied start offset with which to skip or overlap source.
                source = retained; nextPieces[turn] = end + 1
            } else {
                guard case .string(let literal)? = item["source"], !literal.isEmpty,
                      literal.unicodeScalars.count <= 512, literal.utf8.count <= 2_048 else {
                    throw ComputerUseBrowserGoalPlanError.invalidResponse
                }
                source = literal
            }
            let sourceBytes = Data(source.utf8)
            var values: [String] = []
            for hint in hints {
                guard case .string(let value) = hint, !value.isEmpty, value.unicodeScalars.count <= 256, value.utf8.count <= 1_024,
                      sourceBytes.range(of: Data(value.utf8)) != nil else { throw ComputerUseBrowserGoalPlanError.invalidResponse }
                values.append(value)
            }
            let id = ComputerUseTaskContract.digest(["browser-goal-requirement-v2", input.digest, String(index),
                String(turn), String(offsets[turn]), source, role.rawValue, field.rawValue, relation.rawValue] + values)
            requirements.append(.init(id: id, sourceTurnIndex: turn, sourceByteOffset: offsets[turn], sourceByteCount: source.utf8.count,
                role: role, field: field, relation: relation, values: values))
            offsets[turn] += source.utf8.count; sources[turn].append(source); previousTurn = turn
        }
        guard zip(sources, userTurns).allSatisfy({ $0.0.joined().utf8.elementsEqual($0.1.utf8) }),
              Set(requirements.map(\.id)).count == requirements.count else { throw ComputerUseBrowserGoalPlanError.invalidResponse }
        // Contradictory dispositions cannot hide an explicitly unresolved
        // requirement. Research classification still does not prove that the
        // model chose correct roles/fields for any covered source fragment.
        if disposition == .research {
            guard requirements.contains(where: { $0.role == .outcome }),
                  !requirements.contains(where: { $0.role == .clarification || $0.role == .unsupported }) else {
                throw ComputerUseBrowserGoalPlanError.invalidResponse
            }
        }
        let question: Question?
        if disposition == .clarification {
            guard let topic = ComputerUseBrowserClarificationTopic(rawValue: topicName), !questionIndices.isEmpty else {
                throw ComputerUseBrowserGoalPlanError.invalidResponse
            }
            var indices: [Int] = []
            for value in questionIndices {
                guard case .number(let number) = value, let index = Int(exactly: number),
                      requirements.indices.contains(index), index > (indices.last ?? -1) else { throw ComputerUseBrowserGoalPlanError.invalidResponse }
                indices.append(index)
            }
            let review = Self(input: input, disposition: disposition, requirements: requirements, question: nil)
            guard review.permitsQuestion(topic: topic, requirements: indices.map { requirements[$0] }) else { throw ComputerUseBrowserGoalPlanError.invalidResponse }
            question = .init(topic: topic, requirementIDs: indices.map { requirements[$0].id })
        } else {
            guard topicName == "none", questionIndices.isEmpty else { throw ComputerUseBrowserGoalPlanError.invalidResponse }
            question = nil
        }
        return .init(input: input, disposition: disposition, requirements: requirements, question: question)
    }
}

protocol ComputerUseBrowserGoalPlanning: Sendable {
    func propose(_ input: ComputerUseBrowserGoalInput) async throws -> ComputerUseBrowserGoalProposal
}

/// Uses only the host-owned loopback connection and transport. No browser,
/// input injector, navigation API, page content or account state is available.
struct ComputerUseLocalBrowserGoalPlanner: ComputerUseBrowserGoalPlanning {
    static let contextTokens = 4_096
    static let outputTokens = 1_024
    static let framingReserve = 64
    let connection: ComputerUseTextModelConnection
    let transport: any ComputerUseTextModelTransport

    func propose(_ input: ComputerUseBrowserGoalInput) async throws -> ComputerUseBrowserGoalProposal {
        try Task.checkCancellation()
        let catalogue = ComputerUseBrowserGoalSourceCatalogue(input)
        let request = try makeRequest(catalogue)
        let count = try await transport.exactInputTokenCount(completionRequest: request)
        try Task.checkCancellation()
        guard count > 0, count <= Self.contextTokens - Self.outputTokens - Self.framingReserve else {
            throw ComputerUseBrowserGoalPlanError.contextLimit
        }
        let data = try await transport.complete(request: request)
        try Task.checkCancellation()
        return try decode(data, catalogue: catalogue)
    }

    func makeRequest(_ input: ComputerUseBrowserGoalInput) throws -> URLRequest {
        try makeRequest(ComputerUseBrowserGoalSourceCatalogue(input))
    }

    private func makeRequest(_ catalogue: ComputerUseBrowserGoalSourceCatalogue) throws -> URLRequest {
        func enumeration(_ values: [String]) -> [String: Any] { ["type":"string", "enum":values] }
        let requirement: [String: Any] = ["type":"object", "additionalProperties":false,
            "properties": [
                "turn":["type":"integer", "minimum":0, "maximum":catalogue.turns.count - 1],
                "through":["type":"integer", "minimum":0, "maximum":(catalogue.turns.map(\.count).max() ?? 1) - 1],
                "role":enumeration(ComputerUseBrowserGoalProposal.Role.allCases.map(\.rawValue)),
                "field":enumeration(ComputerUseBrowserGoalProposal.Field.allCases.map(\.rawValue)),
                "relation":enumeration(ComputerUseBrowserGoalProposal.Relation.allCases.map(\.rawValue)),
                "values":["type":"array", "maxItems":4, "items":["type":"string", "minLength":1, "maxLength":256]]],
            "required":["turn", "through", "role", "field", "relation", "values"]]
        let question: [String: Any] = ["type":"object", "additionalProperties":false,
            "properties":["topic":enumeration(["none"] + ComputerUseBrowserClarificationTopic.allCases.map(\.rawValue)),
                "requirements":["type":"array", "maxItems":8,
                    "items":["type":"integer", "minimum":0, "maximum":31]]], "required":["topic", "requirements"]]
        let schema: [String: Any] = ["type":"object", "additionalProperties":false,
            "properties":["disposition":enumeration(ComputerUseBrowserGoalProposal.Disposition.allCases.map(\.rawValue)),
                "requirements":["type":"array", "minItems":1, "maxItems":32, "items":requirement],
                "question":question], "required":["disposition", "requirements", "question"]]
        let body: [String: Any] = ["model":connection.modelAlias,
            "messages":[["role":"system", "content":Self.instructions],
                        ["role":"user", "content":String(decoding: try JSONSerialization.data(withJSONObject: catalogue.plannerContext, options: [.sortedKeys]), as: UTF8.self)]],
            "temperature":0, "top_p":1, "top_k":0, "max_tokens":Self.outputTokens, "cache_prompt":false,
            "response_format":["type":"json_schema", "json_schema":["name":"browser_goal_proposal_v5", "strict":true, "schema":schema]]]
        var request = URLRequest(url: connection.baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(connection.bearerToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        return request
    }

    func decode(_ data: Data, input: ComputerUseBrowserGoalInput) throws -> ComputerUseBrowserGoalProposal {
        try decode(data, catalogue: ComputerUseBrowserGoalSourceCatalogue(input))
    }

    private func decode(_ data: Data, catalogue: ComputerUseBrowserGoalSourceCatalogue) throws -> ComputerUseBrowserGoalProposal {
        do {
            let content = try ComputerUseBrowserModelResponse.content(data, modelAlias: connection.modelAlias)
            return try ComputerUseBrowserGoalProposal.decodeReferences(content: content, catalogue: catalogue)
        } catch { throw ComputerUseBrowserGoalPlanError.invalidResponse }
    }

    static let instructions = """
    Interpret the COMPLETE original request and every clarification answer for browser research. Return only the required JSON object. This proposal does not execute actions or certify success.
    The request is user turn 0; each clarification supplies its numbered answer. Each request/answer is a list of [piece ID, exact text] pairs. Join their text in order to read the message. For each requirement return turn and through, the inclusive last piece ID of that clause. Its start is automatically the first unused piece of that turn (initially 0). Keep rows in turn order; consume every piece exactly once through each turn's last ID. IDs restart at 0 in each turn. For [[0,"Find "],[1,"concerts. "],[2,"Do "],[3,"not "],[4,"buy."]], use through 1 for the outcome, then through 4 for the prohibition. Do not copy source text or invent byte offsets. Pieces are lexical boundaries, not separate requirements: combine them into meaningful clauses. Retain all outcomes, conditions, prohibitions, ordering and unresolved work. Never omit an old turn, summarize it, merge repeated occurrences or treat the newest answer as the whole request. Questions, scopes and clocks are context, not additional user instructions.
    Use research for information finding, including travel, concerts and movies; clarification for missing or ambiguous required details; unsupported for work outside research. Every disposition retains the complete source. Research classification does not establish interpretation correctness, available capabilities or completion. Never ask for passwords or verification codes: account login uses manual user control.
    Assign role and field from the schema. outcome is what to find/report; condition narrows acceptable results; prohibition forbids an action; order describes sequence or ranking; clarification and unsupported retain unresolved work. Use field other where needed. Preserve negation and comparative direction. Keep separate dates, locations, route legs, counts, prices, fees, availability and source restrictions separately when their source permits it. Keep each scalar clause's comparator, units and qualifiers together, including both counts of an adult/child party. values are verbatim hints from that fragment only; never invent, translate, normalize or calculate them.
    Relative dates retain the user's words and use that source turn's fixed dateContext. Later messages cannot move an earlier today/tomorrow/weekday reference. Missing units, ambiguous weekdays and conflicting literal answers remain unresolved even if a later model label changes. An unrelated answer cannot erase an earlier requirement or turn a date/price/count conflict into a website question.
    navigationSource restricts pages automation may visit; answerSource restricts sources of reported results. For these fields, include/equal denotes an exclusive allowed set and exclude/notEqual a forbidden set. Copy every stated domain/origin as its own verbatim value. Alternatives in one set belong together; separate constraints all apply. Preferences, comparisons, conditional exceptions and ambiguous website scope stay in source and need source clarification. Do not invent domains from brands, expand subdomains or remove URL paths.
    Ordinary date/quantity/price-parameter answers fill a missing detail or confirm/refine its scoped requirement; they do not authorize a conflicting replacement. replaceDate separately asks to replace one whole known date requirement, including its weekday/bound. replaceQuantity asks to replace one whole scalar count/comparator in the same known unit. replaceParty asks to replace both counts of one complete adult/child party, requiring both categories including zero. Select every source row of the chosen origin, not a partial component or two independent origins. Use replacements only for a requested correction or conflict, never to fit website results. Only the accepted explicit answer grants replacement: retain every old and new source with its original meaning. The native ledger decides which obligations are superseded; do not erase, relabel or summarize old clauses to manufacture that status. Unrelated requirements and shared confirmations remain.
    replaceAdults and replaceChildren are explicit corrections of one category of a fully known, currently bound party. Select every source row of that whole active party. The native question displays the other count that will be retained; the answer must give only the exact changed count with its adult or child label. A bare total, the other category, both categories, a bound, or extra instructions cannot complete this correction. Do not use component correction to erase an unresolved conflict. The resulting native party combines the changed count with the retained count through the question scope; it is not a literal quotation of a complete party from the new answer. Both category capacities and the new total still require native verification under active sources.
    question has topic and requirements. For research/unsupported, use none and an empty array. For clarification, choose one supported topic: \(ComputerUseBrowserClarificationTopic.allCases.map(\.rawValue).joined(separator: ", ")). Supply 1–8 distinct, increasing zero-based requirement indices. Topic fields: \(ComputerUseBrowserClarificationTopic.allCases.map { "\($0.rawValue): \($0.scopeFields.map(\.rawValue).joined(separator: "/"))" }.joined(separator: "; ")). Scope may be a related outcome when the detail has no separate clause, or matching condition/clarification rows. Only source may also select source-field prohibitions or ordering; unsupported work cannot supply scope. Native replacement admission is stricter than field labels. Never generate question text or credentials. If no topic covers the unresolved work, preserve it and use unsupported. A proposed question is not a supplied value. Cover all user source even when it cannot be interpreted; never shorten the input to fit a model budget.
    """
}

/// Common admission for proposal-only browser responses; native tool/form
/// contracts keep their own decoders and are unaffected by this helper.
enum ComputerUseBrowserModelResponse {
    static func content(_ data: Data, modelAlias: String) throws -> String {
        guard !data.isEmpty, data.count <= 256 * 1_024, let source = String(data: data, encoding: .utf8) else {
            throw ComputerUseBrowserGoalPlanError.invalidResponse
        }
        var parser = StrictSemanticJSONParser(source, maximumValueCount: 512)
        guard case .object(let root) = try parser.parse(), root["error"] == nil, root["model"] == .string(modelAlias),
              case .array(let choices)? = root["choices"], choices.count == 1,
              case .object(let choice) = choices[0], choice["finish_reason"] == .string("stop"),
              case .object(let message)? = choice["message"], message["role"] == .string("assistant"),
              case .string(let content)? = message["content"],
              message["tool_calls"] == nil || message["tool_calls"] == .null || message["tool_calls"] == .array([]),
              message["function_call"] == nil || message["function_call"] == .null,
              message["refusal"] == nil || message["refusal"] == .null || message["refusal"] == .string("") else {
            throw ComputerUseBrowserGoalPlanError.invalidResponse
        }
        return content
    }
}

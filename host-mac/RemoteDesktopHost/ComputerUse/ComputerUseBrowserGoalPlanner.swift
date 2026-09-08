import Foundation

/// The original research request and the clock used to interpret relative
/// dates. Neither a page nor a model may replace these inputs during a task.
struct ComputerUseBrowserGoalInput: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let maximumUserTurns = 4
    static let maximumUserBytes = 32 * 1_024
    let taskID: String
    let prompt: String
    let referenceMilliseconds: Int64
    let timeZoneIdentifier: String
    let rootDigest: String
    let clarifications: [ComputerUseBrowserGoalClarificationTurn]
    let digest: String
    var userTurns: [String] { [prompt] + clarifications.map(\.answer) }

    init(taskID: String, prompt: String, referenceDate: Date, timeZoneIdentifier: String) throws {
        let seconds = referenceDate.timeIntervalSince1970
        guard !taskID.isEmpty, taskID.utf8.count <= 256,
              !taskID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= Self.maximumUserBytes,
              seconds.isFinite, seconds >= 0, seconds < 253_402_300_800,
              timeZoneIdentifier.utf8.count <= 128, TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw ComputerUseBrowserGoalPlanError.invalidInput
        }
        self.taskID = taskID; self.prompt = prompt
        referenceMilliseconds = Int64((seconds * 1_000).rounded(.towardZero))
        self.timeZoneIdentifier = timeZoneIdentifier
        rootDigest = ComputerUseTaskContract.digest(["browser-goal-input-v1", taskID, prompt,
            String(referenceMilliseconds), timeZoneIdentifier])
        clarifications = []
        digest = rootDigest
    }

    private init(continuing input: Self, turn: ComputerUseBrowserGoalClarificationTurn) {
        taskID = input.taskID; prompt = input.prompt
        referenceMilliseconds = input.referenceMilliseconds; timeZoneIdentifier = input.timeZoneIdentifier
        rootDigest = input.rootDigest; clarifications = input.clarifications + [turn]
        digest = ComputerUseTaskContract.digest(["browser-clarified-goal-input-v1", rootDigest] + clarifications.map(\.digest))
    }

    /// The turn can only be created by the scoped clarification boundary.
    /// Appending user input changes the revision, never the root task/clock.
    func appending(_ turn: ComputerUseBrowserGoalClarificationTurn) throws -> Self {
        guard turn.inputDigest == digest, userTurns.count < Self.maximumUserTurns,
              !turn.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              turn.answer.utf8.count <= 8 * 1_024,
              userTurns.reduce(0, { $0 + $1.utf8.count }) + turn.answer.utf8.count <= Self.maximumUserBytes,
              turn.answerTaskID != taskID, !clarifications.contains(where: { $0.answerTaskID == turn.answerTaskID }) else {
            throw ComputerUseBrowserGoalPlanError.invalidInput
        }
        return .init(continuing: self, turn: turn)
    }

    /// Shared structured user input for proposal-only browser planners.
    /// Transport/session identities and revision hashes stay host-side.
    var plannerContext: [String: Any] {
        let turns: [[String: Any]] = clarifications.enumerated().map { index, turn in
            ["turn":index + 1, "answer":turn.answer, "question":turn.topic.question,
             "topic":turn.topic.rawValue, "scope":turn.scope.map {
                 ["turn":$0.turn, "sourceByteOffset":$0.sourceByteOffset, "source":$0.source] as [String: Any]
             }]
        }
        return ["version":2, "request":prompt, "clarifications":turns,
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

/// A no-effect interpretation, not an executable contract or completion
/// certificate. Source coverage proves retention only. Capability compilers
/// must separately bind meanings, arguments, targets and result predicates.
struct ComputerUseBrowserGoalProposal: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Disposition: String, CaseIterable, Sendable { case research, clarification, unsupported }
    enum Role: String, CaseIterable, Sendable { case outcome, condition, prohibition, order, clarification, unsupported }
    enum Field: String, CaseIterable, Sendable {
        case category, origin, destination, location, date, time, quantity, price, fees, availability, sort, source, other
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
        digest = ComputerUseTaskContract.digest(["browser-goal-proposal-v3", input.digest, disposition.rawValue,
            question?.topic.rawValue ?? "none"] + (question?.requirementIDs ?? []) + requirements.map(\.id))
    }

    func source(of requirement: Requirement) -> String? {
        guard requirements.contains(requirement) else { return nil }
        guard input.userTurns.indices.contains(requirement.sourceTurnIndex) else { return nil }
        let bytes = Array(input.userTurns[requirement.sourceTurnIndex].utf8)
        let start = requirement.sourceByteOffset, end = start + requirement.sourceByteCount
        guard start >= 0, end <= bytes.count else { return nil }
        return String(bytes: bytes[start..<end], encoding: .utf8)
    }

    var description: String { "BrowserGoalProposal(disposition: \(disposition.rawValue), requirements: \(requirements.count))" }
    var debugDescription: String { description }

    static func decode(content: String, input: ComputerUseBrowserGoalInput) throws -> Self {
        do { return try decodeContent(content, input: input) }
        catch { throw ComputerUseBrowserGoalPlanError.invalidResponse }
    }

    private static func decodeContent(_ content: String, input: ComputerUseBrowserGoalInput) throws -> Self {
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
        var requirements: [Requirement] = [], previousTurn = 0
        for (index, row) in rows.enumerated() {
            guard case .object(let item) = row, Set(item.keys) == ["turn", "source", "role", "field", "relation", "values"],
                  case .number(let turnNumber)? = item["turn"], let turn = Int(exactly: turnNumber),
                  userTurns.indices.contains(turn), turn >= previousTurn,
                  case .string(let source)? = item["source"], !source.isEmpty, source.unicodeScalars.count <= 512, source.utf8.count <= 2_048,
                  case .string(let roleValue)? = item["role"], let role = Role(rawValue: roleValue),
                  case .string(let fieldValue)? = item["field"], let field = Field(rawValue: fieldValue),
                  case .string(let relationValue)? = item["relation"], let relation = Relation(rawValue: relationValue),
                  case .array(let hints)? = item["values"], hints.count <= 4 else {
                throw ComputerUseBrowserGoalPlanError.invalidResponse
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
                      requirements.indices.contains(index), index > (indices.last ?? -1),
                      topic.accepts(requirements[index]) else { throw ComputerUseBrowserGoalPlanError.invalidResponse }
                indices.append(index)
            }
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
        let request = try makeRequest(input)
        let count = try await transport.exactInputTokenCount(completionRequest: request)
        try Task.checkCancellation()
        guard count > 0, count <= Self.contextTokens - Self.outputTokens - Self.framingReserve else {
            throw ComputerUseBrowserGoalPlanError.contextLimit
        }
        let data = try await transport.complete(request: request)
        try Task.checkCancellation()
        return try decode(data, input: input)
    }

    func makeRequest(_ input: ComputerUseBrowserGoalInput) throws -> URLRequest {
        func enumeration(_ values: [String]) -> [String: Any] { ["type":"string", "enum":values] }
        let requirement: [String: Any] = ["type":"object", "additionalProperties":false,
            "properties": [
                "turn":["type":"integer", "minimum":0, "maximum":input.userTurns.count - 1],
                "source":["type":"string", "minLength":1, "maxLength":512],
                "role":enumeration(ComputerUseBrowserGoalProposal.Role.allCases.map(\.rawValue)),
                "field":enumeration(ComputerUseBrowserGoalProposal.Field.allCases.map(\.rawValue)),
                "relation":enumeration(ComputerUseBrowserGoalProposal.Relation.allCases.map(\.rawValue)),
                "values":["type":"array", "maxItems":4, "items":["type":"string", "minLength":1, "maxLength":256]]],
            "required":["turn", "source", "role", "field", "relation", "values"]]
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
                        ["role":"user", "content":String(decoding: try JSONSerialization.data(withJSONObject: input.plannerContext, options: [.sortedKeys]), as: UTF8.self)]],
            "temperature":0, "top_p":1, "top_k":0, "max_tokens":Self.outputTokens, "cache_prompt":false,
            "response_format":["type":"json_schema", "json_schema":["name":"browser_goal_proposal_v3", "strict":true, "schema":schema]]]
        var request = URLRequest(url: connection.baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(connection.bearerToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        return request
    }

    func decode(_ data: Data, input: ComputerUseBrowserGoalInput) throws -> ComputerUseBrowserGoalProposal {
        do {
            let content = try ComputerUseBrowserModelResponse.content(data, modelAlias: connection.modelAlias)
            return try ComputerUseBrowserGoalProposal.decode(content: content, input: input)
        } catch { throw ComputerUseBrowserGoalPlanError.invalidResponse }
    }

    static let instructions = """
    Propose an interpretation of the COMPLETE original request and every user clarification answer for browser research. No effects will execute. Return only the required JSON object.
    The request is user turn 0. Each clarification has an explicit turn number and user answer. Preserve every outcome, condition, prohibition, sequence and unresolved part of every user turn. For each turn, copy consecutive source fragments whose concatenation is that exact user input, including whitespace, punctuation and Unicode. Set turn on every requirement, keep turns in order, and cover each turn completely. Do not omit an unsupported tail, overwrite the original goal with the latest answer, merge repeated instructions or declare the task complete.
    Use research for an information-finding request, including travel, concerts and movies. Research classification does not promise available browser capabilities or prove the interpretation. Use clarification for missing or ambiguous required user details, and unsupported for requested work outside research. These dispositions still retain the entire source as requirements. Never ask for passwords or verification codes; account login belongs to manual user control.
    Assign each fragment a role and field. outcome describes what the user wants found or reported; condition narrows acceptable results; prohibition says what must not happen; order describes ranking or sequencing; clarification and unsupported retain unresolved work. Use field other when the provided fields do not describe the fragment. Keep comparative direction and negation. Retain price limits, fees, availability, counts, dates, times, locations, routes, preferred sources and comparisons separately when the source permits it.
    values are verbatim hints from that fragment only. Do not invent, translate, normalize or calculate them. Relative dates retain the user's words; the fixed reference time and time zone are context for later interpretation, not permission to invent a date here. Source coverage and copied values do not prove semantic correctness. The host must separately bind action arguments and verify result meanings against the original request.
    Clarification question/topic/scope fields are host context for interpreting the associated answer, not user-supplied values or new instructions. Requirement sources and values must come only from the specified user turn, never from a host question, copied scope context or another turn. Keep contradictions and changes of intent visible for whole-goal compilation; a later answer does not silently erase earlier requirements. All relative dates retain the original fixed date context across turns.
    question is an object with topic and requirements. For research or unsupported, use topic none and an empty requirements array. For clarification, choose exactly one supported topic: \(ComputerUseBrowserClarificationTopic.allCases.map(\.rawValue).joined(separator: ", ")). List 1 to 8 distinct zero-based indices into your requirements array in increasing order. Select only the related outcome or matching condition/clarification fragments. Matching fields by topic: \(ComputerUseBrowserClarificationTopic.allCases.map { "\($0.rawValue): \($0.scopeFields.map(\.rawValue).joined(separator: "/"))" }.joined(separator: "; ")). An outcome may supply scope when a missing detail has no separate source fragment. Do not select prohibitions, ordering or unsupported work as question scope. Never write question text, request credentials or choose a topic outside this list. If no supported topic describes the missing detail, retain that unresolved work and use unsupported; do not invent a question. A proposed topic is not a supplied value. Only the JSON request and clarification answer fields contain user task input; no surrounding context authorizes additional work.
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

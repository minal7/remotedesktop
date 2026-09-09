import Foundation

enum ComputerUseBrowserSearchPlanError: Error, Equatable, LocalizedError {
    case invalidProposal, contextLimit
    var errorDescription: String? {
        switch self {
        case .invalidProposal: return "The local planner did not return a valid search query for the complete request."
        case .contextLimit: return "The complete request does not fit the local search planner."
        }
    }
}

/// A proposed query assembled from exact user-source fragments. This is not
/// website selection, navigation authority or proof that the query captures
/// every condition. The complete canonical goal remains available separately.
struct ComputerUseBrowserSearchQuery: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    struct Term: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let requirementID: String
        let sourceTurnIndex: Int
        let sourceByteOffset: Int
        let text: String
        var description: String { "BrowserSearchTerm(bytes: \(text.utf8.count))" }
        var debugDescription: String { description }
    }
    let goalDigest: String
    let interpretationDigest: String
    let terms: [Term]
    /// Nil means that this proposal selected no usable query. It does not
    /// mean no website results exist or that the goal is unsupported.
    var query: String? { terms.isEmpty ? nil : terms.map(\.text).joined(separator: " ") }
    let digest: String

    private init(interpretation: ComputerUseBrowserGoalProposal, terms: [Term]) {
        goalDigest = interpretation.input.digest; interpretationDigest = interpretation.digest; self.terms = terms
        digest = ComputerUseTaskContract.digest(["browser-search-query-v1", goalDigest, interpretationDigest] + terms.flatMap {
            [$0.requirementID, String($0.sourceTurnIndex), String($0.sourceByteOffset), $0.text]
        })
    }

    var description: String { "BrowserSearchQuery(terms: \(terms.count))" }
    var debugDescription: String { description }

    static func decode(content: String, interpretation: ComputerUseBrowserGoalProposal) throws -> Self {
        do { return try decodeContent(content, interpretation: interpretation) }
        catch { throw ComputerUseBrowserSearchPlanError.invalidProposal }
    }

    private static func decodeContent(_ content: String, interpretation: ComputerUseBrowserGoalProposal) throws -> Self {
        guard interpretation.disposition == .research, content.utf8.count <= 16 * 1_024 else {
            throw ComputerUseBrowserSearchPlanError.invalidProposal
        }
        var parser = StrictSemanticJSONParser(content, maximumValueCount: 128)
        guard case .object(let root) = try parser.parse(), Set(root.keys) == ["terms"],
              case .array(let rows)? = root["terms"], rows.count <= 12 else { throw ComputerUseBrowserSearchPlanError.invalidProposal }
        var terms: [Term] = [], previousRequirement = -1, nextSourceOffset = 0
        for row in rows {
            guard case .object(let item) = row, Set(item.keys) == ["requirement", "text"],
                  case .number(let number)? = item["requirement"], let index = Int(exactly: number),
                  interpretation.requirements.indices.contains(index), index >= previousRequirement,
                  case .string(let text)? = item["text"], !text.isEmpty, text.unicodeScalars.count <= 256, text.utf8.count <= 1_024,
                  text.utf8.elementsEqual(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8),
                  !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ComputerUseBrowserSearchPlanError.invalidProposal
            }
            let requirement = interpretation.requirements[index]
            guard requirement.role == .outcome || requirement.role == .condition,
                  interpretation.permitsTaskPurpose(requirement),
                  let source = interpretation.source(of: requirement) else { throw ComputerUseBrowserSearchPlanError.invalidProposal }
            let bytes = Data(source.utf8)
            if index != previousRequirement { nextSourceOffset = 0 }
            guard nextSourceOffset <= bytes.count,
                  let range = bytes.range(of: Data(text.utf8), in: nextSourceOffset..<bytes.count) else {
                throw ComputerUseBrowserSearchPlanError.invalidProposal
            }
            terms.append(.init(requirementID: requirement.id, sourceTurnIndex: requirement.sourceTurnIndex,
                sourceByteOffset: requirement.sourceByteOffset + range.lowerBound, text: text))
            previousRequirement = index; nextSourceOffset = range.upperBound
        }
        let proposal = Self(interpretation: interpretation, terms: terms)
        guard (proposal.query?.utf8.count ?? 0) <= 2_048 else { throw ComputerUseBrowserSearchPlanError.invalidProposal }
        return proposal
    }
}

protocol ComputerUseBrowserSearchPlanning: Sendable {
    func propose(_ interpretation: ComputerUseBrowserGoalProposal) async throws -> ComputerUseBrowserSearchQuery
}

/// Planning receives only the canonical user goal and its source ledger.
/// No page, account state, browser URL or executable tool is exposed here.
struct ComputerUseLocalBrowserSearchPlanner: ComputerUseBrowserSearchPlanning {
    let connection: ComputerUseTextModelConnection
    let transport: any ComputerUseTextModelTransport

    func propose(_ interpretation: ComputerUseBrowserGoalProposal) async throws -> ComputerUseBrowserSearchQuery {
        try Task.checkCancellation()
        let request = try makeRequest(interpretation)
        let count = try await transport.exactInputTokenCount(completionRequest: request)
        try Task.checkCancellation()
        guard count > 0, count <= ComputerUseLocalBrowserGoalPlanner.contextTokens
            - ComputerUseLocalBrowserGoalPlanner.outputTokens - ComputerUseLocalBrowserGoalPlanner.framingReserve else {
            throw ComputerUseBrowserSearchPlanError.contextLimit
        }
        let data = try await transport.complete(request: request)
        try Task.checkCancellation()
        return try decode(data, interpretation: interpretation)
    }

    func makeRequest(_ interpretation: ComputerUseBrowserGoalProposal) throws -> URLRequest {
        guard interpretation.disposition == .research else { throw ComputerUseBrowserSearchPlanError.invalidProposal }
        let term: [String: Any] = ["type":"object", "additionalProperties":false,
            "properties":["requirement":["type":"integer", "minimum":0, "maximum":interpretation.requirements.count - 1],
                "text":["type":"string", "minLength":1, "maxLength":256]], "required":["requirement", "text"]]
        let schema: [String: Any] = ["type":"object", "additionalProperties":false,
            "properties":["terms":["type":"array", "maxItems":12, "items":term]], "required":["terms"]]
        let requirements: [[String: Any]] = try interpretation.requirements.enumerated().map { index, requirement in
            guard let source = interpretation.source(of: requirement) else { throw ComputerUseBrowserSearchPlanError.invalidProposal }
            return ["index":index, "turn":requirement.sourceTurnIndex, "source":source,
                "role":requirement.role.rawValue, "field":requirement.field.rawValue]
        }
        var context: [String: Any] = ["version":1, "goal":interpretation.input.plannerContext, "requirements":requirements]
        let dateReplacements = interpretation.dateReplacementContexts
        let dateReplacementsCompiled = !interpretation.hasUncompiledDateReplacements
        if !dateReplacements.isEmpty || !dateReplacementsCompiled {
            context["version"] = 2
            context["date_replacements"] = dateReplacements.map(\.context)
            context["date_replacements_compiled"] = dateReplacementsCompiled
            let retired = interpretation.retiredTaskPurposeRequirementIDs
            context["retired_task_purpose_requirements"] = interpretation.requirements.indices.filter { retired.contains(interpretation.requirements[$0].id) }
        }
        let body: [String: Any] = ["model":connection.modelAlias,
            "messages":[["role":"system", "content":Self.instructions],
                ["role":"user", "content":String(decoding: try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]), as: UTF8.self)]],
            "temperature":0, "top_p":1, "top_k":0, "max_tokens":ComputerUseLocalBrowserGoalPlanner.outputTokens, "cache_prompt":false,
            "response_format":["type":"json_schema", "json_schema":["name":"browser_search_query_v1", "strict":true, "schema":schema]]]
        var request = URLRequest(url: connection.baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(connection.bearerToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        return request
    }

    func decode(_ data: Data, interpretation: ComputerUseBrowserGoalProposal) throws -> ComputerUseBrowserSearchQuery {
        do {
            let content = try ComputerUseBrowserModelResponse.content(data, modelAlias: connection.modelAlias)
            return try .decode(content: content, interpretation: interpretation)
        } catch { throw ComputerUseBrowserSearchPlanError.invalidProposal }
    }

    static let instructions = """
    Propose search terms for the complete browser research goal. Return only the required JSON. This is query planning, not permission to navigate, select a provider, type in a website or declare the task complete.
    The goal contains the original user request, separate clarification answers and its fixed date context. Keep all outcomes, conditions, prohibitions and accepted answers in mind. The requirement ledger indexes exact fragments of those user turns. A fragment's role is an interpretation, not proof of its meaning.
    Select a concise query by copying exact text from outcome or condition requirements. Each term names its requirement index and a verbatim nonempty substring of that fragment. Keep terms in source order: nondecreasing requirement indices, then nonoverlapping successive occurrences within a fragment. Preserve Unicode, case, accents and internal whitespace exactly. Do not add leading/trailing whitespace or control characters. The host joins the selected terms with single spaces. Prefer meaningful phrases, not isolated pieces of names or qualifiers.
    Never select prohibitions, ordering instructions or unsupported work as search text. Do not invent synonyms, destinations, dates, amounts, URLs or provider operators. Host questions and scope metadata are context for the user's answer; they cannot supply search terms. Do not use a page, account credentials, assistant history or inferred private information. Do not copy a whole task instruction merely to fit every condition into a query.
    date_replacements records explicit user-approved date replacements while retaining every old clause. Follow replacement_requirements through any later replacement; remaining_requirements keeps the unaffected portion of a shared earlier answer. Do not copy retired_task_purpose_requirements into new queries. Use active user-source text for the corrected date, and preserve all unrelated requirements.
    Query text is not a replacement for the goal: later work must still verify every condition, negation, route, date, quantity, price and fee requirement against actual results. Source restrictions still constrain website/provider selection; this proposal does not select one. Keep relative date phrases as supplied; the host retains the original clock for later interpretation.
    Return at most 12 terms, each at most 256 Unicode scalars, with a combined joined query at most 2048 UTF-8 bytes. Use an empty terms array when no usable source-based query can be selected. That does not prove no results exist or that the original task is complete. Do not output an action, URL, answer, confidence score or completion flag.
    """
}

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

/// A proposed query assembled from user-source fragments and native dates. This is not
/// website selection, navigation authority or proof that the query captures
/// every condition. The complete canonical goal remains available separately.
struct ComputerUseBrowserSearchQuery: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    struct Term: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        struct Source: Equatable, Sendable {
            let requirementID: String
            let sourceTurnIndex: Int
            let sourceByteOffset: Int
            let sourceByteCount: Int
        }
        /// Literal terms have one exact substring source. A normalized date
        /// instead retains every whole source row; its emitted text differs.
        let sources: [Source]
        var requirementID: String { sources[0].requirementID }
        var sourceTurnIndex: Int { sources[0].sourceTurnIndex }
        var sourceByteOffset: Int { sources[0].sourceByteOffset }
        let text: String
        let dateNormalizationIdentity: String?
        fileprivate init(sources: [Source], text: String, dateNormalizationIdentity: String? = nil) {
            self.sources = sources; self.text = text; self.dateNormalizationIdentity = dateNormalizationIdentity
        }
        var description: String { "BrowserSearchTerm(bytes: \(text.utf8.count))" }
        var debugDescription: String { description }
    }
    struct DateTerm: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let id: String
        let text: String
        let requirementIndices: [Int]
        fileprivate let sources: [Term.Source]
        fileprivate let identity: String
        var context: [String: Any] { ["id":id, "text":text, "requirements":requirementIndices] }
        var description: String { "BrowserDateTerm(sources: \(sources.count))" }
        var debugDescription: String { description }
    }
    static func dateTerms(for interpretation: ComputerUseBrowserGoalProposal) -> [DateTerm] {
        let ledger = ComputerUseBrowserScalarRequirements(proposal: interpretation)
        guard interpretation.disposition == .research, !ledger.hasUncompiledRequirementReplacements else { return [] }
        var seen: Set<[String]> = []
        return ledger.entries.compactMap { entry in
            guard case .bound(let condition) = entry.resolution, case .day(let range) = condition.predicate,
                  seen.insert(condition.sourceRequirementIDs).inserted,
                  let text = dateText(range) else { return nil }
            let indices = interpretation.requirements.indices.filter { condition.sourceRequirementIDs.contains(interpretation.requirements[$0].id) }
            guard indices.count == condition.sourceRequirementIDs.count, let first = indices.first,
                  Set(indices.map { interpretation.requirements[$0].sourceTurnIndex }).count == 1,
                  indices.allSatisfy({ index in
                      guard interpretation.permitsTaskPurpose(interpretation.requirements[index]),
                            case .bound(let related) = ledger.entries[index].resolution else { return false }
                      return related.predicate == condition.predicate && related.sourceRequirementIDs == condition.sourceRequirementIDs
                  }) else { return nil }
            let sources = indices.map { index -> Term.Source in
                let row = interpretation.requirements[index]
                return .init(requirementID: row.id, sourceTurnIndex: row.sourceTurnIndex,
                    sourceByteOffset: row.sourceByteOffset, sourceByteCount: row.sourceByteCount)
            }
            return .init(id: "date\(first + 1)", text: text, requirementIndices: indices, sources: sources,
                identity: ComputerUseTaskContract.digest(["browser-date-term-v1", interpretation.digest, condition.id, text] + condition.sourceRequirementIDs))
        }
    }
    private static func dateText(_ range: ComputerUseBrowserScalarRequirements.DayRange) -> String? {
        switch (range.lower, range.upper) {
        case (let lower?, let upper?):
            guard range.lowerInclusive, range.upperInclusive, lower <= upper else { return nil }
            return lower == upper ? lower.iso8601 : "from \(lower.iso8601) through \(upper.iso8601)"
        case (let lower?, nil): return (range.lowerInclusive ? "on or after " : "after ") + lower.iso8601
        case (nil, let upper?): return (range.upperInclusive ? "on or before " : "before ") + upper.iso8601
        default: return nil
        }
    }
    static func dateTermContext(for interpretation: ComputerUseBrowserGoalProposal) -> [String: Any]? {
        let ids = ComputerUseBrowserScalarRequirements(proposal: interpretation).datePayloadRequirementIDs
        guard !ids.isEmpty else { return nil }
        return ["version":1, "values":dateTerms(for: interpretation).map(\.context),
            "required_requirements":interpretation.requirements.indices.filter { ids.contains(interpretation.requirements[$0].id) }]
    }
    static func termSchema(for interpretation: ComputerUseBrowserGoalProposal) -> [String: Any] {
        let literal: [String: Any] = ["type":"object", "additionalProperties":false,
            "properties":["requirement":["type":"integer", "minimum":0, "maximum":interpretation.requirements.count - 1],
                "text":["type":"string", "minLength":1, "maxLength":256]], "required":["requirement", "text"]]
        let values = dateTerms(for: interpretation)
        guard !values.isEmpty else { return literal }
        let date: [String: Any] = ["type":"object", "additionalProperties":false,
            "properties":["date":["type":"string", "enum":values.map(\.id)]], "required":["date"]]
        return ["oneOf":[literal, date]]
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
        if terms.contains(where: { $0.dateNormalizationIdentity != nil }) {
            digest = ComputerUseTaskContract.digest(["browser-search-query-v2", goalDigest, interpretationDigest] + terms.flatMap { term in
                [term.text, term.dateNormalizationIdentity ?? "literal", String(term.sources.count)] + term.sources.flatMap {
                    [$0.requirementID, String($0.sourceTurnIndex), String($0.sourceByteOffset), String($0.sourceByteCount)]
                }
            })
        } else {
            digest = ComputerUseTaskContract.digest(["browser-search-query-v1", goalDigest, interpretationDigest] + terms.flatMap {
                [$0.requirementID, String($0.sourceTurnIndex), String($0.sourceByteOffset), $0.text]
            })
        }
    }

    var description: String { "BrowserSearchQuery(terms: \(terms.count))" }
    var debugDescription: String { description }
    func requirementIndices(in interpretation: ComputerUseBrowserGoalProposal) throws -> [Int] {
        guard goalDigest == interpretation.input.digest, interpretationDigest == interpretation.digest else { throw ComputerUseBrowserSearchPlanError.invalidProposal }
        return try terms.flatMap { term in try term.sources.map { source in
            guard let index = interpretation.requirements.firstIndex(where: { $0.id == source.requirementID }) else { throw ComputerUseBrowserSearchPlanError.invalidProposal }
            return index
        } }
    }

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
        let dates = dateTerms(for: interpretation)
        let dateRequirements = ComputerUseBrowserScalarRequirements(proposal: interpretation).datePayloadRequirementIDs
        for row in rows {
            guard case .object(let item) = row else { throw ComputerUseBrowserSearchPlanError.invalidProposal }
            if Set(item.keys) == ["date"] {
                guard case .string(let id)? = item["date"], let value = dates.first(where: { $0.id == id }),
                      let first = value.requirementIndices.first, let last = value.requirementIndices.last,
                      first > previousRequirement else { throw ComputerUseBrowserSearchPlanError.invalidProposal }
                terms.append(.init(sources: value.sources, text: value.text, dateNormalizationIdentity: value.identity))
                previousRequirement = last; nextSourceOffset = interpretation.requirements[last].sourceByteCount
                continue
            }
            guard Set(item.keys) == ["requirement", "text"],
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
                  !dateRequirements.contains(requirement.id),
                  let source = interpretation.source(of: requirement) else { throw ComputerUseBrowserSearchPlanError.invalidProposal }
            let bytes = Data(source.utf8)
            if index != previousRequirement { nextSourceOffset = 0 }
            guard nextSourceOffset <= bytes.count,
                  let range = bytes.range(of: Data(text.utf8), in: nextSourceOffset..<bytes.count) else {
                throw ComputerUseBrowserSearchPlanError.invalidProposal
            }
            terms.append(.init(sources: [.init(requirementID: requirement.id, sourceTurnIndex: requirement.sourceTurnIndex,
                sourceByteOffset: requirement.sourceByteOffset + range.lowerBound, sourceByteCount: text.utf8.count)], text: text))
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
        let term = ComputerUseBrowserSearchQuery.termSchema(for: interpretation)
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
        let dateTerms = ComputerUseBrowserSearchQuery.dateTermContext(for: interpretation)
        if let dateTerms { context["version"] = 3; context["date_terms"] = dateTerms }
        let quantityReplacements = interpretation.quantityReplacementContexts
        if !quantityReplacements.isEmpty || interpretation.hasUncompiledQuantityReplacements {
            context["version"] = 4
            context["quantity_replacements"] = quantityReplacements.map(\.context)
            context["quantity_replacements_compiled"] = !interpretation.hasUncompiledQuantityReplacements
            let retired = interpretation.retiredTaskPurposeRequirementIDs
            context["retired_task_purpose_requirements"] = interpretation.requirements.indices.filter { retired.contains(interpretation.requirements[$0].id) }
        }
        let body: [String: Any] = ["model":connection.modelAlias,
            "messages":[["role":"system", "content":Self.instructions],
                ["role":"user", "content":String(decoding: try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]), as: UTF8.self)]],
            "temperature":0, "top_p":1, "top_k":0, "max_tokens":ComputerUseLocalBrowserGoalPlanner.outputTokens, "cache_prompt":false,
            "response_format":["type":"json_schema", "json_schema":["name":dateTerms == nil ? "browser_search_query_v1" : "browser_search_query_v2", "strict":true, "schema":schema]]]
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
    The goal contains the original user request, separate clarification answers and the fixed date context of each source turn. Keep all outcomes, conditions, prohibitions and accepted answers in mind. The requirement ledger indexes exact fragments of those user turns. A fragment's role is an interpretation, not proof of its meaning.
    Select a concise query using literal terms or offered native date terms. A literal term names its requirement index and a verbatim nonempty substring of that fragment. Keep terms in source order: nondecreasing requirement indices, then nonoverlapping successive occurrences within a fragment. Preserve Unicode, case, accents and internal whitespace exactly. Do not add leading/trailing whitespace or control characters. The host joins the selected terms with single spaces. Prefer meaningful phrases, not isolated pieces of names or qualifiers.
    date_terms version 1 supplies native values with IDs, emitted text and complete source requirement lists. Select one with {"date":"dateN"}; do not also supply text or a requirement. The host emits that fixed civil date or complete before/after/range phrase. It uses the source message's date context and retains all source rows. Treat it as occupying its full source interval when ordering terms. required_requirements cannot supply literal terms, even substrings or absolute-looking endpoints; use an offered date term or leave that date for later clarification/form work. A missing value is unresolved, not permission to guess. Do not split a range, remove its comparator, copy a superseded date or reuse a date ID from another context. Native date text supplies neither a time zone for a website nor proof that a particular provider understands the format.
    Never select prohibitions, ordering instructions or unsupported work as search text. Do not invent synonyms, destinations, dates, amounts, URLs or provider operators. Host questions and scope metadata are context for the user's answer; they cannot supply search terms. Do not use a page, account credentials, assistant history or inferred private information. Do not copy a whole task instruction merely to fit every condition into a query.
    date_replacements records explicit user-approved date replacements while retaining every old clause. Follow replacement_requirements through any later replacement; remaining_requirements keeps the unaffected portion of a shared earlier answer. Do not copy retired_task_purpose_requirements into new queries. Use an active native date term for the corrected date, and preserve all unrelated requirements.
    replaceQuantity is an explicit user correction of one complete known count with its unit. Its fixed question replaces that count and comparator, while retaining every other requirement. An accepted answer must give the same unit, such as three tickets; bare counts, changed units, adult/child compositions, and shared multi-origin confirmations cannot use this replacement. Never propose a replacement merely to fit website results. quantity_replacements links retired rows to their replacement_requirements; follow later replacements. Old rows remain history and cannot justify a new query, field value, selection or private read. A field based on the old count needs fresh active provenance and native verification before submission, even if its text is unchanged. Pending input and preservation duties remain in force.
    replaceParty is the separate explicit correction question for one complete known adult/child party. Select every source row of that whole party, not only one component. Its fixed text requires both new counts, including zero when needed. Only an accepted complete adult/child answer replaces that party; a total, ticket count, omitted component or changed label cannot. Other parties and all unrelated constraints remain. quantity_replacements retains old compositions and their replacement links. Old category or total fields need fresh active source verification before query submission, even if the total or one count is unchanged. Never discard shared confirmations or pending native input to make a correction proceed.
    replaceAdults and replaceChildren are explicit corrections of one category of a fully known, currently bound party. Select every source row of that whole active party. The native question displays the other count that will be retained; the answer must give only the exact changed count with its adult or child label. A bare total, the other category, both categories, a bound, or extra instructions cannot complete this correction. Do not use component correction to erase an unresolved conflict. The resulting native party combines the changed count with the retained count through the question scope; it is not a literal quotation of a complete party from the new answer. Both category capacities and the new total still require native verification under active sources.
    Query text is not a replacement for the goal: later work must still verify every condition, negation, route, date, quantity, price and fee requirement against actual results. Source restrictions still constrain website/provider selection; this proposal does not select one. Never send a known date's relative wording for a website to reinterpret using its own clock. Initial broad fragments with uncompiled embedded dates still require semantic interpretation; the catalogue does not prove that every date in the task was recognized.
    Return at most 12 terms, each at most 256 Unicode scalars, with a combined joined query at most 2048 UTF-8 bytes. Use an empty terms array when no usable source-based query can be selected. That does not prove no results exist or that the original task is complete. Do not output an action, URL, answer, confidence score or completion flag.
    """
}

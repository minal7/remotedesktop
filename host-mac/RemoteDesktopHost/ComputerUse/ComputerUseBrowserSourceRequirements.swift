import Foundation

/// Compile the source portion of a complete, source-covered interpretation.
/// The model still proposes scope/logic; this compiler validates concrete
/// origin sets, never proves that classification semantically correct. No
/// page text, model-authored URL or implicit search-provider exception enters
/// the policy. Ambiguous/unsupported source clauses remain unresolved.
struct ComputerUseBrowserSourceRequirements: Sendable {
    enum UnresolvedReason: String, Hashable, Sendable {
        case ambiguousScope, unsupportedRelation, invalidOrigin, contradictorySources, unresolvedDisposition, sourceLimit
    }
    struct Unresolved: Sendable {
        let requirementID: String
        let reason: UnresolvedReason
    }
    private struct Scope: Sendable {
        var allowed: Set<ComputerUseBrowserSourceOrigin>? = nil
        var excluded: Set<ComputerUseBrowserSourceOrigin> = []
        var requirementIDs: [String] = []
        mutating func include(_ origins: Set<ComputerUseBrowserSourceOrigin>) {
            allowed = allowed.map { $0.intersection(origins) } ?? origins
        }
        var isContradictory: Bool { allowed.map { $0.subtracting(excluded).isEmpty } ?? false }
    }
    let goal: ComputerUseBrowserGoalInput
    let interpretationDigest: String
    let unresolved: [Unresolved]
    private let navigation: Scope
    private let answers: Scope
    private let isResearch: Bool

    /// Ordinary visible web search with the provider's default settings.
    /// Query syntax is only a search aid, never proof of source eligibility.
    static func defaultProviders() throws -> [ComputerUseBrowserSearchProvider] {
        guard let endpoint = URL(string: "https://duckduckgo.com/") else { throw ComputerUseBrowserInitialSearchError.invalidRequest }
        return [try .init(endpoint: endpoint, queryParameter: "q")]
    }

    init(proposal: ComputerUseBrowserGoalProposal) {
        goal = proposal.input; interpretationDigest = proposal.digest
        isResearch = proposal.disposition == .research
        var navigation = Scope(), answers = Scope(), unresolved: [Unresolved] = []
        let nativeScalarSources = Set(ComputerUseBrowserScalarRequirements(proposal: proposal).entries.compactMap { entry -> String? in
            if case .clarification = entry.resolution { return entry.requirementID }
            if case .bound(let condition) = entry.resolution, condition.hasHistoricalSource { return entry.requirementID }
            return nil
        })
        for requirement in proposal.requirements {
            // A sealed literal answer or retained native scalar clause has
            // host-known meaning even if its model field label is wrong.
            if nativeScalarSources.contains(requirement.id) { continue }
            guard [.source, .navigationSource, .answerSource].contains(requirement.field) else { continue }
            func reject(_ reason: UnresolvedReason) { unresolved.append(.init(requirementID: requirement.id, reason: reason)) }
            guard proposal.disposition == .research else { reject(.unresolvedDisposition); continue }
            guard requirement.field != .source else { reject(.ambiguousScope); continue }
            let includes = (requirement.role == .condition || requirement.role == .outcome)
                && (requirement.relation == .include || requirement.relation == .equal)
            let excludes = (requirement.role == .condition || requirement.role == .prohibition)
                && (requirement.relation == .exclude || requirement.relation == .notEqual)
            guard includes || excludes else { reject(.unsupportedRelation); continue }
            // Every hinted source must resolve. Dropping one would turn an
            // incomplete set into an apparently executable source decision.
            let origins = requirement.values.compactMap { try? Self.origin(from: $0) }
            guard let source = proposal.source(of: requirement), !requirement.values.isEmpty,
                  origins.count == requirement.values.count,
                  requirement.values.allSatisfy({ Self.isStandaloneReference($0, in: source) }) else { reject(.invalidOrigin); continue }
            var scope = requirement.field == .navigationSource ? navigation : answers
            scope.requirementIDs.append(requirement.id)
            if includes { scope.include(Set(origins)) } else { scope.excluded.formUnion(origins) }
            if requirement.field == .navigationSource { navigation = scope } else { answers = scope }
        }
        // A new interpretation still covers all bytes, but it can relabel an
        // earlier source clause or drop a domain hint. Keep concrete policies
        // from the complete interpretation sealed when each question was
        // issued, including restrictions outside that question's scope.
        // Explicit scope/intent replacement requires separate reconciliation.
        for answer in proposal.input.clarifications {
            for requirement in answer.priorRequirements {
                guard [.navigationSource, .answerSource].contains(requirement.field),
                      let source = proposal.input.source(of: requirement) else { continue }
                let includes = (requirement.role == .condition || requirement.role == .outcome)
                    && (requirement.relation == .include || requirement.relation == .equal)
                let excludes = (requirement.role == .condition || requirement.role == .prohibition)
                    && (requirement.relation == .exclude || requirement.relation == .notEqual)
                let origins = requirement.values.compactMap { try? Self.origin(from: $0) }
                guard includes || excludes, !origins.isEmpty, origins.count == requirement.values.count,
                      requirement.values.allSatisfy({ Self.isStandaloneReference($0, in: source) }) else { continue }
                let currentIDs = proposal.requirements.filter {
                    $0.sourceTurnIndex == requirement.sourceTurnIndex
                        && $0.sourceByteOffset < requirement.sourceByteOffset + requirement.sourceByteCount
                        && requirement.sourceByteOffset < $0.sourceByteOffset + $0.sourceByteCount
                }.map(\.id)
                // Native scalar literals keep their meaning even if an old
                // model assigned those same source bytes a website field.
                guard !currentIDs.isEmpty, !currentIDs.allSatisfy(nativeScalarSources.contains) else { continue }
                var scope = requirement.field == .navigationSource ? navigation : answers
                let additionalIDs = currentIDs.filter { !scope.requirementIDs.contains($0) }
                scope.requirementIDs.append(contentsOf: additionalIDs)
                if includes { scope.include(Set(origins)) } else { scope.excluded.formUnion(origins) }
                if requirement.field == .navigationSource { navigation = scope } else { answers = scope }
            }
        }
        for scope in [navigation, answers] where scope.isContradictory {
            unresolved += scope.requirementIDs.map { .init(requirementID: $0, reason: .contradictorySources) }
        }
        for scope in [navigation, answers] where scope.excluded.count > 32 || (scope.allowed?.count ?? 0) > 32 {
            let existing = Set(unresolved.map(\.requirementID))
            unresolved += scope.requirementIDs.filter { !existing.contains($0) }.map { .init(requirementID: $0, reason: .sourceLimit) }
        }
        // A search must be able to reach some eligible result document. Do
        // not silently treat a conflicting navigation/result pair as solved.
        let reachableAnswers: Set<ComputerUseBrowserSourceOrigin>?
        if let allowed = navigation.allowed, let eligible = answers.allowed { reachableAnswers = allowed.intersection(eligible) }
        else { reachableAnswers = navigation.allowed ?? answers.allowed }
        if let reachableAnswers, reachableAnswers.subtracting(navigation.excluded.union(answers.excluded)).isEmpty {
            let existing = Set(unresolved.map(\.requirementID))
            unresolved += (navigation.requirementIDs + answers.requirementIDs).filter { !existing.contains($0) }
                .map { .init(requirementID: $0, reason: .contradictorySources) }
        }
        self.navigation = navigation; self.answers = answers; self.unresolved = unresolved
    }

    /// A domain without a scheme denotes its HTTPS origin. Explicit URLs
    /// retain their scheme/port. No www/subdomain/brand/path expansion occurs.
    /// Paths, queries and fragments must not be discarded as if origin-only.
    private static func origin(from value: String) throws -> ComputerUseBrowserSourceOrigin {
        guard !value.isEmpty, value.utf8.allSatisfy({ (33...126).contains($0) }),
              !value.contains("\\"), !value.contains("%") else { throw ComputerUseBrowserError.sourceNotAllowed }
        let explicitScheme = value.contains("://")
        guard let parts = URLComponents(string: explicitScheme ? value : "https://" + value),
              let host = parts.host, explicitScheme || host.contains("."),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/",
              let url = parts.url else { throw ComputerUseBrowserError.sourceNotAllowed }
        return try ComputerUseBrowserSourceOrigin(url)
    }

    /// Copying a host substring out of an email, longer host or path-restricted
    /// URL does not authorize its origin. This checks token boundaries only;
    /// it cannot prove that the model retained all websites or sentence logic.
    private static func isStandaloneReference(_ value: String, in source: String) -> Bool {
        var start = source.startIndex
        while start < source.endIndex, let range = source.range(of: value, options: .literal, range: start..<source.endIndex) {
            let before = range.lowerBound == source.startIndex ? nil : source[source.index(before: range.lowerBound)]
            let after = source[range.upperBound...]
            func terminal(_ tail: Substring) -> Bool {
                guard let first = tail.first else { return true }
                return first.isWhitespace || "\"')>],;!".contains(first)
            }
            let begins = before.map { $0.isWhitespace || "\"'(<[".contains($0) } ?? true
            if begins, terminal(after) || (after.first == "." && terminal(after.dropFirst())) { return true }
            start = range.upperBound
        }
        return false
    }

    /// The host supplies a finite ordered provider catalog. A source conflict
    /// selects another catalog entry or returns nil, never widens navigation.
    func selectSources(from providers: [ComputerUseBrowserSearchProvider]) throws -> ComputerUseBrowserResearchSources? {
        try Task.checkCancellation()
        guard isResearch, unresolved.isEmpty, (1...32).contains(providers.count) else { return nil }
        let policy = try ComputerUseBrowserSourcePolicy(goal: goal,
            allowedOrigins: navigation.allowed.map(Array.init), excludedOrigins: Array(navigation.excluded))
        for provider in providers {
            do { try provider.validateSourcePolicy(policy) }
            catch ComputerUseBrowserError.sourceNotAllowed { continue }
            return try .init(goal: goal, provider: provider,
                allowedOrigins: navigation.allowed.map(Array.init), excludedOrigins: Array(navigation.excluded),
                answerAllowedOrigins: answers.allowed.map(Array.init), answerExcludedOrigins: Array(answers.excluded))
        }
        return nil
    }

    /// Match the policy that actually governed this reading, not merely a
    /// permitted-origin label from an unrelated or looser configuration.
    /// Extra filtering remains usable when the goal has no answer-source clause.
    func matchesAnswerPolicy(_ policy: ComputerUseBrowserAnswerSourcePolicy?) -> Bool {
        guard isResearch, unresolved.isEmpty, let policy, policy.goalRevision == goal.digest else { return false }
        guard !answers.requirementIDs.isEmpty else { return true }
        guard let expected = try? ComputerUseBrowserAnswerSourcePolicy(goal: goal,
            allowedOrigins: answers.allowed.map(Array.init), excludedOrigins: Array(answers.excluded)) else { return false }
        return policy == expected
    }

    /// Exact configuration correspondence, not evidence that a route obeyed
    /// it. Older goal revisions require lineage reconciliation separately.
    func matchesNavigationPolicy(_ policy: ComputerUseBrowserSourcePolicy?) -> Bool {
        guard isResearch, unresolved.isEmpty, let policy,
              policy.taskID == goal.taskID, policy.rootDigest == goal.rootDigest,
              policy.goalRevision == goal.digest else { return false }
        guard requiresNavigationHistory else { return true }
        guard let expected = try? ComputerUseBrowserSourcePolicy(goal: goal,
            allowedOrigins: navigation.allowed.map(Array.init), excludedOrigins: Array(navigation.excluded)) else { return false }
        return policy == expected
    }

    /// A resegmented row may contain other work as well. This identifies
    /// an additional source-policy obligation, not its complete meaning.
    func hasAnswerPolicyObligation(for requirementID: String) -> Bool {
        answers.requirementIDs.contains(requirementID)
    }

    /// Navigation constraints describe the automation's actions over time.
    /// Neither an installed policy nor a permitted answer document proves
    /// that history. Include retained constraints hidden by resegmentation.
    var requiresNavigationHistory: Bool { !navigation.requirementIDs.isEmpty }

    func hasNavigationHistoryObligation(for requirementID: String) -> Bool {
        navigation.requirementIDs.contains(requirementID)
    }
}

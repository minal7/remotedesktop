import Foundation

/// Compiles scalar conditions without pretending to compile the whole goal.
/// Every proposal requirement keeps a ledger entry, including unresolved
/// outcomes, places, sequencing and unsupported language. No effects occur.
/// A bound fragment still needs whole-goal role, scope and logic validation:
/// separate fragments can negate or qualify a locally parsed condition.
struct ComputerUseBrowserScalarRequirements: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum UnresolvedReason: String, Sendable {
        case unresolvedDisposition, notScalar, unrecognizedSource, invalidValue, contradictoryProposal, ambiguousDate
        case ambiguousClarification, clarificationScope, contradictoryClarification
        case historicalScalarScope
        case missingQuantityUnit
        case ambiguousPartyScope
    }
    enum Resolution: Equatable, Sendable {
        case bound(Condition), clarification(ClarificationBinding), unresolved(UnresolvedReason)
        case superseded(Supersession)
        /// A complete weekday clause retained from a prior interpretation.
        /// These native source IDs preserve the uncertainty, not a date value.
        case historicalDateAmbiguity([String])
        /// A retained count/comparator still needs a unit before evaluation.
        case historicalQuantityUnit([String])
    }
    /// The original source remains in the goal. Only an answer to the explicit
    /// native replacement question can retire its active scalar obligation.
    struct Supersession: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let id: String
        let topic: ComputerUseBrowserClarificationTopic
        let answerTurns: [Int]
        let replacementRequirementIDs: [String]
        fileprivate init(input: ComputerUseBrowserGoalInput, requirementID: String, answerTurns: [Int], replacements: [String],
                         topic: ComputerUseBrowserClarificationTopic = .replaceDate) {
            self.topic = topic
            self.answerTurns = answerTurns; replacementRequirementIDs = replacements
            let version = topic == .replaceDate ? "browser-date-supersession-v1"
                : (topic == .replaceParty ? "browser-party-supersession-v1" : "browser-quantity-supersession-v1")
            id = ComputerUseTaskContract.digest([version, input.digest, requirementID]
                + answerTurns.map(String.init) + replacements)
        }
        var description: String { "BrowserScalarSupersession(topic: \(topic.rawValue), turns: \(answerTurns.count), replacements: \(replacementRequirementIDs.count))" }
        var debugDescription: String { description }
    }
    struct ReplacementContext: Equatable, Sendable {
        let requirement: Int
        let replacements: [Int]
        let remaining: [Int]
        let superseded: [Int]
        let answerTurns: [Int]
        var context: [String: Any] {
            ["requirement":requirement, "replacement_requirements":replacements, "remaining_requirements":remaining,
             "superseded_requirements":superseded, "answer_turns":answerTurns]
        }
    }
    struct ClarificationBinding: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        enum Parameter: Equatable, Sendable {
            case currency(Currency), priceBasis(PriceBasis), fees(Fees), date(DayRange)
            case quantity(Comparison?, Int64?, QuantityUnit?)
            case party(PartyComposition)
            fileprivate var isQuantity: Bool {
                switch self { case .quantity, .party: return true; default: return false }
            }
            fileprivate var identity: [String] {
                switch self { case .currency(let value): return ["currency", value.rawValue]
                case .priceBasis(let value): return ["priceBasis", value.rawValue]
                case .fees(let value): return ["fees", value.rawValue]
                case .date(let value): return Predicate.day(value).identity
                case .quantity(let comparison, let count, let unit):
                    return ["quantity", comparison?.rawValue ?? "unchanged", count.map(String.init) ?? "unchanged", unit?.rawValue ?? "unchanged"]
                case .party(let value): return Predicate.party(value).identity }
            }
        }
        let id: String
        let answerTurn: Int
        let parameter: Parameter
        let targetRequirementIDs: [String]
        let supersededDateTargetIDs: [String]
        let supersedingDateAnswerTurns: [Int]
        fileprivate init(input: ComputerUseBrowserGoalInput, turn: Int, parameter: Parameter, targets: [String],
                         supersededDateTargets: [String] = [], supersedingDateTurns: [Int] = []) {
            answerTurn = turn; self.parameter = parameter; targetRequirementIDs = targets
            supersededDateTargetIDs = supersededDateTargets; supersedingDateAnswerTurns = supersedingDateTurns
            id = ComputerUseTaskContract.digest([supersededDateTargets.isEmpty ? "browser-scalar-clarification-v2" : "browser-partly-superseded-date-answer-v1", input.digest,
                input.clarifications[turn - 1].digest, String(turn)] + parameter.identity + targets
                + supersededDateTargets + supersedingDateTurns.map(String.init))
        }
        var description: String { "BrowserScalarClarification(turn: \(answerTurn), targets: \(targetRequirementIDs.count))" }
        var debugDescription: String { description }
    }
    struct Entry: Equatable, Sendable {
        let requirementID: String
        let resolution: Resolution
    }
    enum Comparison: String, Sendable {
        case equal, below, atMost, above, atLeast
        fileprivate func accepts(_ actual: Int64, expected: Int64) -> Bool {
            switch self {
            case .equal: return actual == expected
            case .below: return actual < expected
            case .atMost: return actual <= expected
            case .above: return actual > expected
            case .atLeast: return actual >= expected
            }
        }
        fileprivate var relation: ComputerUseBrowserGoalProposal.Relation {
            switch self {
            case .equal: return .equal
            case .below: return .below
            case .atMost: return .atMost
            case .above: return .above
            case .atLeast: return .atLeast
            }
        }
    }
    enum QuantityScope: String, Sendable { case resultSet, ticketInventory, party }
    enum QuantityUnit: String, Sendable {
        case results, options, flights, concerts, movies, tickets, people, adults, children
        static let literalPattern = #"results?|options?|flights?|concerts?|movies?|tickets?|people|persons?|adults?|children|child"#
        static func literal(_ text: String) -> Self? {
            switch text.lowercased() {
            case "result", "results": return .results
            case "option", "options": return .options
            case "flight", "flights": return .flights
            case "concert", "concerts": return .concerts
            case "movie", "movies": return .movies
            case "ticket", "tickets": return .tickets
            case "person", "persons", "people": return .people
            case "adult", "adults": return .adults
            case "child", "children": return .children
            default: return nil
            }
        }
        var scope: QuantityScope {
            switch self {
            case .results, .options, .flights, .concerts, .movies: return .resultSet
            case .tickets: return .ticketInventory
            case .people, .adults, .children: return .party
            }
        }
        var isPartySize: Bool { scope == .party }
    }
    enum PriceBasis: String, Sendable { case unspecified, total, perPerson, perTicket }
    /// Exact requested categories. This does not define a provider's ages,
    /// ticket types or whether the categories are jointly bookable.
    struct PartyComposition: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let adults: Int64
        let children: Int64
        var total: Int64 { adults + children }
        init?(adults: Int64, children: Int64) {
            guard (0...999).contains(adults), (0...999).contains(children) else { return nil }
            self.adults = adults; self.children = children
        }
        func count(for unit: QuantityUnit) -> Int64? {
            switch unit { case .adults: return adults; case .children: return children; case .people: return total; default: return nil }
        }
        func compareCapacity(adults availableAdults: Int64?, children availableChildren: Int64?, people: Int64? = nil) -> Evaluation {
            guard [availableAdults, availableChildren, people].compactMap({ $0 }).allSatisfy({ $0 >= 0 }),
                  adults == 0 || availableAdults != nil, children == 0 || availableChildren != nil else { return .unverifiable }
            return (availableAdults ?? 0) >= adults && (availableChildren ?? 0) >= children && (people.map { $0 >= total } ?? true)
                ? .satisfied : .notSatisfied
        }
        var description: String { "BrowserPartyComposition" }
        var debugDescription: String { description }
    }
    enum Fees: String, Sendable { case unspecified, included, excluded }
    enum Currency: String, Sendable {
        case usd = "USD", eur = "EUR", gbp = "GBP", cad = "CAD", aud = "AUD", jpy = "JPY"
        // A symbol is retained as a symbol, not guessed to be an ISO currency.
        case dollarSymbol = "$", euroSymbol = "€", poundSymbol = "£", yenSymbol = "¥"
    }
    struct Amount: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        /// Exact fixed-point hundredths, not currency-specific payment units.
        let hundredths: Int64
        let currency: Currency
        init?(hundredths: Int64, currency: Currency) {
            guard (0...99_999_999_999).contains(hundredths) else { return nil }
            self.hundredths = hundredths; self.currency = currency
        }
        var description: String { "BrowserAmount" }
        var debugDescription: String { description }
    }
    struct CivilDay: Equatable, Comparable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let year: Int
        let month: Int
        let day: Int
        init?(year: Int, month: Int, day: Int) {
            guard (1...9_999).contains(year), (1...12).contains(month) else { return nil }
            let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            guard (1...days[month - 1]).contains(day) else { return nil }
            self.year = year; self.month = month; self.day = day
        }
        var iso8601: String {
            func padded(_ value: Int, to length: Int) -> String {
                let string = String(value)
                return String(repeating: "0", count: max(0, length - string.count)) + string
            }
            return padded(year, to: 4) + "-" + padded(month, to: 2) + "-" + padded(day, to: 2)
        }
        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
        }
        var description: String { "BrowserCivilDay" }
        var debugDescription: String { description }
    }
    struct DayRange: Equatable, Sendable {
        let lower: CivilDay?
        let lowerInclusive: Bool
        let upper: CivilDay?
        let upperInclusive: Bool
        fileprivate func accepts(_ day: CivilDay) -> Bool {
            if let lower, day < lower || (!lowerInclusive && day == lower) { return false }
            if let upper, upper < day || (!upperInclusive && day == upper) { return false }
            return true
        }
    }
    enum Predicate: Equatable, Sendable {
        case quantity(Comparison, Int64, QuantityUnit)
        case party(PartyComposition)
        case price(Comparison, Amount, PriceBasis, Fees)
        case day(DayRange)
        fileprivate var identity: [String] {
            switch self {
            case .quantity(let comparison, let count, let unit):
                return ["quantity", comparison.rawValue, String(count), unit.rawValue]
            case .party(let value): return ["party", String(value.adults), String(value.children)]
            case .price(let comparison, let amount, let basis, let fees):
                return ["price", comparison.rawValue, String(amount.hundredths), amount.currency.rawValue, basis.rawValue, fees.rawValue]
            case .day(let range):
                return ["day", range.lower?.iso8601 ?? "", String(range.lowerInclusive), range.upper?.iso8601 ?? "", String(range.upperInclusive)]
            }
        }
    }
    /// Typed scalar data only. A separate result compiler must prove the
    /// source, offer association, exactness and scope before supplying it.
    enum Observation: Equatable, Sendable {
        case quantity(Int64, QuantityUnit)
        case party(PartyComposition)
        case price(Amount, PriceBasis, Fees, isExact: Bool)
        case day(CivilDay)
    }
    /// A parsed quotation only. Neither exact offer pricing, applicability,
    /// inventory nor association is established by a literal's spelling.
    enum Literal: Equatable, Sendable {
        case quantity(Int64, QuantityUnit)
        case party(PartyComposition)
        case price(Amount, PriceBasis, Fees)
        case day(CivilDay)
    }
    enum Evaluation: Equatable, Sendable { case satisfied, notSatisfied, unverifiable }
    struct Condition: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let id: String
        let requirementID: String
        let predicate: Predicate
        let historicalRequirementIDs: [String]
        /// Current source rows jointly expressing one native scalar clause.
        let sourceRequirementIDs: [String]
        var hasHistoricalSource: Bool { !historicalRequirementIDs.isEmpty }
        fileprivate init(inputDigest: String, requirementID: String, predicate: Predicate, historicalRequirementIDs: [String] = [], sourceRequirementIDs: [String]? = nil) {
            self.requirementID = requirementID; self.predicate = predicate
            self.historicalRequirementIDs = historicalRequirementIDs
            self.sourceRequirementIDs = sourceRequirementIDs ?? [requirementID]
            let grouped = self.sourceRequirementIDs.count > 1
            id = ComputerUseTaskContract.digest([grouped ? "browser-grouped-scalar-condition-v1"
                : (historicalRequirementIDs.isEmpty ? "browser-scalar-condition-v1" : "browser-historical-scalar-condition-v1"),
                inputDigest, requirementID] + predicate.identity + historicalRequirementIDs + (grouped ? self.sourceRequirementIDs : []))
        }
        /// This is an arithmetic/civil-date comparison, never whole-result or
        /// task completion. Different units, currencies or incomplete prices
        /// cannot become passing observations through numeric comparison.
        /// Unspecified request basis/fees impose no scalar comparison here;
        /// this does not establish adequate scope for the whole request.
        func evaluate(_ observation: Observation) -> Evaluation {
            switch observation {
            case .quantity(let count, let unit): return compareLiteral(.quantity(count, unit))
            case .party(let value): return compareLiteral(.party(value))
            case .day(let day): return compareLiteral(.day(day))
            case .price(let amount, let basis, let fees, let isExact):
                guard isExact else { return .unverifiable }
                return compareLiteral(.price(amount, basis, fees))
            }
        }
        /// Arithmetic on a quotation for planning. A passing comparison must
        /// never be promoted to a verified observation or fulfilled condition.
        func compareLiteral(_ literal: Literal) -> Evaluation {
            let accepted: Bool
            switch (predicate, literal) {
            case (.quantity(let comparison, let expected, let unit), .quantity(let actual, let observedUnit)):
                guard actual >= 0, unit == observedUnit else { return .unverifiable }
                accepted = comparison.accepts(actual, expected: expected)
            case (.party(let expected), .party(let actual)): accepted = actual == expected
            case (.price(let comparison, let expected, let basis, let fees), .price(let actual, let actualBasis, let actualFees)):
                guard actual.currency == expected.currency,
                      basis == .unspecified || basis == actualBasis,
                      fees == .unspecified || fees == actualFees else { return .unverifiable }
                accepted = comparison.accepts(actual.hundredths, expected: expected.hundredths)
            case (.day(let range), .day(let actual)): accepted = range.accepts(actual)
            default: return .unverifiable
            }
            return accepted ? .satisfied : .notSatisfied
        }
        /// Arithmetic conditional on a separately proposed capacity meaning.
        /// This does not establish stock, date/type applicability, a current
        /// selection or a bookable offer. Never call it on selected counts,
        /// package sizes, policy limits or the number of result cards.
        func compareProposedCapacity(_ literal: Literal) -> Evaluation {
            if case .party(let expected) = predicate, case .party(let actual) = literal {
                return expected.compareCapacity(adults: actual.adults, children: actual.children)
            }
            if case .quantity(_, _, let unit) = predicate, case .party(let actual) = literal, let count = actual.count(for: unit) {
                return compareProposedCapacity(.quantity(count, unit))
            }
            guard case .quantity(let comparison, let expected, let unit) = predicate,
                  unit.scope != .resultSet, expected >= 0,
                  case .quantity(let actual, let observedUnit) = literal, actual >= 0, observedUnit == unit else {
                return .unverifiable
            }
            let minimum: Int64
            switch comparison {
            case .equal, .atLeast: minimum = expected
            case .above:
                let incremented = expected.addingReportingOverflow(1)
                guard !incremented.overflow else { return .unverifiable }
                minimum = incremented.partialValue
            case .atMost, .below: return .unverifiable // No exact/minimum selection can be inferred.
            }
            return actual >= minimum ? .satisfied : .notSatisfied
        }
        var description: String { "BrowserScalarCondition" }
        var debugDescription: String { description }
    }

    let proposal: ComputerUseBrowserGoalProposal
    let entries: [Entry]
    private let dateOrigins: [String: [String]]
    private let quantityOrigins: [String: [String]]
    private let partyOrigins: Set<String>
    func hasQuantityOrigin(_ requirement: ComputerUseBrowserGoalProposal.Requirement) -> Bool { quantityOrigins[requirement.id] != nil }
    private let rootDateGroups: [RootDateGroup]
    func hasDateOrigin(_ requirement: ComputerUseBrowserGoalProposal.Requirement) -> Bool { dateOrigins[requirement.id] != nil }
    /// Known or explicitly retained date duties cannot be emitted as an
    /// arbitrary substring. That could move a relative day or omit a bound.
    var datePayloadRequirementIDs: Set<String> {
        var ids = Set(dateOrigins.keys)
        ids.formUnion(proposal.requirements.filter { $0.role == .condition && $0.field == .date }.map(\.id))
        for (index, answer) in proposal.input.clarifications.enumerated() {
            if answer.topic.isDateTopic { ids.formUnion(proposal.requirements.filter { $0.sourceTurnIndex == index + 1 }.map(\.id)) }
            for historical in answer.priorRequirements where historical.role == .condition && historical.field == .date {
                guard let span = Self.scalarSpan(historical, input: proposal.input) else { continue }
                ids.formUnion(proposal.requirements.filter {
                    $0.sourceTurnIndex == span.turn && $0.sourceByteOffset < span.end
                        && span.start < $0.sourceByteOffset + $0.sourceByteCount
                }.map(\.id))
            }
        }
        return ids
    }
    var dateReplacementContexts: [ReplacementContext] {
        let indices = Dictionary(uniqueKeysWithValues: proposal.requirements.enumerated().map { ($0.element.id, $0.offset) })
        return entries.enumerated().compactMap { index, entry in
            switch entry.resolution {
            case .superseded(let record) where record.topic == .replaceDate:
                return .init(requirement: index, replacements: record.replacementRequirementIDs.compactMap { indices[$0] },
                    remaining: [], superseded: [], answerTurns: record.answerTurns)
            case .clarification(let binding) where !binding.supersededDateTargetIDs.isEmpty:
                return .init(requirement: index, replacements: [], remaining: binding.targetRequirementIDs.compactMap { indices[$0] },
                    superseded: binding.supersededDateTargetIDs.compactMap { indices[$0] }, answerTurns: binding.supersedingDateAnswerTurns)
            default: return nil
            }
        }
    }
    var hasUncompiledDateReplacements: Bool {
        let applied = Set(dateReplacementContexts.flatMap(\.answerTurns))
        return proposal.input.clarifications.enumerated().contains { $0.element.topic == .replaceDate && !applied.contains($0.offset + 1) }
    }
    var quantityReplacementContexts: [ReplacementContext] {
        let indices = Dictionary(uniqueKeysWithValues: proposal.requirements.enumerated().map { ($0.element.id, $0.offset) })
        return entries.enumerated().compactMap { index, entry in
            guard case .superseded(let record) = entry.resolution, record.topic.isQuantityReplacement else { return nil }
            return .init(requirement: index, replacements: record.replacementRequirementIDs.compactMap { indices[$0] },
                remaining: [], superseded: [], answerTurns: record.answerTurns)
        }
    }
    var hasUncompiledQuantityReplacements: Bool {
        let applied = Set(quantityReplacementContexts.flatMap(\.answerTurns))
        return proposal.input.clarifications.enumerated().contains { $0.element.topic.isQuantityReplacement && !applied.contains($0.offset + 1) }
    }
    var hasUncompiledRequirementReplacements: Bool { hasUncompiledDateReplacements || hasUncompiledQuantityReplacements }

    /// One complete origin. A scalar count and a structured party require
    /// different visible questions; neither can replace the other's meaning.
    func quantityReplacementTargets(for selected: [ComputerUseBrowserGoalProposal.Requirement],
                                    topic: ComputerUseBrowserClarificationTopic = .replaceQuantity) -> [ComputerUseBrowserGoalProposal.Requirement]? {
        guard !selected.isEmpty, topic.isQuantityReplacement else { return nil }
        let groups = selected.compactMap { quantityOrigins[$0.id] }
        guard groups.count == selected.count, Set(groups).count == 1, let targets = groups.first,
              (1...8).contains(targets.count) else { return nil }
        let selectedIDs = Set(selected.map(\.id))
        // An answer is one whole native clause even when the model splits it.
        for turn in Set(selected.map(\.sourceTurnIndex).filter { $0 > 0 }) {
            guard Self.coversQuantityAnswer(selected.filter { $0.sourceTurnIndex == turn }.map {
                $0.sourceByteOffset..<($0.sourceByteOffset + $0.sourceByteCount)
            }, turn: turn, input: proposal.input) else { return nil }
        }
        guard selectedIDs.isDisjoint(with: entries.compactMap {
            if case .superseded = $0.resolution { return $0.requirementID }; return nil
        }) else { return nil }
        let targetIDs = Set(targets)
        guard topic == .replaceParty ? targetIDs.isSubset(of: partyOrigins) : targetIDs.isDisjoint(with: partyOrigins) else { return nil }
        // Selecting one source fragment cannot discard another party component.
        guard selectedIDs.isDisjoint(with: targetIDs) || targetIDs.isSubset(of: selectedIDs) else { return nil }
        guard !entries.contains(where: {
            guard case .clarification(let binding) = $0.resolution, binding.parameter.isQuantity else { return false }
            return !targetIDs.isDisjoint(with: binding.targetRequirementIDs) && Set(binding.targetRequirementIDs) != targetIDs
        }) else { return nil }
        guard targets.allSatisfy({ id in
            guard let entry = entries.first(where: { $0.requirementID == id }) else { return false }
            switch entry.resolution {
            case .bound(let condition):
                switch condition.predicate { case .quantity: return topic == .replaceQuantity; case .party: return topic == .replaceParty; default: return false }
            case .unresolved(.ambiguousClarification), .unresolved(.contradictoryClarification): return true
            default: return false
            }
        }) else { return nil }
        let requirements = proposal.requirements.filter { targetIDs.contains($0.id) }
        return requirements.count == targets.count ? requirements : nil
    }
    private let partyGroups: [PartyGroup]
    func partySourceIdentity(for condition: Condition) -> String {
        let span = partyGroups.first(where: { $0.requirementIDs == condition.sourceRequirementIDs })?.span
            ?? proposal.requirements.first(where: { $0.id == condition.requirementID }).flatMap { Self.scalarSpan($0, input: proposal.input) }
        guard let span, proposal.input.userTurns.indices.contains(span.turn) else {
            return ComputerUseTaskContract.digest(["browser-party-source-fallback-v1", condition.id])
        }
        let bytes = Array(proposal.input.userTurns[span.turn].utf8)
        guard span.start >= 0, span.end >= span.start, span.end <= bytes.count else {
            return ComputerUseTaskContract.digest(["browser-party-source-fallback-v1", condition.id])
        }
        return ComputerUseTaskContract.digest(["browser-party-source-v1", proposal.input.rootDigest, String(span.turn),
            String(span.start), String(span.end), String(decoding: bytes[span.start..<span.end], as: UTF8.self)])
    }
    func partyRequirementIndices(for condition: Condition, unit: QuantityUnit) -> [Int] {
        guard let group = partyGroups.first(where: { $0.requirementIDs == condition.sourceRequirementIDs }),
              let span = group.components[unit] else {
            return proposal.requirements.indices.filter { condition.sourceRequirementIDs.contains(proposal.requirements[$0].id) }
        }
        return proposal.requirements.indices.filter {
            let row = proposal.requirements[$0]
            return group.requirementIDs.contains(row.id) && row.sourceByteOffset < span.end
                && span.start < row.sourceByteOffset + row.sourceByteCount
        }
    }
    /// Native source meaning is independent of whether a parameter answer
    /// was compatible or its target could be resolved. A failed date answer
    /// must not become an unrelated website instruction after relabeling.
    let nativeScalarSourceIDs: Set<String>
    var unresolvedRequirementIDs: [String] {
        entries.compactMap {
            switch $0.resolution { case .unresolved, .historicalDateAmbiguity, .historicalQuantityUnit: return $0.requirementID; default: return nil }
        }
    }
    /// Ask about one resolvable weekday occurrence at a time. Separate trip
    /// legs must not be grouped into an ambiguous native fallback question.
    var dateQuestionRequirementID: String? {
        guard let ids = dateQuestionRequirementIDs, ids.count == 1 else { return nil }
        return ids[0]
    }
    var dateQuestionRequirementIDs: [String]? {
        guard let requirement = proposal.requirements.first(where: needsDateDisambiguation) else { return nil }
        if let group = rootDateGroups.first(where: { $0.requirementIDs.contains(requirement.id) }) {
            let selected = proposal.requirements.filter { group.requirementIDs.contains($0.id) }
            guard selected.count <= 8, permitsDateQuestionScope(selected) else { return nil }
            return selected.map(\.id)
        }
        if requirement.sourceTurnIndex > 0,
           proposal.input.clarifications[requirement.sourceTurnIndex - 1].topic.isDateTopic {
            let selected = proposal.requirements.filter { $0.sourceTurnIndex == requirement.sourceTurnIndex }
            guard selected.count <= 8, permitsDateQuestionScope(selected) else { return nil }
            return selected.map(\.id)
        }
        return [requirement.id]
    }
    /// Eligibility for a scoped question is separate from needing an
    /// automatic fallback. A confirmed date must not trigger another question
    /// merely because its native origin survives a model relabeling.
    func permitsDateQuestion(_ requirement: ComputerUseBrowserGoalProposal.Requirement) -> Bool {
        if needsDateDisambiguation(requirement) { return true }
        let introduced = requirement.sourceTurnIndex > 0
            && proposal.input.clarifications.indices.contains(requirement.sourceTurnIndex - 1)
            && proposal.input.clarifications[requirement.sourceTurnIndex - 1].topic.isDateTopic
        guard let index = proposal.requirements.firstIndex(of: requirement),
              introduced || rootDateGroups.contains(where: { $0.requirementIDs.contains(requirement.id) }),
              nativeScalarSourceIDs.contains(requirement.id) else { return false }
        switch entries[index].resolution {
        case .bound(let condition): if case .day = condition.predicate { return true }
        case .clarification(let binding): if case .date = binding.parameter { return true }
        default: break
        }
        return false
    }

    func permitsDateQuestionScope(_ selected: [ComputerUseBrowserGoalProposal.Requirement]) -> Bool {
        let selectedIDs = Set(selected.map(\.id))
        guard rootDateGroups.allSatisfy({ group in
            selectedIDs.isDisjoint(with: group.requirementIDs) || Set(group.requirementIDs).isSubset(of: selectedIDs)
        }) else { return false }
        guard !selected.contains(where: { requirement in
            guard let index = proposal.requirements.firstIndex(of: requirement) else { return true }
            if case .superseded = entries[index].resolution { return true }
            return false
        }) else { return false }
        let missing = selected.contains { requirement in
            guard requirement.role == .outcome, let index = proposal.requirements.firstIndex(of: requirement) else { return false }
            switch entries[index].resolution {
            case .bound(let condition): if case .day = condition.predicate { return false }
            case .historicalDateAmbiguity: return false
            case .clarification(let binding): if case .date = binding.parameter { return false }
            default: break
            }
            return true
        }
        guard !missing || selected.count == 1 else { return false }
        let turns = Set(selected.map(\.sourceTurnIndex).filter { $0 > 0 })
        for turn in turns {
            guard proposal.input.clarifications.indices.contains(turn - 1) else { return false }
            let answer = proposal.input.clarifications[turn - 1]
            guard answer.topic.isDateTopic, Self.isNativeDateAnswer(answer.answer, input: proposal.input, turn: turn) else { continue }
            let ranges = selected.filter { $0.sourceTurnIndex == turn }.map {
                $0.sourceByteOffset..<($0.sourceByteOffset + $0.sourceByteCount)
            }
            guard Self.coversDateAnswer(ranges, turn: turn, input: proposal.input) else { return false }
        }
        return true
    }

    /// Replacement is a separate, visible user decision about one known date
    /// origin. An outcome, two trip legs or an arbitrary date-labelled fragment
    /// cannot acquire replacement authority from a model classification.
    func permitsDateReplacementScope(_ selected: [ComputerUseBrowserGoalProposal.Requirement]) -> Bool {
        dateReplacementTargets(for: selected) != nil
    }
    func dateReplacementTargets(for selected: [ComputerUseBrowserGoalProposal.Requirement]) -> [ComputerUseBrowserGoalProposal.Requirement]? {
        guard !selected.isEmpty, permitsDateQuestionScope(selected) else { return nil }
        let groups = selected.compactMap { dateOrigins[$0.id] }
        guard groups.count == selected.count, Set(groups).count == 1, let targets = groups.first, (1...8).contains(targets.count) else { return nil }
        let eligible = targets.allSatisfy { id in
            guard let entry = entries.first(where: { $0.requirementID == id }) else { return false }
            switch entry.resolution {
            case .bound(let condition): if case .day = condition.predicate { return true }; return false
            case .historicalDateAmbiguity, .unresolved(.ambiguousDate), .unresolved(.ambiguousClarification), .unresolved(.contradictoryClarification): return true
            default: return false
            }
        }
        let requirements = proposal.requirements.filter { targets.contains($0.id) }
        guard eligible, requirements.count == targets.count, permitsDateQuestionScope(requirements) else { return nil }
        return requirements
    }

    private func needsDateDisambiguation(_ requirement: ComputerUseBrowserGoalProposal.Requirement) -> Bool {
        guard let index = proposal.requirements.firstIndex(of: requirement),
              let ownSource = proposal.source(of: requirement) else { return false }
        let source: String
        if let group = rootDateGroups.first(where: { $0.requirementIDs.contains(requirement.id) }) {
            source = group.source
        } else if requirement.sourceTurnIndex > 0, nativeScalarSourceIDs.contains(requirement.id),
           proposal.input.clarifications[requirement.sourceTurnIndex - 1].topic.isDateTopic {
            source = proposal.input.userTurns[requirement.sourceTurnIndex]
        } else { source = ownSource }
        guard Self.unqualifiedWeekday(Self.conditionSource(source)) != nil else { return false }
        switch entries[index].resolution {
        case .historicalDateAmbiguity: return true
        case .unresolved(.ambiguousDate): return [.unspecified, .equal].contains(requirement.relation)
        default: return false
        }
    }
    var quantityQuestionRequirementID: String? { proposal.requirements.first(where: permitsQuantityQuestion)?.id }
    func permitsQuantityQuestion(_ requirement: ComputerUseBrowserGoalProposal.Requirement) -> Bool {
        guard let index = proposal.requirements.firstIndex(of: requirement),
              let source = proposal.source(of: requirement),
              let parts = Self.quantityParts(Self.conditionSource(source)), parts.unit == nil else { return false }
        switch entries[index].resolution {
        case .historicalQuantityUnit, .unresolved(.missingQuantityUnit): return true
        default: return false
        }
    }
    var description: String { "BrowserScalarRequirements(entries: \(entries.count), unresolved: \(unresolvedRequirementIDs.count))" }
    var debugDescription: String { description }

    init(proposal: ComputerUseBrowserGoalProposal) {
        self.proposal = proposal
        let baseEntries = proposal.requirements.map { requirement in
            guard proposal.disposition == .research else {
                return Entry(requirementID: requirement.id, resolution: .unresolved(.unresolvedDisposition))
            }
            return Self.baseEntry(requirement, input: proposal.input)
        }
        let grouping = Self.partyGrouping(proposal)
        partyGroups = grouping.groups
        let dateGroups = Self.historicalRootDateGroups(proposal)
        rootDateGroups = dateGroups
        let grouped = Self.applyingPartyGroups(grouping, proposal: proposal, entries: baseEntries)
        let dateGrouped = Self.applyingRootDateGroups(dateGroups, proposal: proposal, entries: grouped)
        let retained = Self.reconcilingRootDateGroups(dateGroups, entries: Self.reconcilingPartyGroups(grouping.groups,
            entries: Self.retainingHistoricalScalars(proposal,
                protectedHistory: Set(grouping.groups.flatMap(\.historicalIDs) + dateGroups.flatMap(\.historicalIDs)), entries: dateGrouped)))
        var nativeSources = Set(retained.compactMap { entry -> String? in
            switch entry.resolution {
            case .bound(let condition) where condition.hasHistoricalSource: return entry.requirementID
            case .historicalDateAmbiguity, .historicalQuantityUnit: return entry.requirementID
            default: return nil
            }
        })
        nativeSources.formUnion(grouping.groups.flatMap(\.requirementIDs))
        nativeSources.formUnion(grouping.ambiguousIDs)
        nativeSources.formUnion(dateGroups.flatMap(\.requirementIDs))
        if proposal.disposition == .research {
            for (index, answer) in proposal.input.clarifications.enumerated() {
                let literal: Bool
                switch answer.topic {
                case .date, .replaceDate: literal = Self.isNativeDateAnswer(answer.answer, input: proposal.input, turn: index + 1)
                case .quantity: literal = Self.quantityAnswer(answer.answer) != nil
                case .replaceQuantity: literal = Self.quantityReplacementAnswer(answer.answer) != nil
                case .replaceParty: literal = Self.partyLiteral(Self.conditionSource(answer.answer)) != nil
                default: literal = Self.parameter(answer.answer, topic: answer.topic) != nil
                }
                if literal {
                    nativeSources.formUnion(proposal.requirements.filter { $0.sourceTurnIndex == index + 1 }.map(\.id))
                }
            }
        }
        nativeScalarSourceIDs = nativeSources
        let dates = Self.applyingDateClarifications(proposal, rootGroups: dateGroups, to: Self.applyingPriceClarifications(proposal, to: retained))
        dateOrigins = dates.origins
        let quantities = Self.applyingQuantityClarifications(proposal, to: dates.entries)
        quantityOrigins = quantities.origins
        partyOrigins = quantities.partyOrigins
        entries = Self.reconcilingClarificationTargets(Self.reconcilingRootDateGroups(dateGroups,
            entries: Self.reconcilingPartyGroups(grouping.groups, entries: quantities.entries)))
    }

    private static func baseEntry(_ requirement: ComputerUseBrowserGoalProposal.Requirement, input: ComputerUseBrowserGoalInput) -> Entry {
        guard requirement.role == .condition, [.date, .quantity, .price].contains(requirement.field),
              let original = input.source(of: requirement) else {
            return Entry(requirementID: requirement.id, resolution: .unresolved(.notScalar))
        }
        let source = Self.conditionSource(original)
        if requirement.field == .quantity, let parts = Self.quantityParts(source), parts.unit == nil,
           requirement.relation != .unspecified && requirement.relation != parts.comparison.relation {
            return Entry(requirementID: requirement.id, resolution: .unresolved(.contradictoryProposal))
        }
        let parsed: Result<(Predicate, ComputerUseBrowserGoalProposal.Relation), BindingFailure>
        switch requirement.field {
        case .quantity: parsed = Self.quantity(source)
        case .price: parsed = Self.price(source)
        case .date: parsed = Self.date(source, input: input, turn: requirement.sourceTurnIndex)
        default: parsed = .failure(.init(reason: .notScalar))
        }
        switch parsed {
        case .success(let (predicate, relation)):
            guard requirement.relation == .unspecified || requirement.relation == relation else {
                return Entry(requirementID: requirement.id, resolution: .unresolved(.contradictoryProposal))
            }
            return Entry(requirementID: requirement.id, resolution: .bound(.init(inputDigest: input.digest,
                requirementID: requirement.id, predicate: predicate)))
        case .failure(let failure): return Entry(requirementID: requirement.id, resolution: .unresolved(failure.reason))
        }
    }

    /// An answer does not authorize dropping a parsed constraint or a known
    /// weekday ambiguity. Complete native date/party groups are reconciled
    /// separately; other merged/split meanings retain an open obligation.
    private static func retainingHistoricalScalars(_ proposal: ComputerUseBrowserGoalProposal, protectedHistory: Set<String>, entries original: [Entry]) -> [Entry] {
        guard proposal.disposition == .research else { return original }
        var entries = original
        for answer in proposal.input.clarifications {
            for historical in answer.priorRequirements {
                if protectedHistory.contains(historical.id) { continue }
                let previous = Self.baseEntry(historical, input: proposal.input).resolution
                let retainedWeekday: Bool
                if previous == .unresolved(.ambiguousDate), [.unspecified, .equal].contains(historical.relation),
                   let source = proposal.input.source(of: historical) {
                    retainedWeekday = Self.weekdayClause(Self.conditionSource(source))
                } else { retainedWeekday = false }
                let retainedQuantity = previous == .unresolved(.missingQuantityUnit)
                if !retainedWeekday && !retainedQuantity { guard case .bound = previous else { continue } }
                guard let oldSpan = Self.scalarSpan(historical, input: proposal.input) else { continue }
                let overlaps = proposal.requirements.indices.filter {
                    let current = proposal.requirements[$0]
                    return current.sourceTurnIndex == historical.sourceTurnIndex
                        && current.sourceByteOffset < oldSpan.end
                        && oldSpan.start < current.sourceByteOffset + current.sourceByteCount
                }
                let exact = overlaps.filter {
                    Self.scalarSpan(proposal.requirements[$0], input: proposal.input) == oldSpan
                }
                guard overlaps.count == 1, let target = exact.first else {
                    for index in overlaps { entries[index] = .init(requirementID: entries[index].requirementID, resolution: .unresolved(.historicalScalarScope)) }
                    continue
                }
                if [.unresolved(.historicalScalarScope), .unresolved(.ambiguousPartyScope)].contains(entries[target].resolution) { continue }
                let ids: [String]
                switch entries[target].resolution {
                case .bound(let current): ids = current.historicalRequirementIDs
                case .historicalDateAmbiguity(let retained), .historicalQuantityUnit(let retained): ids = retained
                default: ids = []
                }
                let retained = ids.contains(historical.id) ? ids : ids + [historical.id]
                if retainedWeekday {
                    entries[target] = .init(requirementID: entries[target].requirementID, resolution: .historicalDateAmbiguity(retained))
                    continue
                }
                if retainedQuantity {
                    entries[target] = .init(requirementID: entries[target].requirementID, resolution: .historicalQuantityUnit(retained))
                    continue
                }
                guard case .bound(let condition) = previous else { continue }
                entries[target] = .init(requirementID: entries[target].requirementID,
                    resolution: .bound(.init(inputDigest: proposal.input.digest, requirementID: entries[target].requirementID,
                        predicate: condition.predicate, historicalRequirementIDs: retained)))
            }
        }
        return entries
    }

    private struct ScalarSpan: Hashable, Sendable { let turn: Int; let start: Int; let end: Int }
    private struct RootDateGroup: Sendable {
        let span: ScalarSpan
        let source: String
        let range: DayRange?
        let requirementIDs: [String]
        let historicalIDs: [String]
    }
    /// Reassemble only a previously recognized whole date occurrence. The
    /// current model may divide its bytes, but cannot enlarge its meaning,
    /// omit its modifier, or make two separate occurrences one origin.
    private static func historicalRootDateGroups(_ proposal: ComputerUseBrowserGoalProposal) -> [RootDateGroup] {
        guard proposal.disposition == .research else { return [] }
        struct Origin {
            let span: ScalarSpan
            let source: String
            let range: DayRange?
            var ids: [String]
            var ambiguous = false
        }
        var origins: [Origin] = []
        for answer in proposal.input.clarifications {
            for historical in answer.priorRequirements where historical.sourceTurnIndex == 0 {
                guard let source = proposal.input.source(of: historical), let span = scalarSpan(historical, input: proposal.input) else { continue }
                let resolution = baseEntry(historical, input: proposal.input).resolution
                let range: DayRange?
                if case .bound(let condition) = resolution, case .day(let dayRange) = condition.predicate { range = dayRange }
                else if resolution == .unresolved(.ambiguousDate), [.unspecified, .equal].contains(historical.relation),
                        weekdayClause(conditionSource(source)) { range = nil }
                else { continue }
                if let index = origins.firstIndex(where: { $0.span.start <= span.start && span.end <= $0.span.end }) {
                    // A later date-labelled endpoint/weekday fragment is part
                    // of the earlier complete origin, not a new constraint.
                    if !origins[index].ids.contains(historical.id) { origins[index].ids.append(historical.id) }
                    continue
                }
                let overlap = origins.indices.filter { origins[$0].span.start < span.end && span.start < origins[$0].span.end }
                for index in overlap { origins[index].ambiguous = true }
                origins.append(.init(span: span, source: conditionSource(source), range: range,
                    ids: [historical.id], ambiguous: !overlap.isEmpty))
            }
        }
        return origins.compactMap { origin in
            guard !origin.ambiguous else { return nil }
            let rows = proposal.requirements.filter {
                $0.sourceTurnIndex == 0 && $0.sourceByteOffset < origin.span.end
                    && origin.span.start < $0.sourceByteOffset + $0.sourceByteCount
            }
            guard let first = rows.first else { return nil }
            var combined = "", cursor = first.sourceByteOffset
            for row in rows {
                guard row.sourceByteOffset == cursor, let part = proposal.source(of: row) else { return nil }
                combined += part; cursor += row.sourceByteCount
            }
            let core = conditionSource(combined)
            guard core == origin.source, let coreRange = combined.range(of: core, options: .literal),
                  first.sourceByteOffset + combined[..<coreRange.lowerBound].utf8.count == origin.span.start else { return nil }
            return .init(span: origin.span, source: core, range: origin.range, requirementIDs: rows.map(\.id), historicalIDs: origin.ids)
        }
    }
    private static func applyingRootDateGroups(_ groups: [RootDateGroup], proposal: ComputerUseBrowserGoalProposal, entries original: [Entry]) -> [Entry] {
        var entries = original
        for group in groups {
            for index in entries.indices where group.requirementIDs.contains(entries[index].requirementID) {
                let resolution: Resolution = group.range.map { range in
                    .bound(.init(inputDigest: proposal.input.digest, requirementID: entries[index].requirementID,
                        predicate: .day(range), historicalRequirementIDs: group.historicalIDs, sourceRequirementIDs: group.requirementIDs))
                } ?? .historicalDateAmbiguity(group.historicalIDs)
                entries[index] = .init(requirementID: entries[index].requirementID, resolution: resolution)
            }
        }
        return entries
    }
    private static func reconcilingRootDateGroups(_ groups: [RootDateGroup], entries original: [Entry]) -> [Entry] {
        var entries = original
        for group in groups {
            let indices = entries.indices.filter { group.requirementIDs.contains(entries[$0].requirementID) }
            let signatures = indices.compactMap { index -> [String]? in
                switch entries[index].resolution {
                case .bound(let condition):
                    guard case .day = condition.predicate, condition.sourceRequirementIDs == group.requirementIDs else { return nil }
                    return ["date"] + condition.predicate.identity
                case .historicalDateAmbiguity: return ["weekday"]
                case .superseded(let record): return ["superseded"] + record.answerTurns.map(String.init) + record.replacementRequirementIDs
                default: return nil
                }
            }
            if signatures.count == indices.count, Set(signatures).count == 1 { continue }
            let reasons = indices.compactMap { index -> UnresolvedReason? in
                if case .unresolved(let reason) = entries[index].resolution { return reason }; return nil
            }
            let reason: UnresolvedReason = reasons.contains(.historicalScalarScope) ? .historicalScalarScope : (reasons.first ?? .contradictoryClarification)
            for index in indices { entries[index] = .init(requirementID: entries[index].requirementID, resolution: .unresolved(reason)) }
        }
        return entries
    }
    private struct PartyGroup: Sendable {
        let span: ScalarSpan
        let party: PartyComposition
        let requirementIDs: [String]
        let historicalIDs: [String]
        let components: [QuantityUnit: ScalarSpan]
    }
    private struct PartyClause {
        let span: ScalarSpan
        let party: PartyComposition
        let ids: [String]
        let eligible: Bool
        let continued: Bool
        let components: [QuantityUnit: ScalarSpan]
    }
    private struct PartyGrouping { let groups: [PartyGroup]; let ambiguousIDs: Set<String> }

    /// Recognize the same exact source clause regardless of row boundaries.
    /// Candidate windows never cross turns or consume unrelated source text.
    private static func partyClauses(_ rows: [ComputerUseBrowserGoalProposal.Requirement], input: ComputerUseBrowserGoalInput) -> [PartyClause] {
        var clauses: [PartyClause] = []
        for start in rows.indices {
            var source = "", ids: [String] = [], eligible = true, hasQuantity = false
            let turn = rows[start].sourceTurnIndex, offset = rows[start].sourceByteOffset
            for end in start..<rows.count {
                let row = rows[end]
                guard row.sourceTurnIndex == turn, row.sourceByteOffset == offset + source.utf8.count,
                      let part = input.source(of: row), source.utf8.count + part.utf8.count <= 2048 else { break }
                source += part; ids.append(row.id)
                let boundary = ["", "and", ",", "&", ".", ";"].contains(part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                hasQuantity = hasQuantity || row.field == .quantity
                eligible = eligible && row.role == .condition && (boundary || [.quantity, .other].contains(row.field))
                    && [.unspecified, .equal].contains(row.relation)
                let core = conditionSource(source)
                guard let party = partyLiteral(core), let range = source.range(of: core, options: .literal),
                      let componentRanges = partyComponentRanges(core) else { continue }
                let coreOffset = offset + source[..<range.lowerBound].utf8.count
                let span = ScalarSpan(turn: turn, start: coreOffset, end: coreOffset + core.utf8.count)
                let bytes = Array(input.userTurns[turn].utf8)
                let before = String(decoding: bytes[..<span.start], as: UTF8.self)
                let after = String(decoding: bytes[span.end...], as: UTF8.self)
                let separator = #"(?:\s*,?\s+and\s+|\s*,\s*|\s*&\s*|\s+)"#
                let continued = before.range(of: Self.partyComponentPattern + separator + "$", options: [.regularExpression, .caseInsensitive]) != nil
                    || after.range(of: "^" + separator + Self.partyComponentPattern, options: [.regularExpression, .caseInsensitive]) != nil
                    || before.range(of: #"(?:\bat least|\bat most|\bmore than|\bfewer than|\bnot|\bexcept|\bexcluding|\bwithout)\s+$"#,
                        options: [.regularExpression, .caseInsensitive]) != nil
                let components = componentRanges.mapValues { ScalarSpan(turn: turn, start: coreOffset + $0.lowerBound, end: coreOffset + $0.upperBound) }
                clauses.append(.init(span: span, party: party, ids: ids, eligible: eligible && hasQuantity, continued: continued, components: components))
            }
        }
        return clauses
    }

    private static func partyGrouping(_ proposal: ComputerUseBrowserGoalProposal) -> PartyGrouping {
        guard proposal.disposition == .research else { return .init(groups: [], ambiguousIDs: []) }
        let current = partyClauses(proposal.requirements, input: proposal.input)
        let historical = proposal.input.clarifications.flatMap { partyClauses($0.priorRequirements, input: proposal.input) }
            .filter { $0.eligible && !$0.continued }
        let answerSpans = proposal.input.clarifications.enumerated().compactMap { index, turn -> ScalarSpan? in
            guard turn.topic == .quantity || turn.topic == .replaceParty, partyLiteral(conditionSource(turn.answer)) != nil else { return nil }
            return answerSpan(turn.answer, turn: index + 1)
        }
        var grouped: [ScalarSpan: [PartyClause]] = [:], ambiguous: Set<String> = []
        for clause in current {
            guard clause.eligible || historical.contains(where: { $0.span == clause.span && $0.party == clause.party })
                || answerSpans.contains(clause.span) else { continue }
            if clause.continued { ambiguous.formUnion(clause.ids); continue }
            grouped[clause.span, default: []].append(clause)
        }
        var groups: [PartyGroup] = []
        for span in grouped.keys.sorted(by: { ($0.turn, $0.start, $0.end) < ($1.turn, $1.start, $1.end) }) {
            guard let clauses = grouped[span], let first = clauses.first else { continue }
            let ids = Set(clauses.flatMap(\.ids))
            let currentIDs = proposal.requirements.filter { ids.contains($0.id) }.map(\.id)
            var history: [String] = []
            for old in historical where old.span == span && old.party == first.party {
                for id in old.ids where !history.contains(id) { history.append(id) }
            }
            groups.append(.init(span: span, party: first.party, requirementIDs: currentIDs, historicalIDs: history, components: first.components))
        }
        for first in groups.indices {
            for second in groups.indices where second > first {
                if !Set(groups[first].requirementIDs).isDisjoint(with: groups[second].requirementIDs) {
                    ambiguous.formUnion(groups[first].requirementIDs); ambiguous.formUnion(groups[second].requirementIDs)
                }
            }
        }
        return .init(groups: groups.filter { Set($0.requirementIDs).isDisjoint(with: ambiguous) }, ambiguousIDs: ambiguous)
    }

    private static func applyingPartyGroups(_ grouping: PartyGrouping, proposal: ComputerUseBrowserGoalProposal, entries original: [Entry]) -> [Entry] {
        var entries = original
        for group in grouping.groups {
            for index in entries.indices where group.requirementIDs.contains(entries[index].requirementID) {
                entries[index] = .init(requirementID: entries[index].requirementID, resolution: .bound(.init(inputDigest: proposal.input.digest,
                    requirementID: entries[index].requirementID, predicate: .party(group.party), historicalRequirementIDs: group.historicalIDs,
                    sourceRequirementIDs: group.requirementIDs)))
            }
        }
        for index in entries.indices where grouping.ambiguousIDs.contains(entries[index].requirementID) {
            entries[index] = .init(requirementID: entries[index].requirementID, resolution: .unresolved(.ambiguousPartyScope))
        }
        return entries
    }

    private static func reconcilingPartyGroups(_ groups: [PartyGroup], entries original: [Entry]) -> [Entry] {
        var entries = original
        for group in groups {
            let indices = entries.indices.filter { group.requirementIDs.contains(entries[$0].requirementID) }
            let bound = indices.allSatisfy {
                if case .bound(let condition) = entries[$0].resolution {
                    return condition.predicate == .party(group.party) && condition.sourceRequirementIDs == group.requirementIDs
                }
                return false
            }
            if bound { continue }
            let supersessions = indices.compactMap { index -> [String]? in
                guard case .superseded(let record) = entries[index].resolution, record.topic == .replaceParty else { return nil }
                return record.answerTurns.map(String.init) + ["replacements"] + record.replacementRequirementIDs
            }
            if supersessions.count == indices.count, Set(supersessions).count == 1 { continue }
            if let first = indices.first, case .clarification = entries[first].resolution,
               indices.allSatisfy({ entries[$0].resolution == entries[first].resolution }) { continue }
            let failures = indices.compactMap { index -> UnresolvedReason? in
                if case .unresolved(let reason) = entries[index].resolution { return reason }; return nil
            }
            let reason: UnresolvedReason = failures.contains(.historicalScalarScope) ? .historicalScalarScope : (failures.first ?? .contradictoryClarification)
            for index in indices { entries[index] = .init(requirementID: entries[index].requirementID, resolution: .unresolved(reason)) }
        }
        return entries
    }

    private static func scalarSpan(_ requirement: ComputerUseBrowserGoalProposal.Requirement, input: ComputerUseBrowserGoalInput) -> ScalarSpan? {
        guard let source = input.source(of: requirement) else { return nil }
        let clause = conditionSource(source)
        guard !clause.isEmpty, let range = source.range(of: clause, options: .literal) else { return nil }
        let start = requirement.sourceByteOffset + source[..<range.lowerBound].utf8.count
        return .init(turn: requirement.sourceTurnIndex, start: start, end: start + clause.utf8.count)
    }

    /// Resolve only whole, explicit parameter answers from authenticated
    /// clarification turns. The original amount and comparator stay fixed.
    /// Every answer retains a ledger entry tied to the exact target clauses.
    private static func applyingPriceClarifications(_ proposal: ComputerUseBrowserGoalProposal, to original: [Entry]) -> [Entry] {
        guard proposal.disposition == .research else { return original }
        var entries = original
        let priceIndices = original.indices.filter { index in
            if case .bound(let condition) = original[index].resolution, case .price = condition.predicate { return true }
            return false
        }
        var previousTargets: [Int: [Int]] = [:]
        for (index, answer) in proposal.input.clarifications.enumerated() {
            guard [.currency, .priceBasis, .fees].contains(answer.topic) else { continue }
            let turn = index + 1
            let answerIndices = proposal.requirements.indices.filter { proposal.requirements[$0].sourceTurnIndex == turn }
            var targets: Set<Int> = [], possibleTargets: Set<Int> = [], invalidScope = false
            for scope in answer.scope {
                guard scope.turn < turn else { invalidScope = true; continue }
                let matching = priceIndices.filter { Self.contains(scope, requirement: proposal.requirements[$0], proposal: proposal) }
                possibleTargets.formUnion(matching)
                if matching.count == 1 { targets.insert(matching[0]) }
                else if matching.isEmpty, scope.turn > 0, let previous = previousTargets[scope.turn],
                        let expected = Self.parameter(proposal.input.userTurns[scope.turn], topic: proposal.input.clarifications[scope.turn - 1].topic),
                        Self.parameter(scope.source, topic: proposal.input.clarifications[scope.turn - 1].topic) == expected {
                    // A follow-up can refer to a previously resolved answer,
                    // including a source span expressing that same parameter.
                    // The complete earlier answer must already be bound.
                    targets.formUnion(previous); possibleTargets.formUnion(previous)
                } else { invalidScope = true }
            }
            func unresolved(_ reason: UnresolvedReason) {
                for row in possibleTargets.union(targets).union(answerIndices) {
                    entries[row] = .init(requirementID: original[row].requirementID, resolution: .unresolved(reason))
                }
            }
            guard !invalidScope, !targets.isEmpty else { unresolved(.clarificationScope); continue }
            guard let parameter = Self.parameter(answer.answer, topic: answer.topic) else { unresolved(.ambiguousClarification); continue }
            let ordered = targets.sorted()
            var replacements: [(Int, Condition)] = []
            for target in ordered {
                guard case .bound(let condition) = entries[target].resolution,
                      let predicate = Self.applying(parameter, to: condition.predicate) else { continue }
                replacements.append((target, .init(inputDigest: proposal.input.digest,
                    requirementID: condition.requirementID, predicate: predicate, historicalRequirementIDs: condition.historicalRequirementIDs)))
            }
            // A multi-clause answer applies atomically: a conflict in one
            // clause cannot silently change the others or overwrite an
            // unresolved earlier answer with its original default values.
            guard replacements.count == ordered.count else { unresolved(.contradictoryClarification); continue }
            for (target, condition) in replacements {
                entries[target] = .init(requirementID: condition.requirementID, resolution: .bound(condition))
            }
            let binding = ClarificationBinding(input: proposal.input, turn: turn, parameter: parameter,
                targets: ordered.map { original[$0].requirementID })
            for row in answerIndices { entries[row] = .init(requirementID: original[row].requirementID, resolution: .clarification(binding)) }
            previousTargets[turn] = ordered
        }
        return entries
    }

    /// Ordinary date answers resolve a selected weekday occurrence or confirm
    /// a concrete date/range. Only a separate explicit replacement answer may
    /// change that origin; broad scopes and partial units remain unresolved.
    private static func applyingDateClarifications(_ proposal: ComputerUseBrowserGoalProposal, rootGroups: [RootDateGroup], to original: [Entry]) -> (entries: [Entry], origins: [String: [String]]) {
        guard proposal.disposition == .research else { return (original, [:]) }
        var entries = original
        let answerTurns = Set(proposal.input.clarifications.enumerated().compactMap { $0.element.topic.isDateTopic ? $0.offset + 1 : nil })
        let dateIndices = proposal.requirements.indices.filter {
            let requirement = proposal.requirements[$0]
            guard !answerTurns.contains(requirement.sourceTurnIndex) else { return false }
            if case .bound(let condition) = original[$0].resolution, case .day = condition.predicate { return true }
            if case .historicalDateAmbiguity = original[$0].resolution { return true }
            return requirement.role == .condition && requirement.field == .date
        }
        var previousTargets: [Int: [Int]] = [:]
        var originTurns: [Int: Int] = [:]
        var originGroups: [Int: [Int]] = [:]
        for index in dateIndices {
            let known: Bool
            switch original[index].resolution {
            case .bound(let condition): if case .day = condition.predicate { known = true } else { known = false }
            case .historicalDateAmbiguity: known = true
            case .unresolved(.ambiguousDate):
                let requirement = proposal.requirements[index]
                known = [.unspecified, .equal].contains(requirement.relation)
                    && proposal.source(of: requirement).map { Self.weekdayClause(Self.conditionSource($0)) } == true
            default: known = false
            }
            if known {
                if let group = rootGroups.first(where: { $0.requirementIDs.contains(original[index].requirementID) }) {
                    originGroups[index] = original.indices.filter { group.requirementIDs.contains(original[$0].requirementID) }
                } else { originGroups[index] = [index] }
            }
        }
        for (index, answer) in proposal.input.clarifications.enumerated() where answer.topic.isDateTopic {
            let turn = index + 1
            let answerIndices = proposal.requirements.indices.filter { proposal.requirements[$0].sourceTurnIndex == turn }
            var targets: Set<Int> = [], possibleTargets: Set<Int> = [], invalidScope = false
            var onlyMissingDetailScopes = true, hasMissingDetailScope = false
            for scope in answer.scope {
                guard scope.turn < turn else { invalidScope = true; continue }
                var matching = dateIndices.filter { Self.contains(scope, requirement: proposal.requirements[$0], proposal: proposal) }
                // A live question may predate either splitting or rejoining
                // these rows. Reconcile its complete byte coverage, including
                // internal separators, against the same historical origin.
                for group in rootGroups {
                    guard scope.turn == group.span.turn, scope.sourceByteOffset < group.span.end,
                          group.span.start < scope.sourceByteOffset + scope.source.utf8.count,
                          Self.coversScalarSpan(answer.scope.filter { $0.turn == group.span.turn }.map {
                              $0.sourceByteOffset..<($0.sourceByteOffset + $0.source.utf8.count)
                          }, span: group.span, input: proposal.input) else { continue }
                    matching = Array(Set(matching).union(original.indices.filter { group.requirementIDs.contains(original[$0].requirementID) })).sorted()
                }
                possibleTargets.formUnion(matching)
                let matchingGroups = matching.compactMap { originGroups[$0] }
                let wholeGroup = matchingGroups.count == matching.count && Set(matchingGroups).count == 1 && matchingGroups.first == matching
                if matching.count == 1 || wholeGroup { targets.formUnion(matching); onlyMissingDetailScopes = false }
                else if matching.isEmpty, scope.turn > 0, let previous = previousTargets[scope.turn],
                        Self.coversDateAnswer(answer.scope.filter { $0.turn == scope.turn }.map {
                            $0.sourceByteOffset..<($0.sourceByteOffset + $0.source.utf8.count)
                        }, turn: scope.turn, input: proposal.input) {
                    targets.formUnion(previous); possibleTargets.formUnion(previous); onlyMissingDetailScopes = false
                } else if matching.isEmpty,
                          answer.priorRequirements.first(where: { $0.id == scope.requirementID })?.role == .outcome {
                    // A genuinely missing date remains a new answer condition,
                    // subject to the existing complete-goal semantic review.
                    // It is not a replacement for a prior date clause.
                    hasMissingDetailScope = true
                } else { invalidScope = true }
            }
            func unresolved(_ reason: UnresolvedReason) {
                for row in possibleTargets.union(targets).union(answerIndices) {
                    entries[row] = .init(requirementID: original[row].requirementID, resolution: .unresolved(reason))
                }
            }
            guard !invalidScope, !(hasMissingDetailScope && !targets.isEmpty) else { unresolved(.clarificationScope); continue }
            guard targets.allSatisfy({ originGroups[$0].map { Set($0).isSubset(of: targets) } ?? true }) else {
                unresolved(.clarificationScope); continue
            }
            let range = Self.answeredDate(answer.answer, input: proposal.input, turn: turn)
            guard Self.isNativeDateAnswer(answer.answer, input: proposal.input, turn: turn) else { unresolved(.ambiguousClarification); continue }
            let ordered = targets.sorted()
            // Keep the selected origin even after a literal conflict. An
            // explicit replacement can then address that same unit; malformed
            // scopes and compound answers do not gain this lineage.
            if !ordered.isEmpty, ordered.allSatisfy({ originGroups[$0] != nil }) { previousTargets[turn] = ordered }
            if answer.topic == .replaceDate {
                let groups = ordered.compactMap { originGroups[$0] }
                guard groups.count == ordered.count, Set(groups).count == 1, let group = groups.first,
                      group == ordered, !hasMissingDetailScope, !answerIndices.isEmpty,
                      !ordered.contains(where: { if case .superseded = entries[$0].resolution { return true }; return false }),
                      Self.coversDateAnswer(answerIndices.map {
                    let row = proposal.requirements[$0]; return row.sourceByteOffset..<(row.sourceByteOffset + row.sourceByteCount)
                }, turn: turn, input: proposal.input) else { unresolved(.clarificationScope); continue }
                let targetIDs = Set(ordered.map { original[$0].requirementID })
                let replacements = answerIndices.map { original[$0].requirementID }
                let priorTurns = Set(previousTargets.filter { $0.key < turn && Set($0.value) == Set(ordered) }.map(\.key))
                for row in entries.indices where proposal.requirements[row].sourceTurnIndex < turn {
                    // One earlier confirmation may have covered two separate
                    // dates. Replacing one must retain its application to the
                    // other. Superseded references form a retained graph;
                    // later replacements do not flatten away another branch.
                    if case .clarification(let binding) = entries[row].resolution, case .date = binding.parameter,
                       !targetIDs.isDisjoint(with: binding.targetRequirementIDs) {
                        let removed = binding.targetRequirementIDs.filter(targetIDs.contains)
                        let remaining = binding.targetRequirementIDs.filter { !targetIDs.contains($0) }
                        let superseded = binding.supersededDateTargetIDs + removed
                        let turns = binding.supersedingDateAnswerTurns + [turn]
                        let resolution: Resolution
                        if remaining.isEmpty {
                            resolution = .superseded(.init(input: proposal.input, requirementID: original[row].requirementID,
                                answerTurns: turns, replacements: superseded))
                        } else {
                            resolution = .clarification(.init(input: proposal.input, turn: binding.answerTurn, parameter: binding.parameter,
                                targets: remaining, supersededDateTargets: superseded, supersedingDateTurns: turns))
                        }
                        entries[row] = .init(requirementID: original[row].requirementID, resolution: resolution)
                        continue
                    }
                    if case .superseded = entries[row].resolution { continue }
                    guard targets.contains(row) || priorTurns.contains(proposal.requirements[row].sourceTurnIndex) else { continue }
                    entries[row] = .init(requirementID: original[row].requirementID,
                        resolution: .superseded(.init(input: proposal.input, requirementID: original[row].requirementID,
                            answerTurns: [turn], replacements: replacements)))
                }
                for row in answerIndices {
                    let resolution: Resolution = range.map { value -> Resolution in .bound(.init(inputDigest: proposal.input.digest,
                        requirementID: original[row].requirementID, predicate: .day(value), sourceRequirementIDs: replacements)) }
                        ?? .historicalDateAmbiguity([])
                    entries[row] = .init(requirementID: original[row].requirementID, resolution: resolution)
                    originTurns[row] = turn; originGroups[row] = answerIndices
                }
                previousTargets[turn] = answerIndices
                continue
            }
            if targets.isEmpty && onlyMissingDetailScopes {
                // The authenticated, whole date answer supplies its own
                // origin. It must not become a property of a broad outcome,
                // or depend on how a later model labels/partitions its bytes.
                let primaries = answerIndices
                guard hasMissingDetailScope, answer.scope.count == 1, !primaries.isEmpty,
                      Self.coversDateAnswer(primaries.map {
                    let row = proposal.requirements[$0]
                    return row.sourceByteOffset..<(row.sourceByteOffset + row.sourceByteCount)
                }, turn: turn, input: proposal.input) else { unresolved(.clarificationScope); continue }
                let ids = Array(Set(primaries.flatMap { row -> [String] in
                    switch original[row].resolution {
                    case .bound(let condition): return condition.historicalRequirementIDs
                    case .historicalDateAmbiguity(let ids): return ids
                    default: return []
                    }
                })).sorted()
                let sourceIDs = primaries.map { original[$0].requirementID }
                for row in primaries {
                    let resolution: Resolution
                    if let range { resolution = .bound(.init(inputDigest: proposal.input.digest, requirementID: original[row].requirementID,
                        predicate: .day(range), historicalRequirementIDs: ids, sourceRequirementIDs: sourceIDs)) }
                    else { resolution = .historicalDateAmbiguity(ids) }
                    entries[row] = .init(requirementID: original[row].requirementID, resolution: resolution)
                    originTurns[row] = turn; originGroups[row] = primaries
                }
                previousTargets[turn] = primaries
                continue
            }
            guard !targets.isEmpty else { unresolved(.clarificationScope); continue }
            guard let range else { unresolved(.ambiguousClarification); continue }
            let compatible = ordered.allSatisfy { target in
                let requirement = proposal.requirements[target]
                guard let ownSource = proposal.source(of: requirement) else { return false }
                let rootGroup = rootGroups.first(where: { $0.requirementIDs.contains(requirement.id) })
                let source = originTurns[target].map { proposal.input.userTurns[$0] } ?? rootGroup?.source ?? ownSource
                // Repartitioning a known date clause must not remove its
                // modifier/comparator and then resolve the shortened clause.
                for scope in answer.scope where originTurns[target] == nil && rootGroup == nil && Self.contains(scope, requirement: requirement, proposal: proposal) {
                    if let prior = answer.priorRequirements.first(where: { $0.id == scope.requirementID }),
                       prior.field == .date, prior.role == .condition,
                       Self.conditionSource(scope.source) != Self.conditionSource(source) { return false }
                }
                switch entries[target].resolution {
                case .bound(let condition): return condition.predicate == .day(range)
                case .unresolved(.ambiguousDate), .historicalDateAmbiguity:
                    if case .unresolved = entries[target].resolution,
                       ![.unspecified, .equal].contains(requirement.relation) { return false }
                    guard let weekday = Self.unqualifiedWeekday(Self.conditionSource(source)),
                          let day = range.lower, range.upper == day, range.lowerInclusive, range.upperInclusive else { return false }
                    return Self.weekday(of: day) == weekday
                default: return false
                }
            }
            guard compatible else { unresolved(.contradictoryClarification); continue }
            for target in ordered {
                let historicalIDs: [String]
                let sourceIDs = originGroups[target]?.map { original[$0].requirementID } ?? [original[target].requirementID]
                switch entries[target].resolution {
                case .bound(let condition): historicalIDs = condition.historicalRequirementIDs
                case .historicalDateAmbiguity(let ids): historicalIDs = ids
                default: historicalIDs = []
                }
                entries[target] = .init(requirementID: original[target].requirementID,
                    resolution: .bound(.init(inputDigest: proposal.input.digest, requirementID: original[target].requirementID,
                        predicate: .day(range), historicalRequirementIDs: historicalIDs, sourceRequirementIDs: sourceIDs)))
            }
            let binding = ClarificationBinding(input: proposal.input, turn: turn, parameter: .date(range),
                targets: ordered.map { original[$0].requirementID })
            for row in answerIndices { entries[row] = .init(requirementID: original[row].requirementID, resolution: .clarification(binding)) }
            previousTargets[turn] = ordered
        }
        var origins = Dictionary(uniqueKeysWithValues: originGroups.map { index, group in
            (original[index].requirementID, group.map { original[$0].requirementID })
        })
        for (turn, targets) in previousTargets where !targets.isEmpty && targets.allSatisfy({ originGroups[$0] != nil }) {
            for row in proposal.requirements.indices where proposal.requirements[row].sourceTurnIndex == turn {
                origins[original[row].requirementID] = targets.map { original[$0].requirementID }
            }
        }
        return (entries, origins)
    }

    /// A scoped quantity answer fills missing units, confirms a known count,
    /// or refines an all-people party to adults/children. It cannot replace a
    /// different count/comparator or cross inventory, party and result scopes.
    private static func applyingQuantityClarifications(_ proposal: ComputerUseBrowserGoalProposal, to original: [Entry])
        -> (entries: [Entry], origins: [String: [String]], partyOrigins: Set<String>) {
        guard proposal.disposition == .research else { return (original, [:], []) }
        var entries = original
        let answerTurns = Set(proposal.input.clarifications.enumerated().compactMap { $0.element.topic.isQuantityTopic ? $0.offset + 1 : nil })
        var quantityIndices = proposal.requirements.indices.filter {
            let requirement = proposal.requirements[$0]
            guard !answerTurns.contains(requirement.sourceTurnIndex) else { return false }
            switch original[$0].resolution {
            case .bound(let condition):
                switch condition.predicate { case .quantity, .party: return true; default: break }
            case .historicalQuantityUnit, .unresolved(.missingQuantityUnit): return true
            default: break
            }
            return requirement.role == .condition && requirement.field == .quantity
        }
        var previousTargets: [Int: [Int]] = [:]
        var originGroups: [Int: [Int]] = [:], originUnits: [Int: QuantityUnit] = [:]
        var partyOriginRows: Set<Int> = []
        for row in quantityIndices {
            guard case .bound(let condition) = original[row].resolution else { continue }
            switch condition.predicate {
            case .quantity(_, _, let unit) where condition.sourceRequirementIDs == [original[row].requirementID]:
                originGroups[row] = [row]; originUnits[row] = unit
            case .party:
                let group = quantityIndices.filter { condition.sourceRequirementIDs.contains(original[$0].requirementID) }
                guard group.count == condition.sourceRequirementIDs.count else { continue }
                originGroups[row] = group; partyOriginRows.insert(row)
            default: break
            }
        }
        func history(_ resolution: Resolution) -> [String] {
            switch resolution {
            case .bound(let condition): return condition.historicalRequirementIDs
            case .historicalQuantityUnit(let ids): return ids
            default: return []
            }
        }
        for (index, answer) in proposal.input.clarifications.enumerated() where answer.topic.isQuantityTopic {
            let turn = index + 1
            let answerIndices = proposal.requirements.indices.filter { proposal.requirements[$0].sourceTurnIndex == turn }
            var targets: Set<Int> = [], possibleTargets: Set<Int> = [], invalidScope = false, missingDetail = false
            for scope in answer.scope {
                guard scope.turn < turn else { invalidScope = true; continue }
                let matching = quantityIndices.filter {
                    let row = proposal.requirements[$0]
                    if Self.contains(scope, requirement: row, proposal: proposal) { return true }
                    guard case .bound(let condition) = original[$0].resolution, case .party = condition.predicate else { return false }
                    return row.sourceTurnIndex == scope.turn && row.sourceByteOffset < scope.sourceByteOffset + scope.source.utf8.count
                        && scope.sourceByteOffset < row.sourceByteOffset + row.sourceByteCount
                }
                let matchingGroups = Set(matching.map { index -> [String] in
                    if let group = originGroups[index] { return group.map { original[$0].requirementID } }
                    if case .bound(let condition) = original[index].resolution { return condition.sourceRequirementIDs }
                    return [original[index].requirementID]
                })
                let expandedIDs = Set(matchingGroups.flatMap { $0 })
                let expanded = quantityIndices.filter { expandedIDs.contains(original[$0].requirementID) }
                possibleTargets.formUnion(expanded)
                if matchingGroups.count == 1 { targets.formUnion(expanded) }
                else if matching.isEmpty, scope.turn > 0, let previous = previousTargets[scope.turn],
                        (Self.quantityScope(scope.source, within: proposal.input.userTurns[scope.turn])
                            || Self.coversQuantityAnswer(answer.scope.filter { $0.turn == scope.turn }.map {
                                $0.sourceByteOffset..<($0.sourceByteOffset + $0.source.utf8.count)
                            }, turn: scope.turn, input: proposal.input)) {
                    targets.formUnion(previous); possibleTargets.formUnion(previous)
                } else if matching.isEmpty,
                          answer.priorRequirements.first(where: { $0.id == scope.requirementID })?.role == .outcome {
                    missingDetail = true
                } else { invalidScope = true }
            }
            func unresolved(_ reason: UnresolvedReason) {
                for row in possibleTargets.union(targets).union(answerIndices) {
                    entries[row] = .init(requirementID: original[row].requirementID, resolution: .unresolved(reason))
                }
            }
            guard !invalidScope, !(missingDetail && !targets.isEmpty) else { unresolved(.clarificationScope); continue }
            if answer.topic.isQuantityReplacement {
                let ordered = targets.sorted(), groups = ordered.compactMap { originGroups[$0] }
                let sourceRanges = answer.scope.map { $0.sourceByteOffset..<($0.sourceByteOffset + $0.source.utf8.count) }
                guard !missingDetail, let first = ordered.first, let last = ordered.last, groups.count == ordered.count,
                      Set(groups).count == 1, groups.first == ordered,
                      !answerIndices.isEmpty, ordered.allSatisfy({ row in
                          if case .superseded = entries[row].resolution { return false }
                          return proposal.requirements[row].sourceTurnIndex == proposal.requirements[first].sourceTurnIndex
                      }),
                      answer.scope.allSatisfy({ $0.turn == proposal.requirements[first].sourceTurnIndex }),
                      Self.coversScalarSpan(sourceRanges,
                          span: .init(turn: proposal.requirements[first].sourceTurnIndex,
                              start: proposal.requirements[first].sourceByteOffset,
                              end: proposal.requirements[last].sourceByteOffset + proposal.requirements[last].sourceByteCount),
                          input: proposal.input),
                      Self.coversQuantityAnswer(answerIndices.map {
                          let row = proposal.requirements[$0]; return row.sourceByteOffset..<(row.sourceByteOffset + row.sourceByteCount)
                      }, turn: turn, input: proposal.input) else { unresolved(.clarificationScope); continue }
                let predicate: Predicate
                if answer.topic == .replaceParty {
                    guard let party = Self.partyLiteral(Self.conditionSource(answer.answer)),
                          ordered.allSatisfy(partyOriginRows.contains) else { unresolved(.contradictoryClarification); continue }
                    predicate = .party(party)
                } else {
                    guard let parts = Self.quantityReplacementAnswer(answer.answer), let unit = parts.unit,
                          ordered.allSatisfy({ originUnits[$0] == unit && !partyOriginRows.contains($0) }) else { unresolved(.contradictoryClarification); continue }
                    predicate = .quantity(parts.comparison, parts.count, unit)
                }
                let targetIDs = Set(ordered.map { original[$0].requirementID })
                // A shared confirmation cannot be discarded with just one of
                // its origins. Admission also withholds this unsupported case.
                guard !entries.contains(where: {
                    guard case .clarification(let binding) = $0.resolution, binding.parameter.isQuantity else { return false }
                    return !targetIDs.isDisjoint(with: binding.targetRequirementIDs) && Set(binding.targetRequirementIDs) != targetIDs
                }) else { unresolved(.clarificationScope); continue }
                let replacementIDs = answerIndices.map { original[$0].requirementID }
                let priorTurns = Set(previousTargets.filter { $0.key < turn && $0.value == ordered }.map(\.key))
                for row in entries.indices where proposal.requirements[row].sourceTurnIndex < turn {
                    if case .superseded = entries[row].resolution { continue }
                    guard targets.contains(row) || priorTurns.contains(proposal.requirements[row].sourceTurnIndex) else { continue }
                    entries[row] = .init(requirementID: original[row].requirementID,
                        resolution: .superseded(.init(input: proposal.input, requirementID: original[row].requirementID,
                            answerTurns: [turn], replacements: replacementIDs, topic: answer.topic)))
                }
                for row in answerIndices {
                    entries[row] = .init(requirementID: original[row].requirementID,
                        resolution: .bound(.init(inputDigest: proposal.input.digest, requirementID: original[row].requirementID,
                            predicate: predicate, sourceRequirementIDs: replacementIDs)))
                    originGroups[row] = answerIndices
                    if case .quantity(_, _, let unit) = predicate { originUnits[row] = unit }
                    else { partyOriginRows.insert(row) }
                }
                quantityIndices.append(contentsOf: answerIndices)
                previousTargets[turn] = answerIndices
                continue
            }
            guard let parameter = Self.quantityAnswer(answer.answer) else {
                unresolved(.ambiguousClarification); continue
            }
            let knownTargets = targets.sorted()
            let compatibleOrigin: Bool
            switch parameter {
            case .quantity(_, _, let statedUnit):
                compatibleOrigin = knownTargets.allSatisfy { row in
                    if partyOriginRows.contains(row) { return statedUnit.map { [.people, .adults, .children].contains($0) } ?? false }
                    return originGroups[row] != nil && (statedUnit == nil || originUnits[row] == statedUnit)
                }
            case .party: compatibleOrigin = knownTargets.allSatisfy(partyOriginRows.contains)
            default: compatibleOrigin = false
            }
            if !knownTargets.isEmpty, compatibleOrigin {
                // Retain the origin of a literal conflict so an explicit
                // replacement question can resolve it without losing history.
                previousTargets[turn] = knownTargets
            }
            if targets.isEmpty && missingDetail {
                // The entire answer is a new quantity clause. Do not attach
                // its predicate to the earlier, broader outcome requirement.
                guard let span = Self.answerSpan(answer.answer, turn: turn) else { unresolved(.clarificationScope); continue }
                let matches = answerIndices.filter { Self.scalarSpan(proposal.requirements[$0], input: proposal.input) == span }
                let groupedMatches = answerIndices.filter {
                    guard case .bound(let condition) = entries[$0].resolution, case .party = condition.predicate,
                          condition.sourceRequirementIDs.count > 1 else { return false }
                    return Set(condition.sourceRequirementIDs).isSubset(of: Set(answerIndices.map { entries[$0].requirementID }))
                }
                guard let primary = matches.count == 1 ? matches.first : groupedMatches.first else { unresolved(.clarificationScope); continue }
                let primaries: [Int]
                if case .bound(let condition) = entries[primary].resolution, condition.sourceRequirementIDs.count > 1 {
                    primaries = answerIndices.filter { condition.sourceRequirementIDs.contains(entries[$0].requirementID) }
                } else { primaries = [primary] }
                let ids = history(entries[primary].resolution)
                let resolution: Resolution
                let predicate: Predicate?
                switch parameter {
                case .party(let party): predicate = .party(party)
                case .quantity(let comparison, let count?, let unit): predicate = unit.map { .quantity(comparison ?? .equal, count, $0) }
                default: unresolved(.clarificationScope); continue
                }
                if let predicate {
                    resolution = .bound(.init(inputDigest: proposal.input.digest, requirementID: entries[primary].requirementID,
                        predicate: predicate, historicalRequirementIDs: ids))
                } else { resolution = ids.isEmpty ? .unresolved(.missingQuantityUnit) : .historicalQuantityUnit(ids) }
                let sourceIDs = primaries.map { entries[$0].requirementID }
                for row in primaries {
                    let value: Resolution
                    if case .bound(let condition) = resolution {
                        value = .bound(.init(inputDigest: proposal.input.digest, requirementID: entries[row].requirementID,
                            predicate: condition.predicate, historicalRequirementIDs: ids, sourceRequirementIDs: sourceIDs))
                    } else { value = resolution }
                    entries[row] = .init(requirementID: entries[row].requirementID, resolution: value)
                    if case .bound(let condition) = value {
                        if case .quantity(_, _, let unit) = condition.predicate {
                            originGroups[row] = primaries; originUnits[row] = unit
                        } else if case .party = condition.predicate {
                            originGroups[row] = primaries; partyOriginRows.insert(row)
                        }
                    }
                }
                let binding = ClarificationBinding(input: proposal.input, turn: turn, parameter: parameter, targets: sourceIDs)
                for row in answerIndices where !primaries.contains(row) { entries[row] = .init(requirementID: entries[row].requirementID, resolution: .clarification(binding)) }
                previousTargets[turn] = primaries
                continue
            }
            guard !targets.isEmpty else { unresolved(.clarificationScope); continue }
            var replacements: [(Int, Resolution)] = []
            for target in targets.sorted() {
                let requirement = proposal.requirements[target]
                guard let source = proposal.source(of: requirement) else { continue }
                let changedScope = answer.scope.contains { scope in
                    if case .bound(let condition) = entries[target].resolution, case .party = condition.predicate { return false }
                    guard Self.contains(scope, requirement: requirement, proposal: proposal),
                          let prior = answer.priorRequirements.first(where: { $0.id == scope.requirementID }),
                          prior.role == .condition, prior.field == .quantity else { return false }
                    return Self.conditionSource(scope.source) != Self.conditionSource(source)
                }
                guard !changedScope else { continue }
                let ids = history(entries[target].resolution)
                let sourceIDs: [String]
                if case .bound(let condition) = entries[target].resolution { sourceIDs = condition.sourceRequirementIDs }
                else { sourceIDs = [requirement.id] }
                if case .party(let party) = parameter {
                    let compatible: Bool
                    switch entries[target].resolution {
                    case .bound(let condition):
                        switch condition.predicate {
                        case .party(let original): compatible = party == original
                        case .quantity(.equal, let count, let unit): compatible = party.count(for: unit) == count
                        default: compatible = false
                        }
                    case .historicalQuantityUnit, .unresolved(.missingQuantityUnit):
                        let parts = Self.quantityParts(Self.conditionSource(source))
                        compatible = parts?.comparison == .equal && parts?.unit == nil && parts?.count == party.total
                    default: compatible = false
                    }
                    guard compatible else { continue }
                    replacements.append((target, .bound(.init(inputDigest: proposal.input.digest, requirementID: requirement.id,
                        predicate: .party(party), historicalRequirementIDs: ids, sourceRequirementIDs: sourceIDs))))
                    continue
                }
                guard case .quantity(let statedComparison, let statedCount, let statedUnit) = parameter else { continue }
                if case .bound(let condition) = entries[target].resolution, case .party(let party) = condition.predicate {
                    guard statedComparison == nil || statedComparison == .equal, let count = statedCount, let unit = statedUnit,
                          party.count(for: unit) == count else { continue }
                    // Confirm a known component or total without replacing
                    // the retained adult/child composition with that scalar.
                    replacements.append((target, .bound(condition)))
                    continue
                }
                let comparison: Comparison, count: Int64, unit: QuantityUnit?
                switch entries[target].resolution {
                case .bound(let condition):
                    guard case .quantity(let originalComparison, let originalCount, let originalUnit) = condition.predicate else { continue }
                    comparison = originalComparison; count = originalCount; unit = originalUnit
                case .historicalQuantityUnit, .unresolved(.missingQuantityUnit):
                    guard let parts = Self.quantityParts(Self.conditionSource(source)), parts.unit == nil else { continue }
                    comparison = parts.comparison; count = parts.count; unit = nil
                default: continue
                }
                guard statedComparison == nil || statedComparison == comparison, statedCount == nil || statedCount == count else { continue }
                if let unit, let statedUnit, unit != statedUnit,
                   !(unit == .people && [.adults, .children].contains(statedUnit)) { continue }
                if let finalUnit = statedUnit ?? unit {
                    replacements.append((target, .bound(.init(inputDigest: proposal.input.digest, requirementID: requirement.id,
                        predicate: .quantity(comparison, count, finalUnit), historicalRequirementIDs: ids, sourceRequirementIDs: sourceIDs))))
                } else { replacements.append((target, ids.isEmpty ? .unresolved(.missingQuantityUnit) : .historicalQuantityUnit(ids))) }
            }
            guard replacements.count == targets.count else { unresolved(.contradictoryClarification); continue }
            for (target, resolution) in replacements {
                entries[target] = .init(requirementID: entries[target].requirementID, resolution: resolution)
                if case .bound(let condition) = resolution {
                    if case .quantity(_, _, let unit) = condition.predicate {
                        if originGroups[target] == nil { originGroups[target] = [target] }
                        originUnits[target] = unit; partyOriginRows.remove(target)
                    } else if case .party = condition.predicate {
                        originGroups[target] = original.indices.filter { condition.sourceRequirementIDs.contains(original[$0].requirementID) }
                        originUnits[target] = nil; partyOriginRows.insert(target)
                    }
                } else { originGroups[target] = nil; originUnits[target] = nil; partyOriginRows.remove(target) }
            }
            let ordered = targets.sorted()
            let binding = ClarificationBinding(input: proposal.input, turn: turn, parameter: parameter, targets: ordered.map { entries[$0].requirementID })
            for row in answerIndices { entries[row] = .init(requirementID: entries[row].requirementID, resolution: .clarification(binding)) }
            previousTargets[turn] = ordered
        }
        var origins = Dictionary(uniqueKeysWithValues: originGroups.map { row, group in
            (original[row].requirementID, group.map { original[$0].requirementID })
        })
        for (turn, targets) in previousTargets where !targets.isEmpty && targets.allSatisfy({ originGroups[$0] != nil }) {
            for row in proposal.requirements.indices where proposal.requirements[row].sourceTurnIndex == turn {
                origins[original[row].requirementID] = targets.map { original[$0].requirementID }
            }
        }
        let partyOrigins = Set(origins.compactMap { id, group -> String? in
            let rows = original.indices.filter { group.contains(original[$0].requirementID) }
            return !rows.isEmpty && rows.allSatisfy(partyOriginRows.contains) ? id : nil
        })
        return (entries, origins, partyOrigins)
    }

    private static func answerSpan(_ answer: String, turn: Int) -> ScalarSpan? {
        let source = conditionSource(answer)
        guard !source.isEmpty, let range = answer.range(of: source, options: .literal) else { return nil }
        let start = answer[..<range.lowerBound].utf8.count
        return .init(turn: turn, start: start, end: start + source.utf8.count)
    }

    private static func answeredDate(_ source: String, input: ComputerUseBrowserGoalInput, turn: Int) -> DayRange? {
        guard case .success((.day(let range), _)) = date(conditionSource(source), input: input, turn: turn) else { return nil }
        return range
    }

    private static func isNativeDateAnswer(_ source: String, input: ComputerUseBrowserGoalInput, turn: Int) -> Bool {
        guard input.dateContext(forTurn: turn) != nil else { return false }
        return answeredDate(source, input: input, turn: turn) != nil || weekdayClause(conditionSource(source))
    }

    /// Compare the selected byte intervals with the complete native date
    /// answer. Boundary punctuation/whitespace may sit in surrounding rows;
    /// no endpoint, modifier or other non-whitespace byte may be omitted.
    private static func coversDateAnswer(_ ranges: [Range<Int>], turn: Int, input: ComputerUseBrowserGoalInput) -> Bool {
        guard input.userTurns.indices.contains(turn),
              isNativeDateAnswer(input.userTurns[turn], input: input, turn: turn),
              let span = answerSpan(input.userTurns[turn], turn: turn) else { return false }
        return coversScalarSpan(ranges, span: span, input: input)
    }
    private static func coversQuantityAnswer(_ ranges: [Range<Int>], turn: Int, input: ComputerUseBrowserGoalInput) -> Bool {
        guard input.userTurns.indices.contains(turn),
              quantityAnswer(input.userTurns[turn]) != nil || quantityReplacementAnswer(input.userTurns[turn]) != nil,
              let span = answerSpan(input.userTurns[turn], turn: turn) else { return false }
        return coversScalarSpan(ranges, span: span, input: input)
    }
    private static func coversScalarSpan(_ ranges: [Range<Int>], span: ScalarSpan, input: ComputerUseBrowserGoalInput) -> Bool {
        guard input.userTurns.indices.contains(span.turn) else { return false }
        let bytes = Data(input.userTurns[span.turn].utf8)
        var cursor = span.start
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return false }
            let start = max(span.start, range.lowerBound), end = min(span.end, range.upperBound)
            guard start < end else { continue }
            guard start >= cursor, let gap = String(data: bytes[cursor..<start], encoding: .utf8),
                  gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            cursor = end
        }
        guard let remainder = String(data: bytes[cursor..<span.end], encoding: .utf8) else { return false }
        return remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func unqualifiedWeekday(_ source: String) -> Int? {
        guard let values = groups(#"^(?:(?:on|for)\s+)?(Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday)$"#, source) else { return nil }
        return ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"].firstIndex(of: values[0].lowercased())
    }

    private static func weekdayClause(_ source: String) -> Bool {
        groups(#"^(?:(?:on|for)\s+)?(?:(?:this|next)\s+)?(?:Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday)$"#, source) != nil
    }

    /// Proleptic Gregorian civil arithmetic, matching CivilDay's validation.
    /// January 1 of year 1 is Monday; each full seven-day block repeats it.
    private static func weekday(of day: CivilDay) -> Int {
        let year = day.year - 1
        let beforeMonth = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334][day.month - 1]
        let leap = day.year % 4 == 0 && (day.year % 100 != 0 || day.year % 400 == 0)
        return (365 * year + year / 4 - year / 100 + year / 400 + beforeMonth + (leap && day.month > 2 ? 1 : 0) + day.day) % 7
    }

    private static func reconcilingClarificationTargets(_ original: [Entry]) -> [Entry] {
        var entries = original
        let current = Dictionary(uniqueKeysWithValues: entries.map { ($0.requirementID, $0.resolution) })
        for index in entries.indices {
            guard case .clarification(let binding) = entries[index].resolution else { continue }
            if !binding.targetRequirementIDs.allSatisfy({ if case .bound? = current[$0] { return true }; return false }) {
                let waitingForUnit: Bool
                if case .quantity = binding.parameter {
                    waitingForUnit = binding.targetRequirementIDs.allSatisfy {
                        switch current[$0] { case .bound?, .historicalQuantityUnit?, .unresolved(.missingQuantityUnit)?: return true; default: return false }
                    }
                } else { waitingForUnit = false }
                entries[index] = .init(requirementID: entries[index].requirementID,
                    resolution: .unresolved(waitingForUnit ? .missingQuantityUnit : .contradictoryClarification))
            }
        }
        return entries
    }

    private static func contains(_ scope: ComputerUseBrowserGoalClarificationTurn.Scope,
                                 requirement: ComputerUseBrowserGoalProposal.Requirement,
                                 proposal: ComputerUseBrowserGoalProposal) -> Bool {
        guard requirement.sourceTurnIndex == scope.turn, let source = proposal.source(of: requirement) else { return false }
        // A new partition may move boundary whitespace, "and" or sentence
        // punctuation. Use the already supported price-clause normalization,
        // preserving every comparator/value/qualifier byte and its occurrence.
        let clause = conditionSource(source)
        guard !clause.isEmpty, let range = source.range(of: clause, options: .literal) else { return false }
        let start = requirement.sourceByteOffset + source[..<range.lowerBound].utf8.count
        guard start >= scope.sourceByteOffset else { return false }
        let selected = Data(clause.utf8)
        let bytes = Data(scope.source.utf8), offset = start - scope.sourceByteOffset
        guard !selected.isEmpty, offset <= bytes.count, selected.count <= bytes.count - offset else { return false }
        return bytes.subdata(in: offset..<(offset + selected.count)) == selected
    }

    private static func parameter(_ answer: String, topic: ComputerUseBrowserClarificationTopic) -> ClarificationBinding.Parameter? {
        var text = answer.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        if text.last == "." { text.removeLast() }
        if text.hasPrefix("please ") { text = String(text.dropFirst(7)) }
        for suffix in [", please", " please"] where text.hasSuffix(suffix) { text = String(text.dropLast(suffix.count)); break }
        switch topic {
        case .currency:
            for prefix in ["i mean ", "use ", "the currency is "] where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)); break }
            let names: [String: Currency] = ["usd":.usd, "us dollars":.usd, "u.s. dollars":.usd, "american dollars":.usd,
                "cad":.cad, "canadian dollars":.cad, "aud":.aud, "australian dollars":.aud,
                "eur":.eur, "euros":.eur, "gbp":.gbp, "british pounds":.gbp, "jpy":.jpy, "japanese yen":.jpy]
            return names[text].map { .currency($0) }
        case .priceBasis:
            for prefix in ["the budget is ", "it is ", "it's "] where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)); break }
            switch text { case "total", "a total", "in total": return .priceBasis(.total)
            case "per person", "per-person": return .priceBasis(.perPerson)
            case "per ticket", "per-ticket": return .priceBasis(.perTicket)
            default: return nil }
        case .fees:
            switch text { case "yes", "include fees", "including fees", "fees included", "including taxes and fees", "yes, include fees": return .fees(.included)
            case "no", "exclude fees", "excluding fees", "fees excluded", "excluding taxes and fees", "no, exclude fees": return .fees(.excluded)
            default: return nil }
        default: return nil
        }
    }

    private static func applying(_ parameter: ClarificationBinding.Parameter, to predicate: Predicate) -> Predicate? {
        guard case .price(let comparison, let original, let originalBasis, let originalFees) = predicate else { return nil }
        var currency = original.currency, basis = originalBasis, fees = originalFees
        switch parameter {
        case .currency(let value):
            let compatible: Bool
            switch currency {
            case .dollarSymbol: compatible = [.usd, .cad, .aud].contains(value)
            case .euroSymbol: compatible = value == .eur
            case .poundSymbol: compatible = value == .gbp
            case .yenSymbol: compatible = value == .jpy
            default: compatible = value == currency
            }
            guard compatible else { return nil }; currency = value
        case .priceBasis(let value):
            guard basis == .unspecified || basis == value else { return nil }; basis = value
        case .fees(let value):
            guard fees == .unspecified || fees == value else { return nil }; fees = value
        case .date, .quantity, .party: return nil
        }
        guard let amount = Amount(hundredths: original.hundredths, currency: currency) else { return nil }
        return .price(comparison, amount, basis, fees)
    }

    private struct BindingFailure: Error { let reason: UnresolvedReason }
    private static func conditionSource(_ source: String) -> String {
        var result = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.lowercased().hasPrefix("and ") { result = String(result.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if result.last == "." || result.last == "," || result.last == ";" {
            result.removeLast(); result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
    private static func groups(_ pattern: String, _ source: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              match.range == NSRange(source.startIndex..., in: source) else { return nil }
        let text = source as NSString
        return (1..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : text.substring(with: match.range(at: $0)) }
    }
    private static func comparison(_ phrase: String) -> Comparison? {
        switch phrase.lowercased() {
        case "", "exactly": return .equal
        case "under", "below", "less than", "fewer than": return .below
        case "at most", "no more than": return .atMost
        case "over", "above", "more than": return .above
        case "at least": return .atLeast
        default: return nil
        }
    }
    private static func quantity(_ source: String) -> Result<(Predicate, ComputerUseBrowserGoalProposal.Relation), BindingFailure> {
        if let party = partyLiteral(source) { return .success((.party(party), .equal)) }
        guard let parts = quantityParts(source) else { return .failure(.init(reason: .unrecognizedSource)) }
        guard let unit = parts.unit else { return .failure(.init(reason: .missingQuantityUnit)) }
        return .success((.quantity(parts.comparison, parts.count, unit), parts.comparison.relation))
    }
    private struct QuantityParts: Equatable {
        let comparison: Comparison
        let count: Int64
        let unit: QuantityUnit?
        let explicitComparison: Bool
    }
    private static let quantityWords: [String: Int64] = ["one":1, "two":2, "three":3, "four":4, "five":5, "six":6, "seven":7, "eight":8, "nine":9, "ten":10]
    /// Complete option-label arithmetic only. A numeric choice does not prove
    /// the field's category meaning, provider ages or available inventory.
    static func exactQuantityChoiceLabel(_ source: String) -> (count: Int64, unit: QuantityUnit?)? {
        let parts = source.split(whereSeparator: \.isWhitespace)
        guard (1...2).contains(parts.count) else { return nil }
        let number = String(parts[0]), count: Int64
        if number.utf8.count <= 4, number.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int64(number) {
            count = value
        } else if let value = quantityWords[number.lowercased()] { count = value }
        else { return nil }
        guard (0...1998).contains(count) else { return nil }
        if parts.count == 1 { return (count, nil) }
        guard let unit = QuantityUnit.literal(String(parts[1])) else { return nil }
        return (count, unit)
    }
    private static func quantityParts(_ source: String) -> QuantityParts? {
        let pattern = #"^(?:for\s+)?(?:(at least|at most|more than|fewer than|exactly)\s+)?([0-9]{1,3}|one|two|three|four|five|six|seven|eight|nine|ten)(?:\s+("# + QuantityUnit.literalPattern + #"))?$"#
        guard let values = groups(pattern, source), let comparison = comparison(values[0]) else { return nil }
        guard let count = Int64(values[1]) ?? quantityWords[values[1].lowercased()] else { return nil }
        return .init(comparison: comparison, count: count, unit: values[2].isEmpty ? nil : QuantityUnit.literal(values[2]), explicitComparison: !values[0].isEmpty)
    }
    private static func quantityAnswer(_ answer: String) -> ClarificationBinding.Parameter? {
        let source = conditionSource(answer)
        if let party = partyLiteral(source) { return .party(party) }
        if let unit = QuantityUnit.literal(source) { return .quantity(nil, nil, unit) }
        guard let parts = quantityParts(source) else { return nil }
        return .quantity(parts.explicitComparison ? parts.comparison : nil, parts.count, parts.unit)
    }
    private static func quantityReplacementAnswer(_ answer: String) -> QuantityParts? {
        var source = conditionSource(answer)
        if source.lowercased().hasPrefix("make that ") { source = String(source.dropFirst("make that ".count)) }
        guard let parts = quantityParts(source), parts.unit != nil else { return nil }
        return parts
    }
    private static func quantityScope(_ scope: String, within answer: String) -> Bool {
        if let party = partyLiteral(conditionSource(answer)) {
            if let selected = partyLiteral(conditionSource(scope)) { return selected == party }
            guard case .quantity(let comparison, let count?, let unit?)? = quantityAnswer(scope),
                  comparison == nil || comparison == .equal else { return false }
            return party.count(for: unit) == count
        }
        guard case .quantity(let comparison, let count, let unit)? = quantityAnswer(scope),
              case .quantity(let expectedComparison, let expectedCount, let expectedUnit)? = quantityAnswer(answer) else { return false }
        return (comparison == nil || comparison == expectedComparison)
            && (count == nil || count == expectedCount) && (unit == nil || unit == expectedUnit)
    }
    private static let partyComponentPattern = #"([0-9]{1,3}|one|two|three|four|five|six|seven|eight|nine|ten)\s+(adults?|children|child)"#
    private static var partyPattern: String {
        let separator = #"(?:\s*,?\s+and\s+|\s*,\s*|\s*&\s*|\s+)"#
        return #"^(?:for\s+)?(?:exactly\s+)?"# + partyComponentPattern + separator + partyComponentPattern + "$"
    }
    private static func partyComponentRanges(_ source: String) -> [QuantityUnit: Range<Int>]? {
        guard let expression = try? NSRegularExpression(pattern: partyPattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              match.range == NSRange(source.startIndex..., in: source) else { return nil }
        var ranges: [QuantityUnit: Range<Int>] = [:]
        for index in [1, 3] {
            guard let number = Range(match.range(at: index), in: source), let label = Range(match.range(at: index + 1), in: source),
                  let unit = QuantityUnit.literal(String(source[label])) else { return nil }
            ranges[unit] = source[..<number.lowerBound].utf8.count..<source[..<label.upperBound].utf8.count
        }
        return ranges
    }
    static func partyLiteral(_ source: String) -> PartyComposition? {
        guard let parts = groups(partyPattern, source),
              let firstUnit = QuantityUnit.literal(parts[1]), let secondUnit = QuantityUnit.literal(parts[3]), firstUnit != secondUnit else { return nil }
        guard let first = Int64(parts[0]) ?? quantityWords[parts[0].lowercased()], let second = Int64(parts[2]) ?? quantityWords[parts[2].lowercased()] else { return nil }
        return .init(adults: firstUnit == .adults ? first : second, children: firstUnit == .children ? first : second)
    }
    private static func price(_ source: String) -> Result<(Predicate, ComputerUseBrowserGoalProposal.Relation), BindingFailure> {
        let pattern = #"^(under|below|less than|at most|no more than|over|above|more than|at least|exactly)\s+((?:USD|EUR|GBP|CAD|AUD|JPY)|[$€£¥])\s*((?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]{1,2})?)(?:\s+(total|per person|per ticket))?(?:\s+(including fees|excluding fees))?$"#
        guard let values = groups(pattern, source), let comparison = comparison(values[0]),
              let currency = Currency(rawValue: values[1].uppercased()) else { return .failure(.init(reason: .unrecognizedSource)) }
        let number = values[2].replacingOccurrences(of: ",", with: "").split(separator: ".", omittingEmptySubsequences: false)
        guard let wholeText = number.first, wholeText.count <= 9, let whole = Int64(wholeText) else { return .failure(.init(reason: .invalidValue)) }
        let fraction = number.count == 2 ? String(number[1]) : ""
        guard let hundredths = Int64(fraction + String(repeating: "0", count: 2 - fraction.count)),
              let amount = Amount(hundredths: whole * 100 + hundredths, currency: currency) else { return .failure(.init(reason: .invalidValue)) }
        let basis: PriceBasis
        switch values[3].lowercased() { case "total": basis = .total; case "per person": basis = .perPerson; case "per ticket": basis = .perTicket; default: basis = .unspecified }
        let fees: Fees
        switch values[4].lowercased() { case "including fees": fees = .included; case "excluding fees": fees = .excluded; default: fees = .unspecified }
        return .success((.price(comparison, amount, basis, fees), comparison.relation))
    }
    private static func day(_ value: String, context: ComputerUseBrowserGoalInput.DateContext) -> CivilDay? {
        if let parts = groups(#"^([0-9]{4})-([0-9]{2})-([0-9]{2})$"#, value),
           let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) { return .init(year: year, month: month, day: day) }
        guard ["today", "tomorrow"].contains(value.lowercased()), let timeZone = TimeZone(identifier: context.timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let reference = Date(timeIntervalSince1970: Double(context.referenceMilliseconds) / 1_000)
        let today = calendar.startOfDay(for: reference)
        guard let target = calendar.date(byAdding: .day, value: value.lowercased() == "tomorrow" ? 1 : 0, to: today) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: target)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return .init(year: year, month: month, day: day)
    }
    private static func date(_ source: String, input: ComputerUseBrowserGoalInput, turn: Int) -> Result<(Predicate, ComputerUseBrowserGoalProposal.Relation), BindingFailure> {
        guard let context = input.dateContext(forTurn: turn) else { return .failure(.init(reason: .invalidValue)) }
        let token = #"(today|tomorrow|[0-9]{4}-[0-9]{2}-[0-9]{2})"#
        if let parts = groups("^(?:(on|for)\\s+)?" + token + "$", source) {
            guard let value = day(parts[1], context: context) else { return .failure(.init(reason: .invalidValue)) }
            return .success((.day(.init(lower: value, lowerInclusive: true, upper: value, upperInclusive: true)), .equal))
        }
        if let parts = groups("^(before|after|on or before|on or after)\\s+" + token + "$", source) {
            guard let value = day(parts[1], context: context) else { return .failure(.init(reason: .invalidValue)) }
            switch parts[0].lowercased() {
            case "before": return .success((.day(.init(lower: nil, lowerInclusive: false, upper: value, upperInclusive: false)), .earlier))
            case "after": return .success((.day(.init(lower: value, lowerInclusive: false, upper: nil, upperInclusive: false)), .later))
            case "on or before": return .success((.day(.init(lower: nil, lowerInclusive: false, upper: value, upperInclusive: true)), .atMost))
            default: return .success((.day(.init(lower: value, lowerInclusive: true, upper: nil, upperInclusive: false)), .atLeast))
            }
        }
        if let parts = groups("^from\\s+" + token + "\\s+through\\s+" + token + "$", source) {
            guard let lower = day(parts[0], context: context), let upper = day(parts[1], context: context), lower <= upper else {
                return .failure(.init(reason: .invalidValue))
            }
            return .success((.day(.init(lower: lower, lowerInclusive: true, upper: upper, upperInclusive: true)), .between))
        }
        if groups(#"^(?:(?:on|for)\s+)?(?:(?:this|next)\s+)?(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)$"#, source) != nil
            || source.lowercased().hasPrefix("between ") { return .failure(.init(reason: .ambiguousDate)) }
        return .failure(.init(reason: .unrecognizedSource))
    }
}

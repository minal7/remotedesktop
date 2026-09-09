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
    }
    enum Resolution: Equatable, Sendable {
        case bound(Condition), clarification(ClarificationBinding), unresolved(UnresolvedReason)
        /// A complete weekday clause retained from a prior interpretation.
        /// These native source IDs preserve the uncertainty, not a date value.
        case historicalDateAmbiguity([String])
        /// A retained count/comparator still needs a unit before evaluation.
        case historicalQuantityUnit([String])
    }
    struct ClarificationBinding: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        enum Parameter: Equatable, Sendable {
            case currency(Currency), priceBasis(PriceBasis), fees(Fees), date(DayRange)
            case quantity(Comparison?, Int64?, QuantityUnit?)
            case party(PartyComposition)
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
        fileprivate init(input: ComputerUseBrowserGoalInput, turn: Int, parameter: Parameter, targets: [String]) {
            answerTurn = turn; self.parameter = parameter; targetRequirementIDs = targets
            id = ComputerUseTaskContract.digest(["browser-scalar-clarification-v2", input.digest,
                input.clarifications[turn - 1].digest, String(turn)] + parameter.identity + targets)
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
        var hasHistoricalSource: Bool { !historicalRequirementIDs.isEmpty }
        fileprivate init(inputDigest: String, requirementID: String, predicate: Predicate, historicalRequirementIDs: [String] = []) {
            self.requirementID = requirementID; self.predicate = predicate
            self.historicalRequirementIDs = historicalRequirementIDs
            id = ComputerUseTaskContract.digest([historicalRequirementIDs.isEmpty ? "browser-scalar-condition-v1" : "browser-historical-scalar-condition-v1",
                inputDigest, requirementID] + predicate.identity + historicalRequirementIDs)
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
        proposal.requirements.first(where: permitsDateQuestion)?.id
    }
    /// A native fallback may use retained weekday meaning even when the
    /// current model's field/role no longer accepts a date-topic question.
    func permitsDateQuestion(_ requirement: ComputerUseBrowserGoalProposal.Requirement) -> Bool {
        guard let index = proposal.requirements.firstIndex(of: requirement),
              let source = proposal.source(of: requirement),
              Self.unqualifiedWeekday(Self.conditionSource(source)) != nil else { return false }
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
        let retained = Self.retainingHistoricalScalars(proposal, entries: baseEntries)
        var nativeSources = Set(retained.compactMap { entry -> String? in
            switch entry.resolution {
            case .bound(let condition) where condition.hasHistoricalSource: return entry.requirementID
            case .historicalDateAmbiguity, .historicalQuantityUnit: return entry.requirementID
            default: return nil
            }
        })
        if proposal.disposition == .research {
            for (index, answer) in proposal.input.clarifications.enumerated() {
                let literal: Bool
                switch answer.topic {
                case .date: literal = Self.answeredDate(answer.answer, input: proposal.input) != nil
                case .quantity: literal = Self.quantityAnswer(answer.answer) != nil
                default: literal = Self.parameter(answer.answer, topic: answer.topic) != nil
                }
                if literal {
                    nativeSources.formUnion(proposal.requirements.filter { $0.sourceTurnIndex == index + 1 }.map(\.id))
                }
            }
        }
        nativeScalarSourceIDs = nativeSources
        entries = Self.reconcilingClarificationTargets(Self.applyingQuantityClarifications(proposal,
            to: Self.applyingDateClarifications(proposal, to: Self.applyingPriceClarifications(proposal, to: retained))))
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
        case .date: parsed = Self.date(source, input: input)
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
    /// weekday ambiguity. Retain only an exact native clause occurrence;
    /// merged/split meanings need complete obligation reconciliation.
    private static func retainingHistoricalScalars(_ proposal: ComputerUseBrowserGoalProposal, entries original: [Entry]) -> [Entry] {
        guard proposal.disposition == .research else { return original }
        var entries = original
        for answer in proposal.input.clarifications {
            for historical in answer.priorRequirements {
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
                if entries[target].resolution == .unresolved(.historicalScalarScope) { continue }
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

    private struct ScalarSpan: Equatable { let turn: Int; let start: Int; let end: Int }
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

    /// A date answer can resolve a selected weekday occurrence or confirm an
    /// already concrete date/range. It cannot replace a different concrete
    /// value, choose between several dates in one broad scope, or discard a
    /// relative-week modifier whose meaning has not been compiled.
    private static func applyingDateClarifications(_ proposal: ComputerUseBrowserGoalProposal, to original: [Entry]) -> [Entry] {
        guard proposal.disposition == .research else { return original }
        var entries = original
        let answerTurns = Set(proposal.input.clarifications.enumerated().compactMap { $0.element.topic == .date ? $0.offset + 1 : nil })
        let dateIndices = proposal.requirements.indices.filter {
            let requirement = proposal.requirements[$0]
            guard !answerTurns.contains(requirement.sourceTurnIndex) else { return false }
            if case .bound(let condition) = original[$0].resolution, case .day = condition.predicate { return true }
            if case .historicalDateAmbiguity = original[$0].resolution { return true }
            return requirement.role == .condition && requirement.field == .date
        }
        var previousTargets: [Int: [Int]] = [:]
        for (index, answer) in proposal.input.clarifications.enumerated() where answer.topic == .date {
            let turn = index + 1
            let answerIndices = proposal.requirements.indices.filter { proposal.requirements[$0].sourceTurnIndex == turn }
            var targets: Set<Int> = [], possibleTargets: Set<Int> = [], invalidScope = false
            var onlyMissingDetailScopes = true, hasMissingDetailScope = false
            for scope in answer.scope {
                guard scope.turn < turn else { invalidScope = true; continue }
                let matching = dateIndices.filter { Self.contains(scope, requirement: proposal.requirements[$0], proposal: proposal) }
                possibleTargets.formUnion(matching)
                if matching.count == 1 { targets.insert(matching[0]); onlyMissingDetailScopes = false }
                else if matching.isEmpty, scope.turn > 0, let previous = previousTargets[scope.turn],
                        let expected = Self.answeredDate(proposal.input.userTurns[scope.turn], input: proposal.input),
                        Self.answeredDate(scope.source, input: proposal.input) == expected {
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
            guard let range = Self.answeredDate(answer.answer, input: proposal.input) else { unresolved(.ambiguousClarification); continue }
            if targets.isEmpty && onlyMissingDetailScopes { continue }
            guard !targets.isEmpty else { unresolved(.clarificationScope); continue }
            let ordered = targets.sorted()
            let compatible = ordered.allSatisfy { target in
                let requirement = proposal.requirements[target]
                guard let source = proposal.source(of: requirement) else { return false }
                // Repartitioning a known date clause must not remove its
                // modifier/comparator and then resolve the shortened clause.
                for scope in answer.scope where Self.contains(scope, requirement: requirement, proposal: proposal) {
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
                switch entries[target].resolution {
                case .bound(let condition): historicalIDs = condition.historicalRequirementIDs
                case .historicalDateAmbiguity(let ids): historicalIDs = ids
                default: historicalIDs = []
                }
                entries[target] = .init(requirementID: original[target].requirementID,
                    resolution: .bound(.init(inputDigest: proposal.input.digest, requirementID: original[target].requirementID,
                        predicate: .day(range), historicalRequirementIDs: historicalIDs)))
            }
            let binding = ClarificationBinding(input: proposal.input, turn: turn, parameter: .date(range),
                targets: ordered.map { original[$0].requirementID })
            for row in answerIndices { entries[row] = .init(requirementID: original[row].requirementID, resolution: .clarification(binding)) }
            previousTargets[turn] = ordered
        }
        return entries
    }

    /// A scoped quantity answer fills missing units, confirms a known count,
    /// or refines an all-people party to adults/children. It cannot replace a
    /// different count/comparator or cross inventory, party and result scopes.
    private static func applyingQuantityClarifications(_ proposal: ComputerUseBrowserGoalProposal, to original: [Entry]) -> [Entry] {
        guard proposal.disposition == .research else { return original }
        var entries = original
        let answerTurns = Set(proposal.input.clarifications.enumerated().compactMap { $0.element.topic == .quantity ? $0.offset + 1 : nil })
        let quantityIndices = proposal.requirements.indices.filter {
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
        func history(_ resolution: Resolution) -> [String] {
            switch resolution {
            case .bound(let condition): return condition.historicalRequirementIDs
            case .historicalQuantityUnit(let ids): return ids
            default: return []
            }
        }
        for (index, answer) in proposal.input.clarifications.enumerated() where answer.topic == .quantity {
            let turn = index + 1
            let answerIndices = proposal.requirements.indices.filter { proposal.requirements[$0].sourceTurnIndex == turn }
            var targets: Set<Int> = [], possibleTargets: Set<Int> = [], invalidScope = false, missingDetail = false
            for scope in answer.scope {
                guard scope.turn < turn else { invalidScope = true; continue }
                let matching = quantityIndices.filter { Self.contains(scope, requirement: proposal.requirements[$0], proposal: proposal) }
                possibleTargets.formUnion(matching)
                if matching.count == 1 { targets.insert(matching[0]) }
                else if matching.isEmpty, scope.turn > 0, let previous = previousTargets[scope.turn],
                        Self.quantityScope(scope.source, within: proposal.input.userTurns[scope.turn]) {
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
            guard let parameter = Self.quantityAnswer(answer.answer) else {
                unresolved(.ambiguousClarification); continue
            }
            if targets.isEmpty && missingDetail {
                // The entire answer is a new quantity clause. Do not attach
                // its predicate to the earlier, broader outcome requirement.
                guard let span = Self.answerSpan(answer.answer, turn: turn) else { unresolved(.clarificationScope); continue }
                let matches = answerIndices.filter { Self.scalarSpan(proposal.requirements[$0], input: proposal.input) == span }
                guard matches.count == 1, let primary = matches.first else { unresolved(.clarificationScope); continue }
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
                entries[primary] = .init(requirementID: entries[primary].requirementID, resolution: resolution)
                let binding = ClarificationBinding(input: proposal.input, turn: turn, parameter: parameter, targets: [entries[primary].requirementID])
                for row in answerIndices where row != primary { entries[row] = .init(requirementID: entries[row].requirementID, resolution: .clarification(binding)) }
                previousTargets[turn] = [primary]
                continue
            }
            guard !targets.isEmpty else { unresolved(.clarificationScope); continue }
            var replacements: [(Int, Resolution)] = []
            for target in targets.sorted() {
                let requirement = proposal.requirements[target]
                guard let source = proposal.source(of: requirement) else { continue }
                let changedScope = answer.scope.contains { scope in
                    guard Self.contains(scope, requirement: requirement, proposal: proposal),
                          let prior = answer.priorRequirements.first(where: { $0.id == scope.requirementID }),
                          prior.role == .condition, prior.field == .quantity else { return false }
                    return Self.conditionSource(scope.source) != Self.conditionSource(source)
                }
                guard !changedScope else { continue }
                let ids = history(entries[target].resolution)
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
                        predicate: .party(party), historicalRequirementIDs: ids))))
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
                        predicate: .quantity(comparison, count, finalUnit), historicalRequirementIDs: ids))))
                } else { replacements.append((target, ids.isEmpty ? .unresolved(.missingQuantityUnit) : .historicalQuantityUnit(ids))) }
            }
            guard replacements.count == targets.count else { unresolved(.contradictoryClarification); continue }
            for (target, resolution) in replacements { entries[target] = .init(requirementID: entries[target].requirementID, resolution: resolution) }
            let ordered = targets.sorted()
            let binding = ClarificationBinding(input: proposal.input, turn: turn, parameter: parameter, targets: ordered.map { entries[$0].requirementID })
            for row in answerIndices { entries[row] = .init(requirementID: entries[row].requirementID, resolution: .clarification(binding)) }
            previousTargets[turn] = ordered
        }
        return entries
    }

    private static func answerSpan(_ answer: String, turn: Int) -> ScalarSpan? {
        let source = conditionSource(answer)
        guard !source.isEmpty, let range = answer.range(of: source, options: .literal) else { return nil }
        let start = answer[..<range.lowerBound].utf8.count
        return .init(turn: turn, start: start, end: start + source.utf8.count)
    }

    private static func answeredDate(_ source: String, input: ComputerUseBrowserGoalInput) -> DayRange? {
        guard case .success((.day(let range), _)) = date(conditionSource(source), input: input) else { return nil }
        return range
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
    private static func quantityParts(_ source: String) -> QuantityParts? {
        let pattern = #"^(?:for\s+)?(?:(at least|at most|more than|fewer than|exactly)\s+)?([0-9]{1,3}|one|two|three|four|five|six|seven|eight|nine|ten)(?:\s+("# + QuantityUnit.literalPattern + #"))?$"#
        guard let values = groups(pattern, source), let comparison = comparison(values[0]) else { return nil }
        let words: [String: Int64] = ["one":1, "two":2, "three":3, "four":4, "five":5, "six":6, "seven":7, "eight":8, "nine":9, "ten":10]
        guard let count = Int64(values[1]) ?? words[values[1].lowercased()] else { return nil }
        return .init(comparison: comparison, count: count, unit: values[2].isEmpty ? nil : QuantityUnit.literal(values[2]), explicitComparison: !values[0].isEmpty)
    }
    private static func quantityAnswer(_ answer: String) -> ClarificationBinding.Parameter? {
        let source = conditionSource(answer)
        if let party = partyLiteral(source) { return .party(party) }
        if let unit = QuantityUnit.literal(source) { return .quantity(nil, nil, unit) }
        guard let parts = quantityParts(source) else { return nil }
        return .quantity(parts.explicitComparison ? parts.comparison : nil, parts.count, parts.unit)
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
    static func partyLiteral(_ source: String) -> PartyComposition? {
        let number = #"[0-9]{1,3}|one|two|three|four|five|six|seven|eight|nine|ten"#
        let component = "(" + number + #")\s+(adults?|children|child)"#
        let separator = #"(?:\s*,?\s+and\s+|\s*,\s*|\s*&\s*|\s+)"#
        guard let parts = groups(#"^(?:for\s+)?(?:exactly\s+)?"# + component + separator + component + "$", source),
              let firstUnit = QuantityUnit.literal(parts[1]), let secondUnit = QuantityUnit.literal(parts[3]), firstUnit != secondUnit else { return nil }
        let words: [String: Int64] = ["one":1, "two":2, "three":3, "four":4, "five":5, "six":6, "seven":7, "eight":8, "nine":9, "ten":10]
        guard let first = Int64(parts[0]) ?? words[parts[0].lowercased()], let second = Int64(parts[2]) ?? words[parts[2].lowercased()] else { return nil }
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
    private static func day(_ value: String, input: ComputerUseBrowserGoalInput) -> CivilDay? {
        if let parts = groups(#"^([0-9]{4})-([0-9]{2})-([0-9]{2})$"#, value),
           let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) { return .init(year: year, month: month, day: day) }
        guard ["today", "tomorrow"].contains(value.lowercased()), let timeZone = TimeZone(identifier: input.timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let reference = Date(timeIntervalSince1970: Double(input.referenceMilliseconds) / 1_000)
        let today = calendar.startOfDay(for: reference)
        guard let target = calendar.date(byAdding: .day, value: value.lowercased() == "tomorrow" ? 1 : 0, to: today) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: target)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return .init(year: year, month: month, day: day)
    }
    private static func date(_ source: String, input: ComputerUseBrowserGoalInput) -> Result<(Predicate, ComputerUseBrowserGoalProposal.Relation), BindingFailure> {
        let token = #"(today|tomorrow|[0-9]{4}-[0-9]{2}-[0-9]{2})"#
        if let parts = groups("^(?:(on|for)\\s+)?" + token + "$", source) {
            guard let value = day(parts[1], input: input) else { return .failure(.init(reason: .invalidValue)) }
            return .success((.day(.init(lower: value, lowerInclusive: true, upper: value, upperInclusive: true)), .equal))
        }
        if let parts = groups("^(before|after|on or before|on or after)\\s+" + token + "$", source) {
            guard let value = day(parts[1], input: input) else { return .failure(.init(reason: .invalidValue)) }
            switch parts[0].lowercased() {
            case "before": return .success((.day(.init(lower: nil, lowerInclusive: false, upper: value, upperInclusive: false)), .earlier))
            case "after": return .success((.day(.init(lower: value, lowerInclusive: false, upper: nil, upperInclusive: false)), .later))
            case "on or before": return .success((.day(.init(lower: nil, lowerInclusive: false, upper: value, upperInclusive: true)), .atMost))
            default: return .success((.day(.init(lower: value, lowerInclusive: true, upper: nil, upperInclusive: false)), .atLeast))
            }
        }
        if let parts = groups("^from\\s+" + token + "\\s+through\\s+" + token + "$", source) {
            guard let lower = day(parts[0], input: input), let upper = day(parts[1], input: input), lower <= upper else {
                return .failure(.init(reason: .invalidValue))
            }
            return .success((.day(.init(lower: lower, lowerInclusive: true, upper: upper, upperInclusive: true)), .between))
        }
        if groups(#"^(?:(?:on|for)\s+)?(?:(?:this|next)\s+)?(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)$"#, source) != nil
            || source.lowercased().hasPrefix("between ") { return .failure(.init(reason: .ambiguousDate)) }
        return .failure(.init(reason: .unrecognizedSource))
    }
}

import Foundation

/// Compiles scalar conditions without pretending to compile the whole goal.
/// Every proposal requirement keeps a ledger entry, including unresolved
/// outcomes, places, sequencing and unsupported language. No effects occur.
/// A bound fragment still needs whole-goal role, scope and logic validation:
/// separate fragments can negate or qualify a locally parsed condition.
struct ComputerUseBrowserScalarRequirements: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum UnresolvedReason: String, Sendable {
        case unresolvedDisposition, notScalar, unrecognizedSource, invalidValue, contradictoryProposal, ambiguousDate
    }
    enum Resolution: Equatable, Sendable { case bound(Condition), unresolved(UnresolvedReason) }
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
    enum QuantityUnit: String, Sendable { case results, options, flights, concerts, movies, tickets }
    enum PriceBasis: String, Sendable { case unspecified, total, perPerson, perTicket }
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
        case price(Comparison, Amount, PriceBasis, Fees)
        case day(DayRange)
        fileprivate var identity: [String] {
            switch self {
            case .quantity(let comparison, let count, let unit):
                return ["quantity", comparison.rawValue, String(count), unit.rawValue]
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
        case price(Amount, PriceBasis, Fees, isExact: Bool)
        case day(CivilDay)
    }
    /// A parsed quotation only. Neither exact offer pricing, applicability,
    /// inventory nor association is established by a literal's spelling.
    enum Literal: Equatable, Sendable {
        case quantity(Int64, QuantityUnit)
        case price(Amount, PriceBasis, Fees)
        case day(CivilDay)
    }
    enum Evaluation: Equatable, Sendable { case satisfied, notSatisfied, unverifiable }
    struct Condition: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let id: String
        let requirementID: String
        let predicate: Predicate
        fileprivate init(inputDigest: String, requirementID: String, predicate: Predicate) {
            self.requirementID = requirementID; self.predicate = predicate
            id = ComputerUseTaskContract.digest(["browser-scalar-condition-v1", inputDigest, requirementID] + predicate.identity)
        }
        /// This is an arithmetic/civil-date comparison, never whole-result or
        /// task completion. Different units, currencies or incomplete prices
        /// cannot become passing observations through numeric comparison.
        /// Unspecified request basis/fees impose no scalar comparison here;
        /// this does not establish adequate scope for the whole request.
        func evaluate(_ observation: Observation) -> Evaluation {
            switch observation {
            case .quantity(let count, let unit): return compareLiteral(.quantity(count, unit))
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
        var description: String { "BrowserScalarCondition" }
        var debugDescription: String { description }
    }

    let proposal: ComputerUseBrowserGoalProposal
    let entries: [Entry]
    var unresolvedRequirementIDs: [String] {
        entries.compactMap { if case .unresolved = $0.resolution { return $0.requirementID }; return nil }
    }
    var description: String { "BrowserScalarRequirements(entries: \(entries.count), unresolved: \(unresolvedRequirementIDs.count))" }
    var debugDescription: String { description }

    init(proposal: ComputerUseBrowserGoalProposal) {
        self.proposal = proposal
        entries = proposal.requirements.map { requirement in
            guard proposal.disposition == .research else {
                return Entry(requirementID: requirement.id, resolution: .unresolved(.unresolvedDisposition))
            }
            guard requirement.role == .condition, [.date, .quantity, .price].contains(requirement.field),
                  let original = proposal.source(of: requirement) else {
                return Entry(requirementID: requirement.id, resolution: .unresolved(.notScalar))
            }
            let source = Self.conditionSource(original)
            let parsed: Result<(Predicate, ComputerUseBrowserGoalProposal.Relation), BindingFailure>
            switch requirement.field {
            case .quantity: parsed = Self.quantity(source)
            case .price: parsed = Self.price(source)
            case .date: parsed = Self.date(source, input: proposal.input)
            default: parsed = .failure(.init(reason: .notScalar))
            }
            switch parsed {
            case .success(let (predicate, relation)):
                guard requirement.relation == .unspecified || requirement.relation == relation else {
                    return Entry(requirementID: requirement.id, resolution: .unresolved(.contradictoryProposal))
                }
                return Entry(requirementID: requirement.id, resolution: .bound(.init(inputDigest: proposal.input.digest,
                    requirementID: requirement.id, predicate: predicate)))
            case .failure(let failure): return Entry(requirementID: requirement.id, resolution: .unresolved(failure.reason))
            }
        }
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
        guard let values = groups(#"^(?:(at least|at most|more than|fewer than|exactly)\s+)?([0-9]{1,3}|one|two|three|four|five|six|seven|eight|nine|ten)\s+(results|options|flights|concerts|movies|tickets)$"#, source),
              let comparison = comparison(values[0]), let unit = QuantityUnit(rawValue: values[2].lowercased()) else {
            return .failure(.init(reason: .unrecognizedSource))
        }
        let words: [String: Int64] = ["one":1, "two":2, "three":3, "four":4, "five":5, "six":6, "seven":7, "eight":8, "nine":9, "ten":10]
        guard let count = Int64(values[1]) ?? words[values[1].lowercased()] else { return .failure(.init(reason: .invalidValue)) }
        return .success((.quantity(comparison, count, unit), comparison.relation))
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

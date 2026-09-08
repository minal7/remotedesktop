import Foundation

/// A complete requirement ledger for one native-bound candidate reading.
/// Arithmetic/date matches are useful evidence, not proof of offer association
/// or whole-goal fulfillment. No completion flag or answer text is produced.
struct ComputerUseBrowserResultAssessment: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    typealias Scalars = ComputerUseBrowserScalarRequirements
    enum Status: String, Sendable {
        case needsSemanticVerification, needsResultSet, uncompiledRequirement, clarificationApplied
        case missingQuote, ambiguousQuotes, unparsedQuote
        case quotedValueMatches, quotedValueConflicts, incompatibleLiteral
        case reviewMixedOffers, reviewUnresolved, reviewPageContext, reviewQualifiedPrice
        case sourceOriginPermitted, sourceOriginExcluded, sourceUnconfigured, incompletePage
    }
    struct Requirement: Equatable, Sendable {
        let id: String
        let turn: Int
        let sourceByteOffset: Int
        let sourceByteCount: Int
        let role: ComputerUseBrowserGoalProposal.Role
        let field: ComputerUseBrowserGoalProposal.Field
        let relation: ComputerUseBrowserGoalProposal.Relation
    }
    struct Quote: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let fieldIndex: Int
        let kind: ComputerUseBrowserResultProposal.Kind
        let textIDs: [String]
        /// Complete selected source records, never a numeric substring.
        /// Qualifiers outside these records still need semantic association.
        /// Interpretation uses normalized whitespace only.
        let source: String
        let literal: Scalars.Literal?
        var description: String { "BrowserScalarQuote(kind: \(kind.rawValue), parsed: \(literal != nil))" }
        var debugDescription: String { description }
    }
    struct Evaluation: Equatable, Sendable {
        let requirementID: String
        let status: Status
        let quoteIndices: [Int]
    }
    struct Candidate: Equatable, Sendable {
        let candidateID: String
        let quotes: [Quote]
        /// Exactly one entry for every requirement, in original source order.
        let requirements: [Evaluation]
    }
    let goalRevision: String
    let interpretationDigest: String
    let requirements: [Requirement]
    let candidates: [Candidate]
    private let readingIdentity: String

    init(interpretation: ComputerUseBrowserGoalProposal, reading: ComputerUseBrowserResultCandidates) throws {
        guard interpretation.input.digest == reading.goalRevision else { throw ComputerUseBrowserResultError.goalChanged }
        goalRevision = interpretation.input.digest; interpretationDigest = interpretation.digest
        readingIdentity = reading.requirementAssessmentIdentity
        requirements = interpretation.requirements.map {
            .init(id: $0.id, turn: $0.sourceTurnIndex, sourceByteOffset: $0.sourceByteOffset, sourceByteCount: $0.sourceByteCount,
                  role: $0.role, field: $0.field, relation: $0.relation)
        }
        let scalars = Scalars(proposal: interpretation), sources = ComputerUseBrowserSourceRequirements(proposal: interpretation)
        let unresolvedSources = Set(sources.unresolved.map(\.requirementID))
        let conditions = Dictionary(uniqueKeysWithValues: scalars.entries.map { ($0.requirementID, $0.resolution) })
        let pageIncomplete = reading.sourceTruncated || reading.omittedStructure || reading.omittedEmbeddedContent
            || reading.projectionOmittedRecords
        candidates = reading.candidates.enumerated().map { candidateIndex, candidate in
            let review = reading.review?.candidates[candidateIndex]
            let quotes = candidate.fields.enumerated().filter { [.price, .date, .quantity].contains($0.element.kind) }.map { fieldIndex, field -> Quote in
                let source = field.textIDs.compactMap { id in candidate.texts.first { $0.id == id }?.text }.joined(separator: "\n")
                return Quote(fieldIndex: fieldIndex, kind: field.kind, textIDs: field.textIDs, source: source, literal: Self.parse(source, kind: field.kind))
            }
            let incomplete = pageIncomplete || !candidate.unprojectedTextIDs.isEmpty || !candidate.unprojectedLinkIDs.isEmpty
            let evaluations = interpretation.requirements.map { requirement -> Evaluation in
                func result(_ status: Status, quotes: [Int] = []) -> Evaluation {
                    .init(requirementID: requirement.id, status: status, quoteIndices: quotes)
                }
                guard interpretation.disposition == .research else { return result(.uncompiledRequirement) }
                if case .clarification? = conditions[requirement.id] { return result(.clarificationApplied) }
                if unresolvedSources.contains(requirement.id) { return result(.uncompiledRequirement) }
                if requirement.field == .answerSource {
                    switch reading.documentAnswerSourceStatus {
                    case .unconfigured: return result(.sourceUnconfigured)
                    case .excluded: return result(.sourceOriginExcluded)
                    case .permitted: return result(.sourceOriginPermitted)
                    }
                }
                guard case .bound(let condition)? = conditions[requirement.id] else {
                    return result([.price, .date, .quantity].contains(requirement.field) ? .uncompiledRequirement : .needsSemanticVerification)
                }
                // The number of discovered cards is not the number of unique,
                // qualifying offers, nor evidence of inventory for a party.
                if case .quantity = condition.predicate { return result(.needsResultSet) }
                let kind: ComputerUseBrowserResultProposal.Kind
                switch condition.predicate { case .price: kind = .price; case .day: kind = .date; case .quantity: return result(.needsResultSet) }
                let indices = quotes.indices.filter { quotes[$0].kind == kind }
                guard !incomplete else { return result(.incompletePage, quotes: indices) }
                guard !indices.isEmpty else { return result(.missingQuote) }
                // Negative/uncertain semantic proposals prevent a numeric
                // match from hiding a known association concern. Positive
                // labels still establish only a quoted literal comparison.
                if let review {
                    guard review.association != .mixedOffers else { return result(.reviewMixedOffers, quotes: indices) }
                    guard review.association == .singleOffer else { return result(.reviewUnresolved, quotes: indices) }
                    let fields = indices.map { review.fields[quotes[$0].fieldIndex] }
                    if fields.contains(where: { $0.scope == .page }) { return result(.reviewPageContext, quotes: indices) }
                    if fields.contains(where: { $0.scope != .offer }) { return result(.reviewUnresolved, quotes: indices) }
                    if kind == .price {
                        if fields.contains(where: { $0.price == .qualified }) { return result(.reviewQualifiedPrice, quotes: indices) }
                        if fields.contains(where: { $0.price != .exact }) { return result(.reviewUnresolved, quotes: indices) }
                    }
                }
                guard indices.count == 1 else { return result(.ambiguousQuotes, quotes: indices) }
                guard let literal = quotes[indices[0]].literal else { return result(.unparsedQuote, quotes: indices) }
                switch condition.compareLiteral(literal) {
                case .satisfied: return result(.quotedValueMatches, quotes: indices)
                case .notSatisfied: return result(.quotedValueConflicts, quotes: indices)
                case .unverifiable: return result(.incompatibleLiteral, quotes: indices)
                }
            }
            return Candidate(candidateID: candidate.id, quotes: quotes, requirements: evaluations)
        }
    }

    /// Planning gets indices and existing text references, never native URLs,
    /// goal/session hashes, candidate authority or invented normalized prose.
    var plannerContext: [String: Any] {
        ["version":2,
         "requirements":requirements.enumerated().map { index, value in
             ["index":index, "turn":value.turn, "sourceByteOffset":value.sourceByteOffset, "sourceByteCount":value.sourceByteCount,
              "role":value.role.rawValue, "field":value.field.rawValue, "relation":value.relation.rawValue] as [String: Any]
         },
         "candidates":candidates.enumerated().map { index, candidate in
             ["index":index, "quotes":candidate.quotes.map {
                 ["field":$0.fieldIndex, "kind":$0.kind.rawValue, "texts":$0.textIDs, "parsed":$0.literal != nil] as [String: Any]
             }, "requirements":candidate.requirements.map(\.status.rawValue)] as [String: Any]
         }]
    }

    private static func parse(_ source: String, kind: ComputerUseBrowserResultProposal.Kind) -> Scalars.Literal? {
        let text = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        switch kind {
        case .price: return price(text)
        case .date: return day(text).map { .day($0) }
        case .quantity:
            guard let parts = groups(#"^([0-9]{1,3}) (results|options|flights|concerts|movies|tickets)$"#, text),
                  let count = Int64(parts[0]), let unit = Scalars.QuantityUnit(rawValue: parts[1].lowercased()) else { return nil }
            return .quantity(count, unit)
        default: return nil
        }
    }

    private static func groups(_ pattern: String, _ text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.range == NSRange(text.startIndex..., in: text) else { return nil }
        let string = text as NSString
        return (1..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : string.substring(with: match.range(at: $0)) }
    }

    private static func price(_ text: String) -> Scalars.Literal? {
        // Ranges, "from", crossed-out prices, approximate values, unresolved
        // qualifiers and extra prose cannot become exact prices by extraction.
        let pattern = #"^(?:Price: )?((?:USD|EUR|GBP|CAD|AUD|JPY)|[$€£¥])\s*((?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]{1,2})?)(?: (total|per person|per ticket))?(?: (including fees|excluding fees|including taxes and fees|excluding taxes and fees))?$"#
        guard let parts = groups(pattern, text), let currency = Scalars.Currency(rawValue: parts[0].uppercased()) else { return nil }
        let number = parts[1].replacingOccurrences(of: ",", with: "").split(separator: ".", omittingEmptySubsequences: false)
        guard let wholeText = number.first, wholeText.count <= 9, let whole = Int64(wholeText) else { return nil }
        let fraction = number.count == 2 ? String(number[1]) : ""
        guard let cents = Int64(fraction + String(repeating: "0", count: 2 - fraction.count)),
              let amount = Scalars.Amount(hundredths: whole * 100 + cents, currency: currency) else { return nil }
        let basis: Scalars.PriceBasis
        switch parts[2].lowercased() { case "total": basis = .total; case "per person": basis = .perPerson; case "per ticket": basis = .perTicket; default: basis = .unspecified }
        let fees: Scalars.Fees
        switch parts[3].lowercased() { case "including fees", "including taxes and fees": fees = .included
        case "excluding fees", "excluding taxes and fees": fees = .excluded; default: fees = .unspecified }
        return .price(amount, basis, fees)
    }

    private static func day(_ text: String) -> Scalars.CivilDay? {
        if let parts = groups(#"^(?:Date: )?([0-9]{4})-([0-9]{2})-([0-9]{2})$"#, text),
           let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) { return .init(year: year, month: month, day: day) }
        // Explicit English month names and four-digit years are unambiguous.
        // A page's "tomorrow" cannot use the user's original task clock: the
        // page has its own publication/time-zone context, still unresolved.
        let monthPattern = "(January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)"
        let months = ["jan":1, "feb":2, "mar":3, "apr":4, "may":5, "jun":6, "jul":7, "aug":8, "sep":9, "oct":10, "nov":11, "dec":12]
        if let parts = groups("^(?:Date: )?" + monthPattern + " ([0-9]{1,2}), ([0-9]{4})$", text),
           let month = months[String(parts[0].lowercased().prefix(3))], let day = Int(parts[1]), let year = Int(parts[2]) {
            return .init(year: year, month: month, day: day)
        }
        if let parts = groups("^(?:Date: )?([0-9]{1,2}) " + monthPattern + " ([0-9]{4})$", text),
           let day = Int(parts[0]), let month = months[String(parts[1].lowercased().prefix(3))], let year = Int(parts[2]) {
            return .init(year: year, month: month, day: day)
        }
        return nil
    }
    var description: String { "BrowserResultAssessment(requirements: \(requirements.count), candidates: \(candidates.count))" }
    var debugDescription: String { description }
}

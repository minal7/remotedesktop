import Foundation

/// A complete requirement ledger for one native-bound candidate reading.
/// Arithmetic/date matches are useful evidence, not proof of offer association
/// or whole-goal fulfillment. No completion flag or answer text is produced.
struct ComputerUseBrowserResultAssessment: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    typealias Scalars = ComputerUseBrowserScalarRequirements
    enum Status: String, Sendable {
        case needsSemanticVerification, needsResultSet, uncompiledRequirement, clarificationApplied
        case needsTicketInventory, needsPartyCapacity
        case reviewSelectedQuantity, reviewPurchaseLimit, reviewPackageSize, reviewQuantityUnresolved
        case quotedCapacitySufficient, quotedCapacityInsufficient
        case missingQuote, ambiguousQuotes, unparsedQuote
        case needsResultObservation, selectedValueConflicts, unparsedSelection, incompatibleSelection
        case quotedValueMatches, quotedValueConflicts, incompatibleLiteral
        case reviewMixedOffers, reviewUnresolved, reviewPageContext, reviewQualifiedPrice
        case reviewRequirementSupported, reviewRequirementConflict, reviewRequirementUnresolved
        case sourceOriginPermitted, sourceOriginExcluded, sourceUnconfigured, sourcePolicyMismatch, incompletePage
        case navigationHistoryUnverified
    }
    struct Requirement: Equatable, Sendable {
        let id: String
        let turn: Int
        let sourceByteOffset: Int
        let sourceByteCount: Int
        let role: ComputerUseBrowserGoalProposal.Role
        let field: ComputerUseBrowserGoalProposal.Field
        let relation: ComputerUseBrowserGoalProposal.Relation
        let quantityScope: Scalars.QuantityScope?
    }
    struct Quote: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let fieldIndex: Int
        let kind: ComputerUseBrowserResultProposal.Kind
        let textIDs: [String]
        let controlIDs: [String]
        let sourceKind: ComputerUseBrowserResultProposal.Field.SourceKind
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
        try reading.review?.validateInterpretation(interpretation)
        goalRevision = interpretation.input.digest; interpretationDigest = interpretation.digest
        readingIdentity = reading.requirementAssessmentIdentity
        let scalars = Scalars(proposal: interpretation), sources = ComputerUseBrowserSourceRequirements(proposal: interpretation)
        let unresolvedSources = Set(sources.unresolved.map(\.requirementID))
        let conditions = Dictionary(uniqueKeysWithValues: scalars.entries.map { ($0.requirementID, $0.resolution) })
        requirements = interpretation.requirements.map { requirement in
            let scope: Scalars.QuantityScope?
            if case .bound(let condition)? = conditions[requirement.id], case .quantity(_, _, let unit) = condition.predicate {
                scope = unit.scope
            } else { scope = nil }
            return .init(id: requirement.id, turn: requirement.sourceTurnIndex, sourceByteOffset: requirement.sourceByteOffset,
                sourceByteCount: requirement.sourceByteCount, role: requirement.role, field: requirement.field,
                relation: requirement.relation, quantityScope: scope)
        }
        let pageIncomplete = reading.sourceTruncated || reading.omittedStructure || reading.omittedEmbeddedContent
            || reading.projectionOmittedRecords
        candidates = reading.candidates.enumerated().map { candidateIndex, candidate in
            let review = reading.review?.candidates[candidateIndex]
            let quotes = candidate.fields.enumerated().filter { [.price, .date, .quantity].contains($0.element.kind) }.map { fieldIndex, field -> Quote in
                let source = candidate.source(for: field)
                return Quote(fieldIndex: fieldIndex, kind: field.kind, textIDs: field.textIDs, controlIDs: field.controlIDs,
                    sourceKind: field.sourceKind, source: source, literal: Self.parse(source, kind: field.kind))
            }
            let incomplete = pageIncomplete || !candidate.unprojectedTextIDs.isEmpty || !candidate.unprojectedLinkIDs.isEmpty || !candidate.unprojectedControlIDs.isEmpty
            let evaluations = interpretation.requirements.enumerated().map { requirementIndex, requirement -> Evaluation in
                func result(_ status: Status, quotes: [Int] = []) -> Evaluation {
                    .init(requirementID: requirement.id, status: status, quoteIndices: quotes)
                }
                guard interpretation.disposition == .research else { return result(.uncompiledRequirement) }
                if case .clarification? = conditions[requirement.id] { return result(.clarificationApplied) }
                if unresolvedSources.contains(requirement.id) { return result(.uncompiledRequirement) }
                // Page citations and the current source policy cannot prove
                // earlier automated visits. Retained constraints also apply
                // when a later interpretation changes this row's field.
                if sources.hasNavigationHistoryObligation(for: requirement.id) { return result(.navigationHistoryUnverified) }
                if sources.hasAnswerPolicyObligation(for: requirement.id), reading.documentAnswerSourceStatus != .unconfigured,
                   !reading.matchesAnswerSourceRequirements(sources) { return result(.sourcePolicyMismatch) }
                if requirement.field == .answerSource {
                    guard reading.documentAnswerSourceStatus != .unconfigured else { return result(.sourceUnconfigured) }
                    guard reading.matchesAnswerSourceRequirements(sources) else { return result(.sourcePolicyMismatch) }
                    switch reading.documentAnswerSourceStatus {
                    case .unconfigured: return result(.sourceUnconfigured)
                    case .excluded: return result(.sourceOriginExcluded)
                    case .permitted: return result(.sourceOriginPermitted)
                    }
                }
                let semantic = review?.requirements?[requirementIndex]
                let canReview = ComputerUseBrowserResultReviewInput.permitsCandidateJudgment(requirement)
                let semanticFailure: Status? = !canReview || semantic == nil || semantic?.judgment == .supports ? nil
                    : (semantic?.judgment == .conflicts ? .reviewRequirementConflict : .reviewRequirementUnresolved)
                guard case .bound(let condition)? = conditions[requirement.id] else {
                    if [.price, .date, .quantity].contains(requirement.field) { return result(.uncompiledRequirement) }
                    if let semanticFailure { return result(semanticFailure) }
                    // This is the reviewer's cited interpretation, not native
                    // verification of geography, availability or goal success.
                    return result(canReview && semantic?.judgment == .supports ? .reviewRequirementSupported : .needsSemanticVerification)
                }
                // The number of discovered cards is not the number of unique,
                // qualifying offers, nor evidence of inventory for a party.
                if case .quantity(_, _, let unit) = condition.predicate {
                    let indices = quotes.indices.filter { quotes[$0].kind == .quantity }
                    if unit.scope == .resultSet { return result(.needsResultSet) }
                    let pending: Status = unit.scope == .ticketInventory ? .needsTicketInventory : .needsPartyCapacity
                    guard !incomplete else { return result(.incompletePage, quotes: indices) }
                    guard let review, !indices.isEmpty else { return result(pending, quotes: indices) }
                    guard review.association != .mixedOffers else { return result(.reviewMixedOffers, quotes: indices) }
                    guard review.association == .singleOffer else { return result(.reviewUnresolved, quotes: indices) }
                    let available = indices.filter { review.fields[quotes[$0].fieldIndex].quantity == .availableQuantity }
                    if available.isEmpty {
                        let meanings = indices.map { review.fields[quotes[$0].fieldIndex].quantity }
                        if meanings.allSatisfy({ $0 == .selectedQuantity }) { return result(.reviewSelectedQuantity, quotes: indices) }
                        if meanings.allSatisfy({ $0 == .purchaseLimit }) { return result(.reviewPurchaseLimit, quotes: indices) }
                        if meanings.allSatisfy({ $0 == .packageSize }) { return result(.reviewPackageSize, quotes: indices) }
                        return result(.reviewQuantityUnresolved, quotes: indices)
                    }
                    // Do not discard another proposed capacity whose unit or
                    // complete literal cannot be parsed; it could conflict.
                    guard available.allSatisfy({ quotes[$0].literal != nil }) else { return result(.unparsedQuote, quotes: available) }
                    let matching = available.filter {
                        if case .quantity(_, let observedUnit)? = quotes[$0].literal { return observedUnit == unit }
                        return false
                    }
                    guard !matching.isEmpty else { return result(.incompatibleLiteral, quotes: available) }
                    guard matching.count == 1 else { return result(.ambiguousQuotes, quotes: matching) }
                    guard let literal = quotes[matching[0]].literal else { return result(.unparsedQuote, quotes: matching) }
                    switch condition.compareProposedCapacity(literal) {
                    case .satisfied: return result(.quotedCapacitySufficient, quotes: matching)
                    case .notSatisfied: return result(.quotedCapacityInsufficient, quotes: matching)
                    case .unverifiable: return result(pending, quotes: matching)
                    }
                }
                let kind: ComputerUseBrowserResultProposal.Kind
                switch condition.predicate { case .price: kind = .price; case .day: kind = .date; case .quantity: return result(.needsResultSet) }
                let allIndices = quotes.indices.filter { quotes[$0].kind == kind }
                let selections = allIndices.filter { quotes[$0].sourceKind != .pageText }
                let indices = allIndices.filter { quotes[$0].sourceKind == .pageText }
                guard !incomplete else { return result(.incompletePage, quotes: allIndices) }
                // A control records a setting, not the result of applying it.
                // Keep every selected value and check it separately; an equal
                // selection cannot replace a missing/conflicting result fact.
                if !selections.isEmpty {
                    guard let review else { return result(.reviewUnresolved, quotes: selections) }
                    guard review.association != .mixedOffers else { return result(.reviewMixedOffers, quotes: selections) }
                    guard review.association == .singleOffer else { return result(.reviewUnresolved, quotes: selections) }
                    let fields = selections.map { review.fields[quotes[$0].fieldIndex] }
                    if fields.contains(where: { $0.scope == .page }) { return result(.reviewPageContext, quotes: selections) }
                    guard fields.allSatisfy({ $0.scope == .offer }) else { return result(.reviewUnresolved, quotes: selections) }
                    guard selections.allSatisfy({ quotes[$0].sourceKind == .controlState && quotes[$0].literal != nil }) else {
                        return result(.unparsedSelection, quotes: selections)
                    }
                    for index in selections {
                        guard let literal = quotes[index].literal else { return result(.unparsedSelection, quotes: selections) }
                        switch condition.compareLiteral(literal) {
                        case .notSatisfied: return result(.selectedValueConflicts, quotes: selections)
                        case .unverifiable: return result(.incompatibleSelection, quotes: selections)
                        case .satisfied: break
                        }
                    }
                }
                guard !indices.isEmpty else { return result(selections.isEmpty ? .missingQuote : .needsResultObservation, quotes: selections) }
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
                if let semanticFailure { return result(semanticFailure, quotes: indices) }
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
        let navigationAssessment = requirements.contains { $0.field == .navigationSource }
            || candidates.contains { $0.requirements.contains { $0.status == .navigationHistoryUnverified } }
        let policyAssessment = requirements.contains { $0.field == .answerSource }
            || candidates.contains { $0.requirements.contains { $0.status == .sourcePolicyMismatch } }
        return ["version":navigationAssessment ? 6 : (policyAssessment ? 5 : (candidates.contains { $0.quotes.contains { !$0.controlIDs.isEmpty } } ? 4 : 3)),
         "requirements":requirements.enumerated().map { index, value in
             ["index":index, "turn":value.turn, "sourceByteOffset":value.sourceByteOffset, "sourceByteCount":value.sourceByteCount,
              "role":value.role.rawValue, "field":value.field.rawValue, "relation":value.relation.rawValue,
              "quantity_scope":value.quantityScope.map { $0.rawValue as Any } ?? NSNull()] as [String: Any]
         },
         "candidates":candidates.enumerated().map { index, candidate in
             ["index":index, "quotes":candidate.quotes.map {
                 ["field":$0.fieldIndex, "kind":$0.kind.rawValue, "texts":$0.textIDs, "controls":$0.controlIDs,
                  "source_kind":$0.sourceKind.rawValue, "parsed":$0.literal != nil] as [String: Any]
             }, "requirements":candidate.requirements.map(\.status.rawValue)] as [String: Any]
         }]
    }

    private static func parse(_ source: String, kind: ComputerUseBrowserResultProposal.Kind) -> Scalars.Literal? {
        let text = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        switch kind {
        case .price: return price(text)
        case .date: return day(text).map { .day($0) }
        case .quantity:
            guard let parts = groups(#"^([0-9]{1,3}) (results|options|flights|concerts|movies|tickets|people|adults|children)$"#, text),
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

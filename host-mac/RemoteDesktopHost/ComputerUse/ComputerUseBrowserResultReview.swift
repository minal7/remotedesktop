import Foundation

enum ComputerUseBrowserResultReviewError: Error, Equatable { case invalidInput, invalidProposal, inputChanged, contextLimit }

/// Complete goal and exact reading proposal, with only the existing bounded
/// page projection exposed to the model. Native destinations stay private.
struct ComputerUseBrowserResultReviewInput: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let goal: ComputerUseBrowserGoalInput
    private let page: ComputerUseBrowserResultPageInput
    private let selections: [ComputerUseBrowserResultProposal.Selection]
    let interpretation: ComputerUseBrowserGoalProposal?
    let contextJSON: String
    let textIDs: [String]
    private let candidateTextIDs: [Set<String>]
    let permitsOfferAssertions: Bool
    var candidateCount: Int { selections.count }
    var fieldCounts: [Int] { selections.map { $0.fields.count } }
    var requirementCount: Int { interpretation?.requirements.count ?? 0 }
    func fieldTextIDs(candidate: Int, field: Int) -> [String] { selections[candidate].fields[field].textIDs }
    func fieldAddressesRequirement(candidate: Int, field: Int, requirement: Int) -> Bool {
        guard let interpretation, interpretation.requirements.indices.contains(requirement),
              let kind = fieldKind(candidate: candidate, field: field) else { return false }
        switch interpretation.requirements[requirement].field {
        case .category: return [.title, .category].contains(kind)
        case .origin: return kind == .origin
        case .destination: return kind == .destination
        case .location: return kind == .location
        case .date: return kind == .date
        case .time: return kind == .time
        case .price: return kind == .price
        case .fees: return [.fees, .price].contains(kind)
        case .availability: return kind == .availability
        default: return false
        }
    }
    func permitsReference(_ id: String, for candidate: Int) -> Bool {
        !candidateTextIDs.enumerated().contains { $0.offset != candidate && $0.element.contains(id) }
    }
    static func permitsCandidateJudgment(_ requirement: ComputerUseBrowserGoalProposal.Requirement) -> Bool {
        [.outcome, .condition].contains(requirement.role)
            && [.category, .origin, .destination, .location, .date, .time, .price, .fees, .availability].contains(requirement.field)
    }
    func permitsCandidateJudgment(requirement: Int) -> Bool {
        guard let interpretation, interpretation.disposition == .research,
              interpretation.requirements.indices.contains(requirement) else { return false }
        return Self.permitsCandidateJudgment(interpretation.requirements[requirement])
    }
    func fieldKind(candidate: Int, field: Int) -> ComputerUseBrowserResultProposal.Kind? {
        guard selections.indices.contains(candidate), selections[candidate].fields.indices.contains(field) else { return nil }
        return selections[candidate].fields[field].kind
    }

    init(goal: ComputerUseBrowserGoalInput, page: ComputerUseBrowserResultPageInput, proposal: ComputerUseBrowserResultProposal,
         interpretation: ComputerUseBrowserGoalProposal? = nil) throws {
        try proposal.validateReviewInput(page: page, goal: goal)
        guard interpretation == nil || interpretation?.input == goal else { throw ComputerUseBrowserResultReviewError.inputChanged }
        self.interpretation = interpretation
        self.goal = goal; self.page = page; selections = proposal.selections
        candidateTextIDs = selections.map { page.projectedTextIDs(in: $0.containerID) }
        guard let projection = try JSONSerialization.jsonObject(with: Data(page.contextJSON.utf8)) as? [String: Any],
              let records = projection["records"] as? [[String: Any]] else { throw ComputerUseBrowserResultReviewError.invalidInput }
        textIDs = records.filter { $0["kind"] as? String == "text" }.compactMap { $0["id"] as? String }.sorted()
        permitsOfferAssertions = ["source_truncated", "omitted_embedded_content", "omitted_structure", "projection_omitted_records", "budget_omitted_records"]
            .allSatisfy { projection[$0] as? Bool == false }
        let candidates: [[String: Any]] = selections.enumerated().map { index, selection in
            ["index":index, "container":selection.containerID,
             "fields":selection.fields.enumerated().map {
                 ["index":$0.offset, "kind":$0.element.kind.rawValue, "texts":$0.element.textIDs] as [String: Any]
             }, "links":selection.linkIDs]
        }
        var context: [String: Any] = ["version":interpretation == nil ? 1 : 2, "goal":goal.plannerContext, "page":projection,
            "candidates":candidates, "offer_assertions_allowed":permitsOfferAssertions]
        if let interpretation {
            context["requirements"] = try interpretation.requirements.enumerated().map { index, requirement -> [String: Any] in
                guard let source = interpretation.source(of: requirement) else { throw ComputerUseBrowserResultReviewError.invalidInput }
                return ["index":index, "turn":requirement.sourceTurnIndex, "sourceByteOffset":requirement.sourceByteOffset,
                    "source":source, "role":requirement.role.rawValue, "field":requirement.field.rawValue,
                    "relation":requirement.relation.rawValue, "values":requirement.values,
                    "candidate_judgment_allowed":interpretation.disposition == .research && Self.permitsCandidateJudgment(requirement)]
            }
        }
        contextJSON = String(decoding: try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]), as: UTF8.self)
    }
    var description: String { "BrowserResultReviewInput(candidates: \(candidateCount))" }
    var debugDescription: String { description }
}

/// A model's semantic review, not a verified offer or completion certificate.
/// Every candidate/field is accounted for. No new fact text, URL, normalized
/// amount/date or extra field can enter through this response.
struct ComputerUseBrowserResultReview: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Association: String, CaseIterable, Sendable { case singleOffer, mixedOffers, unknown }
    enum Scope: String, CaseIterable, Sendable { case offer, page, unknown }
    enum Price: String, CaseIterable, Sendable { case exact, qualified, unknown, notPrice }
    enum Judgment: String, CaseIterable, Sendable { case supports, conflicts, unknown }
    struct Requirement: Equatable, Sendable {
        let judgment: Judgment
        let textIDs: [String]
    }
    struct Field: Equatable, Sendable {
        let scope: Scope
        let price: Price
        let qualifierTextIDs: [String]
    }
    struct Candidate: Equatable, Sendable {
        let association: Association
        let fields: [Field]
        let requirements: [Requirement]?
    }
    private let input: ComputerUseBrowserResultReviewInput
    let candidates: [Candidate]
    var hasRequirementMapping: Bool { input.interpretation != nil }
    private init(input: ComputerUseBrowserResultReviewInput, candidates: [Candidate]) { self.input = input; self.candidates = candidates }

    static func decode(content: String, input: ComputerUseBrowserResultReviewInput) throws -> Self {
        do {
            guard content.utf8.count <= 16 * 1_024 else { throw ComputerUseBrowserResultReviewError.invalidProposal }
            var parser = StrictSemanticJSONParser(content, maximumValueCount: 2_048)
            guard case .object(let root) = try parser.parse(), Set(root.keys) == ["candidates"],
                  case .array(let rows)? = root["candidates"], rows.count == input.candidateCount else { throw ComputerUseBrowserResultReviewError.invalidProposal }
            let observed = Set(input.textIDs)
            var candidates: [Candidate] = [], referenceCount = 0, requirementReferenceCount = 0
            for (index, row) in rows.enumerated() {
                let keys: Set<String> = input.interpretation == nil ? ["association", "fields"] : ["association", "fields", "requirements"]
                guard case .object(let candidate) = row, Set(candidate.keys) == keys,
                      case .string(let associationName)? = candidate["association"], let association = Association(rawValue: associationName),
                      input.permitsOfferAssertions || association != .singleOffer,
                      case .array(let fieldRows)? = candidate["fields"], fieldRows.count == input.fieldCounts[index] else { throw ComputerUseBrowserResultReviewError.invalidProposal }
                var fields: [Field] = []
                for (fieldIndex, row) in fieldRows.enumerated() {
                    guard case .object(let field) = row, Set(field.keys) == ["scope", "price", "qualifiers"],
                          case .string(let scopeName)? = field["scope"], let scope = Scope(rawValue: scopeName),
                          case .string(let priceName)? = field["price"], let price = Price(rawValue: priceName),
                          case .array(let references)? = field["qualifiers"], references.count <= 8,
                          let kind = input.fieldKind(candidate: index, field: fieldIndex) else { throw ComputerUseBrowserResultReviewError.invalidProposal }
                    guard scope != .offer || (association == .singleOffer && input.permitsOfferAssertions),
                          (kind == .price ? price != .notPrice : price == .notPrice),
                          price != .exact || (scope == .offer && association == .singleOffer) else { throw ComputerUseBrowserResultReviewError.invalidProposal }
                    if association == .singleOffer, kind == .title, scope != .offer { throw ComputerUseBrowserResultReviewError.invalidProposal }
                    var qualifiers: [String] = []
                    for reference in references {
                        guard case .string(let id) = reference, observed.contains(id), !qualifiers.contains(id) else { throw ComputerUseBrowserResultReviewError.invalidProposal }
                        qualifiers.append(id); referenceCount += 1
                    }
                    guard referenceCount <= 128, price != .qualified || !qualifiers.isEmpty else { throw ComputerUseBrowserResultReviewError.invalidProposal }
                    fields.append(.init(scope: scope, price: price, qualifierTextIDs: qualifiers))
                }
                var requirements: [Requirement]?
                if input.interpretation != nil {
                    guard case .array(let evaluations)? = candidate["requirements"], evaluations.count == input.requirementCount else {
                        throw ComputerUseBrowserResultReviewError.invalidProposal
                    }
                    requirements = try evaluations.enumerated().map { requirementIndex, value in
                        guard case .object(let item) = value, Set(item.keys) == ["requirement", "judgment", "texts"],
                              case .number(let number)? = item["requirement"], Int(exactly: number) == requirementIndex,
                              case .string(let name)? = item["judgment"], let judgment = Judgment(rawValue: name),
                              case .array(let references)? = item["texts"], references.count <= 8 else {
                            throw ComputerUseBrowserResultReviewError.invalidProposal
                        }
                        var ids: [String] = []
                        for reference in references {
                            guard case .string(let id) = reference, observed.contains(id), !ids.contains(id),
                                  input.permitsReference(id, for: index) else {
                                throw ComputerUseBrowserResultReviewError.invalidProposal
                            }
                            ids.append(id); requirementReferenceCount += 1
                        }
                        guard requirementReferenceCount <= 128,
                              judgment == .unknown || (!ids.isEmpty && input.permitsCandidateJudgment(requirement: requirementIndex)),
                              judgment != .supports || (input.permitsOfferAssertions && association == .singleOffer) else {
                            throw ComputerUseBrowserResultReviewError.invalidProposal
                        }
                        if judgment == .supports {
                            let selected = Set(ids)
                            // A favorable judgment must cite at least one
                            // whole offer-scoped field. A shared ancestor or
                            // a page-global price alone is not such evidence.
                            var hasOfferField = false
                            for (fieldIndex, field) in fields.enumerated() {
                                let fieldIDs = Set(input.fieldTextIDs(candidate: index, field: fieldIndex))
                                guard !selected.isDisjoint(with: fieldIDs) else { continue }
                                guard selected.isSuperset(of: fieldIDs) else { throw ComputerUseBrowserResultReviewError.invalidProposal }
                                if field.scope == .offer, input.fieldAddressesRequirement(candidate: index, field: fieldIndex, requirement: requirementIndex) {
                                    hasOfferField = true
                                }
                            }
                            guard hasOfferField else { throw ComputerUseBrowserResultReviewError.invalidProposal }
                        }
                        return Requirement(judgment: judgment, textIDs: ids)
                    }
                }
                candidates.append(.init(association: association, fields: fields, requirements: requirements))
            }
            return .init(input: input, candidates: candidates)
        } catch { throw ComputerUseBrowserResultReviewError.invalidProposal }
    }
    func validate(for input: ComputerUseBrowserResultReviewInput) throws {
        guard self.input == input else { throw ComputerUseBrowserResultReviewError.inputChanged }
    }
    func validateInterpretation(_ interpretation: ComputerUseBrowserGoalProposal) throws {
        guard input.interpretation == nil || input.interpretation == interpretation else {
            throw ComputerUseBrowserResultReviewError.inputChanged
        }
    }
    /// Native candidate identity includes the entire review. The private
    /// input is separately compared exactly before attaching the review.
    var digest: String {
        ComputerUseTaskContract.digest([hasRequirementMapping ? "browser-result-review-v2" : "browser-result-review-v1", input.contextJSON, String(candidates.count)]
            + candidates.flatMap { candidate in
                [candidate.association.rawValue, String(candidate.fields.count)] + candidate.fields.flatMap {
                    [$0.scope.rawValue, $0.price.rawValue, String($0.qualifierTextIDs.count)] + $0.qualifierTextIDs
                } + (candidate.requirements.map { ["requirements", String($0.count)] + $0.flatMap {
                    [$0.judgment.rawValue, String($0.textIDs.count)] + $0.textIDs
                } } ?? [])
            })
    }
    /// Indices follow the immutable reading's candidate and field order.
    var plannerContext: [[String: Any]] {
        candidates.map { candidate in
            var context: [String: Any] = ["association":candidate.association.rawValue, "fields":candidate.fields.map {
                ["scope":$0.scope.rawValue, "price":$0.price.rawValue, "qualifiers":$0.qualifierTextIDs] as [String: Any]
            }]
            if let requirements = candidate.requirements {
                context["requirements"] = requirements.enumerated().map {
                    ["requirement":$0.offset, "judgment":$0.element.judgment.rawValue, "texts":$0.element.textIDs] as [String: Any]
                }
            }
            return context
        }
    }
    var description: String { "BrowserResultReview(candidates: \(candidates.count))" }
    var debugDescription: String { description }
}

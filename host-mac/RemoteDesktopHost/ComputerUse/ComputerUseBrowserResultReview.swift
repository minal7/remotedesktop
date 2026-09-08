import Foundation

enum ComputerUseBrowserResultReviewError: Error, Equatable { case invalidInput, invalidProposal, inputChanged, contextLimit }

/// Complete goal and exact reading proposal, with only the existing bounded
/// page projection exposed to the model. Native destinations stay private.
struct ComputerUseBrowserResultReviewInput: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let goal: ComputerUseBrowserGoalInput
    private let page: ComputerUseBrowserResultPageInput
    private let selections: [ComputerUseBrowserResultProposal.Selection]
    let contextJSON: String
    let textIDs: [String]
    let permitsOfferAssertions: Bool
    var candidateCount: Int { selections.count }
    var fieldCounts: [Int] { selections.map { $0.fields.count } }
    func fieldKind(candidate: Int, field: Int) -> ComputerUseBrowserResultProposal.Kind? {
        guard selections.indices.contains(candidate), selections[candidate].fields.indices.contains(field) else { return nil }
        return selections[candidate].fields[field].kind
    }

    init(goal: ComputerUseBrowserGoalInput, page: ComputerUseBrowserResultPageInput, proposal: ComputerUseBrowserResultProposal) throws {
        try proposal.validateReviewInput(page: page, goal: goal)
        self.goal = goal; self.page = page; selections = proposal.selections
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
        let context: [String: Any] = ["version":1, "goal":goal.plannerContext, "page":projection,
            "candidates":candidates, "offer_assertions_allowed":permitsOfferAssertions]
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
    struct Field: Equatable, Sendable {
        let scope: Scope
        let price: Price
        let qualifierTextIDs: [String]
    }
    struct Candidate: Equatable, Sendable {
        let association: Association
        let fields: [Field]
    }
    private let input: ComputerUseBrowserResultReviewInput
    let candidates: [Candidate]
    private init(input: ComputerUseBrowserResultReviewInput, candidates: [Candidate]) { self.input = input; self.candidates = candidates }

    static func decode(content: String, input: ComputerUseBrowserResultReviewInput) throws -> Self {
        do {
            guard content.utf8.count <= 16 * 1_024 else { throw ComputerUseBrowserResultReviewError.invalidProposal }
            var parser = StrictSemanticJSONParser(content, maximumValueCount: 2_048)
            guard case .object(let root) = try parser.parse(), Set(root.keys) == ["candidates"],
                  case .array(let rows)? = root["candidates"], rows.count == input.candidateCount else { throw ComputerUseBrowserResultReviewError.invalidProposal }
            let observed = Set(input.textIDs)
            var candidates: [Candidate] = [], referenceCount = 0
            for (index, row) in rows.enumerated() {
                guard case .object(let candidate) = row, Set(candidate.keys) == ["association", "fields"],
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
                candidates.append(.init(association: association, fields: fields))
            }
            return .init(input: input, candidates: candidates)
        } catch { throw ComputerUseBrowserResultReviewError.invalidProposal }
    }
    func validate(for input: ComputerUseBrowserResultReviewInput) throws {
        guard self.input == input else { throw ComputerUseBrowserResultReviewError.inputChanged }
    }
    /// Native candidate identity includes the entire review. The private
    /// input is separately compared exactly before attaching the review.
    var digest: String {
        ComputerUseTaskContract.digest(["browser-result-review-v1", input.contextJSON, String(candidates.count)]
            + candidates.flatMap { candidate in
                [candidate.association.rawValue, String(candidate.fields.count)] + candidate.fields.flatMap {
                    [$0.scope.rawValue, $0.price.rawValue, String($0.qualifierTextIDs.count)] + $0.qualifierTextIDs
                }
            })
    }
    /// Indices follow the immutable reading's candidate and field order.
    var plannerContext: [[String: Any]] {
        candidates.map { candidate in
            ["association":candidate.association.rawValue, "fields":candidate.fields.map {
                ["scope":$0.scope.rawValue, "price":$0.price.rawValue, "qualifiers":$0.qualifierTextIDs] as [String: Any]
            }]
        }
    }
    var description: String { "BrowserResultReview(candidates: \(candidates.count))" }
    var debugDescription: String { description }
}

import Foundation

/// Output partitions over one immutable review. Every request still carries
/// the complete goal, page and candidate context; only its output is divided.
struct ComputerUseBrowserReviewPart: Equatable, Sendable {
    static let maximumOutputBytes = 896
    static let maximumParts = 32
    let input: ComputerUseBrowserResultReviewInput
    let candidate: Int
    let fields: [Int]
    let requirements: [Int]
    private init(input: ComputerUseBrowserResultReviewInput, candidate: Int, fields: [Int], requirements: [Int]) {
        self.input = input; self.candidate = candidate; self.fields = fields; self.requirements = requirements
    }

    var responseSchema: [String: Any] {
        func enumeration(_ values: [String]) -> [String: Any] { ["type":"string", "enum":values] }
        func index(_ values: [Int]) -> [String: Any] { values.isEmpty ? ["type":"integer"] : ["type":"integer", "enum":values] }
        let references: [String: Any] = ["type":"array", "maxItems":min(8, input.textIDs.count),
            "items":input.textIDs.isEmpty ? ["type":"string"] : enumeration(input.textIDs)]
        let field: [String: Any] = ["type":"object", "additionalProperties":false,
            "properties":["field":index(fields),
                "scope":enumeration(input.permitsOfferAssertions ? ["offer", "page", "unknown"] : ["page", "unknown"]),
                "price":enumeration(ComputerUseBrowserResultReview.Price.allCases.map(\.rawValue)), "qualifiers":references],
            "required":["field", "scope", "price", "qualifiers"]]
        let requirement: [String: Any] = ["type":"object", "additionalProperties":false,
            "properties":["requirement":index(requirements),
                "judgment":enumeration(input.permitsOfferAssertions ? ["supports", "conflicts", "unknown"] : ["conflicts", "unknown"]), "texts":references],
            "required":["requirement", "judgment", "texts"]]
        return ["type":"object", "additionalProperties":false,
            "properties":["candidate":index([candidate]),
                "association":enumeration(input.permitsOfferAssertions ? ["singleOffer", "mixedOffers", "unknown"] : ["mixedOffers", "unknown"]),
                "fields":["type":"array", "minItems":fields.count, "maxItems":fields.count, "items":field],
                "requirements":["type":"array", "minItems":requirements.count, "maxItems":requirements.count, "items":requirement]],
            "required":["candidate", "association", "fields", "requirements"]]
    }

    var contextJSON: String {
        get throws {
            guard var context = try JSONSerialization.jsonObject(with: Data(input.contextJSON.utf8)) as? [String: Any] else {
                throw ComputerUseBrowserResultReviewError.invalidInput
            }
            context["requested_output"] = ["candidate":candidate, "fields":fields, "requirements":requirements]
            return String(decoding: try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]), as: UTF8.self)
        }
    }

    /// Conservative canonical JSON size, not a tokenizer or latency proof.
    /// Use longest allowed enum spellings and eight longest observed IDs.
    private static func rowBounds(_ input: ComputerUseBrowserResultReviewInput) -> (field: [String: Any], requirement: [String: Any]) {
        let ids = Array(input.textIDs.sorted { $0.utf8.count > $1.utf8.count }.prefix(8))
        return (["scope":"unknown", "price":"qualified", "qualifiers":ids],
            ["requirement":31, "judgment":"conflicts", "texts":ids])
    }
    static func wholeOutputFits(_ input: ComputerUseBrowserResultReviewInput) throws -> Bool {
        let bounds = rowBounds(input)
        let rows: [[String: Any]] = input.fieldCounts.map { count in
            var value: [String: Any] = ["association":"mixedOffers", "fields":Array(repeating: bounds.field, count: count)]
            if input.interpretation != nil { value["requirements"] = Array(repeating: bounds.requirement, count: input.requirementCount) }
            return value
        }
        return try JSONSerialization.data(withJSONObject: ["candidates":rows]).count <= maximumOutputBytes
    }
    var maximumCanonicalOutputBytes: Int {
        get throws {
            let bounds = Self.rowBounds(input)
            let rows: [[String: Any]] = fields.map { index in var row = bounds.field; row["field"] = index; return row }
            let judgments: [[String: Any]] = requirements.map { index in var row = bounds.requirement; row["requirement"] = index; return row }
            return try JSONSerialization.data(withJSONObject: ["candidate":candidate, "association":"mixedOffers",
                "fields":rows, "requirements":judgments]).count
        }
    }
    static func plan(_ input: ComputerUseBrowserResultReviewInput) throws -> [Self] {
        var parts: [Self] = []
        for candidate in 0..<input.candidateCount {
            var field = 0, requirement = 0
            while field < input.fieldCounts[candidate] || requirement < input.requirementCount {
                var fields: [Int] = [], requirements: [Int] = [], preferField = true
                while fields.count < 4 || requirements.count < 4 {
                    let canField = field + fields.count < input.fieldCounts[candidate] && fields.count < 4
                    let canRequirement = requirement + requirements.count < input.requirementCount && requirements.count < 4
                    guard canField || canRequirement else { break }
                    let takeField = canField && (preferField || !canRequirement)
                    let nextFields = fields + (takeField ? [field + fields.count] : [])
                    let nextRequirements = requirements + (takeField ? [] : [requirement + requirements.count])
                    let next = Self(input: input, candidate: candidate, fields: nextFields, requirements: nextRequirements)
                    guard try next.maximumCanonicalOutputBytes <= maximumOutputBytes else { break }
                    fields = nextFields; requirements = nextRequirements; preferField = !takeField
                }
                guard !fields.isEmpty || !requirements.isEmpty, parts.count < maximumParts else {
                    throw ComputerUseBrowserResultReviewError.contextLimit
                }
                parts.append(.init(input: input, candidate: candidate, fields: fields, requirements: requirements))
                field += fields.count; requirement += requirements.count
            }
        }
        return parts
    }
}

/// A part cannot be used as a review. The complete assembler re-runs the
/// normal semantic/citation admission against the original input atomically.
struct ComputerUseBrowserReviewPartReply: Sendable {
    struct Field: Decodable, Sendable {
        let field: Int
        let scope: String
        let price: String
        let qualifiers: [String]
        var value: [String: Any] { ["scope":scope, "price":price, "qualifiers":qualifiers] }
    }
    struct Requirement: Decodable, Sendable {
        let requirement: Int
        let judgment: String
        let texts: [String]
        var value: [String: Any] { ["requirement":requirement, "judgment":judgment, "texts":texts] }
    }
    private struct Body: Decodable {
        let candidate: Int
        let association: String
        let fields: [Field]
        let requirements: [Requirement]
    }
    let part: ComputerUseBrowserReviewPart
    let association: String
    let fields: [Field]
    let requirements: [Requirement]
    private init(part: ComputerUseBrowserReviewPart, body: Body) {
        self.part = part; association = body.association; fields = body.fields; requirements = body.requirements
    }
    static func decode(_ content: String, part: ComputerUseBrowserReviewPart) throws -> Self {
        do {
            guard content.utf8.count <= 16 * 1_024 else { throw ComputerUseBrowserResultReviewError.invalidProposal }
            var parser = StrictSemanticJSONParser(content, maximumValueCount: 512)
            guard case .object(let root) = try parser.parse(), Set(root.keys) == ["candidate", "association", "fields", "requirements"],
                  case .array(let fields)? = root["fields"], fields.count == part.fields.count,
                  case .array(let requirements)? = root["requirements"], requirements.count == part.requirements.count else {
                throw ComputerUseBrowserResultReviewError.invalidProposal
            }
            for row in fields {
                guard case .object(let value) = row, Set(value.keys) == ["field", "scope", "price", "qualifiers"] else {
                    throw ComputerUseBrowserResultReviewError.invalidProposal
                }
            }
            for row in requirements {
                guard case .object(let value) = row, Set(value.keys) == ["requirement", "judgment", "texts"] else {
                    throw ComputerUseBrowserResultReviewError.invalidProposal
                }
            }
            let body = try JSONDecoder().decode(Body.self, from: Data(content.utf8)), observed = Set(part.input.textIDs)
            func valid(_ references: [String]) -> Bool {
                references.count <= 8 && Set(references).count == references.count && Set(references).isSubset(of: observed)
            }
            guard body.candidate == part.candidate, ComputerUseBrowserResultReview.Association(rawValue: body.association) != nil,
                  body.fields.map(\.field) == part.fields, body.requirements.map(\.requirement) == part.requirements,
                  body.fields.allSatisfy({ ComputerUseBrowserResultReview.Scope(rawValue: $0.scope) != nil
                    && ComputerUseBrowserResultReview.Price(rawValue: $0.price) != nil && valid($0.qualifiers) }),
                  body.requirements.allSatisfy({ ComputerUseBrowserResultReview.Judgment(rawValue: $0.judgment) != nil
                    && valid($0.texts) && $0.texts.allSatisfy { part.input.permitsReference($0, for: part.candidate) } }) else {
                throw ComputerUseBrowserResultReviewError.invalidProposal
            }
            return .init(part: part, body: body)
        } catch { throw ComputerUseBrowserResultReviewError.invalidProposal }
    }
}

struct ComputerUseBrowserReviewAssembly: Sendable {
    let input: ComputerUseBrowserResultReviewInput
    private let parts: [ComputerUseBrowserReviewPart]
    private var replies: [ComputerUseBrowserReviewPartReply] = []
    init(input: ComputerUseBrowserResultReviewInput, parts: [ComputerUseBrowserReviewPart]) throws {
        guard parts == (try ComputerUseBrowserReviewPart.plan(input)) else { throw ComputerUseBrowserResultReviewError.inputChanged }
        self.input = input; self.parts = parts
    }
    mutating func append(_ reply: ComputerUseBrowserReviewPartReply) throws {
        guard replies.count < parts.count, reply.part == parts[replies.count] else { throw ComputerUseBrowserResultReviewError.inputChanged }
        guard replies.filter({ $0.part.candidate == reply.part.candidate }).allSatisfy({ $0.association == reply.association }) else {
            throw ComputerUseBrowserResultReviewError.invalidProposal
        }
        replies.append(reply)
    }
    func completeContent() throws -> String {
        guard replies.count == parts.count else { throw ComputerUseBrowserResultReviewError.invalidProposal }
        var candidates: [[String: Any]] = []
        for candidate in 0..<input.candidateCount {
            let matching = replies.filter { $0.part.candidate == candidate }
            guard let first = matching.first else { throw ComputerUseBrowserResultReviewError.invalidProposal }
            let fields = matching.flatMap(\.fields), requirements = matching.flatMap(\.requirements)
            guard fields.map(\.field) == Array(0..<input.fieldCounts[candidate]),
                  requirements.map(\.requirement) == Array(0..<input.requirementCount) else {
                throw ComputerUseBrowserResultReviewError.invalidProposal
            }
            var value: [String: Any] = ["association":first.association, "fields":fields.map(\.value)]
            if input.interpretation != nil { value["requirements"] = requirements.map(\.value) }
            candidates.append(value)
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["candidates":candidates], options: [.sortedKeys]), as: UTF8.self)
    }
}

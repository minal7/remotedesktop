import Foundation

public enum AgentContractError: Error, Equatable {
    case invalid(String)
}

struct AgentCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension KeyedDecodingContainer where Key == AgentCodingKey {
    func requireKeys(_ required: Set<String>, optional: Set<String> = []) throws {
        let allowed = required.union(optional)
        let actual = Set(allKeys.map(\.stringValue))
        let missing = required.subtracting(actual)
        let unknown = actual.subtracting(allowed)
        guard missing.isEmpty, unknown.isEmpty else {
            throw AgentContractError.invalid("Object keys differ; missing: \(missing.sorted()), unknown: \(unknown.sorted())")
        }
    }

    func decodeRequired<T: Decodable>(_ type: T.Type, _ key: String) throws -> T {
        try decode(type, forKey: AgentCodingKey(key))
    }

    func decodeNullable<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? {
        let codingKey = AgentCodingKey(key)
        return try decodeNil(forKey: codingKey) ? nil : decode(type, forKey: codingKey)
    }

    func decodeOptionalValue<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? {
        let codingKey = AgentCodingKey(key)
        guard contains(codingKey) else { return nil }
        guard try !decodeNil(forKey: codingKey) else {
            throw AgentContractError.invalid("\(key) must be omitted or contain a value, not null")
        }
        return try decode(type, forKey: codingKey)
    }
}

extension KeyedEncodingContainer where Key == AgentCodingKey {
    mutating func encodeRequired<T: Encodable>(_ value: T, _ key: String) throws {
        try encode(value, forKey: AgentCodingKey(key))
    }

    mutating func encodeNullable<T: Encodable>(_ value: T?, _ key: String) throws {
        let codingKey = AgentCodingKey(key)
        if let value { try encode(value, forKey: codingKey) }
        else { try encodeNil(forKey: codingKey) }
    }
}

enum AgentContractValidation {
    static func require(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
        guard condition() else { throw AgentContractError.invalid(reason) }
    }

    static func requireNonEmpty(_ value: String, _ field: String) throws {
        try require(!value.isEmpty, "\(field) must not be empty")
    }

    static func requireFinite(_ value: Double, _ field: String) throws {
        try require(value.isFinite, "\(field) must be finite")
    }

    static func isAbsoluteURI(_ value: String) -> Bool {
        guard let expression = try? NSRegularExpression(
            pattern: #"^[A-Za-z][A-Za-z0-9+.-]*:(?:[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=-]|%[0-9A-Fa-f]{2})*$"#) else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return expression.firstMatch(in: value, range: range)?.range == range
            && URLComponents(string: value)?.url != nil
    }

    static func isSecureRoleOrState(role: String, state: [String]) -> Bool {
        let exact = Set([
            "password", "passwordfield", "passwordtextfield", "secure", "securefield", "securetextfield",
            "axsecuretextfield", "otp", "onetimecode", "verificationcode", "secret", "credential", "sensitive"
        ])
        let markers = Set(["password", "secure", "otp", "secret", "credential", "sensitive"])
        return ([role] + state).contains { value in
            let normalized = value.lowercased().filter { $0.isLetter || $0.isNumber }
            if exact.contains(normalized) || normalized.hasSuffix("securetextfield") || normalized.hasPrefix("axsecure") {
                return true
            }
            let words = secureTokens(in: value)
            return !words.isDisjoint(with: markers)
        }
    }

    private static func secureTokens(in value: String) -> Set<String> {
        guard let expression = try? NSRegularExpression(pattern: #"[A-Z]+(?=[A-Z][a-z]|\b)|[A-Z]?[a-z]+|\d+"#) else { return [] }
        let searchRange = NSRange(value.startIndex..., in: value)
        return Set(expression.matches(in: value, range: searchRange).compactMap { match in
            guard let range = Range(match.range, in: value) else { return nil }
            return String(value[range]).lowercased()
        })
    }
}

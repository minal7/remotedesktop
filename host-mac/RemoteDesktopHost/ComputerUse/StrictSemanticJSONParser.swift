import Foundation

struct StrictSemanticJSONParser {
    static let maximumNestingDepth = 12
    static let defaultMaximumValueCount = 256

    private let bytes: [UInt8]
    private let maximumValueCount: Int
    private var index = 0
    private var valueCount = 0

    init(
        _ source: String,
        maximumValueCount: Int = Self.defaultMaximumValueCount
    ) {
        bytes = Array(source.utf8)
        self.maximumValueCount = max(1, maximumValueCount)
    }

    mutating func parse() throws -> MCPJSONValue {
        skipWhitespace()
        let result = try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw ParserError.invalidJSON }
        return result
    }

    private mutating func parseValue(depth: Int) throws -> MCPJSONValue {
        guard depth <= Self.maximumNestingDepth, index < bytes.count else {
            throw ParserError.invalidJSON
        }
        valueCount += 1
        guard valueCount <= maximumValueCount else {
            throw ParserError.invalidJSON
        }
        switch bytes[index] {
        case 0x7B: return try parseObject(depth: depth + 1) // {
        case 0x5B: return try parseArray(depth: depth + 1)  // [
        case 0x22: return .string(try parseString())
        case 0x74:
            try consumeLiteral("true")
            return .bool(true)
        case 0x66:
            try consumeLiteral("false")
            return .bool(false)
        case 0x6E:
            try consumeLiteral("null")
            return .null
        case 0x2D, 0x30 ... 0x39:
            return try parseNumber()
        default:
            throw ParserError.invalidJSON
        }
    }

    private mutating func parseObject(depth: Int) throws -> MCPJSONValue {
        index += 1
        skipWhitespace()
        var result: [String: MCPJSONValue] = [:]
        var keys: Set<String> = []
        if consume(0x7D) { return .object(result) }
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw ParserError.invalidJSON
            }
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw ParserError.duplicateKey
            }
            skipWhitespace()
            guard consume(0x3A) else { throw ParserError.invalidJSON } // :
            skipWhitespace()
            result[key] = try parseValue(depth: depth)
            skipWhitespace()
            if consume(0x7D) { return .object(result) }
            guard consume(0x2C) else { throw ParserError.invalidJSON } // ,
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int) throws -> MCPJSONValue {
        index += 1
        skipWhitespace()
        var result: [MCPJSONValue] = []
        if consume(0x5D) { return .array(result) }
        while true {
            result.append(try parseValue(depth: depth))
            skipWhitespace()
            if consume(0x5D) { return .array(result) }
            guard consume(0x2C) else { throw ParserError.invalidJSON }
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        guard consume(0x22) else { throw ParserError.invalidJSON }
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if escaped {
                escaped = false
                index += 1
                continue
            }
            if byte == 0x5C { // backslash
                escaped = true
                index += 1
                continue
            }
            guard byte >= 0x20 else { throw ParserError.invalidJSON }
            index += 1
            if byte == 0x22 {
                let data = Data(bytes[start ..< index])
                guard let value = try? JSONDecoder().decode(
                    String.self, from: data) else {
                    throw ParserError.invalidJSON
                }
                return value
            }
        }
        throw ParserError.invalidJSON
    }

    private mutating func parseNumber() throws -> MCPJSONValue {
        let start = index
        _ = consume(0x2D)
        guard index < bytes.count else { throw ParserError.invalidJSON }
        if consume(0x30) {
            if index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) {
                throw ParserError.invalidJSON
            }
        } else {
            guard consumeDigit(range: 0x31 ... 0x39) else {
                throw ParserError.invalidJSON
            }
            while consumeDigit(range: 0x30 ... 0x39) {}
        }
        var isInteger = true
        if consume(0x2E) {
            isInteger = false
            guard consumeDigit(range: 0x30 ... 0x39) else {
                throw ParserError.invalidJSON
            }
            while consumeDigit(range: 0x30 ... 0x39) {}
        }
        if consume(0x65) || consume(0x45) {
            isInteger = false
            _ = consume(0x2B) || consume(0x2D)
            guard consumeDigit(range: 0x30 ... 0x39) else {
                throw ParserError.invalidJSON
            }
            while consumeDigit(range: 0x30 ... 0x39) {}
        }
        guard let raw = String(bytes: bytes[start ..< index], encoding: .utf8) else {
            throw ParserError.invalidJSON
        }
        if isInteger, let value = Int(raw) { return .integer(value) }
        guard let value = Double(raw), value.isFinite else {
            throw ParserError.invalidJSON
        }
        return .double(value)
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard bytes[index...].starts(with: expected) else {
            throw ParserError.invalidJSON
        }
        index += expected.count
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func consumeDigit(
        range: ClosedRange<UInt8>
    ) -> Bool {
        guard index < bytes.count, range.contains(bytes[index]) else {
            return false
        }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count,
              bytes[index] == 0x20 || bytes[index] == 0x09
                || bytes[index] == 0x0A || bytes[index] == 0x0D {
            index += 1
        }
    }

    private enum ParserError: Error {
        case invalidJSON
        case duplicateKey
    }
}

import Foundation

/// Owner-selected memory behavior for one computer-use task. This transport
/// metadata is never included in the model-facing prompt.
public struct ComputerUseTaskMemoryPolicy: Codable, Equatable, Sendable {
    public let noMemory: Bool
    public let incognito: Bool
    public let pauseLearning: Bool

    public init(noMemory: Bool = false, incognito: Bool = false, pauseLearning: Bool = false) {
        self.noMemory = noMemory
        self.incognito = incognito
        self.pauseLearning = pauseLearning
    }

    public var isEmpty: Bool { !noMemory && !incognito && !pauseLearning }

    private struct AnyKey: CodingKey, Hashable {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: AnyKey.self)
        let allowed: Set<String> = ["noMemory", "incognito", "pauseLearning"]
        guard Set(values.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Unknown task memory policy field"))
        }
        let noMemoryKey = AnyKey(stringValue: "noMemory")!
        let incognitoKey = AnyKey(stringValue: "incognito")!
        let pauseLearningKey = AnyKey(stringValue: "pauseLearning")!
        noMemory = values.contains(noMemoryKey) ? try values.decode(Bool.self, forKey: noMemoryKey) : false
        incognito = values.contains(incognitoKey) ? try values.decode(Bool.self, forKey: incognitoKey) : false
        pauseLearning = values.contains(pauseLearningKey) ? try values.decode(Bool.self, forKey: pauseLearningKey) : false
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: AnyKey.self)
        try values.encode(noMemory, forKey: AnyKey(stringValue: "noMemory")!)
        try values.encode(incognito, forKey: AnyKey(stringValue: "incognito")!)
        try values.encode(pauseLearning, forKey: AnyKey(stringValue: "pauseLearning")!)
    }
}

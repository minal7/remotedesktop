import Foundation

/// Provenance is persisted metadata only. It does not prove an authenticated owner write.
public struct MemoryProvenance: Sendable, Equatable {
    public let sourceMessageID: String?
    public let proposalID: String?
    public let statementID: String?
    public let candidateOrigin: String?
    public let sourceReference: String?
    public let sourceSpan: String?

    public init(sourceMessageID: String? = nil, proposalID: String? = nil, statementID: String? = nil,
                candidateOrigin: String? = nil, sourceReference: String? = nil, sourceSpan: String? = nil) {
        self.sourceMessageID = sourceMessageID
        self.proposalID = proposalID
        self.statementID = statementID
        self.candidateOrigin = candidateOrigin
        self.sourceReference = sourceReference
        self.sourceSpan = sourceSpan
    }
}

/// Database DTO for the isolated store. A future authenticated host writer must validate authority.
public struct MemoryRecord: Sendable, Equatable {
    public let id: String
    public let kind: MemoryKind
    public let body: String
    public let source: MemorySource
    public let observedAt: Int64
    public let active: Bool
    public let confidence: Double
    public let provenance: MemoryProvenance

    public init(id: String, kind: MemoryKind, body: String, source: MemorySource,
                observedAt: Int64, active: Bool = true, confidence: Double = 1,
                provenance: MemoryProvenance = MemoryProvenance()) {
        self.id = id; self.kind = kind; self.body = body; self.source = source
        self.observedAt = observedAt; self.active = active; self.confidence = confidence
        self.provenance = provenance
    }
}

public struct MemoryMatch: Sendable, Equatable {
    public let record: MemoryRecord
    public let rank: Double
}

public struct MemoryRecordPage: Sendable, Equatable {
    public let records: [MemoryRecord]
    public let nextRecordID: String?

    public init(records: [MemoryRecord], nextRecordID: String?) {
        self.records = records
        self.nextRecordID = nextRecordID
    }
}

public enum VaultCardBrand: String, Sendable, CaseIterable {
    case visa = "Visa", mastercard = "Mastercard", amex = "American Express", discover = "Discover"
}

public enum VaultDisplayLabel: String, Sendable, CaseIterable {
    case homeAddress = "Home address"
    case workAddress = "Work address"
    case mobilePhone = "Mobile phone"
    case membership = "Membership card"
    case identityDocument = "Identity document"
}

/// Constrained metadata only; there is no initializer accepting a caller-provided display string.
public struct VaultHandleDisplay: Sendable, Equatable {
    public let id: UUID
    public let displayText: String

    private init(id: UUID, displayText: String) { self.id = id; self.displayText = displayText }

    public static func card(id: UUID = UUID(), brand: VaultCardBrand, last4: String,
                            expirationMonth: Int, expirationYear: Int) throws -> Self {
        guard last4.utf8.count == 4, last4.utf8.allSatisfy({ (48...57).contains($0) }),
              (1...12).contains(expirationMonth), (2000...2200).contains(expirationYear) else {
            throw MemoryStoreError.invalidInput
        }
        return Self(id: id, displayText: "\(brand.rawValue) ending in \(last4), expires \(String(format: "%02d", expirationMonth))/\(expirationYear)")
    }

    public static func labeled(id: UUID = UUID(), label: VaultDisplayLabel) -> Self {
        Self(id: id, displayText: label.rawValue)
    }
}

import Foundation
import CryptoKit

/// Closed typed payloads for an explicit owner entry. Values are redacted and cannot be encoded.
/// The host must obtain any required biometric approval and quiescence before calling the service.
public enum OwnerVaultEntryPayload: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case paymentCard(brand: VaultCardBrand, holderName: VaultSecretValue,
                     number: VaultSecretValue, expiryMonth: Int, expiryYear: Int)
    case address(label: VaultDisplayLabel, line1: VaultSecretValue, line2: VaultSecretValue?,
                 city: VaultSecretValue, region: VaultSecretValue?, postalCode: VaultSecretValue?,
                 country: VaultSecretValue)
    case phone(VaultSecretValue)
    case membership(VaultSecretValue)
    case identity(name: VaultSecretValue, number: VaultSecretValue, expiry: VaultSecretValue?)

    var kind: OwnerVaultEntryKind {
        switch self {
        case .paymentCard: .paymentCard
        case .address: .address
        case .phone: .phone
        case .membership: .membership
        case .identity: .identity
        }
    }

    public var description: String { "<owner-vault-entry-payload>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: [(label: "kind", value: kind.rawValue)], displayStyle: .enum)
    }
}

public enum OwnerVaultEntryKind: String, Codable, Equatable, Sendable {
    case paymentCard, address, phone, membership, identity
}

public enum VaultEntryCreationState: String, Codable, Equatable, Sendable {
    case pending, completed
}

public struct VaultEntryReceipt: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let commandID: UUID
    public let itemID: UUID
    public let kind: OwnerVaultEntryKind
    public let displayText: String

    public var description: String { "<vault-entry-receipt>" }
    public var debugDescription: String { description }
}

public struct VaultEntryStatus: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let commandID: UUID
    public let itemID: UUID
    public let kind: OwnerVaultEntryKind
    public let state: VaultEntryCreationState
    public let displayText: String?

    public var description: String { "<vault-entry-status>" }
    public var debugDescription: String { description }
}

public enum VaultEntryError: Error, Equatable {
    case disabled, unauthorized, incognito, invalidPayload, commandReserved, notFound, incomplete, forgotten
}

struct VaultCreateReservation {
    let itemID: UUID
    let kind: OwnerVaultEntryKind
    let state: VaultEntryCreationState
    let displayText: String?
}

private struct OwnerVaultEntryField {
    let field: VaultSecretField
    let value: VaultSecretValue
}

private struct ValidatedOwnerVaultEntry {
    let kind: OwnerVaultEntryKind
    let displayLabel: VaultDisplayLabel?
    let cardBrand: VaultCardBrand?
    let lastFour: String?
    let month: Int?
    let year: Int?
    let fields: [OwnerVaultEntryField]
}

private extension OwnerVaultEntryPayload {
    func validateForStorage() throws -> ValidatedOwnerVaultEntry {
        switch self {
        case let .paymentCard(brand, holder, number, month, year):
            _ = try checkedText(holder, max: 120)
            let numberText = try number.withCheckedString(max: 19, minimum: 12,
                allowed: { $0.utf8.allSatisfy { (48...57).contains($0) } })
            guard (1...12).contains(month), (2000...2200).contains(year),
                  cardMatches(brand, numberText), luhn(numberText) else { throw VaultEntryError.invalidPayload }
            let monthValue = try VaultSecretValue(String(format: "%02d", month))
            let yearValue = try VaultSecretValue(String(year))
            return ValidatedOwnerVaultEntry(kind: .paymentCard, displayLabel: nil, cardBrand: brand,
                lastFour: String(numberText.suffix(4)), month: month, year: year,
                fields: [OwnerVaultEntryField(field: .cardholderName, value: holder),
                         OwnerVaultEntryField(field: .cardNumber, value: number),
                         OwnerVaultEntryField(field: .cardExpiryMonth, value: monthValue),
                         OwnerVaultEntryField(field: .cardExpiryYear, value: yearValue)])
        case let .address(label, line1, line2, city, region, postalCode, country):
            guard label == .homeAddress || label == .workAddress else { throw VaultEntryError.invalidPayload }
            _ = try checkedText(line1, max: 160); _ = try checkedText(city, max: 100)
            _ = try checkedText(country, max: 2)
            _ = try country.withCheckedString(max: 2, minimum: 2,
                allowed: { $0.utf8.allSatisfy { (65...90).contains($0) } })
            if let line2 { _ = try checkedText(line2, max: 160) }
            if let region { _ = try checkedText(region, max: 100) }
            if let postalCode { _ = try checkedText(postalCode, max: 32) }
            var fields = [OwnerVaultEntryField(field: .addressLine1, value: line1),
                          OwnerVaultEntryField(field: .addressCity, value: city),
                          OwnerVaultEntryField(field: .addressCountry, value: country)]
            if let line2 { fields.append(OwnerVaultEntryField(field: .addressLine2, value: line2)) }
            if let region { fields.append(OwnerVaultEntryField(field: .addressRegion, value: region)) }
            if let postalCode { fields.append(OwnerVaultEntryField(field: .addressPostalCode, value: postalCode)) }
            return ValidatedOwnerVaultEntry(kind: .address, displayLabel: label, cardBrand: nil,
                lastFour: nil, month: nil, year: nil, fields: fields)
        case let .phone(value):
            let text = try value.withCheckedString(max: 32, minimum: 7,
                allowed: { $0.utf8.allSatisfy { (48...57).contains($0) || [43, 40, 41, 45, 32].contains($0) } })
            guard text.filter({ $0.isNumber }).count >= 7 else { throw VaultEntryError.invalidPayload }
            return ValidatedOwnerVaultEntry(kind: .phone, displayLabel: .mobilePhone, cardBrand: nil,
                lastFour: nil, month: nil, year: nil,
                fields: [OwnerVaultEntryField(field: .phoneNumber, value: value)])
        case let .membership(value):
            _ = try checkedText(value, max: 128)
            return ValidatedOwnerVaultEntry(kind: .membership, displayLabel: .membership,
                cardBrand: nil, lastFour: nil, month: nil, year: nil,
                fields: [OwnerVaultEntryField(field: .membershipNumber, value: value)])
        case let .identity(name, number, expiry):
            _ = try checkedText(name, max: 120); _ = try checkedText(number, max: 64)
            if let expiry { _ = try checkedText(expiry, max: 32) }
            var fields = [OwnerVaultEntryField(field: .identityName, value: name),
                          OwnerVaultEntryField(field: .identityNumber, value: number)]
            if let expiry { fields.append(OwnerVaultEntryField(field: .identityExpiry, value: expiry)) }
            return ValidatedOwnerVaultEntry(kind: .identity, displayLabel: .identityDocument,
                cardBrand: nil, lastFour: nil, month: nil, year: nil, fields: fields)
        }
    }
}

private extension VaultSecretValue {
    func withCheckedString(max: Int, minimum: Int = 1,
                           allowed: (String) -> Bool = { _ in true }) throws -> String {
        var result: String?
        withString { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, value.utf8.count <= max,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  allowed(value), value.utf8.count >= minimum else { return }
            result = value
        }
        guard let result else { throw VaultEntryError.invalidPayload }
        return result
    }
}

private func checkedText(_ value: VaultSecretValue, max: Int) throws -> String {
    try value.withCheckedString(max: max)
}

private func cardMatches(_ brand: VaultCardBrand, _ digits: String) -> Bool {
    switch brand {
    case .visa: return digits.hasPrefix("4") && (12...19).contains(digits.count)
    case .mastercard:
        guard digits.count == 16, let prefix = Int(digits.prefix(2)) else { return false }
        return (51...55).contains(prefix) || (digits.count >= 4 && Int(digits.prefix(4)).map { (2221...2720).contains($0) } == true)
    case .amex: return digits.count == 15 && (digits.hasPrefix("34") || digits.hasPrefix("37"))
    case .discover: return digits.count == 16 && (digits.hasPrefix("6011") || digits.hasPrefix("65"))
    }
}

private func luhn(_ value: String) -> Bool {
    var sum = 0
    for (offset, byte) in value.utf8.reversed().enumerated() {
        var digit = Int(byte - 48)
        if offset % 2 == 1 { digit *= 2; if digit > 9 { digit -= 9 } }
        sum += digit
    }
    return sum % 10 == 0
}

extension PersonalMemoryService {
    public func createVaultEntry(commandID: UUID, payload: OwnerVaultEntryPayload,
                                 context: OwnerMemoryContext) throws -> VaultEntryReceipt {
        guard Self.validOwnerContext(context) else { throw VaultEntryError.unauthorized }
        let validated: ValidatedOwnerVaultEntry
        do { validated = try payload.validateForStorage() }
        catch { throw VaultEntryError.invalidPayload }
        let key = Self.vaultCreateCommandKey(ownerID: context.ownerID, commandID: commandID)
        let itemID = UUID()
        do {
            return try vaultLease.withExclusive {
                try writer.withVaultEntryOperation(context: context) { revalidate in
                    try revalidate()
                    do { try store.reserveVaultCreate(commandKey: key, ownerID: context.ownerID,
                        itemID: itemID, kind: validated.kind) }
                    catch { throw Self.vaultEntryError(error) }
                    let vault = KeychainVault(client: keychainClient, namespace: keychainNamespace)
                    for field in validated.fields {
                        try revalidate()
                        do { try vault.store(field.value, for: VaultItemID(uuid: itemID), field: field.field) }
                        catch { throw VaultEntryError.incomplete }
                        try revalidate()
                    }
                    try revalidate()
                    let display = try Self.vaultEntryDisplay(validated, itemID: itemID)
                    do { try store.completeVaultCreate(commandKey: key, ownerID: context.ownerID,
                        itemID: itemID, displayText: display) }
                    catch { throw Self.vaultEntryError(error) }
                    try revalidate()
                    return VaultEntryReceipt(commandID: commandID, itemID: itemID,
                        kind: validated.kind, displayText: display)
                }
            }
        } catch let error as VaultEntryError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw Self.vaultEntryError(error) }
    }

    public func vaultEntryCreationStatus(commandID: UUID,
                                         context: OwnerMemoryContext) throws -> VaultEntryStatus {
        guard Self.validOwnerContext(context) else { throw VaultEntryError.unauthorized }
        let key = Self.vaultCreateCommandKey(ownerID: context.ownerID, commandID: commandID)
        do {
            return try writer.withVaultEntryStatus(context: context) {
                let stored: VaultCreateReservation
                do { stored = try store.vaultCreateStatus(commandKey: key, ownerID: context.ownerID) }
                catch MemoryStoreError.recordNotFound { throw VaultEntryError.notFound }
                catch { throw Self.vaultEntryError(error) }
                return VaultEntryStatus(commandID: commandID, itemID: stored.itemID,
                    kind: stored.kind, state: stored.state, displayText: stored.displayText)
            }
        } catch let error as VaultEntryError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw Self.vaultEntryError(error) }
    }

    private static func vaultCreateCommandKey(ownerID: String, commandID: UUID) -> String {
        let bytes = Data((ownerID + "\u{0}" + commandID.uuidString.lowercased()).utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func validOwnerContext(_ context: OwnerMemoryContext) -> Bool {
        !context.ownerID.isEmpty && context.ownerID.utf8.count <= 256
            && !context.ownerID.utf8.contains(0)
            && !context.sessionID.isEmpty && context.sessionID.utf8.count <= 256
            && !context.sessionID.utf8.contains(0)
            && (context.taskID.map { !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0) } ?? true)
    }

    private static func vaultEntryDisplay(_ entry: ValidatedOwnerVaultEntry, itemID: UUID) throws -> String {
        if let brand = entry.cardBrand, let lastFour = entry.lastFour,
           let month = entry.month, let year = entry.year {
            return try VaultHandleDisplay.card(id: itemID, brand: brand, last4: lastFour,
                expirationMonth: month, expirationYear: year).displayText
        }
        guard let label = entry.displayLabel else { throw VaultEntryError.invalidPayload }
        return VaultHandleDisplay.labeled(id: itemID, label: label).displayText
    }

    private static func vaultEntryError(_ error: Error) -> VaultEntryError {
        if let writerError = error as? OwnerMemoryWriterError {
            switch writerError {
            case .disabled: return .disabled
            case .incognito: return .incognito
            case .unauthorized, .inactiveTask: return .unauthorized
            case .noMemory: return .incomplete
            case .forgotten, .forgetReentrant: return .forgotten
            default: return .incomplete
            }
        }
        if let storeError = error as? MemoryStoreError {
            switch storeError {
            case .disabled: return .disabled
            case .commandConflict: return .commandReserved
            case .recordNotFound: return .notFound
            case .erasurePending, .closed: return .forgotten
            default: return .incomplete
            }
        }
        return .incomplete
    }
}

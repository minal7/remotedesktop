import Foundation

/// Host-owned task evidence. Module-internal until the authenticated broker mints it; intent is
/// metadata and is not itself proof of identity or authority.
struct VaultFillOwnerTaskAuthority: Sendable {
    let ownerID: String
    let sessionID: String
    let taskID: String
    let revision: Int64
    let intent: VaultFillTaskIntent

    init(ownerID: String, sessionID: String, taskID: String, revision: Int64,
         intent: VaultFillTaskIntent) {
        self.ownerID = ownerID; self.sessionID = sessionID; self.taskID = taskID
        self.revision = revision; self.intent = intent
    }
}

enum VaultFillTaskIntent: Sendable {
    case ownerTaskExplicitlyRequestedFill
    case pageRequestedFill
    case modelSuggestedFill
}

enum VaultFillItemKind: Sendable { case paymentCard, address, phone, membership, identity }
struct VaultFillRequest: Sendable {
    let handle: VaultItemID
    let itemKind: VaultFillItemKind
    let field: VaultSecretField
}

enum VaultFillControlPurpose: Sendable { case typedFormField, search, chat, freeText, urlBar, unknown }
enum VaultFillHTMLInputType: Sendable { case text, tel, search, url, email, number, other }

/// Metadata a future trusted host adapter constructs from the current target observation.
struct VaultFillWebTargetInput: Sendable {
    var reference: String
    var navigationGeneration: Int64
    var frameGeneration: Int64
    var topLevelOrigin: String
    var frameOrigin: String
    var autocomplete: String
    var inputType: VaultFillHTMLInputType
    var purpose: VaultFillControlPurpose
    var contentEditable: Bool
    var visible: Bool
    var editable: Bool
    var secure: Bool
}

enum VaultFillAXRole: Sendable { case textField, searchField, comboBox, passwordField, other }
struct VaultFillNativeTargetInput: Sendable {
    var reference: String
    var navigationGeneration: Int64
    var frameGeneration: Int64
    var bundleID: String
    var windowIdentity: String
    var windowTitle: String
    var role: VaultFillAXRole
    var label: String
    var purpose: VaultFillControlPurpose
    var visible: Bool
    var editable: Bool
    var secure: Bool
    var valueSettable: Bool
}

enum VaultFillTargetDescriptor: Sendable {
    case web(VaultFillWebTargetInput)
    case native(VaultFillNativeTargetInput)
}

enum VaultFillConsentClass: Sendable, Equatable {
    case freshPhoneBiometricRequired
    case originApprovalRequired
}

struct VaultFillCanonicalOrigin: Sendable, Equatable { let serialized: String }
struct VaultFillNativeIdentity: Sendable, Equatable {
    let bundleID: String
    let windowIdentity: String
    let windowTitle: String
}
enum VaultFillTargetIdentity: Sendable, Equatable {
    case web(VaultFillCanonicalOrigin)
    case native(VaultFillNativeIdentity)
}

/// Immutable value-free challenge description. It never authorizes secret resolution or execution.
struct VaultFillApprovalDraft: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let ownerID: String
    let sessionID: String
    let taskID: String
    let revision: Int64
    let targetReference: String
    let navigationGeneration: Int64
    let frameGeneration: Int64
    let targetIdentity: VaultFillTargetIdentity
    let handleID: VaultItemID
    let field: VaultSecretField
    let nonce: UUID
    let approvalID: UUID
    let createdAtWall: Date
    let createdAtMonotonic: TimeInterval
    let expiresAt: Date
    let consentClass: VaultFillConsentClass
    let useState: VaultFillChallengeUseState

    fileprivate init(ownerID: String, sessionID: String, taskID: String, revision: Int64,
                     target: ValidatedVaultTarget, handleID: VaultItemID, nonce: UUID, approvalID: UUID,
                     createdAtWall: Date, createdAtMonotonic: TimeInterval, expiresAt: Date,
                     useState: VaultFillChallengeUseState) {
        self.ownerID = ownerID; self.sessionID = sessionID; self.taskID = taskID
        self.revision = revision; targetReference = target.reference
        navigationGeneration = target.navigationGeneration; frameGeneration = target.frameGeneration
        targetIdentity = target.identity; field = target.field; consentClass = target.consentClass
        self.handleID = handleID; self.nonce = nonce; self.approvalID = approvalID
        self.createdAtWall = createdAtWall; self.createdAtMonotonic = createdAtMonotonic
        self.expiresAt = expiresAt; self.useState = useState
    }

    var description: String { "<vault-fill-approval-draft>" }
    var debugDescription: String { description }
}

enum VaultFillAssessment: Sendable {
    case eligible(VaultFillApprovalDraft)
    case denied(VaultFillDenialReason)

    var draft: VaultFillApprovalDraft? { if case .eligible(let value) = self { value } else { nil } }
    var denial: VaultFillDenialReason? { if case .denied(let reason) = self { reason } else { nil } }
}

enum VaultFillDenialReason: Error, Sendable, Equatable {
    case notOwnerRequested, invalidAuthority, invalidClock, invalidTarget, invalidOrigin
    case crossOriginFrame, unclassifiedTarget, prohibitedTarget, fieldMismatch
    case itemFieldMismatch, unsupportedField
}

fileprivate struct ValidatedVaultTarget {
    let reference: String
    let navigationGeneration: Int64
    let frameGeneration: Int64
    let identity: VaultFillTargetIdentity
    let field: VaultSecretField
    let consentClass: VaultFillConsentClass
}

enum VaultFillEligibility {
    private static let challengeLifetime: TimeInterval = 30
    private static let maximumClock: TimeInterval = 4_102_444_800 // 2100-01-01 UTC

    static func assess(authority: VaultFillOwnerTaskAuthority, target: VaultFillTargetDescriptor,
                       request: VaultFillRequest, now: Date,
                       monotonicNow: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> VaultFillAssessment {
        guard authority.intent == .ownerTaskExplicitlyRequestedFill else { return .denied(.notOwnerRequested) }
        guard validOpaque(authority.ownerID, limit: 128), validOpaque(authority.sessionID, limit: 128),
              validOpaque(authority.taskID, limit: 128), authority.revision >= 0 else {
            return .denied(.invalidAuthority)
        }
        let time = now.timeIntervalSince1970
        guard time.isFinite, time >= 0, time <= maximumClock else { return .denied(.invalidClock) }
        let monotonic = monotonicNow()
        guard monotonic.isFinite, monotonic >= 0 else { return .denied(.invalidClock) }
        guard supported(request.field, for: request.itemKind) else {
            return .denied(itemFieldSupported(request.field) ? .itemFieldMismatch : .unsupportedField)
        }
        let validated: ValidatedVaultTarget
        switch validate(target) {
        case .success(let value): validated = value
        case .failure(let reason): return .denied(reason)
        }
        guard validated.field == request.field else { return .denied(.fieldMismatch) }
        let expires = time + challengeLifetime
        guard expires.isFinite, expires <= maximumClock else { return .denied(.invalidClock) }
        return .eligible(VaultFillApprovalDraft(ownerID: authority.ownerID, sessionID: authority.sessionID,
            taskID: authority.taskID, revision: authority.revision, target: validated,
            handleID: request.handle, nonce: UUID(), approvalID: UUID(), createdAtWall: now,
            createdAtMonotonic: monotonic, expiresAt: Date(timeIntervalSince1970: expires),
            useState: VaultFillChallengeUseState()))
    }

    private static func validate(_ descriptor: VaultFillTargetDescriptor) ->
        Result<ValidatedVaultTarget, VaultFillDenialReason> {
        switch descriptor {
        case .web(let web):
            guard web.purpose == .typedFormField, web.visible, web.editable,
                  !web.contentEditable, !web.secure, web.inputType != .search,
                  web.inputType != .url else { return .failure(.prohibitedTarget) }
            guard validOpaque(web.reference, limit: 256), web.navigationGeneration >= 0,
                  web.frameGeneration >= 0 else { return .failure(.invalidTarget) }
            guard let top = canonicalOrigin(web.topLevelOrigin),
                  let frame = canonicalOrigin(web.frameOrigin) else { return .failure(.invalidOrigin) }
            guard top == frame else { return .failure(.crossOriginFrame) }
            guard let field = htmlField(web.autocomplete), inputType(web.inputType, accepts: field) else {
                return .failure(.unclassifiedTarget)
            }
            return .success(ValidatedVaultTarget(reference: web.reference,
                navigationGeneration: web.navigationGeneration, frameGeneration: web.frameGeneration,
                identity: .web(top), field: field, consentClass: consent(for: field)))
        case .native(let native):
            guard native.purpose == .typedFormField, native.visible, native.editable,
                  !native.secure, native.valueSettable, native.role == .textField else {
                return .failure(.prohibitedTarget)
            }
            guard validOpaque(native.reference, limit: 256), native.navigationGeneration >= 0,
                  native.frameGeneration >= 0, validBundle(native.bundleID),
                  validOpaque(native.windowIdentity, limit: 256),
                  validDisplay(native.windowTitle, maximum: 512) else { return .failure(.invalidTarget) }
            guard let field = nativeField(native.label) else { return .failure(.unclassifiedTarget) }
            let identity = VaultFillNativeIdentity(bundleID: native.bundleID,
                windowIdentity: native.windowIdentity, windowTitle: native.windowTitle)
            return .success(ValidatedVaultTarget(reference: native.reference,
                navigationGeneration: native.navigationGeneration, frameGeneration: native.frameGeneration,
                identity: .native(identity), field: field, consentClass: consent(for: field)))
        }
    }

    /// Accepts only strict ASCII HTTPS origin serialization. IPv6 and percent-escaped authorities
    /// are intentionally denied until a reviewed canonicalizer is available.
    private static func canonicalOrigin(_ value: String) -> VaultFillCanonicalOrigin? {
        let bytes = Array(value.utf8)
        guard bytes.count <= 512, bytes.allSatisfy({ $0 > 0x20 && $0 < 0x7f }),
              value.hasPrefix("https://") else { return nil }
        let authority = String(value.dropFirst("https://".count))
        guard !authority.contains(where: { "/\\%@*?#[]".contains($0) }) else { return nil }
        let components = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 1 || components.count == 2,
              validDNSHost(String(components[0])) else { return nil }
        let host = String(components[0]).lowercased()
        var portSuffix = ""
        if components.count == 2 {
            let rawPort = components[1]
            guard !rawPort.isEmpty, (rawPort.count == 1 || rawPort.first != "0"),
                  rawPort.utf8.allSatisfy({ (48...57).contains($0) }),
                  let port = Int(rawPort), (1...65_535).contains(port) else { return nil }
            if port != 443 { portSuffix = ":\(port)" }
        }
        return VaultFillCanonicalOrigin(serialized: "https://\(host)\(portSuffix)")
    }

    private static func validDNSHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 &&
            label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
                                    ($0 >= 48 && $0 <= 57) || $0 == 45 })
        }) else { return false }
        let numericHost = host.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || $0 == 46 }
        let tail = labels.last ?? ""
        let hexNumber = tail.lowercased().hasPrefix("0x") && tail.dropFirst(2).allSatisfy {
            $0.isHexDigit
        }
        if !numericHost && (tail.utf8.allSatisfy { (48...57).contains($0) } || hexNumber) { return false }
        if numericHost {
            let octets = host.split(separator: ".", omittingEmptySubsequences: false)
            return octets.count == 4 && octets.allSatisfy {
                ($0.count == 1 || $0.first != "0") && $0.utf8.allSatisfy { (48...57).contains($0) } &&
                (Int($0).map { (0...255).contains($0) } ?? false)
            }
        }
        return true
    }

    private static func htmlField(_ raw: String) -> VaultSecretField? {
        let bytes = Array(raw.utf8)
        guard !bytes.isEmpty, bytes.count <= 256, bytes.allSatisfy({
            $0 < 0x80 && (($0 >= 0x20 && $0 != 0x7f) || [0x09, 0x0a, 0x0c, 0x0d].contains($0))
        }) else { return nil }
        let tokens = raw.split(whereSeparator: isHTMLWhitespace).map { $0.lowercased() }
        guard !tokens.isEmpty else { return nil }
        var index = 0
        if tokens[index].hasPrefix("section-") {
            let section = tokens[index].dropFirst("section-".count)
            guard !section.isEmpty, section.utf8.allSatisfy({
                ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45
            }) else { return nil }
            index += 1
        }
        if index < tokens.count, tokens[index] == "shipping" || tokens[index] == "billing" { index += 1 }
        var hasContactHint = false
        if index < tokens.count, ["home", "work", "mobile", "fax", "pager"].contains(tokens[index]) {
            hasContactHint = true
            index += 1
        }
        guard index == tokens.count - 1 else { return nil }
        let field: VaultSecretField
        switch tokens[index] {
        case "cc-number": field = .cardNumber
        case "cc-exp-month": field = .cardExpiryMonth
        case "cc-exp-year": field = .cardExpiryYear
        case "cc-name": field = .cardholderName
        case "address-line1": field = .addressLine1
        case "address-line2": field = .addressLine2
        case "address-level2": field = .addressCity
        case "address-level1": field = .addressRegion
        case "postal-code": field = .addressPostalCode
        case "country-name": field = .addressCountry
        case "tel": field = .phoneNumber
        default: return nil
        }
        return hasContactHint && field != .phoneNumber ? nil : field
    }

    private static func isHTMLWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n" ||
            character == "\u{000c}" || character == "\r"
    }

    private static func inputType(_ type: VaultFillHTMLInputType, accepts field: VaultSecretField) -> Bool {
        field == .phoneNumber ? (type == .text || type == .tel) : type == .text
    }

    private static func nativeField(_ label: String) -> VaultSecretField? {
        guard validDisplay(label, maximum: 256) else { return nil }
        switch label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "card number": return .cardNumber
        case "expiration month": return .cardExpiryMonth
        case "expiration year": return .cardExpiryYear
        case "cardholder name": return .cardholderName
        case "address line 1": return .addressLine1
        case "address line 2": return .addressLine2
        case "city": return .addressCity
        case "state/province/region": return .addressRegion
        case "postal code": return .addressPostalCode
        case "country": return .addressCountry
        case "phone number": return .phoneNumber
        default: return nil
        }
    }

    private static func consent(for field: VaultSecretField) -> VaultFillConsentClass {
        switch field {
        case .cardNumber, .cardExpiryMonth, .cardExpiryYear, .cardholderName:
            return .freshPhoneBiometricRequired
        default: return .originApprovalRequired
        }
    }

    private static func supported(_ field: VaultSecretField, for kind: VaultFillItemKind) -> Bool {
        switch kind {
        case .paymentCard: return [.cardNumber, .cardExpiryMonth, .cardExpiryYear, .cardholderName].contains(field)
        case .address: return [.addressLine1, .addressLine2, .addressCity, .addressRegion,
                               .addressPostalCode, .addressCountry].contains(field)
        case .phone: return field == .phoneNumber
        case .membership, .identity: return false
        }
    }

    private static func itemFieldSupported(_ field: VaultSecretField) -> Bool {
        supported(field, for: .paymentCard) || supported(field, for: .address) || supported(field, for: .phone)
    }

    private static func validBundle(_ value: String) -> Bool {
        guard validOpaque(value, limit: 255) else { return false }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy {
                ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
                ($0 >= 48 && $0 <= 57) || $0 == 45
            }
        }
    }

    private static func validOpaque(_ value: String, limit: Int) -> Bool {
        validDisplay(value, maximum: limit) && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validDisplay(_ value: String, maximum: Int) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.count <= maximum && !bytes.contains(0) &&
            !bytes.contains(where: { $0 < 0x20 || $0 == 0x7f })
    }
}

import Foundation
@preconcurrency import Contacts

/// Names are resolved before a strict Mail call is created. This type has no
/// Mail client, and cannot authorize or execute a send.
struct ComputerUseMailRecipients: Equatable, Sendable {
    struct Match: Equatable, Sendable {
        let name: String
        let address: String
    }

    enum Resolution: Equatable, Sendable {
        case ready([String: MCPJSONValue])
        case choose(name: String, field: String, index: Int, matches: [Match])
        case missing(String)
    }

    typealias Lookup = @Sendable (String) async throws -> [Match]
    var arguments: [String: MCPJSONValue]

    init(arguments: [String: MCPJSONValue]) throws {
        var structural = arguments
        for field in ["to", "cc", "bcc"] {
            let entries = try Self.entries(arguments, field: field)
            structural[field] = .string(entries.isEmpty ? (field == "to" ? "validation@example.invalid" : "")
                : entries.map { _ in "validation@example.invalid" }.joined(separator: ", "))
        }
        // Validate every other field before consulting Contacts. Recipient
        // bounds and controls are checked separately, without relaxing the
        // executable Mail schema or approval fingerprint.
        _ = try RemoteDesktopMailRequest(arguments: structural)
        self.arguments = arguments
    }

    mutating func resolve(lookup: Lookup = { try await Self.contacts($0) }) async throws -> Resolution {
        for field in ["to", "cc", "bcc"] {
            var values = try Self.entries(arguments, field: field)
            if field == "to", values.isEmpty { return .missing("What email address should I use?") }
            for index in values.indices {
                let value = values[index]
                if Self.isAddress(value) { continue }
                if value.contains("@") { return .missing("What email address should I use for \(value)?") }
                let found = try await lookup(value)
                try Task.checkCancellation()
                var seen = Set<String>()
                let matches = found.filter {
                    Self.isAddress($0.address) && seen.insert($0.address.lowercased()).inserted
                }.sorted { ($0.name, $0.address) < ($1.name, $1.address) }
                guard !matches.isEmpty else {
                    return .missing("I couldn't find an email address for \(value) in Contacts. What address should I use?")
                }
                if matches.count > 8 { return .missing("Several contacts match \(value). What is their full name or email address?") }
                if matches.count > 1 { return .choose(name: value, field: field, index: index, matches: matches) }
                values[index] = matches[0].address
                arguments[field] = .string(values.joined(separator: ", "))
            }
        }
        _ = try RemoteDesktopMailRequest(arguments: arguments)
        return .ready(arguments)
    }

    mutating func select(address: String, field: String, index: Int) throws {
        guard ["to", "cc", "bcc"].contains(field), Self.isAddress(address) else {
            throw MCPClientError.invalidArguments("The selected recipient is invalid.")
        }
        var values = try Self.entries(arguments, field: field)
        guard values.indices.contains(index) else { throw MCPClientError.approvalMismatch }
        values[index] = address
        arguments[field] = .string(values.joined(separator: ", "))
    }

    private static func entries(_ arguments: [String: MCPJSONValue], field: String) throws -> [String] {
        guard let raw = arguments[field] else { return [] }
        guard case .string(let value) = raw,
              value.utf8.count <= RemoteDesktopMailRequest.maximumApprovalValueBytes else {
            throw MCPClientError.invalidArguments("The recipient field is invalid.")
        }
        let values = value.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard values.count <= RemoteDesktopMailRequest.maximumRecipientsPerField,
              values.allSatisfy({ $0.utf8.count <= RemoteDesktopMailRequest.maximumRecipientBytes
                  && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw MCPClientError.invalidArguments("The recipient field is invalid.")
        }
        return values
    }

    private static func isAddress(_ value: String) -> Bool {
        (try? RemoteDesktopMailRequest(arguments: ["to": .string(value), "subject": .string(""),
            "body": .string(""), "send_now": .bool(false)])) != nil
    }

    static func contacts(_ name: String) async throws -> [Match] {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            guard try await CNContactStore().requestAccess(for: .contacts) else {
                throw MCPClientError.toolFailed("Allow Contacts access on your Mac, or provide an email address.")
            }
        } else if status != .authorized {
            throw MCPClientError.toolFailed("Allow Contacts access on your Mac, or provide an email address.")
        }
        return try await Task.detached(priority: .userInitiated) {
            let store = CNContactStore()
            let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor]
            let contacts = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name),
                keysToFetch: keys)
            return contacts.flatMap { contact in
                let display = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                return contact.emailAddresses.map { Match(name: display, address: String($0.value)) }
            }
        }.value
    }
}

import AppKit
import Foundation
import ApplicationServices

/// A small host-owned description of one Gmail operation. It stores only
/// values already resolved from the user's request or the host file catalog.
struct ComputerUseGmailJob: Equatable, Sendable {
    struct Request: Equatable, Sendable {
        let to: [String]
        let cc: [String]
        let bcc: [String]
        let subject: String
        let body: String
        let fileDescription: String
        let sendRequested: Bool
        let existingDraftURL: URL?
    }

    struct Attachment: Equatable, Sendable {
        let candidateID: String
        let displayName: String
        let byteCount: Int64
    }

    enum Error: Swift.Error, Equatable {
        case invalidRequest
        case invalidDraftURL
    }

    let request: Request
    private(set) var attachment: Attachment?

    init(request: Request) throws {
        guard !request.to.isEmpty,
              request.to.count <= RemoteDesktopMailRequest.maximumRecipientsPerField,
              request.cc.count <= RemoteDesktopMailRequest.maximumRecipientsPerField,
              request.bcc.count <= RemoteDesktopMailRequest.maximumRecipientsPerField,
              request.subject.utf8.count <= RemoteDesktopMailRequest.maximumSubjectBytes,
              request.body.utf8.count <= RemoteDesktopMailRequest.maximumBodyBytes,
              request.fileDescription.utf8.count <= 1_024,
              !request.subject.contains("\0"), !request.subject.contains("\r"), !request.subject.contains("\n"),
              !request.body.contains("\0"), !request.fileDescription.contains("\0") else {
            throw Error.invalidRequest
        }
        let mailFields: [String: MCPJSONValue] = [
            "to": .string(request.to.joined(separator: ", ")),
            "cc": .string(request.cc.joined(separator: ", ")),
            "bcc": .string(request.bcc.joined(separator: ", ")),
            "subject": .string(request.subject), "body": .string(request.body),
            "send_now": .bool(request.sendRequested),
        ]
        do { _ = try RemoteDesktopMailRequest(arguments: mailFields) }
        catch { throw Error.invalidRequest }
        if let draftURL = request.existingDraftURL {
            guard Self.isGmailURL(draftURL), Self.isComposeOrDraftURL(draftURL) else { throw Error.invalidDraftURL }
        }
        self.request = request
    }

    mutating func selectAttachment(_ attachment: Attachment) throws {
        guard (1...128).contains(attachment.candidateID.utf8.count),
              !attachment.displayName.isEmpty, attachment.displayName.utf8.count <= 255,
              !attachment.displayName.contains("/"), !attachment.displayName.contains("\\"),
              attachment.byteCount >= 0 else { throw Error.invalidRequest }
        guard self.attachment == nil || self.attachment == attachment else { throw Error.invalidRequest }
        self.attachment = attachment
    }

    var composeURL: URL? {
        if let existingDraftURL = request.existingDraftURL { return existingDraftURL }
        var components = URLComponents(string: "https://mail.google.com/mail/u/0/")
        var items = [URLQueryItem(name: "view", value: "cm"), URLQueryItem(name: "fs", value: "1"),
            URLQueryItem(name: "to", value: request.to.joined(separator: ", ")),
            URLQueryItem(name: "su", value: request.subject), URLQueryItem(name: "body", value: request.body)]
        if !request.cc.isEmpty { items.append(.init(name: "cc", value: request.cc.joined(separator: ", "))) }
        if !request.bcc.isEmpty { items.append(.init(name: "bcc", value: request.bcc.joined(separator: ", "))) }
        components?.queryItems = items
        let encodedQuery = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encodedQuery
        guard let url = components?.url, Self.isGmailURL(url) else { return nil }
        return url
    }

    var requiresAttachment: Bool { !request.fileDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func verifiesCompose(_ observation: ComputerUseDefaultBrowserPageReader.Observation) -> Bool {
        guard verifiesComposeContents(observation) else { return false }
        return verifiesRecipients(observation)
    }

    func verifiesComposeContents(_ observation: ComputerUseDefaultBrowserPageReader.Observation) -> Bool {
        guard let url = URL(string: observation.url), Self.isGmailURL(url) else { return false }
        let fields = observation.formFieldValues
        func exactField(_ label: String, _ value: String) -> Bool {
            fields.contains { field in
                field.label.localizedCaseInsensitiveContains(label) && field.value == value
            }
        }
        return exactField("subject", request.subject) && fields.contains {
            ($0.role == "AXTextArea" || $0.label.localizedCaseInsensitiveContains("message body"))
                && $0.value == request.body
        }
    }

    func verifiesRecipients(_ observation: ComputerUseDefaultBrowserPageReader.Observation) -> Bool {
        guard let url = URL(string: observation.url), Self.isGmailURL(url) else { return false }
        let fields = observation.formFieldValues
        func fieldsFor(_ fieldName: String) -> [ComputerUseDefaultBrowserPageReader.Observation.FormFieldValue] {
            fields.filter { field in
            let label = "\(field.label) \(field.help)".lowercased()
                return label == fieldName || label.hasPrefix("\(fieldName) ")
                    || label == "\(fieldName) recipients" || label.contains("\(fieldName) recipients")
            }
        }
        let exact: [(String, [String])] = [("to", request.to), ("cc", request.cc), ("bcc", request.bcc)]
        return exact.allSatisfy { fieldName, addresses in
            let observed = fieldsFor(fieldName)
            let actual = observed.flatMap { Self.mailboxes(in: $0.value) }
            let expected = addresses.map { $0.lowercased() }
            return Set(actual).count == actual.count && Set(expected).count == expected.count
                && Set(actual) == Set(expected)
        }
    }

    func verifiesAttachment(_ observation: ComputerUseDefaultBrowserPageReader.Observation) -> Bool {
        guard let url = URL(string: observation.url), Self.isGmailURL(url) else { return false }
        guard let attachment else { return !requiresAttachment }
        var formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let formattedSize = formatter.string(fromByteCount: attachment.byteCount)
        func matches(_ value: String) -> Bool {
            value.localizedCaseInsensitiveContains(attachment.displayName)
                && (value.localizedCaseInsensitiveContains(formattedSize)
                    || value.localizedCaseInsensitiveContains("\(attachment.byteCount) bytes"))
        }
        let textMatches = observation.exactTextValues.filter(matches)
        if !textMatches.isEmpty { return textMatches.count == 1 }
        return observation.controls.filter { matches($0.label) }.count == 1
    }

    func hasVisibleAttachmentRemovalControl(_ observation: ComputerUseDefaultBrowserPageReader.Observation) -> Bool {
        observation.controls.contains { control in
            (control.role == "AXButton" || control.role == "AXPopUpButton")
                && control.label.localizedCaseInsensitiveContains("remove attachment")
        }
    }

    func verifiesSend(_ observation: ComputerUseDefaultBrowserPageReader.Observation) -> Bool {
        request.sendRequested && URL(string: observation.url).map(Self.isGmailURL) == true && observation.exactTextValues.contains {
            $0.localizedCaseInsensitiveContains("Message sent")
        }
    }

    func verifiesSavedDraft(_ observation: ComputerUseDefaultBrowserPageReader.Observation) -> Bool {
        !request.sendRequested && URL(string: observation.url).map(Self.isGmailURL) == true && observation.exactTextValues.contains {
            $0.localizedCaseInsensitiveContains("Draft saved")
                || $0.localizedCaseInsensitiveContains("Saved to Drafts")
        }
    }

    func sendApprovalPresentation() -> MCPComputerUseApprovalPresentation? {
        guard request.sendRequested else { return nil }
        var details = [
            ComputerUseApprovalRequest.Detail(label: "To", value: request.to.joined(separator: ", ")),
            ComputerUseApprovalRequest.Detail(label: "Subject", value: request.subject),
            ComputerUseApprovalRequest.Detail(label: "Message", value: String(request.body.prefix(240))),
        ]
        if let attachment {
            details.append(.init(label: "Attachment", value: "\(attachment.displayName) (\(attachment.byteCount) bytes)"))
        }
        if !request.cc.isEmpty { details.insert(.init(label: "CC", value: request.cc.joined(separator: ", ")), at: 1) }
        if !request.bcc.isEmpty { details.insert(.init(label: "BCC", value: request.bcc.joined(separator: ", ")), at: 1) }
        return .init(message: "Send this email through Gmail?", details: details, confirmLabel: "Send email")
    }

    static func isApprovedDraftURL(_ url: URL) -> Bool {
        isGmailURL(url) && isComposeOrDraftURL(url)
    }

    private static func isGmailURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "mail.google.com"
            && components.user == nil && components.password == nil && components.port == nil
            && components.path.range(of: #"^/mail/u/[0-9]+/?$"#, options: .regularExpression) != nil
    }

    private static func isComposeOrDraftURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.queryItems?.contains(where: { $0.name == "view" && $0.value == "cm" }) == true
            || components.fragment?.range(of: #"(?:^|[?&])compose=[A-Za-z0-9_-]{6,256}(?:&|$)"#,
                options: .regularExpression) != nil
    }

    private static func mailboxes(in value: String) -> [String] {
        value.split(whereSeparator: { $0 == "," || $0 == ";" }).compactMap { raw in
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let pattern = #"^(?:[^<>\r\n]{1,200}\s*<)?([^@\s<>]{1,128}@[^@\s<>]{1,190}\.[^@\s<>]{2,64})>?$"#
            guard let range = part.range(of: pattern, options: .regularExpression) else { return nil }
            let matched = String(part[range])
            if let open = matched.lastIndex(of: "<"), let close = matched.lastIndex(of: ">"), open < close {
                return String(matched[matched.index(after: open)..<close]).lowercased()
            }
            return matched.lowercased()
        }
    }

}

/// Reads the actual recipient chips from one Gmail compose region. Each chip
/// must expose an AXShowMenu action whose menu contains its exact Copy-address
/// item; visible names and account headers are never treated as addresses.
@MainActor
enum ComputerUseGmailRecipientVerifier {
    enum RecipientMenuObservation: Equatable {
        case absent
        case copyAddress(String)
        case unrecognized
    }

    enum RecipientMenuDismissalDecision: Equatable {
        case menuAbsent
        case sendEscape
        case stop
    }

    static func dismissalDecision(observation: RecipientMenuObservation, expectedAddress: String,
                                  escapeDispatched: Bool) -> RecipientMenuDismissalDecision {
        switch observation {
        case .absent:
            return .menuAbsent
        case .copyAddress(let address) where address.caseInsensitiveCompare(expectedAddress) == .orderedSame:
            return escapeDispatched ? .stop : .sendEscape
        case .copyAddress, .unrecognized:
            return .stop
        }
    }

    enum AttachmentEvidence: Equatable {
        case absent
        case matching
        case conflicting
    }

    private final class Node {
        let element: AXUIElement
        let role: String
        let strings: [String]
        let value: String?
        let children: [Node]

        init(element: AXUIElement, role: String, strings: [String], value: String?, children: [Node]) {
            self.element = element
            self.role = role
            self.strings = strings
            self.value = value
            self.children = children
        }
    }

    private enum RecipientField: String, CaseIterable {
        case to, cc, bcc
    }

    static func verify(window: AXUIElement, application: ComputerUseApplicationIdentity,
                       expected: ComputerUseGmailJob.Request,
                       revalidate: @MainActor () throws -> Void,
                       diagnostic: @MainActor (String) -> Void = { _ in }) throws -> Bool {
        try revalidate()
        guard frontmostMatches(application) else { diagnostic("frontmost_mismatch"); return false }
        guard var current = try composeRegion(window: window) else {
            diagnostic("compose_discovery_or_tree_incomplete"); return false
        }
        guard let subject = descendants(of: current).first(where: isSubjectField) else {
            diagnostic("subject_field_missing"); return false
        }

        // Gmail initially exposes a collapsed recipient chip beside Subject.
        // Opening its own menu both reveals the labelled recipient regions and
        // provides exact address evidence; no account header is consulted.
        if recipientChips(in: current, field: .to).isEmpty {
            guard let collapsedChip = collapsedRecipientChip(in: current, subject: subject, diagnostic: diagnostic) else {
                return false
            }
            try revalidate()
            guard AXUIElementPerformAction(collapsedChip.element, "AXShowMenu" as CFString) == .success else {
                diagnostic("collapsed_to_menu_action_failed"); return false
            }
            try revalidate()
            guard let menuState = try composeRegion(window: window) else {
                diagnostic("collapsed_to_menu_tree_unavailable"); return false
            }
            let copyAddress = try copyAddress(in: menuState)
            try revalidate()
            guard try cancelRecipientMenu(in: menuState) else {
                diagnostic("collapsed_to_menu_cancel_failed"); return false
            }
            try revalidate()
            guard copyAddress != nil, let expanded = try composeRegion(window: window),
                  !recipientChips(in: expanded, field: .to).isEmpty else {
                diagnostic(copyAddress == nil ? "collapsed_to_menu_item_unparsed" : "to_chips_not_expanded")
                return false
            }
            current = expanded
        }

        let expectedByField: [RecipientField: [String]] = [
            .to: expected.to, .cc: expected.cc, .bcc: expected.bcc,
        ]
        var actualByField: [RecipientField: [String]] = [:]
        for field in RecipientField.allCases {
            let wanted = expectedByField[field] ?? []
            let chips = recipientChips(in: current, field: field)
            guard chips.count <= RemoteDesktopMailRequest.maximumRecipientsPerField,
                  chips.count == wanted.count else {
                diagnostic("\(field.rawValue)_chip_count_mismatch")
                return false
            }
            var addresses: [String] = []
            for index in chips.indices {
                try revalidate()
                guard let currentState = try composeRegion(window: window) else {
                    diagnostic("compose_lost_before_\(field.rawValue)_menu"); return false
                }
                let currentChips = recipientChips(in: currentState, field: field)
                guard currentChips.count == chips.count, currentChips.indices.contains(index) else {
                    diagnostic("\(field.rawValue)_chips_changed"); return false
                }
                let chip = currentChips[index]
                guard hasAction(chip.element, "AXShowMenu"),
                      AXUIElementPerformAction(chip.element, "AXShowMenu" as CFString) == .success else {
                    diagnostic("\(field.rawValue)_menu_action_failed"); return false
                }
                try revalidate()
                guard let currentState = try composeRegion(window: window) else {
                    diagnostic("\(field.rawValue)_menu_tree_unavailable"); return false
                }
                let menuAddress = try copyAddress(in: currentState)
                try revalidate()
                guard try cancelRecipientMenu(in: currentState) else {
                    diagnostic("\(field.rawValue)_menu_cancel_failed"); return false
                }
                try revalidate()
                guard let menuAddress else { diagnostic("\(field.rawValue)_menu_item_unparsed"); return false }
                addresses.append(menuAddress)
            }
            actualByField[field] = addresses
        }

        for field in RecipientField.allCases {
            let wanted = expectedByField[field] ?? []
            let actual = actualByField[field] ?? []
            let wantedNormalized = wanted.map { $0.lowercased() }
            let actualNormalized = actual.map { $0.lowercased() }
            guard Set(wantedNormalized).count == wantedNormalized.count,
                  Set(actualNormalized).count == actualNormalized.count,
                  Set(actualNormalized) == Set(wantedNormalized) else {
                diagnostic("\(field.rawValue)_address_set_mismatch")
                return false
            }
        }
        try revalidate()
        return true
    }

    /// Identifies only a unique Copy-address menu inside the unique Gmail
    /// compose region. A successful AXCancel call alone is not evidence that
    /// the recipient menu actually disappeared.
    static func recipientMenuObservation(window: AXUIElement, application: ComputerUseApplicationIdentity,
                                         revalidate: @MainActor () throws -> Void) throws -> RecipientMenuObservation {
        try revalidate()
        guard frontmostMatches(application), let compose = try composeRegion(window: window) else {
            return .unrecognized
        }
        let menus = descendants(of: compose).filter { $0.role == "AXMenu" }
        guard !menus.isEmpty else { return .absent }
        guard menus.count == 1, let address = try copyAddress(in: compose) else { return .unrecognized }
        try revalidate()
        return .copyAddress(address)
    }

    static func attachmentEvidence(window: AXUIElement, application: ComputerUseApplicationIdentity,
                                   expected: ComputerUseGmailJob.Attachment,
                                   revalidate: @MainActor () throws -> Void) throws -> AttachmentEvidence {
        try revalidate()
        guard frontmostMatches(application), let compose = try composeRegion(window: window) else {
            return .conflicting
        }
        var formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let formattedSize = formatter.string(fromByteCount: expected.byteCount)
        let staticValues = descendants(of: compose).compactMap { node -> String? in
            node.role == "AXStaticText" ? node.value : nil
        }
        let matches = staticValues.filter { value in
            value.localizedCaseInsensitiveContains(expected.displayName)
                && (value.localizedCaseInsensitiveContains(formattedSize)
                    || value.localizedCaseInsensitiveContains("\(expected.byteCount) bytes"))
        }
        let fileLike = staticValues.filter {
            $0.range(of: #"(?i)\b[^/\s]+\.[a-z0-9]{1,12}\b.{0,64}\b(?:\d+(?:\.\d+)?\s*(?:bytes?|B|KB|MB|GB|TB))\b"#,
                options: .regularExpression) != nil
        }
        let hasRemovalControl = descendants(of: compose).contains { node in
            node.role == "AXButton" && (node.strings + [node.value].compactMap { $0 }).contains {
                $0.localizedCaseInsensitiveContains("remove attachment")
            }
        }
        try revalidate()
        if matches.count == 1 && fileLike.count == 1 { return .matching }
        if matches.isEmpty && fileLike.isEmpty && !hasRemovalControl { return .absent }
        return .conflicting
    }

    static func accountControlLabel(window: AXUIElement, application: ComputerUseApplicationIdentity,
                                    revalidate: @MainActor () throws -> Void) throws -> String? {
        try revalidate()
        guard frontmostMatches(application) else { return nil }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        var visited = 0
        var overflow = false
        var outerWebAreaSeen = false
        var labels: [String] = []

        func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { overflow = true; return nil }
            AXUIElementSetMessagingTimeout(element, 0.1)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                  !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            return value
        }
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= 16, visited < 512, ContinuousClock.now < deadline, !Task.isCancelled else {
                overflow = true; return
            }
            visited += 1
            if read(element, kAXHiddenAttribute as String) as? Bool == true
                || read(element, "AXProtectedContent") as? Bool == true { return }
            let role = read(element, kAXRoleAttribute as String) as? String ?? ""
            let subrole = read(element, kAXSubroleAttribute as String) as? String ?? ""
            guard subrole != (kAXSecureTextFieldSubrole as String),
                  !["AXTable", "AXOutline", "AXList", "AXTextArea", "AXSecureTextField", "AXMenu", "AXMenuItem"].contains(role) else { return }
            if role == "AXGroup" {
                let labels = [kAXTitleAttribute, kAXDescriptionAttribute]
                    .compactMap { read(element, $0 as String) as? String }
                if labels.contains(where: {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).range(of: "Compose:",
                        options: [.anchored, .caseInsensitive]) != nil
                }) { return }
            }
            if role == "AXWebArea" {
                guard !outerWebAreaSeen else { return }
                outerWebAreaSeen = true
            }
            if role == "AXButton" {
                let observed = ([kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
                                 kAXIdentifierAttribute, kAXValueAttribute]
                    .compactMap { read(element, $0 as String) as? String })
                labels.append(contentsOf: observed.filter {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .range(of: "Google Account:", options: [.anchored, .caseInsensitive]) != nil
                })
            }
            guard let rawChildren = read(element, kAXChildrenAttribute as String) else {
                if ["AXWindow", "AXGroup", "AXWebArea", "AXScrollArea"].contains(role) { overflow = true }
                return
            }
            guard let children = rawChildren as? [AXUIElement], children.count <= 128 else {
                overflow = true; return
            }
            for child in children { visit(child, depth: depth + 1) }
        }
        visit(window, depth: 0)
        try revalidate()
        guard !overflow, !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
        let uniqueLabels = Array(Set(labels))
        return uniqueLabels.count == 1 ? uniqueLabels[0] : nil
    }

    private static func composeRegion(window: AXUIElement) throws -> Node? {
        let excluded: Set<String> = ["AXTable", "AXOutline", "AXList", "AXTextArea", "AXWebArea", "AXSecureTextField"]
        guard let groups = findComposeGroups(window), groups.count == 1,
              let compose = buildTree(groups[0], limit: 256, excludedRoles: excluded) else { return nil }
        guard descendants(of: compose).contains(where: isSubjectField) else { return nil }
        return compose
    }

    private static func findComposeGroups(_ window: AXUIElement) -> [AXUIElement]? {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(750))
        var visited = 0
        var overflow = false
        var outerWebAreaSeen = false
        var matches: [AXUIElement] = []
        func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { overflow = true; return nil }
            AXUIElementSetMessagingTimeout(element, 0.1)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                  !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            return value
        }
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= 16, visited < 512, ContinuousClock.now < deadline, !Task.isCancelled else {
                overflow = true; return
            }
            visited += 1
            if read(element, kAXHiddenAttribute as String) as? Bool == true
                || read(element, "AXProtectedContent") as? Bool == true { return }
            let role = read(element, kAXRoleAttribute as String) as? String ?? ""
            let subrole = read(element, kAXSubroleAttribute as String) as? String ?? ""
            guard subrole != (kAXSecureTextFieldSubrole as String),
                  !["AXTable", "AXOutline", "AXList", "AXSecureTextField"].contains(role) else { return }
            if role == "AXWebArea" {
                guard !outerWebAreaSeen else { return }
                outerWebAreaSeen = true
            }
            if role == "AXGroup" {
                let labels = [kAXTitleAttribute, kAXDescriptionAttribute]
                    .compactMap { read(element, $0 as String) as? String }
                if labels.contains(where: {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).range(of: "Compose:",
                        options: [.anchored, .caseInsensitive]) != nil
                }) {
                    matches.append(element)
                    return
                }
            }
            guard let rawChildren = read(element, kAXChildrenAttribute as String) else {
                if ["AXWindow", "AXGroup", "AXWebArea", "AXComboBox", "AXScrollArea"].contains(role) { overflow = true }
                return
            }
            guard let children = rawChildren as? [AXUIElement], children.count <= 128 else {
                overflow = true; return
            }
            for child in children { visit(child, depth: depth + 1) }
        }
        visit(window, depth: 0)
        guard !overflow, !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
        return matches
    }

    private static func buildTree(_ root: AXUIElement, limit: Int, excludedRoles: Set<String>) -> Node? {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(750))
        var visited = 0
        var overflow = false
        var outerWebAreaSeen = false
        func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.1)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                  !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            return value
        }
        func makeNode(_ element: AXUIElement, depth: Int) -> Node? {
            guard depth <= 16, visited < limit, ContinuousClock.now < deadline, !Task.isCancelled else {
                overflow = true; return nil
            }
            visited += 1
            if let hidden = read(element, kAXHiddenAttribute as String) as? Bool, hidden { return nil }
            if let protected = read(element, "AXProtectedContent") as? Bool, protected { return nil }
            let role = read(element, kAXRoleAttribute as String) as? String ?? ""
            let subrole = read(element, kAXSubroleAttribute as String) as? String ?? ""
            guard subrole != (kAXSecureTextFieldSubrole as String), !excludedRoles.contains(role) else { return nil }
            if role == "AXWebArea" {
                guard !outerWebAreaSeen else { return nil }
                outerWebAreaSeen = true
            }
            let strings = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
                kAXIdentifierAttribute, kAXPlaceholderValueAttribute]
                .compactMap { read(element, $0 as String) as? String }
            let value = role == "AXStaticText" ? read(element, kAXValueAttribute as String) as? String : nil
            let childValue = read(element, kAXChildrenAttribute as String)
            let childElements = childValue as? [AXUIElement]
            if childValue == nil && ["AXWindow", "AXGroup", "AXWebArea", "AXComboBox", "AXScrollArea", "AXMenu"].contains(role) {
                overflow = true
            }
            if (childElements?.count ?? 0) > 128 { overflow = true; return nil }
            let children = (childElements ?? []).compactMap { makeNode($0, depth: depth + 1) }
            return Node(element: element, role: role, strings: strings, value: value, children: children)
        }
        guard let tree = makeNode(root, depth: 0), !overflow, !Task.isCancelled,
              ContinuousClock.now < deadline else { return nil }
        return tree
    }

    private static func descendants(of node: Node) -> [Node] {
        [node] + node.children.flatMap(descendants)
    }

    private static func isSubjectField(_ node: Node) -> Bool {
        node.role == "AXTextField" && node.strings.contains(where: {
            $0.localizedCaseInsensitiveCompare("Subject") == .orderedSame
        })
    }

    private static func parent(of target: Node, in root: Node) -> Node? {
        root.children.contains(where: { $0 === target }) ? root
            : root.children.lazy.compactMap { parent(of: target, in: $0) }.first
    }

    private static func collapsedRecipientChip(in compose: Node, subject: Node,
                                              diagnostic: @MainActor (String) -> Void) -> Node? {
        let excluded: Set<String> = ["AXTextArea", "AXMenu", "AXMenuItem", "AXWebArea", "AXSecureTextField",
                                     "AXHeading", "AXButton", "AXLink"]
        var ancestor = parent(of: subject, in: compose)
        var counts: [Int] = []
        for depth in 1...6 {
            guard let row = ancestor, row !== compose else { break }
            var matches: [Node] = []
            func visit(_ node: Node) {
                guard node !== subject, !excluded.contains(node.role) else { return }
                if node.role == "AXStaticText", !(node.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   hasAction(node.element, "AXShowMenu") {
                    matches.append(node)
                }
                for child in node.children { visit(child) }
            }
            for child in row.children { visit(child) }
            counts.append(matches.count)
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 {
                diagnostic("collapsed_to_ancestor_ambiguous_depth_\(depth)_count_\(matches.count)")
                return nil
            }
            ancestor = parent(of: row, in: compose)
        }
        diagnostic("collapsed_to_chip_not_found_depth_\(counts.count)_candidate_counts_\(counts.map { String($0) }.joined(separator: "-"))")
        return nil
    }

    private static func recipientChips(in compose: Node, field: RecipientField) -> [Node] {
        var result: [Node] = []
        func visit(_ node: Node, ancestors: [Node]) {
            guard node.role != "AXMenu", node.role != "AXMenuItem" else { return }
            if node.role == "AXStaticText", hasAction(node.element, "AXShowMenu"),
               ancestors.contains(where: { identifies($0, as: field) }) {
                result.append(node)
            }
            for child in node.children { visit(child, ancestors: ancestors + [node]) }
        }
        visit(compose, ancestors: [])
        return result
    }

    private static func identifies(_ node: Node, as field: RecipientField) -> Bool {
        let aliases: [RecipientField: [String]] = [
            .to: ["to", "to recipients"], .cc: ["cc", "cc recipients"], .bcc: ["bcc", "bcc recipients"],
        ]
        return (node.strings + [node.value].compactMap { $0 }).contains { value in
            aliases[field, default: []].contains { value.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare($0) == .orderedSame }
        }
    }

    private static func hasAction(_ element: AXUIElement, _ action: String) -> Bool {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success,
              let names = actions as? [String] else { return false }
        return names.contains(action)
    }

    static func mailbox(fromCopyMenuTitle title: String) -> String? {
        guard let match = title.range(of: #"^Copy "([^"\r\n]{3,320})"(?: Option\+C)?$"#,
            options: .regularExpression) else { return nil }
        let address = String(title[match]).replacingOccurrences(of: #"^Copy "|"(?: Option\+C)?$"#,
            with: "", options: .regularExpression)
        guard address.range(of: #"^[^@\s<>]{1,128}@[^@\s<>]{1,190}\.[^@\s<>]{2,64}$"#,
            options: .regularExpression) != nil else { return nil }
        return address
    }

    private static func copyAddress(in root: Node) throws -> String? {
        let menus = descendants(of: root).filter { $0.role == "AXMenu" }
        guard menus.count == 1 else { return nil }
        let items = descendants(of: menus[0]).filter { $0.role == "AXMenuItem" }
        let matches = items.compactMap { node -> String? in
            guard let title = readString(node.element, kAXTitleAttribute as String)
                    ?? readString(node.element, kAXValueAttribute as String) else { return nil }
            return mailbox(fromCopyMenuTitle: title)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func cancelRecipientMenu(in root: Node) throws -> Bool {
        let menus = descendants(of: root).filter { $0.role == "AXMenu" }
        guard menus.count == 1, hasAction(menus[0].element, "AXCancel") else { return false }
        return AXUIElementPerformAction(menus[0].element, "AXCancel" as CFString) == .success
    }

    private static func readString(_ element: AXUIElement, _ attribute: String) -> String? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func frontmostMatches(_ expected: ComputerUseApplicationIdentity) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated else { return false }
        return app.processIdentifier == expected.processIdentifier && app.bundleIdentifier == expected.bundleIdentifier
    }
}

@MainActor
protocol ComputerUseGmailApprovalPresenting {
    func gmailApprovalPresentation(for action: ComputerUsePredictedAction) -> MCPComputerUseApprovalPresentation?
}

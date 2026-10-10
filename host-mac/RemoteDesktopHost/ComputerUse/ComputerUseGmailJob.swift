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
        let account: ComputerUseGmailAccountDirectory.Account?

        init(to: [String], cc: [String], bcc: [String], subject: String, body: String,
             fileDescription: String, sendRequested: Bool, existingDraftURL: URL? = nil,
             account: ComputerUseGmailAccountDirectory.Account? = nil) {
            self.to = to; self.cc = cc; self.bcc = bcc
            self.subject = subject; self.body = body; self.fileDescription = fileDescription
            self.sendRequested = sendRequested; self.existingDraftURL = existingDraftURL; self.account = account
        }
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
            if let account = request.account,
               ComputerUseGmailAccountDirectory.accountIndex(from: draftURL.absoluteString) != account.index {
                throw Error.invalidDraftURL
            }
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
        let accountIndex = request.account?.index ?? 0
        var components = URLComponents(string: "https://mail.google.com/mail/u/\(accountIndex)/")
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
        guard let url = URL(string: observation.url), Self.isGmailURL(url), matchesAccount(url) else { return false }
        let fields = observation.formFieldValues
        let subjects = fields.filter {
            $0.label.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare("Subject") == .orderedSame
        }
        let bodies = fields.filter {
            $0.role == "AXTextArea" && $0.label.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare("Message Body") == .orderedSame
        }
        return subjects.count == 1 && subjects[0].value == request.subject
            && bodies.count == 1 && bodies[0].value == request.body
    }

    func composeFieldDiagnostics(_ observation: ComputerUseDefaultBrowserPageReader.Observation) -> [String: String] {
        let fields = observation.formFieldValues
        let subjects = fields.filter {
            $0.label.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare("Subject") == .orderedSame
        }
        let bodies = fields.filter {
            $0.role == "AXTextArea" && $0.label.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare("Message Body") == .orderedSame
        }
        return [
            "gmailSubjectFieldCount": String(subjects.count),
            "gmailSubjectValueMatches": String(subjects.count == 1 && subjects[0].value == request.subject),
            "gmailMessageBodyFieldCount": String(bodies.count),
            "gmailMessageBodyValueMatches": String(bodies.count == 1 && bodies[0].value == request.body),
        ]
    }

    func verifiesRecipients(_ observation: ComputerUseDefaultBrowserPageReader.Observation) -> Bool {
        guard let url = URL(string: observation.url), Self.isGmailURL(url), matchesAccount(url) else { return false }
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
        guard let url = URL(string: observation.url), Self.isGmailURL(url), matchesAccount(url) else { return false }
        guard let attachment else { return !requiresAttachment }
        let linkLabels = observation.controls.filter { $0.role == "AXLink" }.map(\.label)
        let linkCandidates = linkLabels.filter(Self.isAttachmentLabel)
        let labels = linkCandidates.isEmpty
            ? observation.exactTextValues.filter(Self.isAttachmentLabel) : linkCandidates
        return labels.count == 1 && Self.attachmentLabelMatches(labels[0], expected: attachment)
    }

    private struct AttachmentSizeLabel: Equatable {
        let amount: Decimal
        let unit: String
    }

    private struct ParsedAttachmentLabel: Equatable {
        let fileName: String
        let size: AttachmentSizeLabel?
    }

    static func attachmentLabelMatches(_ label: String, expected: Attachment) -> Bool {
        guard let parsed = parseAttachmentLabel(label), parsed.fileName == expected.displayName,
              let size = parsed.size else { return false }
        return attachmentSizeLabelMatches(size, byteCount: expected.byteCount)
    }

    static func isAttachmentLabel(_ label: String) -> Bool {
        parseAttachmentLabel(label) != nil
    }

    private static func parseAttachmentLabel(_ label: String) -> ParsedAttachmentLabel? {
        let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName: String
        let sizeText: String
        if value.hasSuffix(")"), let separator = value.range(of: " (", options: .backwards) {
            fileName = String(value[..<separator.lowerBound])
            sizeText = String(value[separator.upperBound..<value.index(before: value.endIndex)])
        } else if let separator = value.range(of: ",", options: .backwards) {
            fileName = String(value[..<separator.lowerBound])
            sizeText = String(value[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }
        guard !fileName.isEmpty, !fileName.contains("/"), !fileName.contains("\\"), !sizeText.isEmpty else { return nil }
        let size = parseAttachmentSizeLabel(sizeText)
        return .init(fileName: fileName, size: size)
    }

    private static func parseAttachmentSizeLabel(_ text: String) -> AttachmentSizeLabel? {
        guard let expression = try? NSRegularExpression(pattern: #"^\s*([0-9]+(?:[.,][0-9]+)?)\s*(bytes?|b|k|kb|kib|m|mb|mib|g|gb|gib|t|tb|tib)\s*$"#,
                                                        options: .caseInsensitive) else { return nil }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard let match = expression.firstMatch(in: text, range: fullRange), match.range == fullRange,
              match.numberOfRanges == 3,
              let amountRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text) else { return nil }
        let numberText = String(text[amountRange]).replacingOccurrences(of: ",", with: ".")
        guard let amount = Decimal(string: numberText, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let rawUnit = String(text[unitRange]).lowercased()
        let unit: String
        switch rawUnit {
        case "b", "byte", "bytes": unit = "B"
        case "k", "kb", "kib": unit = "K"
        case "m", "mb", "mib": unit = "M"
        case "g", "gb", "gib": unit = "G"
        case "t", "tb", "tib": unit = "T"
        default: return nil
        }
        return .init(amount: amount, unit: unit)
    }

    private static func attachmentSizeLabelMatches(_ observed: AttachmentSizeLabel, byteCount: Int64) -> Bool {
        guard byteCount >= 0 else { return false }
        if observed.unit == "B", observed.amount == Decimal(byteCount) { return true }

        for style in [ByteCountFormatter.CountStyle.file, .binary] {
            let formatter = ByteCountFormatter()
            formatter.countStyle = style
            guard let expected = parseAttachmentSizeLabel(formatter.string(fromByteCount: byteCount)),
                  expected.unit == observed.unit else { continue }
            if expected.amount == observed.amount { return true }
            var expectedAmount = expected.amount
            var rounded = Decimal()
            NSDecimalRound(&rounded, &expectedAmount, 0, .plain)
            if observed.amount == rounded { return true }
        }
        return false
    }

    func hasVisibleAttachmentRemovalControl(_ observation: ComputerUseDefaultBrowserPageReader.Observation) -> Bool {
        observation.controls.contains { control in
            (control.role == "AXButton" || control.role == "AXPopUpButton")
                && control.label.localizedCaseInsensitiveContains("remove attachment")
        }
    }

    func verifiesSend(_ observation: ComputerUseDefaultBrowserPageReader.Observation) -> Bool {
        request.sendRequested && URL(string: observation.url).map { Self.isGmailURL($0) && matchesAccount($0) } == true && observation.exactTextValues.contains {
            $0.localizedCaseInsensitiveContains("Message sent")
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

    func attachApprovalPresentation() -> MCPComputerUseApprovalPresentation? {
        guard requiresAttachment, let attachment, let account = request.account else { return nil }
        var details = [
            ComputerUseApprovalRequest.Detail(label: "File", value: attachment.displayName),
            ComputerUseApprovalRequest.Detail(label: "Size", value: "\(attachment.byteCount) bytes"),
            ComputerUseApprovalRequest.Detail(label: "Destination", value: "Gmail (\(account.email))"),
            ComputerUseApprovalRequest.Detail(label: "To", value: request.to.joined(separator: ", ")),
            ComputerUseApprovalRequest.Detail(label: "Subject", value: request.subject),
        ]
        if !request.cc.isEmpty { details.append(.init(label: "CC", value: request.cc.joined(separator: ", "))) }
        if !request.bcc.isEmpty { details.append(.init(label: "BCC", value: request.bcc.joined(separator: ", "))) }
        return .init(message: "Attach this file to the Gmail draft?", details: details, confirmLabel: "Attach file")
    }

    static func isApprovedDraftURL(_ url: URL) -> Bool {
        isGmailURL(url) && isComposeOrDraftURL(url)
    }

    static func isOpaqueComposeDraftURL(_ url: URL) -> Bool {
        guard isGmailURL(url), let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment else {
            return false
        }
        return fragment.range(of: #"^drafts\?compose=[A-Za-z0-9_-]{6,256}$"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func uniqueDraftSubjectCellIndex(rowTexts: [String], scanComplete: Bool, subject: String) -> Int? {
        guard scanComplete, !subject.isEmpty else { return nil }
        let matches = rowTexts.indices.filter { rowTexts[$0] == subject }
        return matches.count == 1 ? matches[0] : nil
    }

    static func primaryDraftSubjectCellText(cellValue: String?, firstDescendantStaticText: String?) -> String? {
        if let cellValue, !cellValue.isEmpty { return cellValue }
        guard let firstDescendantStaticText, !firstDescendantStaticText.isEmpty else { return nil }
        return firstDescendantStaticText
    }

    private func matchesAccount(_ url: URL) -> Bool {
        guard let account = request.account else { return true }
        return ComputerUseGmailAccountDirectory.accountIndex(from: url.absoluteString) == account.index
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

enum ComputerUseGmailAccountDirectory {
    struct Account: Equatable, Hashable, Sendable {
        let email: String
        let displayName: String
        let index: Int
    }
    struct Link: Equatable, Sendable { let label: String; let url: String }
    struct Snapshot: Equatable, Sendable { let current: Account; let accounts: [Account] }
    enum MenuRead: Equatable, Sendable { case notOpen, invalid, accounts(Snapshot) }
    enum PreferenceResolution: Equatable, Sendable {
        case askUser
        case selected(Account)
        case unavailable
    }

    static func resolvePreference(_ preferredEmail: String?, in snapshot: Snapshot) -> PreferenceResolution {
        guard let preferredEmail else { return .askUser }
        guard let match = snapshot.accounts.first(where: {
            $0.email.caseInsensitiveCompare(preferredEmail) == .orderedSame
        }) else { return .unavailable }
        return .selected(match)
    }

    static func accountIndex(from rawURL: String, requireAccountLink: Bool = false) -> Int? {
        guard let url = URL(string: rawURL), let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "https", c.host?.lowercased() == "mail.google.com",
              c.user == nil, c.password == nil, c.port == nil,
              !requireAccountLink || (c.query == nil && c.fragment == nil),
              let match = c.path.range(of: #"^/mail/u/([0-9]+)/?$"#, options: .regularExpression),
              let range = c.path[match].range(of: #"[0-9]+"#, options: .regularExpression),
              let index = Int(c.path[range]), (0...9_999).contains(index) else { return nil }
        return index
    }

    static func confirmsActiveAccount(currentURL: String, windowTitle: String?, accountControlLabel: String?,
                                      expected: Account) -> Bool {
        guard accountIndex(from: currentURL) == expected.index else { return false }
        if let accountControlLabel {
            guard accountControlLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                .range(of: #"^Google Account:"#, options: [.regularExpression, .caseInsensitive]) != nil,
                  email(in: accountControlLabel)?.caseInsensitiveCompare(expected.email) == .orderedSame else { return false }
            if let titleEmail = standaloneComposerEmail(windowTitle, currentURL: currentURL),
               titleEmail.caseInsensitiveCompare(expected.email) != .orderedSame { return false }
            return true
        }
        return standaloneComposerEmail(windowTitle, currentURL: currentURL)?
            .caseInsensitiveCompare(expected.email) == .orderedSame
    }

    static func standaloneComposerEmail(_ rawTitle: String?, currentURL: String) -> String? {
        guard let rawTitle,
              let url = URL(string: currentURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              accountIndex(from: currentURL) != nil,
              components.queryItems?.filter({ $0.name == "fs" }).count == 1,
              components.queryItems?.first(where: { $0.name == "fs" })?.value == "1",
              components.queryItems?.filter({ $0.name == "tf" }).count == 1,
              components.queryItems?.first(where: { $0.name == "tf" })?.value == "cm",
              let match = rawTitle.range(of: #"^Compose Mail - ([^\s@]+@[^\s@]+) - Gmail$"#,
                options: [.regularExpression, .caseInsensitive]),
              let emailRange = rawTitle[match].range(of: #"[^\s@]+@[^\s@]+"#, options: .regularExpression) else { return nil }
        return email(in: String(rawTitle[match][emailRange]))
    }

    @MainActor
    static func observedWindowTitle(window: AXUIElement, application: ComputerUseApplicationIdentity,
                                    revalidate: @MainActor () throws -> Void) throws -> String? {
        try revalidate()
        guard frontmostMatches(application) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success,
              let title = value as? String, !title.isEmpty else { return nil }
        try revalidate()
        return title
    }

    static func inboxURL(index: Int) -> URL? {
        guard (0...9_999).contains(index) else { return nil }
        return URL(string: "https://mail.google.com/mail/u/\(index)/")
    }

    static func draftsURL(index: Int) -> URL? {
        guard (0...9_999).contains(index) else { return nil }
        return URL(string: "https://mail.google.com/mail/u/\(index)/#drafts")
    }

    static func email(in rawLabel: String) -> String? {
        let pattern = #"[A-Z0-9.!#$%&'*+/=?^_`{|}~-]{1,128}@[A-Z0-9](?:[A-Z0-9-]{0,188}[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]{0,62}[A-Z0-9])?)+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = rawLabel as NSString
        let matches = regex.matches(in: rawLabel, range: NSRange(location: 0, length: ns.length))
        guard matches.count == 1, let range = Range(matches[0].range, in: rawLabel) else { return nil }
        let value = String(rawLabel[range])
        guard value.utf8.count <= 320, !value.contains("..") else { return nil }
        return value.lowercased()
    }

    static func snapshot(currentLabel: String, currentURL: String, links: [Link]) -> Snapshot? {
        guard currentLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                .range(of: #"^Google Account:"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let currentEmail = email(in: currentLabel), let currentIndex = accountIndex(from: currentURL) else { return nil }
        func name(_ label: String, email: String) -> String {
            var value = label.replacingOccurrences(of: email, with: "", options: .caseInsensitive)
            value = value.replacingOccurrences(of: #"\(opens a new tab\)"#, with: "",
                options: [.regularExpression, .caseInsensitive])
            value = value.replacingOccurrences(of: #"^Google Account:"#, with: "", options: .regularExpression)
            value = value.replacingOccurrences(of: #"\([^)]*@[^)]*\)"#, with: "", options: .regularExpression)
            value = value.replacingOccurrences(of: #",\s*Google membership$"#, with: "", options: [.regularExpression, .caseInsensitive])
            value = value.replacingOccurrences(of: #"\s+(?:AI Pro\s+)?account(?:\s+Collapse accounts list)?$"#,
                with: "", options: [.regularExpression, .caseInsensitive])
            value = value.replacingOccurrences(of: #"\s+Collapse accounts list$"#,
                with: "", options: [.regularExpression, .caseInsensitive])
            value = value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "(),")))
            return value.isEmpty ? email : String(value.prefix(96))
        }
        let current = Account(email: currentEmail, displayName: name(currentLabel, email: currentEmail), index: currentIndex)
        var byEmail: [String: Account] = [current.email: current]
        var byIndex: [Int: String] = [current.index: current.email]
        for link in links {
            let lower = link.label.lowercased()
            guard !["signed out", "sign in", "sign out", "add another account"].contains(where: lower.contains),
                  let index = accountIndex(from: link.url, requireAccountLink: true),
                  let address = email(in: link.label) else { continue }
            let item = Account(email: address, displayName: name(link.label, email: address), index: index)
            if let prior = byEmail[address], prior.index != index { return nil }
            if let priorEmail = byIndex[index], priorEmail != address { return nil }
            byEmail[address] = item
            byIndex[index] = address
        }
        guard byEmail.count <= ComputerUseClarificationChoice.maximumChoices else { return nil }
        return Snapshot(current: current, accounts: byEmail.values.sorted { $0.index < $1.index })
    }

    @MainActor
    static func openMenu(observation: ComputerUseDefaultBrowserPageReader.Observation,
        window: AXUIElement, reader: ComputerUseDefaultBrowserPageReader,
        revalidate: @MainActor () throws -> Void) throws -> Bool {
        try revalidate()
        let controls = observation.controls.filter { $0.role == "AXButton" && $0.label.hasPrefix("Google Account:") }
        guard controls.count == 1,
              let element = reader.retainedControl(observationID: observation.id, controlID: controls[0].id,
                application: observation.application, window: window) else { return false }
        var raw: CFArray?
        guard AXUIElementCopyActionNames(element, &raw) == .success,
              (raw as? [String])?.contains("AXPress") == true else { return false }
        try revalidate()
        guard AXUIElementPerformAction(element, "AXPress" as CFString) == .success else { return false }
        try revalidate()
        return true
    }

    @MainActor
    static func readMenu(window: AXUIElement, application: ComputerUseApplicationIdentity, currentURL: String,
        closeMenu: Bool, revalidate: @MainActor () throws -> Void) throws -> MenuRead {
        try revalidate()
        guard frontmostMatches(application) else { return .invalid }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        var visited = 0, overflow = false, outerWebAreaSeen = false
        func read(_ element: AXUIElement, _ attr: String) -> CFTypeRef? {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { overflow = true; return nil }
            AXUIElementSetMessagingTimeout(element, 0.1)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
                  !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            return value
        }
        var groups: [AXUIElement] = []
        func find(_ element: AXUIElement, depth: Int) {
            guard depth <= 16, visited < 512, ContinuousClock.now < deadline, !Task.isCancelled else { overflow = true; return }
            visited += 1
            if read(element, kAXHiddenAttribute as String) as? Bool == true
                || read(element, "AXProtectedContent") as? Bool == true { return }
            let role = read(element, kAXRoleAttribute as String) as? String ?? ""
            guard !["AXTable", "AXOutline", "AXList", "AXTextArea", "AXSecureTextField"].contains(role) else { return }
            if role == "AXWebArea" { guard !outerWebAreaSeen else { return }; outerWebAreaSeen = true }
            if role == "AXGroup" {
                let labels = [kAXTitleAttribute, kAXDescriptionAttribute]
                    .compactMap { read(element, $0 as String) as? String }
                if labels.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare("Account and settings") == .orderedSame }) {
                    groups.append(element); return
                }
            }
            guard let children = read(element, kAXChildrenAttribute as String) as? [AXUIElement], children.count <= 128 else {
                if ["AXWindow", "AXGroup", "AXWebArea", "AXScrollArea"].contains(role) { overflow = true }
                return
            }
            children.forEach { find($0, depth: depth + 1) }
        }
        find(window, depth: 0)
        guard !overflow, !Task.isCancelled, ContinuousClock.now < deadline else { return .invalid }
        guard !groups.isEmpty else { return .notOpen }
        guard groups.count == 1 else { return .invalid }
        let root = groups[0]
        var nodesVisited = 0, treeInvalid = false
        guard let currentLabel = try ComputerUseGmailRecipientVerifier.accountControlLabel(
            window: window, application: application, revalidate: revalidate),
              let currentEmail = email(in: currentLabel) else { return .invalid }
        var selectedMenuEmails = Set<String>(), links: [Link] = [], closeButtons: [AXUIElement] = []
        var menuOverflow = false
        func collect(_ element: AXUIElement, depth: Int) {
            guard depth <= 12, nodesVisited < 128, ContinuousClock.now < deadline, !Task.isCancelled else {
                menuOverflow = true; return
            }
            nodesVisited += 1
            let role = read(element, kAXRoleAttribute as String) as? String ?? ""
            if read(element, kAXHiddenAttribute as String) as? Bool == true
                || read(element, "AXProtectedContent") as? Bool == true
                || ["AXTable", "AXOutline", "AXList", "AXTextArea", "AXSecureTextField", "AXTextField"].contains(role) {
                return
            }
            if role == "AXButton" || role == "AXLink" {
                let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute]
                    .compactMap { read(element, $0 as String) as? String }
                if role == "AXButton" {
                    for label in labels where label.localizedCaseInsensitiveContains("Collapse accounts list") {
                        if let email = email(in: label) { selectedMenuEmails.insert(email) }
                    }
                    if labels.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .localizedCaseInsensitiveCompare("Close") == .orderedSame }) { closeButtons.append(element) }
                } else if role == "AXLink" {
                    let raw = read(element, "AXURL")
                    let url = (raw as? URL)?.absoluteString ?? raw as? String ?? ""
                    if let label = labels.first { links.append(.init(label: label, url: url)) }
                }
            }
            guard let children = read(element, kAXChildrenAttribute as String) as? [AXUIElement], children.count <= 128 else {
                if ["AXGroup", "AXMenu", "AXWindow"].contains(role) { treeInvalid = true }
                return
            }
            children.forEach { collect($0, depth: depth + 1) }
        }
        collect(root, depth: 0)
        guard !treeInvalid, !menuOverflow, !overflow, !Task.isCancelled, ContinuousClock.now < deadline,
              selectedMenuEmails.count == 1, selectedMenuEmails.contains(currentEmail),
              let snapshot = snapshot(currentLabel: currentLabel, currentURL: currentURL, links: links) else { return .invalid }
        if closeMenu {
            guard closeButtons.count == 1 else { return .invalid }
            var actions: CFArray?
            guard AXUIElementCopyActionNames(closeButtons[0], &actions) == .success,
                  (actions as? [String])?.contains("AXPress") == true else { return .invalid }
            try revalidate()
            guard AXUIElementPerformAction(closeButtons[0], "AXPress" as CFString) == .success else { return .invalid }
            try revalidate()
        }
        return .accounts(snapshot)
    }

    @MainActor
    private static func frontmostMatches(_ expected: ComputerUseApplicationIdentity) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated else { return false }
        return app.processIdentifier == expected.processIdentifier && app.bundleIdentifier == expected.bundleIdentifier
    }
}

@MainActor
final class ComputerUseGmailAccountPreferences {
    private let defaults: UserDefaults
    private let key: String
    init(defaults: UserDefaults = .standard, key: String = "ComputerUse.gmail.accountEmail") {
        self.defaults = defaults; self.key = key
    }
    var preferredEmail: String? { defaults.string(forKey: key).map { $0.lowercased() } }
    func remember(_ account: ComputerUseGmailAccountDirectory.Account) { defaults.set(account.email, forKey: key) }
}

/// Reads the actual recipient chips from one Gmail compose region. Each chip
/// must expose an AXShowMenu action whose menu contains its exact Copy-address
/// item; visible names and account headers are never treated as addresses.
@MainActor
enum ComputerUseGmailRecipientVerifier {
    static func pressExactDraftSubjectRow(window: AXUIElement, application: ComputerUseApplicationIdentity,
        subject: String, expectedCell: AXUIElement, expectedRow: AXUIElement, expectedBounds: CGRect,
        revalidate: @MainActor () throws -> Void, willDispatch: @MainActor () -> Void) throws -> Bool {
        try revalidate()
        var ambiguous = false
        guard let current = try exactDraftSubjectCellEvidence(window: window, application: application,
            subject: subject, ambiguous: &ambiguous, revalidate: revalidate),
              !ambiguous, CFEqual(current.cell, expectedCell), CFEqual(current.row, expectedRow),
              current.bounds.equalTo(expectedBounds) else { return false }
        try revalidate()
        willDispatch()
        guard AXUIElementPerformAction(current.row, "AXPress" as CFString) == .success else { return false }
        return true
    }

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
        let title: String?
        let description: String?
        let value: String?
        let children: [Node]

        init(element: AXUIElement, role: String, strings: [String], title: String?, description: String?,
             value: String?, children: [Node]) {
            self.element = element
            self.role = role
            self.strings = strings
            self.title = title
            self.description = description
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

    static func exactDraftSubjectCellEvidence(window: AXUIElement, application: ComputerUseApplicationIdentity,
                                              subject: String,
                                              ambiguous: inout Bool,
                                              diagnostic: ((String) -> Void)? = nil,
                                              revalidate: @MainActor () throws -> Void)
        throws -> (cell: AXUIElement, row: AXUIElement, bounds: CGRect)? {
        var visited = 0, maxDepth = 0, maxChildren = 0, scanReason = "none"
        func report(_ phase: String, reason: String? = nil, exactMatches: Int = 0) {
            diagnostic?("phase=\(phase) reason=\(reason ?? scanReason) visited=\(visited) max_depth=\(maxDepth) max_children=\(maxChildren) exact_matches=\(exactMatches)")
        }
        func failScan(_ reason: String) {
            if scanReason == "none" { scanReason = reason }
        }
        func deadlineOrCancellationReason() -> String {
            Task.isCancelled ? "cancelled" : "deadline"
        }
        do { try revalidate() }
        catch {
            report("revalidation_failed", reason: "revalidation_failed")
            throw error
        }
        guard frontmostMatches(application), !subject.isEmpty else {
            report("preflight_rejected", reason: "preflight_rejected")
            return nil
        }
        // Gmail's Drafts table can expose hundreds of empty AXCell values;
        // allow one bounded fresh traversal to read the first static-text fallback.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var overflow = false, outerWebAreaSeen = false
        var cellTexts: [String] = []
        var cellElements: [AXUIElement] = []
        var visitedElements: [AXUIElement] = []
        func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            guard !Task.isCancelled, ContinuousClock.now < deadline else {
                overflow = true
                failScan(deadlineOrCancellationReason())
                return nil
            }
            AXUIElementSetMessagingTimeout(element, 0.1)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                  !Task.isCancelled, ContinuousClock.now < deadline else {
                if Task.isCancelled || ContinuousClock.now >= deadline {
                    overflow = true
                    failScan(deadlineOrCancellationReason())
                }
                return nil
            }
            return value
        }
        func visit(_ element: AXUIElement, depth: Int, activeCellIndex: Int?) {
            guard !visitedElements.contains(where: { CFEqual($0, element) }) else { return }
            visitedElements.append(element)
            maxDepth = max(maxDepth, depth)
            guard depth <= 16 else { overflow = true; failScan("depth_limit"); return }
            guard visited < 1_800 else { overflow = true; failScan("node_limit"); return }
            guard !Task.isCancelled, ContinuousClock.now < deadline else {
                overflow = true
                failScan(deadlineOrCancellationReason())
                return
            }
            visited += 1
            if read(element, kAXHiddenAttribute as String) as? Bool == true
                || read(element, "AXProtectedContent") as? Bool == true { return }
            let role = read(element, kAXRoleAttribute as String) as? String ?? ""
            let subrole = read(element, kAXSubroleAttribute as String) as? String ?? ""
            guard subrole != (kAXSecureTextFieldSubrole as String),
                  !["AXTextArea", "AXSecureTextField", "AXMenu", "AXMenuItem"].contains(role) else { return }
            if role == "AXWebArea" {
                guard !outerWebAreaSeen else { return }
                outerWebAreaSeen = true
            }
            var descendantCellIndex = activeCellIndex
            if outerWebAreaSeen, role == "AXCell" {
                let index = cellTexts.count
                let value = read(element, kAXValueAttribute as String) as? String
                cellTexts.append(ComputerUseGmailJob.primaryDraftSubjectCellText(
                    cellValue: value, firstDescendantStaticText: nil) ?? "")
                cellElements.append(element)
                descendantCellIndex = index
            } else if outerWebAreaSeen, role == "AXStaticText",
                      let index = descendantCellIndex, cellTexts.indices.contains(index), cellTexts[index].isEmpty {
                let value = read(element, kAXValueAttribute as String) as? String
                cellTexts[index] = ComputerUseGmailJob.primaryDraftSubjectCellText(
                    cellValue: nil, firstDescendantStaticText: value) ?? ""
            }
            guard let children = read(element, kAXChildrenAttribute as String) as? [AXUIElement] else {
                if ["AXWindow", "AXGroup", "AXWebArea", "AXTable", "AXRow", "AXScrollArea"].contains(role) {
                    overflow = true
                    failScan(role == "AXScrollArea" ? "scroll_children_unavailable" : "container_children_unavailable")
                }
                return
            }
            maxChildren = max(maxChildren, children.count)
            guard children.count <= 128 else { overflow = true; failScan("children_limit"); return }
            children.forEach { visit($0, depth: depth + 1, activeCellIndex: descendantCellIndex) }
        }
        visit(window, depth: 0, activeCellIndex: nil)
        let exactCellIndices = cellTexts.indices.filter { cellTexts[$0] == subject }
        guard !overflow, outerWebAreaSeen else {
            report("scan_incomplete", reason: outerWebAreaSeen ? nil : "webarea_missing", exactMatches: exactCellIndices.count)
            return nil
        }
        if exactCellIndices.count > 1 {
            ambiguous = true
            report("ambiguous_subject", reason: "duplicate_subject", exactMatches: exactCellIndices.count)
            return nil
        }
        guard let selectedCellIndex = ComputerUseGmailJob.uniqueDraftSubjectCellIndex(
                rowTexts: cellTexts, scanComplete: true, subject: subject),
              cellElements.indices.contains(selectedCellIndex),
              !Task.isCancelled, ContinuousClock.now < deadline else {
            report("subject_not_unique", reason: "subject_missing", exactMatches: exactCellIndices.count)
            return nil
        }

        let cell = cellElements[selectedCellIndex]
        var ancestor = cell
        var row: AXUIElement?
        for _ in 0..<12 {
            guard let parentValue = read(ancestor, kAXParentAttribute as String),
                  CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { break }
            let parent = unsafeBitCast(parentValue, to: AXUIElement.self)
            let role = read(parent, kAXRoleAttribute as String) as? String ?? ""
            if role == "AXRow" {
                row = parent
                break
            }
            ancestor = parent
            if CFEqual(parent, window) { break }
        }
        guard let row else {
            report("row_missing", reason: "row_missing", exactMatches: exactCellIndices.count)
            return nil
        }
        guard let position = read(cell, kAXPositionAttribute as String),
              let size = read(cell, kAXSizeAttribute as String),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            report("bounds_missing", reason: "bounds_missing", exactMatches: exactCellIndices.count)
            return nil
        }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else {
            report("bounds_invalid", reason: "bounds_invalid", exactMatches: exactCellIndices.count)
            return nil
        }
        do { try revalidate() }
        catch {
            report("revalidation_failed", reason: "revalidation_failed", exactMatches: exactCellIndices.count)
            throw error
        }
        guard frontmostMatches(application) else {
            report("revalidation_failed", reason: "revalidation_failed", exactMatches: exactCellIndices.count)
            return nil
        }
        report("verified", exactMatches: exactCellIndices.count)
        return (cell, row, CGRect(origin: point, size: dimensions))
    }

    static func attachmentEvidence(window: AXUIElement, application: ComputerUseApplicationIdentity,
                                   expected: ComputerUseGmailJob.Attachment?,
                                   revalidate: @MainActor () throws -> Void) throws -> AttachmentEvidence {
        try revalidate()
        guard frontmostMatches(application), let compose = try composeRegion(window: window) else {
            return .conflicting
        }
        let nodes = descendants(of: compose)
        let containers = nodes.filter(isAttachmentContainer)
        let linksInContainer = containers.count == 1
            ? descendants(of: containers[0]).filter { $0.role == "AXLink" }
            : []
        let candidateNodes = containers.isEmpty ? nodes.filter { $0.role == "AXStaticText" } : linksInContainer
        let labelsByNode = candidateNodes.map(attachmentLabels(for:))
        let removalControlCount = nodes.filter { node in
            node.role == "AXButton" && (node.title.map { isRemoveAttachmentLabel($0) } == true
                || node.description.map { isRemoveAttachmentLabel($0) } == true
                || node.value.map { isRemoveAttachmentLabel($0) } == true)
        }.count
        try revalidate()
        return classifyAttachmentEvidence(labelsByNode: labelsByNode,
            attachmentContainerCount: containers.count,
            attachmentContainerLinkCount: containers.count == 1 ? linksInContainer.count : nil,
            removalControlCount: removalControlCount, expected: expected)
    }

    static func classifyAttachmentEvidence(labelsByNode: [[String]], attachmentContainerCount: Int,
                                           attachmentContainerLinkCount: Int?, removalControlCount: Int,
                                           expected: ComputerUseGmailJob.Attachment?) -> AttachmentEvidence {
        guard attachmentContainerCount >= 0, removalControlCount >= 0 else { return .conflicting }
        if attachmentContainerCount > 1 { return .conflicting }
        if removalControlCount > 1 { return .conflicting }
        if attachmentContainerCount == 1,
           (attachmentContainerLinkCount != 1 || removalControlCount != 1) { return .conflicting }

        let parsed = labelsByNode.flatMap { labels in
            Array(Set(labels)).filter(ComputerUseGmailJob.isAttachmentLabel)
        }
        if parsed.isEmpty, attachmentContainerCount == 0, removalControlCount == 0 { return .absent }
        guard let expected else { return .conflicting }
        let matches = parsed.filter { ComputerUseGmailJob.attachmentLabelMatches($0, expected: expected) }
        if parsed.count == 1, matches.count == 1 { return .matching }
        return .conflicting
    }

    private static func isAttachmentContainer(_ node: Node) -> Bool {
        guard node.role == "AXGroup" else { return false }
        return [node.title, node.description].compactMap { $0 }.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .range(of: "Attachment:", options: [.anchored, .caseInsensitive]) != nil
        }
    }

    private static func isRemoveAttachmentLabel(_ label: String) -> Bool {
        label.localizedCaseInsensitiveContains("remove attachment")
    }

    private static func attachmentLabels(for node: Node) -> [String] {
        let values: [String]
        if node.role == "AXStaticText" {
            values = [node.value, node.title, node.description].compactMap { $0 }
        } else {
            // Gmail's attachment link exposes its display text in title/description;
            // its URL is not evidence of the selected attachment.
            values = [node.title, node.description].compactMap { $0 }
        }
        return Array(Set(values))
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
                  !["AXTable", "AXOutline", "AXList", "AXTextArea", "AXSecureTextField", "AXMenu", "AXMenuItem", "AXSheet"].contains(role) else { return }
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
            let title = read(element, kAXTitleAttribute as String) as? String
            let description = read(element, kAXDescriptionAttribute as String) as? String
            let strings = [title, description].compactMap { $0 }
                + [kAXHelpAttribute, kAXIdentifierAttribute, kAXPlaceholderValueAttribute]
                .compactMap { read(element, $0 as String) as? String }
            let value = role == "AXStaticText" ? read(element, kAXValueAttribute as String) as? String : nil
            let childValue = read(element, kAXChildrenAttribute as String)
            let childElements = childValue as? [AXUIElement]
            if childValue == nil && ["AXWindow", "AXGroup", "AXWebArea", "AXComboBox", "AXScrollArea", "AXMenu"].contains(role) {
                overflow = true
            }
            if (childElements?.count ?? 0) > 128 { overflow = true; return nil }
            let children = (childElements ?? []).compactMap { makeNode($0, depth: depth + 1) }
            return Node(element: element, role: role, strings: strings, title: title,
                description: description, value: value, children: children)
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

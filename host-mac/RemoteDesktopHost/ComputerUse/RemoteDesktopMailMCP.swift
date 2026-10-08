import Foundation
import MCP
import OSLog
#if canImport(Darwin)
import Darwin
#endif

/// The Mail capability is compiled into the signed host and connected through
/// the official Swift MCP SDK's in-memory transport. It does not inherit shell
/// state, open a listener, contact a remote service, or require an API key.
enum RemoteDesktopMailMCP {
    static let serverID = "com.threadmark.remotedesktop.host.mail-mcp"
    static let serverName = "remote-desktop-mail"
    static let serverVersion = "1.0.0"
    static let toolName = "remote_desktop_mail"

    static let reviewedDescription = """
    Create a visible plain-text email draft in Apple Mail, or send it after explicit user approval. \
    This tool works only with Apple Mail; it cannot access webmail or discover the account's email address. \
    Supply optional attachment_paths only as exact absolute local file paths. \
    Provide explicit mailbox addresses only, separated by commas, semicolons, or newlines; \
    names, display-name forms, and aliases such as "me" are not resolved. Set send_now to false to open \
    a draft for review, or true only when the user explicitly asked to send now. Mail uses \
    the user's default sending account; this tool does not silently select another account.
    """

    static let inputSchema: MCPJSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "to": .object([
                "type": .string("string"),
                "description": .string("Required explicit mailbox addresses only, separated by commas, semicolons, or newlines; no names or aliases."),
            ]),
            "cc": .object([
                "type": .string("string"),
                "description": .string("Optional explicit mailbox addresses only, separated by commas, semicolons, or newlines; no names or aliases."),
            ]),
            "bcc": .object([
                "type": .string("string"),
                "description": .string("Optional explicit mailbox addresses only, separated by commas, semicolons, or newlines; no names or aliases."),
            ]),
            "subject": .object([
                "type": .string("string"),
                "description": .string("The exact email subject."),
            ]),
            "body": .object([
                "type": .string("string"),
                "description": .string("The exact plain-text email body."),
            ]),
            "attachment_paths": .object([
                "type": .string("array"),
                "maxItems": .integer(5),
                "uniqueItems": .bool(true),
                "items": .object([
                    "type": .string("string"),
                    "minLength": .integer(1),
                    "maxLength": .integer(1_024),
                ]),
                "description": .string("Optional exact absolute local file paths to attach."),
            ]),
            "send_now": .object([
                "type": .string("boolean"),
                "description": .string("False opens a visible draft; true sends only after explicit approval."),
            ]),
        ]),
        "required": .array([
            .string("to"),
            .string("subject"),
            .string("body"),
            .string("send_now"),
        ]),
        "additionalProperties": .bool(false),
    ])
}

struct RemoteDesktopMailRecipientFailure: Error, Equatable, Sendable {
    enum Field: Equatable, Sendable {
        case to
        case cc
        case bcc
    }

    let field: Field

    static func safeQuestion(for field: Field) -> String {
        switch field {
        case .to: return "What email address should I use for the To recipient?"
        case .cc: return "What email address should I use for the CC recipient?"
        case .bcc: return "What email address should I use for the BCC recipient?"
        }
    }
}

struct RemoteDesktopMailRequest: Equatable, Sendable {
    static let maximumRecipientsPerField = 100
    static let maximumRecipientBytes = 512
    static let maximumApprovalValueBytes = 8_000
    static let maximumSubjectBytes = 4 * 1_024
    static let maximumBodyBytes = maximumApprovalValueBytes
    static let maximumAttachments = 5
    static let maximumAttachmentPathBytes = 1_024
    static let maximumAttachmentBytes = 25 * 1_024 * 1_024

    let to: String
    let cc: String
    let bcc: String
    let subject: String
    let body: String
    let sendNow: Bool
    let attachmentPaths: [String]

    init(arguments: [String: MCPJSONValue]) throws {
        let allowed = Set(["to", "cc", "bcc", "subject", "body", "send_now", "attachment_paths"])
        let unknown = Set(arguments.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw MCPClientError.invalidArguments(
                "The Mail request contains unknown fields: \(unknown.sorted().joined(separator: ", ")).")
        }
        guard case .string(let to)? = arguments["to"],
              case .string(let subject)? = arguments["subject"],
              case .string(let body)? = arguments["body"],
              case .bool(let sendNow)? = arguments["send_now"] else {
            throw MCPClientError.invalidArguments(
                "Mail requires string to, subject, and body fields plus an explicit send_now boolean.")
        }
        let cc = try Self.optionalString(arguments["cc"], name: "cc")
        let bcc = try Self.optionalString(arguments["bcc"], name: "bcc")
        let attachmentPaths = try Self.attachmentPaths(arguments["attachment_paths"])

        _ = try Self.recipients(in: to, field: .to)
        _ = try Self.recipients(in: cc, field: .cc)
        _ = try Self.recipients(in: bcc, field: .bcc)
        guard subject.utf8.count <= Self.maximumSubjectBytes,
              !subject.contains("\0"),
              !subject.contains("\r"),
              !subject.contains("\n") else {
            throw MCPClientError.invalidArguments(
                "The Mail subject is too long or contains an unsupported control character.")
        }
        guard body.utf8.count <= Self.maximumBodyBytes,
              !body.contains("\0") else {
            throw MCPClientError.invalidArguments(
                "The Mail body is too long or contains an unsupported null character.")
        }

        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.sendNow = sendNow
        self.attachmentPaths = attachmentPaths
    }

    /// The fixed JXA program receives one bounded JSON value over stdin.
    /// Message fields never appear in source, argv, or environment. Only approved
    /// attachment bytes are staged privately while Mail copies them.
    func automationPayload(attachments: [RemoteDesktopMailAttachmentSnapshot] = []) throws -> Data {
        guard attachments.map(\.path) == attachmentPaths else {
            throw MCPClientError.approvalMismatch
        }
        return try JSONEncoder().encode(AutomationPayload(
            to: try Self.recipients(in: to, field: .to),
            cc: try Self.recipients(in: cc, field: .cc),
            bcc: try Self.recipients(in: bcc, field: .bcc),
            subject: subject,
            body: body,
            sendNow: sendNow,
            attachments: attachments.map {
                .init(fileName: $0.fileName, base64Data: $0.data.base64EncodedString())
            }))
    }

    private struct AutomationPayload: Codable {
        let to: [String]
        let cc: [String]
        let bcc: [String]
        let subject: String
        let body: String
        let sendNow: Bool
        let attachments: [PayloadAttachment]

        enum CodingKeys: String, CodingKey {
            case to, cc, bcc, subject, body
            case sendNow = "send_now"
            case attachments
        }
    }

    private struct PayloadAttachment: Codable {
        let fileName: String
        let base64Data: String

        enum CodingKeys: String, CodingKey {
            case fileName = "file_name"
            case base64Data = "base64_data"
        }
    }

    private static func attachmentPaths(_ value: MCPJSONValue?) throws -> [String] {
        guard let value else { return [] }
        guard case .array(let entries) = value, entries.count <= maximumAttachments else {
            throw MCPClientError.invalidArguments("Mail attachment_paths must contain at most five exact file paths.")
        }
        var seenPaths = Set<String>()
        var result: [String] = []
        for entry in entries {
            guard case .string(let path) = entry, !path.isEmpty,
                  path.utf8.count <= maximumAttachmentPathBytes,
                  !path.contains("\0"),
                  !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw MCPClientError.invalidArguments("Mail attachment_paths contains an invalid file path.")
            }
            let url = URL(fileURLWithPath: path)
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.hasPrefix("/"),
                  components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  url.lastPathComponent != ".", url.lastPathComponent != "/" else {
                throw MCPClientError.invalidArguments("Mail attachments require exact absolute normalized file paths.")
            }
            guard seenPaths.insert(path).inserted else {
                throw MCPClientError.invalidArguments("Mail attachment paths must be unique.")
            }
            result.append(path)
        }
        return result
    }

    private static func optionalString(
        _ value: MCPJSONValue?,
        name: String
    ) throws -> String {
        guard let value else { return "" }
        guard case .string(let string) = value else {
            throw MCPClientError.invalidArguments("Mail field \(name) must be a string.")
        }
        return string
    }

    private static func recipients(
        in value: String,
        field: RemoteDesktopMailRecipientFailure.Field
    ) throws -> [String] {
        let fieldName = String(describing: field)
        guard value.utf8.count <= maximumApprovalValueBytes else {
            throw MCPClientError.invalidArguments(
                "Mail field \(field) exceeds the exact mobile approval limit.")
        }
        let separators = CharacterSet(charactersIn: ",;\n")
        let recipients = value
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard field != .to || !recipients.isEmpty else {
            throw RemoteDesktopMailRecipientFailure(field: field)
        }
        guard recipients.count <= maximumRecipientsPerField else {
            throw MCPClientError.invalidArguments(
                "Mail field \(field) contains too many recipients.")
        }
        for recipient in recipients {
            guard recipient.utf8.count <= maximumRecipientBytes,
                  !recipient.contains("\0"),
                  !recipient.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw MCPClientError.invalidArguments(
                    "Mail field \(fieldName) contains an invalid recipient.")
            }
            guard isMailboxAddress(recipient) else {
                throw RemoteDesktopMailRecipientFailure(field: field)
            }
        }
        return recipients
    }

    private static func isMailboxAddress(_ value: String) -> Bool {
        var quoted = false
        var escaped = false
        var atIndex: String.Index?
        for index in value.indices {
            let character = value[index]
            if quoted {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    quoted = false
                }
            } else if character == "\"" {
                guard index == value.startIndex else { return false }
                quoted = true
            } else if character == "@" {
                guard atIndex == nil else { return false }
                atIndex = index
            }
        }
        guard !quoted, !escaped, let atIndex else { return false }
        let local = String(value[..<atIndex])
        let domain = String(value[value.index(after: atIndex)...])
        guard !local.isEmpty, !domain.isEmpty else { return false }

        if local.first == "\"" {
            guard local.count >= 2, local.last == "\"" else { return false }
            let content = local.dropFirst().dropLast()
            var contentEscaped = false
            for scalar in content.unicodeScalars {
                if contentEscaped {
                    contentEscaped = false
                } else if scalar == "\\" {
                    contentEscaped = true
                } else if scalar == "\"" {
                    return false
                } else if CharacterSet.controlCharacters.contains(scalar) {
                    return false
                }
            }
            guard !contentEscaped else { return false }
        } else {
            let atoms = local.split(separator: ".", omittingEmptySubsequences: false)
            guard atoms.allSatisfy({ !$0.isEmpty }) else { return false }
            let allowed = CharacterSet(charactersIn: "!#$%&'*+-/=?^_`{|}~")
            guard local.unicodeScalars.allSatisfy({
                $0 == "." || CharacterSet.alphanumerics.contains($0) || allowed.contains($0)
            }) else { return false }
        }

        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.first != "-", label.last != "-" else { return false }
            return label.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-"
            }
        }
    }
}

struct RemoteDesktopMailAttachmentSnapshot: Equatable, Sendable {
    let path: String
    let fileName: String
    let data: Data
}

/// Reads the exact selected local files through no-follow descriptors. The
/// approved bytes stay in host memory; the later Mail payload never reopens a
/// model-supplied path after approval.
enum RemoteDesktopMailAttachmentFileReader {
    static func snapshot(paths: [String]) throws -> [RemoteDesktopMailAttachmentSnapshot] {
        try Task.checkCancellation()
        guard paths.count <= RemoteDesktopMailRequest.maximumAttachments else {
            throw MCPClientError.invalidArguments("Mail attachments exceed the five-file limit.")
        }
        var total = 0
        return try paths.map { path in
            let data = try read(path: path, remainingLimit: RemoteDesktopMailRequest.maximumAttachmentBytes - total)
            total += data.count
            guard total <= RemoteDesktopMailRequest.maximumAttachmentBytes else {
                throw MCPClientError.invalidArguments("Mail attachments exceed the 25 MiB total limit.")
            }
            return .init(path: path, fileName: URL(fileURLWithPath: path).lastPathComponent, data: data)
        }
    }

    static func approvalDigest(_ snapshots: [RemoteDesktopMailAttachmentSnapshot]) throws -> String {
        try MCPDigest.sha256(of: .array(snapshots.map { snapshot in
            .object([
                "path": .string(snapshot.path),
                "file_name": .string(snapshot.fileName),
                "byte_count": .integer(snapshot.data.count),
                "content_sha256": .string(MCPDigest.sha256(snapshot.data)),
            ])
        }))
    }

    static func verifyUnchanged(_ snapshots: [RemoteDesktopMailAttachmentSnapshot]) throws {
        let current: [RemoteDesktopMailAttachmentSnapshot]
        do {
            current = try snapshot(paths: snapshots.map(\.path))
        } catch {
            throw MCPClientError.approvalMismatch
        }
        guard current == snapshots else {
            throw MCPClientError.approvalMismatch
        }
    }

    private static func read(path: String, remainingLimit: Int) throws -> Data {
        #if canImport(Darwin)
        let url = URL(fileURLWithPath: path)
        let resourceValues = try url.resourceValues(forKeys: [
            .isAliasFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ])
        guard resourceValues.isAliasFile != true,
              resourceValues.isUbiquitousItem != true
                || resourceValues.ubiquitousItemDownloadingStatus == .current else {
            throw MCPClientError.invalidArguments("Mail attachments must be available local files, not aliases or download placeholders.")
        }
        guard remainingLimit >= 0 else {
            throw MCPClientError.invalidArguments("Mail attachments exceed the 25 MiB total limit.")
        }
        var components = URL(fileURLWithPath: path).pathComponents.dropFirst().filter { !$0.isEmpty }
        guard let last = components.popLast(), !components.isEmpty else {
            throw MCPClientError.invalidArguments("A Mail attachment must be a regular file.")
        }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw MCPClientError.invalidArguments("The Mail attachment path is unavailable.") }
        defer { close(directory) }
        for component in components {
            let next = component.withCString { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else { throw MCPClientError.invalidArguments("Mail attachment paths cannot contain symbolic links.") }
            close(directory)
            directory = next
        }
        let descriptor = last.withCString { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC) }
        guard descriptor >= 0 else { throw MCPClientError.invalidArguments("The Mail attachment is unavailable or is a symbolic link.") }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              (before.st_flags & UInt32(SF_DATALESS)) == 0,
              before.st_size >= 0, before.st_size <= remainingLimit else {
            throw MCPClientError.invalidArguments("Mail attachments must be regular files within the 25 MiB total limit.")
        }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBufferPointer { bytes in
                Darwin.read(descriptor, bytes.baseAddress!, bytes.count)
            }
            guard count >= 0 else { throw MCPClientError.invalidArguments("The Mail attachment could not be read.") }
            if count == 0 { break }
            guard data.count + count <= remainingLimit else {
                throw MCPClientError.invalidArguments("Mail attachments exceed the 25 MiB total limit.")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, data.count == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw MCPClientError.approvalMismatch
        }
        return data
        #else
        throw MCPClientError.invalidArguments("Local Mail attachments are supported only on macOS.")
        #endif
    }
}

struct RemoteDesktopMailAutomationReceipt: Equatable, Sendable {
    let attachmentNames: [String]
    let draftSaved: Bool
}

enum RemoteDesktopMailAutomationStage: String, Decodable, Equatable, Sendable {
    case readRequest = "read_request"
    case activateMail = "activate_mail"
    case createMessage = "create_message"
    case setMessageFields = "set_message_fields"
    case prepareStaging = "prepare_staging"
    case stageAttachment = "stage_attachment"
    case attachFile = "attach_file"
    case verifyAttachedNames = "verify_attached_names"
    case sendMessage = "send_message"
    case saveDraft = "save_draft"
    case verifySavedDraft = "verify_saved_draft"
    case validateReceipt = "validate_receipt"
    case scriptProcess = "script_process"
    case complete
}

struct RemoteDesktopMailAutomationFailure: Error, Equatable, Sendable, LocalizedError {
    let stage: RemoteDesktopMailAutomationStage

    var errorDescription: String? {
        "Mail automation stopped at stage \(stage.rawValue)."
    }
}

protocol RemoteDesktopMailAutomationRunning: Sendable {
    func run(payload: Data) async throws -> RemoteDesktopMailAutomationReceipt
}

/// Only this fixed JXA source is executable. User/model values arrive as a
/// bounded JSON object on stdin and are never concatenated into source/argv.
enum RemoteDesktopMailJXA {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/osascript")

    static let savedBodyVerificationSource = #"""
    function mimeHeader(headers, name) {
        const unfolded = headers.replace(/\r?\n[ \t]+/g, " ");
        const prefix = name.toLowerCase() + ":";
        const line = unfolded.split(/\r?\n/).find(item => item.toLowerCase().indexOf(prefix) === 0);
        return line ? line.slice(prefix.length).trim() : "";
    }

    function mimeEntityParts(body, boundary, visit) {
        const marker = "--" + boundary;
        let markerAt = body.indexOf(marker);
        let count = 0;
        while (markerAt >= 0 && count < 12) {
            const contentAt = markerAt + marker.length;
            if (body.substr(contentAt, 2) === "--") break;
            let partStart = contentAt;
            if (body.substr(partStart, 2) === "\r\n") partStart += 2;
            else if (body.charAt(partStart) === "\n") partStart += 1;

            const crlfNext = body.indexOf("\r\n" + marker, partStart);
            const lfNext = body.indexOf("\n" + marker, partStart);
            let partEnd = -1;
            let nextMarker = -1;
            if (crlfNext >= 0 && (lfNext < 0 || crlfNext <= lfNext)) {
                partEnd = crlfNext;
                nextMarker = crlfNext + 2;
            } else if (lfNext >= 0) {
                partEnd = lfNext;
                nextMarker = lfNext + 1;
            }
            if (partEnd < 0) break;
            const part = body.substring(partStart, partEnd);
            if (visit(part) === true) return true;
            markerAt = nextMarker;
            count += 1;
        }
        return false;
    }

    function decodeMimeText(body, encoding, charset) {
        const transfer = encoding.toLowerCase();
        let text = body;
        if (transfer === "quoted-printable") {
            let encoded = "";
            for (let index = 0; index < body.length; index += 1) {
                const code = body.charCodeAt(index);
                if (code === 61) {
                    if (body.charAt(index + 1) === "\r" && body.charAt(index + 2) === "\n") {
                        index += 2;
                        continue;
                    }
                    if (body.charAt(index + 1) === "\n") { index += 1; continue; }
                    const pair = body.substr(index + 1, 2);
                    if (!/^[0-9a-f]{2}$/i.test(pair)) return null;
                    encoded += "%" + pair;
                    index += 2;
                } else {
                    if (code > 127) return null;
                    encoded += "%" + code.toString(16).padStart(2, "0");
                }
            }
            try { text = decodeURIComponent(encoded); } catch (_) { return null; }
        } else if (transfer === "base64") {
            const data = $.NSData.alloc.initWithBase64EncodedStringOptions($(body.replace(/\s/g, "")), 0);
            if (!data) return null;
            const decoded = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
            if (!decoded) return null;
            text = ObjC.unwrap(decoded);
        } else if (transfer !== "7bit" && transfer !== "8bit" && transfer !== "binary" && transfer !== "") {
            return null;
        }

        const encodingValue = charset.toLowerCase();
        if (encodingValue && encodingValue !== "utf-8" && encodingValue !== "utf8"
            && encodingValue !== "us-ascii" && encodingValue !== "ascii") return null;
        return text;
    }

    function findMimeText(raw, depth, budget) {
        if (depth > 5 || budget.parts >= 24 || raw.length > 192 * 1024 * 1024) return null;
        const separator = raw.match(/\r?\n\r?\n/);
        if (!separator || separator.index === undefined) return null;
        const headerText = raw.substring(0, separator.index);
        const body = raw.substring(separator.index + separator[0].length);
        const contentType = mimeHeader(headerText, "Content-Type");
        if (/^multipart\//i.test(contentType)) {
            const boundaryMatch = contentType.match(/boundary\s*=\s*(?:"([^"]+)"|([^;\s]+))/i);
            if (!boundaryMatch) return null;
            let plain = null;
            let html = null;
            mimeEntityParts(body, boundaryMatch[1] || boundaryMatch[2], part => {
                budget.parts += 1;
                const found = findMimeText(part, depth + 1, budget);
                if (!found) return false;
                if (found.type === "text/html" && !html) html = found;
                if (found.type === "text/plain" && !plain) plain = found;
                return !!html;
            });
            return html || plain;
        }

        const mediaType = contentType.split(";")[0].trim().toLowerCase();
        if (mediaType !== "text/html" && mediaType !== "text/plain") return null;
        const charsetMatch = contentType.match(/charset\s*=\s*(?:"([^"]+)"|([^;\s]+))/i);
        const charset = charsetMatch ? (charsetMatch[1] || charsetMatch[2]) : "utf-8";
        if (body.length > 64 * 1024) return null;
        const decoded = decodeMimeText(body, mimeHeader(headerText, "Content-Transfer-Encoding"), charset);
        return decoded === null ? null : {type: mediaType, text: decoded, charset: charset};
    }

    function savedBodyMatches(message, expectedBody) {
        const source = String(message.source());
        if (source.length > 192 * 1024 * 1024) return false;
        const found = findMimeText(source, 0, {parts: 0});
        if (!found) return false;
        let rendered = found.text;
        if (found.type === "text/html") {
            rendered = rendered.replace(/<div class="Apple-Mail-URLShareUserContentTopClass"><br><\/div>/g, "");
            rendered = rendered.replace(
                /<span class="Apple-string-attachment">\s*(?:<object\b[^>]*><\/object>|<img\b[^>]*\/?>)\s*<\/span>/g,
                "");
            // This single terminal NBSP is Mail's cursor/layout marker, not
            // requested text. Earlier converted-space spans remain meaningful.
            rendered = rendered.replace(
                /<span class="Apple-converted-space">&nbsp;<\/span>(?=(?:<\/(?:font|p|blockquote|div|body)>|\s)*<\/body>\s*<\/html>\s*$)/i,
                "");
            const charset = found.charset.toLowerCase();
            const metaCharset = charset === "us-ascii" || charset === "ascii" ? "us-ascii" : "utf-8";
            if (!/<meta\b[^>]*charset\s*=/i.test(rendered)) {
                if (/<head\b[^>]*>/i.test(rendered)) {
                    rendered = rendered.replace(/<head\b[^>]*>/i, match => match + "<meta charset=\"" + metaCharset + "\">");
                } else {
                    rendered = "<meta charset=\"" + metaCharset + "\">" + rendered;
                }
            }
            const htmlData = $(rendered).dataUsingEncoding($.NSUTF8StringEncoding);
            const htmlOptions = $.NSDictionary.dictionaryWithObjectForKey(
                $.NSHTMLTextDocumentType, $.NSDocumentTypeDocumentAttribute);
            const richText = $.NSAttributedString.alloc.initWithDataOptionsDocumentAttributesError(
                htmlData, htmlOptions, null, null);
            if (!richText) return false;
            rendered = ObjC.unwrap(richText.string).replace(/\r\n?/g, "\n").replace(/\u2028/g, "\n");
            // AppKit adds one terminal newline when closing the HTML block.
            if (rendered.endsWith("\n")) rendered = rendered.slice(0, -1);
        } else {
            rendered = rendered.replace(/\r\n?/g, "\n");
        }
        return rendered === String(expectedBody).replace(/\r\n?/g, "\n");
    }

    function verifiedSavedDraftAttachmentNames(mail, request, previousDraftIDs, expectedNames) {
        try {
            const matchingSubjects = mail.draftsMailbox.messages.whose({subject: request.subject})();
            const newDrafts = matchingSubjects.filter(message =>
                previousDraftIDs.indexOf(message.id()) === -1);
            if (newDrafts.length !== 1) return null;

            const draft = newDrafts[0];
            const recipients = draft.toRecipients().map(item => String(item.address()));
            const ccRecipients = draft.ccRecipients().map(item => String(item.address()));
            const bccRecipients = draft.bccRecipients().map(item => String(item.address()));
            const savedNames = draft.mailAttachments().map(item => String(item.name()));
            if (String(draft.subject()) !== request.subject
                || !savedBodyMatches(draft, request.body)
                || JSON.stringify(recipients) !== JSON.stringify(request.to)
                || JSON.stringify(ccRecipients) !== JSON.stringify(request.cc)
                || JSON.stringify(bccRecipients) !== JSON.stringify(request.bcc)
                || JSON.stringify(savedNames) !== JSON.stringify(expectedNames)) return null;
            return savedNames;
        } catch (_) {
            // Mail can briefly reject a getter while its save is settling.
            return null;
        }
    }

    """#

    static let source = #"""
    ObjC.import('Foundation');
    ObjC.import('AppKit');
    \#(savedBodyVerificationSource)

    function readRequest() {
        const data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
        const text = ObjC.unwrap(
            $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding)
        );
        return JSON.parse(text);
    }

    function run() {
        let stage = "read_request";
        const stagedPaths = [];
        let fileManager = null;
        let privateDirectory = null;
        try {
            const request = readRequest();
            const mail = Application('/System/Applications/Mail.app');
            stage = "activate_mail";
            mail.activate();

            // Mail's outgoing and saved message IDs use different identifiers.
            // Snapshot matching drafts before creating this composer instead.
            const previousDraftIDs = mail.draftsMailbox.messages.whose({subject: request.subject})()
                .map(message => message.id());

            stage = "create_message";
            const outgoingMessage = mail.OutgoingMessage({
                subject: request.subject,
                content: request.body,
                visible: true
            });
            mail.outgoingMessages.push(outgoingMessage);

            stage = "set_message_fields";
            // The approved body is exact: never append a configured Mail signature.
            outgoingMessage.messageSignature = null;
            request.to.forEach(address =>
                outgoingMessage.toRecipients.push(mail.ToRecipient({address: address}))
            );
            request.cc.forEach(address =>
                outgoingMessage.ccRecipients.push(mail.CcRecipient({address: address}))
            );
            request.bcc.forEach(address =>
                outgoingMessage.bccRecipients.push(mail.BccRecipient({address: address}))
            );
            outgoingMessage.visible = true;
            // Mail can clear an outgoing body's contents while recipients and
            // signature settings initialize; restore the approved exact body.
            outgoingMessage.content = request.body;

            const expectedNames = (request.attachments || []).map(item => item.file_name);
            const temporaryDirectory = ObjC.unwrap($.NSTemporaryDirectory());
            fileManager = $.NSFileManager.defaultManager;
            privateDirectory = temporaryDirectory + "/RemoteDesktopMail-" + ObjC.unwrap($.NSUUID.UUID.UUIDString);
            const privateAttributes = $.NSDictionary.dictionaryWithObjectForKey($(448), $('NSFilePosixPermissions'));
            stage = "prepare_staging";
            if (!fileManager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(
                $(privateDirectory), false, privateAttributes, null)) {
                throw new Error("staging directory");
            }

            (request.attachments || []).forEach((item, index) => {
                stage = "stage_attachment";
                const itemDirectory = privateDirectory + "/" + index;
                if (!fileManager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(
                    $(itemDirectory), false, privateAttributes, null)) {
                    throw new Error("attachment directory");
                }
                const path = itemDirectory + "/" + item.file_name;
                const bytes = $.NSData.alloc.initWithBase64EncodedStringOptions($(item.base64_data), 0);
                if (!bytes || !bytes.writeToFileAtomically($(path), true)) {
                    throw new Error("attachment bytes");
                }
                const fileAttributes = $.NSDictionary.dictionaryWithObjectForKey($(256), $('NSFilePosixPermissions'));
                if (!fileManager.setAttributesOfItemAtPathError(fileAttributes, $(path), null)) {
                    throw new Error("attachment permissions");
                }
                stagedPaths.push(path);
                stage = "attach_file";
                outgoingMessage.content.attachments.push(mail.Attachment({fileName: Path(path)}));
            });

            let observedNames = [];
            if (request.send_now) {
                stage = "verify_attached_names";
                const deadline = Date.now() + 8_000;
                while (Date.now() < deadline) {
                    observedNames = outgoingMessage.content.attachments().map(item => {
                        // Mail declares attachment.fileName as a file/Path, not a string.
                        const path = String(item.fileName());
                        const url = $.NSURL.fileURLWithPath($(path));
                        return ObjC.unwrap(url.lastPathComponent);
                    });
                    if (observedNames.length === expectedNames.length
                        && observedNames.every((name, index) => name === expectedNames[index])) break;
                    delay(0.05);
                }
                if (observedNames.length !== expectedNames.length
                    || !observedNames.every((name, index) => name === expectedNames[index])) {
                    throw new Error("Mail did not confirm the exact approved attachments");
                }

                // Keep Mail in front while the approved send runs.
                stage = "send_message";
                mail.activate();
                $.NSThread.sleepForTimeInterval(0.2);
                const sentSuccessfully = outgoingMessage.send();
                if (sentSuccessfully !== true) {
                    throw new Error('Mail rejected the send command');
                }
                mail.activate();
            } else {
                stage = "save_draft";
                outgoingMessage.save();
                // Save keeps the same outgoing composer available for review.
                outgoingMessage.visible = true;
                mail.activate();

                stage = "verify_saved_draft";
                const draftDeadline = Date.now() + 10_000;
                let saved = false;
                while (Date.now() < draftDeadline) {
                    const savedNames = verifiedSavedDraftAttachmentNames(
                        mail, request, previousDraftIDs, expectedNames);
                    if (savedNames !== null) {
                        saved = true;
                        observedNames = savedNames;
                        break;
                    }
                    delay(0.1);
                }
                if (!saved) throw new Error("draft readback");
                mail.activate();
            }
            stage = "complete";
            return JSON.stringify({success: true, stage: stage,
                attachment_names: observedNames, draft_saved: !request.send_now});
        } catch (_) {
            // Stable stage codes are diagnostic only; never return exception text or request data.
            return JSON.stringify({success: false, stage: stage,
                attachment_names: [], draft_saved: false});
        } finally {
            if (fileManager) {
                stagedPaths.forEach(path => fileManager.removeItemAtPathError($(path), null));
                if (privateDirectory) fileManager.removeItemAtPathError($(privateDirectory), null);
            }
        }
    }
    """#

    static let processArguments = ["-l", "JavaScript", "-e", source]
}

private struct RemoteDesktopMailAutomationReceiptPayload: Decodable {
    let success: Bool
    let stage: String
    let attachmentNames: [String]
    let draftSaved: Bool
    enum CodingKeys: String, CodingKey {
        case success, stage
        case attachmentNames = "attachment_names"
        case draftSaved = "draft_saved"
    }
}

actor SystemRemoteDesktopMailAutomationRunner: RemoteDesktopMailAutomationRunning {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.threadmark.RemoteDesktopHost",
        category: "MailAutomation")
    private var activeProcess: Process?

    func run(payload: Data) async throws -> RemoteDesktopMailAutomationReceipt {
        guard activeProcess == nil else {
            throw MCPClientError.toolFailed("Another local Mail action is already running.")
        }
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = RemoteDesktopMailJXA.executableURL
        process.arguments = RemoteDesktopMailJXA.processArguments
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
        ]
        let standardInput = Pipe()
        process.standardInput = standardInput
        // The fixed script returns only attachment names for a typed receipt.
        let standardOutput = Pipe()
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        activeProcess = process
        let termination = RemoteDesktopMailProcessTermination()
        let launchState = RemoteDesktopMailProcessLaunchState(process: process)
        process.terminationHandler = { completed in
            termination.finish(completed.terminationStatus)
        }
        defer {
            if activeProcess === process { activeProcess = nil }
            process.terminationHandler = nil
            try? standardInput.fileHandleForWriting.close()
        }

        // The cancellation callback operates on a lock-backed launch state
        // directly, without waiting for another actor hop. Launch and stdin
        // feed are separate linearized phases: cancellation before feed keeps
        // the child blocked without private data and prevents the Mail action.
        let status: Int32
        do {
            status = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try launchState.launch()
                try Task.checkCancellation()
                try launchState.feed(
                    payload,
                    to: standardInput.fileHandleForWriting)
                return await termination.value()
            } onCancel: {
                launchState.cancel()
            }
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
        try Task.checkCancellation()
        guard status == 0 else {
            Self.logFailure(.scriptProcess)
            throw RemoteDesktopMailAutomationFailure(stage: .scriptProcess)
        }
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        guard output.count <= 4_096,
              let receipt = try? JSONDecoder().decode(RemoteDesktopMailAutomationReceiptPayload.self, from: output),
              let stage = RemoteDesktopMailAutomationStage(rawValue: receipt.stage),
              receipt.attachmentNames.count <= RemoteDesktopMailRequest.maximumAttachments else {
            Self.logFailure(.validateReceipt)
            throw RemoteDesktopMailAutomationFailure(stage: .validateReceipt)
        }
        guard receipt.success, stage == .complete else {
            Self.logFailure(stage)
            throw RemoteDesktopMailAutomationFailure(stage: stage)
        }
        return RemoteDesktopMailAutomationReceipt(
            attachmentNames: receipt.attachmentNames,
            draftSaved: receipt.draftSaved)
    }

    private static func logFailure(_ stage: RemoteDesktopMailAutomationStage) {
        logger.error("Mail automation failed at stage \(stage.rawValue, privacy: .public)")
    }

}

/// Synchronizes cancellation with the two consequential process phases.
/// Holding the lock across `Process.run()` prevents the classic check/launch
/// race. Feeding claims its phase under the lock, then writes cancellable
/// chunks without holding it so cancellation can terminate a blocked child.
final class RemoteDesktopMailProcessLaunchState: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var isCancelled = false
    private var didLaunch = false
    private var didFeed = false

    init(process: Process) {
        self.process = process
    }

    func launch() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { throw CancellationError() }
        try process.run()
        didLaunch = true
    }

    func feed(_ payload: Data, to input: FileHandle) throws {
        lock.lock()
        guard !isCancelled, didLaunch, !didFeed else {
            lock.unlock()
            throw CancellationError()
        }
        // A canceled child closes its pipe. Suppress SIGPIPE for this one
        // descriptor so the writer throws instead of crashing the host.
        #if canImport(Darwin)
        guard fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            lock.unlock()
            throw MCPClientError.toolFailed("Mail's input pipe could not be protected.")
        }
        #endif
        didFeed = true
        lock.unlock()
        var offset = 0
        while offset < payload.count {
            lock.lock()
            let cancelled = isCancelled
            lock.unlock()
            guard !cancelled else { throw CancellationError() }
            let end = min(offset + 64 * 1_024, payload.count)
            try input.write(contentsOf: payload.subdata(in: offset..<end))
            offset = end
        }
        // EOF lets the fixed script parse and act. This small final phase is
        // linearized with cancellation; the potentially blocking write is not.
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { throw CancellationError() }
        try input.close()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let shouldTerminate = didLaunch && process.isRunning
        lock.unlock()
        if shouldTerminate { process.terminate() }
    }
}

private final class RemoteDesktopMailProcessTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func finish(_ status: Int32) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: status)
        } else {
            self.status = status
            lock.unlock()
        }
    }

    func value() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

private actor RemoteDesktopMailMCPHandler {
    let runner: any RemoteDesktopMailAutomationRunning
    private var approvedAttachments: [String: [RemoteDesktopMailAttachmentSnapshot]] = [:]

    init(runner: any RemoteDesktopMailAutomationRunning) {
        self.runner = runner
    }

    func registerApprovedAttachments(call: MCPToolCall,
                                    snapshots: [RemoteDesktopMailAttachmentSnapshot]) throws -> String {
        let mail = try RemoteDesktopMailRequest(arguments: call.arguments)
        guard call.toolName == RemoteDesktopMailMCP.toolName,
              call.serverID == RemoteDesktopMailMCP.serverID,
              !snapshots.isEmpty, mail.attachmentPaths == snapshots.map(\.path) else {
            throw MCPClientError.approvalMismatch
        }
        let key = try Self.argumentKey(call.arguments)
        guard approvedAttachments[key] == nil else { throw MCPClientError.approvalMismatch }
        approvedAttachments[key] = snapshots
        return key
    }

    func discardApprovedAttachments(key: String) {
        approvedAttachments.removeValue(forKey: key)
    }

    func call(_ request: CallTool.Parameters) async -> CallTool.Result {
        guard request.name == RemoteDesktopMailMCP.toolName else {
            return Self.failure("The requested local Mail tool is unavailable.")
        }

        do {
            let arguments = try (request.arguments ?? [:]).mapValues {
                try MCPJSONValue(remoteDesktopMailValue: $0)
            }
            let mail = try RemoteDesktopMailRequest(arguments: arguments)
            let snapshots: [RemoteDesktopMailAttachmentSnapshot]
            if mail.attachmentPaths.isEmpty {
                snapshots = []
            } else {
                let key = try Self.argumentKey(arguments)
                guard let approved = approvedAttachments.removeValue(forKey: key),
                      approved.map(\.path) == mail.attachmentPaths else {
                    throw MCPClientError.approvalMismatch
                }
                snapshots = approved
            }
            let receipt = try await runner.run(payload: mail.automationPayload(attachments: snapshots))
            let expectedNames = snapshots.map(\.fileName)
            guard receipt.attachmentNames == expectedNames,
                  receipt.draftSaved == !mail.sendNow else {
                throw MCPClientError.toolFailed("Mail did not confirm the approved action result.")
            }
            let message: String
            if mail.sendNow {
                message = "Mail accepted the approved email for sending."
            } else if expectedNames.isEmpty {
                message = "Email draft opened visibly in Mail for review."
            } else {
                message = "Email draft opened visibly in Mail with \(expectedNames.count) confirmed attachment(s)."
            }
            var structured: [String: MCPJSONValue] = [
                "status": .string(mail.sendNow ? "accepted_for_sending" : "draft_opened"),
            ]
            if !expectedNames.isEmpty {
                structured["attachment_count"] = .integer(expectedNames.count)
                structured["attachment_names"] = .array(expectedNames.map(MCPJSONValue.string))
                structured["attachment_digest"] = .string(
                    try RemoteDesktopMailAttachmentFileReader.approvalDigest(snapshots))
            }
            return try CallTool.Result(
                content: [.text(text: message, annotations: nil, _meta: nil)],
                structuredContent: MCPJSONValue.object(structured).remoteDesktopMailMCPValue,
                isError: false)
        } catch is CancellationError {
            return Self.failure("The local Mail action was canceled.")
        } catch let failure as RemoteDesktopMailAutomationFailure {
            return Self.failure(
                "Mail could not complete the approved local action at stage \(failure.stage.rawValue).")
        } catch {
            // Never return paths, content, or AppleScript diagnostics.
            return Self.failure("Mail could not complete the approved local action.")
        }
    }

    private static func argumentKey(_ arguments: [String: MCPJSONValue]) throws -> String {
        try MCPDigest.sha256(MCPDigest.canonicalData(for: .object(arguments)))
    }

    private static func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true)
    }
}

/// A normal MCP client session backed by a normal MCP server, joined with an
/// `InMemoryTransport` pair. Keeping the full protocol roundtrip makes local
/// tools obey the same discovery/call boundary as the signed sidecar tools.
actor RemoteDesktopMailMCPClientSession: MCPClientSessioning {
    private let processGeneration: UInt64
    private let runner: any RemoteDesktopMailAutomationRunning

    private var server: Server?
    private var client: Client?
    private var handler: RemoteDesktopMailMCPHandler?
    private var clientTransport: InMemoryTransport?
    private var serverTransport: InMemoryTransport?
    private var identity: MCPProcessIdentity?

    init(
        processGeneration: UInt64,
        runner: any RemoteDesktopMailAutomationRunning =
            SystemRemoteDesktopMailAutomationRunner()
    ) {
        self.processGeneration = processGeneration
        self.runner = runner
    }

    func start() async throws -> MCPProcessIdentity {
        if let identity, client != nil, server != nil { return identity }
        guard client == nil, server == nil else {
            throw MCPClientError.transport(
                "The previous embedded Mail MCP session did not stop cleanly.")
        }

        let transports = await InMemoryTransport.createConnectedPair()
        let handler = RemoteDesktopMailMCPHandler(runner: runner)
        self.handler = handler
        let server = Server(
            name: RemoteDesktopMailMCP.serverName,
            version: RemoteDesktopMailMCP.serverVersion,
            capabilities: .init(tools: .init()),
            configuration: .strict)
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [Tool(
                name: RemoteDesktopMailMCP.toolName,
                description: RemoteDesktopMailMCP.reviewedDescription,
                inputSchema: try RemoteDesktopMailMCP.inputSchema.remoteDesktopMailMCPValue,
                annotations: .init(
                    title: "Mail on this Mac",
                    readOnlyHint: false,
                    destructiveHint: true,
                    idempotentHint: false,
                    openWorldHint: true),
            )])
        }
        await server.withMethodHandler(CallTool.self) { request in
            await handler.call(request)
        }
        let client = Client(
            name: "RemoteDesktopHost",
            version: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            capabilities: .init(),
            configuration: .strict)

        self.server = server
        self.client = client
        clientTransport = transports.client
        serverTransport = transports.server

        do {
            try await server.start(transport: transports.server)
            let initialization = try await client.connect(transport: transports.client)
            guard initialization.serverInfo.name == RemoteDesktopMailMCP.serverName,
                  initialization.serverInfo.version == RemoteDesktopMailMCP.serverVersion,
                  initialization.capabilities.tools != nil else {
                throw MCPClientError.serverMismatch(
                    "The embedded Mail MCP server identity did not match the signed host.")
            }
            let identity = MCPProcessIdentity(
                serverID: RemoteDesktopMailMCP.serverID,
                processGeneration: processGeneration,
                processIdentifier: getpid(),
                binaryPath: Bundle.main.executableURL?.path
                    ?? ProcessInfo.processInfo.arguments.first ?? "",
                launchedAt: Date())
            self.identity = identity
            return identity
        } catch let error as MCPClientError {
            await stop()
            throw error
        } catch is CancellationError {
            await stop()
            throw MCPClientError.cancelled
        } catch {
            await stop()
            throw MCPClientError.transport(
                String(String(describing: error).prefix(400)))
        }
    }

    func listAllowedTools() async throws -> [MCPAllowedTool] {
        guard let client, let identity else { throw MCPClientError.notRunning }
        do {
            let response = try await client.listTools()
            guard response.tools.count == 1,
                  response.nextCursor == nil,
                  let tool = response.tools.first,
                  tool.name == RemoteDesktopMailMCP.toolName else {
                throw MCPClientError.serverMismatch(
                    "The embedded Mail MCP server advertised an unexpected tool set.")
            }
            let schema = try MCPJSONValue(remoteDesktopMailValue: tool.inputSchema)
            guard schema == RemoteDesktopMailMCP.inputSchema else {
                throw MCPClientError.serverMismatch(
                    "The embedded Mail MCP schema did not match the signed host contract.")
            }
            let assessment = MCPToolSafetyPolicy.assess(toolName: tool.name)
            guard assessment.risk == .approvalRequired else {
                throw MCPClientError.toolNotAllowed(tool.name)
            }
            return [try MCPAllowedTool(
                serverID: identity.serverID,
                processGeneration: identity.processGeneration,
                toolName: tool.name,
                description: RemoteDesktopMailMCP.reviewedDescription,
                inputSchema: schema,
                risk: assessment.risk,
                approval: assessment.approval)]
        } catch let error as MCPClientError {
            throw error
        } catch {
            throw MCPClientError.transport(
                String(String(describing: error).prefix(400)))
        }
    }

    func execute(_ call: MCPToolCall) async throws -> MCPToolResult {
        guard let client, let identity else { throw MCPClientError.notRunning }
        guard call.serverID == identity.serverID,
              call.processGeneration == identity.processGeneration,
              call.toolName == RemoteDesktopMailMCP.toolName else {
            throw MCPClientError.staleCall
        }
        do {
            let request: RequestContext<CallTool.Result> = try await client.callTool(
                name: call.toolName,
                arguments: try call.arguments.mapValues {
                    try $0.remoteDesktopMailMCPValue
                })
            return try await withTaskCancellationHandler {
                let result = try await request.value
                return try MCPToolOutputSanitizer.sanitize(
                    result: result,
                    call: call)
            } onCancel: { [weak self] in
                Task {
                    try? await client.cancelRequest(
                        request.requestID,
                        reason: "The user canceled the local Mail action.")
                    await self?.stop()
                }
            }
        } catch let error as MCPClientError {
            throw error
        } catch is CancellationError {
            throw MCPClientError.cancelled
        } catch {
            throw MCPClientError.transport(
                String(String(describing: error).prefix(400)))
        }
    }

    /// Binds approved bytes to the exact unchanged MCP call. The wire request
    /// still uses its original fingerprinted arguments and schema; the typed
    /// snapshot is an in-process, one-use host context consumed by the handler.
    func executeApprovedMail(_ call: MCPToolCall,
                             attachments: [RemoteDesktopMailAttachmentSnapshot]) async throws -> MCPToolResult {
        guard let handler, call.toolName == RemoteDesktopMailMCP.toolName,
              call.serverID == RemoteDesktopMailMCP.serverID,
              call.processGeneration == processGeneration else { throw MCPClientError.staleCall }
        let key = try await handler.registerApprovedAttachments(call: call, snapshots: attachments)
        do {
            let result = try await execute(call)
            await handler.discardApprovedAttachments(key: key)
            return result
        } catch {
            await handler.discardApprovedAttachments(key: key)
            throw error
        }
    }

    func stop() async {
        let client = self.client
        let server = self.server
        self.client = nil
        self.server = nil
        handler = nil
        identity = nil
        clientTransport = nil
        serverTransport = nil
        await client?.disconnect()
        await server?.stop()
    }
}

private extension MCPJSONValue {
    init(remoteDesktopMailValue: Value) throws {
        switch remoteDesktopMailValue {
        case .null: self = .null
        case .bool(let value): self = .bool(value)
        case .int(let value): self = .integer(value)
        case .double(let value):
            guard value.isFinite else {
                throw MCPClientError.serverMismatch(
                    "The embedded Mail MCP server returned a non-finite number.")
            }
            self = .double(value)
        case .string(let value): self = .string(value)
        case .data(let mimeType, let data):
            self = .string("[Binary data omitted: \(mimeType ?? "unknown type"), \(data.count) bytes]")
        case .array(let values):
            self = .array(try values.map(Self.init(remoteDesktopMailValue:)))
        case .object(let values):
            self = .object(try values.mapValues(Self.init(remoteDesktopMailValue:)))
        }
    }

    var remoteDesktopMailMCPValue: Value {
        get throws {
            switch self {
            case .null: return .null
            case .bool(let value): return .bool(value)
            case .integer(let value): return .int(value)
            case .double(let value):
                guard value.isFinite else {
                    throw MCPClientError.invalidArguments("Numbers must be finite.")
                }
                return .double(value)
            case .string(let value): return .string(value)
            case .array(let values):
                return .array(try values.map { try $0.remoteDesktopMailMCPValue })
            case .object(let values):
                return .object(try values.mapValues { try $0.remoteDesktopMailMCPValue })
            }
        }
    }
}

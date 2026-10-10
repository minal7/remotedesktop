import Foundation
import XCTest
@testable import RemoteDesktopHost

final class ComputerUseWebJobRequestTests: XCTestCase {
    func testEmailRoutesToGmailByDefaultAndAppleMailStaysExcluded() throws {
        guard case .gmail(let draft) = ComputerUseWebJobRequest.route(
            "Email Jordan a draft about the quarterly review; do not send it.") else {
            return XCTFail("Unqualified email work routes to Gmail on the web")
        }
        XCTAssertEqual(draft.originalRequest, "Email Jordan a draft about the quarterly review; do not send it.")
        XCTAssertFalse(draft.sendRequested)

        guard case .gmail(let send) = ComputerUseWebJobRequest.route(
            "Please send an email to jordan@example.com with the attached agenda.") else {
            return XCTFail("A literal send request routes to Gmail")
        }
        XCTAssertTrue(send.sendRequested)

        guard case .gmail(let negatedSend) = ComputerUseWebJobRequest.route(
            "Draft an email to Jordan; don't send it.") else {
            return XCTFail("An explicitly unsent email still routes to Gmail")
        }
        XCTAssertFalse(negatedSend.sendRequested)

        XCTAssertEqual(ComputerUseWebJobRequest.route("Email Jordan using Apple Mail."), .explicitAppleMail)
        XCTAssertEqual(ComputerUseWebJobRequest.route("Open Gmail."), .gmail(.init(originalRequest: "Open Gmail.", sendRequested: false)))
        XCTAssertEqual(ComputerUseWebJobRequest.route("Email alex@example.com with subject \"Apple Mail\"."),
            .gmail(.init(originalRequest: "Email alex@example.com with subject \"Apple Mail\".", sendRequested: false)))
        XCTAssertEqual(ComputerUseWebJobRequest.route("Draft an email in Gmail, not Apple Mail."),
            .gmail(.init(originalRequest: "Draft an email in Gmail, not Apple Mail.", sendRequested: false)))
    }

    func testNamedDriveAndDropboxFileOperationsRouteToTheirWebsites() throws {
        guard case .googleDriveUpload(let drive) = ComputerUseWebJobRequest.route(
            "Add the newest Board Review deck to Google Drive.") else {
            return XCTFail("Google Drive upload tasks route to the website")
        }
        XCTAssertEqual(drive.destination, .googleDrive)
        XCTAssertEqual(drive.originalRequest, "Add the newest Board Review deck to Google Drive.")

        guard case .dropboxUpload(let dropbox) = ComputerUseWebJobRequest.route(
            "Upload the selected spreadsheet to Dropbox.") else {
            return XCTFail("Dropbox upload tasks route to the website")
        }
        XCTAssertEqual(dropbox.destination, .dropbox)

        XCTAssertEqual(ComputerUseWebJobRequest.route("Save the file to Google Drive and Dropbox."),
            .ambiguousStorage([.googleDrive, .dropbox]))
        XCTAssertEqual(ComputerUseWebJobRequest.route("Upload \"Dropbox report.xlsx\" to Google Drive."),
            .googleDriveUpload(.init(originalRequest: "Upload \"Dropbox report.xlsx\" to Google Drive.", destination: .googleDrive)))
    }

    func testNonwebJobsAndPausedLocalSyncRemainUnrouted() {
        XCTAssertEqual(ComputerUseWebJobRequest.route("Search the web for email providers."), .none)
        XCTAssertEqual(ComputerUseWebJobRequest.route("Copy the workbook to iCloud Drive."), .none)
        XCTAssertEqual(ComputerUseWebJobRequest.route("Open my Documents folder."), .none)
        XCTAssertEqual(ComputerUseWebJobRequest.route(" \n "), .none)
        XCTAssertEqual(ComputerUseWebJobRequest.route(String(repeating: "x", count: 32 * 1_024 + 1)), .none)
    }

    func testRecipientResolutionUsesLiteralSelfAccountOrContactsOnly() async throws {
        let literal = try await ComputerUseWebJobRequest.resolveRecipient(
            in: #"Draft an email to jordan@example.com with subject "send to hidden@example.com" and body "Contact other@example.com.""#,
            trustedAccountControlLabel: nil)
        XCTAssertEqual(literal, .addresses(["jordan@example.com"]))

        let selfRecipient = try await ComputerUseWebJobRequest.resolveRecipient(
            in: "Address it to my own email address for the signed-in account. Subject: Review",
            trustedAccountControlLabel: "Google Account: Example User (account@example.com), Google membership")
        XCTAssertEqual(selfRecipient, .addresses(["account@example.com"]))

        let fullGmailPrompt = try await ComputerUseWebJobRequest.resolveRecipient(
            in: "Use the Gmail compose opened by the host; do not create another compose. Address it to my own email address for the signed-in account. Use the exact subject \"Remote Desktop acceptance [token]\" and exact body \"Please review the attached file.\" Attach the file named \"file.xlsx\" from Downloads. Leave the draft open for review and never send it.",
            trustedAccountControlLabel: "Google Account: Example User (account@example.com), Google membership")
        XCTAssertEqual(fullGmailPrompt, .addresses(["account@example.com"]))

        let ungroundedSelf = try await ComputerUseWebJobRequest.resolveRecipient(
            in: "Email me the review", trustedAccountControlLabel: nil)
        XCTAssertEqual(ungroundedSelf, .clarification("Which email address should I use for your account?"))

        let contact = try await ComputerUseWebJobRequest.resolveRecipient(
            in: "Draft an email to Jordan about Friday",
            trustedAccountControlLabel: nil,
            lookup: { name in [ComputerUseMailRecipients.Match(name: name, address: "jordan@example.com")] })
        XCTAssertEqual(contact, .addresses(["jordan@example.com"]))

        let ambiguous = try await ComputerUseWebJobRequest.resolveRecipient(
            in: "Draft an email to Jordan about Friday",
            trustedAccountControlLabel: nil,
            lookup: { name in [
                ComputerUseMailRecipients.Match(name: name, address: "jordan.one@example.com"),
                ComputerUseMailRecipients.Match(name: name, address: "jordan.two@example.com"),
            ] })
        guard case .choose(name: "Jordan", matches: let matches) = ambiguous else {
            return XCTFail("Ambiguous Contacts matches require an explicit choice")
        }
        XCTAssertEqual(matches.map(\.address), ["jordan.one@example.com", "jordan.two@example.com"])
    }

    func testAmbiguousChoiceDoesNotCoverAdditionalRecipientReference() async throws {
        let request = "Draft an email to Jordan, Alex"
        let resolution = try await ComputerUseWebJobRequest.resolveRecipient(
            in: request, trustedAccountControlLabel: nil,
            lookup: { _ in [
                ComputerUseMailRecipients.Match(name: "Jordan Lee", address: "jordan.one@example.com"),
                ComputerUseMailRecipients.Match(name: "Jordan Lee", address: "jordan.two@example.com"),
            ] })
        XCTAssertEqual(resolution, .clarification(
            "Please provide the exact email addresses for all recipients so I can avoid choosing the wrong person."),
            "A choice for one entry cannot silently replace a mixed-recipient request")
    }

    func testExtractionRequestExposesOnlyThreeContentFieldsAndPreservesPrompt() throws {
        let prompt = "Draft to Jordan at jordan@example.com. Subject: Board Review. Body: The meeting is Friday. Attach the latest deck."
        let clarifications = [["question": "Which deck?", "answer": "The Board Review deck."]]
        let extractor = try makeExtractor(transport: WebJobTransport(reply: Data()))
        let request = try extractor.makeRequest(originalRequest: prompt, clarifications: clarifications)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "fixture-local-model")
        XCTAssertEqual(body["temperature"] as? Double, 0)

        let responseFormat = try XCTUnwrap(body["response_format"] as? [String: Any])
        let jsonSchema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        let schema = try XCTUnwrap(jsonSchema["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["subject", "body", "file_description"])
        XCTAssertEqual(Set(schema["required"] as? [String] ?? []), ["subject", "body", "file_description"])
        let fileDescriptionSchema = try XCTUnwrap(properties["file_description"] as? [String: Any])
        let fileDescriptionBranches = try XCTUnwrap(fileDescriptionSchema["anyOf"] as? [[String: Any]])
        XCTAssertTrue(fileDescriptionBranches.contains { $0["type"] as? String == "null" })
        let fileObject = try XCTUnwrap(fileDescriptionBranches.first { $0["type"] as? String == "object" })
        XCTAssertEqual(fileObject["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set((fileObject["properties"] as? [String: Any] ?? [:]).keys),
            ["description", "file_kind", "name_contains", "folder_scope", "date_field", "direction"])

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let system = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(system.contains("Extract only the email subject, email body and source-file description/query"))
        let requestContext = try XCTUnwrap(messages.last?["content"] as? String)
        let context = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(requestContext.utf8)) as? [String: Any])
        XCTAssertEqual(context["original_request"] as? String, prompt)
        XCTAssertEqual(context["clarifications"] as? [[String: String]], clarifications)
        XCTAssertFalse(properties.keys.contains("to"))
        XCTAssertFalse(properties.keys.contains("path"))
        XCTAssertFalse(properties.keys.contains("sha256"))
    }

    func testExtractionDecoderPreservesValuesAndRejectsMalformedOrHostFields() throws {
        let valid = #"{"subject":"Board Review","body":"The meeting is Friday.\nThanks, Jordan","file_description":{"description":"the latest Board Review deck","file_kind":"presentation","name_contains":"Board Review","folder_scope":"downloads","date_field":"modifiedAt","direction":"descending"}}"#
        XCTAssertEqual(try ComputerUseWebJobContentExtractor.decode(valid), .init(
            subject: "Board Review", body: "The meeting is Friday.\nThanks, Jordan",
            fileDescription: "the latest Board Review deck",
            fileQuery: .init(fileKind: .presentation,
                sort: .init(field: .modifiedAt, direction: .descending),
                nameContains: "Board Review", folderScope: .downloads)))
        let exactFilename = #"{"subject":"","body":"","file_description":{"description":"the file named BoardReview Final.pptx","file_kind":"presentation","name_contains":"BoardReview Final.pptx","folder_scope":"documents","date_field":"none","direction":"none"}}"#
        XCTAssertEqual(try ComputerUseWebJobContentExtractor.decode(exactFilename), .init(
            subject: "", body: "", fileDescription: "the file named BoardReview Final.pptx",
            fileQuery: .init(fileKind: .presentation, nameContains: "BoardReview Final.pptx", folderScope: .documents)))
        XCTAssertEqual(try ComputerUseWebJobContentExtractor.decode(
            #"{"subject":"","body":"","file_description":null}"#),
            .init(subject: "", body: "", fileDescription: ""))

        let invalid = [
            #"{"subject":"x","body":"y","file_description":null,"recipient":"jordan@example.com"}"#,
            #"{"subject":"x","subject":"y","body":"z","file_description":""}"#,
            #"{"subject":"x","body":"y","file_description":{"description":"latest deck","file_kind":"presentation","name_contains":"x","folder_scope":"downloads","date_field":"modifiedAt","direction":"descending","source_path":"/Users/me/secret.pptx"}}"#,
            #"{"subject":"x","body":"y","file_description":{"description":"/Users/me/secret.pptx","file_kind":"presentation","name_contains":"x","folder_scope":"downloads","date_field":"none","direction":"none"}}"#,
            #"{"subject":"x","body":"y","file_description":{"description":"latest deck","file_kind":"presentation","name_contains":"https://example.com/file","folder_scope":"downloads","date_field":"none","direction":"none"}}"#,
            #"{"subject":"x","body":"y","file_description":{"description":"latest deck","file_kind":"presentation","name_contains":"aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899","folder_scope":"downloads","date_field":"none","direction":"none"}}"#,
            #"{"subject":"x","body":"y","file_description":{"description":"latest deck","file_kind":"unknown","name_contains":"x","folder_scope":"downloads","date_field":"none","direction":"none"}}"#,
            #"{"subject":"x","body":"y","file_description":{"description":"latest deck","file_kind":"presentation","name_contains":"x","folder_scope":"downloads","date_field":"none","direction":"descending"}}"#,
            #"{"subject":"x","body":"y","file_description":{"description":"latest deck","description":"other","file_kind":"presentation","name_contains":"x","folder_scope":"downloads","date_field":"none","direction":"none"}}"#,
            #"{"subject":"x\ny","body":"y","file_description":"z"}"#,
            #"{"subject":"x","body":"\#(String(repeating: "é", count: 4_001))","file_description":null}"#,
            "not JSON",
        ]
        for content in invalid {
            XCTAssertThrowsError(try ComputerUseWebJobContentExtractor.decode(content))
        }
    }

    func testLiteralFilenameExtensionOverridesCoarseFileKindWithoutChangingQueryAuthority() throws {
        func decode(_ fileName: String, kind: String) throws -> ComputerUseLocalFileCatalog.Query? {
            let object: [String: Any] = [
                "subject": "", "body": "",
                "file_description": [
                    "description": "the file named \(fileName)",
                    "file_kind": kind,
                    "name_contains": fileName,
                    "folder_scope": "downloads",
                    "date_field": "modifiedAt",
                    "direction": "descending",
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return try ComputerUseWebJobContentExtractor.decode(String(decoding: data, as: UTF8.self)).fileQuery
        }

        let spreadsheet = try XCTUnwrap(decode("Gmail Acceptance - Quarterly Metrics.XLSX", kind: "document"))
        XCTAssertEqual(spreadsheet.fileKind, .spreadsheet)
        XCTAssertEqual(spreadsheet.nameContains, "Gmail Acceptance - Quarterly Metrics.XLSX")
        XCTAssertEqual(spreadsheet.folderScope, .downloads)
        XCTAssertEqual(spreadsheet.sort, .init(field: .modifiedAt, direction: .descending))

        XCTAssertEqual(try decode("Quarterly Metrics.pptx", kind: "document")?.fileKind, .presentation)
        XCTAssertEqual(try decode("Quarterly Metrics.pdf", kind: "spreadsheet")?.fileKind, .document)
        XCTAssertEqual(try decode("Quarterly Metrics.unknown", kind: "presentation")?.fileKind, .presentation)
        XCTAssertEqual(try decode("Quarterly Metrics", kind: "spreadsheet")?.fileKind, .spreadsheet)

        XCTAssertThrowsError(try decode("/Users/example/Downloads/Quarterly Metrics.xlsx", kind: "document"),
            "A recognized suffix must not make a path-like value acceptable")
    }

    func testExtractorUsesOnlyLocalStrictTextProposal() async throws {
        let responseContent = #"{"subject":"Board Review","body":"The meeting is Friday.","file_description":{"description":"the latest Board Review deck","file_kind":"presentation","name_contains":"Board Review","folder_scope":"downloads","date_field":"modifiedAt","direction":"descending"}}"#
        let transport = WebJobTransport(reply: try envelope(responseContent))
        let extractor = try makeExtractor(transport: transport)
        let result = try await extractor.propose(originalRequest: "Email Jordan about Friday and attach the latest Board Review deck.")
        XCTAssertEqual(result, .init(subject: "Board Review", body: "The meeting is Friday.",
            fileDescription: "the latest Board Review deck", fileQuery: .init(fileKind: .presentation,
                sort: .init(field: .modifiedAt, direction: .descending), nameContains: "Board Review",
                folderScope: .downloads)))
        let lastRequest = await transport.lastRequest()
        let request = try XCTUnwrap(lastRequest)
        XCTAssertEqual(request.url?.host, "127.0.0.1")
    }

    func testExtractorResolvesModelSelectedQuotedLiteralReferencesExactly() async throws {
        let subject = "Rëveiw [typo-λ]"
        let body = "Line one  with exact spacing; café."
        let filename = "Δonnées Qtr typo.xlsx"
        let prompt = "Draft an email to Jordan with subject \"\(subject)\" and body “\(body)”. Attach the file named \"\(filename)\" from Downloads."
        let response: [String: Any] = [
            "subject": ["literal_id": "q0"],
            "body": ["literal_id": "q1"],
            "file_description": [
                "description": "the file named", "file_kind": "spreadsheet",
                "name_contains": ["literal_id": "q2"], "folder_scope": "downloads",
                "date_field": "none", "direction": "none",
            ],
        ]
        let responseData = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        let transport = WebJobTransport(reply: try envelope(String(decoding: responseData, as: UTF8.self)))
        let extractor = try makeExtractor(transport: transport)

        let result = try await extractor.propose(originalRequest: prompt)
        XCTAssertEqual(result.subject, subject)
        XCTAssertEqual(result.body, body)
        XCTAssertEqual(result.fileQuery?.nameContains, filename)
        XCTAssertEqual(result.fileQuery?.fileKind, .spreadsheet)

        let recordedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        let bodyObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(bodyObject["messages"] as? [[String: Any]])
        let contextString = try XCTUnwrap(messages.last?["content"] as? String)
        let context = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contextString.utf8)) as? [String: Any])
        XCTAssertEqual(context["literal_payloads"] as? [String: String],
            ["q0": subject, "q1": body, "q2": filename])
    }

    func testExtractorRejectsMutatedQuotedTextAndUnknownLiteralReference() async throws {
        let exactSubject = "Quarterly Review [147b3ba460c143a6aedde7ba27f52f57]"
        let prompt = "Draft an email with the exact subject \"\(exactSubject)\" and body “Review the figures.”"
        for proposal in [
            #"{"subject":"Quarterly Review [147b3ba460c143a6aedde7ba27f52f]","body":{"literal_id":"q1"},"file_description":null}"#,
            #"{"subject":{"literal_id":"q9"},"body":{"literal_id":"q1"},"file_description":null}"#,
        ] {
            let extractor = try makeExtractor(transport: WebJobTransport(reply: try envelope(proposal)))
            do {
                _ = try await extractor.propose(originalRequest: prompt)
                XCTFail("Only an exact source-backed literal reference may supply quoted field text")
            } catch let error as ComputerUseWebJobContentExtractor.Error {
                XCTAssertEqual(error, .invalidResponse)
            }
        }
    }

    func testExtractorLiteralInventoryIncludesAcceptedClarificationsAndRejectsAmbiguousQuotes() async throws {
        let extractor = try makeExtractor(transport: WebJobTransport(reply: try envelope(
            #"{"subject":{"literal_id":"q1"},"body":{"literal_id":"q0"},"file_description":null}"#)))
        let result = try await extractor.propose(originalRequest: "Draft about \"Quarterly\".",
            clarifications: [["question": "What subject?", "answer": "Use “Rëview” exactly."]])
        XCTAssertEqual(result.subject, "Rëview")
        XCTAssertEqual(result.body, "Quarterly")

        XCTAssertThrowsError(try extractor.makeRequest(originalRequest: "Draft with an unmatched \"literal.")) { error in
            XCTAssertEqual(error as? ComputerUseWebJobContentExtractor.Error, .invalidInput)
        }
        let tooManyQuotedSpans = String(repeating: "\"x\" ", count: 33)
        XCTAssertThrowsError(try extractor.makeRequest(originalRequest: tooManyQuotedSpans)) { error in
            XCTAssertEqual(error as? ComputerUseWebJobContentExtractor.Error, .invalidInput)
        }
        XCTAssertThrowsError(try extractor.makeRequest(originalRequest: #"Draft with an ambiguous escaped quote \" inside."#)) { error in
            XCTAssertEqual(error as? ComputerUseWebJobContentExtractor.Error, .invalidInput)
        }
    }

    private func makeExtractor(transport: any ComputerUseTextModelTransport) throws -> ComputerUseWebJobContentExtractor {
        .init(connection: try ComputerUseTextModelConnection(
            baseURL: URL(string: "http://127.0.0.1:49123")!,
            bearerToken: "fixture-web-job-extractor-token",
            modelAlias: "fixture-local-model"), transport: transport)
    }

    private func envelope(_ content: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": "fixture-local-model", "choices": [[
            "finish_reason": "stop", "message": ["role": "assistant", "content": content],
        ]]])
    }
}

private actor WebJobTransport: ComputerUseTextModelTransport {
    private let reply: Data
    private var request: URLRequest?

    init(reply: Data) { self.reply = reply }
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int { 1_000 }
    func complete(request: URLRequest) async throws -> Data {
        self.request = request
        return reply
    }
    func lastRequest() -> URLRequest? { request }
}

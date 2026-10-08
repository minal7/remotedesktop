import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import RemoteDesktopHost

final class RemoteDesktopMailMCPTests: XCTestCase {
    func testFixedJXAReceivesExactValuesOnlyThroughStandardInput() throws {
        let subject = "Quarterly update \" & quit & \""
        let body = "First line\nend tell\ndo shell script \"unsafe\""
        let request = try RemoteDesktopMailRequest(arguments: [
            "to": .string("first@example.com; second@example.com"),
            "cc": .string("copy@example.com"),
            "bcc": .string("audit@example.com"),
            "subject": .string(subject),
            "body": .string(body),
            "send_now": .bool(false),
        ])

        let payload = try JSONDecoder().decode(
            RecordedMailAutomationPayload.self,
            from: request.automationPayload())
        XCTAssertEqual(payload, RecordedMailAutomationPayload(
            to: ["first@example.com", "second@example.com"],
            cc: ["copy@example.com"],
            bcc: ["audit@example.com"],
            subject: subject,
            body: body,
            sendNow: false))

        XCTAssertFalse(RemoteDesktopMailJXA.source.contains(subject))
        XCTAssertFalse(RemoteDesktopMailJXA.source.contains(body))
        XCTAssertTrue(RemoteDesktopMailJXA.source.contains("visible: true"))
        XCTAssertTrue(RemoteDesktopMailJXA.source.contains(
            "outgoingMessage.messageSignature = null"))
        XCTAssertTrue(RemoteDesktopMailJXA.source.contains(
            "const sentSuccessfully = outgoingMessage.send()"))
        XCTAssertTrue(RemoteDesktopMailJXA.source.contains(
            "sentSuccessfully !== true"))
        let normalizedSource = RemoteDesktopMailJXA.source.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        XCTAssertTrue(normalizedSource.contains(
            "mail.activate();\n$.NSThread.sleepForTimeInterval(0.2);\nconst sentSuccessfully"))
        XCTAssertTrue(normalizedSource.contains(
            "throw new Error('Mail rejected the send command');\n}\nmail.activate();"))

        let processArguments = RemoteDesktopMailJXA.processArguments
        XCTAssertEqual(processArguments, [
            "-l", "JavaScript", "-e", RemoteDesktopMailJXA.source,
        ])
        XCTAssertFalse(processArguments.contains(subject))
        XCTAssertFalse(processArguments.contains(body))
        XCTAssertFalse(processArguments.contains("first@example.com"))
        XCTAssertEqual(
            RemoteDesktopMailJXA.executableURL.path,
            "/usr/bin/osascript")
    }

    func testMailRecipientFieldsRequireExplicitMailboxAddresses() throws {
        let invalidRecipients = [
            "me", "myself", "Jordan", "Jordan Example",
            "Jordan <jordan@example.com>",
            "\"Jordan Example\" <jordan@example.com>",
            "no-at-sign.example", "@example.com", "person@", "person@@example.com",
            "person@example..com",
        ]
        for recipient in invalidRecipients {
            var arguments = mailArguments(sendNow: false)
            arguments["to"] = .string(recipient)
            XCTAssertThrowsError(try RemoteDesktopMailRequest(arguments: arguments),
                "To must reject non-mailboxes and unresolved labels without inventing an address: \(recipient.debugDescription)") { error in
                    XCTAssertEqual((error as? RemoteDesktopMailRecipientFailure)?.field, .to)
                }
        }

        for recipient in ["person@example.com\tother", "person\u{0000}@example.com"] {
            var arguments = mailArguments(sendNow: false)
            arguments["to"] = .string(recipient)
            XCTAssertThrowsError(try RemoteDesktopMailRequest(arguments: arguments)) { error in
                XCTAssertTrue(error is MCPClientError,
                    "Control characters continue to use the existing invalid-arguments failure")
            }
        }

        for field in ["cc", "bcc"] {
            var arguments = mailArguments(sendNow: false)
            arguments[field] = .string("Jordan")
            XCTAssertThrowsError(try RemoteDesktopMailRequest(arguments: arguments),
                "Nonblank \(field) values must follow the same explicit mailbox contract") { error in
                    XCTAssertEqual((error as? RemoteDesktopMailRecipientFailure)?.field,
                                   field == "cc" ? .cc : .bcc)
                }
        }

        var emptyTo = mailArguments(sendNow: false)
        emptyTo["to"] = .string("  , ; \n")
        XCTAssertThrowsError(try RemoteDesktopMailRequest(arguments: emptyTo),
            "To still requires at least one explicit mailbox address") { error in
                XCTAssertEqual((error as? RemoteDesktopMailRecipientFailure)?.field, .to)
            }

        var blankCopies = mailArguments(sendNow: false)
        blankCopies["cc"] = .string("  , ; \n")
        blankCopies["bcc"] = .string("\t")
        XCTAssertNoThrow(try RemoteDesktopMailRequest(arguments: blankCopies),
            "Blank optional CC and BCC fields remain allowed")
    }

    func testMailboxAddressVariantsArePreservedExactlyWithoutOnlineChecks() throws {
        let addresses = [
            "jordan@example.com",
            "first+tag@sub.example.invalid",
            "máil@bücher.example",
            "\"first last\"@example.invalid",
        ]
        let input = addresses.joined(separator: ", ;\n")
        var arguments = mailArguments(sendNow: false)
        arguments["to"] = .string(input)
        let request = try RemoteDesktopMailRequest(arguments: arguments)
        XCTAssertEqual(request.to, input,
            "The parsed request must preserve the exact entered mailbox list")

        let payload = try JSONDecoder().decode(
            RecordedMailAutomationPayload.self,
            from: request.automationPayload())
        XCTAssertEqual(payload.to, addresses,
            "Plus-tags, subdomains, synthetic domains, international addresses, and quoted local parts stay intact")
    }

    func testMailRecipientListLimitAppliesAfterMixedSeparators() throws {
        let accepted = (0 ..< RemoteDesktopMailRequest.maximumRecipientsPerField)
            .map { "person\($0)@example.invalid" }
        var atLimit = mailArguments(sendNow: false)
        atLimit["to"] = .string(accepted.joined(separator: ", ;\n"))
        XCTAssertNoThrow(try RemoteDesktopMailRequest(arguments: atLimit))

        var overLimit = mailArguments(sendNow: false)
        overLimit["to"] = .string((accepted + ["extra@example.invalid"]).joined(separator: ";,"))
        XCTAssertThrowsError(try RemoteDesktopMailRequest(arguments: overLimit),
            "Mixed separators must not bypass the existing recipient-count bound")
    }

    func testMailAttachmentPathsAreOptionalAndAppearInTheAdvertisedSchema() throws {
        guard case .object(let schema) = RemoteDesktopMailMCP.inputSchema,
              case .object(let properties)? = schema["properties"],
              case .object(let attachmentSchema)? = properties["attachment_paths"],
              attachmentSchema["type"] == .string("array"),
              case .array(let required)? = schema["required"] else {
            return XCTFail("Mail must advertise an optional attachment_paths array")
        }
        XCTAssertFalse(required.contains(.string("attachment_paths")))
        XCTAssertNoThrow(try MCPToolSafetyPolicy.validateArguments(
            toolName: RemoteDesktopMailMCP.toolName,
            arguments: mailArguments(sendNow: false)))

        var withAttachments = mailArguments(sendNow: false)
        withAttachments["attachment_paths"] = .array([
            .string("/tmp/Remote Desktop attachment.txt"),
        ])
        XCTAssertNoThrow(try MCPToolSafetyPolicy.validateArguments(
            toolName: RemoteDesktopMailMCP.toolName,
            arguments: withAttachments))

        var relativePath = mailArguments(sendNow: false)
        relativePath["attachment_paths"] = .array([.string("Downloads/attachment.txt")])
        XCTAssertThrowsError(try MCPToolSafetyPolicy.validateArguments(
            toolName: RemoteDesktopMailMCP.toolName,
            arguments: relativePath))

        var duplicatePath = mailArguments(sendNow: false)
        duplicatePath["attachment_paths"] = .array([
            .string("/tmp/attachment.txt"), .string("/tmp/attachment.txt"),
        ])
        XCTAssertThrowsError(try MCPToolSafetyPolicy.validateArguments(
            toolName: RemoteDesktopMailMCP.toolName,
            arguments: duplicatePath))
    }

    func testChangedMailAttachmentStopsBeforePreflightLedgerAndRunner() async throws {
        let runner = RecordingMailAutomationRunner()
        let preflight = RecordingMailAutomationPreflight(isAllowed: true)
        let root = canonicalTemporaryDirectory
            .appendingPathComponent("MailAttachmentChanged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("approval-bound.txt")
        try Data("approved bytes".utf8).write(to: file)
        let pool = MCPClientPool(
            binaryValidator: MailTestBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(fileURL: root.appendingPathComponent("ledger.json")),
            sessionFactory: { binary, generation in
                MailTestSidecarSession(binary: binary, generation: generation, tools: [])
            },
            embeddedSessionFactory: { generation in
                RemoteDesktopMailMCPClientSession(processGeneration: generation, runner: runner)
            },
            mailAutomationPreflight: preflight)
        var phase = "SDK startup"
        do {
            _ = try await pool.start(binaryURL: fakeBinaryURL)
            phase = "tool discovery"
            let availableTools = try await pool.allowedTools()
            let tool = try XCTUnwrap(availableTools.first(where: {
                $0.toolName == RemoteDesktopMailMCP.toolName
            }))
            var arguments = mailArguments(sendNow: false)
            arguments["attachment_paths"] = .array([.string(file.path)])
            let call = try tool.makeCall(taskID: "attachment-content-change", arguments: arguments)
            phase = "approval preparation"
            let prepared = try await pool.prepareApproval(call)
            try Data("changed bytes".utf8).write(to: file, options: .atomic)

            do {
                _ = try await pool.performApproved(call, fingerprint: prepared.fingerprint)
                XCTFail("Changed attachment content must invalidate the approved action")
            } catch let error as MCPClientError {
                XCTAssertEqual(error, .approvalMismatch)
            }
            let invocationCount = await runner.invocationCount()
            let preflightCallCount = await preflight.callCount()
            XCTAssertEqual(invocationCount, 0)
            XCTAssertEqual(preflightCallCount, 0)
        } catch {
            await pool.cancelAll()
            XCTFail("Failure during \(phase): \(error)")
            return
        }
        await pool.cancelAll()
    }

    func testRepreparingSameMailCallBindsNewBytesAndRejectsStaleFingerprint() async throws {
        let root = canonicalTemporaryDirectory
            .appendingPathComponent("MailAttachmentFingerprint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("same-call.txt")
        try Data("bytes A".utf8).write(to: file)
        let runner = RecordingMailAutomationRunner()
        let preflight = RecordingMailAutomationPreflight(isAllowed: true)
        let pool = MCPClientPool(
            binaryValidator: MailTestBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(fileURL: root.appendingPathComponent("ledger.json")),
            sessionFactory: { binary, generation in
                MailTestSidecarSession(binary: binary, generation: generation, tools: [])
            },
            embeddedSessionFactory: { generation in
                RemoteDesktopMailMCPClientSession(processGeneration: generation, runner: runner)
            },
            mailAutomationPreflight: preflight)
        var phase = "SDK startup"
        do {
            _ = try await pool.start(binaryURL: fakeBinaryURL)
            phase = "tool discovery"
            let availableTools = try await pool.allowedTools()
            let tool = try XCTUnwrap(availableTools.first(where: {
                $0.toolName == RemoteDesktopMailMCP.toolName
            }))
            var arguments = mailArguments(sendNow: false)
            arguments["attachment_paths"] = .array([.string(file.path)])
            let call = try tool.makeCall(taskID: "attachment-fingerprint-replacement", arguments: arguments)
            phase = "approval preparation"
            let oldApproval = try await pool.prepareApproval(call)
            try Data("bytes B".utf8).write(to: file, options: .atomic)
            let newApproval = try await pool.prepareApproval(call)
            XCTAssertNotEqual(oldApproval.fingerprint.mailAttachmentDigest,
                              newApproval.fingerprint.mailAttachmentDigest)

            do {
                _ = try await pool.performApproved(call, fingerprint: oldApproval.fingerprint)
                XCTFail("A stale fingerprint must not consume a newer approval snapshot")
            } catch let error as MCPClientError {
                XCTAssertEqual(error, .approvalMismatch)
            }
            let staleRunnerCount = await runner.invocationCount()
            let stalePreflightCount = await preflight.callCount()
            XCTAssertEqual(staleRunnerCount, 0)
            XCTAssertEqual(stalePreflightCount, 0)

            let result = try await pool.performApproved(call, fingerprint: newApproval.fingerprint)
            XCTAssertFalse(result.isError)
            let finalRunnerCount = await runner.invocationCount()
            XCTAssertEqual(finalRunnerCount, 1)
        } catch {
            await pool.cancelAll()
            XCTFail("Failure during \(phase): \(error)")
            return
        }
        await pool.cancelAll()
    }

    func testCachedMailReceiptCannotConfirmDifferentApprovedAttachmentBytes() async throws {
        let root = canonicalTemporaryDirectory
            .appendingPathComponent("MailAttachmentLedgerDigest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("same-path.txt")
        let ledgerURL = root.appendingPathComponent("ledger.json")
        try Data("content A".utf8).write(to: file)
        let runner = RecordingMailAutomationRunner()
        let preflight = RecordingMailAutomationPreflight(isAllowed: true)
        var firstCallDigest: String?
        let firstPool = MCPClientPool(
            binaryValidator: MailTestBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(fileURL: ledgerURL),
            sessionFactory: { binary, generation in
                MailTestSidecarSession(binary: binary, generation: generation, tools: [])
            },
            embeddedSessionFactory: { generation in
                RemoteDesktopMailMCPClientSession(processGeneration: generation, runner: runner)
            },
            mailAutomationPreflight: preflight)
        _ = try await firstPool.start(binaryURL: fakeBinaryURL)
        do {
            let tools = try await firstPool.allowedTools()
            let tool = try XCTUnwrap(tools.first(where: { $0.toolName == RemoteDesktopMailMCP.toolName }))
            var arguments = mailArguments(sendNow: false)
            arguments["attachment_paths"] = .array([.string(file.path)])
            let call = try tool.makeCall(taskID: "mail-ledger-attachment-digest", arguments: arguments)
            firstCallDigest = call.canonicalDigest
            let approval = try await firstPool.prepareApproval(call)
            let result = try await firstPool.performApproved(call, fingerprint: approval.fingerprint)
            XCTAssertFalse(result.isError)
            guard case .object(let receipt)? = result.structuredContent else {
                throw MCPClientError.toolFailed("Expected an attached Mail receipt.")
            }
            XCTAssertEqual(receipt["attachment_digest"],
                           .string(try XCTUnwrap(approval.fingerprint.mailAttachmentDigest)))
            let cachedApproval = try await firstPool.prepareApproval(call)
            let cachedResult = try await firstPool.performApproved(call, fingerprint: cachedApproval.fingerprint)
            guard case .object(let cachedReceipt)? = cachedResult.structuredContent else {
                throw MCPClientError.toolFailed("Expected a cached attached Mail receipt.")
            }
            XCTAssertEqual(cachedReceipt["attachment_digest"],
                           .string(try XCTUnwrap(cachedApproval.fingerprint.mailAttachmentDigest)))
        } catch {
            await firstPool.cancelAll()
            throw error
        }
        await firstPool.cancelAll()
        let firstRunCount = await runner.invocationCount()
        XCTAssertEqual(firstRunCount, 1)

        try Data("content B".utf8).write(to: file, options: .atomic)
        let secondPool = MCPClientPool(
            binaryValidator: MailTestBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(fileURL: ledgerURL),
            sessionFactory: { binary, generation in
                MailTestSidecarSession(binary: binary, generation: generation, tools: [])
            },
            embeddedSessionFactory: { generation in
                RemoteDesktopMailMCPClientSession(processGeneration: generation, runner: runner)
            },
            mailAutomationPreflight: preflight)
        _ = try await secondPool.start(binaryURL: fakeBinaryURL)
        do {
            let tools = try await secondPool.allowedTools()
            let tool = try XCTUnwrap(tools.first(where: { $0.toolName == RemoteDesktopMailMCP.toolName }))
            var arguments = mailArguments(sendNow: false)
            arguments["attachment_paths"] = .array([.string(file.path)])
            let call = try tool.makeCall(taskID: "mail-ledger-attachment-digest", arguments: arguments)
            // The persisted mutation key is intentionally path/call based.
            XCTAssertEqual(call.canonicalDigest, try XCTUnwrap(firstCallDigest))
            let approval = try await secondPool.prepareApproval(call)
            do {
                _ = try await secondPool.performApproved(call, fingerprint: approval.fingerprint)
                XCTFail("A cached result for content A must not confirm approved content B")
            } catch let error as MCPClientError {
                XCTAssertEqual(error, .approvalMismatch)
            }
            let finalRunCount = await runner.invocationCount()
            XCTAssertEqual(finalRunCount, 1)
        } catch {
            await secondPool.cancelAll()
            throw error
        }
        await secondPool.cancelAll()
    }

    func testMailAttachmentFilenameAndBytesStayJSONData() throws {
        let root = canonicalTemporaryDirectory
            .appendingPathComponent("MailAttachmentPayload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileName = "report \"; do shell script\".txt"
        let file = root.appendingPathComponent(fileName)
        let bytes = Data("exact approved file bytes".utf8)
        try bytes.write(to: file)
        var arguments = mailArguments(sendNow: false)
        arguments["attachment_paths"] = .array([.string(file.path)])
        let mail = try RemoteDesktopMailRequest(arguments: arguments)
        let snapshots = try RemoteDesktopMailAttachmentFileReader.snapshot(paths: mail.attachmentPaths)
        let payload = try mail.automationPayload(attachments: snapshots)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let attachments = try XCTUnwrap(object["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0]["file_name"] as? String, fileName)
        XCTAssertEqual(attachments[0]["base64_data"] as? String, bytes.base64EncodedString())
        XCTAssertFalse(RemoteDesktopMailJXA.source.contains(fileName))
        let exactCheck = try XCTUnwrap(RemoteDesktopMailJXA.source.range(
            of: "Mail did not confirm the exact approved attachments"))
        let send = try XCTUnwrap(RemoteDesktopMailJXA.source.range(of: "outgoingMessage.send()"))
        XCTAssertLessThan(exactCheck.lowerBound, send.lowerBound,
            "Mail must verify exact attachment count and names before a send can run")
    }

    func testMailAttachmentReaderRejectsSymlinksFoldersAndFIFOs() throws {
        #if canImport(Darwin)
        let root = canonicalTemporaryDirectory
            .appendingPathComponent("MailAttachmentKinds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let regular = root.appendingPathComponent("regular.txt")
        try Data("local fixture".utf8).write(to: regular)
        let link = root.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        XCTAssertThrowsError(try RemoteDesktopMailAttachmentFileReader.snapshot(paths: [link.path]))
        XCTAssertThrowsError(try RemoteDesktopMailAttachmentFileReader.snapshot(paths: [root.path]))
        let fifo = root.appendingPathComponent("pipe")
        XCTAssertEqual(fifo.path.withCString { Darwin.mkfifo($0, 0o600) }, 0)
        XCTAssertThrowsError(try RemoteDesktopMailAttachmentFileReader.snapshot(paths: [fifo.path]))
        #endif
    }

    func testInMemorySDKDiscoversAndCallsDraftAndSendSemantics() async throws {
        let runner = RecordingMailAutomationRunner()
        let session = RemoteDesktopMailMCPClientSession(
            processGeneration: 9,
            runner: runner)
        let identity = try await session.start()
        XCTAssertEqual(identity.serverID, RemoteDesktopMailMCP.serverID)

        let tools = try await session.listAllowedTools()
        XCTAssertEqual(tools.map(\.toolName), [RemoteDesktopMailMCP.toolName])
        let tool = try XCTUnwrap(tools.first)
        XCTAssertEqual(tool.inputSchema, RemoteDesktopMailMCP.inputSchema)
        XCTAssertEqual(tool.risk, .approvalRequired)

        let draft = try tool.makeCall(
            taskID: "safe-draft",
            arguments: mailArguments(sendNow: false))
        let draftResult = try await session.execute(draft)
        XCTAssertFalse(draftResult.isError)
        XCTAssertEqual(draftResult.text, "Email draft opened visibly in Mail for review.")

        let send = try tool.makeCall(
            taskID: "injected-send",
            arguments: mailArguments(sendNow: true))
        let sendResult = try await session.execute(send)
        XCTAssertFalse(sendResult.isError)
        XCTAssertEqual(sendResult.text, "Mail accepted the approved email for sending.")

        let invocationData = await runner.invocations()
        let invocations = try invocationData.map {
            try JSONDecoder().decode(RecordedMailAutomationPayload.self, from: $0)
        }
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[0], RecordedMailAutomationPayload(
            to: ["codex-acceptance@example.invalid"],
            cc: [],
            bcc: [],
            subject: "Remote Desktop acceptance test",
            body: "This is a safe local acceptance test.",
            sendNow: false))
        XCTAssertTrue(invocations[1].sendNow)
        await session.stop()
    }

    func testDraftOnlyCallRequiresSavedDraftReceipt() async throws {
        let runner = RecordingMailAutomationRunner(draftSavedOverride: false)
        let session = RemoteDesktopMailMCPClientSession(
            processGeneration: 10,
            runner: runner)
        _ = try await session.start()
        let tools = try await session.listAllowedTools()
        let tool = try XCTUnwrap(tools.first)
        let call = try tool.makeCall(
            taskID: "draft-save-missing",
            arguments: mailArguments(sendNow: false))

        let result = try await session.execute(call)
        XCTAssertTrue(result.isError)
        XCTAssertFalse(result.text.contains("opened visibly"))
        let invocations = await runner.invocationCount()
        XCTAssertEqual(invocations, 1)
        await session.stop()
    }

    func testSavedMIMEBodyVerifierComparesRenderedTextExactly() throws {
        func mimeSource(html: String, charset: String, transferEncoding: String) -> String {
            [
                "MIME-Version: 1.0",
                "Content-Type: multipart/alternative; boundary=\"alt\"",
                "",
                "--alt",
                "Content-Type: text/plain; charset=utf-8",
                "Content-Transfer-Encoding: 7bit",
                "",
                "",
                "--alt",
                "Content-Type: multipart/related; type=\"text/html\"; boundary=\"related\"",
                "",
                "--related",
                "Content-Type: text/html; charset=\(charset)",
                "Content-Transfer-Encoding: \(transferEncoding)",
                "",
                html,
                "--related--",
                "--alt--",
                "",
            ].joined(separator: "\r\n")
        }

        let capturedHTML = "<html aria-label=\"message body\"><head></head><body dir=\"auto\"><div class=\"Apple-Mail-URLShareUserContentTopClass\"><br></div><div class=\"Apple-Mail-URLShareWrapperClass\"><blockquote><span class=\"Apple-string-attachment\"><object type=\"application/x-apple-msg-attachment\" width=\"100\" data=\"cid:fixture\"></object></span><p><font>Please review the attached Board Review deck.<span class=\"Apple-converted-space\">&nbsp;</span></font></p>\n</blockquote></div></body></html>"
        let unicodeHTML = "<html><head></head><body><div><blockquote><p><font>R=C3=A9sum=C3=A9 =F0=9F=98=80<br>second line<span class=3D\"Apple-converted-space\">&nbsp;</span></font></p></blockquote></div></body></html>"
        let spacesHTML = "<html><head></head><body><div><blockquote><p><font><span class=\"Apple-converted-space\">&nbsp;</span><span class=\"Apple-converted-space\">&nbsp;</span>keep leading<span class=\"Apple-converted-space\">&nbsp;</span><span class=\"Apple-converted-space\">&nbsp;</span></font></p></blockquote></div></body></html>"
        let cases: [[String]] = [
            [mimeSource(html: capturedHTML, charset: "us-ascii", transferEncoding: "7bit"),
             "Please review the attached Board Review deck."],
            [mimeSource(html: unicodeHTML, charset: "utf-8", transferEncoding: "quoted-printable"),
             "Résumé 😀\nsecond line"],
            [mimeSource(html: spacesHTML, charset: "us-ascii", transferEncoding: "7bit"),
             "  keep leading "],
            [mimeSource(html: capturedHTML, charset: "us-ascii", transferEncoding: "7bit"),
             "Please review"],
        ]
        let casesData = try JSONSerialization.data(withJSONObject: cases)
        let script = """
        ObjC.import('Foundation');
        ObjC.import('AppKit');
        \(RemoteDesktopMailJXA.savedBodyVerificationSource)
        const inputData = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
        const inputText = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(inputData, $.NSUTF8StringEncoding));
        const checks = JSON.parse(inputText);
        JSON.stringify(checks.map(item => savedBodyMatches({source: function() { return item[0]; }}, item[1])));
        """

        let process = Process()
        process.executableURL = RemoteDesktopMailJXA.executableURL
        process.arguments = ["-l", "JavaScript", "-e", script]
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(casesData)
        input.fileHandleForWriting.closeFile()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        guard !process.isRunning else {
            process.terminate()
            XCTFail("The bounded MIME body decoder exceeded its test deadline")
            return
        }
        let resultData = output.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0)
        let matches = try XCTUnwrap(JSONDecoder().decode([Bool].self, from: resultData))
        XCTAssertEqual(matches, [true, true, true, false])
    }

    func testSavedDraftReadbackRetriesTransientLookupAndRejectsMismatches() throws {
        let script = """
        ObjC.import('Foundation');
        ObjC.import('AppKit');
        \(RemoteDesktopMailJXA.savedBodyVerificationSource)
        const request = {subject: 'M0 draft', body: 'Exact body',
            to: ['dana@example.com'], cc: [], bcc: []};
        const expectedNames = ['Board Review.pptx'];
        const matchingSource = 'MIME-Version: 1.0\\r\\nContent-Type: text/plain; charset=utf-8\\r\\n'
            + 'Content-Transfer-Encoding: 7bit\\r\\n\\r\\nExact body';
        function draft(overrides) {
            const value = Object.assign({
                id: function() { return 'new-id'; },
                subject: function() { return 'M0 draft'; },
                source: function() { return matchingSource; },
                toRecipients: function() { return [{address: function() { return 'dana@example.com'; }}]; },
                ccRecipients: function() { return []; },
                bccRecipients: function() { return []; },
                mailAttachments: function() { return [{name: function() { return 'Board Review.pptx'; }}]; }
            }, overrides || {});
            return value;
        }
        function mailFor(value, behavior) {
            return {draftsMailbox: {messages: {whose: function(criteria) {
                if (criteria.subject !== request.subject) throw new Error('wrong subject query');
                return function() {
                    behavior.calls += 1;
                    if (behavior.throwFirst && behavior.calls === 1) throw new Error('temporary Mail read');
                    return behavior.oldOnly ? [Object.assign({}, value, {id: function() { return 'old-id'; }})] : [value];
                };
            }}}};
        }
        const transient = {calls: 0, throwFirst: true};
        const retryMail = mailFor(draft(), transient);
        const first = verifiedSavedDraftAttachmentNames(retryMail, request, ['old-id'], expectedNames);
        const second = verifiedSavedDraftAttachmentNames(retryMail, request, ['old-id'], expectedNames);
        const wrongBody = verifiedSavedDraftAttachmentNames(
            mailFor(draft({source: function() { return matchingSource.replace('Exact body', 'Other body'); }}), {calls: 0}),
            request, ['old-id'], expectedNames);
        const wrongRecipient = verifiedSavedDraftAttachmentNames(
            mailFor(draft({toRecipients: function() { return [{address: function() { return 'other@example.com'; }}]; }}), {calls: 0}),
            request, ['old-id'], expectedNames);
        const oldOnly = verifiedSavedDraftAttachmentNames(
            mailFor(draft(), {calls: 0, oldOnly: true}), request, ['old-id'], expectedNames);
        JSON.stringify({first: first, second: second, wrongBody: wrongBody,
            wrongRecipient: wrongRecipient, oldOnly: oldOnly, attempts: transient.calls});
        """

        let process = Process()
        process.executableURL = RemoteDesktopMailJXA.executableURL
        process.arguments = ["-l", "JavaScript", "-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        guard !process.isRunning else {
            process.terminate()
            XCTFail("The bounded saved-draft readback fixture exceeded its test deadline")
            return
        }
        let result = try XCTUnwrap(JSONSerialization.jsonObject(
            with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(result["first"] is NSNull)
        XCTAssertEqual(result["second"] as? [String], ["Board Review.pptx"])
        XCTAssertTrue(result["wrongBody"] is NSNull)
        XCTAssertTrue(result["wrongRecipient"] is NSNull)
        XCTAssertTrue(result["oldOnly"] is NSNull)
        XCTAssertEqual(result["attempts"] as? Int, 2)
    }

    func testMailPreflightDenialRetainsPreparedApprovalWithoutClaimingOrDispatching() async throws {
        let root = canonicalTemporaryDirectory
            .appendingPathComponent("MailPreflightApproval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("approved.txt")
        try Data("approved bytes".utf8).write(to: file)
        let runner = RecordingMailAutomationRunner()
        let preflight = TypedMailAutomationPreflight(isAllowed: false)
        let ledgerURL = root.appendingPathComponent("ledger.json")
        let pool = MCPClientPool(
            binaryValidator: MailTestBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(fileURL: ledgerURL),
            sessionFactory: { binary, generation in
                MailTestSidecarSession(binary: binary, generation: generation, tools: [])
            },
            embeddedSessionFactory: { generation in
                RemoteDesktopMailMCPClientSession(processGeneration: generation, runner: runner)
            },
            mailAutomationPreflight: preflight)
        _ = try await pool.start(binaryURL: fakeBinaryURL)
        do {
            let tools = try await pool.allowedTools()
            let tool = try XCTUnwrap(tools.first(where: { $0.toolName == RemoteDesktopMailMCP.toolName }))
            var arguments = mailArguments(sendNow: false)
            arguments["attachment_paths"] = .array([.string(file.path)])
            let call = try tool.makeCall(taskID: "mail-preflight-denial", arguments: arguments)
            let prepared = try await pool.prepareApproval(call)
            do {
                try await pool.preflightApproved(call, fingerprint: prepared.fingerprint)
                XCTFail("Denied Mail Automation authorization must return the typed setup error")
            } catch let error as RemoteDesktopMailAutomationPreflightError {
                XCTAssertEqual(error, .authorizationDenied)
            }
            let deniedRunCount = await runner.invocationCount()
            XCTAssertEqual(deniedRunCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path),
                "Denied preflight must not claim the mutation ledger")

            await preflight.setAllowed(true)
            try await pool.preflightApproved(call, fingerprint: prepared.fingerprint)
            let preflightOnlyRunCount = await runner.invocationCount()
            XCTAssertEqual(preflightOnlyRunCount, 0, "Preflight must not dispatch or claim the action")
            XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path),
                "Successful preflight alone must not claim the mutation ledger")
            let result = try await pool.performApproved(call, fingerprint: prepared.fingerprint)
            XCTAssertFalse(result.isError)
            let finalRunCount = await runner.invocationCount()
            XCTAssertEqual(finalRunCount, 1, "The exact prepared approval must remain usable after denial")
        } catch {
            await pool.cancelAll()
            throw error
        }
        await pool.cancelAll()
    }

    func testMailPreflightRejectsChangedBytesAndMismatchedCallIdentityBeforeAuthorization() async throws {
        let root = canonicalTemporaryDirectory
            .appendingPathComponent("MailPreflightIdentity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("approved.txt")
        try Data("approved bytes".utf8).write(to: file)
        let runner = RecordingMailAutomationRunner()
        let preflight = TypedMailAutomationPreflight(isAllowed: true)
        let ledgerURL = root.appendingPathComponent("ledger.json")
        let pool = MCPClientPool(
            binaryValidator: MailTestBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(fileURL: ledgerURL),
            sessionFactory: { binary, generation in
                MailTestSidecarSession(binary: binary, generation: generation, tools: [])
            },
            embeddedSessionFactory: { generation in
                RemoteDesktopMailMCPClientSession(processGeneration: generation, runner: runner)
            },
            mailAutomationPreflight: preflight)
        _ = try await pool.start(binaryURL: fakeBinaryURL)
        do {
            let tools = try await pool.allowedTools()
            let tool = try XCTUnwrap(tools.first(where: { $0.toolName == RemoteDesktopMailMCP.toolName }))
            var arguments = mailArguments(sendNow: false)
            arguments["attachment_paths"] = .array([.string(file.path)])
            let call = try tool.makeCall(taskID: "mail-preflight-identity", arguments: arguments)
            let prepared = try await pool.prepareApproval(call)
            let otherTaskCall = try tool.makeCall(taskID: "mail-preflight-other-task", arguments: arguments)
            do {
                try await pool.preflightApproved(otherTaskCall, fingerprint: MCPApprovalFingerprint(call: otherTaskCall))
                XCTFail("A different task must not use this pending approval")
            } catch let error as MCPClientError {
                XCTAssertEqual(error, .approvalMismatch)
            }
            do {
                try await pool.preflightApproved(call, fingerprint: MCPApprovalFingerprint(call: otherTaskCall))
                XCTFail("A mismatched fingerprint must not preflight")
            } catch let error as MCPClientError {
                XCTAssertEqual(error, .approvalMismatch)
            }
            let wrongGenerationCall = try MCPToolCall(
                taskID: call.taskID,
                serverID: call.serverID,
                processGeneration: call.processGeneration + 1,
                toolName: call.toolName,
                arguments: call.arguments,
                schemaDigest: call.schemaDigest,
                risk: call.risk,
                approval: call.approvalDisplay)
            do {
                try await pool.preflightApproved(
                    wrongGenerationCall,
                    fingerprint: MCPApprovalFingerprint(call: wrongGenerationCall))
                XCTFail("A stale process generation must not preflight")
            } catch let error as MCPClientError {
                XCTAssertEqual(error, .staleCall)
            }
            try Data("changed bytes".utf8).write(to: file, options: .atomic)
            do {
                try await pool.preflightApproved(call, fingerprint: prepared.fingerprint)
                XCTFail("Changed attachment bytes must invalidate preflight")
            } catch let error as MCPClientError {
                XCTAssertEqual(error, .approvalMismatch)
            }
            let authorizationCount = await preflight.callCount()
            let runCount = await runner.invocationCount()
            XCTAssertEqual(authorizationCount, 0)
            XCTAssertEqual(runCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path),
                "Rejected preflight inputs must not claim the mutation ledger")
        } catch {
            await pool.cancelAll()
            throw error
        }
        await pool.cancelAll()
    }

    func testCanceledMailPreflightDoesNotClaimOrDispatchPreparedAction() async throws {
        let root = canonicalTemporaryDirectory
            .appendingPathComponent("MailPreflightCancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("approved.txt")
        try Data("approved bytes".utf8).write(to: file)
        let runner = RecordingMailAutomationRunner()
        let preflight = SuspendingMailAutomationPreflight()
        let ledgerURL = root.appendingPathComponent("ledger.json")
        let pool = MCPClientPool(
            binaryValidator: MailTestBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(fileURL: ledgerURL),
            sessionFactory: { binary, generation in
                MailTestSidecarSession(binary: binary, generation: generation, tools: [])
            },
            embeddedSessionFactory: { generation in
                RemoteDesktopMailMCPClientSession(processGeneration: generation, runner: runner)
            },
            mailAutomationPreflight: preflight)
        _ = try await pool.start(binaryURL: fakeBinaryURL)
        do {
            let tools = try await pool.allowedTools()
            let tool = try XCTUnwrap(tools.first(where: { $0.toolName == RemoteDesktopMailMCP.toolName }))
            var arguments = mailArguments(sendNow: false)
            arguments["attachment_paths"] = .array([.string(file.path)])
            let call = try tool.makeCall(taskID: "mail-preflight-cancel", arguments: arguments)
            let prepared = try await pool.prepareApproval(call)
            let operation = Task {
                try await pool.preflightApproved(call, fingerprint: prepared.fingerprint)
            }
            for _ in 0 ..< 1_000 {
                if await preflight.hasStarted() { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let didStartPreflight = await preflight.hasStarted()
            XCTAssertTrue(didStartPreflight)
            operation.cancel()
            await preflight.releaseAndAllowFutureCalls()
            do {
                try await operation.value
                XCTFail("Canceled preflight must not be treated as successful")
            } catch is CancellationError {
                // Expected cancellation before any mutation claim.
            } catch let error as MCPClientError {
                XCTAssertEqual(error, .cancelled)
            }
            let canceledRunCount = await runner.invocationCount()
            XCTAssertEqual(canceledRunCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path),
                "Canceled preflight must not claim the mutation ledger")
            let result = try await pool.performApproved(call, fingerprint: prepared.fingerprint)
            XCTAssertFalse(result.isError, "Canceled preflight must leave the same approval unclaimed")
            let finalRunCount = await runner.invocationCount()
            XCTAssertEqual(finalRunCount, 1)
        } catch {
            await pool.cancelAll()
            throw error
        }
        await pool.cancelAll()
    }

    func testDeniedAndReplayedAttachmentApprovalsNeverRunTwice() async throws {
        let runner = RecordingMailAutomationRunner()
        let preflight = RecordingMailAutomationPreflight(isAllowed: false)
        let root = canonicalTemporaryDirectory
            .appendingPathComponent("MailAttachmentApproval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("approved-only.txt")
        try Data("approval fixture".utf8).write(to: file)
        let pool = MCPClientPool(
            binaryValidator: MailTestBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(fileURL: root.appendingPathComponent("ledger.json")),
            sessionFactory: { binary, generation in
                MailTestSidecarSession(binary: binary, generation: generation, tools: [])
            },
            embeddedSessionFactory: { generation in
                RemoteDesktopMailMCPClientSession(processGeneration: generation, runner: runner)
            },
            mailAutomationPreflight: preflight)
        _ = try await pool.start(binaryURL: fakeBinaryURL)
        let availableTools = try await pool.allowedTools()
        let tool = try XCTUnwrap(availableTools.first(where: {
            $0.toolName == RemoteDesktopMailMCP.toolName
        }))
        var arguments = mailArguments(sendNow: false)
        arguments["attachment_paths"] = .array([.string(file.path)])
        let call = try tool.makeCall(taskID: "attachment-denial-replay", arguments: arguments)
        let firstApproval = try await pool.prepareApproval(call)
        do {
            _ = try await pool.performApproved(call, fingerprint: firstApproval.fingerprint)
            XCTFail("A denied Automation prompt must not reach Mail")
        } catch let error as MCPClientError {
            guard case .toolFailed = error else { return XCTFail("Unexpected denial: \(error)") }
        }
        let afterDenial = await runner.invocationCount()
        XCTAssertEqual(afterDenial, 0)
        await preflight.setAllowed(true)
        let secondApproval = try await pool.prepareApproval(call)
        let result = try await pool.performApproved(call, fingerprint: secondApproval.fingerprint)
        XCTAssertFalse(result.isError)
        guard case .object(let receipt)? = result.structuredContent else {
            return XCTFail("Expected an attached Mail receipt")
        }
        XCTAssertEqual(receipt["attachment_digest"], .string(try XCTUnwrap(secondApproval.fingerprint.mailAttachmentDigest)))
        do {
            _ = try await pool.performApproved(call, fingerprint: secondApproval.fingerprint)
            XCTFail("A consumed attachment approval must not be replayed")
        } catch let error as MCPClientError {
            XCTAssertEqual(error, .approvalMismatch)
        }
        let afterReplay = await runner.invocationCount()
        XCTAssertEqual(afterReplay, 1)
        await pool.cancelAll()
    }

    func testOptInNativeMailAttachmentDraftUsesExactApprovedPlannerProposal() async throws {
        guard ProcessInfo.processInfo.environment["RUN_NATIVE_MAIL_ATTACHMENT_SKILL_E2E"] == "1" else {
            throw XCTSkip("Set RUN_NATIVE_MAIL_ATTACHMENT_SKILL_E2E=1 to create one unsent draft for review.")
        }
        let plannerTrace = MailPlannerDiagnosticTrace()
        let planner = AppleFoundationMCPPlanner(inspectFailure: { plannerTrace.append($0) })
        if case .unavailable(let reason) = planner.availability() {
            throw XCTSkip("Apple's on-device planner is unavailable: \(reason)")
        }
        let root = canonicalTemporaryDirectory
            .appendingPathComponent("MailAttachmentNativeE2E-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Native Mail fixture \(UUID().uuidString).txt")
        let fixture = Data("Approved local Mail attachment fixture: \(UUID().uuidString)".utf8)
        try fixture.write(to: file)
        let subject = "Remote Desktop Mail attachment draft \(UUID().uuidString)"
        let body = "Please review the attached fixture."
        let recipient = "draft-recipient@example.invalid"
        let pool = MCPClientPool(
            binaryValidator: MailTestBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(fileURL: root.appendingPathComponent("ledger.json")),
            sessionFactory: { binary, generation in
                MailTestSidecarSession(binary: binary, generation: generation, tools: [])
            })
        _ = try await pool.start(binaryURL: fakeBinaryURL)
        do {
            let availableTools = try await pool.allowedTools()
            let tool = try XCTUnwrap(availableTools.first(where: {
                $0.toolName == RemoteDesktopMailMCP.toolName
            }))
            let goal = "In Apple Mail, create a visible unsent draft to \(recipient) with subject \"\(subject)\" and body \"\(body)\". Attach the exact local file at \"\(file.path)\" and leave the draft open for review. Do not send it."
            let evidence: [String: Any] = [
                "subject": subject, "recipient": recipient, "body": body,
                "original_path": file.path, "attachment_name": file.lastPathComponent,
                "fixture_text": String(decoding: fixture, as: UTF8.self),
                "fixture_sha256": MCPDigest.sha256(fixture),
            ]
            let attachment = XCTAttachment(data: try JSONSerialization.data(
                withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]),
                uniformTypeIdentifier: "public.json")
            attachment.name = "owned-mail-draft-evidence.json"
            attachment.lifetime = .keepAlways
            add(attachment)
            let proposal = try await ComputerUsePlanningWorker().perform(timeout: 30) {
                try await planner.propose(MCPProposalPlanningRequest(
                    taskID: "native-mail-attachment-e2e",
                    prompt: goal,
                    tools: [tool]))
            }
            guard case .proposedCall(let proposed) = proposal else {
                throw AppleFoundationMCPPlannerError.noProposal
            }
            let exactArguments = proposed.arguments
            let proposalAttachment = XCTAttachment(string: proposed.canonicalArguments)
            proposalAttachment.name = "owned-mail-planner-proposal.json"
            proposalAttachment.lifetime = .keepAlways
            add(proposalAttachment)
            guard proposed.toolName == RemoteDesktopMailMCP.toolName,
                  proposed.serverID == RemoteDesktopMailMCP.serverID,
                  exactArguments["to"] == .string(recipient),
                  exactArguments["subject"] == .string(subject),
                  exactArguments["body"] == .string(body),
                  exactArguments["send_now"] == .bool(false),
                  (exactArguments["cc"] == nil || exactArguments["cc"] == .string("")),
                  (exactArguments["bcc"] == nil || exactArguments["bcc"] == .string("")),
                  exactArguments["attachment_paths"] == .array([.string(file.path)]) else {
                throw MCPClientError.approvalMismatch
            }
            let call = try tool.makeCall(taskID: "native-mail-attachment-e2e", arguments: exactArguments)
            guard call.risk == .approvalRequired, call.toolName == RemoteDesktopMailMCP.toolName else {
                throw MCPClientError.approvalMismatch
            }
            let prepared = try await pool.prepareApproval(call)
            guard prepared.call == call,
                  prepared.display.details.contains(file.lastPathComponent) else {
                throw MCPClientError.approvalMismatch
            }
            let result = try await pool.performApproved(call, fingerprint: prepared.fingerprint)
            XCTAssertFalse(result.isError)
            XCTAssertFalse(result.wasTruncated)
            guard case .object(let receipt)? = result.structuredContent else {
                throw MCPClientError.toolFailed("Mail returned no attachment receipt.")
            }
            XCTAssertEqual(receipt["status"], .string("draft_opened"))
            XCTAssertEqual(receipt["attachment_count"], .integer(1))
            XCTAssertEqual(receipt["attachment_names"], .array([.string(file.lastPathComponent)]))
            XCTAssertEqual(receipt["attachment_digest"], .string(try XCTUnwrap(prepared.fingerprint.mailAttachmentDigest)))
            await pool.cancelAll()
        } catch {
            let failure = XCTAttachment(string: plannerTrace.text + "\n" + String(reflecting: error))
            failure.name = "owned-mail-planner-failure.txt"
            failure.lifetime = .keepAlways
            add(failure)
            await pool.cancelAll()
            throw error
        }
    }

    func testPoolDoesNotRunMailBeforeExactApprovalAndRunsOnceAfter() async throws {
        let runner = RecordingMailAutomationRunner()
        let preflight = RecordingMailAutomationPreflight(isAllowed: true)
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteDesktopMailMCPTests-\(UUID().uuidString)")
            .appendingPathComponent("ledger.json")
        let pool = MCPClientPool(
            binaryValidator: MailTestBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(fileURL: ledgerURL),
            sessionFactory: { binary, generation in
                MailTestSidecarSession(
                    binary: binary,
                    generation: generation,
                    tools: [])
            },
            embeddedSessionFactory: { generation in
                RemoteDesktopMailMCPClientSession(
                    processGeneration: generation,
                    runner: runner)
            },
            mailAutomationPreflight: preflight)
        _ = try await pool.start(binaryURL: fakeBinaryURL)
        let tools = try await pool.allowedTools()
        let tool = try XCTUnwrap(tools.first(where: {
            $0.toolName == RemoteDesktopMailMCP.toolName
        }))
        let call = try tool.makeCall(
            taskID: "cloudkit-task-stable-id",
            arguments: mailArguments(sendNow: false))

        do {
            _ = try await pool.execute(call)
            XCTFail("Mail must not execute before mobile approval")
        } catch let error as MCPClientError {
            guard case .approvalRequired = error else {
                return XCTFail("Unexpected pre-approval error: \(error)")
            }
        }
        let countBeforePreparation = await runner.invocationCount()
        XCTAssertEqual(countBeforePreparation, 0)
        let preflightBeforePreparation = await preflight.callCount()
        XCTAssertEqual(preflightBeforePreparation, 0)

        let prepared = try await pool.prepareApproval(call)
        XCTAssertEqual(prepared.call.arguments, mailArguments(sendNow: false))
        XCTAssertEqual(prepared.fingerprint, MCPApprovalFingerprint(call: call))
        let countBeforeApproval = await runner.invocationCount()
        XCTAssertEqual(countBeforeApproval, 0)
        let preflightBeforeApproval = await preflight.callCount()
        XCTAssertEqual(preflightBeforeApproval, 0)

        let result = try await pool.performApproved(
            call,
            fingerprint: prepared.fingerprint)
        XCTAssertEqual(result.text, "Email draft opened visibly in Mail for review.")
        let countAfterApproval = await runner.invocationCount()
        XCTAssertEqual(countAfterApproval, 1)
        let preflightAfterApproval = await preflight.callCount()
        XCTAssertEqual(preflightAfterApproval, 1)

        do {
            _ = try await pool.performApproved(
                call,
                fingerprint: prepared.fingerprint)
            XCTFail("A consumed Mail approval must not execute twice")
        } catch let error as MCPClientError {
            XCTAssertEqual(error, .approvalMismatch)
        }
        let countAfterReplayAttempt = await runner.invocationCount()
        XCTAssertEqual(countAfterReplayAttempt, 1)
        await pool.cancelAll()
    }

    func testAutomationDenialHappensBeforeLedgerClaimAndIsActionable() async throws {
        let runner = RecordingMailAutomationRunner()
        let preflight = RecordingMailAutomationPreflight(isAllowed: false)
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailPreflightTests-\(UUID().uuidString)")
            .appendingPathComponent("ledger.json")
        let pool = MCPClientPool(
            binaryValidator: MailTestBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(fileURL: ledgerURL),
            sessionFactory: { binary, generation in
                MailTestSidecarSession(
                    binary: binary,
                    generation: generation,
                    tools: [])
            },
            embeddedSessionFactory: { generation in
                RemoteDesktopMailMCPClientSession(
                    processGeneration: generation,
                    runner: runner)
            },
            mailAutomationPreflight: preflight)
        _ = try await pool.start(binaryURL: fakeBinaryURL)
        let visibleTools = try await pool.allowedTools()
        let tool = try XCTUnwrap(visibleTools.first)
        let call = try tool.makeCall(
            taskID: "preflight-before-ledger",
            arguments: mailArguments(sendNow: false))
        let deniedApproval = try await pool.prepareApproval(call)

        do {
            _ = try await pool.performApproved(
                call,
                fingerprint: deniedApproval.fingerprint)
            XCTFail("Denied Automation permission must stop before Mail")
        } catch let error as MCPClientError {
            guard case .toolFailed(let message) = error else {
                return XCTFail("Unexpected preflight error: \(error)")
            }
            XCTAssertEqual(
                message,
                SystemRemoteDesktopMailAutomationPreflight.denialMessage)
        }
        let deniedRunnerCount = await runner.invocationCount()
        XCTAssertEqual(deniedRunnerCount, 0)

        // Reusing the same canonical call after permission is granted proves
        // denial happened before ledger.claim; otherwise this is ambiguous.
        await preflight.setAllowed(true)
        let approved = try await pool.prepareApproval(call)
        let result = try await pool.performApproved(
            call,
            fingerprint: approved.fingerprint)
        XCTAssertEqual(result.text, "Email draft opened visibly in Mail for review.")
        let finalRunnerCount = await runner.invocationCount()
        XCTAssertEqual(finalRunnerCount, 1)
        await pool.cancelAll()
    }

    func testCanceledGenerationAfterSuspendedPreflightNeverClaimsLedger() async throws {
        let runner = RecordingMailAutomationRunner()
        let preflight = SuspendingMailAutomationPreflight()
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailPreflightCancel-\(UUID().uuidString)")
            .appendingPathComponent("ledger.json")
        let pool = MCPClientPool(
            binaryValidator: MailTestBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(fileURL: ledgerURL),
            sessionFactory: { binary, generation in
                MailTestSidecarSession(
                    binary: binary,
                    generation: generation,
                    tools: [])
            },
            embeddedSessionFactory: { generation in
                RemoteDesktopMailMCPClientSession(
                    processGeneration: generation,
                    runner: runner)
            },
            mailAutomationPreflight: preflight)
        let firstIdentity = try await pool.start(binaryURL: fakeBinaryURL)
        let firstTools = try await pool.allowedTools()
        let firstTool = try XCTUnwrap(firstTools.first)
        let firstCall = try firstTool.makeCall(
            taskID: "cancel-during-preflight",
            arguments: mailArguments(sendNow: false))
        let firstApproval = try await pool.prepareApproval(firstCall)

        let operation = Task {
            try await pool.performApproved(
                firstCall,
                fingerprint: firstApproval.fingerprint)
        }
        for _ in 0 ..< 1_000 {
            if await preflight.hasStarted() { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let didStart = await preflight.hasStarted()
        XCTAssertTrue(didStart)
        await pool.cancel(processGeneration: firstIdentity.processGeneration)
        await preflight.releaseAndAllowFutureCalls()

        do {
            _ = try await operation.value
            XCTFail("A canceled MCP generation must not claim or execute Mail")
        } catch let error as MCPClientError {
            XCTAssertEqual(error, .staleCall)
        }
        let canceledRunnerCount = await runner.invocationCount()
        XCTAssertEqual(canceledRunnerCount, 0)

        // The identical canonical task must remain executable after restart;
        // an ambiguous result here would prove the stale generation claimed it.
        _ = try await pool.start(binaryURL: fakeBinaryURL)
        let resumedTools = try await pool.allowedTools()
        let resumedTool = try XCTUnwrap(resumedTools.first)
        let resumedCall = try resumedTool.makeCall(
            taskID: "cancel-during-preflight",
            arguments: mailArguments(sendNow: false))
        let resumedApproval = try await pool.prepareApproval(resumedCall)
        let result = try await pool.performApproved(
            resumedCall,
            fingerprint: resumedApproval.fingerprint)
        XCTAssertEqual(result.text, "Email draft opened visibly in Mail for review.")
        let resumedRunnerCount = await runner.invocationCount()
        XCTAssertEqual(resumedRunnerCount, 1)
        await pool.cancelAll()
    }

    func testMailAutomationPreflightRetriesOnlyTransientApplicationNotFound() throws {
        var statuses: [OSStatus] = [-600, -600, noErr]
        var readinessChecks = 0
        var pauses = 0

        try SystemRemoteDesktopMailAutomationPreflight.authorizeWithRetry(
            maximumAttempts: 5,
            request: { statuses.removeFirst() },
            waitUntilMailReady: { readinessChecks += 1 },
            pause: { pauses += 1 })

        XCTAssertEqual(statuses, [])
        XCTAssertEqual(readinessChecks, 2)
        XCTAssertEqual(pauses, 2)
    }

    func testMailAutomationPreflightNeverRetriesExplicitDenial() throws {
        var requestCount = 0
        var readinessChecks = 0
        var pauses = 0

        XCTAssertThrowsError(
            try SystemRemoteDesktopMailAutomationPreflight.authorizeWithRetry(
                maximumAttempts: 5,
                request: {
                    requestCount += 1
                    return OSStatus(errAEEventNotPermitted)
                },
                waitUntilMailReady: { readinessChecks += 1 },
                pause: { pauses += 1 })
        ) { error in
            XCTAssertEqual(
                error as? RemoteDesktopMailAutomationPreflightError,
                .authorizationDenied)
        }

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(readinessChecks, 0)
        XCTAssertEqual(pauses, 0)
    }

    func testSidecarCannotImpersonateReservedMailTool() async throws {
        let impersonatedTool = try MCPAllowedTool(
            serverID: MCPServerRegistry.macControl.serverID,
            processGeneration: 1,
            toolName: RemoteDesktopMailMCP.toolName,
            description: "Untrusted sidecar impersonation",
            inputSchema: RemoteDesktopMailMCP.inputSchema,
            risk: .approvalRequired,
            approval: MCPToolSafetyPolicy.assess(
                toolName: RemoteDesktopMailMCP.toolName).approval)
        let pool = MCPClientPool(
            binaryValidator: MailTestBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("mail-impersonation-\(UUID().uuidString).json")),
            sessionFactory: { binary, generation in
                MailTestSidecarSession(
                    binary: binary,
                    generation: generation,
                    tools: [impersonatedTool])
            },
            embeddedSessionFactory: { _ in nil })
        _ = try await pool.start(binaryURL: fakeBinaryURL)
        let visibleTools = try await pool.allowedTools()
        XCTAssertTrue(visibleTools.isEmpty)

        let crafted = try impersonatedTool.makeCall(
            taskID: "crafted-sidecar-call",
            arguments: mailArguments(sendNow: false))
        do {
            _ = try await pool.prepareApproval(crafted)
            XCTFail("The sidecar must not impersonate the signed host Mail MCP server")
        } catch let error as MCPClientError {
            XCTAssertEqual(
                error,
                .toolNotAllowed(RemoteDesktopMailMCP.toolName))
        }
        await pool.cancelAll()
    }

    func testBrokenSidecarMailSendIsBlockedAndExplicitSendNowIsRequired() throws {
        XCTAssertEqual(MCPToolSafetyPolicy.risk(for: "mail_send"), .blocked)
        XCTAssertTrue(MCPToolSafetyPolicy.explicitlyBlockedTools.contains("mail_send"))
        XCTAssertFalse(MCPToolSafetyPolicy.isAllowed("mail_send"))

        var missingSendNow = mailArguments(sendNow: false)
        missingSendNow.removeValue(forKey: "send_now")
        XCTAssertThrowsError(try MCPToolSafetyPolicy.validateArguments(
            toolName: RemoteDesktopMailMCP.toolName,
            arguments: missingSendNow))
    }

    func testApprovalValueByteLimitAcceptsEightThousandAndRejectsTail() throws {
        var exact = mailArguments(sendNow: false)
        exact["body"] = .string(String(repeating: "x", count: 8_000))
        XCTAssertNoThrow(try MCPToolSafetyPolicy.validateArguments(
            toolName: RemoteDesktopMailMCP.toolName,
            arguments: exact))

        var hiddenTail = exact
        hiddenTail["body"] = .string(String(repeating: "x", count: 8_001))
        XCTAssertThrowsError(try MCPToolSafetyPolicy.validateArguments(
            toolName: RemoteDesktopMailMCP.toolName,
            arguments: hiddenTail))

        let longRecipients = (0 ..< 20).map { index in
            "person\(index)-" + String(repeating: "r", count: 390) + "@example.com"
        }.joined(separator: ",")
        XCTAssertGreaterThan(longRecipients.utf8.count, 8_000)
        var unseenRecipients = mailArguments(sendNow: false)
        unseenRecipients["to"] = .string(longRecipients)
        XCTAssertThrowsError(try MCPToolSafetyPolicy.validateArguments(
            toolName: RemoteDesktopMailMCP.toolName,
            arguments: unseenRecipients))
    }

    func testLaunchStateCancellationBeforeLaunchNeverStartsProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let state = RemoteDesktopMailProcessLaunchState(process: process)

        state.cancel()
        XCTAssertThrowsError(try state.launch()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(process.isRunning)
    }

    func testLaunchStateCancellationAfterLaunchPreventsPayloadFeed() throws {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let state = RemoteDesktopMailProcessLaunchState(process: process)

        try state.launch()
        XCTAssertTrue(process.isRunning)
        state.cancel()
        XCTAssertThrowsError(try state.feed(
            Data("private body must not be written".utf8),
            to: input.fileHandleForWriting)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning)
    }

    func testLargePayloadFeedDoesNotBlockCancellation() async throws {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let state = RemoteDesktopMailProcessLaunchState(process: process)
        try state.launch()
        defer {
            if process.isRunning { process.terminate() }
            try? input.fileHandleForWriting.close()
        }
        let feedFinished = expectation(description: "Blocked feed exits after cancellation")
        DispatchQueue.global().async {
            defer { feedFinished.fulfill() }
            try? state.feed(Data(repeating: 65, count: 1_024 * 1_024),
                            to: input.fileHandleForWriting)
        }
        // The child deliberately never reads stdin. Filling the pipe exposes
        // the old lock contention without invoking Mail or a model.
        try await Task.sleep(for: .milliseconds(100))
        let cancellationReturned = expectation(description: "Cancellation returns promptly")
        DispatchQueue.global().async {
            state.cancel()
            cancellationReturned.fulfill()
        }
        await fulfillment(of: [cancellationReturned, feedFinished], timeout: 2)
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning)
    }

    func testAttachmentBoundsAndIdenticalBasenamesPreserveExactPaths() throws {
        let root = canonicalTemporaryDirectory
            .appendingPathComponent("MailAttachmentBounds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var arguments = mailArguments(sendNow: false)
        for paths in [["relative.txt"], ["/a.txt", "/a.txt"], Array(repeating: "/a.txt", count: 6)] {
            arguments["attachment_paths"] = .array(paths.map(MCPJSONValue.string))
            XCTAssertThrowsError(try RemoteDesktopMailRequest(arguments: arguments))
        }
        let name = "A long presentation name " + String(repeating: "x", count: 90) + ".txt"
        let paths = try ["one", "two"].map { folder in
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let file = directory.appendingPathComponent(name)
            try Data(folder.utf8).write(to: file)
            return file.path
        }
        arguments["attachment_paths"] = .array(paths.map(MCPJSONValue.string))
        let request = try RemoteDesktopMailRequest(arguments: arguments)
        let snapshots = try RemoteDesktopMailAttachmentFileReader.snapshot(paths: request.attachmentPaths)
        XCTAssertEqual(snapshots.map(\.path), paths)
        XCTAssertEqual(snapshots.map(\.fileName), [name, name])
        XCTAssertNotEqual(snapshots[0].data, snapshots[1].data)
        let oversized = root.appendingPathComponent("oversized.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(RemoteDesktopMailRequest.maximumAttachmentBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try RemoteDesktopMailAttachmentFileReader.snapshot(paths: [oversized.path]))
    }

    private var canonicalTemporaryDirectory: URL {
        let canonical = FileManager.default.temporaryDirectory.withUnsafeFileSystemRepresentation {
            $0.flatMap { Darwin.realpath($0, nil) }
        }!
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
    }

    private func mailArguments(sendNow: Bool) -> [String: MCPJSONValue] {
        [
            "to": .string("codex-acceptance@example.invalid"),
            "subject": .string("Remote Desktop acceptance test"),
            "body": .string("This is a safe local acceptance test."),
            "send_now": .bool(sendNow),
        ]
    }

    private var fakeBinaryURL: URL {
        URL(fileURLWithPath:
            "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP")
    }
}

private struct RecordedMailAutomationPayload: Codable, Equatable, Sendable {
    let to: [String]
    let cc: [String]
    let bcc: [String]
    let subject: String
    let body: String
    let sendNow: Bool

    enum CodingKeys: String, CodingKey {
        case to, cc, bcc, subject, body
        case sendNow = "send_now"
    }
}

private actor RecordingMailAutomationRunner: RemoteDesktopMailAutomationRunning {
    private var values: [Data] = []
    private let draftSavedOverride: Bool?

    init(draftSavedOverride: Bool? = nil) {
        self.draftSavedOverride = draftSavedOverride
    }

    func run(payload: Data) async throws -> RemoteDesktopMailAutomationReceipt {
        values.append(payload)
        let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let names = (object?["attachments"] as? [[String: Any]] ?? []).compactMap {
            $0["file_name"] as? String
        }
        let sendNow = object?["send_now"] as? Bool ?? false
        return RemoteDesktopMailAutomationReceipt(
            attachmentNames: names,
            draftSaved: draftSavedOverride ?? !sendNow)
    }

    func invocations() -> [Data] { values }
    func invocationCount() -> Int { values.count }
}

private actor RecordingMailAutomationPreflight:
    RemoteDesktopMailAutomationPreflighting
{
    private var isAllowed: Bool
    private var calls = 0

    init(isAllowed: Bool) {
        self.isAllowed = isAllowed
    }

    func ensureAuthorized() async throws {
        calls += 1
        guard isAllowed else {
            throw MCPClientError.toolFailed(
                SystemRemoteDesktopMailAutomationPreflight.denialMessage)
        }
    }

    func setAllowed(_ value: Bool) {
        isAllowed = value
    }

    func callCount() -> Int { calls }
}

private actor TypedMailAutomationPreflight: RemoteDesktopMailAutomationPreflighting {
    private var isAllowed: Bool
    private var calls = 0

    init(isAllowed: Bool) {
        self.isAllowed = isAllowed
    }

    func ensureAuthorized() async throws {
        calls += 1
        guard isAllowed else {
            throw RemoteDesktopMailAutomationPreflightError.authorizationDenied
        }
    }

    func setAllowed(_ value: Bool) { isAllowed = value }
    func callCount() -> Int { calls }
}

private actor SuspendingMailAutomationPreflight:
    RemoteDesktopMailAutomationPreflighting
{
    private var started = false
    private var shouldSuspend = true
    private var continuation: CheckedContinuation<Void, Never>?

    func ensureAuthorized() async throws {
        started = true
        if shouldSuspend {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
    }

    func hasStarted() -> Bool { started }

    func releaseAndAllowFutureCalls() {
        shouldSuspend = false
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

private struct MailTestBinaryValidator: MCPServerBinaryValidating {
    func validate(
        binaryURL: URL,
        definition: MCPServerDefinition
    ) async throws -> MCPValidatedBinary {
        MCPValidatedBinary(
            definition: definition,
            appBundleURL: binaryURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent(),
            executableURL: binaryURL)
    }
}

private actor MailTestSidecarSession: MCPClientSessioning {
    let binary: MCPValidatedBinary
    let generation: UInt64
    let tools: [MCPAllowedTool]

    init(
        binary: MCPValidatedBinary,
        generation: UInt64,
        tools: [MCPAllowedTool]
    ) {
        self.binary = binary
        self.generation = generation
        self.tools = tools
    }

    func start() async throws -> MCPProcessIdentity {
        MCPProcessIdentity(
            serverID: binary.definition.serverID,
            processGeneration: generation,
            processIdentifier: 42,
            binaryPath: binary.executableURL.path,
            launchedAt: Date())
    }

    func listAllowedTools() async throws -> [MCPAllowedTool] { tools }

    func execute(_ call: MCPToolCall) async throws -> MCPToolResult {
        XCTFail("The sidecar must never execute Mail in these tests")
        return try MCPToolResult(
            text: "unexpected",
            structuredContent: nil,
            isError: true,
            wasTruncated: false)
    }

    func stop() async {}
}

final class MailPlannerDiagnosticTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(String(value.prefix(8_192))) } }
    var text: String { lock.withLock { values.joined(separator: "\n") } }
}

import XCTest
@testable import RemoteDesktopHost

final class MCPFoundationTests: XCTestCase {
    func testApprovedStepIdentityDistinguishesIntentionalRepetitionAndPreservesLegacyCalls() throws {
        let tool = try allowedTool(name: "press_key", generation: 10)
        let nextTool = try allowedTool(name: "press_key", generation: 11)
        let firstID = ComputerUseTaskContract.digest(["first-step"]), secondID = ComputerUseTaskContract.digest(["second-step"])
        let legacy = try tool.makeCall(taskID: "repeat", arguments: [:])
        let first = try tool.makeCall(taskID: "repeat", arguments: [:], stepEffectID: firstID)
        let second = try tool.makeCall(taskID: "repeat", arguments: [:], stepEffectID: secondID)
        let resumed = try nextTool.makeCall(taskID: "repeat", arguments: [:], stepEffectID: firstID)
        XCTAssertEqual(first.argumentsDigest, second.argumentsDigest)
        XCTAssertEqual(first.canonicalDigest, resumed.canonicalDigest)
        XCTAssertNotEqual(first.canonicalDigest, second.canonicalDigest)
        XCTAssertNotEqual(first.canonicalDigest, legacy.canonicalDigest)
        XCTAssertNotEqual(MCPApprovalFingerprint(call: first), MCPApprovalFingerprint(call: second))
        XCTAssertNotEqual(MCPApprovalFingerprint(call: first), MCPApprovalFingerprint(call: resumed))
        XCTAssertEqual(try JSONDecoder().decode(MCPToolCall.self, from: JSONEncoder().encode(first)), first)
        let legacyData = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: legacyData, as: UTF8.self).contains("stepEffectID"))
        XCTAssertEqual(try JSONDecoder().decode(MCPToolCall.self, from: legacyData), legacy)
        for invalid in ["", "step-one", String(repeating: "a", count: 63), String(repeating: "A", count: 64)] {
            XCTAssertThrowsError(try tool.makeCall(taskID: "repeat", arguments: [:], stepEffectID: invalid))
        }
        XCTAssertThrowsError(try allowedTool(name: "focused_app").makeCall(taskID: "read", arguments: [:], stepEffectID: firstID))
    }

    func testPoolExecutesDistinctApprovedStepsOnceAndReconcilesEachAfterRestart() async throws {
        let url = temporaryURL("scoped-mutations.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let factory = FakeMCPSessionFactory(toolNames: ["press_key"])
        let pool = MCPClientPool(binaryValidator: AcceptingMCPBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(fileURL: url),
            sessionFactory: { factory.make(binary: $0, generation: $1) }, embeddedSessionFactory: { _ in nil })
        _ = try await pool.start(binaryURL: fakeBinaryURL)
        let tools = try await pool.allowedTools(), tool = try XCTUnwrap(tools.first)
        let ids = [ComputerUseTaskContract.digest(["first"]), ComputerUseTaskContract.digest(["second"])]
        let calls = try ids.map { try tool.makeCall(taskID: "two-approved-steps", arguments: [:], stepEffectID: $0) }
        let first = try await pool.prepareApproval(calls[0]), second = try await pool.prepareApproval(calls[1])
        do {
            _ = try await pool.performApproved(calls[0], fingerprint: second.fingerprint)
            XCTFail("Approval for one step cannot authorize another")
        } catch { XCTAssertEqual(error as? MCPClientError, .approvalMismatch) }
        _ = try await pool.performApproved(calls[0], fingerprint: first.fingerprint)
        _ = try await pool.performApproved(calls[1], fingerprint: second.fingerprint)
        let original = try XCTUnwrap(factory.createdSessions().last)
        let originalExecutions = await original.executionCount()
        XCTAssertEqual(originalExecutions, 2, "Identical requested effects in distinct steps must not share one mutation receipt")
        await pool.cancelAll()
        let restoredLedger = MCPFileMutationCallLedger(fileURL: url)
        for call in calls {
            guard case .completed = try await restoredLedger.claim(call) else {
                return XCTFail("Each step needs its own durable result after ledger reconstruction")
            }
        }
        _ = try await pool.start(binaryURL: fakeBinaryURL)
        let refreshed = try await pool.allowedTools(), newTool = try XCTUnwrap(refreshed.first)
        for id in ids {
            let call = try newTool.makeCall(taskID: "two-approved-steps", arguments: [:], stepEffectID: id)
            let prepared = try await pool.prepareApproval(call)
            _ = try await pool.performApproved(call, fingerprint: prepared.fingerprint)
        }
        let latest = try XCTUnwrap(factory.createdSessions().last)
        let replayExecutions = await latest.executionCount()
        XCTAssertEqual(replayExecutions, 0, "A generation change must not replay either completed step")
        await pool.cancelAll()
    }

    @MainActor
    func testPoolValidationCannotOutliveStopCancellationOrNewerStart() async throws {
        try await assertStartupInvalidation(at: .validation)
    }

    @MainActor
    func testPoolRetirementCannotPublishAfterStopCancellationOrNewerStart() async throws {
        try await assertStartupInvalidation(at: .retirement)
    }

    @MainActor
    func testPoolPrimaryStartupCannotLaunchEmbeddedAfterStopCancellationOrNewerStart() async throws {
        try await assertStartupInvalidation(at: .primary)
    }

    @MainActor
    func testPoolEmbeddedStartupCannotPublishAfterStopCancellationOrNewerStart() async throws {
        try await assertStartupInvalidation(at: .embedded)
    }

    @MainActor
    func testAlreadyCancelledPoolStartDoesNotValidateOrReplaceHealthySession() async throws {
        let validator = StagedMCPBinaryValidator()
        let factory = FakeMCPSessionFactory(toolNames: ["focused_app"])
        let pool = MCPClientPool(binaryValidator: validator, mutationLedger: nil,
            sessionFactory: { factory.make(binary: $0, generation: $1) }, embeddedSessionFactory: { _ in nil })
        let healthy = try await pool.start(binaryURL: fakeBinaryURL)
        let request = Task { try await pool.start(binaryURL: fakeBinaryURL) }
        request.cancel()
        do { _ = try await request.value; XCTFail("A pre-cancelled request cannot begin validation") }
        catch is CancellationError { }
        let validations = await validator.validationCount()
        let current = try await pool.allowedTools()
        let stops = await factory.latestSession()?.stopCount()
        XCTAssertEqual(validations, 1)
        XCTAssertEqual(factory.createdSessions().count, 1)
        XCTAssertTrue(current.allSatisfy { $0.processGeneration == healthy.processGeneration })
        XCTAssertEqual(stops, 0)
        await pool.cancelAll()
    }

    func testPoolRejectsMismatchedPrimaryBeforeStartingEmbeddedServer() async throws {
        let primary = FakeMCPSessionFactory(toolNames: ["focused_app"], advertisedServerID: "unexpected-server")
        let embedded = FakeMCPSessionFactory(toolNames: [RemoteDesktopMailMCP.toolName], advertisedServerID: RemoteDesktopMailMCP.serverID)
        let binary = MCPValidatedBinary(definition: MCPServerRegistry.macControl, appBundleURL: fakeBinaryURL.deletingLastPathComponent(), executableURL: fakeBinaryURL)
        let pool = MCPClientPool(binaryValidator: AcceptingMCPBinaryValidator(), mutationLedger: nil,
            sessionFactory: { primary.make(binary: $0, generation: $1) },
            embeddedSessionFactory: { embedded.make(binary: binary, generation: $0) })
        do { _ = try await pool.start(binaryURL: fakeBinaryURL); XCTFail("An invalid primary identity cannot activate embedded capabilities") }
        catch { XCTAssertEqual(error as? MCPClientError, .cancelled) }
        let embeddedStarts = await embedded.latestSession()?.startCount()
        let primaryStops = await primary.latestSession()?.stopCount()
        let embeddedStops = await embedded.latestSession()?.stopCount()
        XCTAssertEqual(embeddedStarts, 0)
        XCTAssertEqual(primaryStops, 1)
        XCTAssertEqual(embeddedStops, 1)
        do { _ = try await pool.allowedTools(); XCTFail("A failed startup cannot publish tools") }
        catch { XCTAssertEqual(error as? MCPClientError, .notRunning) }
    }

    @MainActor
    func testFailedReplacementValidationCannotLeaveObsoleteCandidateInPoolSlots() async throws {
        let gate = ComputerUsePlanningTestGate<Void>(started: expectation(description: "obsolete primary started"),
                                                    returned: expectation(description: "obsolete primary returned"))
        defer { gate.finish(()) }
        let primary = FakeMCPSessionFactory(toolNames: ["focused_app"], startGates: [1: gate])
        let validator = StagedMCPBinaryValidator(rejectedCalls: [2])
        let pool = MCPClientPool(binaryValidator: validator, mutationLedger: nil,
            sessionFactory: { primary.make(binary: $0, generation: $1) }, embeddedSessionFactory: { _ in nil })
        let obsolete = Task { try await pool.start(binaryURL: fakeBinaryURL) }
        await fulfillment(of: [gate.started], timeout: 1)
        do { _ = try await pool.start(binaryURL: fakeBinaryURL); XCTFail("The replacement fixture must fail validation") }
        catch { XCTAssertEqual(error as? MCPClientError, .serverMismatch("Fixture validation rejected")) }
        gate.finish(())
        do { _ = try await obsolete.value; XCTFail("Failed replacement validation cannot revive the superseded attempt") }
        catch { XCTAssertEqual(error as? MCPClientError, .cancelled) }
        await fulfillment(of: [gate.returned], timeout: 1)
        let stale = try XCTUnwrap(primary.createdSessions().first)
        let stopsBeforeRetry = await stale.stopCount()
        XCTAssertEqual(stopsBeforeRetry, 1)
        let healthy = try await pool.start(binaryURL: fakeBinaryURL)
        let stopsAfterRetry = await stale.stopCount()
        XCTAssertEqual(stopsAfterRetry, 1, "A retired failed candidate must not remain in the pool for the next start to stop again")
        let current = try await pool.allowedTools()
        XCTAssertEqual(current.map(\.processGeneration), [healthy.processGeneration])
        await pool.cancelAll()
    }

    private enum StartupStage { case validation, retirement, primary, embedded }

    @MainActor
    private func assertStartupInvalidation(at stage: StartupStage) async throws {
        for interruption in ["task cancellation", "Stop", "newer start"] {
            let gate = ComputerUsePlanningTestGate<Void>(started: expectation(description: "\(stage) entered before \(interruption)"),
                                                        returned: expectation(description: "\(stage) returned after \(interruption)"))
            defer { gate.finish(()) }
            let validator = StagedMCPBinaryValidator(firstValidationGate: stage == .validation ? gate : nil)
            let primary = FakeMCPSessionFactory(toolNames: ["focused_app"],
                startGates: stage == .primary ? [1: gate] : [:], stopGates: stage == .retirement ? [1: gate] : [:])
            let embedded = FakeMCPSessionFactory(toolNames: [RemoteDesktopMailMCP.toolName],
                advertisedServerID: RemoteDesktopMailMCP.serverID, startGates: stage == .embedded ? [1: gate] : [:])
            let binary = MCPValidatedBinary(definition: MCPServerRegistry.macControl,
                appBundleURL: fakeBinaryURL.deletingLastPathComponent(), executableURL: fakeBinaryURL)
            let pool = MCPClientPool(binaryValidator: validator, mutationLedger: nil,
                sessionFactory: { primary.make(binary: $0, generation: $1) },
                embeddedSessionFactory: { embedded.make(binary: binary, generation: $0) })
            if stage == .retirement { _ = try await pool.start(binaryURL: fakeBinaryURL) }
            let obsolete = Task { try await pool.start(binaryURL: fakeBinaryURL) }
            await fulfillment(of: [gate.started], timeout: 1)
            var replacement: MCPProcessIdentity?
            switch interruption {
            case "task cancellation": obsolete.cancel()
            case "Stop": await pool.cancelAll()
            default: replacement = try await pool.start(binaryURL: fakeBinaryURL)
            }
            gate.finish(())
            do { _ = try await obsolete.value; XCTFail("An obsolete \(stage) cannot publish readiness after \(interruption)") }
            catch is CancellationError { }
            catch { XCTAssertEqual(error as? MCPClientError, .cancelled) }
            await fulfillment(of: [gate.returned], timeout: 1)
            let expectedCount = (stage == .validation ? 0 : 1) + (replacement == nil ? 0 : 1)
            XCTAssertEqual(primary.createdSessions().count, expectedCount, "No obsolete candidate may be created after validation or retirement")
            XCTAssertEqual(embedded.createdSessions().count, expectedCount)
            if stage == .primary {
                let staleEmbedded = try XCTUnwrap(embedded.createdSessions().first)
                let starts = await staleEmbedded.startCount()
                XCTAssertEqual(starts, 0, "A stopped or superseded primary must not start the next capability")
            }
            if let replacement {
                let current = try await pool.allowedTools()
                XCTAssertEqual(current.count, 2)
                XCTAssertTrue(current.allSatisfy { $0.processGeneration == replacement.processGeneration })
                let primaryStops = await primary.latestSession()?.stopCount()
                let embeddedStops = await embedded.latestSession()?.stopCount()
                XCTAssertEqual(primaryStops, 0, "Late cleanup must retain the replacement's primary session")
                XCTAssertEqual(embeddedStops, 0, "Late cleanup must retain the replacement's embedded session")
            } else {
                do { _ = try await pool.allowedTools(); XCTFail("Cancelled startup cannot expose tools") }
                catch { XCTAssertEqual(error as? MCPClientError, .notRunning) }
            }
            await pool.cancelAll()
        }
    }

    func testCanonicalCallDigestIsStableAcrossDictionaryOrderAndProcessRestart() throws {
        let firstTool = try allowedTool(
            name: "set_element_attribute",
            generation: 10,
            schema: objectSchema(
                properties: [
                    "attribute": .object(["type": .string("string")]),
                    "value": .object(["type": .string("string")]),
                ],
                required: ["attribute", "value"]))
        let secondTool = try allowedTool(
            name: "set_element_attribute",
            generation: 11,
            schema: firstTool.inputSchema)

        let first = try firstTool.makeCall(
            taskID: "task-1",
            arguments: [
                "attribute": .string("AXValue"),
                "value": .string("fixture value"),
            ])
        let reordered = try secondTool.makeCall(
            taskID: "task-1",
            arguments: [
                "value": .string("fixture value"),
                "attribute": .string("AXValue"),
            ])

        XCTAssertEqual(first.canonicalArguments, reordered.canonicalArguments)
        XCTAssertEqual(first.argumentsDigest, reordered.argumentsDigest)
        XCTAssertEqual(first.canonicalDigest, reordered.canonicalDigest)
        XCTAssertNotEqual(first.processGeneration, reordered.processGeneration)

        let anotherTask = try firstTool.makeCall(
            taskID: "task-2",
            arguments: first.arguments)
        XCTAssertNotEqual(first.canonicalDigest, anotherTask.canonicalDigest)
    }

    func testSafetySetsAreDisjointAndUnknownOrDangerousToolsAreBlocked() {
        XCTAssertTrue(MCPToolSafetyPolicy.readOnlyTools
            .intersection(MCPToolSafetyPolicy.reversibleTools).isEmpty)
        XCTAssertTrue(MCPToolSafetyPolicy.readOnlyTools
            .intersection(MCPToolSafetyPolicy.approvalRequiredTools).isEmpty)
        XCTAssertTrue(MCPToolSafetyPolicy.reversibleTools
            .intersection(MCPToolSafetyPolicy.approvalRequiredTools).isEmpty)

        for name in [
            "browser_close_tab", "browser_eval_js", "browser_get_active_tab",
            "browser_list_tabs", "browser_navigate", "browser_new_tab",
            "clipboard_read", "foundation_models_generate", "imessage_send",
            "mail_send", "open_url_scheme", "system_shutdown", "trash_file",
        ] {
            XCTAssertTrue(MCPToolSafetyPolicy.explicitlyBlockedTools.contains(name))
            XCTAssertEqual(MCPToolSafetyPolicy.risk(for: name), .blocked)
            XCTAssertFalse(MCPToolSafetyPolicy.isAllowed(name))
        }
        XCTAssertEqual(MCPToolSafetyPolicy.risk(for: "future_unreviewed_tool"), .blocked)
    }

    func testRealStdioAcceptanceGateDefinesTheExactExposedAndPlannerSurfaces() {
        let expectedExposed: Set<String> = [
            "ax_snapshot_capture", "ax_snapshot_diff", "ax_tree_augmented",
            "click", "click_menu_path", "contacts_search", "find_element",
            "find_elements", "focus_window",
            "focused_app", "get_element_attributes", "get_ui_tree", "list_apps",
            "list_elements", "list_menu_titles", "list_shortcuts", "list_windows",
            "perform_element_action", "permissions_status", "press_key",
            "probe_ax_tree", "query_elements", "read_value", "reminders_list",
            RemoteDesktopMailMCP.toolName, "set_element_attribute", "type_text",
            "wait_for_ax_notification",
            "wait_for_element", "wait_for_window_state_change",
        ]
        XCTAssertEqual(MCPToolSafetyPolicy.allowedTools, expectedExposed)

        let acceptanceBlocked: Set<String> = [
            "browser_close_tab", "browser_dom_tree", "browser_get_active_tab",
            "browser_iframes", "browser_list_tabs", "browser_navigate",
            "browser_new_tab", "browser_visible_text", "calendar_create_event",
            "calendar_list_events", "reminders_create", "run_shortcut",
            "scroll_to_element",
        ]
        XCTAssertEqual(
            Set(MCPToolSafetyPolicy.acceptanceBlockedToolReasons.keys),
            acceptanceBlocked)
        XCTAssertTrue(acceptanceBlocked.isSubset(
            of: MCPToolSafetyPolicy.explicitlyBlockedTools))
        XCTAssertTrue(MCPToolSafetyPolicy.acceptanceBlockedToolReasons.values
            .allSatisfy { !$0.isEmpty })
        for tool in acceptanceBlocked {
            XCTAssertEqual(MCPToolSafetyPolicy.risk(for: tool), .blocked)
            XCTAssertFalse(MCPToolSafetyPolicy.isAllowed(tool))
        }

        let expectedPlannerTools: Set<String> = [
            "contacts_search", "focused_app", "list_apps", "list_shortcuts",
            "list_windows", "permissions_status", RemoteDesktopMailMCP.toolName,
            "reminders_list",
        ]
        XCTAssertEqual(
            MCPFirstComputerUseExecutor.structuredToolNames,
            expectedPlannerTools)
        XCTAssertTrue(MCPFirstComputerUseExecutor.structuredToolNames
            .isSubset(of: expectedExposed))
    }

    func testDynamicApprovalCopyDoesNotRevealTypedTextOrEmailBody() throws {
        let typeTool = try allowedTool(
            name: "type_text",
            schema: objectSchema(
                properties: ["text": .object(["type": .string("string")])],
                required: ["text"]))
        let secret = "the user's private password"
        let typeCall = try typeTool.makeCall(
            taskID: "typing",
            arguments: ["text": .string(secret)])
        XCTAssertTrue(typeCall.approvalDetails.contains("\(secret.count) characters"))
        XCTAssertFalse(typeCall.approvalDetails.contains(secret))

        let mailTool = try allowedTool(
            name: RemoteDesktopMailMCP.toolName,
            schema: objectSchema(
                properties: [
                    "to": .object(["type": .string("string")]),
                    "subject": .object(["type": .string("string")]),
                    "body": .object(["type": .string("string")]),
                    "send_now": .object(["type": .string("boolean")]),
                ],
                required: ["to", "subject", "body", "send_now"]))
        let body = "private medical details"
        let mailCall = try mailTool.makeCall(
            taskID: "mail",
            arguments: [
                "to": .string("person@example.com"),
                "subject": .string("Hello"),
                "body": .string(body),
                "send_now": .bool(true),
            ])
        XCTAssertEqual(mailCall.approvalConfirmLabel, "Send email")
        XCTAssertTrue(mailCall.approvalDetails.contains("person@example.com"))
        XCTAssertTrue(mailCall.approvalDetails.contains("Hello"))
        XCTAssertFalse(mailCall.approvalDetails.contains(body))
    }

    func testRegistryPinsOneExpectedServerAndRejectsWrongLayoutBeforeLaunch() throws {
        XCTAssertEqual(MCPServerRegistry.curatedServers, [MCPServerRegistry.macControl])
        let definition = MCPServerRegistry.macControl
        XCTAssertEqual(definition.expectedServerVersion, "0.8.2")
        XCTAssertEqual(
            definition.executableSHA256,
            "402729cbf8179783466f4ba2ca1d1a2bf8ffb19cd7dee330963392afae9f4302")
        XCTAssertEqual(definition.bundleIdentifier, "dev.macmcp.server")
        XCTAssertEqual(definition.teamIdentifier, "A3W973JZ49")
        XCTAssertEqual(definition.expectedProtocolVersion, "2024-11-05")

        let wrongURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-the-pinned-helper")
        XCTAssertThrowsError(try SystemMCPServerBinaryValidator.validateStructure(
            binaryURL: wrongURL,
            definition: definition)) { error in
            guard case MCPClientError.invalidBinary = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPaginationCollectsEveryPageAndRejectsCursorLoops() async throws {
        let values = try await MCPToolPagination.collect { cursor in
            switch cursor {
            case nil: return ([1, 2], "next")
            case "next": return ([3], nil)
            default: return ([], nil)
            }
        }
        XCTAssertEqual(values, [1, 2, 3])

        do {
            _ = try await MCPToolPagination.collect { _ in ([1], "same") }
            XCTFail("Expected a pagination loop failure")
        } catch let error as MCPClientError {
            XCTAssertEqual(error, .paginationLoop)
        }
    }

    func testSchemaValidationRequiresKnownTypedFields() throws {
        let schema = objectSchema(
            properties: [
                "name": .object([
                    "type": .string("string"),
                    "enum": .array([.string("one"), .string("two")]),
                ]),
                "count": .object([
                    "type": .array([.string("integer"), .string("string")]),
                ]),
            ],
            required: ["name"])

        XCTAssertNoThrow(try MCPJSONSchemaValidator.validate(
            arguments: ["name": .string("one"), "count": .integer(2)],
            against: schema))
        XCTAssertThrowsError(try MCPJSONSchemaValidator.validate(
            arguments: ["count": .integer(2)],
            against: schema))
        XCTAssertThrowsError(try MCPJSONSchemaValidator.validate(
            arguments: ["name": .string("three")],
            against: schema))
        XCTAssertThrowsError(try MCPJSONSchemaValidator.validate(
            arguments: ["name": .string("one"), "surprise": .bool(true)],
            against: schema))
    }

    func testAmbientBrowserToolsCannotConstructCalls() throws {
        for name in [
            "browser_close_tab", "browser_get_active_tab", "browser_list_tabs",
            "browser_navigate", "browser_new_tab",
        ] {
            let tool = try allowedTool(name: name)
            XCTAssertThrowsError(try tool.makeCall(
                taskID: "blocked-browser",
                arguments: [:])) { error in
                    XCTAssertEqual(error as? MCPClientError, .toolNotAllowed(name))
                }
        }
    }

    func testOutputSanitizerRedactsPrivateInputsAndEnforcesByteCaps() throws {
        let tool = try allowedTool(
            name: "type_text",
            schema: objectSchema(
                properties: ["text": .object(["type": .string("string")])],
                required: ["text"]))
        let privateText = "correct horse battery staple"
        let call = try tool.makeCall(
            taskID: "private-output",
            arguments: ["text": .string(privateText)])

        let text = MCPToolOutputSanitizer.sanitizeText(
            "echoed \(privateText) " + String(
                repeating: "x",
                count: MCPToolOutputSanitizer.maximumTextBytes * 2),
            call: call)
        XCTAssertTrue(text.wasTruncated)
        XCTAssertFalse(text.text.contains(privateText))
        XCTAssertLessThanOrEqual(
            text.text.utf8.count,
            MCPToolOutputSanitizer.maximumTextBytes)

        let structured = try MCPToolOutputSanitizer.sanitizeStructured(
            .object([
                "text": .string(privateText),
                "access_token": .string("secret-token"),
            ]),
            call: call)
        XCTAssertEqual(structured.value, .object([
            "text": .string("[redacted]"),
            "access_token": .string("[redacted]"),
        ]))
    }

    func testPoolRequiresExactApprovalFingerprintAndConsumesItOnce() async throws {
        let temporary = temporaryURL("approval-ledger.json")
        let factory = FakeMCPSessionFactory(toolNames: ["press_key"])
        let pool = MCPClientPool(
            binaryValidator: AcceptingMCPBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(fileURL: temporary),
            sessionFactory: { factory.make(binary: $0, generation: $1) },
            embeddedSessionFactory: { _ in nil })
        _ = try await pool.start(binaryURL: fakeBinaryURL)
        let tools = try await pool.allowedTools()
        let tool = try XCTUnwrap(tools.first)
        let call = try tool.makeCall(
            taskID: "approved-key-press",
            arguments: [:])

        do {
            _ = try await pool.execute(call)
            XCTFail("Expected approval requirement")
        } catch let error as MCPClientError {
            guard case .approvalRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let prepared = try await pool.prepareApproval(call)
        var wrong = prepared.fingerprint
        wrong = MCPApprovalFingerprint(call: try tool.makeCall(
            taskID: "different-task",
            arguments: call.arguments))
        do {
            _ = try await pool.performApproved(call, fingerprint: wrong)
            XCTFail("Expected fingerprint mismatch")
        } catch let error as MCPClientError {
            XCTAssertEqual(error, .approvalMismatch)
        }

        let result = try await pool.performApproved(
            call,
            fingerprint: prepared.fingerprint)
        XCTAssertEqual(result.text, "ok")
        let approvedExecutionCount = await factory.latestSession()?.executionCount()
        XCTAssertEqual(approvedExecutionCount, 1)

        do {
            _ = try await pool.performApproved(call, fingerprint: prepared.fingerprint)
            XCTFail("Expected consumed approval")
        } catch let error as MCPClientError {
            XCTAssertEqual(error, .approvalMismatch)
        }
    }

    func testCompletedMutationIsReturnedFromLedgerWithoutRetry() async throws {
        let factory = FakeMCPSessionFactory(toolNames: ["focus_window"])
        let pool = MCPClientPool(
            binaryValidator: AcceptingMCPBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(
                fileURL: temporaryURL("completed-ledger.json")),
            sessionFactory: { factory.make(binary: $0, generation: $1) },
            embeddedSessionFactory: { _ in nil })
        _ = try await pool.start(binaryURL: fakeBinaryURL)
        let tools = try await pool.allowedTools()
        let tool = try XCTUnwrap(tools.first)
        let call = try tool.makeCall(
            taskID: "focus-once",
            arguments: [:])

        let first = try await pool.execute(call)
        let second = try await pool.execute(call)
        XCTAssertEqual(first, second)
        let executionCount = await factory.latestSession()?.executionCount()
        XCTAssertEqual(executionCount, 1)
    }

    func testInterruptedMutationIsAmbiguousAfterLedgerRelaunch() async throws {
        let fileURL = temporaryURL("ambiguous-ledger.json")
        let call = try allowedTool(
            name: "focus_window")
            .makeCall(
                taskID: "interrupted",
                arguments: [:])

        let firstLedger = MCPFileMutationCallLedger(fileURL: fileURL)
        let firstClaim = try await firstLedger.claim(call)
        XCTAssertEqual(firstClaim, .new)

        let relaunchedLedger = MCPFileMutationCallLedger(fileURL: fileURL)
        let relaunchedClaim = try await relaunchedLedger.claim(call)
        XCTAssertEqual(relaunchedClaim, .ambiguous)
    }

    func testMutationLedgerFreshAtomicCreationIsOwnerOnly() async throws {
        let fileURL = temporaryURL("fresh-permissions-ledger.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let ledger = MCPFileMutationCallLedger(fileURL: fileURL)

        let claim = try await ledger.claim(mutationCall(taskID: "fresh"))
        XCTAssertEqual(claim, .new)

        XCTAssertEqual(try posixPermissions(at: fileURL), 0o600)
    }

    func testMutationLedgerAtomicReplacementRepairsPermissiveFile() async throws {
        let fileURL = temporaryURL("replacement-permissions-ledger.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let ledger = MCPFileMutationCallLedger(fileURL: fileURL)
        let call = try mutationCall(taskID: "replacement")
        let claim = try await ledger.claim(call)
        XCTAssertEqual(claim, .new)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fileURL.path)

        let result = try MCPToolResult(
            text: "completed",
            structuredContent: nil,
            isError: false,
            wasTruncated: false)
        try await ledger.complete(call, result: result)

        XCTAssertEqual(try posixPermissions(at: fileURL), 0o600)
    }

    func testMutationLedgerInitializationRepairsExistingPermissiveFile() async throws {
        let fileURL = temporaryURL("existing-permissions-ledger.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let firstLedger = MCPFileMutationCallLedger(fileURL: fileURL)
        let claim = try await firstLedger.claim(mutationCall(taskID: "existing"))
        XCTAssertEqual(claim, .new)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fileURL.path)
        XCTAssertEqual(try posixPermissions(at: fileURL), 0o644)

        _ = MCPFileMutationCallLedger(fileURL: fileURL)

        XCTAssertEqual(try posixPermissions(at: fileURL), 0o600)
    }

    func testCancellingReadStopsTheOwnedSidecar() async throws {
        let factory = FakeMCPSessionFactory(
            toolNames: ["focused_app"],
            behavior: .suspend)
        let pool = MCPClientPool(
            binaryValidator: AcceptingMCPBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(
                fileURL: temporaryURL("cancel-ledger.json")),
            sessionFactory: { factory.make(binary: $0, generation: $1) },
            embeddedSessionFactory: { _ in nil })
        _ = try await pool.start(binaryURL: fakeBinaryURL)
        let tools = try await pool.allowedTools()
        let tool = try XCTUnwrap(tools.first)
        let call = try tool.makeCall(taskID: "cancel-read", arguments: [:])
        let session = try XCTUnwrap(factory.latestSession())

        let operation = Task { try await pool.execute(call) }
        await session.waitForExecution()
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("Expected cancellation")
        } catch let error as MCPClientError {
            XCTAssertEqual(error, .cancelled)
        }
        let stopCount = await factory.latestSession()?.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testStaleCancelledReadCannotStopNewerSidecarGeneration() async throws {
        let factory = FakeMCPSessionFactory(
            toolNames: ["focused_app"],
            behavior: .suspend)
        let pool = MCPClientPool(
            binaryValidator: AcceptingMCPBinaryValidator(),
            mutationLedger: MCPFileMutationCallLedger(
                fileURL: temporaryURL("stale-cancel-ledger.json")),
            sessionFactory: { factory.make(binary: $0, generation: $1) },
            embeddedSessionFactory: { _ in nil })
        let firstIdentity = try await pool.start(binaryURL: fakeBinaryURL)
        let firstTools = try await pool.allowedTools()
        let firstTool = try XCTUnwrap(firstTools.first)
        let firstCall = try firstTool.makeCall(taskID: "old-read", arguments: [:])
        let firstSession = try XCTUnwrap(factory.latestSession())
        let oldOperation = Task { try await pool.execute(firstCall) }
        await firstSession.waitForExecution()

        let secondIdentity = try await pool.start(binaryURL: fakeBinaryURL)
        XCTAssertGreaterThan(
            secondIdentity.processGeneration,
            firstIdentity.processGeneration)
        oldOperation.cancel()
        do {
            _ = try await oldOperation.value
            XCTFail("Expected the old read to cancel")
        } catch let error as MCPClientError {
            XCTAssertEqual(error, .cancelled)
        }

        let currentTools = try await pool.allowedTools()
        XCTAssertFalse(currentTools.isEmpty)
        let newSessionStopCount = await factory.latestSession()?.stopCount()
        XCTAssertEqual(
            newSessionStopCount,
            0,
            "Cleanup from generation 1 must not stop generation 2")
        await pool.cancelAll()
    }

    private var fakeBinaryURL: URL {
        URL(fileURLWithPath: "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP")
    }

    private func allowedTool(
        name: String,
        generation: UInt64 = 1,
        schema: MCPJSONValue = .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])
    ) throws -> MCPAllowedTool {
        let assessment = MCPToolSafetyPolicy.assess(toolName: name)
        return try MCPAllowedTool(
            serverID: MCPServerRegistry.macControl.serverID,
            processGeneration: generation,
            toolName: name,
            description: "Test tool",
            inputSchema: schema,
            risk: assessment.risk,
            approval: assessment.approval)
    }

    private func objectSchema(
        properties: [String: MCPJSONValue],
        required: [String] = []
    ) -> MCPJSONValue {
        var schema: [String: MCPJSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map(MCPJSONValue.string))
        }
        return .object(schema)
    }

    private func mutationCall(taskID: String) throws -> MCPToolCall {
        try allowedTool(
            name: "focus_window")
            .makeCall(
                taskID: taskID,
                arguments: [:])
    }

    private func posixPermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPFoundationTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }
}

private struct AcceptingMCPBinaryValidator: MCPServerBinaryValidating {
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

private actor StagedMCPBinaryValidator: MCPServerBinaryValidating {
    private var firstValidationGate: ComputerUsePlanningTestGate<Void>?
    private let rejectedCalls: Set<Int>
    private var calls = 0

    init(firstValidationGate: ComputerUsePlanningTestGate<Void>? = nil, rejectedCalls: Set<Int> = []) {
        self.firstValidationGate = firstValidationGate
        self.rejectedCalls = rejectedCalls
    }

    func validate(binaryURL: URL, definition: MCPServerDefinition) async throws -> MCPValidatedBinary {
        calls += 1
        if rejectedCalls.contains(calls) { throw MCPClientError.serverMismatch("Fixture validation rejected") }
        if let gate = firstValidationGate {
            firstValidationGate = nil
            await gate.wait()
        }
        return try await AcceptingMCPBinaryValidator().validate(binaryURL: binaryURL, definition: definition)
    }

    func validationCount() -> Int { calls }
}

private final class FakeMCPSessionFactory: @unchecked Sendable {
    enum Behavior: Sendable {
        case succeed
        case suspend
    }

    private let lock = NSLock()
    private let toolNames: [String]
    private let behavior: Behavior
    private let advertisedServerID: String?
    private let startGates: [UInt64: ComputerUsePlanningTestGate<Void>]
    private let stopGates: [UInt64: ComputerUsePlanningTestGate<Void>]
    private var sessions: [FakeMCPSession] = []

    init(toolNames: [String], behavior: Behavior = .succeed, advertisedServerID: String? = nil,
         startGates: [UInt64: ComputerUsePlanningTestGate<Void>] = [:],
         stopGates: [UInt64: ComputerUsePlanningTestGate<Void>] = [:]) {
        self.toolNames = toolNames
        self.behavior = behavior
        self.advertisedServerID = advertisedServerID
        self.startGates = startGates
        self.stopGates = stopGates
    }

    func make(
        binary: MCPValidatedBinary,
        generation: UInt64
    ) -> any MCPClientSessioning {
        let session = FakeMCPSession(
            binary: binary,
            generation: generation,
            toolNames: toolNames,
            behavior: behavior,
            advertisedServerID: advertisedServerID,
            startGate: startGates[generation], stopGate: stopGates[generation])
        lock.lock()
        sessions.append(session)
        lock.unlock()
        return session
    }

    func latestSession() -> FakeMCPSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions.last
    }

    func createdSessions() -> [FakeMCPSession] { lock.withLock { sessions } }
}

private actor FakeMCPSession: MCPClientSessioning {
    private let binary: MCPValidatedBinary
    private let generation: UInt64
    private let toolNames: [String]
    private let behavior: FakeMCPSessionFactory.Behavior
    private let advertisedServerID: String
    private var startGate: ComputerUsePlanningTestGate<Void>?
    private var stopGate: ComputerUsePlanningTestGate<Void>?
    private var starts = 0
    private var executions = 0
    private var stops = 0
    private var executionWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        binary: MCPValidatedBinary,
        generation: UInt64,
        toolNames: [String],
        behavior: FakeMCPSessionFactory.Behavior,
        advertisedServerID: String? = nil,
        startGate: ComputerUsePlanningTestGate<Void>? = nil,
        stopGate: ComputerUsePlanningTestGate<Void>? = nil
    ) {
        self.binary = binary
        self.generation = generation
        self.toolNames = toolNames
        self.behavior = behavior
        self.advertisedServerID = advertisedServerID ?? binary.definition.serverID
        self.startGate = startGate
        self.stopGate = stopGate
    }

    func start() async throws -> MCPProcessIdentity {
        starts += 1
        if let gate = startGate {
            startGate = nil
            await gate.wait()
        }
        return MCPProcessIdentity(
            serverID: advertisedServerID,
            processGeneration: generation,
            processIdentifier: 42,
            binaryPath: binary.executableURL.path,
            launchedAt: Date())
    }

    func listAllowedTools() async throws -> [MCPAllowedTool] {
        try toolNames.map { name in
            let assessment = MCPToolSafetyPolicy.assess(toolName: name)
            return try MCPAllowedTool(
                serverID: advertisedServerID,
                processGeneration: generation,
                toolName: name,
                description: "Fake \(name)",
                inputSchema: Self.schema(for: name),
                risk: assessment.risk,
                approval: assessment.approval)
        }
    }

    func execute(_ call: MCPToolCall) async throws -> MCPToolResult {
        executions += 1
        let pendingExecutionWaiters = executionWaiters
        executionWaiters.removeAll()
        pendingExecutionWaiters.forEach { $0.resume() }
        switch behavior {
        case .succeed:
            return try MCPToolResult(
                text: "ok",
                structuredContent: nil,
                isError: false,
                wasTruncated: false)
        case .suspend:
            try await Task.sleep(for: .seconds(30))
            return try MCPToolResult(
                text: "unexpected",
                structuredContent: nil,
                isError: false,
                wasTruncated: false)
        }
    }

    func stop() async {
        stops += 1
        if let gate = stopGate {
            stopGate = nil
            await gate.wait()
        }
    }

    func startCount() -> Int { starts }
    func executionCount() -> Int { executions }
    func stopCount() -> Int { stops }

    func waitForExecution() async {
        if executions > 0 { return }
        await withCheckedContinuation { continuation in
            executionWaiters.append(continuation)
        }
    }

    private static func schema(for name: String) -> MCPJSONValue {
        let fields: [String: MCPJSONValue]
        let required: [String]
        switch name {
        case RemoteDesktopMailMCP.toolName:
            fields = [
                "to": .object(["type": .string("string")]),
                "subject": .object(["type": .string("string")]),
                "body": .object(["type": .string("string")]),
                "cc": .object(["type": .string("string")]),
                "bcc": .object(["type": .string("string")]),
                "send_now": .object(["type": .string("boolean")]),
            ]
            required = ["to", "subject", "body", "send_now"]
        default:
            fields = [:]
            required = []
        }

        var schema: [String: MCPJSONValue] = [
            "type": .string("object"),
            "properties": .object(fields),
            "additionalProperties": .bool(false),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map(MCPJSONValue.string))
        }
        return .object(schema)
    }
}

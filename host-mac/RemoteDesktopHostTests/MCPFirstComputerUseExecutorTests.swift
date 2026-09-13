import XCTest
import AppKit
import CryptoKit
@testable import RemoteDesktopHost

@MainActor
final class MCPFirstComputerUseExecutorTests: XCTestCase {
    func testOptInFaraQuestionsContinueThroughCapabilityMCPAndDeferredLayers() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_NATIVE_BROWSER_INPUT"] == "1" else { throw XCTSkip("Opt-in: all Fara question executor layers") }
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraMCPQuestion-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
        var calls = 0, admissions = 0, loads = 0
        let original = "Find concert tickets."
        let fara = try ComputerUseFaraBrowserExecutor(journalDirectory: directory.appendingPathComponent("fara"), propose: { input in
            XCTAssertEqual(input.goal, original); XCTAssertEqual(input.history.count, calls)
            guard calls < 2 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
            if calls == 1 { XCTAssertEqual(input.userResponse, "Kyoto") }
            let question = calls == 0 ? "Which city?" : "Which date?"
            calls += 1
            let response = "<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"ask_user_question\",\"question\":\"\(question)\"}}</tool_call>"
            return try .init(response: response, action: ComputerUseFaraAction.decodeNativeMessage(response))
        })
        let deferred = ComputerUseDeferredVisualExecutor(loader: { _ in loads += 1; return fara })
        let planner = StubMCPPlanner(mode: .repeatFocusedApp)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let mcp = try await MCPFirstComputerUseExecutor.load(binaryURL: URL(fileURLWithPath: "/test/helper"), visualFallback: deferred, planner: planner, clientPool: pool)
        let capability = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in admissions += 1; return nil }, desktopFactory: { _ in mcp })
        let first = try await capability.execute(taskID: "root", prompt: original, trustedUserPrompt: original, tools: tools, progress: { _ in })
        XCTAssertEqual(first, .clarificationRequired("Which city?"))
        let pending = try XCTUnwrap(capability.clarification(taskID: "root"))
        let goal = try pending.goal.answering(pending.question, with: "Kyoto")
        let second = try await capability.continueClarification(taskID: "answer", originatingTaskID: "root", goal: goal, progress: { _ in })
        XCTAssertEqual(second, .clarificationRequired("Which date?"))
        XCTAssertEqual(try capability.clarification(taskID: "answer")?.goal, goal)
        XCTAssertEqual(planner.proposedToolNames.count, 1); XCTAssertEqual(admissions, 1); XCTAssertEqual(loads, 1); XCTAssertEqual(calls, 2)
        capability.invalidateClarification(taskID: "answer")
        XCTAssertNil(try capability.clarification(taskID: "answer"))
        await pool.cancelAll()
    }

    func testOptInProductionNativeLoaderRoutesBrowserTaskThroughMacToolsToFara() async throws {
        try await runProductionBrowserComposition(reusesPriorTaskPage: false)
    }

    func testOptInProductionNativeLoaderStartsNewBrowserTaskOnPriorTasksPage() async throws {
        try await runProductionBrowserComposition(reusesPriorTaskPage: true)
    }

    func testOptInProductionNativeLoaderUsesActualMacHelperAndDefaultPlannerFromEmptyBrowser() async throws {
        try await runProductionBrowserComposition(reusesPriorTaskPage: false, usesActualMacTools: true)
    }

    private func runProductionBrowserComposition(reusesPriorTaskPage: Bool, usesActualMacTools: Bool = false) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_FARA_SEARCH_MODEL_ACCEPTANCE"] == "1" else { throw XCTSkip("Opt-in: production native/Fara loaders and controlled browser task") }
        let nativeModel = URL(fileURLWithPath: try XCTUnwrap(environment["NATIVE_TEXT_MODEL_PATH"]))
        let file = try FileHandle(forReadingFrom: nativeModel)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty { hash.update(data: chunk) }
        XCTAssertEqual(hash.finalize().map { String(format: "%02x", $0) }.joined(), ComputerUseArtifactManifest.nativeTextV2.modelArtifacts[0].sha256)
        let faraInputs = try await FaraTestAssets.inputs(environment: environment)
        let previousPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let style = "<style>body{font:26px system-ui;margin:50px;background:white;color:#111}a{display:block;padding:24px;background:#eef4ff}</style>"
        let server = try OwnedBrowserHTTPFixture(routes: [
            "/results": .init(body: "<!doctype html>" + style + "<h1>Concert search results</h1><a href='/details'>Tokyo Music Hall concert details</a>"),
            "/details": .init(body: "<!doctype html>" + style + "<h1>Tokyo Music Hall</h1><p>Friday concert starts at 7 pm.</p><p>Ticket price: 2400 JPY.</p>")])
        let base = try await server.start(); defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaraDefaultComposition-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = ComputerUseOwnedBrowser(mayAct: { true }); defer { browser.close() }
        let taskID = "normal-browser-route"
        let browserTaskID = reusesPriorTaskPage ? "prior-browser-task" : taskID
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true },
            browserNavigationTask: .init(browser: browser, journalDirectory: directory.appendingPathComponent("browser")))
        let requirement = try browser.prepareWorkflowSession(taskID: browserTaskID)
        let policy = try ComputerUseBrowserSourcePolicy(goal: .init(taskID: browserTaskID, prompt: "Controlled local sources only", referenceDate: Date(), timeZoneIdentifier: "UTC"),
            allowedOrigins: [ComputerUseBrowserSourceOrigin(base)])
        try browser.installSourcePolicy(policy, replacing: nil, session: requirement)
        if !usesActualMacTools {
            _ = try await browser.navigate(taskID: browserTaskID, operationID: "fixture", to: base.appendingPathComponent("results"))
        }
        let runtime = OSAtlasLlamaRuntime()
        let planner = StubMCPPlanner(mode: .generationFailure)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let helperState = directory.appendingPathComponent("helper-state")
        let realPool = MCPClientPool(sessionFactory: { binary, generation in
            MCPClientSession(validatedBinary: binary, processGeneration: generation, stateDirectory: helperState)
        })
        var hybrid: MCPFirstComputerUseExecutor?
        var visualLoads = 0, result: ComputerUseExecutionResult?, failure: Error?
        var progressMessages: [String] = [], discoveredTools: [String] = []
        do {
            let native = try await ComputerUseNativeTextExecutorLoader.load(receipt: .init(
                installationVersion: ComputerUseArtifactManifest.nativeTextV2.installationVersion, modelVariant: .nativeText4B,
                modelDirectory: nativeModel.deletingLastPathComponent().path, installedAt: Date()), tools: tools, runtime: runtime,
                journalDirectory: directory.appendingPathComponent("text"), progress: { _ in })
            let loader = OSAtlasVisualExecutorLoader(runtime: runtime, faraJournalDirectory: directory.appendingPathComponent("fara"))
            let deferred = ComputerUseDeferredVisualExecutor(loader: { progress in
                visualLoads += 1
                return try await loader.load(receipt: .init(installationVersion: ComputerUseArtifactManifest.current.installationVersion,
                    modelVariant: .fara15_4B, modelDirectory: faraInputs.modelURL.deletingLastPathComponent().path, installedAt: Date()), progress: progress)
            }, abandon: { _ in await loader.deactivate() })
            native.setDesktopFactory { _ in
                let loaded: MCPFirstComputerUseExecutor
                if usesActualMacTools {
                    let helper = URL(fileURLWithPath: try XCTUnwrap(environment["MAC_CONTROL_HELPER_PATH"]))
                    loaded = try await MCPFirstComputerUseExecutor.load(binaryURL: helper,
                        visualFallback: deferred, clientPool: realPool)
                    discoveredTools = try await realPool.allowedTools().map(\.toolName).sorted()
                } else {
                    loaded = try await MCPFirstComputerUseExecutor.load(binaryURL: URL(fileURLWithPath: "/fixture/helper"),
                        visualFallback: deferred, planner: planner, clientPool: pool)
                }
                hybrid = loaded
                return loaded
            }
            let goal = (usesActualMacTools ? "Visit \(base.appendingPathComponent("results").absoluteString). " : "")
                + "Find the Tokyo Music Hall concert in these results. Open its details and report its ticket price, start time and source URL."
            // Reserve the legacy driver's slot to reject that route before it
            // can invoke Qwen research inference. The trained browser loop
            // must use its own retained action/session path.
            result = try await tools.withOwnedBrowserResearchAdmission(didPrepare: { _ in
                XCTFail("Default browsing must not use the legacy Qwen research driver")
            }, operation: {
                try await native.execute(taskID: taskID, prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { progressMessages.append($0) })
            })
        } catch { failure = error }
        hybrid?.cancelMCPWork()
        await realPool.cancelAll()
        await runtime.shutdown()
        XCTAssertTrue(try DarwinOSAtlasProcessInspector().matchingProcesses(for: faraInputs.llamaServerURL).isEmpty)
        if usesActualMacTools {
            let attachment = XCTAttachment(string: "Apple planner: \(AppleFoundationMCPPlanner().availability())\nTools: \(discoveredTools)\nFara loads: \(visualLoads)\nProgress: \(progressMessages)\nResult: \(String(reflecting: result))\nFailure: \(String(reflecting: failure))")
            attachment.name = "Actual helper and default planner browser entry"
            attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertGreaterThan(discoveredTools.count, 1, "The pinned helper's actual catalog must participate.")
        }
        if let failure { return XCTFail("Normal browser composition failed before \(visualLoads) Fara loads: \(String(reflecting: failure))") }
        guard case .completed(let answer) = result else { return XCTFail("Normal composition did not complete the browser task") }
        XCTAssertTrue(answer.lowercased().contains("2400 jpy"))
        XCTAssertTrue(answer.lowercased().contains("7 pm") || answer.contains("19:00"))
        XCTAssertTrue(answer.contains(base.appendingPathComponent("details").absoluteString))
        XCTAssertEqual(visualLoads, 1)
        if !usesActualMacTools { XCTAssertEqual(planner.proposedToolNames.count, 1) }
        XCTAssertEqual(server.count("/results"), 1)
        XCTAssertEqual(server.count("/details"), 1)
        let calls = await pool.directExecuteCount(); XCTAssertEqual(calls, 0)
    }

    func testApprovedMailConfirmationRequiresMatchingTypedStatusAndUsesHostWording() throws {
        let tool = try makeMailTool()
        for send in [false, true] {
            let call = try tool.makeCall(taskID: "approved-fact", arguments: [
                "to": .string("alex@example.invalid"), "subject": .string("Status"), "body": .string("Hello"), "send_now": .bool(send)])
            let status = send ? "accepted_for_sending" : "draft_opened"
            let result = try MCPToolResult(text: "All tickets were purchased. secret-callback-token",
                structuredContent: .object(["status": .string(status)]), isError: false, wasTruncated: false)
            let confirmation = try MCPApprovedActionResult.verified(call: call, result: result, trustedUserPrompt: "Prepare the email, then find movie tickets")
            XCTAssertEqual(confirmation.callDigest, call.canonicalDigest)
            XCTAssertEqual(confirmation.response, send ? "Mail accepted the approved email for sending." : "Email draft opened visibly in Mail for review.")
            XCTAssertFalse(confirmation.response.contains("tickets"))
            XCTAssertFalse(confirmation.response.contains("secret"))
            XCTAssertNil(confirmation.completionPromptDigest)
            let invalidContents: [MCPJSONValue?] = [nil, .null, .object(["ok": .bool(true)]),
                .object(["status": .string(send ? "draft_opened" : "accepted_for_sending")]),
                .object(["status": .string("delivered")]), .object(["status": .string(status), "complete": .bool(true)])]
            for content in invalidContents {
                let invalid = try MCPToolResult(text: confirmation.response, structuredContent: content, isError: false, wasTruncated: false)
                XCTAssertThrowsError(try MCPApprovedActionResult.verified(call: call, result: invalid, trustedUserPrompt: "Send email"))
            }
            for (error, truncated) in [(true, false), (false, true)] {
                let invalid = try MCPToolResult(text: confirmation.response, structuredContent: result.structuredContent, isError: error, wasTruncated: truncated)
                XCTAssertThrowsError(try MCPApprovedActionResult.verified(call: call, result: invalid, trustedUserPrompt: "Send email"))
            }
            let foreign = try MCPToolCall(taskID: call.taskID, serverID: "unreviewed-server", processGeneration: call.processGeneration,
                toolName: call.toolName, arguments: call.arguments, schemaDigest: call.schemaDigest, risk: .approvalRequired, approval: call.approvalDisplay)
            XCTAssertThrowsError(try MCPApprovedActionResult.verified(call: foreign, result: result, trustedUserPrompt: "Send email"))
        }
    }

    func testWholeMailTaskProofRequiresTheCompleteCurrentLiteralRequest() throws {
        let tool = try makeMailTool()
        for send in [false, true] {
            let prompt = "\(send ? "Send" : "Draft") an email to alex@example.invalid with subject \"Café\" and body \"Hello. Then find tickets.\""
            let arguments: [String: MCPJSONValue] = ["to": .string("alex@example.invalid"), "subject": .string("Café"),
                "body": .string("Hello. Then find tickets."), "send_now": .bool(send)]
            let call = try tool.makeCall(taskID: "complete-mail", arguments: arguments)
            let result = try MCPToolResult(text: "Untrusted success prose", structuredContent: .object([
                "status": .string(send ? "accepted_for_sending" : "draft_opened")]), isError: false, wasTruncated: false)
            let confirmation = try MCPApprovedActionResult.verified(call: call, result: result, trustedUserPrompt: prompt)
            XCTAssertEqual(confirmation.completionPromptDigest, try MCPDigest.sha256(of: .string(prompt)))
            let scopedCall = try tool.makeCall(taskID: call.taskID, arguments: arguments,
                stepEffectID: ComputerUseTaskContract.digest(["approved-mail-step"]))
            let scopedConfirmation = try MCPApprovedActionResult.verified(call: scopedCall, result: result, trustedUserPrompt: prompt)
            XCTAssertEqual(scopedConfirmation.response, confirmation.response)
            XCTAssertNil(scopedConfirmation.completionPromptDigest,
                "A task-plan step needs the contract's whole-goal verifier even when this action matches a literal Mail command")
            for request in [prompt + ", then list my reminders", "First find Alex's number. " + prompt, "Do not " + prompt,
                            "Explain how to " + prompt, "Write the text: " + prompt, prompt.replacingOccurrences(of: "Café", with: "Cafe\u{301}"),
                            prompt.replacingOccurrences(of: "alex@example.invalid", with: "pat@example.invalid")] {
                let partial = try MCPApprovedActionResult.verified(call: call, result: result, trustedUserPrompt: request)
                XCTAssertNil(partial.completionPromptDigest, request)
                XCTAssertEqual(partial.response, confirmation.response, "Action confirmation survives an unproven whole task")
            }
            var withBCC = arguments; withBCC["bcc"] = .string("extra@example.invalid")
            let extraRecipient = try tool.makeCall(taskID: call.taskID, arguments: withBCC)
            XCTAssertNil(try MCPApprovedActionResult.verified(call: extraRecipient, result: result, trustedUserPrompt: prompt).completionPromptDigest)
        }
    }

    func testCompoundApprovedRequestReturnsAnActionFactWithoutWholeTaskCompletion() async throws {
        let planner = StubMCPPlanner(mode: .draft)
        let pool = StubMCPClientPool(tools: [try makeMailTool()], resultText: "Everything is complete, including the reminders.")
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(binaryURL: URL(fileURLWithPath: "/test/helper"),
            visualFallback: fallback, planner: planner, clientPool: pool)
        let prompt = "Draft the exact acceptance email, then list my reminders."
        let initial = try await executor.execute(taskID: "compound-approved", prompt: prompt, tools: makeHostTools(), progress: { _ in })
        guard case .mcpApprovalRequired(let prepared) = initial else { return XCTFail("An exact action must still require approval") }
        let confirmed = try await executor.continueAfterApproval(prepared, tools: makeHostTools(), progress: { _ in })
        XCTAssertEqual(confirmed.response, "Email draft opened visibly in Mail for review.")
        XCTAssertNil(confirmed.completionPromptDigest)
        XCTAssertEqual(fallback.callCount, 0)
        do {
            _ = try await executor.continueAfterApproval(prepared, tools: makeHostTools(), progress: { _ in })
            XCTFail("A missing whole-task proof cannot reopen the consumed approval")
        } catch { XCTAssertEqual(error as? MCPFirstComputerUseExecutor.ExecutorError, .approvalStateChanged) }
        let count = await pool.approvedExecuteCount()
        XCTAssertEqual(count, 1)
    }

    func testDeterministicMailStartupCancellationRetiresReturnedHelperBeforeNewWork() async throws {
        try await assertPreparationCancellation(at: .startup)
    }

    func testDeterministicMailDiscoveryCancellationCannotPrepareAnApproval() async throws {
        try await assertPreparationCancellation(at: .discovery)
    }

    func testDeterministicMailPreparationCancellationCannotPublishOrReplayLateApproval() async throws {
        try await assertPreparationCancellation(at: .preparation)
    }

    func testStructuredStartupCancellationAlsoRetiresReturnedHelperWithoutPlanning() async throws {
        try await assertPreparationCancellation(at: .startup, structured: true)
    }

    func testCompleteMailRemainsModelIndependentWhilePlanningPermitIsOccupied() async throws {
        let worker = ComputerUsePlanningWorker()
        let gate = ComputerUsePlanningTestGate<Void>(started: expectation(description: "unrelated planner occupied"),
                                                    returned: expectation(description: "unrelated planner returned"))
        defer { gate.finish(()) }
        let occupied = Task { try await worker.perform { await gate.wait() } }
        await fulfillment(of: [gate.started], timeout: 1)
        let planner = StubMCPPlanner(mode: .unavailable)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(binaryURL: URL(fileURLWithPath: "/test/helper"),
            visualFallback: fallback, planner: planner, clientPool: pool, planningWorker: worker)
        let result = try await executor.execute(taskID: "exact-mail", prompt: exactPreparationPrompt,
            tools: makeHostTools(), progress: { _ in })
        guard case .mcpApprovalRequired(let prepared) = result else { return XCTFail("A complete Mail request needs no planner capacity") }
        XCTAssertEqual(prepared.call.arguments["to"], .string("reviewer@example.invalid"))
        XCTAssertEqual(prepared.call.arguments["send_now"], .bool(false))
        XCTAssertTrue(planner.proposedToolNames.isEmpty)
        XCTAssertEqual(fallback.callCount, 0)
        let direct = await pool.directExecuteCount(), approved = await pool.approvedExecuteCount()
        XCTAssertEqual(direct, 0)
        XCTAssertEqual(approved, 0)
        gate.finish(())
        try await occupied.value
        await fulfillment(of: [gate.returned], timeout: 1)
    }

    func testStoppedHelperStartFailureJoinsEarlierCleanupWithoutMailFallback() async throws {
        let startGate = ComputerUsePlanningTestGate<Void>(started: expectation(description: "helper start entered"),
                                                         returned: expectation(description: "helper start returned"))
        let cleanupGate = ComputerUsePlanningTestGate<Void>(started: expectation(description: "earlier helper cleanup entered"),
                                                           returned: expectation(description: "earlier helper cleanup finished"))
        defer { startGate.finish(()); cleanupGate.finish(()) }
        let pool = StubMCPClientPool(tools: [try makeMailTool()], advancesGenerations: true, cancellationGates: [1: cleanupGate])
        let planner = StubMCPPlanner(mode: .clarification)
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(binaryURL: URL(fileURLWithPath: "/test/helper"),
            visualFallback: fallback, planner: planner, clientPool: pool, planningWorker: ComputerUsePlanningWorker())
        await pool.suspendNextStart(startGate)
        await pool.failNextStart(.serverMismatch("Fixture startup failed after Stop"))
        var finished = false
        let request = Task { () -> Result<ComputerUseExecutionResult, Error> in
            defer { finished = true }
            do { return .success(try await executor.execute(taskID: "stopped", prompt: "Draft the exact acceptance email.", tools: makeHostTools(), progress: { _ in })) }
            catch { return .failure(error) }
        }
        await fulfillment(of: [startGate.started], timeout: 1)
        executor.cancelMCPWork()
        await fulfillment(of: [cleanupGate.started], timeout: 1)
        startGate.finish(())
        await fulfillment(of: [startGate.returned], timeout: 1)
        XCTAssertFalse(finished)
        cleanupGate.finish(())
        switch await request.value {
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        case .success: XCTFail("A failed stopped start must not turn into a Mail clarification or fallback")
        }
        await fulfillment(of: [cleanupGate.returned], timeout: 1)
        let state = await pool.loadState()
        let prepared = await pool.preparedApprovalCount()
        XCTAssertEqual(state.cancelled, [1])
        XCTAssertEqual(state.cancelAll, 0)
        XCTAssertEqual(state.discoveries, 1)
        XCTAssertEqual(prepared, 0)
        XCTAssertTrue(planner.proposedToolNames.isEmpty)
        XCTAssertEqual(fallback.callCount, 0)
    }

    private enum PreparationStage { case startup, discovery, preparation }

    private var exactPreparationPrompt: String {
        "Draft an email to reviewer@example.invalid with subject Status and body The draft is ready for review."
    }

    private func assertPreparationCancellation(at stage: PreparationStage, structured: Bool = false) async throws {
        for stopOnly in [false, true] {
            let stageGate = ComputerUsePlanningTestGate<Void>(started: expectation(description: "\(stage) entered, Stop only \(stopOnly)"),
                                                             returned: expectation(description: "\(stage) returned, Stop only \(stopOnly)"))
            let cleanupGate = ComputerUsePlanningTestGate<Void>(started: expectation(description: "returned generation cleanup entered"),
                                                               returned: expectation(description: "returned generation cleanup finished"))
            defer { stageGate.finish(()); cleanupGate.finish(()) }
            let pool = StubMCPClientPool(tools: [try makeMailTool()], resultText: "draft created",
                advancesGenerations: true, cancellationGates: [2: cleanupGate])
            let planner = StubMCPPlanner(mode: structured ? .clarification : .unavailable)
            let fallback = StubVisualExecutor()
            let executor = try await MCPFirstComputerUseExecutor.load(binaryURL: URL(fileURLWithPath: "/test/helper"),
                visualFallback: fallback, planner: planner, clientPool: pool, planningWorker: ComputerUsePlanningWorker())
            switch stage {
            case .startup: await pool.suspendNextStart(stageGate)
            case .discovery: await pool.suspendNextDiscovery(stageGate)
            case .preparation: await pool.suspendNextPreparation(stageGate)
            }
            let prompt = structured ? "Help with this document." : exactPreparationPrompt
            var finished = false
            let request = Task { () -> Result<ComputerUseExecutionResult, Error> in
                defer { finished = true }
                do { return .success(try await executor.execute(taskID: "interrupted", prompt: prompt, tools: makeHostTools(), progress: { _ in })) }
                catch { return .failure(error) }
            }
            await fulfillment(of: [stageGate.started], timeout: 1)
            if stopOnly { executor.cancelMCPWork() } else { request.cancel() }
            stageGate.finish(())
            await fulfillment(of: [stageGate.returned, cleanupGate.started], timeout: 1)
            XCTAssertFalse(finished, "The current owner must join cleanup of the returned generation")
            do { _ = try await executor.execute(taskID: "overlap", prompt: prompt, tools: makeHostTools(), progress: { _ in }); XCTFail("Cleanup still owns this executor") }
            catch { XCTAssertEqual(error as? MCPFirstComputerUseExecutor.ExecutorError, .alreadyExecuting) }
            let whileStopping = await pool.loadState()
            let preparedCount = await pool.preparedApprovalCount()
            XCTAssertEqual(whileStopping.discoveries, stage == .startup ? 1 : 2)
            XCTAssertEqual(preparedCount, stage == .preparation ? 1 : 0)
            let stale = await pool.mostRecentPreparation()
            if stage == .preparation { XCTAssertNotNil(stale) }
            cleanupGate.finish(())
            switch await request.value {
            case .failure(let error): XCTAssertTrue(error is CancellationError)
            case .success: XCTFail("An interrupted stage cannot publish approval or completion")
            }
            await fulfillment(of: [cleanupGate.returned], timeout: 1)
            let stopped = await pool.loadState()
            XCTAssertEqual(stopped.cancelled, stopOnly && stage == .startup ? [1, 2] : [2])
            XCTAssertEqual(stopped.cancelAll, 0, "Cleanup must be scoped to the returned generation")
            XCTAssertTrue(planner.proposedToolNames.isEmpty)
            XCTAssertEqual(fallback.callCount, 0)
            if let stale {
                do { _ = try await executor.continueAfterApproval(stale, tools: makeHostTools(), progress: { _ in }); XCTFail("A late preparation cannot be replayed") }
                catch { XCTAssertEqual(error as? MCPFirstComputerUseExecutor.ExecutorError, .approvalStateChanged) }
            }
            let direct = await pool.directExecuteCount(), approved = await pool.approvedExecuteCount()
            XCTAssertEqual(direct, 0)
            XCTAssertEqual(approved, 0)
            let fresh = try await executor.execute(taskID: "fresh", prompt: prompt, tools: makeHostTools(), progress: { _ in })
            if structured {
                XCTAssertEqual(fresh, .clarificationRequired("Which document should I use?"))
            } else {
                guard case .mcpApprovalRequired(let prepared) = fresh else { return XCTFail("A fresh explicit request must remain usable after cleanup") }
                XCTAssertEqual(prepared.call.processGeneration, 3)
                let result = try await executor.continueAfterApproval(prepared, tools: makeHostTools(), progress: { _ in })
                XCTAssertEqual(result.response, "Email draft opened visibly in Mail for review.")
                XCTAssertNil(result.completionPromptDigest)
                let performed = await pool.approvedExecuteCount()
                XCTAssertEqual(performed, 1)
            }
        }
    }

    func testPlanningDeadlineNeverFallsBackOrPreparesLateCalls() async throws {
        for prompt in ["What application is focused?", "Draft the exact acceptance email."] {
            let worker = ComputerUsePlanningWorker()
            let gate = ComputerUsePlanningTestGate<Void>(started: expectation(description: "planner started \(prompt)"),
                                                        returned: expectation(description: "planner returned \(prompt)"))
            defer { gate.finish(()) }
            let latePlanner = StubMCPPlanner(mode: .draft)
            let planner = DeadlineMCPPlanner { request in
                await gate.wait()
                return try await latePlanner.propose(request)
            }
            let pool = StubMCPClientPool(tools: [try makeMailTool(), try makeFocusedAppTool()])
            let fallback = StubVisualExecutor()
            let executor = try await MCPFirstComputerUseExecutor.load(binaryURL: URL(fileURLWithPath: "/test/helper"),
                visualFallback: fallback, planner: planner, clientPool: pool,
                planningWorker: worker, planningTimeout: 0.1)
            do { _ = try await executor.execute(taskID: "timed-out", prompt: prompt, tools: makeHostTools(), progress: { _ in }); XCTFail("Planning must time out") }
            catch { XCTAssertEqual(error as? ComputerUsePlanningWorker.Failure, .timedOut) }
            await fulfillment(of: [gate.started], timeout: 1)
            let starts = await pool.helperStartCount()
            do { _ = try await executor.execute(taskID: "busy", prompt: prompt, tools: makeHostTools(), progress: { _ in }); XCTFail("The outstanding planner still owns capacity") }
            catch { XCTAssertEqual(error as? ComputerUsePlanningWorker.Failure, .busy) }
            let startsWhileBusy = await pool.helperStartCount()
            XCTAssertEqual(startsWhileBusy, starts)
            gate.finish(())
            await fulfillment(of: [gate.returned], timeout: 1)
            try await waitForAvailablePlanningWorker(worker)
            let direct = await pool.directExecuteCount()
            let prepared = await pool.preparedApprovalCount()
            let approved = await pool.approvedExecuteCount()
            XCTAssertEqual(direct, 0)
            XCTAssertEqual(prepared, 0, "A late proposal must never become an approval request")
            XCTAssertEqual(approved, 0)
            XCTAssertEqual(fallback.callCount, 0, "Planning timeout cannot authorize visual or Mail fallback")
        }
    }

    func testCancelledPlanningJoinsHelperCleanupAndRejectsOverlappingExecutions() async throws {
        let worker = ComputerUsePlanningWorker()
        let proposalGate = ComputerUsePlanningTestGate<Void>(started: expectation(description: "planner started"),
                                                            returned: expectation(description: "planner returned"))
        let cleanupGate = ComputerUsePlanningTestGate<Void>(started: expectation(description: "cleanup started"),
                                                           returned: expectation(description: "cleanup returned"))
        defer { proposalGate.finish(()); cleanupGate.finish(()) }
        let planner = DeadlineMCPPlanner { _ in await proposalGate.wait(); return .message("VISUAL_FALLBACK_REQUIRED") }
        let pool = StubMCPClientPool(tools: [try makeMailTool()], cancellationGate: cleanupGate)
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(binaryURL: URL(fileURLWithPath: "/test/helper"),
            visualFallback: fallback, planner: planner, clientPool: pool, planningWorker: worker)
        var finished = false
        let first = Task { () -> Result<ComputerUseExecutionResult, Error> in
            defer { finished = true }
            do { return .success(try await executor.execute(taskID: "cancelled", prompt: "Help with this document.", tools: makeHostTools(), progress: { _ in })) }
            catch { return .failure(error) }
        }
        await fulfillment(of: [proposalGate.started], timeout: 2)
        first.cancel()
        executor.cancelMCPWork()
        await fulfillment(of: [cleanupGate.started], timeout: 1)
        XCTAssertFalse(finished, "The cancelled owner must join its exact helper cleanup")
        let starts = await pool.helperStartCount()
        do { _ = try await executor.execute(taskID: "overlap", prompt: "Help with this document.", tools: makeHostTools(), progress: { _ in }); XCTFail("An active owner must not be replaced") }
        catch { XCTAssertEqual(error as? MCPFirstComputerUseExecutor.ExecutorError, .alreadyExecuting) }
        cleanupGate.finish(())
        switch await first.value {
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        case .success: XCTFail("A cancelled proposal cannot produce a task result")
        }
        await fulfillment(of: [cleanupGate.returned], timeout: 1)
        XCTAssertThrowsError(try worker.requireAvailable()) {
            XCTAssertEqual($0 as? ComputerUsePlanningWorker.Failure, .busy)
        }
        proposalGate.finish(())
        await fulfillment(of: [proposalGate.returned], timeout: 1)
        try await waitForAvailablePlanningWorker(worker)
        let load = await pool.loadState()
        let finalStarts = await pool.helperStartCount()
        XCTAssertEqual(finalStarts, starts)
        XCTAssertEqual(load.cancelled, [1], "Stop and Task cancellation must share one cleanup operation")
        XCTAssertEqual(fallback.callCount, 0)
    }

    func testSynchronousMCPCancellationIsJoinedBeforeAnotherHelperStart() async throws {
        let gate = ComputerUsePlanningTestGate<Void>(started: expectation(description: "cleanup started"),
                                                    returned: expectation(description: "cleanup returned"))
        defer { gate.finish(()) }
        let planner = StubMCPPlanner(mode: .clarification)
        let pool = StubMCPClientPool(tools: [try makeMailTool()], cancellationGate: gate)
        let executor = try await MCPFirstComputerUseExecutor.load(binaryURL: URL(fileURLWithPath: "/test/helper"),
            visualFallback: StubVisualExecutor(), planner: planner, clientPool: pool,
            planningWorker: ComputerUsePlanningWorker())
        executor.cancelMCPWork()
        executor.cancelMCPWork()
        await fulfillment(of: [gate.started], timeout: 1)
        let nextEntered = expectation(description: "replacement request entered")
        let next = Task {
            nextEntered.fulfill()
            return try await executor.execute(taskID: "next", prompt: "Help with this document.", tools: makeHostTools(), progress: { _ in })
        }
        await fulfillment(of: [nextEntered], timeout: 1)
        let startsDuringCleanup = await pool.helperStartCount()
        XCTAssertEqual(startsDuringCleanup, 1, "No new helper start may pass the pending cleanup")
        XCTAssertTrue(planner.proposedToolNames.isEmpty)
        gate.finish(())
        let nextResult = try await next.value
        XCTAssertEqual(nextResult, .clarificationRequired("Which document should I use?"))
        await fulfillment(of: [gate.returned], timeout: 1)
        let load = await pool.loadState()
        let startsAfterCleanup = await pool.helperStartCount()
        let overlappingStarts = await pool.helperStartsDuringCleanup()
        XCTAssertEqual(load.cancelled, [1])
        XCTAssertEqual(startsAfterCleanup, 2)
        XCTAssertEqual(overlappingStarts, 0, "Record ordering at the helper boundary as well as the suspended request")
    }

    func testSynchronousMCPStopRejectsLateProposalAndJoinsCleanupWithoutTaskCancellation() async throws {
        let proposalGate = ComputerUsePlanningTestGate<Void>(started: expectation(description: "planner started"),
                                                            returned: expectation(description: "planner returned"))
        let cleanupGate = ComputerUsePlanningTestGate<Void>(started: expectation(description: "cleanup started"),
                                                           returned: expectation(description: "cleanup returned"))
        defer { proposalGate.finish(()); cleanupGate.finish(()) }
        let planner = DeadlineMCPPlanner { _ in await proposalGate.wait(); return .message("VISUAL_FALLBACK_REQUIRED") }
        let pool = StubMCPClientPool(tools: [try makeMailTool()], cancellationGate: cleanupGate)
        let fallback = StubVisualExecutor()
        let worker = ComputerUsePlanningWorker()
        let executor = try await MCPFirstComputerUseExecutor.load(binaryURL: URL(fileURLWithPath: "/test/helper"),
            visualFallback: fallback, planner: planner, clientPool: pool, planningWorker: worker)
        var finished = false
        let request = Task { () -> Result<ComputerUseExecutionResult, Error> in
            defer { finished = true }
            do { return .success(try await executor.execute(taskID: "stopped", prompt: "Help with this document.", tools: makeHostTools(), progress: { _ in })) }
            catch { return .failure(error) }
        }
        await fulfillment(of: [proposalGate.started], timeout: 1)
        executor.cancelMCPWork()
        await fulfillment(of: [cleanupGate.started], timeout: 1)
        proposalGate.finish(())
        await fulfillment(of: [proposalGate.returned], timeout: 1)
        XCTAssertFalse(finished)
        XCTAssertEqual(fallback.callCount, 0)
        cleanupGate.finish(())
        switch await request.value {
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        case .success: XCTFail("A stopped helper generation cannot authorize a late proposal or fallback")
        }
        await fulfillment(of: [cleanupGate.returned], timeout: 1)
        try await waitForAvailablePlanningWorker(worker)
        let prepared = await pool.preparedApprovalCount()
        let direct = await pool.directExecuteCount()
        XCTAssertEqual(prepared, 0)
        XCTAssertEqual(direct, 0)
        XCTAssertEqual(fallback.callCount, 0)
    }

    func testApprovedMCPActionKeepsReturnedResultWhileJoiningCancellation() async throws {
        let effectGate = ComputerUsePlanningTestGate<Void>(started: expectation(description: "approved effect posted"),
                                                          returned: expectation(description: "approved result returned"))
        let cleanupGate = ComputerUsePlanningTestGate<Void>(started: expectation(description: "cleanup started"),
                                                           returned: expectation(description: "cleanup returned"))
        defer { effectGate.finish(()); cleanupGate.finish(()) }
        let pool = StubMCPClientPool(tools: [try makeMailTool()], resultText: "draft created",
            cancellationGate: cleanupGate, approvedOperationGate: effectGate)
        let executor = try await MCPFirstComputerUseExecutor.load(binaryURL: URL(fileURLWithPath: "/test/helper"),
            visualFallback: StubVisualExecutor(), planner: StubMCPPlanner(mode: .draft), clientPool: pool,
            planningWorker: ComputerUsePlanningWorker())
        let result = try await executor.execute(taskID: "approved", prompt: "Draft the exact acceptance email.", tools: makeHostTools(), progress: { _ in })
        guard case .mcpApprovalRequired(let prepared) = result else { return XCTFail("The fixture needs an exact prepared action") }
        var finished = false
        let approved = Task {
            defer { finished = true }
            return try await executor.continueAfterApproval(prepared, tools: makeHostTools(), progress: { _ in })
        }
        await fulfillment(of: [effectGate.started], timeout: 1)
        approved.cancel()
        executor.cancelMCPWork()
        await fulfillment(of: [cleanupGate.started], timeout: 1)
        effectGate.finish(())
        await fulfillment(of: [effectGate.returned], timeout: 1)
        XCTAssertFalse(finished, "A returned effect result must still join cancellation cleanup")
        cleanupGate.finish(())
        let approvedResult = try await approved.value
        XCTAssertEqual(approvedResult.response, "Email draft opened visibly in Mail for review.")
        XCTAssertNil(approvedResult.completionPromptDigest)
        await fulfillment(of: [cleanupGate.returned], timeout: 1)
        do { _ = try await executor.continueAfterApproval(prepared, tools: makeHostTools(), progress: { _ in }); XCTFail("The consumed approval cannot replay") }
        catch { XCTAssertEqual(error as? MCPFirstComputerUseExecutor.ExecutorError, .approvalStateChanged) }
        let posted = await pool.approvedExecuteCount()
        let load = await pool.loadState()
        XCTAssertEqual(posted, 1)
        XCTAssertEqual(load.cancelled, [1])
    }

    func testExplicitBrowserNavigationUsesOwnedContextWithAppleAndVisualUnavailable() async throws {
        let server = try OwnedBrowserHTTPFixture()
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browserTask = ComputerUseBrowserNavigationTask(
            browser: ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true }), journalDirectory: directory)
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, browserNavigationTask: browserTask)
        defer { tools.closeOwnedBrowser() }
        let planner = StubMCPPlanner(mode: .unavailable)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let executor = try await MCPFirstComputerUseExecutor.load(binaryURL: URL(fileURLWithPath: "/test/helper"),
            visualFallback: ComputerUseDeferredVisualExecutor(), planner: planner, clientPool: pool)
        defer { executor.cancelMCPWork() }
        let current = "Open \(base.appendingPathComponent("current")) then \(base.appendingPathComponent("current"))"
        for _ in 0..<2 {
            let result = try await executor.execute(taskID: "browser", modelPrompt: "Open \(base.appendingPathComponent("history"))",
                currentUserPrompt: current, conversation: [], tools: tools, progress: { _ in })
            guard case .completed = result else { return XCTFail("The explicit browser goal must not require either local model") }
        }
        XCTAssertEqual(server.count("/current"), 2)
        XCTAssertEqual(server.count("/history"), 0)
        XCTAssertTrue(planner.proposedToolNames.isEmpty)
        let calls = await pool.directExecuteCount()
        XCTAssertEqual(calls, 0, "Ambient browser MCP tools remain outside this navigation path")
    }

    func testCancelledHelperActivationReleasesReturnedGenerationWithoutDiscoveringTools() async throws {
        let pool = StubMCPClientPool(tools: [try makeMailTool()], loadFault: .suspendedStart)
        let task = Task {
            try await MCPFirstComputerUseExecutor.load(binaryURL: URL(fileURLWithPath: "/test/helper"),
                visualFallback: ComputerUseDeferredVisualExecutor(), clientPool: pool)
        }
        await pool.waitForSuspendedLoad()
        task.cancel()
        await pool.releaseLoad()
        do { _ = try await task.value; XCTFail("Cancelled activation cannot publish a ready executor") }
        catch is CancellationError { }
        let state = await pool.loadState()
        XCTAssertEqual(state.discoveries, 0)
        XCTAssertEqual(state.cancelled, [1])
        XCTAssertEqual(state.cancelAll, 0)
    }

    func testCancelledToolDiscoveryReleasesOwnedHelperBeforeReturning() async throws {
        let pool = StubMCPClientPool(tools: [try makeMailTool()], loadFault: .suspendedTools)
        let task = Task {
            try await MCPFirstComputerUseExecutor.load(binaryURL: URL(fileURLWithPath: "/test/helper"),
                visualFallback: ComputerUseDeferredVisualExecutor(), clientPool: pool)
        }
        await pool.waitForSuspendedLoad()
        task.cancel()
        await pool.releaseLoad()
        do { _ = try await task.value; XCTFail("Cancelled discovery cannot publish a ready executor") }
        catch is CancellationError { }
        let state = await pool.loadState()
        XCTAssertEqual(state.discoveries, 1)
        XCTAssertEqual(state.cancelled, [1])
        XCTAssertEqual(state.cancelAll, 0)
    }

    func testFailedDiscoveryAndMissingToolReleaseOnlyOwnedHelperGeneration() async throws {
        for fault in [StubMCPClientPool.LoadFault.toolsFailure, .none] {
            let pool = StubMCPClientPool(tools: [], loadFault: fault)
            do {
                _ = try await MCPFirstComputerUseExecutor.load(binaryURL: URL(fileURLWithPath: "/test/helper"),
                    visualFallback: ComputerUseDeferredVisualExecutor(), clientPool: pool)
                XCTFail("An unusable helper must not become ready")
            } catch { }
            let state = await pool.loadState()
            XCTAssertEqual(state.cancelled, [1])
            XCTAssertEqual(state.cancelAll, 0, "Unscoped cleanup could stop a newer run")
        }
    }

    func testStructuredApprovalWorksWithoutInstalledVisualModel() async throws {
        let planner = StubMCPPlanner(mode: .draft)
        let pool = StubMCPClientPool(tools: [try makeMailTool()], resultText: "draft created")
        let executor = try await MCPFirstComputerUseExecutor.load(binaryURL: URL(fileURLWithPath: "/test/helper"),
            visualFallback: ComputerUseDeferredVisualExecutor(), planner: planner, clientPool: pool)
        XCTAssertTrue(executor.isReady)
        XCTAssertTrue(executor.hasAdditionalSetup)
        let result = try await executor.execute(taskID: "structured-only", prompt: "Draft the exact acceptance email.",
            tools: makeHostTools(), progress: { _ in })
        guard case .mcpApprovalRequired(let prepared) = result else { return XCTFail("Exact approval must still be required") }
        let before = await pool.approvedExecuteCount()
        XCTAssertEqual(before, 0)
        let completed = try await executor.continueAfterApproval(prepared, tools: makeHostTools(), progress: { _ in })
        XCTAssertEqual(completed.response, "Email draft opened visibly in Mail for review.")
        XCTAssertNil(completed.completionPromptDigest)
        let after = await pool.approvedExecuteCount()
        XCTAssertEqual(after, 1)
    }

    func testStructuredTaskDoesNotLoadVisualUntilFallbackActuallyExecutes() async throws {
        var loads = 0
        let actual = StubVisualExecutor()
        let deferred = ComputerUseDeferredVisualExecutor(loader: { _ in loads += 1; return actual })
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let structured = try await MCPFirstComputerUseExecutor.load(binaryURL: URL(fileURLWithPath: "/test/helper"),
            visualFallback: deferred, planner: StubMCPPlanner(mode: .draft), clientPool: pool)
        _ = try await structured.execute(taskID: "draft", prompt: "Draft the exact acceptance email.",
            tools: makeHostTools(), progress: { _ in })
        XCTAssertEqual(loads, 0)
        let needsVisual = try await MCPFirstComputerUseExecutor.load(binaryURL: URL(fileURLWithPath: "/test/helper"),
            visualFallback: deferred, planner: StubMCPPlanner(mode: .unavailable), clientPool: pool)
        _ = try await needsVisual.execute(taskID: "visual", prompt: "Use this GUI-only app",
            tools: makeHostTools(), progress: { _ in })
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(actual.callCount, 1)
    }

    func testMissingVisualWithUnavailableAppleReturnsSpecificUnableOutcome() async throws {
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let executor = try await MCPFirstComputerUseExecutor.load(binaryURL: URL(fileURLWithPath: "/test/helper"),
            visualFallback: ComputerUseDeferredVisualExecutor(), planner: StubMCPPlanner(mode: .unavailable), clientPool: pool)
        XCTAssertTrue(executor.isReady)
        let result = try await executor.execute(taskID: "missing-visual", prompt: "Use this GUI-only app",
            tools: makeHostTools(), progress: { _ in })
        guard case .unableToComplete(let reason) = result else { return XCTFail("Missing visual capability must be explicit") }
        XCTAssertTrue(reason.contains("visual control"))
        let count = await pool.directExecuteCount()
        XCTAssertEqual(count, 0)
    }

    func testVisualApprovalEffectForwardsToRetainedFallbackWithoutGlobalInputOrPlanner() async throws {
        let planner = StubMCPPlanner(mode: .clarification)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(binaryURL: URL(fileURLWithPath: "/fictional/MacControlMCP"),
            visualFallback: fallback, planner: planner, clientPool: pool)
        let token = ComputerUseVisualApprovalContinuation(taskID: "native-effect-forward", nonce: UUID())
        let action = ComputerUsePredictedAction.click(x: 20, y: 30, button: 0, count: 1)
        let fingerprint = ComputerUseApprovalFingerprint(action: action, applicationID: "fixture.browser", accessibilityIdentity: "button", visualDigest: nil)
        var began = 0
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true },
            actionPerformer: { _ in XCTFail("Retained approval effect entered global input") })
        try await executor.performApprovedVisualAction(token, action: action, fingerprint: fingerprint, tools: tools,
            willBeginEffect: { began += 1 })
        XCTAssertEqual(fallback.performedApprovals, [token])
        XCTAssertEqual(fallback.performedFingerprints, [fingerprint])
        XCTAssertEqual(began, 1)
        XCTAssertTrue(planner.proposedToolNames.isEmpty)
        let direct = await pool.directExecuteCount(), approved = await pool.approvedExecuteCount()
        XCTAssertEqual(direct, 0); XCTAssertEqual(approved, 0)
    }

    func testVisualApprovalContinuationForwardsDirectlyToFallbackWithoutPlannerOrMCP()
        async throws {
        let planner = StubMCPPlanner(mode: .clarification)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor(
            result: .completed("Approved visual task finished"))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)
        let continuation = ComputerUseVisualApprovalContinuation(
            taskID: "task-b09",
            nonce: UUID(uuidString:
                "01234567-89AB-CDEF-0123-456789ABCDEF")!)
        let action = ComputerUsePredictedAction.click(
            x: 499,
            y: 529,
            button: 0,
            count: 1)
        var progress: [String] = []

        let result = try await executor.continueAfterApprovedVisualAction(
            continuation,
            action: action,
            tools: makeHostTools(),
            progress: { progress.append($0) })

        XCTAssertEqual(result, .completed("Approved visual task finished"))
        XCTAssertEqual(fallback.continuations, [continuation])
        XCTAssertEqual(fallback.continuationActions, [action])
        XCTAssertEqual(progress, ["Continuing the approved visual task…"])
        XCTAssertTrue(
            planner.proposedToolNames.isEmpty,
            "Typed visual continuation must not re-enter the Apple planner")
        let directCountAfterContinuation = await pool.directExecuteCount()
        let approvedCountAfterContinuation = await pool.approvedExecuteCount()
        XCTAssertEqual(directCountAfterContinuation, 0)
        XCTAssertEqual(approvedCountAfterContinuation, 0)

        executor.cancelVisualApprovalContinuation(continuation)
        XCTAssertEqual(fallback.cancelledContinuations, [continuation])
        XCTAssertTrue(planner.proposedToolNames.isEmpty)
        let directCountAfterCancellation = await pool.directExecuteCount()
        let approvedCountAfterCancellation = await pool.approvedExecuteCount()
        XCTAssertEqual(directCountAfterCancellation, 0)
        XCTAssertEqual(approvedCountAfterCancellation, 0)
    }

    func testMutationProposalStopsBeforeExecutionAndRunsExactlyOnceAfterApproval() async throws {
        let tool = try makeMailTool()
        let planner = StubMCPPlanner(mode: .draft)
        let pool = StubMCPClientPool(
            tools: [tool],
            resultText: "draft created")
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let first = try await executor.execute(
            taskID: "task-email-draft",
            prompt: "Draft the exact acceptance email.",
            tools: makeHostTools(),
            progress: { _ in })

        guard case .mcpApprovalRequired(let prepared) = first else {
            return XCTFail("Expected the exact MCP call to wait for approval")
        }
        XCTAssertEqual(prepared.call.toolName, RemoteDesktopMailMCP.toolName)
        let directBeforeApproval = await pool.directExecuteCount()
        let approvedBeforeApproval = await pool.approvedExecuteCount()
        XCTAssertEqual(directBeforeApproval, 0)
        XCTAssertEqual(approvedBeforeApproval, 0)

        let completed = try await executor.continueAfterApproval(
            prepared,
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(completed.response, "Email draft opened visibly in Mail for review.")
        XCTAssertNil(completed.completionPromptDigest)
        let directAfterApproval = await pool.directExecuteCount()
        let approvedAfterApproval = await pool.approvedExecuteCount()
        XCTAssertEqual(directAfterApproval, 0)
        XCTAssertEqual(approvedAfterApproval, 1)

        do {
            _ = try await executor.continueAfterApproval(
                prepared,
                tools: makeHostTools(),
                progress: { _ in })
            XCTFail("The same approval must not be reusable")
        } catch let error as MCPFirstComputerUseExecutor.ExecutorError {
            XCTAssertEqual(error, .approvalStateChanged)
        }
        let approvedAfterReplay = await pool.approvedExecuteCount()
        XCTAssertEqual(approvedAfterReplay, 1)
    }

    func testUnavailableAppleModelUsesVisualFallbackWithoutCallingMCP() async throws {
        let tool = try makeMailTool()
        let planner = StubMCPPlanner(mode: .unavailable)
        let pool = StubMCPClientPool(tools: [tool])
        let fallback = StubVisualExecutor(result: .completed("Visual fallback finished"))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "task-gui",
            prompt: "Use this GUI-only app",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(result, .completed("Visual fallback finished"))
        XCTAssertEqual(fallback.callCount, 1)
        let directCount = await pool.directExecuteCount()
        let approvedCount = await pool.approvedExecuteCount()
        XCTAssertEqual(directCount, 0)
        XCTAssertEqual(approvedCount, 0)
    }

    func testVisibleSupportPhoneReadUsesGenericPlannerWithoutVisualPreRoute()
        async throws {
        let prompts = [
            "Please open Safari and tell me the support phone number shown on the local page already loaded there.",
            "What is the support phone shown on the Safari page?",
            "Which is the support phone shown on the Safari page?",
            "What is the support telephone number shown on the Safari page?",
            "Give me the support contact number shown on the current webpage.",
            "Please open Safari and tell me the support phone number shown on the local page already loaded there. Do not use Contacts.",
        ]
        for (index, prompt) in prompts.enumerated() {
            let planner = StubMCPPlanner(mode: .clarification)
            let pool = StubMCPClientPool(tools: [
                try makeMailTool(),
                try makePlannerVisibleReadOnlyTool("contacts_search"),
            ])
            let fallback = StubVisualExecutor(
                result: .completed("A visual fallback must not run"))
            let executor = try await MCPFirstComputerUseExecutor.load(
                binaryURL: URL(fileURLWithPath:
                    "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
                visualFallback: fallback,
                planner: planner,
                clientPool: pool)
            var progress: [String] = []
            let taskID = "hostile-support-phone-visible-read-\(index)"

            let result = try await executor.execute(
                taskID: taskID,
                prompt: prompt,
                trustedUserPrompt: prompt,
                tools: makeHostTools(),
                progress: { progress.append($0) })

            XCTAssertEqual(
                result,
                .clarificationRequired("Which document should I use?"),
                prompt)
            XCTAssertEqual(fallback.callCount, 0, prompt)
            XCTAssertTrue(fallback.prompts.isEmpty, prompt)
            XCTAssertTrue(fallback.trustedUserPrompts.isEmpty, prompt)
            XCTAssertTrue(fallback.taskIDs.isEmpty, prompt)
            XCTAssertEqual(
                planner.proposedToolNames.count,
                1,
                "No benchmark-shaped prompt may bypass the ordinary planner: \(prompt)")
            XCTAssertEqual(
                progress.first,
                "Planning with on-device Apple Intelligence…")
            let directCount = await pool.directExecuteCount()
            let approvedCount = await pool.approvedExecuteCount()
            XCTAssertEqual(directCount, 0, prompt)
            XCTAssertEqual(approvedCount, 0, prompt)
        }
    }

    func testVisibleSupportPhoneCompoundWorkUsesGenericPlannerWithoutEffects()
        async throws {
        let prefix =
            "Please open Safari and tell me the support phone number shown on the local page already loaded there."
        let prompts = [
            prefix + " Then call it.",
            prefix + " Then click Help.",
            prefix + " Then tell me the support hours.",
            prefix + " Then search Contacts for the same number.",
        ]
        for (index, prompt) in prompts.enumerated() {
            let planner = StubMCPPlanner(mode: .clarification)
            let pool = StubMCPClientPool(tools: [
                try makeMailTool(),
                try makePlannerVisibleReadOnlyTool("contacts_search"),
            ])
            let fallback = StubVisualExecutor(
                result: .completed("A visual fallback must not run"))
            let executor = try await MCPFirstComputerUseExecutor.load(
                binaryURL: URL(fileURLWithPath:
                    "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
                visualFallback: fallback,
                planner: planner,
                clientPool: pool)

            let result = try await executor.execute(
                taskID: "hostile-support-phone-compound-\(index)",
                prompt: prompt,
                trustedUserPrompt: prompt,
                tools: makeHostTools(),
                progress: { _ in })

            XCTAssertEqual(
                result,
                .clarificationRequired("Which document should I use?"),
                prompt)
            XCTAssertEqual(fallback.callCount, 0, prompt)
            XCTAssertTrue(fallback.prompts.isEmpty, prompt)
            XCTAssertTrue(fallback.trustedUserPrompts.isEmpty, prompt)
            XCTAssertEqual(
                planner.proposedToolNames.count,
                1,
                "Compound work must use the ordinary planner/policy path: \(prompt)")
            let directCount = await pool.directExecuteCount()
            let approvedCount = await pool.approvedExecuteCount()
            XCTAssertEqual(directCount, 0, prompt)
            XCTAssertEqual(approvedCount, 0, prompt)
        }
    }

    func testVisibleSupportPhoneReadUsesGenericFallbackWhenPlannerUnavailable()
        async throws {
        let prompt =
            "Please open Safari and tell me the support phone number shown on the local page already loaded there."
        let planner = StubMCPPlanner(mode: .unavailable)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor(
            result: .completed("Visible page read finished"))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "support-phone-generic-unavailable",
            prompt: prompt,
            trustedUserPrompt: prompt,
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(result, .completed("Visible page read finished"))
        XCTAssertEqual(fallback.callCount, 1)
        XCTAssertEqual(fallback.prompts, [prompt])
        XCTAssertEqual(fallback.trustedUserPrompts, [prompt])
        XCTAssertTrue(planner.proposedToolNames.isEmpty)
        let directCount = await pool.directExecuteCount()
        let approvedCount = await pool.approvedExecuteCount()
        XCTAssertEqual(directCount, 0)
        XCTAssertEqual(approvedCount, 0)
    }

    func testBrowserOnlyReadUsesGenericPlannerFallbackWithoutAdvertisingBlockedBrowserTools() async throws {
        let browserNames = [
            "browser_close_tab", "browser_get_active_tab", "browser_list_tabs",
            "browser_navigate", "browser_new_tab",
        ]
        let planner = StubMCPPlanner(mode: .generationFailure)
        let pool = StubMCPClientPool(
            tools: [try makeMailTool()] + (try browserNames.map {
                try makeBlockedBrowserAdvertisement($0)
            }))
        let guidance = OSAtlasComputerUseExecutor.deliverySignInGuidance
        let fallback = StubVisualExecutor(
            result: .userInterventionRequired(guidance))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)
        let prompt = "Check the current delivered price and ETA for the DoorDash item already in my cart. Do not place the order. Do not enter account information or check out."
        var progress: [String] = []

        let result = try await executor.execute(
            taskID: "task-doordash-visual-login-handoff",
            prompt: prompt,
            tools: makeHostTools(),
            progress: { progress.append($0) })

        XCTAssertEqual(result, .userInterventionRequired(guidance))
        XCTAssertEqual(fallback.prompts, [prompt])
        XCTAssertEqual(
            planner.proposedToolNames.count,
            1,
            "The generic planner must get one opportunity to select the visual fallback")
        let proposedToolNames = try XCTUnwrap(
            planner.proposedToolNames.first)
        XCTAssertTrue(
            proposedToolNames.allSatisfy {
                !browserNames.contains($0)
            },
            "Blocked browser advertisements must never enter the planner surface")
        XCTAssertEqual(
            progress.first,
            "Planning with on-device Apple Intelligence…")
        XCTAssertTrue(progress.contains(
            "This app needs visual control — switching locally…"))
        XCTAssertFalse(progress.contains(where: {
            $0.localizedCaseInsensitiveContains("Reminders")
                || $0.localizedCaseInsensitiveContains("Calendar")
                || $0.localizedCaseInsensitiveContains("Contacts")
        }))
        let directCount = await pool.directExecuteCount()
        let approvedCount = await pool.approvedExecuteCount()
        XCTAssertEqual(directCount, 0)
        XCTAssertEqual(approvedCount, 0)
    }

    func testDeliveryQuoteInModelHistoryCannotDivertCurrentTrustedRead() async throws {
        let focusedApp = try makePlannerVisibleReadOnlyTool("focused_app")
        let resultText = #"{"ok":true,"app":{"pid":4242,"name":"Notes","bundleIdentifier":"com.apple.Notes","isActive":true}}"#
        let planner = SequencedMCPPlanner(steps: [
            .call(
                toolName: "focused_app",
                arguments: [:],
                requiredPromptFragment: nil),
            .completion(
                "Notes is focused.",
                requiredPromptFragment: resultText),
        ])
        let pool = RecordingMCPClientPool(
            tools: [focusedApp, try makeMailTool()],
            resultsByTool: [
                "focused_app": try MCPToolResult(
                    text: resultText,
                    structuredContent: .object([
                        "ok": .bool(true),
                        "app": .object([
                            "pid": .integer(4_242),
                            "name": .string("Notes"),
                            "bundleIdentifier": .string("com.apple.Notes"),
                            "isActive": .bool(true),
                        ]),
                    ]),
                    isError: false,
                    wasTruncated: false),
            ])
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)
        let modelPrompt = "Assistant previously discussed a DoorDash delivery price and ETA quote. Current request: Which app is focused?"
        let trustedPrompt = "Which app is focused?"

        let result = try await executor.execute(
            taskID: "history-quote-current-focused-app",
            prompt: modelPrompt,
            trustedUserPrompt: trustedPrompt,
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(
            result,
            .completed(
                "Focused app: Notes — PID 4242; bundle: com.apple.Notes; active: yes."))
        XCTAssertEqual(fallback.callCount, 0)
        let directCalls = await pool.directCalls()
        XCTAssertEqual(directCalls.count, 1)
    }

    func testCompoundDeliveryQuoteAndSaveDoesNotUsePureQuoteFastPath() async throws {
        let planner = StubMCPPlanner(mode: .clarification)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor(
            result: .completed("Pure visual quote route was used."))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "compound-quote-save",
            prompt: "Check the current DoorDash delivery price and ETA, then save it.",
            trustedUserPrompt:
                "Check the current DoorDash delivery price and ETA, then save it.",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(
            result,
            .clarificationRequired("Which document should I use?"))
        XCTAssertEqual(fallback.callCount, 0)
        XCTAssertEqual(planner.proposedToolNames.count, 1)
    }

    func testDeliveryQuoteFollowUpRetainsEffectWhenWithoutOnlyModifiesItsDetails()
        async throws {
        let prompts = [
            "Check the current DoorDash delivery price and ETA, then email it to me without changing the subject line.",
            "Check the current DoorDash delivery price and ETA, then save it without overwriting my old quote.",
        ]

        for (index, prompt) in prompts.enumerated() {
            let planner = StubMCPPlanner(mode: .clarification)
            let pool = StubMCPClientPool(tools: [try makeMailTool()])
            let fallback = StubVisualExecutor(
                result: .completed("Pure visual quote route was used."))
            let executor = try await MCPFirstComputerUseExecutor.load(
                binaryURL: URL(fileURLWithPath:
                    "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
                visualFallback: fallback,
                planner: planner,
                clientPool: pool)

            let result = try await executor.execute(
                taskID: "compound-quote-without-\(index)",
                prompt: prompt,
                trustedUserPrompt: prompt,
                tools: makeHostTools(),
                progress: { _ in })

            XCTAssertEqual(
                result,
                .clarificationRequired("Which document should I use?"),
                prompt)
            XCTAssertEqual(fallback.callCount, 0, prompt)
            XCTAssertEqual(planner.proposedToolNames.count, 1, prompt)
        }
    }

    func testExplicitlyNegatedDeliveryEffectsUseGenericVisualFallbackWithoutEffects()
        async throws {
        let planner = StubMCPPlanner(mode: .generationFailure)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor(result: .completed("Quote reported."))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)
        let prompt = "Check the current DoorDash delivery price and ETA without emailing or saving it. Do not place the order."

        let result = try await executor.execute(
            taskID: "pure-quote-negated-effects",
            prompt: prompt,
            trustedUserPrompt: prompt,
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(result, .completed("Quote reported."))
        XCTAssertEqual(fallback.callCount, 1)
        XCTAssertEqual(
            planner.proposedToolNames.count,
            1,
            "Browser reads should get the generic planner opportunity before visual fallback")
        let directCount = await pool.directExecuteCount()
        let approvedCount = await pool.approvedExecuteCount()
        XCTAssertEqual(
            directCount,
            0,
            "Negated follow-up effects must not execute a structured tool")
        XCTAssertEqual(
            approvedCount,
            0,
            "Negated follow-up effects must not reach an approval execution")
    }

    func testNegatedPrivateReadClausesCannotAuthorizeContactsOrReminders()
        async throws {
        let rows: [(
            label: String,
            toolName: String,
            prompt: String,
            arguments: [String: MCPJSONValue]
        )] = [
            (
                label: "negated-contact",
                toolName: "contacts_search",
                prompt: "Do not show Jordan Lee's contact. Tell me the weather instead.",
                arguments: [
                    "query": .string("Jordan Lee"),
                    "limit": .integer(5),
                ]),
            (
                label: "negated-contact-with-comma-interjections",
                toolName: "contacts_search",
                prompt: "Do not, under any circumstances, show Jordan Lee's contact.",
                arguments: [
                    "query": .string("Jordan Lee"),
                    "limit": .integer(5),
                ]),
            (
                label: "negated-contact-with-however-interjection",
                toolName: "contacts_search",
                prompt: "Do not, however, show Jordan Lee's contact.",
                arguments: [
                    "query": .string("Jordan Lee"),
                    "limit": .integer(5),
                ]),
            (
                label: "excluded-contact-after-anything-but",
                toolName: "contacts_search",
                prompt: "Do anything but show Jordan Lee's contact.",
                arguments: [
                    "query": .string("Jordan Lee"),
                    "limit": .integer(5),
                ]),
            (
                label: "excluded-contact-after-expanded-anything-but",
                toolName: "contacts_search",
                prompt: "Do anything at all but show Jordan Lee's contact.",
                arguments: [
                    "query": .string("Jordan Lee"),
                    "limit": .integer(5),
                ]),
            (
                label: "excluded-contact-after-other-than",
                toolName: "contacts_search",
                prompt: "Show everything other than Jordan Lee's contact.",
                arguments: [
                    "query": .string("Jordan Lee"),
                    "limit": .integer(5),
                ]),
            (
                label: "excluded-contact-after-excluding",
                toolName: "contacts_search",
                prompt: "Show all local data excluding Jordan Lee's contact.",
                arguments: [
                    "query": .string("Jordan Lee"),
                    "limit": .integer(5),
                ]),
            (
                label: "negated-contact-entity-with-affirmative-alternative",
                toolName: "contacts_search",
                prompt: "Do not show Jordan Lee's contact; show Avery Chen's phone number instead.",
                arguments: [
                    "query": .string("Jordan Lee"),
                    "limit": .integer(5),
                ]),
            (
                label: "negated-contact-after-incidental-report-noun",
                toolName: "contacts_search",
                prompt: "The contact report mentions Jordan Lee; do not show Jordan Lee's contact.",
                arguments: [
                    "query": .string("Jordan Lee"),
                    "limit": .integer(5),
                ]),
            (
                label: "negated-reminders",
                toolName: "reminders_list",
                prompt: "Never list my reminders. Tell me which app is focused instead.",
                arguments: [
                    "include_completed": .bool(false),
                    "limit": .integer(5),
                ]),
            (
                label: "negated-reminders-with-comma-interjections",
                toolName: "reminders_list",
                prompt: "Never, ever, list my reminders.",
                arguments: [
                    "include_completed": .bool(false),
                    "limit": .integer(5),
                ]),
            (
                label: "negated-reminders-with-however-interjection",
                toolName: "reminders_list",
                prompt: "Do not, however, list my reminders.",
                arguments: [
                    "include_completed": .bool(false),
                    "limit": .integer(5),
                ]),
            (
                label: "without-reminders",
                toolName: "reminders_list",
                prompt: "Tell me which app is focused without showing my reminders.",
                arguments: [
                    "include_completed": .bool(false),
                    "limit": .integer(5),
                ]),
        ]

        for row in rows {
            let tool = try makePlannerVisibleReadOnlyTool(row.toolName)
            let planner = SequencedMCPPlanner(steps: [
                .call(
                    toolName: row.toolName,
                    arguments: row.arguments,
                    requiredPromptFragment: nil),
            ])
            let pool = RecordingMCPClientPool(
                tools: [tool, try makeMailTool()],
                resultsByTool: [:])
            let fallback = StubVisualExecutor(
                result: .completed("Visual verification took over."))
            let executor = try await MCPFirstComputerUseExecutor.load(
                binaryURL: URL(fileURLWithPath:
                    "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
                visualFallback: fallback,
                planner: planner,
                clientPool: pool)

            let result = try await executor.execute(
                taskID: row.label,
                prompt: row.prompt,
                trustedUserPrompt: row.prompt,
                tools: makeHostTools(),
                progress: { _ in })

            XCTAssertEqual(
                result,
                .completed("Visual verification took over."),
                row.label)
            XCTAssertEqual(fallback.callCount, 1, row.label)
            let directCalls = await pool.directCalls()
            XCTAssertTrue(
                directCalls.isEmpty,
                "A negated private read executed for (row.label)")
            XCTAssertEqual(planner.completedStepCount, 1, row.label)
        }
    }

    func testAffirmativePrivateReadsRemainAuthorizedBeforeTrailingWithoutClause()
        async throws {
        let rows: [PlannerVisibleReadOnlyRow] = [
            PlannerVisibleReadOnlyRow(
                toolName: "contacts_search",
                prompt: "Show me Jordan Lee's phone number in Contacts without editing the contact.",
                arguments: [
                    "query": .string("Jordan Lee"),
                    "limit": .integer(5),
                ],
                resultText: #"{"ok":true,"contacts":[{"name":"Jordan Lee","phones":["+1 415 555 0142"],"emails":[]}]}"#,
                structuredContent: .object([
                    "ok": .bool(true),
                    "contacts": .array([.object([
                        "name": .string("Jordan Lee"),
                        "phones": .array([.string("+1 415 555 0142")]),
                        "emails": .array([]),
                    ])]),
                ]),
                completion: "Jordan Lee has +1 415 555 0142.",
                expectedProjection: "Contacts (showing up to 5):\n1. Jordan Lee — phones: +1 415 555 0142; emails: none."),
            PlannerVisibleReadOnlyRow(
                toolName: "contacts_search",
                prompt: "Please, when convenient, show me Jordan Lee's phone number in Contacts.",
                arguments: [
                    "query": .string("Jordan Lee"),
                    "limit": .integer(5),
                ],
                resultText: #"{"ok":true,"contacts":[{"name":"Jordan Lee","phones":["+1 415 555 0142"],"emails":[]}]}"#,
                structuredContent: .object([
                    "ok": .bool(true),
                    "contacts": .array([.object([
                        "name": .string("Jordan Lee"),
                        "phones": .array([.string("+1 415 555 0142")]),
                        "emails": .array([]),
                    ])]),
                ]),
                completion: "Jordan Lee has +1 415 555 0142.",
                expectedProjection: "Contacts (showing up to 5):\n1. Jordan Lee — phones: +1 415 555 0142; emails: none."),
            PlannerVisibleReadOnlyRow(
                toolName: "contacts_search",
                prompt: "Do not show my reminders, but show Jordan Lee's contact.",
                arguments: [
                    "query": .string("Jordan Lee"),
                    "limit": .integer(5),
                ],
                resultText: #"{"ok":true,"contacts":[{"name":"Jordan Lee","phones":["+1 415 555 0142"],"emails":[]}]}"#,
                structuredContent: .object([
                    "ok": .bool(true),
                    "contacts": .array([.object([
                        "name": .string("Jordan Lee"),
                        "phones": .array([.string("+1 415 555 0142")]),
                        "emails": .array([]),
                    ])]),
                ]),
                completion: "Jordan Lee has +1 415 555 0142.",
                expectedProjection: "Contacts (showing up to 5):\n1. Jordan Lee — phones: +1 415 555 0142; emails: none."),
            PlannerVisibleReadOnlyRow(
                toolName: "reminders_list",
                prompt: "Show my incomplete reminders without changing them.",
                arguments: [
                    "include_completed": .bool(false),
                    "limit": .integer(5),
                ],
                resultText: #"{"ok":true,"reminders":[{"title":"Pick up library holds","completed":false,"list":"Errands"}]}"#,
                structuredContent: .object([
                    "ok": .bool(true),
                    "reminders": .array([.object([
                        "title": .string("Pick up library holds"),
                        "completed": .bool(false),
                        "list": .string("Errands"),
                    ])]),
                ]),
                completion: "Pick up library holds is incomplete.",
                expectedProjection: "Reminders (showing up to 5):\n1. Pick up library holds — incomplete; list: Errands."),
            PlannerVisibleReadOnlyRow(
                toolName: "reminders_list",
                prompt: "Please, when convenient, list my incomplete reminders.",
                arguments: [
                    "include_completed": .bool(false),
                    "limit": .integer(5),
                ],
                resultText: #"{"ok":true,"reminders":[{"title":"Pick up library holds","completed":false,"list":"Errands"}]}"#,
                structuredContent: .object([
                    "ok": .bool(true),
                    "reminders": .array([.object([
                        "title": .string("Pick up library holds"),
                        "completed": .bool(false),
                        "list": .string("Errands"),
                    ])]),
                ]),
                completion: "Pick up library holds is incomplete.",
                expectedProjection: "Reminders (showing up to 5):\n1. Pick up library holds — incomplete; list: Errands."),
        ]

        for (index, row) in rows.enumerated() {
            let tool = try makePlannerVisibleReadOnlyTool(row.toolName)
            let planner = SequencedMCPPlanner(steps: [
                .call(
                    toolName: row.toolName,
                    arguments: row.arguments,
                    requiredPromptFragment: nil),
                .completion(
                    row.completion,
                    requiredPromptFragment: row.resultText),
            ])
            let pool = RecordingMCPClientPool(
                tools: [tool, try makeMailTool()],
                resultsByTool: [
                    row.toolName: try MCPToolResult(
                        text: row.resultText,
                        structuredContent: row.structuredContent,
                        isError: false,
                        wasTruncated: false),
                ])
            let fallback = StubVisualExecutor()
            let executor = try await MCPFirstComputerUseExecutor.load(
                binaryURL: URL(fileURLWithPath:
                    "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
                visualFallback: fallback,
                planner: planner,
                clientPool: pool)

            let result = try await executor.execute(
                taskID: "affirmative-private-read-\(index)",
                prompt: row.prompt,
                trustedUserPrompt: row.prompt,
                tools: makeHostTools(),
                progress: { _ in })

            XCTAssertEqual(result, .completed(row.expectedProjection), row.toolName)
            XCTAssertEqual(fallback.callCount, 0, row.toolName)
            let directCalls = await pool.directCalls()
            XCTAssertEqual(directCalls.map(\.toolName), [row.toolName], row.toolName)
        }
    }

    func testEveryPlannerVisibleReadOnlyOperationTraversesProductionExecutor() async throws {
        let rows: [PlannerVisibleReadOnlyRow] = [
            PlannerVisibleReadOnlyRow(
                toolName: "contacts_search",
                prompt: "Find the phone number and email address for Jordan Lee in my Contacts.",
                arguments: [
                    "query": .string("Jordan Lee"),
                    "limit": .integer(5),
                ],
                resultText: #"{"ok":true,"contacts":[{"name":"Jordan Lee","phones":["+1 415 555 0142"],"emails":["jordan.lee@example.invalid"]}]}"#,
                structuredContent: .object([
                    "ok": .bool(true),
                    "contacts": .array([.object([
                        "name": .string("Jordan Lee"),
                        "phones": .array([.string("+1 415 555 0142")]),
                        "emails": .array([.string("jordan.lee@example.invalid")]),
                    ])]),
                ]),
                completion: "Jordan Lee is listed with +1 415 555 0142 and jordan.lee@example.invalid.",
                expectedProjection: "Contacts (showing up to 5):\n1. Jordan Lee — phones: +1 415 555 0142; emails: jordan.lee@example.invalid."),
            PlannerVisibleReadOnlyRow(
                toolName: "reminders_list",
                prompt: "Show my first five incomplete reminders so I can plan this afternoon.",
                arguments: [
                    "include_completed": .bool(false),
                    "limit": .integer(5),
                ],
                resultText: #"{"ok":true,"reminders":[{"title":"Pick up library holds","completed":false,"list":"Errands"}]}"#,
                structuredContent: .object([
                    "ok": .bool(true),
                    "reminders": .array([.object([
                        "title": .string("Pick up library holds"),
                        "completed": .bool(false),
                        "list": .string("Errands"),
                    ])]),
                ]),
                completion: "Your first incomplete reminder is Pick up library holds in Errands.",
                expectedProjection: "Reminders:\n1. Pick up library holds — incomplete; list: Errands."),
            PlannerVisibleReadOnlyRow(
                toolName: "list_shortcuts",
                prompt: "Which Apple Shortcuts are available on this Mac? Do not run one.",
                arguments: [:],
                resultText: #"{"ok":true,"names":["Log Water","Start Focus"],"count":2}"#,
                structuredContent: .object([
                    "ok": .bool(true),
                    "names": .array([.string("Log Water"), .string("Start Focus")]),
                    "count": .integer(2),
                ]),
                completion: "The available Shortcuts are Log Water and Start Focus.",
                expectedProjection: "Available Shortcuts (2):\n1. Log Water\n2. Start Focus"),
            PlannerVisibleReadOnlyRow(
                toolName: "focused_app",
                prompt: "Which Mac app am I currently using?",
                arguments: [:],
                resultText: #"{"ok":true,"app":{"pid":4242,"name":"Notes","bundleIdentifier":"com.apple.Notes","isActive":true}}"#,
                structuredContent: .object([
                    "ok": .bool(true),
                    "app": .object([
                        "pid": .integer(4_242),
                        "name": .string("Notes"),
                        "bundleIdentifier": .string("com.apple.Notes"),
                        "isActive": .bool(true),
                    ]),
                ]),
                completion: "Notes is the currently focused app.",
                expectedProjection: "Focused app: Notes — PID 4242; bundle: com.apple.Notes; active: yes."),
            PlannerVisibleReadOnlyRow(
                toolName: "list_apps",
                prompt: "Which apps are currently running on my Mac?",
                arguments: [:],
                resultText: #"{"ok":true,"apps":[{"pid":4242,"name":"Notes"},{"pid":4343,"name":"Calendar"}]}"#,
                structuredContent: .object([
                    "ok": .bool(true),
                    "apps": .array([
                        .object(["pid": .integer(4_242), "name": .string("Notes")]),
                        .object(["pid": .integer(4_343), "name": .string("Calendar")]),
                    ]),
                ]),
                completion: "Notes and Calendar are currently running.",
                expectedProjection: "Running apps:\n1. Notes — PID 4242.\n2. Calendar — PID 4343."),
            PlannerVisibleReadOnlyRow(
                toolName: "list_windows",
                prompt: "List the open windows so I can find my packing list.",
                arguments: [:],
                resultText: #"{"ok":true,"windows":[{"pid":4242,"index":0,"title":"Packing list"}]}"#,
                structuredContent: .object([
                    "ok": .bool(true),
                    "windows": .array([.object([
                        "pid": .integer(4_242),
                        "index": .integer(0),
                        "title": .string("Packing list"),
                    ])]),
                ]),
                completion: "Notes has an open window titled Packing list.",
                expectedProjection: "Open windows:\n1. Packing list — PID 4242; index 0."),
            PlannerVisibleReadOnlyRow(
                toolName: "permissions_status",
                prompt: "Check whether this Mac is ready for Accessibility computer control.",
                arguments: [:],
                resultText: #"{"ok":true,"accessibility":"granted"}"#,
                structuredContent: .object([
                    "ok": .bool(true),
                    "accessibility": .string("granted"),
                ]),
                completion: "Accessibility access is granted, so this Mac is ready for computer control.",
                expectedProjection: "Accessibility permission: granted."),
        ]
        let expectedReadOnlySurface = MCPFirstComputerUseExecutor
            .structuredToolNames.subtracting([RemoteDesktopMailMCP.toolName])
        XCTAssertEqual(Set(rows.map(\.toolName)), expectedReadOnlySurface)

        for (index, row) in rows.enumerated() {
            let tool = try makePlannerVisibleReadOnlyTool(row.toolName)
            XCTAssertEqual(tool.inputSchema, plannerVisibleReadOnlySchema(row.toolName))
            let planner = SequencedMCPPlanner(steps: [
                .call(
                    toolName: row.toolName,
                    arguments: row.arguments,
                    requiredPromptFragment: nil),
                .completion(
                    row.completion,
                    requiredPromptFragment: row.resultText),
            ])
            let expectedResult = try MCPToolResult(
                text: row.resultText,
                structuredContent: row.structuredContent,
                isError: false,
                wasTruncated: false)
            let pool = RecordingMCPClientPool(
                tools: [tool, try makeMailTool()],
                resultsByTool: [row.toolName: expectedResult])
            let fallback = StubVisualExecutor()
            let executor = try await MCPFirstComputerUseExecutor.load(
                binaryURL: URL(fileURLWithPath:
                    "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
                visualFallback: fallback,
                planner: planner,
                clientPool: pool)
            let taskID = "planner-visible-read-only-\(index)"
            var progress: [String] = []

            let result = try await executor.execute(
                taskID: taskID,
                prompt: row.prompt,
                tools: makeHostTools(),
                progress: { progress.append($0) })

            XCTAssertEqual(
                result,
                .completed(row.expectedProjection),
                row.toolName)
            XCTAssertEqual(fallback.callCount, 0, row.toolName)
            let directCalls = await pool.directCalls()
            XCTAssertEqual(directCalls.count, 1, row.toolName)
            XCTAssertEqual(directCalls.first?.taskID, taskID, row.toolName)
            XCTAssertEqual(directCalls.first?.toolName, row.toolName, row.toolName)
            XCTAssertEqual(directCalls.first?.arguments, row.arguments, row.toolName)
            XCTAssertEqual(directCalls.first?.risk, .readOnly, row.toolName)
            let approvedCalls = await pool.approvedCalls()
            XCTAssertTrue(approvedCalls.isEmpty, row.toolName)
            XCTAssertEqual(planner.completedStepCount, 2, row.toolName)
            XCTAssertEqual(planner.requests.count, 2, row.toolName)
            XCTAssertTrue(
                planner.requests.allSatisfy {
                    Set($0.tools.map(\.toolName)) == [
                        row.toolName, RemoteDesktopMailMCP.toolName,
                    ]
                },
                row.toolName)
            XCTAssertTrue(
                planner.requests[1].prompt.contains(row.resultText),
                "The planner did not consume the exact local result for \(row.toolName)")
            XCTAssertTrue(progress.contains("Checking the local result…"), row.toolName)
        }
    }

    func testPlannerCannotSelectPromptAlternativeOverTypedFocusedApp() async throws {
        let focusedApp = try makePlannerVisibleReadOnlyTool("focused_app")
        let resultText = #"{"ok":true,"app":{"pid":4242,"name":"Notes","bundleIdentifier":"com.apple.Notes","isActive":true}}"#
        let planner = SequencedMCPPlanner(steps: [
            .call(
                toolName: "focused_app",
                arguments: [:],
                requiredPromptFragment: nil),
            .completion(
                "Safari is the currently focused app.",
                requiredPromptFragment: resultText),
        ])
        let pool = RecordingMCPClientPool(
            tools: [focusedApp, try makeMailTool()],
            resultsByTool: [
                "focused_app": try MCPToolResult(
                    text: resultText,
                    structuredContent: .object([
                        "ok": .bool(true),
                        "app": .object([
                            "pid": .integer(4_242),
                            "name": .string("Notes"),
                            "bundleIdentifier": .string("com.apple.Notes"),
                            "isActive": .bool(true),
                        ]),
                    ]),
                    isError: false,
                    wasTruncated: false),
            ])
        let fallback = StubVisualExecutor(
            result: .completed("Visual verification took over."))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "typed-focused-app-prompt-alternative",
            prompt: "Is Notes or Safari the Mac app I am currently using?",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(
            result,
            .completed(
                "Focused app: Notes — PID 4242; bundle: com.apple.Notes; active: yes."))
        XCTAssertEqual(fallback.callCount, 0)
        let directCalls = await pool.directCalls()
        XCTAssertEqual(directCalls.count, 1)
    }

    func testReadOnlyCompletionRequiresSuccessfulUntruncatedStructuredContent() async throws {
        let validContent = MCPJSONValue.object([
            "ok": .bool(true),
            "app": .object([
                "pid": .integer(4_242),
                "name": .string("Notes"),
                "bundleIdentifier": .string("com.apple.Notes"),
                "isActive": .bool(true),
            ]),
        ])
        let cases: [(String, MCPJSONValue?, Bool)] = [
            ("missing typed content", nil, false),
            ("truncated result", validContent, true),
            ("unsuccessful typed content", .object(["ok": .bool(false)]), false),
        ]

        for (label, structuredContent, wasTruncated) in cases {
            let focusedApp = try makePlannerVisibleReadOnlyTool("focused_app")
            let resultText = #"{"ok":true,"app":{"pid":4242,"name":"Notes"}}"#
            let planner = SequencedMCPPlanner(steps: [
                .call(
                    toolName: "focused_app",
                    arguments: [:],
                    requiredPromptFragment: nil),
                .completion(
                    "Notes is focused.",
                    requiredPromptFragment: resultText),
            ])
            let pool = RecordingMCPClientPool(
                tools: [focusedApp, try makeMailTool()],
                resultsByTool: [
                    "focused_app": try MCPToolResult(
                        text: resultText,
                        structuredContent: structuredContent,
                        isError: false,
                        wasTruncated: wasTruncated),
                ])
            let fallback = StubVisualExecutor(
                result: .completed("Visual verification took over."))
            let executor = try await MCPFirstComputerUseExecutor.load(
                binaryURL: URL(fileURLWithPath:
                    "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
                visualFallback: fallback,
                planner: planner,
                clientPool: pool)

            let result = try await executor.execute(
                taskID: "typed-result-precondition-\(label)",
                prompt: "Which app is currently focused?",
                tools: makeHostTools(),
                progress: { _ in })

            XCTAssertEqual(
                result,
                .completed("Visual verification took over."),
                label)
            XCTAssertEqual(fallback.callCount, 1, label)
            let directCalls = await pool.directCalls()
            XCTAssertEqual(directCalls.count, 1, label)
        }
    }

    func testPlannerCannotInvertTypedReminderCompletionPolarity() async throws {
        let reminders = try makePlannerVisibleReadOnlyTool("reminders_list")
        let resultText = #"{"ok":true,"reminders":[{"title":"Submit expense report","completed":false,"list":"Work"}]}"#
        let planner = SequencedMCPPlanner(steps: [
            .call(
                toolName: "reminders_list",
                arguments: [
                    "include_completed": .bool(false),
                    "limit": .integer(5),
                ],
                requiredPromptFragment: nil),
            .completion(
                "Submit expense report is completed in Work.",
                requiredPromptFragment: resultText),
        ])
        let pool = RecordingMCPClientPool(
            tools: [reminders, try makeMailTool()],
            resultsByTool: [
                "reminders_list": try MCPToolResult(
                    text: resultText,
                    structuredContent: .object([
                        "ok": .bool(true),
                        "reminders": .array([.object([
                            "title": .string("Submit expense report"),
                            "completed": .bool(false),
                            "list": .string("Work"),
                        ])]),
                    ]),
                    isError: false,
                    wasTruncated: false),
            ])
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "typed-reminder-polarity",
            prompt: "Which reminders are incomplete in my Work list?",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(
            result,
            .completed(
                "Reminders (showing up to 5):\n1. Submit expense report — incomplete; list: Work."))
        XCTAssertEqual(fallback.callCount, 0)
    }

    func testPlannerCannotRecombineFieldsAcrossTypedContacts() async throws {
        let contacts = try makePlannerVisibleReadOnlyTool("contacts_search")
        let resultText = #"{"ok":true,"contacts":[{"name":"Jordan Lee","phones":["+1 415 555 0142"],"emails":["jordan@example.invalid"]},{"name":"Avery Lee","phones":["+1 212 555 0199"],"emails":["avery@example.invalid"]}]}"#
        let planner = SequencedMCPPlanner(steps: [
            .call(
                toolName: "contacts_search",
                arguments: [
                    "query": .string("Lee"),
                    "limit": .integer(5),
                ],
                requiredPromptFragment: nil),
            .completion(
                "Jordan Lee has +1 212 555 0199 and avery@example.invalid; Avery Lee has +1 415 555 0142 and jordan@example.invalid.",
                requiredPromptFragment: resultText),
        ])
        let pool = RecordingMCPClientPool(
            tools: [contacts, try makeMailTool()],
            resultsByTool: [
                "contacts_search": try MCPToolResult(
                    text: resultText,
                    structuredContent: .object([
                        "ok": .bool(true),
                        "contacts": .array([
                            .object([
                                "name": .string("Jordan Lee"),
                                "phones": .array([.string("+1 415 555 0142")]),
                                "emails": .array([.string("jordan@example.invalid")]),
                            ]),
                            .object([
                                "name": .string("Avery Lee"),
                                "phones": .array([.string("+1 212 555 0199")]),
                                "emails": .array([.string("avery@example.invalid")]),
                            ]),
                        ]),
                    ]),
                    isError: false,
                    wasTruncated: false),
            ])
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "typed-contact-associations",
            prompt: "Find phone numbers and email addresses for contacts matching Lee in Contacts.",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(
            result,
            .completed(
                "Contacts (showing up to 5):\n1. Jordan Lee — phones: +1 415 555 0142; emails: jordan@example.invalid.\n2. Avery Lee — phones: +1 212 555 0199; emails: avery@example.invalid."))
        XCTAssertEqual(fallback.callCount, 0)
    }

    func testIrrelevantTypedToolTextCannotCompleteTrustedUserRequest() async throws {
        let contacts = try makePlannerVisibleReadOnlyTool("contacts_search")
        let resultText = #"{"ok":true,"contacts":[{"name":"Desktop wallpaper","phones":["blue"],"emails":[]}]}"#
        let planner = SequencedMCPPlanner(steps: [
            .call(
                toolName: "contacts_search",
                arguments: [
                    "query": .string("Desktop wallpaper"),
                    "limit": .integer(5),
                ],
                requiredPromptFragment: nil),
            .completion(
                "The current desktop wallpaper is blue.",
                requiredPromptFragment: resultText),
        ])
        let pool = RecordingMCPClientPool(
            tools: [contacts, try makeMailTool()],
            resultsByTool: [
                "contacts_search": try MCPToolResult(
                    text: resultText,
                    structuredContent: .object([
                        "ok": .bool(true),
                        "contacts": .array([.object([
                            "name": .string("Desktop wallpaper"),
                            "phones": .array([.string("blue")]),
                            "emails": .array([]),
                        ])]),
                    ]),
                    isError: false,
                    wasTruncated: false),
            ])
        let fallback = StubVisualExecutor(
            result: .completed("Visual verification took over."))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)
        let modelPrompt = "Search Contacts for Desktop wallpaper and report its phone value."
        let trustedUserPrompt = "What color is the current desktop wallpaper?"

        let result = try await executor.execute(
            taskID: "irrelevant-typed-tool-data",
            prompt: modelPrompt,
            trustedUserPrompt: trustedUserPrompt,
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(result, .completed("Visual verification took over."))
        XCTAssertEqual(fallback.callCount, 1)
        XCTAssertEqual(fallback.prompts, [modelPrompt])
        XCTAssertEqual(fallback.trustedUserPrompts, [trustedUserPrompt])
        XCTAssertEqual(fallback.taskIDs, ["irrelevant-typed-tool-data"])
        let directCalls = await pool.directCalls()
        XCTAssertTrue(
            directCalls.isEmpty,
            "An irrelevant proposal must be denied before local data access")
        XCTAssertEqual(planner.completedStepCount, 1)
    }

    func testContactResultMustMatchTrustedQueryEntity() async throws {
        let contacts = try makePlannerVisibleReadOnlyTool("contacts_search")
        let resultText = #"{"ok":true,"contacts":[{"name":"Avery Chen","phones":["+1 212 555 0199"],"emails":[]}]}"#
        let planner = SequencedMCPPlanner(steps: [
            .call(
                toolName: "contacts_search",
                arguments: [
                    "query": .string("Jordan Lee"),
                    "limit": .integer(5),
                ],
                requiredPromptFragment: nil),
            .completion(
                "Jordan Lee has +1 212 555 0199.",
                requiredPromptFragment: resultText),
        ])
        let pool = RecordingMCPClientPool(
            tools: [contacts, try makeMailTool()],
            resultsByTool: [
                "contacts_search": try MCPToolResult(
                    text: resultText,
                    structuredContent: .object([
                        "ok": .bool(true),
                        "contacts": .array([.object([
                            "name": .string("Avery Chen"),
                            "phones": .array([.string("+1 212 555 0199")]),
                            "emails": .array([]),
                        ])]),
                    ]),
                    isError: false,
                    wasTruncated: false),
            ])
        let fallback = StubVisualExecutor(
            result: .completed("Visual verification took over."))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "contact-query-result-mismatch",
            prompt: "Find Jordan Lee's phone number in Contacts.",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(result, .completed("Visual verification took over."))
        XCTAssertEqual(fallback.callCount, 1)
        let directCalls = await pool.directCalls()
        XCTAssertEqual(directCalls.count, 1)
        XCTAssertEqual(planner.completedStepCount, 1)
    }

    func testIncompleteReminderIntentRejectsIncludeCompletedInversionBeforeRead() async throws {
        let reminders = try makePlannerVisibleReadOnlyTool("reminders_list")
        let planner = SequencedMCPPlanner(steps: [
            .call(
                toolName: "reminders_list",
                arguments: [
                    "include_completed": .bool(true),
                    "limit": .integer(5),
                ],
                requiredPromptFragment: nil),
        ])
        let pool = RecordingMCPClientPool(
            tools: [reminders, try makeMailTool()],
            resultsByTool: [:])
        let fallback = StubVisualExecutor(
            result: .completed("Visual verification took over."))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "reminder-completion-filter-inversion",
            prompt: "Show my first five incomplete reminders.",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(result, .completed("Visual verification took over."))
        XCTAssertEqual(fallback.callCount, 1)
        let directCalls = await pool.directCalls()
        XCTAssertTrue(directCalls.isEmpty)
    }

    func testNamedAppWindowReadRejectsArbitraryPIDWithoutTypedAppProof() async throws {
        let windows = try makePlannerVisibleReadOnlyTool("list_windows")
        let planner = SequencedMCPPlanner(steps: [
            .call(
                toolName: "list_windows",
                arguments: ["pid": .integer(4_242)],
                requiredPromptFragment: nil),
        ])
        let pool = RecordingMCPClientPool(
            tools: [windows, try makeMailTool()],
            resultsByTool: [:])
        let fallback = StubVisualExecutor(
            result: .completed("Visual verification took over."))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "named-window-unproved-pid",
            prompt: "List the open Notes windows.",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(result, .completed("Visual verification took over."))
        XCTAssertEqual(fallback.callCount, 1)
        let directCalls = await pool.directCalls()
        XCTAssertTrue(directCalls.isEmpty)
    }

    func testNamedAppWindowReadUsesTypedAppInventoryAsMinimalDependency() async throws {
        let apps = try makePlannerVisibleReadOnlyTool("list_apps")
        let windows = try makePlannerVisibleReadOnlyTool("list_windows")
        let appsText = #"{"ok":true,"apps":[{"pid":4242,"name":"Notes"},{"pid":4343,"name":"Calendar"}]}"#
        let windowsText = #"{"ok":true,"pid":4242,"windows":[{"pid":4242,"index":0,"title":"Packing list"}]}"#
        let planner = SequencedMCPPlanner(steps: [
            .call(
                toolName: "list_apps",
                arguments: [:],
                requiredPromptFragment: nil),
            .call(
                toolName: "list_windows",
                arguments: ["pid": .integer(4_242)],
                requiredPromptFragment: appsText),
            .completion(
                "Notes has a Packing list window.",
                requiredPromptFragment: windowsText),
        ])
        let pool = RecordingMCPClientPool(
            tools: [apps, windows, try makeMailTool()],
            resultsByTool: [
                "list_apps": try MCPToolResult(
                    text: appsText,
                    structuredContent: .object([
                        "ok": .bool(true),
                        "apps": .array([
                            .object([
                                "pid": .integer(4_242),
                                "name": .string("Notes"),
                            ]),
                            .object([
                                "pid": .integer(4_343),
                                "name": .string("Calendar"),
                            ]),
                        ]),
                    ]),
                    isError: false,
                    wasTruncated: false),
                "list_windows": try MCPToolResult(
                    text: windowsText,
                    structuredContent: .object([
                        "ok": .bool(true),
                        "pid": .integer(4_242),
                        "windows": .array([.object([
                            "pid": .integer(4_242),
                            "index": .integer(0),
                            "title": .string("Packing list"),
                        ])]),
                    ]),
                    isError: false,
                    wasTruncated: false),
            ])
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "named-window-typed-pid-proof",
            prompt: "List the open Notes windows.",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(
            result,
            .completed(
                "Open windows for Notes:\n1. Packing list — PID 4242; index 0."))
        XCTAssertEqual(fallback.callCount, 0)
        let directCalls = await pool.directCalls()
        XCTAssertEqual(
            directCalls.map(\.toolName),
            ["list_apps", "list_windows"])
    }

    func testNamedWindowPromptFormsRejectUnscopedReadsWhileGenericFormsRemainUnscoped() async throws {
        let windows = try makePlannerVisibleReadOnlyTool("list_windows")
        let namedPrompts = [
            "List windows for Notes.",
            "Which windows does Notes have?",
            "Notes open windows.",
        ]
        for (index, prompt) in namedPrompts.enumerated() {
            let planner = SequencedMCPPlanner(steps: [
                .call(
                    toolName: "list_windows",
                    arguments: [:],
                    requiredPromptFragment: nil),
            ])
            let pool = RecordingMCPClientPool(
                tools: [windows, try makeMailTool()],
                resultsByTool: [:])
            let fallback = StubVisualExecutor(
                result: .completed("Visual verification took over."))
            let executor = try await MCPFirstComputerUseExecutor.load(
                binaryURL: URL(fileURLWithPath:
                    "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
                visualFallback: fallback,
                planner: planner,
                clientPool: pool)

            let result = try await executor.execute(
                taskID: "named-window-form-\(index)",
                prompt: prompt,
                tools: makeHostTools(),
                progress: { _ in })

            XCTAssertEqual(
                result,
                .completed("Visual verification took over."),
                prompt)
            XCTAssertEqual(fallback.callCount, 1, prompt)
            let directCalls = await pool.directCalls()
            XCTAssertTrue(
                directCalls.isEmpty,
                "Named request executed an unscoped window read: \(prompt)")
        }

        let genericPrompts = [
            "List all windows.",
            "List current windows.",
            "List open windows.",
        ]
        let windowsText = #"{"ok":true,"windows":[]}"#
        for (index, prompt) in genericPrompts.enumerated() {
            let planner = SequencedMCPPlanner(steps: [
                .call(
                    toolName: "list_windows",
                    arguments: [:],
                    requiredPromptFragment: nil),
                .completion(
                    "No windows are open.",
                    requiredPromptFragment: windowsText),
            ])
            let pool = RecordingMCPClientPool(
                tools: [windows, try makeMailTool()],
                resultsByTool: [
                    "list_windows": try MCPToolResult(
                        text: windowsText,
                        structuredContent: .object([
                            "ok": .bool(true),
                            "windows": .array([]),
                        ]),
                        isError: false,
                        wasTruncated: false),
                ])
            let fallback = StubVisualExecutor()
            let executor = try await MCPFirstComputerUseExecutor.load(
                binaryURL: URL(fileURLWithPath:
                    "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
                visualFallback: fallback,
                planner: planner,
                clientPool: pool)

            let result = try await executor.execute(
                taskID: "generic-window-form-\(index)",
                prompt: prompt,
                tools: makeHostTools(),
                progress: { _ in })

            XCTAssertEqual(
                result,
                .completed("No matching open windows were found."),
                prompt)
            XCTAssertEqual(fallback.callCount, 0, prompt)
            let directCalls = await pool.directCalls()
            XCTAssertEqual(directCalls.map(\.toolName), ["list_windows"], prompt)
        }
    }

    func testNamedWindowPIDProofRejectsAmbiguousDuplicateApplicationInventory() async throws {
        let apps = try makePlannerVisibleReadOnlyTool("list_apps")
        let windows = try makePlannerVisibleReadOnlyTool("list_windows")
        let appsText = #"{"ok":true,"apps":[{"pid":4242,"name":"Notes"},{"pid":4343,"name":"Notes"}]}"#
        let planner = SequencedMCPPlanner(steps: [
            .call(
                toolName: "list_apps",
                arguments: [:],
                requiredPromptFragment: nil),
            .call(
                toolName: "list_windows",
                arguments: ["pid": .integer(4_242)],
                requiredPromptFragment: appsText),
        ])
        let pool = RecordingMCPClientPool(
            tools: [apps, windows, try makeMailTool()],
            resultsByTool: [
                "list_apps": try MCPToolResult(
                    text: appsText,
                    structuredContent: .object([
                        "ok": .bool(true),
                        "apps": .array([
                            .object([
                                "pid": .integer(4_242),
                                "name": .string("Notes"),
                            ]),
                            .object([
                                "pid": .integer(4_343),
                                "name": .string("Notes"),
                            ]),
                        ]),
                    ]),
                    isError: false,
                    wasTruncated: false),
            ])
        let fallback = StubVisualExecutor(
            result: .completed("Visual verification took over."))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "ambiguous-named-window-pid-proof",
            prompt: "List windows for Notes.",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(result, .completed("Visual verification took over."))
        XCTAssertEqual(fallback.callCount, 1)
        let directCalls = await pool.directCalls()
        XCTAssertEqual(
            directCalls.map(\.toolName),
            ["list_apps"],
            "An ambiguous app-name-to-PID mapping must not authorize list_windows")
    }

    func testEveryContactValueRequestRejectsFinitePlannerLimitBeforeLocalAccess() async throws {
        let contacts = try makePlannerVisibleReadOnlyTool("contacts_search")
        let phones = (1 ... 20).map {
            "Jordan-number-\($0)-" + String(repeating: "9", count: 100)
        }
        let resultText = "typed contact result with many phone values"
        let planner = SequencedMCPPlanner(steps: [
            .call(
                toolName: "contacts_search",
                arguments: [
                    "query": .string("Jordan Lee"),
                    "limit": .integer(5),
                ],
                requiredPromptFragment: nil),
            .completion(
                "Here are every one of Jordan's phone numbers.",
                requiredPromptFragment: resultText),
        ])
        let pool = RecordingMCPClientPool(
            tools: [contacts, try makeMailTool()],
            resultsByTool: [
                "contacts_search": try MCPToolResult(
                    text: resultText,
                    structuredContent: .object([
                        "ok": .bool(true),
                        "contacts": .array([.object([
                            "name": .string("Jordan Lee"),
                            "phones": .array(phones.map { .string($0) }),
                            "emails": .array([]),
                        ])]),
                    ]),
                    isError: false,
                    wasTruncated: false),
            ])
        let fallback = StubVisualExecutor(
            result: .completed("Visual verification took over."))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "exhaustive-contact-values-over-bound",
            prompt: "Find every phone number for Jordan Lee in Contacts.",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(result, .completed("Visual verification took over."))
        XCTAssertEqual(fallback.callCount, 1)
        let directCalls = await pool.directCalls()
        XCTAssertTrue(
            directCalls.isEmpty,
            "A finite contact limit cannot prove an every-value request")
        XCTAssertEqual(
            planner.completedStepCount,
            1,
            "The proposed bounded read should be rejected before execution")
    }

    func testEveryReminderRequestRejectsFinitePlannerLimitBeforeLocalAccess() async throws {
        let reminders = try makePlannerVisibleReadOnlyTool("reminders_list")
        let reminderValues: [MCPJSONValue] = (1 ... 30).map { index in
            .object([
                "title": .string(
                    "Incomplete reminder \(index) "
                        + String(repeating: "x", count: 70)),
                "completed": .bool(false),
                "list": .string("Work"),
            ])
        }
        let resultText = "typed reminder result with many rows"
        let planner = SequencedMCPPlanner(steps: [
            .call(
                toolName: "reminders_list",
                arguments: [
                    "include_completed": .bool(false),
                    "limit": .integer(1),
                ],
                requiredPromptFragment: nil),
            .completion(
                "Here is every incomplete reminder.",
                requiredPromptFragment: resultText),
        ])
        let pool = RecordingMCPClientPool(
            tools: [reminders, try makeMailTool()],
            resultsByTool: [
                "reminders_list": try MCPToolResult(
                    text: resultText,
                    structuredContent: .object([
                        "ok": .bool(true),
                        "reminders": .array(reminderValues),
                    ]),
                    isError: false,
                    wasTruncated: false),
            ])
        let fallback = StubVisualExecutor(
            result: .completed("Visual verification took over."))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "exhaustive-reminder-rows-over-bound",
            prompt: "Show every incomplete reminder.",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(result, .completed("Visual verification took over."))
        XCTAssertEqual(fallback.callCount, 1)
        let directCalls = await pool.directCalls()
        XCTAssertTrue(
            directCalls.isEmpty,
            "A finite reminder limit cannot prove an every-row request")
        XCTAssertEqual(planner.completedStepCount, 1)
    }

    func testAllWindowRequestFailsClosedWhenBoundedProjectionCannotIncludeEveryRow() async throws {
        let windows = try makePlannerVisibleReadOnlyTool("list_windows")
        let windowValues: [MCPJSONValue] = (1 ... 30).map { index in
            .object([
                "pid": .integer(4_000 + index),
                "index": .integer(index - 1),
                "title": .string(
                    "Window \(index) " + String(repeating: "x", count: 70)),
            ])
        }
        let resultText = "typed window result with many rows"
        let planner = SequencedMCPPlanner(steps: [
            .call(
                toolName: "list_windows",
                arguments: [:],
                requiredPromptFragment: nil),
            .completion(
                "Here are all windows.",
                requiredPromptFragment: resultText),
        ])
        let pool = RecordingMCPClientPool(
            tools: [windows, try makeMailTool()],
            resultsByTool: [
                "list_windows": try MCPToolResult(
                    text: resultText,
                    structuredContent: .object([
                        "ok": .bool(true),
                        "windows": .array(windowValues),
                    ]),
                    isError: false,
                    wasTruncated: false),
            ])
        let fallback = StubVisualExecutor(
            result: .completed("Visual verification took over."))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "all-window-rows-over-projection-bound",
            prompt: "List all windows.",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(result, .completed("Visual verification took over."))
        XCTAssertEqual(fallback.callCount, 1)
        let directCalls = await pool.directCalls()
        XCTAssertEqual(directCalls.map(\.toolName), ["list_windows"])
        XCTAssertEqual(
            planner.completedStepCount,
            1,
            "A partial host projection must never reach TASK_COMPLETE")
    }

    func testContactCompletionRequiresEveryRequestedPerson() async throws {
        let prompt = "Find Jordan Lee and Avery Chen in Contacts."
        for query in ["Jordan Lee", "Avery Chen"] {
            let observed = try await exerciseContactRequirements(prompt: prompt, queries: [query])
            XCTAssertEqual(observed.result, .clarificationRequired("Unfulfilled task reached fallback."))
            XCTAssertEqual(observed.readQueries, [query])
            XCTAssertEqual(observed.plannerSteps, 2)
            XCTAssertEqual(observed.fallbackPrompts, [prompt])
        }
    }

    func testContactCompletionProjectsAllEntitiesInRequestOrder() async throws {
        let prompts = [
            "Find Jordan Lee and Avery Chen in Contacts.",
            "Find the phone number and email address for Jordan Lee and Avery Chen in my Contacts.",
            "Show Jordan Lee's and Avery Chen's phone numbers in Contacts.",
            "Find Jordan Lee in Contacts and show Avery Chen's phone number in Contacts.",
        ]
        for prompt in prompts {
            let observed = try await exerciseContactRequirements(
                prompt: prompt, queries: ["Avery Chen", "Jordan Lee"])
            XCTAssertEqual(observed.result, .completed(
                "Contacts query: Jordan Lee\nContacts (showing up to 5):\n1. Jordan Lee — phones: +1 415 555 0142; emails: none.\n\nContacts query: Avery Chen\nContacts (showing up to 5):\n1. Avery Chen — phones: +1 415 555 0199; emails: none."), prompt)
            XCTAssertEqual(observed.readQueries, ["Avery Chen", "Jordan Lee"], prompt)
            XCTAssertEqual(observed.plannerSteps, 3, prompt)
            XCTAssertTrue(observed.fallbackPrompts.isEmpty, prompt)
            XCTAssertTrue(observed.initialPlannerPrompt.contains(
                #"["Jordan Lee","Avery Chen"]"#), prompt)
        }
    }

    func testContactCompletionLabelsWhichRequestedEntityHasNoMatches() async throws {
        let observed = try await exerciseContactRequirements(
            prompt: "Find Jordan Lee and Avery Chen in Contacts.",
            queries: ["Jordan Lee", "Avery Chen"], emptyQueries: ["Avery Chen"])
        XCTAssertEqual(observed.result, .completed(
            "Contacts query: Jordan Lee\nContacts (showing up to 5):\n1. Jordan Lee — phones: +1 415 555 0142; emails: none.\n\nContacts query: Avery Chen\nNo matching contacts were found."))
        XCTAssertEqual(observed.readQueries, ["Jordan Lee", "Avery Chen"])
        XCTAssertTrue(observed.fallbackPrompts.isEmpty)
    }

    func testCompiledContactEntitiesRejectPartialOrPunctuationChangedQueriesBeforeAccess() async throws {
        for row in [
            (prompt: "Find Jordan Lee and Avery Chen in Contacts.", query: "Lee"),
            (prompt: "Find Ann-Marie Lee in Contacts.", query: "Ann Marie Lee"),
        ] {
            let observed = try await exerciseContactRequirements(
                prompt: row.prompt, queries: [row.query])
            XCTAssertEqual(observed.result, .clarificationRequired("Unfulfilled task reached fallback."))
            XCTAssertTrue(observed.readQueries.isEmpty, row.prompt)
            XCTAssertEqual(observed.plannerSteps, 1, row.prompt)
            XCTAssertEqual(observed.fallbackPrompts, [row.prompt])
        }
    }

    func testUncompiledContactEntityClausesCannotBecomePartialCompletion() async throws {
        for prompt in [
            "Find Jordan Lee and Avery Chen or someone else in Contacts.",
            "Find Jordan Lee in Contacts. Then find Avery Chen.",
            "Find Jordan Lee's phone number and Avery Chen's email address in Contacts.",
            "Find Jordan Lee and Avery Chen in Contacts without showing Avery Chen.",
        ] {
            let observed = try await exerciseContactRequirements(prompt: prompt, queries: ["Jordan Lee"])
            XCTAssertEqual(observed.result, .clarificationRequired("Unfulfilled task reached fallback."), prompt)
            XCTAssertEqual(observed.readQueries, ["Jordan Lee"], prompt)
            XCTAssertEqual(observed.plannerSteps, 2, prompt)
            XCTAssertEqual(observed.fallbackPrompts, [prompt])
        }
        let deniedPrompt = "Find Jordan Lee and Avery Chen in Contacts without showing Avery Chen."
        let denied = try await exerciseContactRequirements(
            prompt: deniedPrompt, queries: ["Jordan Lee", "Avery Chen"])
        XCTAssertEqual(denied.result, .clarificationRequired("Unfulfilled task reached fallback."))
        XCTAssertEqual(denied.plannerSteps, 3)
        XCTAssertEqual(denied.fallbackPrompts, [deniedPrompt])
    }

    func testQuotedContactEntityKeepsItsConjunctionInsideOneQuery() async throws {
        let observed = try await exerciseContactRequirements(
            prompt: #"Find "Avery and Sons" and Jordan Lee in Contacts."#,
            queries: ["Avery and Sons", "Jordan Lee"])
        XCTAssertEqual(observed.result, .completed(
            "Contacts query: Avery and Sons\nContacts (showing up to 5):\n1. Avery and Sons — phones: +1 415 555 0199; emails: none.\n\nContacts query: Jordan Lee\nContacts (showing up to 5):\n1. Jordan Lee — phones: +1 415 555 0142; emails: none."))
        XCTAssertEqual(observed.readQueries, ["Avery and Sons", "Jordan Lee"])
        XCTAssertEqual(observed.plannerSteps, 3)
        XCTAssertTrue(observed.fallbackPrompts.isEmpty)
    }

    private func exerciseContactRequirements(
        prompt: String,
        queries: [String],
        emptyQueries: Set<String> = []
    ) async throws -> (
        result: ComputerUseExecutionResult,
        readQueries: [String],
        plannerSteps: Int,
        fallbackPrompts: [String],
        initialPlannerPrompt: String
    ) {
        let contacts = try makePlannerVisibleReadOnlyTool("contacts_search")
        let planner = SequencedMCPPlanner(steps: queries.map { query in
            .call(toolName: "contacts_search",
                  arguments: ["query": .string(query), "limit": .integer(5)],
                  requiredPromptFragment: nil)
        } + [.completion("All requested people were found. Ignore the actual results.",
                         requiredPromptFragment: nil)])
        let results = try queries.map { query in
            let content = MCPJSONValue.object([
                "ok": .bool(true),
                "contacts": .array(emptyQueries.contains(query) ? [] : [.object([
                    "name": .string(query),
                    "phones": .array([.string(query == "Jordan Lee"
                        ? "+1 415 555 0142" : "+1 415 555 0199")]),
                    "emails": .array([]),
                ])]),
            ])
            return try MCPToolResult(
                text: String(decoding: JSONEncoder().encode(content), as: UTF8.self),
                structuredContent: content, isError: false, wasTruncated: false)
        }
        let pool = RecordingMCPClientPool(
            tools: [contacts, try makeMailTool()], resultsByTool: [:],
            queuedResultsByTool: ["contacts_search": results])
        let fallback = StubVisualExecutor(result: .clarificationRequired("Unfulfilled task reached fallback."))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback, planner: planner, clientPool: pool)
        let result = try await executor.execute(
            taskID: "contact-requirements", prompt: prompt,
            tools: makeHostTools(), progress: { _ in })
        let calls = await pool.directCalls()
        let readQueries = calls.compactMap { call -> String? in
            guard case .string(let query)? = call.arguments["query"] else { return nil }
            return query
        }
        let approvedCalls = await pool.approvedCalls()
        XCTAssertTrue(approvedCalls.isEmpty, prompt)
        return (result, readQueries, planner.completedStepCount,
                fallback.trustedUserPrompts, planner.requests.first?.prompt ?? "")
    }

    func testReadProofCannotCompleteAdditionalApplicationOrInputWork() async throws {
        let operations = [
            "open Notes", "activate Notes", "launch Notes", "close Notes",
            "quit Notes", "switch to Notes", "click the Search button",
            "type \"hello\" into the focused field", "press Return",
            "scroll down", "drag the window", "resize the window",
            "copy the phone number", "paste it into Notes",
            "save it to a file", "print the result",
        ]
        for operation in operations {
            let prompt = "Find Jordan Lee's phone number in Contacts and \(operation)."
            try await assertContactReadCompletion(
                prompt: prompt,
                trustedPrompt: prompt,
                expectsFallback: true)
        }
        // Separate sentences and an ordinary polite question still ask for work.
        for suffix in ["Open Notes.", "Could you open Notes?"] {
            let prompt = "Find Jordan Lee's phone number in Contacts. \(suffix)"
            try await assertContactReadCompletion(
                prompt: prompt,
                trustedPrompt: prompt,
                expectsFallback: true)
        }
    }

    func testReadCompletionPreservesNegatedAndQuotedActionWords() async throws {
        for suffix in [
            "without editing the contact.",
            "and do not open Notes.",
            ". Do not, even after the lookup, open Notes.",
            ". The quoted label is \"open Notes\".",
        ] {
            let prompt = "Find Jordan Lee's phone number in Contacts \(suffix)"
            try await assertContactReadCompletion(
                prompt: prompt,
                trustedPrompt: prompt,
                expectsFallback: false)
        }
    }

    func testReadCompletionUsesCurrentInstructionForAdditionalWork() async throws {
        let readPrompt = "Find Jordan Lee's phone number in Contacts."
        let compoundPrompt = "Find Jordan Lee's phone number in Contacts and open Notes."
        try await assertContactReadCompletion(
            prompt: readPrompt,
            trustedPrompt: compoundPrompt,
            expectsFallback: true)
        try await assertContactReadCompletion(
            prompt: "Earlier request: open Notes. Current request: \(readPrompt)",
            trustedPrompt: readPrompt,
            expectsFallback: false)
    }

    func testReadCompletionDistinguishesOpenWindowInventoryFromOpeningWindows() async throws {
        let rows: [(prompt: String, expectsFallback: Bool)] = [
            ("List open windows.", false),
            ("Please show all open windows.", false),
            ("Could you list the currently open windows?", false),
            ("Please list open windows and open Notes.", true),
            ("Please list open windows. Open Notes.", true),
            ("Please list\nopen windows.", true),
        ]
        for row in rows {
            let tool = try makePlannerVisibleReadOnlyTool("list_windows")
            let resultText = #"{"ok":true,"windows":[{"pid":4242,"index":0,"title":"Packing list"}]}"#
            let planner = SequencedMCPPlanner(steps: [
                .call(toolName: "list_windows", arguments: [:], requiredPromptFragment: nil),
                .completion("Everything is done.", requiredPromptFragment: resultText),
            ])
            let pool = RecordingMCPClientPool(
                tools: [tool, try makeMailTool()],
                resultsByTool: [
                    "list_windows": try MCPToolResult(
                        text: resultText,
                        structuredContent: .object([
                            "ok": .bool(true),
                            "windows": .array([.object([
                                "pid": .integer(4_242),
                                "index": .integer(0),
                                "title": .string("Packing list"),
                            ])]),
                        ]),
                        isError: false,
                        wasTruncated: false),
                ])
            let fallbackResult = ComputerUseExecutionResult.clarificationRequired(
                "Fixture fallback received the full request.")
            let fallback = StubVisualExecutor(result: fallbackResult)
            let executor = try await MCPFirstComputerUseExecutor.load(
                binaryURL: URL(fileURLWithPath:
                    "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
                visualFallback: fallback,
                planner: planner,
                clientPool: pool)
            let result = try await executor.execute(
                taskID: "read-completion-open-windows",
                prompt: row.prompt,
                tools: makeHostTools(),
                progress: { _ in })

            XCTAssertEqual(result, row.expectsFallback ? fallbackResult : .completed(
                "Open windows:\n1. Packing list — PID 4242; index 0."), row.prompt)
            XCTAssertEqual(fallback.callCount, row.expectsFallback ? 1 : 0, row.prompt)
            XCTAssertEqual(fallback.trustedUserPrompts,
                           row.expectsFallback ? [row.prompt] : [], row.prompt)
            let directCalls = await pool.directCalls()
            XCTAssertEqual(directCalls.map(\.toolName), ["list_windows"], row.prompt)
            let approvedCalls = await pool.approvedCalls()
            XCTAssertTrue(approvedCalls.isEmpty, row.prompt)
            XCTAssertEqual(planner.completedStepCount, 2, row.prompt)
        }
    }

    private func assertContactReadCompletion(
        prompt: String,
        trustedPrompt: String,
        expectsFallback: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let contacts = try makePlannerVisibleReadOnlyTool("contacts_search")
        let resultText = #"{"ok":true,"contacts":[{"name":"Jordan Lee","phones":["+1 415 555 0142"],"emails":[]}]}"#
        let planner = SequencedMCPPlanner(steps: [
            .call(
                toolName: "contacts_search",
                arguments: ["query": .string("Jordan Lee"), "limit": .integer(5)],
                requiredPromptFragment: nil),
            .completion("Everything is done.", requiredPromptFragment: resultText),
        ])
        let pool = RecordingMCPClientPool(
            tools: [contacts, try makeMailTool()],
            resultsByTool: [
                "contacts_search": try MCPToolResult(
                    text: resultText,
                    structuredContent: .object([
                        "ok": .bool(true),
                        "contacts": .array([.object([
                            "name": .string("Jordan Lee"),
                            "phones": .array([.string("+1 415 555 0142")]),
                            "emails": .array([]),
                        ])]),
                    ]),
                    isError: false,
                    wasTruncated: false),
            ])
        let fallbackResult = ComputerUseExecutionResult.clarificationRequired(
            "Fixture fallback received the full request.")
        let fallback = StubVisualExecutor(result: fallbackResult)
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)
        let result = try await executor.execute(
            taskID: "read-completion-additional-work",
            prompt: prompt,
            trustedUserPrompt: trustedPrompt,
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(result, expectsFallback ? fallbackResult : .completed(
            "Contacts (showing up to 5):\n1. Jordan Lee — phones: +1 415 555 0142; emails: none."),
            trustedPrompt, file: file, line: line)
        XCTAssertEqual(fallback.callCount, expectsFallback ? 1 : 0,
                       trustedPrompt, file: file, line: line)
        XCTAssertEqual(fallback.prompts, expectsFallback ? [prompt] : [],
                       trustedPrompt, file: file, line: line)
        XCTAssertEqual(fallback.trustedUserPrompts, expectsFallback ? [trustedPrompt] : [],
                       trustedPrompt, file: file, line: line)
        XCTAssertEqual(fallback.taskIDs, expectsFallback ? ["read-completion-additional-work"] : [],
                       trustedPrompt, file: file, line: line)
        let directCalls = await pool.directCalls()
        XCTAssertEqual(directCalls.map(\.toolName), ["contacts_search"],
                       trustedPrompt, file: file, line: line)
        let approvedCalls = await pool.approvedCalls()
        XCTAssertTrue(approvedCalls.isEmpty, trustedPrompt, file: file, line: line)
        XCTAssertEqual(planner.completedStepCount, 2, trustedPrompt, file: file, line: line)
    }

    func testTwoDomainPromptCannotCompleteFromOnlyOneDomain() async throws {
        let contacts = try makePlannerVisibleReadOnlyTool("contacts_search")
        let resultText = #"{"ok":true,"contacts":[{"name":"Jordan Lee","phones":["+1 415 555 0142"],"emails":[]}]}"#
        let planner = SequencedMCPPlanner(steps: [
            .call(
                toolName: "contacts_search",
                arguments: [
                    "query": .string("Jordan Lee"),
                    "limit": .integer(5),
                ],
                requiredPromptFragment: nil),
            .completion(
                "Jordan Lee has +1 415 555 0142 and there are no incomplete reminders.",
                requiredPromptFragment: resultText),
        ])
        let pool = RecordingMCPClientPool(
            tools: [contacts, try makeMailTool()],
            resultsByTool: [
                "contacts_search": try MCPToolResult(
                    text: resultText,
                    structuredContent: .object([
                        "ok": .bool(true),
                        "contacts": .array([.object([
                            "name": .string("Jordan Lee"),
                            "phones": .array([.string("+1 415 555 0142")]),
                            "emails": .array([]),
                        ])]),
                    ]),
                    isError: false,
                    wasTruncated: false),
            ])
        let fallback = StubVisualExecutor(
            result: .completed("Visual verification took over."))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "multi-domain-partial-proof",
            prompt: "Find Jordan Lee's phone number in Contacts and show my incomplete reminders.",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(result, .completed("Visual verification took over."))
        XCTAssertEqual(fallback.callCount, 1)
        let directCalls = await pool.directCalls()
        XCTAssertEqual(directCalls.count, 1)
        XCTAssertEqual(planner.completedStepCount, 2)
    }

    func testTwoDomainPromptCombinesOnlyHostProjectedProofs() async throws {
        let contacts = try makePlannerVisibleReadOnlyTool("contacts_search")
        let reminders = try makePlannerVisibleReadOnlyTool("reminders_list")
        let contactsText = #"{"ok":true,"contacts":[{"name":"Jordan Lee","phones":["+1 415 555 0142"],"emails":[]}]}"#
        let remindersText = #"{"ok":true,"reminders":[{"title":"Pick up library holds","completed":false,"list":"Errands"}]}"#
        let planner = SequencedMCPPlanner(steps: [
            .call(
                toolName: "contacts_search",
                arguments: [
                    "query": .string("Jordan Lee"),
                    "limit": .integer(5),
                ],
                requiredPromptFragment: nil),
            .call(
                toolName: "reminders_list",
                arguments: [
                    "include_completed": .bool(false),
                    "limit": .integer(5),
                ],
                requiredPromptFragment: contactsText),
            .completion(
                "Jordan Lee has +1 415 555 0142; Pick up library holds is incomplete.",
                requiredPromptFragment: remindersText),
        ])
        let pool = RecordingMCPClientPool(
            tools: [contacts, reminders, try makeMailTool()],
            resultsByTool: [
                "contacts_search": try MCPToolResult(
                    text: contactsText,
                    structuredContent: .object([
                        "ok": .bool(true),
                        "contacts": .array([.object([
                            "name": .string("Jordan Lee"),
                            "phones": .array([.string("+1 415 555 0142")]),
                            "emails": .array([]),
                        ])]),
                    ]),
                    isError: false,
                    wasTruncated: false),
                "reminders_list": try MCPToolResult(
                    text: remindersText,
                    structuredContent: .object([
                        "ok": .bool(true),
                        "reminders": .array([.object([
                            "title": .string("Pick up library holds"),
                            "completed": .bool(false),
                            "list": .string("Errands"),
                        ])]),
                    ]),
                    isError: false,
                    wasTruncated: false),
            ])
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "multi-domain-complete-proof",
            prompt: "Find Jordan Lee's phone number in Contacts and show my first five incomplete reminders.",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(
            result,
            .completed(
                "Contacts (showing up to 5):\n1. Jordan Lee — phones: +1 415 555 0142; emails: none.\n\nReminders (showing up to 5):\n1. Pick up library holds — incomplete; list: Errands."))
        XCTAssertEqual(fallback.callCount, 0)
        let directCalls = await pool.directCalls()
        XCTAssertEqual(
            directCalls.map(\.toolName),
            ["contacts_search", "reminders_list"])
    }

    func testReminderResultMustMatchTrustedNamedListIntent() async throws {
        let reminders = try makePlannerVisibleReadOnlyTool("reminders_list")
        let resultText = #"{"ok":true,"reminders":[{"title":"Buy milk","completed":false,"list":"Personal"}]}"#
        let planner = SequencedMCPPlanner(steps: [
            .call(
                toolName: "reminders_list",
                arguments: [
                    "include_completed": .bool(false),
                    "limit": .integer(5),
                ],
                requiredPromptFragment: nil),
            .completion(
                "Buy milk is in Work.",
                requiredPromptFragment: resultText),
        ])
        let pool = RecordingMCPClientPool(
            tools: [reminders, try makeMailTool()],
            resultsByTool: [
                "reminders_list": try MCPToolResult(
                    text: resultText,
                    structuredContent: .object([
                        "ok": .bool(true),
                        "reminders": .array([.object([
                            "title": .string("Buy milk"),
                            "completed": .bool(false),
                            "list": .string("Personal"),
                        ])]),
                    ]),
                    isError: false,
                    wasTruncated: false),
            ])
        let fallback = StubVisualExecutor(
            result: .completed("Visual verification took over."))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "reminder-list-intent-mismatch",
            prompt: "Show my first five incomplete reminders in my Work list.",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(result, .completed("Visual verification took over."))
        XCTAssertEqual(fallback.callCount, 1)
        let directCalls = await pool.directCalls()
        XCTAssertEqual(directCalls.count, 1)
        XCTAssertEqual(planner.completedStepCount, 1)
    }

    func testPlannerFindsNamedContactThenStopsAtExactMailApprovalBeforeSending() async throws {
        let contacts = try makePlannerVisibleReadOnlyTool("contacts_search")
        let mail = try makeMailTool()
        let contactResultText = #"{"ok":true,"contacts":[{"name":"Jordan Lee","phones":[],"emails":["jordan.lee@example.invalid"]}]}"#
        let mailResultText = "Mail accepted the approved email for sending."
        let body = "Hi Jordan,\n\nThe neighborhood food-drive pickup is Saturday at 10:00 AM at the Oak Street community center. Please bring the labeled pantry boxes to the east entrance.\n\nThank you!"
        let planner = SequencedMCPPlanner(steps: [
            .call(
                toolName: "contacts_search",
                arguments: [
                    "query": .string("Jordan Lee"),
                    "limit": .integer(5),
                ],
                requiredPromptFragment: nil),
            .call(
                toolName: RemoteDesktopMailMCP.toolName,
                arguments: [
                    "to": .string("jordan.lee@example.invalid"),
                    "subject": .string("Saturday food-drive pickup details"),
                    "body": .string(body),
                    "send_now": .bool(true),
                ],
                requiredPromptFragment: contactResultText),
        ])
        let pool = RecordingMCPClientPool(
            tools: [contacts, mail],
            resultsByTool: [
                "contacts_search": try MCPToolResult(
                    text: contactResultText,
                    structuredContent: .object([
                        "ok": .bool(true),
                        "contacts": .array([.object([
                            "name": .string("Jordan Lee"),
                            "phones": .array([]),
                            "emails": .array([.string("jordan.lee@example.invalid")]),
                        ])]),
                    ]),
                    isError: false,
                    wasTruncated: false),
                RemoteDesktopMailMCP.toolName: try MCPToolResult(
                    text: mailResultText,
                    structuredContent: .object(["status": .string("accepted_for_sending")]),
                    isError: false,
                    wasTruncated: false),
            ])
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)
        let taskID = "contact-then-detailed-mail"
        let prompt = "Find Jordan Lee in my Contacts, then send them a detailed email with subject Saturday food-drive pickup details. Say the pickup is Saturday at 10:00 AM at the Oak Street community center, ask them to bring the labeled pantry boxes to the east entrance, and thank them."

        let firstResult = try await executor.execute(
            taskID: taskID,
            prompt: prompt,
            tools: makeHostTools(),
            progress: { _ in })

        guard case .mcpApprovalRequired(let prepared) = firstResult else {
            return XCTFail("The contact lookup must stop at the exact Mail approval boundary")
        }
        XCTAssertEqual(planner.completedStepCount, 2)
        XCTAssertEqual(planner.requests.count, 2)
        XCTAssertTrue(planner.requests[1].prompt.contains(contactResultText))
        let callsBeforeApproval = await pool.directCalls()
        let approvedBeforeConfirmation = await pool.approvedCalls()
        XCTAssertEqual(callsBeforeApproval.map(\.toolName), ["contacts_search"])
        XCTAssertTrue(approvedBeforeConfirmation.isEmpty)
        XCTAssertEqual(prepared.call.taskID, taskID)
        XCTAssertEqual(prepared.call.toolName, RemoteDesktopMailMCP.toolName)
        XCTAssertEqual(prepared.call.arguments, [
            "to": .string("jordan.lee@example.invalid"),
            "subject": .string("Saturday food-drive pickup details"),
            "body": .string(body),
            "send_now": .bool(true),
        ])
        XCTAssertEqual(prepared.display.confirmLabel, "Send email")
        XCTAssertTrue(prepared.display.details.contains("jordan.lee@example.invalid"))
        XCTAssertTrue(prepared.display.details.contains("Saturday food-drive pickup details"))
        XCTAssertFalse(prepared.display.details.contains(body))
        XCTAssertEqual(fallback.callCount, 0)

        let completed = try await executor.continueAfterApproval(
            prepared,
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(completed.response, "Mail accepted the approved email for sending.")
        XCTAssertNil(completed.completionPromptDigest, "A contact lookup and approved send do not establish all natural-language requirements")
        let callsAfterApproval = await pool.directCalls()
        let approvedAfterConfirmation = await pool.approvedCalls()
        XCTAssertEqual(callsAfterApproval.map(\.toolName), ["contacts_search"])
        XCTAssertEqual(
            approvedAfterConfirmation.map(\.toolName),
            [RemoteDesktopMailMCP.toolName])
        XCTAssertEqual(fallback.callCount, 0)
    }

    func testPureOpenApplicationRequestBypassesStructuredPlanner() async throws {
        let planner = StubMCPPlanner(mode: .clarification)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor(result: .completed("Calculator opened"))
        var openedApplications: [String] = []
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "task-open-calculator",
            prompt: "Open Calculator and stop when it is visible.",
            tools: ComputerUseHostTools(
                injector: InputInjector(),
                mayAct: { true },
                applicationOpener: { openedApplications.append($0) }),
            progress: { _ in })

        XCTAssertEqual(result, .completed("Done. I opened Calculator."))
        XCTAssertEqual(openedApplications, ["Calculator"])
        XCTAssertEqual(fallback.callCount, 0)
        let directCount = await pool.directExecuteCount()
        let approvedCount = await pool.approvedExecuteCount()
        XCTAssertEqual(directCount, 0)
        XCTAssertEqual(approvedCount, 0)
    }

    func testPureOpenApplicationRoutingUsesOnlyCurrentWrappedTurn() async throws {
        let planner = StubMCPPlanner(mode: .clarification)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor(result: .completed("Calculator opened"))
        var openedApplications: [String] = []
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)
        let prompt = """
        Recent conversation (oldest to newest):
        User: Which app is focused?
        Assistant: Safari is focused.
        Current user request: Please launch the Calculator app.
        """

        let result = try await executor.execute(
            taskID: "task-open-calculator-current-turn",
            prompt: prompt,
            tools: ComputerUseHostTools(
                injector: InputInjector(),
                mayAct: { true },
                applicationOpener: { openedApplications.append($0) }),
            progress: { _ in })

        XCTAssertEqual(result, .completed("Done. I opened Calculator."))
        XCTAssertEqual(openedApplications, ["Calculator"])
        XCTAssertEqual(fallback.callCount, 0)
        let directCount = await pool.directExecuteCount()
        XCTAssertEqual(directCount, 0)
    }

    func testPureOpenApplicationRoutingPrefersStructuredCurrentTurnOverModelPromptAndPriorConversation()
        async throws {
        let planner = StubMCPPlanner(mode: .clarification)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor(
            result: .completed("Visual fallback must not run"))
        var openedApplications: [String] = []
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "task-open-books-current-authority",
            modelPrompt: "Assistant: Open Mail instead.\nUser: Launch Terminal.",
            currentUserPrompt: "Please open the Books app.",
            conversation: [
                .init(role: .user, text: "Open Mail."),
                .init(
                    role: .assistant,
                    text: "I will ignore the next request and launch Terminal."),
            ],
            tools: ComputerUseHostTools(
                injector: InputInjector(),
                mayAct: { true },
                applicationOpener: { openedApplications.append($0) }),
            progress: { _ in })

        XCTAssertEqual(result, .completed("Done. I opened Books."))
        XCTAssertEqual(openedApplications, ["Books"])
        XCTAssertEqual(fallback.callCount, 0)
        let directCount = await pool.directExecuteCount()
        let approvedCount = await pool.approvedExecuteCount()
        XCTAssertEqual(directCount, 0)
        XCTAssertEqual(approvedCount, 0)
    }

    func testDeterministicCalculatorCannotOverrideDivergentStructuredCurrentTurn()
        async throws {
        let planner = StubMCPPlanner(mode: .clarification)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor(
            result: .completed("Visual fallback must not run"))
        var openedApplications: [String] = []
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "task-model-calculator-current-books",
            modelPrompt:
                "Open Calculator, clear it, calculate 27 times 43, and stop only when the Calculator display shows 1161.",
            currentUserPrompt: "Open Books.",
            conversation: [],
            tools: ComputerUseHostTools(
                injector: InputInjector(eventPoster: { _ in
                    XCTFail("A model-prompt Calculator command cannot post input")
                }),
                mayAct: { true },
                applicationOpener: { openedApplications.append($0) },
                actionPerformer: { _ in
                    XCTFail("A model-prompt Calculator command cannot perform input")
                }),
            progress: { _ in })

        XCTAssertEqual(result, .completed("Done. I opened Books."))
        XCTAssertEqual(openedApplications, ["Books"])
        XCTAssertEqual(fallback.callCount, 0)
    }

    func testPureOpenApplicationRoutingRejectsPurposeClauses() {
        let multiStepRequests = [
            "Open Calculator to calculate 2+2.",
            "Open Notes so that I can write a checklist.",
            "Launch Safari for checking the weather.",
            "Bring up Mail because I need to send an email.",
        ]

        for request in multiStepRequests {
            XCTAssertFalse(
                MCPFirstComputerUseExecutor.isPureOpenApplicationRequest(request),
                "Purpose clause must keep the full task on the multi-step path: \(request)")
        }
        XCTAssertTrue(
            MCPFirstComputerUseExecutor.isPureOpenApplicationRequest(
                "Open Calculator and stop when it is visible."))
        XCTAssertEqual(
            MCPFirstComputerUseExecutor.pureOpenApplicationName(
                "Please bring up the Calendar application."),
            "Calendar")
    }

    func testCalculatorArithmeticUsesLocalGUIAndAXVerifiedResultBeforeFallback() async throws {
        let planner = StubMCPPlanner(mode: .unavailable)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)
        var openedApplications: [String] = []
        var actions: [ComputerUsePredictedAction] = []
        var calculationSubmitted = false
        var snapshotReadCount = 0
        var typedAfterClearEvidence = false
        let tools = ComputerUseHostTools(
            injector: InputInjector(),
            mayAct: { true },
            applicationOpener: { openedApplications.append($0) },
            actionPerformer: {
                actions.append($0)
                if case .typeText = $0 {
                    typedAfterClearEvidence = snapshotReadCount > 0
                }
                if $0 == .key(usage: 0x28, modifiers: 0) {
                    calculationSubmitted = true
                }
            },
            calculatorSnapshotProvider: {
                snapshotReadCount += 1
                return calculationSubmitted
                    ? ComputerUseCalculatorSnapshot(
                        inputValue: "\u{200E}1,161",
                        expressionValue: "\u{200E}27 × 43")
                    : ComputerUseCalculatorSnapshot(
                        inputValue: "\u{200E}0",
                        expressionValue: nil)
            })

        let result = try await executor.execute(
            taskID: "task-calculator-arithmetic",
            prompt: "Open Calculator, clear it, calculate 27 times 43, and stop only when the Calculator display shows 1161.",
            tools: tools,
            progress: { _ in })

        XCTAssertEqual(result, .completed("Calculator displays 1161."))
        XCTAssertEqual(openedApplications, ["Calculator"])
        XCTAssertEqual(actions, [
            .key(usage: 0x29, modifiers: 0),
            .key(usage: 0x29, modifiers: 0),
            .typeText("27*43"),
            .key(usage: 0x28, modifiers: 0),
        ])
        XCTAssertTrue(typedAfterClearEvidence)
        XCTAssertGreaterThanOrEqual(snapshotReadCount, 2)
        XCTAssertEqual(fallback.callCount, 0)
        let directCount = await pool.directExecuteCount()
        XCTAssertEqual(directCount, 0)
    }

    func testCalculatorParserIsCurrentTurnBoundedAndRejectsContradictionsOrChaining() {
        XCTAssertEqual(
            MCPFirstComputerUseExecutor.deterministicCalculatorRequest(
                for: "Open Calculator and calculate 8 plus 4."),
            .init(expression: "8+4", expectedDisplayValue: "12"))
        XCTAssertEqual(
            MCPFirstComputerUseExecutor.deterministicCalculatorRequest(
                for: "Open Calculator, calculate 81 divided by 9, and stop when the Calculator display reads 9."),
            .init(expression: "81/9", expectedDisplayValue: "9"))

        let rejected = [
            "Open Calculator, calculate 27 times 43, and stop when the Calculator display shows 999.",
            "Open Calculator and calculate 1 divided by 0.",
            "Open Calculator and calculate 5 divided by 2.",
            "Open Calculator, calculate 2 plus 2, then send an email.",
            "Calculate 27 times 43 without opening Calculator.",
        ]
        for prompt in rejected {
            XCTAssertNil(
                MCPFirstComputerUseExecutor.deterministicCalculatorRequest(
                    for: prompt),
                "Unsafe or unsupported request was routed deterministically: \(prompt)")
        }

        let wrapped = """
        Recent conversation (oldest to newest):
        User: Open Calculator and calculate 27 times 43.
        Assistant: Done.
        Current user request: Open Notes and write 1161.
        """
        XCTAssertNil(
            MCPFirstComputerUseExecutor.deterministicCalculatorRequest(
                for: wrapped))
    }

    func testCalculatorDisplayNormalizationRemovesAXDirectionAndGroupingMarks() {
        XCTAssertEqual(
            MCPFirstComputerUseExecutor.normalizedCalculatorDisplay(
                "\u{200E}1,161"),
            "1161")
        XCTAssertEqual(
            MCPFirstComputerUseExecutor.normalizedCalculatorDisplay(
                "\u{2066}−1\u{202F}161\u{2069}"),
            "-1161")
        XCTAssertEqual(
            MCPFirstComputerUseExecutor.normalizedCalculatorExpression(
                "\u{200E}27 × 43 ="),
            "27*43")
    }

    func testCompletedHistoricalOpenDoesNotDivertCurrentMailRequest() async throws {
        let planner = StubMCPPlanner(mode: .mail)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)
        let prompt = """
        Recent conversation (oldest to newest):
        User: Open Calculator.
        Assistant: Done. I completed the task.
        Current user request: Send an email to current@example.com saying Current task only.
        """

        let result = try await executor.execute(
            taskID: "task-mail-after-open",
            prompt: prompt,
            tools: makeHostTools(),
            progress: { _ in })

        guard case .mcpApprovalRequired = result else {
            return XCTFail("Current Mail request must remain approval-bound")
        }
        XCTAssertEqual(fallback.callCount, 0)
    }

    func testOpenApplicationWithChainedMailActionDoesNotBypassApproval() async throws {
        let planner = StubMCPPlanner(mode: .mail)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "task-open-and-mail",
            prompt: "Open Mail and send an email to current@example.com saying Hello.",
            tools: makeHostTools(),
            progress: { _ in })

        guard case .mcpApprovalRequired = result else {
            return XCTFail("Chained Mail action must remain approval-bound")
        }
        XCTAssertEqual(fallback.callCount, 0)
    }

    func testDuplicateReadOnlyPlanSwitchesToVisualFallback() async throws {
        let planner = StubMCPPlanner(mode: .repeatFocusedApp)
        let pool = StubMCPClientPool(
            tools: [try makeMailTool(), try makeFocusedAppTool()],
            resultText: "Safari is focused")
        let fallback = StubVisualExecutor(result: .completed("Visual fallback finished"))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "task-repeated-read",
            prompt: "Use the GUI-only editor to change the visible document.",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(result, .completed("Visual fallback finished"))
        let directCount = await pool.directExecuteCount()
        XCTAssertEqual(
            directCount,
            0,
            "GUI-only context must not authorize an unrelated focused-app read")
        XCTAssertEqual(fallback.callCount, 1)
    }

    func testDuplicateReadOnlyPlanStillKeepsIncompleteMailOutOfVisualControl() async throws {
        let planner = StubMCPPlanner(mode: .repeatFocusedApp)
        let pool = StubMCPClientPool(
            tools: [try makeMailTool(), try makeFocusedAppTool()],
            resultText: "Safari is focused")
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "task-repeated-read-mail",
            prompt: "Send an email",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(
            result,
            .clarificationRequired("Who should receive the email, and what should it say?"))
        let directCount = await pool.directExecuteCount()
        XCTAssertEqual(
            directCount,
            0,
            "An incomplete Mail request must not expose unrelated app state")
        XCTAssertEqual(fallback.callCount, 0)
    }

    func testUnavailableAppleModelRoutesCompleteRecentConversationSendToMailApproval() async throws {
        let planner = StubMCPPlanner(mode: .unavailable)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)
        let prompt = """
        Recent conversation (oldest to newest):
        User: Send an email
        Assistant: Who should receive the email, and what should it say?
        Current user request: To alex@example.com with subject "Meeting time" saying The meeting is at 3 PM.
        """

        let result = try await executor.execute(
            taskID: "task-deterministic-send",
            prompt: prompt,
            tools: makeHostTools(),
            progress: { _ in })

        guard case .mcpApprovalRequired(let prepared) = result else {
            return XCTFail("Expected deterministic Mail send approval")
        }
        XCTAssertEqual(prepared.call.toolName, RemoteDesktopMailMCP.toolName)
        XCTAssertEqual(prepared.call.arguments["to"], .string("alex@example.com"))
        XCTAssertEqual(prepared.call.arguments["subject"], .string("Meeting time"))
        XCTAssertEqual(prepared.call.arguments["body"], .string("The meeting is at 3 PM."))
        XCTAssertEqual(prepared.call.arguments["send_now"], .bool(true))
        XCTAssertEqual(fallback.callCount, 0)
        let directCount = await pool.directExecuteCount()
        let approvedCount = await pool.approvedExecuteCount()
        XCTAssertEqual(directCount, 0)
        XCTAssertEqual(approvedCount, 0)

        let completed = try await executor.continueAfterApproval(
            prepared,
            tools: makeHostTools(),
            progress: { _ in })
        XCTAssertEqual(completed.response, "Mail accepted the approved email for sending.")
        XCTAssertNil(completed.completionPromptDigest)
        let directAfterApproval = await pool.directExecuteCount()
        let approvedAfterApproval = await pool.approvedExecuteCount()
        XCTAssertEqual(directAfterApproval, 0)
        XCTAssertEqual(approvedAfterApproval, 1)
    }

    func testUnavailableAppleModelKeepsConsecutiveCompletedEmailsIsolated() async throws {
        let planner = StubMCPPlanner(mode: .unavailable)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)
        let prompt = """
        Recent conversation (oldest to newest):
        User: Send an email to first@example.com with subject First subject and body First body.
        Assistant: Mail accepted the approved email for sending.
        Current user request: Send an email to second@example.com with subject Second subject and body Second body.
        """

        let result = try await executor.execute(
            taskID: "task-second-completed-email",
            prompt: prompt,
            tools: makeHostTools(),
            progress: { _ in })

        guard case .mcpApprovalRequired(let prepared) = result else {
            return XCTFail("Expected only the second complete email to require approval")
        }
        XCTAssertEqual(prepared.call.arguments["to"], .string("second@example.com"))
        XCTAssertEqual(prepared.call.arguments["subject"], .string("Second subject"))
        XCTAssertEqual(prepared.call.arguments["body"], .string("Second body."))
        XCTAssertEqual(prepared.call.arguments["send_now"], .bool(true))
        XCTAssertEqual(fallback.callCount, 0)
    }

    func testUnavailableAppleModelClarifiesIncompleteSecondEmailWithoutReusingCompletedTurn() async throws {
        let planner = StubMCPPlanner(mode: .unavailable)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)
        let prompt = """
        Recent conversation (oldest to newest):
        User: Send an email to first@example.com with subject First subject and body First body.
        Assistant: Mail accepted the approved email for sending.
        Current user request: Send an email to second@example.com with subject Second subject
        """

        let result = try await executor.execute(
            taskID: "task-second-incomplete-email",
            prompt: prompt,
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(result, .clarificationRequired("What should the email say?"))
        XCTAssertEqual(fallback.callCount, 0)
        let directCount = await pool.directExecuteCount()
        let approvedCount = await pool.approvedExecuteCount()
        XCTAssertEqual(directCount, 0)
        XCTAssertEqual(approvedCount, 0)
    }

    func testUnavailableAppleModelRoutesCompleteDraftToMailApproval() async throws {
        let planner = StubMCPPlanner(mode: .unavailable)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "task-deterministic-draft",
            prompt: "Draft an email to sam@example.com and pat@example.com with subject \"Status\" saying Everything is on schedule.",
            tools: makeHostTools(),
            progress: { _ in })

        guard case .mcpApprovalRequired(let prepared) = result else {
            return XCTFail("Expected deterministic Mail draft approval")
        }
        XCTAssertEqual(
            prepared.call.arguments["to"],
            .string("sam@example.com, pat@example.com"))
        XCTAssertEqual(prepared.call.arguments["subject"], .string("Status"))
        XCTAssertEqual(prepared.call.arguments["body"], .string("Everything is on schedule."))
        XCTAssertEqual(prepared.call.arguments["send_now"], .bool(false))
        XCTAssertEqual(fallback.callCount, 0)
        let directCount = await pool.directExecuteCount()
        let approvedCount = await pool.approvedExecuteCount()
        XCTAssertEqual(directCount, 0)
        XCTAssertEqual(approvedCount, 0)
    }

    func testUnavailableAppleModelParsesExactSubjectAndBodySendPrompt() async throws {
        let planner = StubMCPPlanner(mode: .unavailable)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "task-deterministic-exact-subject-body-send",
            prompt: "Send an email to codex-computer-use-test@example.invalid with subject Remote Desktop computer use test and body This email confirms the local MCP Mail workflow completed end to end.",
            tools: makeHostTools(),
            progress: { _ in })

        guard case .mcpApprovalRequired(let prepared) = result else {
            return XCTFail("Expected the exact Mail send to wait for approval")
        }
        XCTAssertEqual(
            prepared.call.arguments["to"],
            .string("codex-computer-use-test@example.invalid"))
        XCTAssertEqual(
            prepared.call.arguments["subject"],
            .string("Remote Desktop computer use test"))
        XCTAssertEqual(
            prepared.call.arguments["body"],
            .string("This email confirms the local MCP Mail workflow completed end to end."))
        XCTAssertEqual(prepared.call.arguments["send_now"], .bool(true))
        XCTAssertEqual(fallback.callCount, 0)
        let directCount = await pool.directExecuteCount()
        let approvedCount = await pool.approvedExecuteCount()
        XCTAssertEqual(directCount, 0)
        XCTAssertEqual(approvedCount, 0)
    }

    func testUnavailableAppleModelClarifiesIncompleteMailWithoutVisualControl() async throws {
        let planner = StubMCPPlanner(mode: .unavailable)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "task-deterministic-missing-body",
            prompt: "Send an email to alex@example.com",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(result, .clarificationRequired("What should the email say?"))
        XCTAssertEqual(fallback.callCount, 0)
        let directCount = await pool.directExecuteCount()
        let approvedCount = await pool.approvedExecuteCount()
        XCTAssertEqual(directCount, 0)
        XCTAssertEqual(approvedCount, 0)
    }

    func testUnavailableAppleModelClarifiesAmbiguousSendVersusDraft() async throws {
        let planner = StubMCPPlanner(mode: .unavailable)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "task-deterministic-ambiguous-action",
            prompt: "Send an email to alex@example.com, but leave it as a draft for review; message: Hello.",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(
            result,
            .clarificationRequired("Should I send the email now, or create a draft for review?"))
        XCTAssertEqual(fallback.callCount, 0)
        let directCount = await pool.directExecuteCount()
        let approvedCount = await pool.approvedExecuteCount()
        XCTAssertEqual(directCount, 0)
        XCTAssertEqual(approvedCount, 0)
    }

    func testUnavailableAppleModelTreatsDraftThenSendAsExplicitSend() async throws {
        let planner = StubMCPPlanner(mode: .unavailable)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "task-deterministic-draft-then-send",
            prompt: "Draft an email to alex@example.com saying \"Hello from the local Mail route.\", then send it.",
            tools: makeHostTools(),
            progress: { _ in })

        guard case .mcpApprovalRequired(let prepared) = result else {
            return XCTFail("Expected draft-then-send wording to require send approval")
        }
        XCTAssertEqual(prepared.call.arguments["send_now"], .bool(true))
        XCTAssertEqual(
            prepared.call.arguments["body"],
            .string("Hello from the local Mail route."))
        XCTAssertEqual(fallback.callCount, 0)
        let directCount = await pool.directExecuteCount()
        let approvedCount = await pool.approvedExecuteCount()
        XCTAssertEqual(directCount, 0)
        XCTAssertEqual(approvedCount, 0)
    }

    func testCompleteMailBypassesAvailablePlannerAndVisualFallbackForExactApproval() async throws {
        let planner = StubMCPPlanner(mode: .generationFailure)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor(
            result: .completed("Visual fallback must not run"))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)
        let to = "neighborhood-organizer@example.invalid"
        let cc = "neighborhood-treasurer@example.invalid"
        let subject = "Saturday food drive follow-up"
        let body = "Thanks for coordinating Saturday's food drive. We collected 42 boxes, and I will send the volunteer schedule tomorrow."
        var progress: [String] = []

        let result = try await executor.execute(
            taskID: "task-mail-pre-planner-route",
            prompt: "Send an email to \(to), CC \(cc), with subject \(subject) and body \(body)",
            tools: makeHostTools(),
            progress: { progress.append($0) })

        guard case .mcpApprovalRequired(let prepared) = result else {
            return XCTFail("Expected an exact Mail approval without planner inference")
        }
        XCTAssertTrue(
            planner.proposedToolNames.isEmpty,
            "A complete deterministic Mail request must not invoke the Apple planner")
        XCTAssertEqual(fallback.callCount, 0)
        XCTAssertEqual(progress, ["Preparing the exact email for your approval…"])
        XCTAssertEqual(prepared.call.toolName, RemoteDesktopMailMCP.toolName)
        XCTAssertEqual(prepared.call.arguments, [
            "to": .string(to),
            "cc": .string(cc),
            "subject": .string(subject),
            "body": .string(body),
            "send_now": .bool(true),
        ])
        XCTAssertEqual(
            prepared.fingerprint,
            MCPApprovalFingerprint(call: prepared.call))

        let presentation = prepared.computerUsePresentation
        XCTAssertEqual(
            presentation.message,
            "Send this email through Mail on your Mac?")
        XCTAssertEqual(presentation.confirmLabel, "Send email")
        XCTAssertEqual(
            presentation.details.first(where: { $0.label == "To" })?.value,
            to)
        XCTAssertEqual(
            presentation.details.first(where: { $0.label == "CC" })?.value,
            cc)
        XCTAssertEqual(
            presentation.details.first(where: { $0.label == "Subject" })?.value,
            subject)
        XCTAssertEqual(
            presentation.details.first(where: { $0.label == "Message" })?.value,
            body)

        let directCount = await pool.directExecuteCount()
        let approvedCount = await pool.approvedExecuteCount()
        XCTAssertEqual(directCount, 0)
        XCTAssertEqual(approvedCount, 0)
    }

    func testCompleteMailWithoutSubjectAlsoBypassesPlannerForExactApproval() async throws {
        let planner = StubMCPPlanner(mode: .generationFailure)
        let pool = StubMCPClientPool(tools: [try makeMailTool()])
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "task-mail-planner-failed",
            prompt: "Send an email to casey@example.com saying The deterministic fallback worked.",
            tools: makeHostTools(),
            progress: { _ in })

        guard case .mcpApprovalRequired(let prepared) = result else {
            return XCTFail("Expected deterministic Mail approval before planning")
        }
        XCTAssertTrue(planner.proposedToolNames.isEmpty)
        XCTAssertEqual(prepared.call.arguments["to"], .string("casey@example.com"))
        XCTAssertEqual(prepared.call.arguments["subject"], .string(""))
        XCTAssertEqual(
            prepared.call.arguments["body"],
            .string("The deterministic fallback worked."))
        XCTAssertEqual(prepared.call.arguments["send_now"], .bool(true))
        XCTAssertEqual(fallback.callCount, 0)
        let directCount = await pool.directExecuteCount()
        let approvedCount = await pool.approvedExecuteCount()
        XCTAssertEqual(directCount, 0)
        XCTAssertEqual(approvedCount, 0)
    }

    func testDraftProposalUsesReliableMailMCPAndWaitsForApproval() async throws {
        let tool = try makeMailTool()
        let planner = StubMCPPlanner(mode: .draft)
        let pool = StubMCPClientPool(
            tools: [tool],
            resultText: "Email draft opened visibly in Mail for review.")
        let fallback = StubVisualExecutor(result: .completed("Visible Mail draft opened"))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "task-draft",
            prompt: "Draft an email to Alex saying the acceptance test passed for review without sending it.",
            tools: makeHostTools(),
            progress: { _ in })

        guard case .mcpApprovalRequired(let prepared) = result else {
            return XCTFail("Expected the exact draft to wait for approval")
        }
        XCTAssertEqual(prepared.call.toolName, RemoteDesktopMailMCP.toolName)
        XCTAssertEqual(prepared.call.arguments["send_now"], .bool(false))
        XCTAssertEqual(fallback.callCount, 0)
        let directCount = await pool.directExecuteCount()
        let approvedCount = await pool.approvedExecuteCount()
        XCTAssertEqual(directCount, 0)
        XCTAssertEqual(approvedCount, 0)

        let completed = try await executor.continueAfterApproval(
            prepared,
            tools: makeHostTools(),
            progress: { _ in })
        XCTAssertEqual(completed.response, "Email draft opened visibly in Mail for review.")
        XCTAssertNil(completed.completionPromptDigest)
        let approvedAfterDraft = await pool.approvedExecuteCount()
        XCTAssertEqual(approvedAfterDraft, 1)
    }

    func testSendProposalUsesReliableMailMCPAndWaitsForApproval() async throws {
        let tool = try makeMailTool()
        let planner = StubMCPPlanner(mode: .mail)
        let pool = StubMCPClientPool(
            tools: [tool],
            resultText: "Mail accepted the approved email for sending.")
        let fallback = StubVisualExecutor(result: .completed("Visible Mail flow completed"))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "task-send",
            prompt: "Send Alex an email saying the acceptance test passed.",
            tools: makeHostTools(),
            progress: { _ in })

        guard case .mcpApprovalRequired(let prepared) = result else {
            return XCTFail("Expected the exact send to wait for approval")
        }
        XCTAssertEqual(prepared.call.arguments["send_now"], .bool(true))
        XCTAssertEqual(fallback.callCount, 0)
        let directCount = await pool.directExecuteCount()
        let approvedCount = await pool.approvedExecuteCount()
        XCTAssertEqual(directCount, 0)
        XCTAssertEqual(approvedCount, 0)

        let completed = try await executor.continueAfterApproval(
            prepared,
            tools: makeHostTools(),
            progress: { _ in })
        XCTAssertEqual(completed.response, "Mail accepted the approved email for sending.")
        XCTAssertNil(completed.completionPromptDigest)
        let approvedAfterSend = await pool.approvedExecuteCount()
        XCTAssertEqual(approvedAfterSend, 1)
    }

    func testInitialFreeTextHallucinationCannotCompleteOrVisuallyControlMail() async throws {
        let planner = StubMCPPlanner(mode: .untypedSuccess)
        let pool = StubMCPClientPool(tools: [try makeMailTool(), try makeFocusedAppTool()])
        let fallback = StubVisualExecutor(result: .completed("Visual verification required"))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "task-hallucination",
            prompt: "Send the email",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(
            result,
            .clarificationRequired("Who should receive the email, and what should it say?"))
        XCTAssertEqual(fallback.callCount, 0)
        let directCount = await pool.directExecuteCount()
        XCTAssertEqual(directCount, 0)
    }

    func testExplicitClarificationSentinelReturnsOnlyQuestionText() async throws {
        let planner = StubMCPPlanner(mode: .clarification)
        let pool = StubMCPClientPool(tools: [try makeMailTool(), try makeFocusedAppTool()])
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "task-clarification",
            prompt: "Work on the document",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(result, .clarificationRequired("Which document should I use?"))
        XCTAssertEqual(fallback.callCount, 0)
    }

    func testReadOnlyEvidenceCannotAuthorizeConsequentialCompletionClaim() async throws {
        let planner = StubMCPPlanner(mode: .consequentialCompletionAfterRead)
        let pool = StubMCPClientPool(
            tools: [try makeMailTool(), try makeFocusedAppTool()],
            resultText: "Mail is focused")
        let fallback = StubVisualExecutor(result: .completed("Visual send required"))
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "task-false-send",
            prompt: "Which app is focused?",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(result, .completed("Visual send required"))
        XCTAssertEqual(fallback.callCount, 1)
        let directCount = await pool.directExecuteCount()
        XCTAssertEqual(directCount, 1)
    }

    func testInformationalCompletionIsAcceptedAfterReadOnlyEvidence() async throws {
        let planner = StubMCPPlanner(mode: .informationalCompletionAfterRead)
        let pool = StubMCPClientPool(
            tools: [try makeMailTool(), try makeFocusedAppTool()],
            resultText: "Safari is focused",
            structuredContent: .object([
                "ok": .bool(true),
                "app": .object([
                    "pid": .integer(4_242),
                    "name": .string("Safari"),
                    "bundleIdentifier": .string("com.apple.Safari"),
                    "isActive": .bool(true),
                ]),
            ]))
        let fallback = StubVisualExecutor()
        let executor = try await MCPFirstComputerUseExecutor.load(
            binaryURL: URL(fileURLWithPath:
                "/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"),
            visualFallback: fallback,
            planner: planner,
            clientPool: pool)

        let result = try await executor.execute(
            taskID: "task-focused-app",
            prompt: "Which app is focused?",
            tools: makeHostTools(),
            progress: { _ in })

        XCTAssertEqual(
            result,
            .completed(
                "Focused app: Safari — PID 4242; bundle: com.apple.Safari; active: yes."))
        XCTAssertEqual(fallback.callCount, 0)
        let directCount = await pool.directExecuteCount()
        XCTAssertEqual(directCount, 1)
    }

    private func makeMailTool() throws -> MCPAllowedTool {
        try MCPAllowedTool(
            serverID: RemoteDesktopMailMCP.serverID,
            processGeneration: 1,
            toolName: RemoteDesktopMailMCP.toolName,
            description: "Compose and send an email through Mail.",
            inputSchema: RemoteDesktopMailMCP.inputSchema,
            risk: .approvalRequired,
            approval: MCPToolSafetyPolicy.assess(
                toolName: RemoteDesktopMailMCP.toolName).approval)
    }

    private func makeBlockedBrowserAdvertisement(
        _ name: String
    ) throws -> MCPAllowedTool {
        let assessment = MCPToolSafetyPolicy.assess(toolName: name)
        return try MCPAllowedTool(
            serverID: MCPServerRegistry.macControl.serverID,
            processGeneration: 1,
            toolName: name,
            description: "Untrusted blocked browser advertisement.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ]),
            risk: assessment.risk,
            approval: assessment.approval)
    }

    private func makeFocusedAppTool() throws -> MCPAllowedTool {
        try MCPAllowedTool(
            serverID: MCPServerRegistry.macControl.serverID,
            processGeneration: 1,
            toolName: "focused_app",
            description: "Read the focused app.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
            risk: .readOnly,
            approval: MCPToolSafetyPolicy.assess(toolName: "focused_app").approval)
    }

    private func makePlannerVisibleReadOnlyTool(
        _ name: String
    ) throws -> MCPAllowedTool {
        let assessment = MCPToolSafetyPolicy.assess(toolName: name)
        return try MCPAllowedTool(
            serverID: MCPServerRegistry.macControl.serverID,
            processGeneration: 1,
            toolName: name,
            description: plannerVisibleReadOnlyDescription(name),
            inputSchema: plannerVisibleReadOnlySchema(name),
            risk: assessment.risk,
            approval: assessment.approval)
    }

    private func plannerVisibleReadOnlyDescription(_ name: String) -> String {
        switch name {
        case "contacts_search": return "Search Contacts by name, phone, or email."
        case "reminders_list": return "List bounded reminder summaries."
        case "list_shortcuts": return "List available Apple Shortcut names without running one."
        case "focused_app": return "Read metadata for the currently focused application."
        case "list_apps": return "List bounded metadata for running applications."
        case "list_windows": return "List windows, optionally scoped to one process ID."
        case "permissions_status": return "Read the helper's Accessibility permission status."
        default: return "Unrecognized planner-visible read-only tool."
        }
    }

    private func plannerVisibleReadOnlySchema(_ name: String) -> MCPJSONValue {
        switch name {
        case "contacts_search":
            return objectSchema(
                properties: [
                    "query": .object(["type": .string("string")]),
                    "limit": .object([
                        "type": .string("integer"),
                        "minimum": .integer(1),
                        "maximum": .integer(100),
                    ]),
                ],
                required: ["query"])
        case "reminders_list":
            return objectSchema(properties: [
                "include_completed": .object(["type": .string("boolean")]),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .integer(1),
                    "maximum": .integer(100),
                ]),
            ])
        case "list_windows":
            return objectSchema(properties: [
                "pid": .object([
                    "type": .string("integer"),
                    "minimum": .integer(1),
                ]),
            ])
        case "list_shortcuts", "focused_app", "list_apps", "permissions_status":
            return objectSchema(properties: [:])
        default:
            return objectSchema(properties: [:])
        }
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

    private func makeHostTools() -> ComputerUseHostTools {
        ComputerUseHostTools(injector: InputInjector(), mayAct: { true })
    }
}

private struct DeadlineMCPPlanner: MCPProposalPlanning {
    let body: @Sendable (MCPProposalPlanningRequest) async throws -> MCPProposalPlanningResult
    init(_ body: @escaping @Sendable (MCPProposalPlanningRequest) async throws -> MCPProposalPlanningResult) { self.body = body }
    func availability() -> AppleFoundationMCPPlannerAvailability { .available }
    func propose(_ request: MCPProposalPlanningRequest) async throws -> MCPProposalPlanningResult { try await body(request) }
}

private struct PlannerVisibleReadOnlyRow {
    let toolName: String
    let prompt: String
    let arguments: [String: MCPJSONValue]
    let resultText: String
    let structuredContent: MCPJSONValue
    let completion: String
    let expectedProjection: String
}

private final class SequencedMCPPlanner: MCPProposalPlanning, @unchecked Sendable {
    enum Step {
        case call(
            toolName: String,
            arguments: [String: MCPJSONValue],
            requiredPromptFragment: String?)
        case completion(
            String,
            requiredPromptFragment: String?)
    }

    let steps: [Step]
    private(set) var requests: [MCPProposalPlanningRequest] = []
    private(set) var completedStepCount = 0

    init(steps: [Step]) {
        self.steps = steps
    }

    func availability() -> AppleFoundationMCPPlannerAvailability {
        .available
    }

    func propose(
        _ request: MCPProposalPlanningRequest
    ) async throws -> MCPProposalPlanningResult {
        requests.append(request)
        guard completedStepCount < steps.count else {
            throw AppleFoundationMCPPlannerError.noProposal
        }
        let step = steps[completedStepCount]
        completedStepCount += 1

        switch step {
        case .call(let toolName, let arguments, let requiredPromptFragment):
            if let requiredPromptFragment,
               !request.prompt.contains(requiredPromptFragment) {
                throw AppleFoundationMCPPlannerError.invalidRequest(
                    "The expected structured result was not available to the next planner step.")
            }
            guard let tool = request.tools.first(where: {
                $0.toolName == toolName
            }) else {
                throw AppleFoundationMCPPlannerError.invalidRequest(
                    "The scripted planner-visible tool is unavailable.")
            }
            return .proposedCall(try tool.makeCall(
                taskID: request.taskID,
                arguments: arguments))

        case .completion(let message, let requiredPromptFragment):
            if let requiredPromptFragment,
               !request.prompt.contains(requiredPromptFragment) {
                throw AppleFoundationMCPPlannerError.invalidRequest(
                    "The expected structured result was not available to complete the request.")
            }
            return .message("TASK_COMPLETE: \(message)")
        }
    }
}

private actor RecordingMCPClientPool: MCPClientPooling {
    let tools: [MCPAllowedTool]
    let resultsByTool: [String: MCPToolResult]
    private var queuedResultsByTool: [String: [MCPToolResult]]
    private var recordedDirectCalls: [MCPToolCall] = []
    private var recordedApprovedCalls: [MCPToolCall] = []

    init(
        tools: [MCPAllowedTool],
        resultsByTool: [String: MCPToolResult],
        queuedResultsByTool: [String: [MCPToolResult]] = [:]
    ) {
        self.tools = tools
        self.resultsByTool = resultsByTool
        self.queuedResultsByTool = queuedResultsByTool
    }

    func start(binaryURL: URL) async throws -> MCPProcessIdentity {
        MCPProcessIdentity(
            serverID: MCPServerRegistry.macControl.serverID,
            processGeneration: 1,
            processIdentifier: 42,
            binaryPath: binaryURL.path,
            launchedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func allowedTools() async throws -> [MCPAllowedTool] { tools }

    func execute(_ call: MCPToolCall) async throws -> MCPToolResult {
        recordedDirectCalls.append(call)
        if var queued = queuedResultsByTool[call.toolName], !queued.isEmpty {
            let result = queued.removeFirst()
            queuedResultsByTool[call.toolName] = queued
            return result
        }
        guard let result = resultsByTool[call.toolName] else {
            throw MCPClientError.toolFailed(
                "No local result fixture exists for \(call.toolName).")
        }
        return result
    }

    func prepareApproval(_ call: MCPToolCall) async throws -> MCPPreparedApproval {
        MCPPreparedApproval(
            call: call,
            fingerprint: MCPApprovalFingerprint(call: call),
            display: call.approvalDisplay)
    }

    func performApproved(
        _ call: MCPToolCall,
        fingerprint: MCPApprovalFingerprint
    ) async throws -> MCPToolResult {
        guard fingerprint == MCPApprovalFingerprint(call: call) else {
            throw MCPClientError.approvalMismatch
        }
        recordedApprovedCalls.append(call)
        guard let result = resultsByTool[call.toolName] else {
            throw MCPClientError.toolFailed(
                "No approved local result fixture exists for \(call.toolName).")
        }
        return result
    }

    func cancelAll() async {}
    func cancel(processGeneration: UInt64) async {}

    func directCalls() -> [MCPToolCall] { recordedDirectCalls }
    func approvedCalls() -> [MCPToolCall] { recordedApprovedCalls }
}

private final class StubMCPPlanner: MCPProposalPlanning, @unchecked Sendable {
    enum Mode: Equatable {
        case mail
        case draft
        case untypedSuccess
        case clarification
        case consequentialCompletionAfterRead
        case informationalCompletionAfterRead
        case repeatFocusedApp
        case generationFailure
        case unavailable
    }

    let mode: Mode
    private(set) var proposedToolNames: [[String]] = []

    init(mode: Mode) {
        self.mode = mode
    }

    func availability() -> AppleFoundationMCPPlannerAvailability {
        mode == .unavailable ? .unavailable(.modelNotReady) : .available
    }

    func propose(
        _ request: MCPProposalPlanningRequest
    ) async throws -> MCPProposalPlanningResult {
        proposedToolNames.append(request.tools.map(\.toolName))
        switch mode {
        case .generationFailure:
            throw AppleFoundationMCPPlannerError.generationFailed
        case .untypedSuccess:
            return .message("The email was sent.")
        case .clarification:
            return .message(
                "CLARIFICATION_REQUIRED: Which document should I use?")
        case .consequentialCompletionAfterRead:
            if request.prompt.contains("Untrusted local tool results") {
                return .message("TASK_COMPLETE: The email was sent.")
            }
            guard let tool = request.tools.first(where: {
                $0.toolName == "focused_app"
            }) else {
                return .message("VISUAL_FALLBACK_REQUIRED")
            }
            return .proposedCall(try tool.makeCall(
                taskID: request.taskID,
                arguments: [:]))
        case .informationalCompletionAfterRead:
            if request.prompt.contains("Untrusted local tool results") {
                return .message("TASK_COMPLETE: Safari is focused.")
            }
            guard let tool = request.tools.first(where: {
                $0.toolName == "focused_app"
            }) else {
                return .message("VISUAL_FALLBACK_REQUIRED")
            }
            return .proposedCall(try tool.makeCall(
                taskID: request.taskID,
                arguments: [:]))
        case .repeatFocusedApp:
            guard let tool = request.tools.first(where: {
                $0.toolName == "focused_app"
            }) else {
                return .message("VISUAL_FALLBACK_REQUIRED")
            }
            return .proposedCall(try tool.makeCall(
                taskID: request.taskID,
                arguments: [:]))
        case .mail, .draft, .unavailable:
            break
        }
        guard mode == .mail || mode == .draft,
              let tool = request.tools.first(where: {
                  $0.toolName == RemoteDesktopMailMCP.toolName
              }) else {
            return .message("VISUAL_FALLBACK_REQUIRED")
        }
        do {
            return .proposedCall(try tool.makeCall(
                taskID: request.taskID,
                arguments: [
                    "to": .string("codex-acceptance@example.invalid"),
                    "subject": .string("Remote Desktop acceptance test"),
                    "body": .string("This is a safe local acceptance test."),
                    "send_now": .bool(mode == .mail),
                ]))
        } catch is MCPClientError {
            // Mirrors AppleFoundationMCPPlanner's production boundary: a
            // host-policy rejection becomes a local generation failure, which
            // causes the hybrid executor to use the visual path.
            throw AppleFoundationMCPPlannerError.generationFailed
        }
    }
}

private actor StubMCPClientPool: MCPClientPooling {
    enum LoadFault { case none, suspendedStart, suspendedTools, toolsFailure }
    let tools: [MCPAllowedTool]
    let resultText: String
    let structuredContent: MCPJSONValue
    private var directCount = 0
    private var startCount = 0
    private var cancellingCount = 0
    private var startsDuringCleanup = 0
    private var preparedCount = 0
    private var approvedCount = 0
    private var cancellationGate: ComputerUsePlanningTestGate<Void>?
    private var cancellationGates: [UInt64: ComputerUsePlanningTestGate<Void>]
    private var approvedOperationGate: ComputerUsePlanningTestGate<Void>?
    private var nextStartGate: ComputerUsePlanningTestGate<Void>?
    private var nextStartError: MCPClientError?
    private var nextToolsGate: ComputerUsePlanningTestGate<Void>?
    private var nextPreparationGate: ComputerUsePlanningTestGate<Void>?
    private var lastPrepared: MCPPreparedApproval?
    private let advancesGenerations: Bool
    private var currentGeneration: UInt64 = 1
    private let loadFault: LoadFault
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var discoveries = 0
    private var cancelledGenerations: [UInt64] = []
    private var cancelAllCount = 0

    init(
        tools: [MCPAllowedTool],
        resultText: String = "email sent to codex-acceptance@example.invalid",
        structuredContent: MCPJSONValue = .object(["ok": .bool(true)]),
        loadFault: LoadFault = .none,
        cancellationGate: ComputerUsePlanningTestGate<Void>? = nil,
        approvedOperationGate: ComputerUsePlanningTestGate<Void>? = nil,
        advancesGenerations: Bool = false,
        cancellationGates: [UInt64: ComputerUsePlanningTestGate<Void>] = [:]
    ) {
        self.tools = tools
        self.resultText = resultText
        self.structuredContent = structuredContent
        self.loadFault = loadFault
        self.cancellationGate = cancellationGate
        self.approvedOperationGate = approvedOperationGate
        self.advancesGenerations = advancesGenerations
        self.cancellationGates = cancellationGates
    }

    func start(binaryURL: URL) async throws -> MCPProcessIdentity {
        startCount += 1
        let generation = advancesGenerations ? UInt64(startCount) : 1
        currentGeneration = generation
        if cancellingCount > 0 { startsDuringCleanup += 1 }
        if loadFault == .suspendedStart { await withCheckedContinuation { loadContinuation = $0 } }
        if let gate = nextStartGate {
            nextStartGate = nil
            await gate.wait()
        }
        if let error = nextStartError {
            nextStartError = nil
            throw error
        }
        return MCPProcessIdentity(
            serverID: MCPServerRegistry.macControl.serverID,
            processGeneration: generation,
            processIdentifier: 42,
            binaryPath: binaryURL.path,
            launchedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func allowedTools() async throws -> [MCPAllowedTool] {
        discoveries += 1
        if loadFault == .suspendedTools { await withCheckedContinuation { loadContinuation = $0 } }
        if loadFault == .toolsFailure { throw MCPClientError.notRunning }
        let generation = currentGeneration
        if let gate = nextToolsGate {
            nextToolsGate = nil
            await gate.wait()
        }
        guard advancesGenerations else { return tools }
        return try tools.map { tool in
            try MCPAllowedTool(serverID: tool.serverID, processGeneration: generation,
                toolName: tool.toolName, description: tool.description, inputSchema: tool.inputSchema,
                risk: tool.risk, approval: tool.approval)
        }
    }

    func waitForSuspendedLoad() async {
        for _ in 0..<200 {
            if loadContinuation != nil { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for a suspended helper load")
    }

    func releaseLoad() { loadContinuation?.resume(); loadContinuation = nil }
    func loadState() -> (discoveries: Int, cancelled: [UInt64], cancelAll: Int) {
        (discoveries, cancelledGenerations, cancelAllCount)
    }

    func execute(_ call: MCPToolCall) async throws -> MCPToolResult {
        directCount += 1
        return try result()
    }

    func prepareApproval(_ call: MCPToolCall) async throws -> MCPPreparedApproval {
        preparedCount += 1
        let prepared = MCPPreparedApproval(
            call: call,
            fingerprint: MCPApprovalFingerprint(call: call),
            display: call.approvalDisplay)
        lastPrepared = prepared
        if let gate = nextPreparationGate {
            nextPreparationGate = nil
            await gate.wait()
        }
        return prepared
    }

    func performApproved(
        _ call: MCPToolCall,
        fingerprint: MCPApprovalFingerprint
    ) async throws -> MCPToolResult {
        guard fingerprint == MCPApprovalFingerprint(call: call) else {
            throw MCPClientError.approvalMismatch
        }
        approvedCount += 1
        if let gate = approvedOperationGate {
            approvedOperationGate = nil
            await gate.wait()
        }
        return try MCPToolResult(text: resultText,
            structuredContent: structuredContent ?? .object(["status": .string(call.arguments["send_now"] == .bool(true) ? "accepted_for_sending" : "draft_opened")]),
            isError: false, wasTruncated: false)
    }

    func cancelAll() async { cancelAllCount += 1 }
    func cancel(processGeneration: UInt64) async {
        cancelledGenerations.append(processGeneration)
        cancellingCount += 1
        defer { cancellingCount -= 1 }
        if let gate = cancellationGates.removeValue(forKey: processGeneration) {
            await gate.wait()
        } else if let gate = cancellationGate {
            cancellationGate = nil
            await gate.wait()
        }
    }

    func directExecuteCount() -> Int { directCount }
    func helperStartCount() -> Int { startCount }
    func helperStartsDuringCleanup() -> Int { startsDuringCleanup }
    func preparedApprovalCount() -> Int { preparedCount }
    func approvedExecuteCount() -> Int { approvedCount }
    func mostRecentPreparation() -> MCPPreparedApproval? { lastPrepared }
    func suspendNextStart(_ gate: ComputerUsePlanningTestGate<Void>) { nextStartGate = gate }
    func failNextStart(_ error: MCPClientError) { nextStartError = error }
    func suspendNextDiscovery(_ gate: ComputerUsePlanningTestGate<Void>) { nextToolsGate = gate }
    func suspendNextPreparation(_ gate: ComputerUsePlanningTestGate<Void>) { nextPreparationGate = gate }

    private func result() throws -> MCPToolResult {
        try MCPToolResult(
            text: resultText,
            structuredContent: structuredContent,
            isError: false,
            wasTruncated: false)
    }
}

@MainActor
private final class StubVisualExecutor:
    ComputerUseExecuting,
    ComputerUseVisualApprovalContinuing {
    let isReady = true
    let runtimeName = "Stub visual fallback"
    let result: ComputerUseExecutionResult
    private(set) var callCount = 0
    private(set) var prompts: [String] = []
    private(set) var trustedUserPrompts: [String] = []
    private(set) var taskIDs: [String] = []
    private(set) var continuations: [ComputerUseVisualApprovalContinuation] = []
    private(set) var continuationActions: [ComputerUsePredictedAction] = []
    private(set) var cancelledContinuations: [ComputerUseVisualApprovalContinuation] = []
    private(set) var performedApprovals: [ComputerUseVisualApprovalContinuation] = []
    private(set) var performedFingerprints: [ComputerUseApprovalFingerprint] = []

    init(result: ComputerUseExecutionResult = .completed("Visual complete")) {
        self.result = result
    }

    func execute(
        prompt: String,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        callCount += 1
        prompts.append(prompt)
        trustedUserPrompts.append(prompt)
        return result
    }

    func execute(
        taskID: String,
        prompt: String,
        trustedUserPrompt: String,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        callCount += 1
        taskIDs.append(taskID)
        prompts.append(prompt)
        trustedUserPrompts.append(trustedUserPrompt)
        return result
    }

    func performApprovedVisualAction(_ continuation: ComputerUseVisualApprovalContinuation,
        action: ComputerUsePredictedAction, fingerprint: ComputerUseApprovalFingerprint,
        tools: ComputerUseHostTools, willBeginEffect: () -> Void) async throws {
        XCTAssertEqual(action, fingerprint.action)
        performedApprovals.append(continuation)
        performedFingerprints.append(fingerprint)
        willBeginEffect()
    }

    func continueAfterApprovedVisualAction(
        _ continuation: ComputerUseVisualApprovalContinuation,
        action: ComputerUsePredictedAction,
        tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void
    ) async throws -> ComputerUseExecutionResult {
        continuations.append(continuation)
        continuationActions.append(action)
        progress("Continuing the approved visual task…")
        return result
    }

    func cancelVisualApprovalContinuation(
        _ continuation: ComputerUseVisualApprovalContinuation
    ) {
        cancelledContinuations.append(continuation)
    }
}

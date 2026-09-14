import AppKit
import ApplicationServices
import CryptoKit
import CoreImage
import XCTest
import Vision
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseNativeTextIntegrationTests: XCTestCase {
    func testSignedHostMacToolsStartAndPrepareApprovalWithoutModels() async throws {
        guard ProcessInfo.processInfo.environment["RUN_SIGNED_INDEPENDENT_MAC_TOOLS_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in signed helper installation and real MCP protocol; no desktop or Mail effects")
        }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            throw NativeTextFixtureFailure.unexpectedOutcome("Signed app-hosted test required")
        }
        // Install the real pinned helper in an isolated root, using the actual
        // download, checksum, signature and notarization checks. Neither model
        // package or inference runtime is present in this composition.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacToolsIntegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = MacControlMCPInstaller(rootDirectory: directory.appendingPathComponent("helper"))
        let receipt = try await installer.install { update in
            FileHandle.standardError.write(Data("Signed Mac tools: \(update.phase.rawValue)\n".utf8))
        }
        let installed = await installer.currentInstallation()
        XCTAssertEqual(installed, receipt)
        let pool = MCPClientPool(mutationLedger: MCPFileMutationCallLedger(fileURL: directory.appendingPathComponent("ledger.json")),
            sessionFactory: { binary, generation in
                MCPClientSession(validatedBinary: binary, processGeneration: generation,
                    stateDirectory: directory.appendingPathComponent("state"))
            })
        do {
            let executor = try await MCPFirstComputerUseExecutor.load(binaryURL: URL(fileURLWithPath: receipt.binaryPath),
                visualFallback: ComputerUseDeferredVisualExecutor(), planner: IntegrationUnavailableMCPPlanner(), clientPool: pool)
            XCTAssertTrue(executor.isReady)
            XCTAssertTrue(executor.hasAdditionalSetup)
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { false })
            let prompt = "Draft an email to codex-acceptance@example.invalid with subject \"Status\" saying Everything is on schedule."
            let result = try await executor.execute(taskID: "signed-no-models", modelPrompt: prompt,
                currentUserPrompt: prompt, conversation: [], tools: tools, progress: { _ in })
            guard case .mcpApprovalRequired(let prepared) = result else {
                throw NativeTextFixtureFailure.unexpectedOutcome("The exact draft must stop at approval without effects")
            }
            XCTAssertEqual(prepared.call.toolName, RemoteDesktopMailMCP.toolName)
            XCTAssertEqual(prepared.call.arguments["to"], .string("codex-acceptance@example.invalid"))
            XCTAssertEqual(prepared.call.arguments["subject"], .string("Status"))
            XCTAssertEqual(prepared.call.arguments["body"], .string("Everything is on schedule."))
            XCTAssertEqual(prepared.call.arguments["send_now"], .bool(false))
            // Never approve or call the Mail tool. Pool teardown also discards
            // the prepared fingerprint and awaits the real sidecar's exit.
            await pool.cancelAll()
            do { _ = try await pool.allowedTools(); XCTFail("The sidecar must be stopped") }
            catch MCPClientError.notRunning { }
        } catch {
            await pool.cancelAll()
            throw error
        }
    }

    func testOptInNativeDesktopCaptureContainsTheFrontmostFixture() async throws {
        try await runFixture(browser: false, captureOnly: true)
    }

    func testOptInNativeScrollUsesBothAxesAndStopsAtDocumentBoundaries() async throws {
        try await runNativeScrollFixture(useHolo: false)
    }

    func testOptInHoloScrollsANativeDocumentAndReportsRevealedText() async throws {
        guard ProcessInfo.processInfo.environment["RUN_HOLO_DESKTOP_ACCEPTANCE"] == "1" else { throw XCTSkip("Opt-in bounded Holo native inference") }
        try await runNativeScrollFixture(useHolo: true)
    }

    private func runNativeScrollFixture(useHolo: Bool) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_COMPUTER_USE_NATIVE_SCROLL_ACCEPTANCE"] == "1" else { throw XCTSkip("Opt-in disposable AppKit scroll fixture") }
        guard AXIsProcessTrusted() else { return XCTFail("Accessibility permission is required") }
        let executable = try XCTUnwrap(environment["COMPUTER_USE_TEXT_FIXTURE_EXECUTABLE"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let state = directory.appendingPathComponent("state.json"), previousApp = NSWorkspace.shared.frontmostApplication
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = [state.path, "--scroll"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            previousApp?.activate(options: []); try? FileManager.default.removeItem(at: directory)
        }
        for _ in 0..<100 {
            if process.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier, FileManager.default.fileExists(atPath: state.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        func read() throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any]) }
        func scalar(_ value: [String: Any], _ key: String) throws -> Double { try XCTUnwrap(value[key] as? Double) }
        var previous = try read()
        guard previous["mode"] as? String == "scroll" else { return XCTFail("A scroll-enabled fixture is required") }
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier })
        let steps: [(Bool, Int)] = [(false, -300), (false, 120), (true, 250), (true, -100), (false, -10_000), (false, -10_000), (true, 10_000), (true, 10_000)]
        let goal = useHolo ? "Find and report the lower section code in this document by scrolling vertically. Keep the horizontal position at the left edge and leave the window open." : "Scroll the native document down, up, right and left, then verify its boundaries. Leave the window open."
        let proposalDirectory = useHolo ? URL(fileURLWithPath: try XCTUnwrap(environment["NATIVE_MODEL_TRIAL_DIRECTORY"])) : directory.appendingPathComponent("proposals")
        try FileManager.default.createDirectory(at: proposalDirectory, withIntermediateDirectories: false)
        var responses: [[String: Any]] = [], diagnosticProbe: HoloProbeProcess?
        let started = Date()
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory.appendingPathComponent("journals"), propose: { input in
            if !useHolo, input.actionError != nil { throw ComputerUseDesktopExecutor.Failure.changedScreen }
            guard responses.count < (useHolo ? 6 : 9) else { throw ComputerUseDesktopExecutor.Failure.stepLimit }
            if !useHolo, !responses.isEmpty {
                var current = try read()
                for _ in 0..<40 {
                    if (current["events"] as? [[String: Any]] ?? []).count >= responses.count { break }
                    try await Task.sleep(for: .milliseconds(25)); current = try read()
                }
                let events = try XCTUnwrap(current["events"] as? [[String: Any]])
                guard events.count == responses.count, events.allSatisfy({ $0["type"] as? String == "scroll" }) else {
                    throw NativeTextFixtureFailure.unexpectedOutcome("Expected exactly one native wheel event per dispatch and no other input: \(events)")
                }
                let step = steps[responses.count - 1], key = step.0 ? "x" : "y", other = step.0 ? "y" : "x"
                let before = try scalar(previous, key), after = try scalar(current, key)
                let increasing = step.0 ? step.1 > 0 : step.1 < 0
                let atLimit = step.1.magnitude == 10_000
                let expectedMax = try scalar(current, step.0 ? "maxX" : "maxY")
                let event = try XCTUnwrap(events.last)
                guard event["precise"] as? Bool == true,
                      try scalar(event, "dx") == Double(step.0 ? -step.1 : 0),
                      try scalar(event, "dy") == Double(step.0 ? 0 : step.1),
                      abs(try scalar(current, other) - scalar(previous, other)) < 0.01,
                      (atLimit ? abs(after - expectedMax) < 1 : (increasing ? after > before : after < before)) else {
                    throw NativeTextFixtureFailure.unexpectedOutcome("Wrong scroll direction, axis or boundary: before=\(previous), after=\(current)")
                }
                previous = current
            }
            let proposal: ComputerUseDesktopProposal
            if useHolo {
                let screen = try tools.currentScreen(), window = try XCTUnwrap(screen.frontmostWindowBounds)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: input.screenshotPNG)), image = try XCTUnwrap(bitmap.cgImage)
                let crop = CGRect(x: (window.minX - screen.displayBounds.minX) / screen.displayBounds.width * CGFloat(image.width),
                    y: (window.minY - screen.displayBounds.minY) / screen.displayBounds.height * CGFloat(image.height),
                    width: window.width / screen.displayBounds.width * CGFloat(image.width), height: window.height / screen.displayBounds.height * CGFloat(image.height)).integral
                let attachment = XCTAttachment(image: NSImage(cgImage: try XCTUnwrap(image.cropping(to: crop)), size: .zero))
                attachment.name = "Native scroll observation \(responses.count)"; attachment.lifetime = .keepAlways; self.add(attachment)
                proposal = try await .init(HoloTestProposalRunner.propose(input: input, directory: proposalDirectory,
                    index: responses.count, environment: environment, memoryLimitGiB: 5, registerProbe: { diagnosticProbe = $0 }))
            } else if responses.count == steps.count {
                proposal = .init(response: "done", action: .reportCompletion("Verified native scrolling."))
            } else {
                let pane = try XCTUnwrap(input.nativeControls?.items.first { $0.description.hasPrefix("AXScrollArea") })
                let step = steps[responses.count], point = pane.bounds1000
                let arguments: [String: Any] = ["action": step.0 ? "hscroll" : "scroll", "pixels": step.1,
                    "coordinate": [point[0] + point[2] / 2, point[1] + point[3] / 2]]
                let wire = "<tool_call>" + String(decoding: try JSONSerialization.data(withJSONObject: ["name": "computer_use", "arguments": arguments]), as: UTF8.self) + "</tool_call>"
                proposal = .init(response: wire, action: try ComputerUseFaraAction.decode(wire))
            }
            responses.append(["response": proposal.response, "actionError": input.actionError ?? "", "nativeControls": input.nativeControls?.jsonObject ?? [:]])
            return proposal
        }, finishRun: { await diagnosticProbe?.cancelAndWait(); diagnosticProbe = nil })
        let run = Task { try await executor.execute(taskID: "native-scroll", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in }) }
        let deadline = Task { try await Task.sleep(for: .seconds(useHolo ? 90 : 40)); run.cancel() }
        var result: ComputerUseExecutionResult?, failure: Error?
        do { result = try await run.value } catch { failure = error }
        deadline.cancel()
        let final = try read(), journals = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("journals"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
        let dispatches = journals.filter { $0.stepIDs == ["native-dispatch-returned"] }.count
        let workersGone = useHolo ? try DarwinOSAtlasProcessInspector().matchingProcesses(for: URL(fileURLWithPath: XCTUnwrap(environment["HOLO_BINARY"]))).isEmpty : true
        let report: [String: Any] = ["scope": useHolo ? "actual-Holo-native-scroll" : "scripted-native-scroll", "goal": goal,
            "responses": responses, "fixtureState": final, "dispatchJournalCount": dispatches, "elapsedSeconds": Date().timeIntervalSince(started),
            "result": result.map { String(describing: $0) } ?? "", "failure": failure.map { String(reflecting: $0) } ?? "",
            "revalidation": executor.lastRevalidationDiagnostic, "ownedWorkerExited": workersGone, "diagnosticWorkerLimitGiB": useHolo ? 5 : 0,
            "wholeApp12GBQualified": false, "fixtureFrontmostAtReturn": NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "Native scroll workflow"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(workersGone)
        if let failure { return XCTFail("Native scroll failed: \(failure); \(executor.lastRevalidationDiagnostic)") }
        guard case .completed(let answer) = result else { return XCTFail("Native scroll did not complete: \(String(describing: result))") }
        XCTAssertTrue(process.isRunning); XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, process.processIdentifier)
        let events = try XCTUnwrap(final["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, dispatches); XCTAssertTrue(events.allSatisfy { $0["type"] as? String == "scroll" })
        if useHolo {
            XCTAssertTrue(answer.contains("FJ-482")); XCTAssertEqual(final["lowerCodeVisible"] as? Bool, true)
            XCTAssertEqual(try scalar(final, "x"), 0, accuracy: 0.01); XCTAssertGreaterThan(dispatches, 0)
        } else { XCTAssertEqual(dispatches, steps.count) }
        let calls = responses.count
        let replay = try await executor.execute(taskID: "native-scroll", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
        XCTAssertEqual(replay, result)
        XCTAssertEqual(responses.count, calls)
        XCTAssertEqual((try read()["events"] as? [[String: Any]])?.count, events.count)
    }

    func testOptInNativeDesktopImageBuildsAllModelRequests() async throws {
        try await runFixture(browser: false, modelRequestOnly: true)
    }

    func testOptInNativeModelLoopEditsPausesAndResumesWithoutReplay() async throws {
        try await runFixture(browser: false, nativeModelLoop: true)
    }

    func testOptInDelayedNativeFieldClickUsesTheWholeEditableRow() async throws {
        try await runFixture(browser: false, nativeModelLoop: true, nativeClickFraction: 0.083, nativeClickDelay: .seconds(3))
    }

    func testOptInInitialNativeFieldClickPreservesAnEmptySibling() async throws {
        try await runFixture(browser: false, nativeModelLoop: true, nativeClickFraction: 0.083,
            nativeClickDelay: .seconds(6), nativeOriginText: "")
    }

    func testOptInNativeTypingAfterPlanningDelayRetainsTheSelectedField() async throws {
        try await runFixture(browser: false, nativeModelLoop: true, nativeClickFraction: 0.49,
            nativeOriginText: "", nativeClickBottomOffset: 112, nativeTypeDelay: .seconds(15))
    }

    func testOptInDelayedNativeCompletionPreservesAnExactFormResult() async throws {
        try await runFixture(browser: false, nativeModelLoop: true, nativeCompletionDelay: .seconds(20))
    }

    func testOptInFaraModelEditsANativeDesktopForm() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_DESKTOP_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in: bounded local Fara Q4 inference and disposable native input")
        }
        try await runFixture(browser: false, actualDesktopModel: .fara)
    }

    func testOptInDiagnosticFaraQ4EditsANativeDesktopForm() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FARA_DESKTOP_DIAGNOSTIC_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in: Fara Q4 native task with an explicit diagnostic 5 GiB worker cap")
        }
        try await runFixture(browser: false, actualDesktopModel: .faraDiagnostic)
    }

    func testOptInGUIOwlModelEditsANativeDesktopForm() async throws {
        guard ProcessInfo.processInfo.environment["RUN_GUI_OWL_DESKTOP_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in: bounded GUI-Owl Q4 inference and disposable native input")
        }
        try await runFixture(browser: false, actualDesktopModel: .guiOwl)
    }

    func testOptInHoloModelEditsANativeDesktopForm() async throws {
        guard ProcessInfo.processInfo.environment["RUN_HOLO_DESKTOP_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in: bounded Holo Q4 inference and disposable native input")
        }
        try await runFixture(browser: false, actualDesktopModel: .holo)
    }

    func testOptInHoloModelFillsBothNativeFieldsWithUnicode() async throws {
        guard ProcessInfo.processInfo.environment["RUN_HOLO_DESKTOP_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in: bounded Holo Q4 inference and disposable native input")
        }
        try await runFixture(browser: false, actualDesktopModel: .holo, nativeModelTask: .init(
            prompt: "Set Origin to exactly Zürich and Destination to exactly 東京. Leave the form open.",
            origin: "Zürich", destination: "東京"))
    }

    func testOptInOneHoloProposalPreservesNativeFieldBinding() async throws {
        guard ProcessInfo.processInfo.environment["RUN_NATIVE_MODEL_BINDING_PROBE"] == "1" else {
            throw XCTSkip("Opt-in: one model proposal with AX diagnostics and no generated input")
        }
        try await runFixture(browser: false, actualDesktopModel: .holo, nativeBindingProbe: true)
    }

    private enum BindingProbeStop: Error { case observed }

    func testNativeKeyChordsRemainLiteralAndRejectAmbiguousSequences() throws {
        for (keys, usage, modifiers) in [(["Alt", "Left"], 0x50, UInt16(4)), (["Left", "Option"], 0x50, 4),
            (["Control", "a"], 0x04, 2), (["Command", "a"], 0x04, 8), (["Shift", "ArrowRight"], 0x4F, 1),
            (["Backspace"], 0x2A, 0), (["Delete"], 0x4C, 0)] {
            XCTAssertEqual(try ComputerUseNativeKeyChord.action(keys), .key(usage: usage, modifiers: modifiers))
        }
        for keys in [[], ["Command"], ["a", "b"], ["Cmd", "Command", "a"], ["Alt", "Option", "Left"], [""], ["😀"]] {
            XCTAssertThrowsError(try ComputerUseNativeKeyChord.action(keys))
        }
    }

    func testNativeTargetedScrollPreservesPointsAndDirectionAcrossProviders() throws {
        let image = try ComputerUseDesktopImage(observation: .init(image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 800)),
            displayBounds: CGRect(x: -640, y: -200, width: 1280, height: 800)))
        for (horizontal, pixels, direction) in [(false, 240, "up"), (false, -240, "down"), (true, 240, "right"), (true, -240, "left")] {
            let name = horizontal ? "hscroll" : "scroll"
            let call = "<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"\(name)\",\"coordinate\":[250,500],\"pixels\":\(pixels)}}</tool_call>"
            let fara = try ComputerUseFaraAction.decode(call)
            let owlData = try JSONSerialization.data(withJSONObject: ["model": ComputerUseGUIOwlModel.modelAlias,
                "choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": "Action: Scroll the observed pane.\n" + call]]]])
            let owl = try XCTUnwrap(ComputerUseGUIOwlModel.decode(owlData).compatibleDesktopProposal().action)
            let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["direction": direction, "distance": abs(pixels), "x": 250, "y": 500]), as: UTF8.self)
            let holoData = try JSONSerialization.data(withJSONObject: ["model": ComputerUseHoloModel.modelAlias,
                "choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "content": "", "tool_calls": [["id": "scroll-case", "type": "function", "function": ["name": "scroll", "arguments": arguments]]]]]]])
            let holo = try ComputerUseHoloModel.decode(holoData).action
            for action in [fara, owl, holo] {
                XCTAssertEqual(try ComputerUseDesktopExecutor.nativeAction(action, image: image),
                    .scroll(x: -320, y: 200, dx: horizontal ? -pixels : 0, dy: horizontal ? 0 : pixels))
            }
            let legacy = try ComputerUseFaraAction.decode("<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"\(name)\",\"pixels\":\(pixels)}}</tool_call>")
            XCTAssertEqual(legacy, .scroll(horizontal: horizontal, pixels: Double(pixels)))
            XCTAssertThrowsError(try ComputerUseDesktopExecutor.nativeAction(legacy, image: image), "Native scrolling cannot guess a target")
        }
    }

    func testNativeScrollRejectsMalformedAmountsAndPartialOrInvalidPoints() throws {
        func fara(_ arguments: String) -> String { "<tool_call>{\"name\":\"computer_use\",\"arguments\":" + arguments + "}</tool_call>" }
        func holo(_ arguments: String) throws -> ComputerUseFaraModel.Proposal {
            try ComputerUseHoloModel.decode(JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "tool_calls", "message": [
                "role": "assistant", "content": "", "tool_calls": [["id": "edge", "type": "function", "function": ["name": "scroll", "arguments": arguments]]]]]]]))
        }
        let invalidAmounts = ["0", "0.5", "10001", "true", "\"240\"", "null", "1e309"]
        for amount in invalidAmounts {
            let call = fara("{\"action\":\"scroll\",\"pixels\":\(amount),\"coordinate\":[250,500]}")
            XCTAssertThrowsError(try ComputerUseFaraAction.decode(call), amount)
            XCTAssertThrowsError(try ComputerUseGUIOwlModel.decode(JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": "Action: Scroll.\n" + call]]]])), amount)
            XCTAssertThrowsError(try holo("{\"direction\":\"down\",\"distance\":\(amount),\"x\":250,\"y\":500}"), amount)
        }
        for coordinate in ["null", "[]", "[250]", "[250,500,1]", "[true,500]", "[250,\"500\"]", "[-1,500]", "[250,1001]", "[250,1e309]"] {
            XCTAssertThrowsError(try ComputerUseFaraAction.decode(fara("{\"action\":\"hscroll\",\"pixels\":240,\"coordinate\":\(coordinate)}")), coordinate)
        }
        for point in ["\"x\":250", "\"y\":500", "\"x\":true,\"y\":500", "\"x\":250.5,\"y\":500", "\"x\":-1,\"y\":500", "\"x\":250,\"y\":1001", "\"x\":250,\"y\":null"] {
            XCTAssertThrowsError(try holo("{\"direction\":\"down\",\"distance\":240,\(point)}"), point)
        }
        let image = try ComputerUseDesktopImage(observation: .init(image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400)), displayBounds: CGRect(x: 0, y: 0, width: 640, height: 400)))
        for amount in [0, 0.5, -0.5, 10_001, -.infinity, .nan] as [Double] {
            XCTAssertThrowsError(try ComputerUseDesktopExecutor.nativeAction(.scrollAt(horizontal: false, pixels: amount, point: .init(x: 500, y: 500)), image: image))
        }
        for point in [ComputerUseFaraAction.Point(x: -1, y: 500), .init(x: 500, y: 1001), .init(x: .nan, y: 500)] {
            XCTAssertThrowsError(try ComputerUseDesktopExecutor.nativeAction(.scrollAt(horizontal: false, pixels: -240, point: point), image: image))
        }
    }

    func testNativeScrollRejectsOutsideWindowAndChangedObservationBeforeInput() async throws {
        for scenario in ["outside", "window moved", "authority changed", "missing point"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var frame = CGRect(x: 100, y: 50, width: 200, height: 200), focus = "pane", calls = 0, effects = 0
            let tools = desktopTestTools(focus: { focus }, window: { frame }, perform: { _ in effects += 1 })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
                calls += 1
                if calls == 1 {
                    if scenario == "window moved" { frame.origin.x += 20 }
                    if scenario == "authority changed" { focus = "different pane" }
                    let action: ComputerUseFaraAction = scenario == "missing point" ? .scroll(horizontal: false, pixels: -240) :
                        .scrollAt(horizontal: false, pixels: -240, point: scenario == "outside" ? .init(x: 900, y: 900) : .init(x: 300, y: 300))
                    return .init(response: "scroll", action: action)
                }
                XCTAssertEqual(calls, 2); XCTAssertNotNil(input.actionError, scenario)
                if scenario == "missing point" { XCTAssertTrue(input.actionError?.contains("explicit coordinate") == true) }
                return .init(response: "stop", action: .reportCompletion("No scroll was sent"))
            })
            let result = try await executor.execute(taskID: "scroll-boundary", prompt: "Scroll the observed pane", trustedUserPrompt: "Scroll the observed pane", tools: tools, progress: { _ in })
            XCTAssertEqual(result, .completed("No scroll was sent")); XCTAssertEqual(effects, 0, scenario)
            let journals = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
                .map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
            XCTAssertFalse(journals.contains { $0.stepIDs == ["native-dispatch-returned"] }, scenario)
        }
    }

    private final class ScrollInterruptionEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [CGEventType] = []
        private var restored = false
        let stopAfter: Int
        init(stopAfter: Int) { self.stopAfter = stopAfter }
        func record(_ event: CGEvent) { lock.lock(); defer { lock.unlock() }; events.append(event.type) }
        var allowed: Bool { lock.lock(); defer { lock.unlock() }; return restored || events.count < stopAfter }
        var types: [CGEventType] { lock.lock(); defer { lock.unlock() }; return events }
        func restore() { lock.lock(); defer { lock.unlock() }; restored = true }
    }

    func testNativeScrollWithdrawalBetweenPointerAndWheelCannotReplay() async throws {
        for stopAfter in [1, 2] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let events = ScrollInterruptionEvents(stopAfter: stopAfter)
            let tools = desktopTestTools(injector: InputInjector(eventPoster: { events.record($0) }), mayAct: { events.allowed })
            var proposals = 0
            let propose: ComputerUseDesktopExecutor.Propose = { _ in
                proposals += 1
                return .init(response: "scroll", action: .scrollAt(horizontal: false, pixels: -240, point: .init(x: 500, y: 500)))
            }
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: propose)
            do { _ = try await executor.execute(taskID: "scroll-interrupted", prompt: "Scroll down", trustedUserPrompt: "Scroll down", tools: tools, progress: { _ in }); XCTFail("Partial native dispatch must not complete") } catch { }
            XCTAssertEqual(events.types.first, .mouseMoved)
            XCTAssertEqual(events.types.count, stopAfter)
            XCTAssertEqual(events.types.filter { $0 == .scrollWheel }.count, stopAfter - 1)
            events.restore()
            let resumed = try await executor.execute(taskID: "scroll-interrupted", prompt: "Scroll down", trustedUserPrompt: "Scroll down", tools: tools, progress: { _ in })
            guard case .unableToComplete = resumed else { return XCTFail("Uncertain wheel dispatch became successful") }
            let restarted = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: propose)
            do { _ = try await restarted.execute(taskID: "scroll-interrupted", prompt: "Scroll down", trustedUserPrompt: "Scroll down", tools: tools, progress: { _ in }); XCTFail("Restart replayed uncertain wheel dispatch") } catch { }
            XCTAssertEqual(proposals, 1); XCTAssertEqual(events.types.count, stopAfter)
            let journals = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
                .map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
            XCTAssertEqual(journals.filter { $0.statuses == [.uncertain] }.count, 1)
        }
    }

    func testFaraDesktopRequestAdvertisesOnlyImplementedNativeCapabilities() throws {
        let image = try ComputerUseDesktopImage(observation: .init(
            image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400)),
            displayBounds: CGRect(x: 0, y: 0, width: 640, height: 400)))
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil,
            baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
        let goal = "Edit the current document."
        let native = ComputerUseFaraModel.Input(goal: goal, screenshotPNG: image.png, surface: .desktop)
        func system(_ input: ComputerUseFaraModel.Input) throws -> String {
            let request = try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: input)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            return try XCTUnwrap(messages.first?["content"] as? String)
        }
        let prompt = try system(native)
        let start = try XCTUnwrap(prompt.range(of: "<tools>\n"))
        let end = try XCTUnwrap(prompt.range(of: "</tools>", range: start.upperBound..<prompt.endIndex))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(prompt[start.upperBound..<end.lowerBound].utf8)) as? [String: Any])
        let function = try XCTUnwrap(schema["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        let actions = try XCTUnwrap(properties["action"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(actions["enum"] as? [String])),
            Set(["key", "type", "left_click", "right_click", "double_click", "triple_click", "scroll", "hscroll", "wait", "pause_and_memorize_fact", "terminate"]))
        XCTAssertEqual(function["name"] as? String, "computer_use")
        XCTAssertTrue(prompt.contains("macOS")); XCTAssertTrue(prompt.contains("Command"))
        XCTAssertTrue(prompt.contains("<tool_call>"))
        XCTAssertEqual(try system(.init(goal: goal, screenshotPNG: image.png)), ComputerUseFaraModel.officialSystemPrompt)
        var mixed = native; mixed.currentURL = URL(string: "https://example.com")
        XCTAssertThrowsError(try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: mixed))
        mixed = native; mixed.userResponse = "An answer from another surface"
        XCTAssertThrowsError(try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: mixed))
        XCTAssertThrowsError(try ComputerUseHoloModel.makeRequest(endpoint: endpoint, input: mixed))
        XCTAssertThrowsError(try ComputerUseGUIOwlModel.makeRequest(endpoint: endpoint, input: mixed))
    }

    private func desktopTestTools(focus: @escaping () -> String = { "field" },
        textEditor: ComputerUseTextEditor? = nil,
        injector: InputInjector = InputInjector(), mayAct: @escaping () -> Bool = { true },
        window: @escaping () -> CGRect = { CGRect(x: 0, y: 0, width: 640, height: 400) },
        perform: ((ComputerUsePredictedAction) throws -> Void)? = nil) -> ComputerUseHostTools {
        ComputerUseHostTools(injector: injector, mayAct: mayAct,
            approvalTargetProvider: { _ in .init(context: "AXTextField Query", applicationID: "fixture", accessibilityIdentity: focus()) },
            actionPerformer: perform, textEditor: textEditor,
            screenProvider: { .init(image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400)),
                displayBounds: CGRect(x: 0, y: 0, width: 640, height: 400), frontmostWindowBounds: window()) },
            transientSystemOverlayProvider: { _ in false }, accessibilityContextProvider: { _ in "AXTextField Query" },
            authenticationContextProvider: { nil }, screenCaptureConsentContextProvider: { nil },
            planningAccessibilityIdentityProvider: focus, frontmostApplicationProvider: { "Fixture" })
    }

    func testGUIOwlNativeStatusAndManualHandoffRemainDistinct() async throws {
        for mode in ["success", "failure", "handoff"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var calls = 0, effects = 0, firstResponse: String?
            let tools = desktopTestTools(perform: { _ in effects += 1 })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
                calls += 1
                guard calls <= 2 else { throw ComputerUseDesktopExecutor.Failure.stepLimit }
                let arguments: [String: String]
                if calls == 2 {
                    XCTAssertEqual(mode, "handoff"); XCTAssertEqual(input.history.count, 1)
                    XCTAssertEqual(input.history.first?.response, firstResponse)
                    XCTAssertNil(input.history.first?.action); XCTAssertNil(input.userResponse)
                    arguments = ["action": "answer", "text": "The requested step is finished."]
                } else if mode == "handoff" {
                    arguments = ["action": "interact", "text": "Complete the local step – 東京, then Resume."]
                } else { arguments = ["action": "terminate", "status": mode] }
                let body = try JSONSerialization.data(withJSONObject: ["name": "computer_use", "arguments": arguments])
                let response = "Action: Follow the current task.\n<tool_call>" + String(decoding: body, as: UTF8.self) + "</tool_call>"
                if calls == 1 { firstResponse = response }
                let packet = try JSONSerialization.data(withJSONObject: ["model": ComputerUseGUIOwlModel.modelAlias,
                    "choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": response]]]])
                return try ComputerUseGUIOwlModel.decode(packet).compatibleDesktopProposal()
            })
            do {
                let result = try await executor.execute(taskID: mode, prompt: "Complete the current local step", trustedUserPrompt: "Complete the current local step", tools: tools, progress: { _ in })
                switch (mode, result) {
                case ("success", .completed): break
                case ("failure", .unableToComplete): break
                case ("handoff", .userInterventionRequired(let message)):
                    XCTAssertEqual(message, "Complete the local step – 東京, then Resume."); XCTAssertEqual(calls, 1)
                    let resumed = try await executor.execute(taskID: mode, prompt: "Complete the current local step", trustedUserPrompt: "Complete the current local step", tools: tools, progress: { _ in })
                    XCTAssertEqual(resumed, .completed("The requested step is finished.")); XCTAssertEqual(calls, 2)
                default: XCTFail("Incorrect native outcome for \(mode): \(result)")
                }
                let count = calls
                _ = try await executor.execute(taskID: mode, prompt: "Complete the current local step", trustedUserPrompt: "Complete the current local step", tools: tools, progress: { _ in })
                XCTAssertEqual(calls, count); XCTAssertEqual(effects, 0)
            } catch { XCTFail("Native GUI-Owl \(mode) could not continue: \(error)") }
        }
    }

    func testNativeCandidateProfilesDeclareMacEffectsAndKeepSeparateProtocols() throws {
        let image = try ComputerUseDesktopImage(observation: .init(
            image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400)),
            displayBounds: CGRect(x: 0, y: 0, width: 640, height: 400)))
        let input = ComputerUseFaraModel.Input(goal: "Edit the current form.", screenshotPNG: image.png, surface: .desktop)
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil,
            baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
        let holo = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(ComputerUseHoloModel.makeRequest(endpoint: endpoint, input: input).httpBody)) as? [String: Any])
        let holoTools = try XCTUnwrap(holo["tools"] as? [[String: Any]]).compactMap { $0["function"] as? [String: Any] }
        XCTAssertEqual(Set(holoTools.compactMap { $0["name"] as? String }), Set(["click", "type", "key", "scroll", "wait", "answer"]))
        let key = try XCTUnwrap(holoTools.first { $0["name"] as? String == "key" }?["description"] as? String)
        XCTAssertTrue(key.contains("Command")); XCTAssertTrue(key.contains("Control")); XCTAssertFalse(key.contains("browser"))
        let owl = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(ComputerUseGUIOwlModel.makeRequest(endpoint: endpoint, input: input).httpBody)) as? [String: Any])
        XCTAssertNil(owl["tools"], "GUI-Owl must keep its XML protocol")
        let messages = try XCTUnwrap(owl["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        let prompt = try XCTUnwrap(content.first?["text"] as? String)
        let start = try XCTUnwrap(prompt.range(of: "<tools>\n"))
        let end = try XCTUnwrap(prompt.range(of: "</tools>", range: start.upperBound..<prompt.endIndex))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(prompt[start.upperBound..<end.lowerBound].utf8)) as? [String: Any])
        let function = try XCTUnwrap(schema["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        let action = try XCTUnwrap(properties["action"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(action["enum"] as? [String])),
            Set(["key", "type", "left_click", "right_click", "double_click", "triple_click", "scroll", "hscroll", "wait", "answer", "terminate", "interact"]))
        XCTAssertNil(properties["answer"]); XCTAssertNil(properties["fact"])
        let status = try XCTUnwrap(properties["status"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(status["enum"] as? [String])), Set(["success", "failure"]))
    }

    func testNativeProvidersRetainObservedEditorWithItsScreenshot() throws {
        let image = try ComputerUseDesktopImage(observation: .init(
            image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400)),
            displayBounds: CGRect(x: 0, y: 0, width: 640, height: 400)))
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil,
            baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
        let previousEditor = "Archive – 東京", currentEditor = "Search – e\u{301}"
        let fara = "<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"wait\",\"time\":0}}</tool_call>"
        let holo = "{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"focus-1\",\"type\":\"function\",\"function\":{\"name\":\"wait\",\"arguments\":\"{\\\"time\\\":0}\"}}]}"
        let variants: [(String, String, (OSAtlasLlamaEndpoint, ComputerUseFaraModel.Input) throws -> URLRequest)] = [
            ("Fara", fara, ComputerUseFaraModel.makeRequest),
            ("GUI-Owl", "Action: Wait for the interface.\n" + fara, ComputerUseGUIOwlModel.makeRequest),
            ("Holo", holo, ComputerUseHoloModel.makeRequest)]
        for (name, response, build) in variants {
            var input = ComputerUseFaraModel.Input(goal: "Edit the requested field.", screenshotPNG: image.png,
                surface: .desktop, history: [.init(screenshotPNG: image.png, response: response, focusedEditor: previousEditor)],
                actionError: "The previous click was not performed.", focusedEditor: currentEditor)
            let body = try XCTUnwrap(build(endpoint, input).httpBody)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
            let observations = messages.filter { $0["role"] as? String == "user" }.map { message in
                (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            XCTAssertTrue(try XCTUnwrap(observations.first).contains(previousEditor), name)
            XCTAssertTrue(try XCTUnwrap(observations.last).contains(currentEditor), name)
            XCTAssertTrue(try XCTUnwrap(observations.last).contains("focused_editor"), name)
            input.focusedEditor = String(repeating: "x", count: 1_025)
            XCTAssertThrowsError(try build(endpoint, input), name)
            input.focusedEditor = currentEditor; input.surface = .browser
            XCTAssertThrowsError(try build(endpoint, input), name)
        }
    }

    func testNativeModelsObserveInvisibleTextAndSelectionAfterAKeyEffect() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var value = "", selection = NSRange(location: 0, length: 0), calls = 0
        let editor = ComputerUseTextEditor(read: {
            .init(targetID: "same-editor", value: value, selection: selection, isEditable: true, isSecure: false)
        }, select: { _, _ in XCTFail("No selection setter expected"); return false },
            replaceSelectedText: { _, _ in XCTFail("No text setter expected"); return nil },
            postUnicode: { _, _ in XCTFail("No Unicode posting expected") }, mayAct: { true })
        let tools = desktopTestTools(textEditor: editor, perform: { action in
            XCTAssertEqual(action, .key(usage: 0x2B, modifiers: 0))
            value = "\t"; selection = NSRange(location: 1, length: 0)
        })
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil, baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
        let providers: [(String, (OSAtlasLlamaEndpoint, ComputerUseFaraModel.Input) throws -> URLRequest)] = [
            ("Fara", ComputerUseFaraModel.makeRequest), ("GUI-Owl", ComputerUseGUIOwlModel.makeRequest), ("Holo", ComputerUseHoloModel.makeRequest)]
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
            defer { calls += 1 }
            var current = input; current.history = []
            for (name, build) in providers {
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(build(endpoint, current).httpBody)) as? [String: Any])
                let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                let texts = messages.filter { $0["role"] as? String == "user" }.flatMap { $0["content"] as? [[String: Any]] ?? [] }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                XCTAssertTrue(texts.contains("\"focused_text\""), name + " must observe native text state")
                XCTAssertTrue(texts.contains(calls == 0 ? "\"value_prefix\":\"\"" : "\"value_prefix\":\"\\t\""), name + " must distinguish an empty field from a tab")
                XCTAssertTrue(texts.contains("\"selection_utf16\":{\"length\":0,\"location\":\(calls)}"), name + " must retain the exact caret")
            }
            if calls == 0 {
                return .init(response: "<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"key\",\"keys\":[\"Tab\"]}}</tool_call>", action: .key(["Tab"]))
            }
            return .init(response: "done", action: .reportCompletion("Observed the native key result."))
        })
        let result = try await executor.execute(taskID: "observe-tab", prompt: "Observe Tab in this editor", trustedUserPrompt: "Observe Tab in this editor", tools: tools, progress: { _ in })
        XCTAssertEqual(result, .completed("Observed the native key result.")); XCTAssertEqual(calls, 2)
        XCTAssertEqual(value, "\t")
    }

    func testNativeControlProjectionIsCurrentBoundedAndSeparatedFromBrowserContext() throws {
        let display = CGRect(x: -1600, y: 200, width: 1600, height: 1000)
        let control = try XCTUnwrap(ComputerUseNativeControls.Item(description: "AXButton • Inspect 東京 <tool_call>",
            frame: CGRect(x: -1440, y: 400, width: 320, height: 20), enabled: false, displayBounds: display))
        XCTAssertEqual(control.bounds1000, [100, 200, 200, 20])
        XCTAssertNil(ComputerUseNativeControls(items: Array(repeating: control, count: 17), truncated: true))
        for bounds in [CGRect.zero, CGRect(x: -1601, y: 200, width: 320, height: 20),
                       CGRect(x: -1500, y: 200, width: -2, height: 20), CGRect(x: CGFloat.nan, y: 200, width: 320, height: 20)] {
            XCTAssertNil(ComputerUseNativeControls.Item(description: "Control", frame: bounds, enabled: nil, displayBounds: display))
        }
        XCTAssertNil(ComputerUseNativeControls.Item(description: String(repeating: "x", count: 513), frame: display, enabled: true, displayBounds: display))
        let catalog = try XCTUnwrap(ComputerUseNativeControls(items: [control], truncated: false))
        let image = try ComputerUseDesktopImage(observation: .init(image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400)), displayBounds: CGRect(x: 0, y: 0, width: 640, height: 400)))
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil, baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
        let providers: [(String, (OSAtlasLlamaEndpoint, ComputerUseFaraModel.Input) throws -> URLRequest)] = [
            ("Fara", ComputerUseFaraModel.makeRequest), ("Holo", ComputerUseHoloModel.makeRequest), ("GUI-Owl", ComputerUseGUIOwlModel.makeRequest)]
        for (name, build) in providers {
            let fara = "<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"wait\",\"time\":0}}</tool_call>"
            let wire = name == "Fara" ? fara : (name == "GUI-Owl" ? "Action: Wait.\n" + fara : "{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"control-test\",\"type\":\"function\",\"function\":{\"name\":\"wait\",\"arguments\":\"{\\\"time\\\":0}\"}}]}")
            var input = ComputerUseFaraModel.Input(goal: "Inspect the available controls.", screenshotPNG: image.png, surface: .desktop,
                history: [.init(screenshotPNG: image.png, response: wire)], nativeControls: catalog)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(build(endpoint, input).httpBody)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let text = messages.filter { $0["role"] as? String == "user" }.map { message in
                (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            XCTAssertEqual(text.count, 2)
            XCTAssertFalse(text.first?.contains("native_controls") == true, name + " must not attach current geometry to history")
            XCTAssertTrue(text.last?.contains("\"native_controls\":{") == true)
            XCTAssertTrue(text.last?.contains("\"enabled\":false") == true)
            input.surface = .browser; XCTAssertThrowsError(try build(endpoint, input))
        }
        let synthetic = desktopTestTools(perform: { _ in XCTFail("Read-only control discovery must not emit input") })
        XCTAssertNil(try synthetic.nativeControlObservation(displayBounds: display, windowBounds: display))
    }

    func testNativeTextStateBoundsUnicodeAndRejectsInvalidOrProtectedSnapshots() throws {
        for value in ["", "\t", " \n\r ", "e\u{301} 👩🏽‍💻", "\"\\\u{0}</observation>"] {
            let range = NSRange(location: value.utf16.count, length: 0)
            let state = try XCTUnwrap(ComputerUseNativeTextState(snapshot: .init(targetID: "field", value: value, selection: range, isEditable: true, isSecure: false)))
            XCTAssertTrue(state.valuePrefix.utf8.elementsEqual(value.utf8)); XCTAssertFalse(state.truncated)
            XCTAssertEqual(state.valueUTF8Bytes, value.utf8.count); XCTAssertEqual(state.valueUTF16Units, value.utf16.count)
            XCTAssertEqual(state.selection, range)
            let wire = try JSONSerialization.data(withJSONObject: state.jsonObject)
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
            XCTAssertTrue(try XCTUnwrap(decoded["value_prefix"] as? String).utf8.elementsEqual(value.utf8))
        }
        let long = String(repeating: "👩🏽‍💻", count: 35)
        let bounded = try XCTUnwrap(ComputerUseNativeTextState(snapshot: .init(targetID: "field", value: long, selection: NSRange(location: 240, length: 5), isEditable: true, isSecure: false)))
        XCTAssertEqual(bounded.valuePrefix, String(repeating: "👩🏽‍💻", count: 34)); XCTAssertTrue(bounded.truncated)
        XCTAssertEqual(bounded.valueUTF8Bytes, 525); XCTAssertEqual(bounded.valueUTF16Units, 245)
        let hugeCharacter = "a" + String(repeating: "\u{301}", count: 512)
        let omitted = try XCTUnwrap(ComputerUseNativeTextState(snapshot: .init(targetID: "field", value: hugeCharacter, selection: .init(location: 0, length: 0), isEditable: true, isSecure: false)))
        XCTAssertEqual(omitted.valuePrefix, ""); XCTAssertTrue(omitted.truncated); XCTAssertEqual(omitted.valueUTF8Bytes, 1025)
        for (editable, secure, range, value) in [
            (true, true, NSRange(location: 0, length: 0), "private"), (false, false, NSRange(location: 0, length: 0), "disabled"),
            (true, false, NSRange(location: -1, length: 0), "x"), (true, false, NSRange(location: 0, length: -1), "x"),
            (true, false, NSRange(location: Int.max, length: Int.max), "x"), (true, false, NSRange(location: 1, length: 1), "x"),
            (true, false, NSRange(location: 0, length: 0), String(repeating: "x", count: 1_048_577))] {
            XCTAssertNil(ComputerUseNativeTextState(snapshot: .init(targetID: "field", value: value, selection: range, isEditable: editable, isSecure: secure)))
        }
    }

    func testNativeTextObservationRejectsProtectedChangedOrWithdrawnState() throws {
        for mode in ["secure", "became-secure", "disabled", "missing", "identity", "value", "selection", "pause", "password-context"] {
            var reads = 0, allowed = true
            let editor = ComputerUseTextEditor(read: {
                reads += 1
                if mode == "missing" { return nil }
                if mode == "pause", reads == 2 { allowed = false }
                return .init(targetID: mode == "identity" && reads == 2 ? "new-field" : "field",
                    value: mode == "value" && reads == 2 ? "changed" : "private-value",
                    selection: NSRange(location: mode == "selection" && reads == 2 ? 1 : 0, length: 0),
                    isEditable: mode != "disabled", isSecure: mode == "secure" || (mode == "became-secure" && reads == 2))
            }, select: { _, _ in XCTFail("No effect"); return false }, replaceSelectedText: { _, _ in XCTFail("No effect"); return nil },
                postUnicode: { _, _ in XCTFail("No effect") }, mayAct: { allowed })
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { allowed }, textEditor: editor,
                accessibilityContextProvider: { _ in mode == "password-context" ? "AXSecureTextField Password" : "AXTextArea Notes" })
            if mode == "pause" { XCTAssertThrowsError(try tools.nativeFocusedEditorObservation()) }
            else { XCTAssertNil(try tools.nativeFocusedEditorObservation(), mode) }
            if mode == "password-context" { XCTAssertEqual(reads, 0, "Reject a protected context before reading values") }
        }
    }

    func testNativeTextHistoryKeepsOriginalOutcomesAndRejectsOrphanedOrOversizedState() throws {
        let image = try ComputerUseDesktopImage(observation: .init(image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400)), displayBounds: CGRect(x: 0, y: 0, width: 640, height: 400)))
        let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil, baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
        func state(_ value: String) throws -> ComputerUseNativeTextState {
            try XCTUnwrap(.init(snapshot: .init(targetID: "field", value: value, selection: .init(location: value.utf16.count, length: 0), isEditable: true, isSecure: false)))
        }
        let providers: [(String, (OSAtlasLlamaEndpoint, ComputerUseFaraModel.Input) throws -> URLRequest)] = [
            ("Fara", ComputerUseFaraModel.makeRequest), ("GUI-Owl", ComputerUseGUIOwlModel.makeRequest), ("Holo", ComputerUseHoloModel.makeRequest)]
        for (name, build) in providers {
            func wire(_ index: Int) throws -> String {
                let fara = "<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"wait\",\"time\":0}}</tool_call>"
                if name == "Fara" { return fara }
                if name == "GUI-Owl" { return "Action: Inspect current state.\n" + fara }
                return String(decoding: try JSONSerialization.data(withJSONObject: ["role": "assistant", "content": "", "tool_calls": [["id": "state-\(index)", "type": "function", "function": ["name": "wait", "arguments": "{\"time\":0}"]]]]), as: UTF8.self)
            }
            var history: [ComputerUseFaraModel.Step] = try (0..<3).map { .init(screenshotPNG: image.png, response: try wire($0), focusedEditor: "Earlier editor \($0)", focusedTextState: try state($0 == 0 ? "\t" : "earlier-\($0)")) }
            history[0].resultObservation = .init(currentURL: nil, userResponse: nil, actionError: "Original feedback", focusedEditor: "Original next editor", focusedTextState: try state("original-next\n\t"))
            var input = ComputerUseFaraModel.Input(goal: "Inspect the editor state.", screenshotPNG: image.png, surface: .desktop,
                history: history, focusedEditor: "Current editor", focusedTextState: try state("current-e\u{301}"))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(build(endpoint, input).httpBody)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let text = messages.flatMap { message -> [String] in
                if let value = message["content"] as? String { return [value] }
                return (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            }.joined(separator: "\n")
            for value in ["\t", "original-next\n\t", "current-e\u{301}"] {
                let expected = String(decoding: try JSONSerialization.data(withJSONObject: ["value_prefix": value], options: .withoutEscapingSlashes), as: UTF8.self).dropFirst().dropLast()
                XCTAssertTrue(text.contains(expected), name + " lost a native observation: \(value.debugDescription)")
            }
            input.focusedEditor = nil; XCTAssertThrowsError(try build(endpoint, input), "State without its editor is ambiguous")
            input.focusedEditor = "Current editor"; input.surface = .browser; XCTAssertThrowsError(try build(endpoint, input))
            input.surface = .desktop; input.history[0].resultObservation?.focusedEditor = nil; XCTAssertThrowsError(try build(endpoint, input))
            input.history[0].resultObservation = .init(currentURL: nil, userResponse: nil, actionError: String(repeating: "x", count: 16_385),
                focusedEditor: "Original next editor", focusedTextState: try state("original-next\n\t"))
            XCTAssertThrowsError(try build(endpoint, input), name + " must bound the captured outcome error")
            input.history = try (0..<20).map { .init(screenshotPNG: image.png, response: try wire($0), focusedEditor: String(repeating: "x", count: 1024), focusedTextState: try state(String(repeating: "\u{0}", count: 512))) }
            XCTAssertThrowsError(try build(endpoint, input), name + " must bound serialized text including JSON escaping")
        }
    }

    func testNativeFocusDescriptionRequiresAnEditableTargetAndBoundsUnicode() throws {
        var context = "AXTextArea Notes – 東京", permitted = true
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { permitted },
            accessibilityContextProvider: { _ in context })
        XCTAssertEqual(try tools.nativeFocusedEditorDescription(), context)
        for rejected in ["AXButton Continue", "AXSecureTextField Password", "AXTextField enabled=false", "AXTextArea editable=false"] {
            context = rejected; XCTAssertNil(try tools.nativeFocusedEditorDescription(), rejected)
        }
        context = "AXComboBox " + String(repeating: "👩🏽‍💻", count: 100)
        let bounded = try XCTUnwrap(tools.nativeFocusedEditorDescription())
        XCTAssertLessThanOrEqual(bounded.utf8.count, 1_024)
        XCTAssertTrue(bounded.hasSuffix("👩🏽‍💻")); XCTAssertTrue(context.hasPrefix(bounded))
        permitted = false; XCTAssertThrowsError(try tools.nativeFocusedEditorDescription())
    }

    func testNativeDesktopApprovalIsSingleUseAndCannotReviveAfterTargetRejection() async throws {
        for changed in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var focus = "field", effects = 0, calls = 0
            let tools = desktopTestTools(focus: { focus }, perform: { _ in effects += 1 })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
                calls += 1
                return calls == 1 ? .init(response: "return", action: .key(["Return"])) : .init(response: "done", action: .reportCompletion("Done"))
            })
            let pending = try await executor.execute(taskID: "approval", prompt: "Press Return", trustedUserPrompt: "Press Return", tools: tools, progress: { _ in })
            guard case .approvalRequired(_, let action, let token) = pending else { return XCTFail("Expected native approval") }
            let fingerprint = try tools.prepareNativeActionFingerprint(for: action)
            if changed {
                focus = "changed field"
                do { try await executor.performApprovedVisualAction(token, action: action, fingerprint: fingerprint, tools: tools, willBeginEffect: {}); XCTFail("Changed target executed") } catch { }
                focus = "field"
                do { try await executor.performApprovedVisualAction(token, action: action, fingerprint: fingerprint, tools: tools, willBeginEffect: {}); XCTFail("Rejected approval revived") } catch { }
                XCTAssertEqual(effects, 0)
            } else {
                try await executor.performApprovedVisualAction(token, action: action, fingerprint: fingerprint, tools: tools, willBeginEffect: {})
                do { try await executor.performApprovedVisualAction(token, action: action, fingerprint: fingerprint, tools: tools, willBeginEffect: {}); XCTFail("Approval replay executed") } catch { }
                do { _ = try await executor.execute(taskID: "approval", prompt: "Press Return", trustedUserPrompt: "Press Return", tools: tools, progress: { _ in }); XCTFail("Performed approval was offered again") } catch { }
                let result = try await executor.continueAfterApprovedVisualAction(token, action: action, tools: tools, progress: { _ in })
                XCTAssertEqual(result, .completed("Done")); XCTAssertEqual(effects, 1); XCTAssertEqual(calls, 2)
            }
        }
    }

    func testNativeDesktopUncertainEffectCannotReplayOnResumeOrRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var effects = 0, proposals = 0
        let tools = desktopTestTools(perform: { _ in effects += 1; throw ComputerUseTextEditError.deliveryUncertain })
        let propose: ComputerUseDesktopExecutor.Propose = { _ in proposals += 1; return .init(response: "type", action: .typeText("Tokyo")) }
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: propose)
        do { _ = try await executor.execute(taskID: "uncertain", prompt: "Type Tokyo", trustedUserPrompt: "Type Tokyo", tools: tools, progress: { _ in }); XCTFail("Expected uncertain effect") } catch { }
        let resumed = try await executor.execute(taskID: "uncertain", prompt: "Type Tokyo", trustedUserPrompt: "Type Tokyo", tools: tools, progress: { _ in })
        guard case .unableToComplete = resumed else { return XCTFail("Uncertain action became complete") }
        let restarted = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: propose)
        do { _ = try await restarted.execute(taskID: "uncertain", prompt: "Type Tokyo", trustedUserPrompt: "Type Tokyo", tools: tools, progress: { _ in }); XCTFail("Recovered uncertain action executed") } catch { }
        XCTAssertEqual(effects, 1); XCTAssertEqual(proposals, 1)
        let journals = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
        XCTAssertEqual(journals.filter { $0.statuses == [.uncertain] }.count, 1)
    }

    func testNativeDesktopCancellationRejectsLateProposalAndConcurrentExecution() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "Native proposal entered")
        let returned = expectation(description: "Late proposal returned")
        var release: CheckedContinuation<ComputerUseDesktopProposal, Never>?
        var effects = 0, finishes = 0
        let tools = desktopTestTools(perform: { _ in effects += 1 })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            let result = await withCheckedContinuation { release = $0; started.fulfill() }
            returned.fulfill()
            return result
        }, finishRun: { finishes += 1 })
        let run = Task { try await executor.execute(taskID: "cancel", prompt: "Type text", trustedUserPrompt: "Type text", tools: tools, progress: { _ in }) }
        await fulfillment(of: [started], timeout: 2)
        do { _ = try await executor.execute(taskID: "other", prompt: "Other", trustedUserPrompt: "Other", tools: tools, progress: { _ in }); XCTFail("Concurrent task entered") }
        catch { XCTAssertEqual(error as? ComputerUseTaskExecutionError, .alreadyExecuting) }
        run.cancel()
        do { _ = try await run.value; XCTFail("Cancelled task returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        release?.resume(returning: .init(response: "late", action: .typeText("Must not appear")))
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(effects, 0); XCTAssertEqual(finishes, 1)
        let journals = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
        XCTAssertFalse(journals.contains { $0.stepIDs == ["native-dispatch-returned"] })
    }

    func testNativeDiagnosticCancellationJoinsItsProcessBeforeReturning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("probe.sh")
        let started = directory.appendingPathComponent("started"), cleaned = directory.appendingPathComponent("cleaned")
        try """
        started_path=$1
        cleaned_path=$2
        cleanup() {
            trap '' TERM
            kill "$child" 2>/dev/null
            wait "$child" 2>/dev/null
            sleep 0.3
            printf joined > "$cleaned_path"
            exit 0
        }
        trap cleanup TERM
        sleep 30 &
        child=$!
        printf started > "$started_path"
        wait "$child"
        cleanup
        """.write(to: script, atomically: true, encoding: .utf8)
        let probe = HoloProbeProcess()
        let returned = expectation(description: "Diagnostic process joined")
        var effects = 0
        let tools = desktopTestTools(perform: { _ in effects += 1 })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory.appendingPathComponent("journal"), propose: { _ in
            defer { returned.fulfill() }
            try probe.start(python: "/bin/sh", script: script.path, arguments: [started.path, cleaned.path])
            _ = try await probe.finish()
            return .init(response: "late", action: .typeText("Must not appear"))
        }, finishRun: { await probe.cancelAndWait() })
        let run = Task { try await executor.execute(taskID: "probe-cancel", prompt: "Type text", trustedUserPrompt: "Type text", tools: tools, progress: { _ in }) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: started.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        run.cancel()
        do { _ = try await run.value; XCTFail("Cancelled diagnostic returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleaned.path), "The executor must join its diagnostic process before returning")
        await fulfillment(of: [returned], timeout: 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleaned.path))
        XCTAssertEqual(effects, 0)
    }

    func testNativeDesktopCancellationAfterDispatchRetainsHistoryOnResume() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var run: Task<ComputerUseExecutionResult, Error>?
        var effects = 0, proposals = 0
        let tools = desktopTestTools(perform: { _ in effects += 1; run?.cancel() })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
            proposals += 1
            if proposals == 1 { return .init(response: "type", action: .typeText("One edit")) }
            XCTAssertEqual(input.history.count, 1)
            XCTAssertEqual(input.history.first?.action, .typeText("One edit"))
            return .init(response: "done", action: .reportCompletion("Done"))
        })
        run = Task { try await executor.execute(taskID: "after", prompt: "One edit", trustedUserPrompt: "One edit", tools: tools, progress: { _ in }) }
        do { _ = try await run?.value; XCTFail("Post-dispatch cancellation returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        let resumed = try await executor.execute(taskID: "after", prompt: "One edit", trustedUserPrompt: "One edit", tools: tools, progress: { _ in })
        XCTAssertEqual(resumed, .completed("Done")); XCTAssertEqual(effects, 1); XCTAssertEqual(proposals, 2)
        do { _ = try await executor.execute(taskID: "after", prompt: "New goal", trustedUserPrompt: "New goal", tools: tools, progress: { _ in }); XCTFail("Task identity accepted a changed goal") }
        catch { XCTAssertEqual(error as? ComputerUseDesktopExecutor.Failure, .changedTask) }
    }

    func testNativeDesktopHistoryRetainsRejectedActionFeedbackWithItsObservation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var focus = "first field", effects = 0, calls = 0
        var rejectedFeedback: String?
        let tools = desktopTestTools(focus: { focus }, perform: { _ in effects += 1 })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
            calls += 1
            switch calls {
            case 1:
                focus = "another field"
                return .init(response: "key", action: .key(["a"]))
            case 2:
                rejectedFeedback = try XCTUnwrap(input.actionError)
                XCTAssertEqual(input.history.count, 1)
                XCTAssertNil(input.history.first?.actionError)
                return .init(response: "wait", action: .wait(0))
            case 3:
                XCTAssertNil(input.actionError)
                XCTAssertEqual(input.history.count, 2)
                XCTAssertEqual(input.history[1].actionError, rejectedFeedback,
                    "The observation after rejection must retain that result when it becomes history")
                return .init(response: "done", action: .reportCompletion("Done"))
            default: throw ComputerUseDesktopExecutor.Failure.stepLimit
            }
        })
        let result = try await executor.execute(taskID: "feedback", prompt: "Use the current field", trustedUserPrompt: "Use the current field", tools: tools, progress: { _ in })
        XCTAssertEqual(result, .completed("Done")); XCTAssertEqual(calls, 3); XCTAssertEqual(effects, 0)
    }

    func testDesktopImagePreservesOrientationAndFullOffsetDisplayCoordinates() throws {
        let extent = CGRect(x: 0, y: 0, width: 640, height: 320)
        let redTop = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 160, width: 640, height: 160))
        let blueBottom = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 160))
        let source = redTop.composited(over: blueBottom).cropped(to: extent)
            .transformed(by: CGAffineTransform(translationX: 90, y: -30))
        let frame = try ComputerUseDesktopImage(observation: .init(image: source,
            displayBounds: CGRect(x: -1920, y: 120, width: 1920, height: 960),
            frontmostWindowBounds: CGRect(x: -1500, y: 300, width: 300, height: 200)))
        XCTAssertEqual(frame.pixelWidth, 640); XCTAssertEqual(frame.pixelHeight, 320)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: frame.png))
        let top = try XCTUnwrap(bitmap.colorAt(x: 40, y: 40)?.usingColorSpace(.deviceRGB))
        let bottom = try XCTUnwrap(bitmap.colorAt(x: 40, y: 280)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(top.redComponent, 0.9); XCTAssertLessThan(top.blueComponent, 0.1)
        XCTAssertGreaterThan(bottom.blueComponent, 0.9); XCTAssertLessThan(bottom.redComponent, 0.1)
        for (x, y, expectedX, expectedY) in [(0.0, 0.0, -1920, 120), (250, 250, -1440, 360),
                (500, 500, -960, 600), (1000, 1000, -1, 1079), (12.5, 87.5, -1896, 204)] {
            let point = try frame.displayPoint(normalizedX: x, normalizedY: y)
            XCTAssertEqual(point.x, expectedX); XCTAssertEqual(point.y, expectedY)
        }
        for value in [-0.01, 1000.01, Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try frame.displayPoint(normalizedX: value, normalizedY: 500))
            XCTAssertThrowsError(try frame.displayPoint(normalizedX: 500, normalizedY: value))
        }
    }

    func testDesktopImageBoundsRetinaSizeAndRejectsInvalidGeometry() throws {
        let source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 5000, height: 3000))
        let bounds = CGRect(x: 200, y: -1500, width: 2500, height: 1500)
        let frame = try ComputerUseDesktopImage(observation: .init(image: source, displayBounds: bounds))
        XCTAssertEqual(frame.pixelWidth, 2048); XCTAssertEqual(frame.pixelHeight, 1228)
        XCTAssertLessThanOrEqual(frame.png.count, ComputerUseModelImagePolicy.maximumPNGBytes)
        try ComputerUseFaraModel.validatePNG(frame.png)
        let point = try frame.displayPoint(normalizedX: 1000, normalizedY: 1000)
        XCTAssertEqual(point.x, 2699); XCTAssertEqual(point.y, -1)
        for invalid in [CGRect.zero, .infinite, CGRect(x: 0, y: 0, width: 100, height: 100),
                        CGRect(x: 0.5, y: 0, width: 2500, height: 1500)] {
            XCTAssertThrowsError(try ComputerUseDesktopImage(observation: .init(image: source, displayBounds: invalid)))
        }
        XCTAssertThrowsError(try ComputerUseDesktopImage(observation: .init(image: .empty(), displayBounds: bounds)))
        XCTAssertThrowsError(try ComputerUseDesktopImage(observation: .init(image: CIImage(color: .white), displayBounds: bounds)))
    }

    func testDesktopImageShrinksBusyPixelsToTheEncodedByteBudget() throws {
        let side = 1024
        var bytes = Data(count: side * side * 4)
        bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            var random: UInt32 = 0x517CC1B7
            for i in 0..<buffer.count {
                random = random &* 1664525 &+ 1013904223
                buffer[i] = i % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: random >> 24)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let image = try XCTUnwrap(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let frame = try ComputerUseDesktopImage(observation: .init(image: CIImage(cgImage: image),
            displayBounds: CGRect(x: 0, y: 0, width: side, height: side)))
        XCTAssertLessThan(frame.pixelWidth, side, "The initial random PNG exceeds the byte cap")
        XCTAssertEqual(frame.pixelWidth, frame.pixelHeight)
        XCTAssertLessThanOrEqual(frame.png.count, ComputerUseModelImagePolicy.maximumPNGBytes)
        try ComputerUseFaraModel.validatePNG(frame.png)
    }

    func testNativeInsertionPointComparisonRejectsChangedContentAndOtherControls() throws {
        let bounds = CGRect(x: -200, y: 100, width: 640, height: 400)
        let window = CGRect(x: -150, y: 140, width: 400, height: 220)
        let field = CGRect(x: -120, y: 220, width: 250, height: 25)
        func image(changing rect: CGRect? = nil) throws -> ComputerUseDesktopImage {
            var image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400))
            if let rect {
                let local = CGRect(x: rect.minX - bounds.minX, y: bounds.maxY - rect.maxY, width: rect.width, height: rect.height)
                image = CIImage(color: .blue).cropped(to: local).composited(over: image)
            }
            return try .init(observation: .init(image: image, displayBounds: bounds))
        }
        let before = try image()
        XCTAssertTrue(try before.matchesInsertionPointPixels(of: image(), window: window, field: field))
        XCTAssertTrue(try before.matchesInsertionPointPixels(of: image(changing: CGRect(x: -50, y: 222, width: 1, height: 20)), window: window, field: field))
        let fractionalField = CGRect(x: -120, y: 220.3, width: 250, height: 24.7)
        XCTAssertTrue(try before.matchesInsertionPointPixels(of: image(changing: CGRect(x: -50, y: 220.3, width: 1, height: 20)), window: window, field: fractionalField),
            "A rendered pixel cell can cross the fractional logical edge of its text field")
        XCTAssertTrue(try before.matchesInsertionPointPixels(of: image(changing: CGRect(x: -50, y: 226, width: 1, height: 20)), window: window, field: field),
            "Resampling can extend the insertion point by one image pixel beyond the field's rounded footprint")
        for change in [CGRect(x: -50, y: 222, width: 8, height: 20), CGRect(x: -50, y: 150, width: 1, height: 20),
                       CGRect(x: -50, y: 242, width: 10, height: 1), CGRect(x: -123, y: 220, width: 2, height: 20)] {
            XCTAssertFalse(try before.matchesInsertionPointPixels(of: image(changing: change), window: window, field: field), "\(change)")
        }
    }

    func testNativeWindowComparisonExcludesPartialPixelsFromOutsideItsBounds() throws {
        let bounds = CGRect(x: -400, y: 100, width: 1728, height: 1117)
        for window in [CGRect(x: -180, y: 625, width: 640, height: 332),
                       CGRect(x: -80.25, y: 300.75, width: 450.5, height: 280.5)] {
            let field = CGRect(x: window.minX + 30, y: window.minY + 100, width: 250, height: 25)
            func image(changing rect: CGRect? = nil) throws -> ComputerUseDesktopImage {
                var image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: bounds.width * 2, height: bounds.height * 2))
                if let rect {
                    let local = CGRect(x: (rect.minX - bounds.minX) * 2, y: (bounds.maxY - rect.maxY) * 2,
                        width: rect.width * 2, height: rect.height * 2)
                    image = CIImage(color: .blue).cropped(to: local).composited(over: image)
                }
                return try .init(observation: .init(image: image, displayBounds: bounds))
            }
            let before = try image()
            for outside in [CGRect(x: window.maxX, y: window.minY + 20, width: 4, height: 160),
                            CGRect(x: window.minX - 4, y: window.minY + 20, width: 4, height: 160),
                            CGRect(x: window.minX + 20, y: window.minY - 4, width: 160, height: 4),
                            CGRect(x: window.minX + 20, y: window.maxY, width: 160, height: 4)] {
                XCTAssertTrue(try before.matchesInsertionPointPixels(of: image(changing: outside), window: window, field: field),
                    "Resampling must not import an adjacent window's pixels into the current window: \(outside)")
            }
            for inside in [CGRect(x: window.maxX - 3, y: window.minY + 20, width: 2, height: 160),
                           CGRect(x: window.minX + 1, y: window.minY + 20, width: 2, height: 160),
                           CGRect(x: field.minX + 20, y: field.minY, width: 10, height: 20)] {
                XCTAssertFalse(try before.matchesInsertionPointPixels(of: image(changing: inside), window: window, field: field),
                    "Visible edge content and text changes remain significant: \(inside)")
            }
        }
    }

    func testRealNativeFieldsReceiveExactVerifiedEdits() async throws {
        try await runFixture(browser: false)
    }

    func testRealBrowserFieldsReceiveExactVerifiedEdits() async throws {
        try await runFixture(browser: true)
    }

    func testRealNativeNaturalLanguageGoalsAndResume() async throws {
        try await runFixture(browser: false, localGoalsOnly: true)
    }

    func testRealBrowserNaturalLanguageGoalsAndResume() async throws {
        try await runFixture(browser: true, localGoalsOnly: true)
    }

    func testSignedHostNativePackageEditsNativeFields() async throws {
        try await runFixture(browser: false, signedPackage: true)
    }

    func testSignedHostNativePackageEditsBrowserFields() async throws {
        try await runFixture(browser: true, signedPackage: true)
    }

    func testSignedHostNativePackageInstallsAndLoads() async throws {
        guard ProcessInfo.processInfo.environment["RUN_SIGNED_NATIVE_PACKAGE_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in real-model package/runtime prerequisite; no desktop effects")
        }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            throw NativeTextFixtureFailure.unexpectedOutcome("Signed app-hosted test required")
        }
        let installer = ComputerUseInstaller.nativeText()
        let receipt = try await installer.install { update in
            FileHandle.standardError.write(Data("Signed native package: \(update.phase.rawValue)\n".utf8))
        }
        let verified = await installer.currentInstallation()
        XCTAssertEqual(verified, receipt)
        let runtime = OSAtlasLlamaRuntime.shared
        do {
            // Loading needs no Accessibility authority. A false action gate
            // prevents this prerequisite from acquiring any desktop effect.
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { false })
            let executor = try await ComputerUseNativeTextExecutorLoader.load(receipt: receipt,
                tools: tools, progress: { _ in })
            XCTAssertTrue(executor.isReady)
            XCTAssertTrue(executor.hasAdditionalSetup)
            XCTAssertFalse(executor.requiresMacControlHelper)
            try await installer.recordRuntimeActivationSuccess(for: receipt)
            await runtime.shutdown()
        } catch {
            await runtime.shutdown()
            throw error
        }
    }

    private enum NativeModel: String { case fara, faraDiagnostic, guiOwl, holo }

    private struct NativeModelTask {
        let prompt: String
        let origin: String
        let destination: String
        static let singleField = Self(prompt: "In the Destination field, type Tokyo. Leave Origin empty and leave the form open.", origin: "", destination: "Tokyo")
    }

    private func runFixture(browser: Bool, localGoalsOnly: Bool = false, signedPackage: Bool = false, captureOnly: Bool = false, modelRequestOnly: Bool = false, nativeModelLoop: Bool = false, actualDesktopModel: NativeModel? = nil, nativeClickFraction: CGFloat = 0.5, nativeClickDelay: Duration = .zero, nativeOriginText: String = "Seattle", nativeClickBottomOffset: CGFloat = 125, nativeTypeDelay: Duration = .zero, nativeBindingProbe: Bool = false, nativeCompletionDelay: Duration = .zero, nativeModelTask: NativeModelTask = .singleField) async throws {
        if signedPackage, ProcessInfo.processInfo.environment["RUN_SIGNED_NATIVE_PACKAGE_ACCEPTANCE"] != "1" {
            throw XCTSkip("Use run_text_edit_acceptance.sh --signed-package-only with the pinned model staged")
        }
        if localGoalsOnly, ProcessInfo.processInfo.environment["RUN_NATIVE_TEXT_GOALS_LOCAL_ACCEPTANCE"] != "1" {
            throw XCTSkip("Use run_native_text_model_acceptance.py for the real local planner and native effects")
        }
        guard ProcessInfo.processInfo.environment["RUN_COMPUTER_USE_NATIVE_TEXT_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Use host-mac/scripts/run_text_edit_acceptance.sh on a prepared Mac")
        }
        guard AXIsProcessTrusted() else {
            return XCTFail("Accessibility permission is required for the opt-in live native test")
        }
        let executable = try XCTUnwrap(ProcessInfo.processInfo.environment["COMPUTER_USE_TEXT_FIXTURE_EXECUTABLE"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let state = directory.appendingPathComponent("state.json")
        let previousApp = NSWorkspace.shared.frontmostApplication
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [state.path]
        if browser { process.arguments?.append("--browser") }
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            previousApp?.activate(options: [])
            try? FileManager.default.removeItem(at: directory)
        }
        for _ in 0 ..< 100 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier,
               FileManager.default.fileExists(atPath: state.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, process.processIdentifier)
        // WebKit publishes AX focus asynchronously after DOM focus. A visible
        // window and loaded DOM do not yet prove editable Accessibility focus.
        let readiness = ComputerUseAccessibilityTextTarget()
        for _ in 0..<80 {
            if readiness.snapshot() != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let injector = InputInjector()
        var simulatedLogin = false
        let axLog = NativeAXProbeLog()
        let diagnosticTarget = nativeBindingProbe ? NativeAXProbeLog.makeTarget(log: axLog) : nil
        let tools = ComputerUseHostTools(injector: injector, mayAct: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier
        }, nativeTextTarget: diagnosticTarget, authenticationContextProvider: nativeModelLoop ? {
            simulatedLogin ? .init(focusedElement: "AXTextField AXSecureTextField Password", boundedWindowContext: "Sign in\nPassword\nContinue") : nil
        } : nil)
        if let actualDesktopModel {
            let environment = ProcessInfo.processInfo.environment
            let workerLimitGiB = actualDesktopModel == .faraDiagnostic ? 5 :
                (actualDesktopModel == .holo ? Int(environment["NATIVE_HOLO_WORKER_LIMIT_GIB"] ?? "4") ?? 0 : 4)
            guard [4, 5].contains(workerLimitGiB) else { return XCTFail("Only 4 GiB or explicit diagnostic 5 GiB is supported") }
            let inputs = actualDesktopModel == .fara ? try await FaraTestAssets.inputs(environment: environment) : nil
            let binaryKey = actualDesktopModel == .guiOwl ? "GUI_OWL_BINARY" : (actualDesktopModel == .faraDiagnostic ? "FARA_NATIVE_BINARY" : "HOLO_BINARY")
            let workerURL = try inputs?.llamaServerURL ?? URL(fileURLWithPath: XCTUnwrap(environment[binaryKey]))
            XCTAssertTrue(try DarwinOSAtlasProcessInspector().matchingProcesses(for: workerURL).isEmpty)
            let proposalDirectory = actualDesktopModel == .fara ? directory : URL(fileURLWithPath: try XCTUnwrap(environment["NATIVE_MODEL_TRIAL_DIRECTORY"]))
            if actualDesktopModel != .fara { try FileManager.default.createDirectory(at: proposalDirectory, withIntermediateDirectories: false) }
            let runtime = OSAtlasLlamaRuntime()
            let memory = Task.detached { () -> (UInt64, Int) in
                var peak: UInt64 = 0, samples = 0
                while !Task.isCancelled {
                    for child in (try? DarwinOSAtlasProcessInspector().matchingProcesses(for: workerURL)) ?? [] {
                        if let bytes = OSAtlasProcessMemoryGuard.residentBytes(processID: child.processIdentifier) {
                            peak = max(peak, bytes); samples += 1
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                return (peak, samples)
            }
            var responses: [[String: Any]] = []
            var bindingObservation: [String: Any] = [:]
            var diagnosticProbe: HoloProbeProcess?
            let started = Date()
            let goal = nativeModelTask.prompt
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory.appendingPathComponent("actual-native"), propose: { input in
                guard responses.count < 6 else { throw ComputerUseDesktopExecutor.Failure.stepLimit }
                XCTAssertEqual(input.surface, .desktop)
                if nativeBindingProbe, responses.isEmpty {
                    let response = "{\"content\":\"\",\"role\":\"assistant\",\"tool_calls\":[{\"function\":{\"arguments\":\"{\\\"time\\\":0}\",\"name\":\"wait\"},\"id\":\"binding-probe-observation\",\"type\":\"function\"}]}"
                    responses.append(["response": response, "source": "scripted observation; no input"])
                    return .init(response: response, action: .wait(0))
                }
                guard !nativeBindingProbe || responses.count == 1 else { throw ComputerUseDesktopExecutor.Failure.stepLimit }
                // Preserve only this disposable native window for visual
                // grounding diagnosis. Record its position in the exact
                // full-display image supplied to the model; no input changes.
                let observation = try tools.currentScreen()
                let window = try XCTUnwrap(observation.frontmostWindowBounds)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: input.screenshotPNG))
                let source = try XCTUnwrap(bitmap.cgImage)
                let display = observation.displayBounds
                let crop = CGRect(x: (window.minX - display.minX) * CGFloat(source.width) / display.width,
                    y: (window.minY - display.minY) * CGFloat(source.height) / display.height,
                    width: window.width * CGFloat(source.width) / display.width,
                    height: window.height * CGFloat(source.height) / display.height).integral
                let cropped = try XCTUnwrap(source.cropping(to: crop))
                let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]))
                let imageAttachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                imageAttachment.name = "\(actualDesktopModel.rawValue) native fixture observation \(responses.count)"; imageAttachment.lifetime = .keepAlways; self.add(imageAttachment)
                let began = Date()
                let beforeBinding = diagnosticTarget?.snapshot()
                if nativeBindingProbe { axLog.mark("model-enter") }
                let proposal: ComputerUseDesktopProposal
                switch actualDesktopModel {
                case .fara:
                    let endpoint = try await runtime.activateFara(XCTUnwrap(inputs))
                    proposal = try await .init(runtime.proposeFara(endpoint: endpoint, input: input))
                case .guiOwl:
                    proposal = try await GUIOwlTestProposalRunner.propose(input: input, directory: proposalDirectory,
                        index: responses.count, environment: environment, registerProbe: { diagnosticProbe = $0 }).compatibleDesktopProposal()
                case .faraDiagnostic:
                    proposal = try await .init(FaraQ6TestProposalRunner.proposeNativeQ4(input: input, directory: proposalDirectory,
                        index: responses.count, environment: environment, registerProbe: { diagnosticProbe = $0 }))
                case .holo:
                    proposal = try await .init(HoloTestProposalRunner.propose(input: input, directory: proposalDirectory,
                        index: responses.count, environment: environment, memoryLimitGiB: workerLimitGiB, registerProbe: { diagnosticProbe = $0 }))
                }
                responses.append(["response": proposal.response, "seconds": Date().timeIntervalSince(began), "actionError": input.actionError ?? "",
                    "focusedEditor": input.focusedEditor ?? "", "focusedText": input.focusedTextState?.jsonObject ?? [:],
                    "nativeControls": input.nativeControls?.jsonObject ?? [:],
                    "displayBounds": NSStringFromRect(display), "windowBounds": NSStringFromRect(window),
                    "fixtureCropInModelImage": NSStringFromRect(crop), "modelImageWidth": source.width, "modelImageHeight": source.height])
                if nativeBindingProbe {
                    axLog.mark("model-returned")
                    let afterBinding = diagnosticTarget?.snapshot()
                    bindingObservation = ["beforeTargetID": beforeBinding?.targetID ?? "nil", "afterTargetID": afterBinding?.targetID ?? "nil",
                        "sameTarget": beforeBinding?.targetID == afterBinding?.targetID,
                        "sameValue": beforeBinding?.value == afterBinding?.value, "sameSelection": beforeBinding?.selection == afterBinding?.selection,
                        "beforeAvailable": beforeBinding != nil, "afterAvailable": afterBinding != nil]
                    axLog.mark("post-model-read")
                    throw BindingProbeStop.observed
                }
                return proposal
            }, finishRun: { await diagnosticProbe?.cancelAndWait(); diagnosticProbe = nil; await runtime.shutdown() })
            let run = Task { try await executor.execute(taskID: "actual-native-form", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in }) }
            let deadline = Task { try await Task.sleep(for: .seconds(90)); run.cancel() }
            var result: ComputerUseExecutionResult?, failure: Error?
            do { result = try await run.value } catch { failure = error }
            deadline.cancel()
            await runtime.shutdown(); memory.cancel()
            let measured = await memory.value
            let gone = try DarwinOSAtlasProcessInspector().matchingProcesses(for: workerURL).isEmpty
            let journals = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("actual-native"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
            let fieldState = try JSONSerialization.jsonObject(with: Data(contentsOf: state))
            var report: [String: Any] = ["scope": "actual-\(actualDesktopModel.rawValue)-Q4-native-desktop-form", "goal": goal,
                "expectedFixtureState": ["origin": nativeModelTask.origin, "destination": nativeModelTask.destination],
                "responses": responses, "result": result.map { String(describing: $0) } ?? "",
                "workerLimitBytes": UInt64(workerLimitGiB) * 1024 * 1024 * 1024, "diagnosticMemoryLimitOnly": workerLimitGiB != 4,
                "fixtureProcessRunning": process.isRunning,
                "fixtureFrontmostAtReturn": NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier,
                "workerResidency": actualDesktopModel == .fara ? "retained within task" : "fresh worker per proposal",
                "failure": failure.map { String(reflecting: $0) } ?? "", "elapsedSeconds": Date().timeIntervalSince(started),
                "peakSampledWorkerBytes": measured.0, "memorySamples": measured.1, "ownedWorkerExited": gone,
                "fixtureState": fieldState, "dispatchJournalCount": journals.filter { $0.stepIDs == ["native-dispatch-returned"] }.count,
                "targetMacRAMGB": 12, "wholeApp12GBQualified": false, "revalidation": executor.lastRevalidationDiagnostic]
            if let stop = await runtime.lastWorkerStop {
                report["workerStop"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stop))
            }
            if nativeBindingProbe {
                report["scope"] = "one-Holo-proposal-native-binding-diagnostic-no-generated-effects"
                report["bindingObservation"] = bindingObservation; report["axDiagnostics"] = axLog.snapshot()
            }
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
            attachment.name = "Actual \(actualDesktopModel.rawValue) native desktop workflow"; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertTrue(gone)
            if nativeBindingProbe {
                XCTAssertTrue(failure is BindingProbeStop)
                XCTAssertEqual(responses.count, 2, "One scripted observation followed by one real model proposal")
                XCTAssertFalse(journals.contains { $0.stepIDs == ["native-dispatch-returned"] })
                try await verify(state, field: "origin", equals: ""); try await verify(state, field: "destination", equals: "")
                XCTAssertEqual(bindingObservation["beforeAvailable"] as? Bool, true)
                XCTAssertEqual(bindingObservation["afterAvailable"] as? Bool, true)
                XCTAssertEqual(bindingObservation["sameTarget"] as? Bool, true, "A model call must not change the selected field binding")
                return
            }
            if let failure { return XCTFail("Native \(actualDesktopModel.rawValue) task failed: \(failure)") }
            guard case .completed = result else { return XCTFail("Native \(actualDesktopModel.rawValue) task did not complete: \(String(describing: result))") }
            XCTAssertTrue(process.isRunning)
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, process.processIdentifier)
            try await verify(state, field: "origin", equals: nativeModelTask.origin)
            try await verify(state, field: "destination", equals: nativeModelTask.destination)
            let count = responses.count
            let replay = try await executor.execute(taskID: "actual-native-form", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
            XCTAssertEqual(replay, result); XCTAssertEqual(responses.count, count)
            return
        }
        if nativeModelLoop {
            let lifecycleProbe = nativeTypeDelay > .zero || nativeCompletionDelay > .zero ? ComputerUseAXLifecycleMonitor(application: AXUIElementCreateApplication(process.processIdentifier)) : nil
            defer { lifecycleProbe?.cancel() }
            let exact = "  東京 e\u{301} 👩🏽‍💻  "
            let goal = "Set Origin to \(nativeOriginText.isEmpty ? "an empty value" : nativeOriginText) and replace Destination with \(exact). Leave the form open."
            var proposals = 0
            var trace: [String] = []
            var previousModelImage: Data?
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory.appendingPathComponent("native-loop"), propose: { input in
                trace.append("proposal=\(proposals) error=\(input.actionError ?? "none") signed=\(tools.frontmostApplicationSnapshot().identity?.codeIdentity != nil) editable=\(try tools.focusedTypingTargetIsEditable(providerAction: .typeText("probe")))")
                if input.actionError != nil {
                    let screen = try tools.currentScreen(), window = try XCTUnwrap(screen.frontmostWindowBounds)
                    for (name, png) in [("before", previousModelImage), ("after", Optional(input.screenshotPNG))] {
                        guard let png, let source = CGImageSourceCreateWithData(png as CFData, nil),
                              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                        let crop = CGRect(x: (window.minX - screen.displayBounds.minX) / screen.displayBounds.width * CGFloat(image.width),
                            y: (window.minY - screen.displayBounds.minY) / screen.displayBounds.height * CGFloat(image.height),
                            width: window.width / screen.displayBounds.width * CGFloat(image.width), height: window.height / screen.displayBounds.height * CGFloat(image.height)).integral
                        if let clipped = image.cropping(to: crop) {
                            let attachment = XCTAttachment(image: NSImage(cgImage: clipped, size: .zero))
                            attachment.name = "Native scripted rejection \(name)"; attachment.lifetime = .keepAlways; self.add(attachment)
                        }
                    }
                    throw ComputerUseDesktopExecutor.Failure.changedScreen
                }
                previousModelImage = input.screenshotPNG
                XCTAssertEqual(input.goal, goal); XCTAssertEqual(input.surface, .desktop)
                XCTAssertNil(input.currentURL); XCTAssertNil(input.pageReading)
                if proposals == 0 {
                    let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil, baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
                    let providers: [(String, (OSAtlasLlamaEndpoint, ComputerUseFaraModel.Input) throws -> URLRequest)] = [
                        ("Fara", ComputerUseFaraModel.makeRequest), ("Holo", ComputerUseHoloModel.makeRequest), ("GUI-Owl", ComputerUseGUIOwlModel.makeRequest)]
                    let screen = try tools.currentScreen()
                    for (name, build) in providers {
                        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(build(endpoint, input).httpBody)) as? [String: Any])
                        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                        let texts = messages.filter { $0["role"] as? String == "user" }.flatMap { $0["content"] as? [[String: Any]] ?? [] }.compactMap { $0["text"] as? String }
                        let line = try XCTUnwrap(texts.flatMap { $0.components(separatedBy: "\n") }.first { $0.hasPrefix("{\"native_controls\":") }, name + " needs observed native control geometry")
                        let observation = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                        let catalog = try XCTUnwrap(observation["native_controls"] as? [String: Any])
                        let items = try XCTUnwrap(catalog["items"] as? [[String: Any]])
                        for label in ["Origin", "Destination"] {
                            let item = try XCTUnwrap(items.first { ($0["description"] as? String)?.contains(label) == true })
                            let bounds = try XCTUnwrap(item["bounds_1000"] as? [Double]); XCTAssertEqual(bounds.count, 4)
                            guard bounds.count == 4 else { continue }
                            let frame = CGRect(x: screen.displayBounds.minX + bounds[0] / 1000 * screen.displayBounds.width,
                                y: screen.displayBounds.minY + bounds[1] / 1000 * screen.displayBounds.height,
                                width: bounds[2] / 1000 * screen.displayBounds.width, height: bounds[3] / 1000 * screen.displayBounds.height)
                            let actual = try XCTUnwrap(tools.nativePointerTargetFrame(for: .click(x: Int(frame.midX), y: Int(frame.midY), button: 1, count: 1)))
                            XCTAssertEqual(frame.minX, actual.minX, accuracy: 0.01); XCTAssertEqual(frame.minY, actual.minY, accuracy: 0.01)
                            XCTAssertEqual(frame.width, actual.width, accuracy: 0.01); XCTAssertEqual(frame.height, actual.height, accuracy: 0.01)
                        }
                    }
                }
                let focusedLabel = proposals == 0 || (proposals == 1 && !nativeOriginText.isEmpty) ? "Origin" : "Destination"
                XCTAssertTrue(input.focusedEditor?.contains(focusedLabel) == true, "The native model must see the actual focused editor: \(String(describing: input.focusedEditor))")
                XCTAssertFalse(input.focusedEditor?.contains("Replace this") == true)
                XCTAssertFalse(input.focusedEditor?.contains(exact) == true)
                let expectedValue = proposals == 0 ? "" : (proposals == 1 ? nativeOriginText : (proposals == 2 ? "" : (proposals <= 4 ? "Replace this" : exact)))
                let projectedState = try XCTUnwrap(input.focusedTextState)
                XCTAssertTrue(projectedState.valuePrefix.utf8.elementsEqual(expectedValue.utf8))
                XCTAssertEqual(projectedState.valueUTF8Bytes, expectedValue.utf8.count); XCTAssertFalse(projectedState.truncated)
                XCTAssertEqual(projectedState.selection, NSRange(location: proposals == 4 ? 0 : expectedValue.utf16.count,
                    length: proposals == 4 ? expectedValue.utf16.count : 0))
                guard proposals < 7 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
                let index = proposals; proposals += 1
                XCTAssertEqual(input.history.count, min(index, 5))
                @MainActor func clickArguments() async throws -> [String: Any] {
                    try await self.verify(state, field: "origin", equals: nativeOriginText)
                    let screen = try tools.currentScreen(), window = try XCTUnwrap(screen.frontmostWindowBounds)
                    let x = window.minX + 24 + 580 * nativeClickFraction, y = window.maxY - nativeClickBottomOffset
                    let target = try tools.nativePointerTargetFrame(for: .click(x: Int(x), y: Int(y), button: 1, count: 1))
                    trace.append("clickPoint=\(x),\(y) targetFrame=\(String(describing: target))")
                    try await Task.sleep(for: nativeClickDelay)
                    let after = try tools.nativePointerTargetFrame(for: .click(x: Int(x), y: Int(y), button: 1, count: 1))
                    trace.append("afterDelayTargetFrame=\(String(describing: after))")
                    return ["action": "left_click", "coordinate": [
                        (x - screen.displayBounds.minX) / screen.displayBounds.width * 1000,
                        (y - screen.displayBounds.minY) / screen.displayBounds.height * 1000]]
                }
                let arguments: [String: Any]
                switch index {
                case 0: arguments = nativeOriginText.isEmpty ? try await clickArguments() : ["action": "type", "text": nativeOriginText]
                case 1: arguments = nativeOriginText.isEmpty ? ["action": "wait", "time": 0] : try await clickArguments()
                case 2:
                    if nativeTypeDelay > .zero {
                        _ = lifecycleProbe?.drain()
                        let before = readiness.snapshot()
                        try await Task.sleep(for: nativeTypeDelay)
                        let after = readiness.snapshot()
                        let events = lifecycleProbe?.drain().map { $0.notification ?? String(describing: $0.kind) } ?? []
                        trace.append("typingDelay: beforeID=\(before?.targetID ?? "nil") afterID=\(after?.targetID ?? "nil") sameValue=\(before?.value == after?.value) sameSelection=\(before?.selection == after?.selection) events=\(events)")
                    }
                    arguments = ["action": "type", "text": "Replace this"]
                case 3:
                    try await self.verify(state, field: "destination", equals: "Replace this")
                    arguments = ["action": "key", "keys": ["Command", "a"]]
                case 4: arguments = ["action": "type", "text": exact]
                case 5:
                    try await self.verify(state, field: "destination", equals: exact)
                    simulatedLogin = true
                    arguments = ["action": "wait", "time": 0]
                default:
                    if nativeCompletionDelay > .zero {
                        _ = lifecycleProbe?.drain()
                        let before = readiness.snapshot()
                        try await Task.sleep(for: nativeCompletionDelay)
                        let after = readiness.snapshot()
                        let events = lifecycleProbe?.drain().map { $0.notification ?? String(describing: $0.kind) } ?? []
                        trace.append("completionDelay: beforeID=\(before?.targetID ?? "nil") afterID=\(after?.targetID ?? "nil") sameValue=\(before?.value == after?.value) sameSelection=\(before?.selection == after?.selection) events=\(events)")
                        let screen = try tools.currentScreen(), window = try XCTUnwrap(screen.frontmostWindowBounds)
                        let freshImage = try ComputerUseDesktopImage(observation: screen)
                        for (name, png) in [("before", input.screenshotPNG), ("after", freshImage.png)] {
                            let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
                            let full = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                            let crop = CGRect(x: (window.minX - screen.displayBounds.minX) * CGFloat(full.width) / screen.displayBounds.width,
                                y: (window.minY - screen.displayBounds.minY) * CGFloat(full.height) / screen.displayBounds.height,
                                width: window.width * CGFloat(full.width) / screen.displayBounds.width,
                                height: window.height * CGFloat(full.height) / screen.displayBounds.height).integral
                            let image = try XCTUnwrap(full.cropping(to: crop))
                            let attachment = XCTAttachment(image: NSImage(cgImage: image, size: crop.size))
                            attachment.name = "Delayed native completion " + name; attachment.lifetime = .keepAlways; self.add(attachment)
                        }
                    }
                    arguments = ["action": "terminate", "answer": "The two fields are filled."]
                }
                let data = try JSONSerialization.data(withJSONObject: ["name": "computer_use", "arguments": arguments])
                let response = "<tool_call>" + String(decoding: data, as: UTF8.self) + "</tool_call>"
                return try .init(response: response, action: .decodeNativeMessage(response))
            })
            do {
                let paused = try await executor.execute(taskID: "native-form", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
                guard case .userInterventionRequired = paused else { return XCTFail("Expected login handoff, got \(paused)") }
                XCTAssertEqual(proposals, 6)
                simulatedLogin = false
                let result = try await executor.execute(taskID: "native-form", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
                XCTAssertEqual(result, .completed("The two fields are filled.")); XCTAssertEqual(proposals, 7)
                try await verify(state, field: "origin", equals: nativeOriginText)
                try await verify(state, field: "destination", equals: exact)
                let replay = try await executor.execute(taskID: "native-form", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
                XCTAssertEqual(replay, result); XCTAssertEqual(proposals, 7)
                let journals = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("native-loop"), includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
                let dispatches = journals.filter { $0.stepIDs == ["native-dispatch-returned"] }
                XCTAssertEqual(dispatches.count, nativeOriginText.isEmpty ? 4 : 5)
                XCTAssertTrue(dispatches.allSatisfy { $0.statuses == [.verified] })
                let report: [String: Any] = ["inference": false, "nativeInput": true, "proposals": proposals,
                    "verifiedDispatches": dispatches.count, "simulatedLogin": true, "trace": trace,
                    "completedWithoutReplay": replay == result, "independentFieldVerification": true]
                let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
                attachment.name = "Native desktop workflow metadata"; attachment.lifetime = .keepAlways; add(attachment)
            } catch { XCTFail("Native model loop failed after \(proposals) proposals: \(String(reflecting: error)); \(trace); \(executor.lastRevalidationDiagnostic)") }
            return
        }
        if captureOnly || modelRequestOnly {
            // One real display capture, no model or input. OCR is confined to
            // this disposable native window and checks independent fixture text.
            let started = Date()
            do {
                let observation = try tools.currentScreen()
                let captureSeconds = Date().timeIntervalSince(started)
                var modelMetadata: [String: Any] = [:]
                var inspectedImage = observation.image
                if modelRequestOnly {
                    let preparationStart = Date()
                    let image = try ComputerUseDesktopImage(observation: observation)
                    inspectedImage = try XCTUnwrap(CIImage(data: image.png))
                    let input = ComputerUseFaraModel.Input(goal: "Read the labels in the frontmost native window.", screenshotPNG: image.png)
                    let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil,
                        baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
                    _ = try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: input)
                    _ = try ComputerUseHoloModel.makeRequest(endpoint: endpoint, input: input)
                    _ = try ComputerUseGUIOwlModel.makeRequest(endpoint: endpoint, input: input)
                    XCTAssertNil(input.currentURL); XCTAssertNil(input.pageReading)
                    let corner = try image.displayPoint(normalizedX: 1000, normalizedY: 1000)
                    XCTAssertEqual(corner.x, Int(observation.displayBounds.maxX) - 1)
                    XCTAssertEqual(corner.y, Int(observation.displayBounds.maxY) - 1)
                    modelMetadata = ["modelImageWidth": image.pixelWidth, "modelImageHeight": image.pixelHeight,
                        "pngBytes": image.png.count, "imageAndRequestSeconds": Date().timeIntervalSince(preparationStart),
                        "requestProtocols": ["Fara", "Holo", "GUI-Owl"]]
                }
                let bounds = try XCTUnwrap(observation.normalizedFrontmostWindowBounds)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.regionOfInterest = bounds
                try VNImageRequestHandler(ciImage: inspectedImage).perform([request])
                let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
                XCTAssertTrue(lines.contains("Origin"), "Native capture did not show Origin")
                XCTAssertTrue(lines.contains("Destination"), "Native capture did not show Destination")
                var report: [String: Any] = ["captureSeconds":captureSeconds,
                    "imageWidth":observation.image.extent.width,"imageHeight":observation.image.extent.height,
                    "displayBounds":NSStringFromRect(observation.displayBounds),
                    "windowBounds":observation.frontmostWindowBounds.map(NSStringFromRect) ?? "missing",
                    "fixtureVisible":lines.contains("Origin") && lines.contains("Destination"),"inference":false,"input":false]
                report.merge(modelMetadata) { _, value in value }
                let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]), uniformTypeIdentifier: "public.json")
                attachment.name = "Native desktop capture metadata"; attachment.lifetime = .keepAlways; add(attachment)
            } catch { XCTFail("Native desktop fixture capture failed: \(String(reflecting: error))") }
            return
        }
        if signedPackage {
            try await runSignedPackageGoals(browser: browser, pid: process.processIdentifier,
                state: state, directory: directory, tools: tools)
            return
        }
        if localGoalsOnly {
            try await runLocalGoals(browser: browser, pid: process.processIdentifier, state: state,
                                    directory: directory, injector: injector, tools: tools)
            return
        }
        // The fixture reports values through its own app state, independently
        // of the Accessibility readback used by the production text editor.
        let exact = "  \nTokyo 東京 e\u{301} 👨‍👩‍👧‍👦 😀\n" + String(repeating: "x", count: 2_000) + "\n  "
        do {
            try await tools.performVerified(.typeText(exact))
        } catch {
            if let bytes = try? Data(contentsOf: state),
               let fields = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                for name in ["origin", "destination"] {
                    let value = fields[name] as? String ?? ""
                    print("Fixture \(name): \(value.utf8.count) bytes; prefix=\(String(value.prefix(35)).debugDescription)")
                }
            }
            if let value = readiness.snapshot() {
                print("Fixture AX: \(value.value.utf8.count) bytes; prefix=\(String(value.value.prefix(35)).debugDescription)")
            }
            throw error
        }
        try await verify(state, field: "origin", equals: exact)
        try await tools.editFocusedText("San Francisco", mode: .replaceAll)
        try await verify(state, field: "origin", equals: "San Francisco")
        try await tools.editFocusedText(" — appended", mode: .append)
        try await verify(state, field: "origin", equals: "San Francisco — appended")

        let root = AXUIElementCreateApplication(process.processIdentifier)
        let destination = try XCTUnwrap(findElement(id: "destination", root: root))
        XCTAssertEqual(AXUIElementSetAttributeValue(destination, kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
        try await Task.sleep(for: .milliseconds(100))
        try await tools.performVerified(.typeText("San Francisco"))
        try await verify(state, field: "destination", equals: "San Francisco")
        try await verify(state, field: "origin", equals: "San Francisco — appended")

        // Exercise real Unicode events as well as the preferred AX setter.
        try await tools.editFocusedText("", mode: .replaceAll)
        let textTarget = ComputerUseAccessibilityTextTarget()
        let snapshot = try XCTUnwrap(textTarget.snapshot())
        var postedChunks = 0
        let fallbackEditor = ComputerUseTextEditor(
            read: { textTarget.snapshot() },
            select: { try textTarget.select($0, expected: $1) },
            replaceSelectedText: { _, _ in nil },
            postUnicode: { text, expected in
                postedChunks += 1
                guard await injector.applyTextStroke(text, ifAllowed: {
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier
                }, beforePosting: { textTarget.snapshot() == expected }) else { throw ComputerUseTextEditError.interrupted }
            },
            mayAct: { NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier })
        do {
            try await fallbackEditor.edit(exact, expected: snapshot)
        } catch {
            if let current = textTarget.snapshot() {
                print("Unicode fixture result: \(current.value.utf8.count) bytes; prefix=\(String(current.value.prefix(45)).debugDescription); chunks=\(postedChunks)")
            }
            try await Task.sleep(for: .seconds(1))
            if let bytes = try? Data(contentsOf: state),
               let fields = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                for name in ["destination", "rawDestination"] {
                    print("Unicode after settling \(name): \((fields[name] as? String ?? "").utf8.count) bytes")
                }
            }
            print("AX after settling: \(textTarget.snapshot()?.value.utf8.count ?? -1) bytes")
            throw error
        }
        XCTAssertGreaterThan(postedChunks, 1)
        try await verify(state, field: "destination", equals: exact)

        let beforeReplacement = try XCTUnwrap(textTarget.snapshot())
        try "replace-destination".write(to: state.appendingPathExtension("command"), atomically: true, encoding: .utf8)
        var replaced = false
        for _ in 0..<100 {
            if let bytes = try? Data(contentsOf: state),
               let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               value["generation"] as? Int == 1 { replaced = true; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(replaced, "Fixture must actually replace the control")
        XCTAssertNil(textTarget.snapshot(targetID: beforeReplacement.targetID),
                     "An old reference cannot target a new control with the same value, label and geometry")
        let afterReplacement = try XCTUnwrap(textTarget.snapshot())
        XCTAssertNotEqual(afterReplacement.targetID, beforeReplacement.targetID)
        XCTAssertTrue(afterReplacement.value.utf8.elementsEqual(beforeReplacement.value.utf8))
    }

    /// Exercises the production installer, bundled runtime resolver, shared
    /// process owner and whole-goal coordinator. The fixture's own state file
    /// is the effect oracle; no screenshot/model output establishes success.
    private func runSignedPackageGoals(browser: Bool, pid: pid_t, state: URL,
                                      directory: URL, tools: ComputerUseHostTools) async throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            throw NativeTextFixtureFailure.unexpectedOutcome("Signed app-hosted test required")
        }
        let environment = ProcessInfo.processInfo.environment
        let corpusURL = URL(fileURLWithPath: try XCTUnwrap(environment["COMPUTER_USE_SIGNED_PACKAGE_CORPUS"]))
        let reportPrefix = try XCTUnwrap(environment["COMPUTER_USE_SIGNED_PACKAGE_REPORT_PREFIX"])
        let corpusData = try Data(contentsOf: corpusURL)
        let corpusDigest = SHA256.hash(data: corpusData).map { String(format: "%02x", $0) }.joined()
        guard corpusDigest == "846b06a7b3524ec5803022d110805ec5614fa56f153238a792c01290b04e67f4" else {
            throw NativeTextFixtureFailure.unexpectedOutcome("Regression corpus changed")
        }
        let corpus = try XCTUnwrap(JSONSerialization.jsonObject(with: corpusData) as? [String: Any])
        let cases = try XCTUnwrap(corpus["cases"] as? [[String: Any]])
        let reportURL = URL(fileURLWithPath: reportPrefix + (browser ? ".webkit.json" : ".appkit.json"))
        guard !FileManager.default.fileExists(atPath: reportURL.path) else {
            throw NativeTextFixtureFailure.unexpectedOutcome("Refusing to overwrite previous results")
        }
        let installer = ComputerUseInstaller.nativeText()
        let receipt = try await installer.install { update in
            FileHandle.standardError.write(Data("Signed native package: \(update.phase.rawValue)\n".utf8))
        }
        let current = await installer.currentInstallation()
        XCTAssertEqual(current, receipt, "Only the real installer can establish package verification")
        let runtime = OSAtlasLlamaRuntime.shared
        do {
            let executor = try await ComputerUseNativeTextExecutorLoader.load(receipt: receipt, tools: tools,
                journalDirectory: directory.appendingPathComponent("signed-steps"), progress: { _ in })
            try await installer.recordRuntimeActivationSuccess(for: receipt)
            let runtimeDirectory = try OSAtlasVisualExecutorLoader.bundledRuntimeDirectoryURL(in: .main)
            let runtimeData = try Data(contentsOf: runtimeDirectory.appendingPathComponent("llama-server"))
            let runtimeDigest = SHA256.hash(data: runtimeData).map { String(format: "%02x", $0) }.joined()
            var rows: [[String: Any]] = []
            let runID = UUID().uuidString
            for item in cases {
                let id = try XCTUnwrap(item["id"] as? String)
                let initial = item["initial"] as? [String: String] ?? [:]
                try await resetFields(initial, pid: pid, tools: tools)
                var prompt = try XCTUnwrap(item["prompt"] as? String)
                if item["payloadRecipe"] != nil {
                    prompt = prompt.replacingOccurrences(of: "PAYLOAD", with: "\"" + String(repeating: "x", count: 2_000) + "\"")
                }
                let started = ProcessInfo.processInfo.systemUptime
                let result = try await executor.execute(taskID: runID + "-" + id, modelPrompt: prompt,
                    currentUserPrompt: prompt, conversation: [], tools: tools, progress: { _ in })
                var expected = item["expected"] as? [String: String]
                    ?? ["origin": String(repeating: "x", count: 2_000), "destination": ""]
                let disposition: String
                switch item["expectedOutcome"] as? String {
                case "unsupportedWithoutEffects":
                    guard case .unableToComplete = result else { throw NativeTextFixtureFailure.unexpectedOutcome(id) }
                    disposition = "unsupportedWithoutEffects"
                    expected = ["origin": initial["origin"] ?? "", "destination": initial["destination"] ?? ""]
                case "clarificationWithoutEffects":
                    guard case .clarificationRequired = result else { throw NativeTextFixtureFailure.unexpectedOutcome(id) }
                    disposition = "clarificationWithoutEffects"
                    expected = ["origin": initial["origin"] ?? "", "destination": initial["destination"] ?? ""]
                default:
                    guard case .completed = result else { throw NativeTextFixtureFailure.unexpectedOutcome(id) }
                    disposition = "completed"
                }
                for name in ["origin", "destination"] { try await verify(state, field: name, equals: expected[name] ?? "") }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                rows.append(["id": id, "disposition": disposition, "verified": true, "elapsedSeconds": elapsed])
                let report: [String: Any] = ["schemaVersion": 1, "scope": "signed-package-known-form-regressions",
                    "fixture": browser ? "WebKit" : "AppKit", "hostBundlePath": Bundle.main.bundleURL.path,
                    "installationVersion": receipt.installationVersion, "runtimeBinarySHA256": runtimeDigest,
                    "modelSHA256FromVerifiedManifest": ComputerUseArtifactManifest.nativeTextV2.modelArtifacts[0].sha256,
                    "corpusSHA256": corpusDigest, "cases": rows]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: reportURL, options: .atomic)
                reportGoal(browser: browser, id: id, elapsed: elapsed)
            }
            await runtime.shutdown()
        } catch {
            await runtime.shutdown()
            throw error
        }
    }

    private func runLocalGoals(browser: Bool, pid: pid_t, state: URL, directory: URL,
                               injector: InputInjector, tools: ComputerUseHostTools) async throws {
        let connectionFile = try XCTUnwrap(ProcessInfo.processInfo.environment["COMPUTER_USE_TEXT_MODEL_CONNECTION_FILE"])
        let connectionData = try Data(contentsOf: URL(fileURLWithPath: connectionFile))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: connectionData) as? [String: String])
        let connection = try ComputerUseTextModelConnection(
            baseURL: XCTUnwrap(URL(string: XCTUnwrap(object["baseURL"]))),
            bearerToken: XCTUnwrap(object["bearerToken"]), modelAlias: XCTUnwrap(object["modelAlias"]))
        let contract = try XCTUnwrap(ComputerUseLocalTextGoalPlanner.Contract(rawValue: object["contract"] ?? "frozen-v1"))
        let localPlanner = ComputerUseLocalTextGoalPlanner(connection: connection, contract: contract)
        let countedPlanner = CountingNativeTextPlanner(localPlanner)
        var allowed = true
        let mayAct = { allowed && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
        let executor = ComputerUseNativeTextExecutor(injector: injector, mayAct: mayAct,
            journalDirectory: directory.appendingPathComponent("steps"), planner: countedPlanner)
        let corpusURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AcceptanceFixtures/native-text-goals-v1.json")
        let corpus = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: corpusURL)) as? [String: Any])
        let cases = try XCTUnwrap(corpus["cases"] as? [[String: Any]])
        let faultsOnly = ProcessInfo.processInfo.environment["COMPUTER_USE_TEXT_GOALS_FAULTS_ONLY"] == "1"
        for item in cases where item["fault"] == nil && !faultsOnly {
            let id = try XCTUnwrap(item["id"] as? String)
            let initial = item["initial"] as? [String: String] ?? [:]
            try await resetFields(initial, pid: pid, tools: tools)
            var prompt = try XCTUnwrap(item["prompt"] as? String)
            if item["payloadRecipe"] != nil {
                prompt = prompt.replacingOccurrences(of: "PAYLOAD", with: "\"" + String(repeating: "x", count: 2_000) + "\"")
            }
            let started = ProcessInfo.processInfo.systemUptime
            let result = try await executor.execute(taskID: id, prompt: prompt, progress: { _ in })
            var expected = item["expected"] as? [String: String]
                ?? ["origin": String(repeating: "x", count: 2_000), "destination": ""]
            switch item["expectedOutcome"] as? String {
            case "unsupportedWithoutEffects":
                guard result == nil else { throw NativeTextFixtureFailure.unexpectedOutcome(id) }
                expected = ["origin": initial["origin"] ?? "", "destination": initial["destination"] ?? ""]
            case "clarificationWithoutEffects":
                guard case .clarificationRequired = result else { return XCTFail("\(id): expected clarification") }
                expected = ["origin": initial["origin"] ?? "", "destination": initial["destination"] ?? ""]
            default:
                guard case .completed = result else { return XCTFail("\(id): both field outcomes must be verified") }
            }
            for name in ["origin", "destination"] { try await verify(state, field: name, equals: expected[name] ?? "") }
            reportGoal(browser: browser, id: id, elapsed: ProcessInfo.processInfo.systemUptime - started)
        }

        // Pausing after the first append makes a replay visibly wrong. Resume
        // must use the retained contract without another inference.
        try await resetFields(["origin": "A", "destination": "B"], pid: pid, tools: tools)
        let prompt = "Append \"!\" to both Origin and Destination."
        let beforeCalls = await countedPlanner.calls
        do {
            _ = try await executor.execute(taskID: "pause", prompt: prompt, verifiedStep: { complete, _ in
                if complete == 1 { _ = injector.interruptAutomation { allowed = false; return true } }
            }, progress: { _ in })
            XCTFail("Expected pause between native edits")
        } catch { XCTAssertEqual(error as? ComputerUseTextEditError, .interrupted) }
        try await verify(state, field: "origin", equals: "A!")
        try await verify(state, field: "destination", equals: "B")
        allowed = true
        let resumed = try await executor.execute(taskID: "pause", prompt: prompt, progress: { _ in })
        guard case .completed = resumed else { return XCTFail("Resume must verify both outcomes") }
        try await verify(state, field: "origin", equals: "A!")
        try await verify(state, field: "destination", equals: "B!")
        let afterCalls = await countedPlanner.calls
        XCTAssertEqual(afterCalls, beforeCalls + 1, "Resume must not reconstruct the task with another model call")
        reportGoal(browser: browser, id: "pause-resume", elapsed: nil)

        // Both edits have happened, but completion still requires their final
        // predicates. A user changing the first field during a pause must not
        // be overwritten or hidden by the second field's successful edit.
        try await resetFields([:], pid: pid, tools: tools)
        let compound = "Set Origin to Oslo and Destination to Bergen."
        var pausedAfterBothEdits = false
        do {
            let result = try await executor.execute(taskID: "changed-final", prompt: compound, verifiedStep: { complete, total in
                if complete == total { _ = injector.interruptAutomation { allowed = false; return true } }
            }, progress: { _ in })
            XCTFail("N12: expected pause after both edits; actual result: \(String(describing: result))")
        } catch {
            pausedAfterBothEdits = error as? ComputerUseTextEditError == .interrupted
            XCTAssertTrue(pausedAfterBothEdits, "N12: \(error)")
        }
        if pausedAfterBothEdits {
            try await verify(state, field: "origin", equals: "Oslo")
            try await verify(state, field: "destination", equals: "Bergen")
            try await resetFields(["origin": "user changed this", "destination": "Bergen"], pid: pid, tools: tools)
            allowed = true
            do { _ = try await executor.execute(taskID: "changed-final", prompt: compound, progress: { _ in }); XCTFail("Changed final value must prevent completion") }
            catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .incompleteOutcome) }
            try await verify(state, field: "origin", equals: "user changed this")
            try await verify(state, field: "destination", equals: "Bergen")
            reportGoal(browser: browser, id: "N12-changed-before-final-verification", elapsed: nil)
        }
        allowed = true

        try await resetFields([:], pid: pid, tools: tools)
        let observedTransport = ObservedNativeTextTransport()
        let cancellable = ComputerUseNativeTextExecutor(injector: injector, mayAct: mayAct,
            journalDirectory: directory.appendingPathComponent("cancel-inference"),
            planner: ComputerUseLocalTextGoalPlanner(connection: connection, transport: observedTransport, contract: contract))
        let inference = Task {
            try await cancellable.execute(taskID: "cancel-inference", prompt: "Set both Origin and Destination to Helsinki.", progress: { _ in })
        }
        defer { inference.cancel() }
        for _ in 0..<200 {
            if await observedTransport.completions > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let completionCalls = await observedTransport.completions
        XCTAssertEqual(completionCalls, 1, "Cancellation must occur after the real completion request starts")
        try await Task.sleep(for: .milliseconds(100))
        let cancellationStart = ProcessInfo.processInfo.systemUptime
        _ = injector.interruptAutomation { allowed = false; return true }
        inference.cancel()
        do { _ = try await inference.value; XCTFail("Cancelled inference must not produce effects") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        let cancellationSeconds = ProcessInfo.processInfo.systemUptime - cancellationStart
        XCTAssertLessThan(cancellationSeconds, 1)
        try await verify(state, field: "origin", equals: "")
        try await verify(state, field: "destination", equals: "")
        reportGoal(browser: browser, id: "cancel-during-inference", elapsed: cancellationSeconds)
        allowed = true

        // Force the real Unicode fallback and interrupt while a key is held.
        // The fixture must retain only a prefix and the journal must prevent a
        // subsequent run from blindly replaying that possibly delivered edit.
        let posted = NativeTextPostedEvents()
        let unicodeInjector = InputInjector(eventPoster: { event in
            posted.record(event)
            event.post(tap: .cghidEventTap)
        })
        let unicodeTarget = ComputerUseAccessibilityTextTarget()
        var stoppedDuringTyping = false
        let unicode = ComputerUseNativeTextExecutor(injector: unicodeInjector, mayAct: mayAct,
            journalDirectory: directory.appendingPathComponent("cancel-unicode"), planner: countedPlanner,
            editOverride: { edit, _ in
                let snapshot = try XCTUnwrap(unicodeTarget.snapshot())
                let interrupt = Task { @MainActor in
                    while !Task.isCancelled {
                        if posted.counts[0] >= 3 {
                            _ = unicodeInjector.interruptAutomation { allowed = false; return true }
                            stoppedDuringTyping = true
                            return
                        }
                        try await Task.sleep(for: .milliseconds(1))
                    }
                }
                defer { interrupt.cancel() }
                let editor = ComputerUseTextEditor(read: { unicodeTarget.snapshot() },
                    select: { try unicodeTarget.select($0, expected: $1) }, replaceSelectedText: { _, _ in nil },
                    postUnicode: { text, expected in
                        let delivered = await unicodeInjector.applyTextStroke(text, ifAllowed: mayAct,
                            beforePosting: { unicodeTarget.snapshot() == expected })
                        guard delivered else { throw ComputerUseTextEditError.interrupted }
                    }, mayAct: mayAct)
                try await editor.edit(edit.text, mode: edit.mode, expected: snapshot)
            })
        let unicodePrompt = "Set Destination to \"" + String(repeating: "x", count: 100) + "\"."
        do { _ = try await unicode.execute(taskID: "cancel-unicode", prompt: unicodePrompt, progress: { _ in }); XCTFail("Expected interrupted Unicode delivery") }
        catch { XCTAssertEqual(error as? ComputerUseTextEditError, .interrupted) }
        XCTAssertTrue(stoppedDuringTyping)
        let postedAtStop = posted.counts
        XCTAssertGreaterThanOrEqual(postedAtStop[0], 3)
        XCTAssertEqual(postedAtStop[0], postedAtStop[1], "Every posted key-down must have exactly one release")
        try await Task.sleep(for: .milliseconds(100))
        let partialState = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any])
        let prefix = try XCTUnwrap(partialState["destination"] as? String)
        XCTAssertFalse(prefix.isEmpty, "The independent fixture must prove actual partial delivery")
        XCTAssertLessThan(prefix.count, 100)
        XCTAssertTrue(prefix.allSatisfy { $0 == "x" })
        allowed = true
        do { _ = try await unicode.execute(taskID: "cancel-unicode", prompt: unicodePrompt, progress: { _ in }); XCTFail("Partial input must be reconciled without replay") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .uncertainEffect) }
        XCTAssertEqual(posted.counts, postedAtStop)
        try await verify(state, field: "destination", equals: prefix)
        try await verify(state, field: "origin", equals: "")
        reportGoal(browser: browser, id: "cancel-during-unicode-without-replay", elapsed: nil)

        // A faulted delivery adapter changes the real fixture to a partial
        // value. Retrying the same task must reconcile it as uncertain.
        try await resetFields([:], pid: pid, tools: tools)
        var deliveries = 0
        let partial = ComputerUseNativeTextExecutor(injector: injector, mayAct: mayAct,
            journalDirectory: directory.appendingPathComponent("partial"), planner: countedPlanner,
            editOverride: { edit, _ in
                deliveries += 1
                XCTAssertEqual(edit.text, "Madrid")
                try await tools.editFocusedText("Ma", mode: .replaceAll)
                throw ComputerUseTextEditError.deliveryUncertain
            })
        do { _ = try await partial.execute(taskID: "partial", prompt: "Set Destination to Madrid.", progress: { _ in }); XCTFail("Expected partial input") }
        catch { XCTAssertEqual(error as? ComputerUseTextEditError, .deliveryUncertain) }
        do { _ = try await partial.execute(taskID: "partial", prompt: "Set Destination to Madrid.", progress: { _ in }); XCTFail("Expected reconciliation") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .uncertainEffect) }
        XCTAssertEqual(deliveries, 1)
        try await verify(state, field: "origin", equals: "")
        try await verify(state, field: "destination", equals: "Ma")
        reportGoal(browser: browser, id: "partial-without-replay", elapsed: nil)

        // Replace the actual target after inference returns and before the
        // executor's preflight. Same label/value/geometry must not revive it.
        try await resetFields([:], pid: pid, tools: tools)
        let replacingPlanner = CountingNativeTextPlanner(localPlanner) {
            try "replace-origin".write(to: state.appendingPathExtension("command"), atomically: true, encoding: .utf8)
            for _ in 0..<100 {
                if let data = try? Data(contentsOf: state),
                   let stateObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   stateObject["generation"] as? Int == 1 { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw NativeTextFixtureFailure.replacementTimedOut
        }
        let stale = ComputerUseNativeTextExecutor(injector: injector, mayAct: mayAct,
            journalDirectory: directory.appendingPathComponent("stale"), planner: replacingPlanner)
        do { _ = try await stale.execute(taskID: "stale", prompt: "Set Origin to Lisbon.", progress: { _ in }); XCTFail("Expected stale target") }
        catch { XCTAssertEqual(error as? ComputerUseTextTaskError, .staleTarget) }
        try await verify(state, field: "origin", equals: "")
        try await verify(state, field: "destination", equals: "")
        reportGoal(browser: browser, id: "replaced-after-inference", elapsed: nil)
    }

    private func resetFields(_ values: [String: String], pid: pid_t, tools: ComputerUseHostTools) async throws {
        let root = AXUIElementCreateApplication(pid)
        for name in ["origin", "destination"] {
            let element = try XCTUnwrap(findElement(id: name, root: root))
            XCTAssertEqual(AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
            try await Task.sleep(for: .milliseconds(75))
            try await tools.editFocusedText(values[name] ?? "", mode: .replaceAll)
            var range = CFRange(location: 0, length: 0)
            let selection = try XCTUnwrap(AXValueCreate(.cfRange, &range))
            XCTAssertEqual(AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, selection), .success)
        }
    }

    private func reportGoal(browser: Bool, id: String, elapsed: TimeInterval?) {
        let duration = elapsed.map { String(format: " %.3f s", $0) } ?? ""
        FileHandle.standardError.write(Data("Native goal \(browser ? "WebKit" : "AppKit") \(id): verified\(duration)\n".utf8))
    }

    private func verify(_ state: URL, field: String, equals expected: String) async throws {
        for _ in 0 ..< 100 {
            if let bytes = try? Data(contentsOf: state),
               let fields = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               let actual = fields[field] as? String,
               actual.utf8.elementsEqual(expected.utf8) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NativeTextFixtureFailure.valueDidNotMatch(field)
    }

    private func findElement(id: String, root: AXUIElement) -> AXUIElement? {
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < 150 {
            let element = queue.removeFirst()
            visited += 1
            var value: CFTypeRef?
            for name in [kAXIdentifierAttribute as String, "AXDOMIdentifier"] {
                if AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
                   value as? String == id { return element }
            }
            for attribute in [kAXWindowsAttribute, kAXChildrenAttribute] {
                value = nil
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                   let children = value as? [AXUIElement] { queue.append(contentsOf: children) }
            }
        }
        return nil
    }

}

private struct IntegrationUnavailableMCPPlanner: MCPProposalPlanning {
    func availability() -> AppleFoundationMCPPlannerAvailability { .unavailable(.modelNotReady) }
    func propose(_ request: MCPProposalPlanningRequest) async throws -> MCPProposalPlanningResult {
        XCTFail("This qualification must not invoke Apple inference")
        throw AppleFoundationMCPPlannerError.unavailable(.modelNotReady)
    }
}

private enum NativeTextFixtureFailure: Error {
    case replacementTimedOut, valueDidNotMatch(String), unexpectedOutcome(String)
}

private final class NativeTextPostedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var down = 0
    private var up = 0
    var counts: [Int] { lock.withLock { [down, up] } }
    func record(_ event: CGEvent) {
        lock.withLock {
            if event.type == .keyDown { down += 1 }
            if event.type == .keyUp { up += 1 }
        }
    }
}

private actor ObservedNativeTextTransport: ComputerUseTextModelTransport {
    let wrapped = URLSessionOSAtlasTransport()
    private(set) var completions = 0
    func exactInputTokenCount(completionRequest: URLRequest) async throws -> Int {
        try await wrapped.exactInputTokenCount(completionRequest: completionRequest)
    }
    func complete(request: URLRequest) async throws -> Data {
        completions += 1
        return try await wrapped.complete(request: request)
    }
}

private actor CountingNativeTextPlanner: ComputerUseTextGoalPlanning {
    let wrapped: any ComputerUseTextGoalPlanning
    let afterProposal: @MainActor @Sendable () async throws -> Void
    private(set) var calls = 0
    init(_ wrapped: any ComputerUseTextGoalPlanning,
         afterProposal: @escaping @MainActor @Sendable () async throws -> Void = {}) {
        self.wrapped = wrapped
        self.afterProposal = afterProposal
    }
    func propose(prompt: String, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal {
        calls += 1
        let proposal = try await wrapped.propose(prompt: prompt, fields: fields)
        try await afterProposal()
        return proposal
    }
}

/// Opt-in diagnostic only: record AX status codes and event names, never
/// values, selected text or queries against destroyed event handles.
private final class NativeAXProbeLog: @unchecked Sendable {
    private let lock = NSLock()
    private let started = Date()
    private var counts: [String: Int] = [:]
    private var events: [String] = []
    private var observedReferences: [(String, AXUIElement)] = []
    func observeReference(_ name: String, value: CFTypeRef?) {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        lock.lock(); defer { lock.unlock() }
        if observedReferences.count < 128 { observedReferences.append((name, value as! AXUIElement)) }
    }
    func relation(to element: AXUIElement?) -> String {
        guard let element else { return "unknown" }
        lock.lock(); defer { lock.unlock() }
        return Set(observedReferences.filter { CFEqual($0.1, element) }.map(\.0)).sorted().joined(separator: ",")
    }
    func mark(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        if events.count < 128 { events.append(String(format: "%.3f ", Date().timeIntervalSince(started)) + value) }
    }
    func record(_ operation: String, name: String, status: AXError, elapsed: TimeInterval) {
        guard status != .success || elapsed >= 0.1 else { return }
        let key = "\(operation):\(name):\(status.rawValue)"
        lock.lock()
        if counts[key] != nil || counts.count < 128 { counts[key, default: 0] += 1 }
        lock.unlock()
        if status == .cannotComplete || status == .invalidUIElement || elapsed >= 0.1 {
            mark(key + String(format: " duration=%.3f", elapsed))
        }
    }
    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["readStatusCounts": counts, "events": events]
    }
    @MainActor static func makeTarget(log: NativeAXProbeLog) -> ComputerUseAccessibilityTextTarget {
        let live = ComputerUseAccessibilityTextTarget.Access.live
        let access = ComputerUseAccessibilityTextTarget.Access(frontmost: live.frontmost, read: { name, element in
            let began = Date(); var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            if [kAXFocusedUIElementAttribute, kAXFocusedWindowAttribute, kAXParentAttribute, kAXTitleUIElementAttribute].contains(name) {
                log.observeReference(name, value: status == .success ? value : nil)
            }
            log.record("read", name: name, status: status, elapsed: Date().timeIntervalSince(began))
            return status == .success ? value : nil
        }, canSet: { name, element in
            let began = Date(); var settable: DarwinBoolean = false
            let status = AXUIElementIsAttributeSettable(element, name as CFString, &settable)
            log.record("canSet", name: name, status: status, elapsed: Date().timeIntervalSince(began))
            return status == .success && settable.boolValue
        }, write: live.write, timeout: live.timeout, makeLifecycleMonitor: { application in
            log.observeReference("application", value: application.root)
            return NativeAXProbeMonitor(base: ComputerUseAXLifecycleMonitor(application: application.root), log: log)
        })
        return ComputerUseAccessibilityTextTarget(access: access)
    }
}

private final class NativeAXProbeMonitor: ComputerUseAXLifecycleMonitoring {
    private let base: any ComputerUseAXLifecycleMonitoring
    private let log: NativeAXProbeLog
    init(base: any ComputerUseAXLifecycleMonitoring, log: NativeAXProbeLog) { self.base = base; self.log = log }
    func drain() -> [ComputerUseAXLifecycleEvent] {
        let events = base.drain()
        for event in events {
            let relation = log.relation(to: event.element)
            log.mark("lifecycle:\(event.kind):" + (event.notification ?? "unknown") + ":references=" + (relation.isEmpty ? "unrelated" : relation))
        }
        return events
    }
    func cancel() { base.cancel() }
    deinit { base.cancel() }
}

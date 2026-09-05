import AppKit
import ApplicationServices
import CryptoKit
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseNativeTextIntegrationTests: XCTestCase {
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

    private func runFixture(browser: Bool, localGoalsOnly: Bool = false, signedPackage: Bool = false) async throws {
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
        let tools = ComputerUseHostTools(injector: injector, mayAct: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier
        })
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
            select: { textTarget.select($0) },
            replaceSelectedText: { _ in nil },
            postUnicode: { text in
                postedChunks += 1
                guard await injector.applyTextPaced(text, ifAllowed: {
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier
                }) else { throw ComputerUseTextEditError.interrupted }
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
                let editor = ComputerUseTextEditor(read: { unicodeTarget.snapshot() },
                    select: { unicodeTarget.select($0) }, replaceSelectedText: { _ in nil },
                    postUnicode: { text in
                        let interrupt = Task { @MainActor in
                            for _ in 0..<200 {
                                if posted.counts[0] >= 3 {
                                    _ = unicodeInjector.interruptAutomation { allowed = false; return true }
                                    stoppedDuringTyping = true
                                    return
                                }
                                try await Task.sleep(for: .milliseconds(1))
                            }
                        }
                        defer { interrupt.cancel() }
                        let delivered = await unicodeInjector.applyTextPaced(text, ifAllowed: mayAct)
                        try await interrupt.value
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

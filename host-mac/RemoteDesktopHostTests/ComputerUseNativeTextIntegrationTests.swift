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

    func testOptInNativeDesktopImageBuildsAllModelRequests() async throws {
        try await runFixture(browser: false, modelRequestOnly: true)
    }

    func testOptInNativeModelLoopEditsPausesAndResumesWithoutReplay() async throws {
        try await runFixture(browser: false, nativeModelLoop: true)
    }

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

    private func desktopTestTools(focus: @escaping () -> String = { "field" },
        perform: @escaping (ComputerUsePredictedAction) throws -> Void) -> ComputerUseHostTools {
        ComputerUseHostTools(injector: InputInjector(), mayAct: { true },
            approvalTargetProvider: { _ in .init(context: "AXTextField Query", applicationID: "fixture", accessibilityIdentity: focus()) },
            actionPerformer: perform,
            screenProvider: { .init(image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 400)),
                displayBounds: CGRect(x: 0, y: 0, width: 640, height: 400), frontmostWindowBounds: CGRect(x: 0, y: 0, width: 640, height: 400)) },
            transientSystemOverlayProvider: { _ in false }, accessibilityContextProvider: { _ in "AXTextField Query" },
            authenticationContextProvider: { nil }, screenCaptureConsentContextProvider: { nil },
            planningAccessibilityIdentityProvider: focus, frontmostApplicationProvider: { "Fixture" })
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
        var release: CheckedContinuation<ComputerUseFaraModel.Proposal, Never>?
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

    private func runFixture(browser: Bool, localGoalsOnly: Bool = false, signedPackage: Bool = false, captureOnly: Bool = false, modelRequestOnly: Bool = false, nativeModelLoop: Bool = false) async throws {
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
        let tools = ComputerUseHostTools(injector: injector, mayAct: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier
        }, authenticationContextProvider: nativeModelLoop ? {
            simulatedLogin ? .init(focusedElement: "AXTextField AXSecureTextField Password", boundedWindowContext: "Sign in\nPassword\nContinue") : nil
        } : nil)
        if nativeModelLoop {
            let exact = "  東京 e\u{301} 👩🏽‍💻  "
            let goal = "Set Origin to Seattle and replace Destination with \(exact). Leave the form open."
            var proposals = 0
            var trace: [String] = []
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory.appendingPathComponent("native-loop"), propose: { input in
                trace.append("proposal=\(proposals) error=\(input.actionError ?? "none") signed=\(tools.frontmostApplicationSnapshot().identity?.codeIdentity != nil) editable=\(try tools.focusedTypingTargetIsEditable(providerAction: .typeText("probe")))")
                XCTAssertEqual(input.goal, goal); XCTAssertNil(input.currentURL); XCTAssertNil(input.pageReading)
                guard proposals < 7 else { throw ComputerUseFaraBrowserExecutor.Failure.stepLimit }
                let index = proposals; proposals += 1
                XCTAssertEqual(input.history.count, min(index, 5))
                let arguments: [String: Any]
                switch index {
                case 0: arguments = ["action": "type", "text": "Seattle"]
                case 1:
                    try await self.verify(state, field: "origin", equals: "Seattle")
                    let screen = try tools.currentScreen(), window = try XCTUnwrap(screen.frontmostWindowBounds)
                    let x = window.minX + 314, y = window.maxY - 125
                    arguments = ["action": "left_click", "coordinate": [
                        (x - screen.displayBounds.minX) / screen.displayBounds.width * 1000,
                        (y - screen.displayBounds.minY) / screen.displayBounds.height * 1000]]
                case 2: arguments = ["action": "type", "text": "Replace this"]
                case 3:
                    try await self.verify(state, field: "destination", equals: "Replace this")
                    arguments = ["action": "key", "keys": ["Command", "a"]]
                case 4: arguments = ["action": "type", "text": exact]
                case 5:
                    try await self.verify(state, field: "destination", equals: exact)
                    simulatedLogin = true
                    arguments = ["action": "wait", "time": 0]
                default: arguments = ["action": "terminate", "answer": "The two fields are filled."]
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
                try await verify(state, field: "origin", equals: "Seattle")
                try await verify(state, field: "destination", equals: exact)
                let replay = try await executor.execute(taskID: "native-form", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
                XCTAssertEqual(replay, result); XCTAssertEqual(proposals, 7)
                let journals = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("native-loop"), includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
                let dispatches = journals.filter { $0.stepIDs == ["native-dispatch-returned"] }
                XCTAssertEqual(dispatches.count, 5)
                XCTAssertTrue(dispatches.allSatisfy { $0.statuses == [.verified] })
                let report: [String: Any] = ["inference": false, "nativeInput": true, "proposals": proposals,
                    "verifiedDispatches": dispatches.count, "simulatedLogin": true,
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

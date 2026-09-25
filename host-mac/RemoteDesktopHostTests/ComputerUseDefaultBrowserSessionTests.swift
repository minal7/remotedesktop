import XCTest
import AppKit
import CoreImage
import CoreGraphics
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseDefaultBrowserSessionTests: XCTestCase {
    private final class FakeDesktop {
        var windows: [ComputerUseDefaultBrowserSession.Window] = []
        var focusedID: String?
        var launchCount = 0
        var keyCount = 0
        var createCount = 1
        var transientWindowFailures = 0
        var transientWindowFailure: ComputerUseDefaultBrowserSession.Failure = .targetLost
        var deferNewWindowFocusCaptures = 0
        var pendingFocusedID: String?
        var newWindowCreated = false
        var taskID = "task-1"
        var fileOpenPanel: ComputerUseDefaultBrowserSession.FileOpenPanel?
        var hasUnrecognizedSheets = false

        func snapshot(application: ComputerUseApplicationIdentity) -> ComputerUseDefaultBrowserSession.WindowSnapshot {
            .init(application: application, windows: windows, focusedWindowID: focusedID,
                hasSheets: fileOpenPanel != nil || hasUnrecognizedSheets,
                fileOpenPanel: fileOpenPanel, hasUnrecognizedSheets: hasUnrecognizedSheets)
        }
    }

    func testEnsureOpensExactlyOneWindowAndResumeReturnsSameRetainedWindow() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = try fixture.session()
        let first = try await session.ensure(taskID: "task-1", goal: "Use the default browser", tools: fixture.tools)
        let resumed = try await session.ensure(taskID: "task-1", goal: "Use the default browser", tools: fixture.tools)
        XCTAssertEqual(first.id, "new")
        XCTAssertEqual(resumed.id, first.id)
        XCTAssertEqual(fixture.desktop.launchCount, 1)
        XCTAssertEqual(fixture.desktop.keyCount, 1)
        XCTAssertEqual(fixture.desktop.windows.map(\.id), ["existing", "new"])
        XCTAssertEqual(fixture.desktop.windows.first?.identity, fixture.original.identity)
    }

    func testWindowCreationWaitsForTransientAXLossOrAmbiguityWithoutRepeatingInput() async throws {
        for failure in [ComputerUseDefaultBrowserSession.Failure.targetLost, .ambiguousWindows] {
            let fixture = try Fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            fixture.desktop.transientWindowFailures = 1
            fixture.desktop.transientWindowFailure = failure
            let session = try fixture.session()
            let window = try await session.ensure(taskID: "task-1", goal: "Use the default browser", tools: fixture.tools)
            XCTAssertEqual(window.id, "new")
            XCTAssertEqual(fixture.desktop.keyCount, 1)
        }
    }

    func testWindowBoundsRefreshAndUnfocusedCreationAreTransient() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.desktop.deferNewWindowFocusCaptures = 2
        let session = try fixture.session()
        let first = try await session.ensure(taskID: "task-1", goal: "Use the default browser", tools: fixture.tools)
        XCTAssertEqual(first.id, "new")
        XCTAssertEqual(fixture.desktop.keyCount, 1)

        let index = try XCTUnwrap(fixture.desktop.windows.firstIndex(where: { $0.id == first.id }))
        let old = fixture.desktop.windows[index]
        let resizedBounds = CGRect(x: 40, y: 50, width: 900, height: 700)
        let resizedIdentity = ComputerUseFrontmostWindowCaptureIdentity(
            applicationProcessIdentifier: old.identity.applicationProcessIdentifier,
            accessibilityWindowHash: old.identity.accessibilityWindowHash,
            bounds: resizedBounds)
        fixture.desktop.windows[index] = .init(id: old.id, application: old.application,
            accessibilityElement: old.accessibilityElement, identity: resizedIdentity)
        let resumed = try await session.ensure(taskID: "task-1", goal: "Use the default browser", tools: fixture.tools)
        XCTAssertEqual(resumed.id, first.id)
        XCTAssertEqual(resumed.identity.bounds, resizedBounds)
        XCTAssertTrue(CFEqual(resumed.accessibilityElement, first.accessibilityElement))
        XCTAssertEqual(fixture.desktop.keyCount, 1, "Transient focus or geometry changes must not replay Cmd-N")
    }

    func testChangedTaskOrGoalAndLostWindowFailWithoutOpeningAnother() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = try fixture.session()
        _ = try await session.ensure(taskID: "task-1", goal: "Use the default browser", tools: fixture.tools)
        XCTAssertThrowsError(try session.validate(taskID: "task-2", goal: "Use the default browser", tools: fixture.tools))
        XCTAssertThrowsError(try session.validate(taskID: "task-1", goal: "Different goal", tools: fixture.tools))
        fixture.desktop.windows.removeAll { $0.id == "new" }
        fixture.desktop.focusedID = "existing"
        XCTAssertThrowsError(try session.validate(taskID: "task-1", goal: "Use the default browser", tools: fixture.tools))
        do {
            _ = try await session.ensure(taskID: "task-1", goal: "Use the default browser", tools: fixture.tools)
            XCTFail("A lost session window must not be replaced")
        } catch {}
        XCTAssertEqual(fixture.desktop.launchCount, 1)
        XCTAssertEqual(fixture.desktop.keyCount, 1)
    }

    func testCancelledBeforeLaunchDoesNotDispatchOrCreateWindow() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = try fixture.session()
        let operation = Task { try await session.ensure(taskID: "task-1", goal: "Use the default browser", tools: fixture.tools) }
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("Cancelled session setup must stop before launch or native input")
        } catch is CancellationError {
        } catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertEqual(fixture.desktop.launchCount, 0)
        XCTAssertEqual(fixture.desktop.keyCount, 0)
    }

    func testMissingOrMultipleNewWindowsFailAndNeverReplayCmdN() async throws {
        for createdCount in [0, 2] {
            let fixture = try Fixture(createCount: createdCount)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let session = try fixture.session()
            do {
                _ = try await session.ensure(taskID: "task-1", goal: "Use the default browser", tools: fixture.tools)
                XCTFail("Only exactly one new focused AX window is accepted")
            } catch {}
            do {
                _ = try await session.ensure(taskID: "task-1", goal: "Use the default browser", tools: fixture.tools)
                XCTFail("An uncertain attempted Cmd+N must never replay")
            } catch {}
            XCTAssertEqual(fixture.desktop.keyCount, 1)
        }
    }

    func testNativeSheetsCauseHandoffBeforeKeyboardInput() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.desktop.windows[0] = fixture.window("existing", pid: 91, hash: 1)
        let session = try fixture.session(hasSheets: true)
        do {
            _ = try await session.ensure(taskID: "task-1", goal: "Use the default browser", tools: fixture.tools)
            XCTFail("This slice must not act inside arbitrary sheets or file pickers")
        } catch {}
        XCTAssertEqual(fixture.desktop.keyCount, 0)
    }

    func testRecognizedFileOpenPanelScopesActionsAndRestoresParentBounds() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = try fixture.session()
        let parent = try await session.ensure(taskID: "task-1", goal: "Use the default browser", tools: fixture.tools)
        let parentBounds = parent.identity.bounds
        let pickerBounds = CGRect(x: 300, y: 200, width: 700, height: 500)
        let selectedURL = URL(fileURLWithPath: "/fixture/selected.pdf")
        let primaryBounds = CGRect(x: 900, y: 650, width: 90, height: 32)
        fixture.desktop.fileOpenPanel = fixture.fileOpenPanel(parentWindowID: parent.id, bounds: pickerBounds,
            focused: true, selectedFileURLs: [selectedURL], primaryActionBounds: primaryBounds, primaryActionEnabled: true)

        try session.validate(taskID: "task-1", goal: "Use the default browser", tools: fixture.tools)
        XCTAssertEqual(session.currentActionBounds, pickerBounds)
        XCTAssertEqual(session.currentFileOpenPanel?.parentWindowID, parent.id)
        XCTAssertEqual(session.currentFileOpenPanel?.selectedFileURLs, [selectedURL])
        XCTAssertEqual(session.currentFileOpenPanel?.primaryActionBounds, primaryBounds)
        XCTAssertEqual(session.currentFileOpenPanel?.primaryActionEnabled, true)
        XCTAssertEqual(session.currentWindow?.identity.bounds, parentBounds, "Picker geometry must not replace browser-window identity bounds")

        let goToBounds = CGRect(x: 420, y: 330, width: 450, height: 180)
        fixture.desktop.fileOpenPanel = fixture.fileOpenPanel(parentWindowID: parent.id,
            bounds: CGRect(x: 280, y: 180, width: 760, height: 540),
            focused: true, goToFolderBounds: goToBounds)
        try session.validate(taskID: "task-1", goal: "Use the default browser", tools: fixture.tools)
        XCTAssertTrue(session.currentFileOpenPanel?.isNavigatingPath == true)
        XCTAssertEqual(session.currentActionBounds, goToBounds)

        fixture.desktop.fileOpenPanel = nil
        try session.validate(taskID: "task-1", goal: "Use the default browser", tools: fixture.tools)
        XCTAssertNil(session.currentFileOpenPanel)
        XCTAssertEqual(session.currentActionBounds, parentBounds)
    }

    func testFileOpenPanelMustBelongToRetainedWindowAndHaveNoOtherSheets() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = try fixture.session()
        let parent = try await session.ensure(taskID: "task-1", goal: "Use the default browser", tools: fixture.tools)
        fixture.desktop.fileOpenPanel = fixture.fileOpenPanel(parentWindowID: "foreign-window",
            bounds: CGRect(x: 300, y: 200, width: 700, height: 500), focused: true)
        XCTAssertThrowsError(try session.validate(taskID: "task-1", goal: "Use the default browser", tools: fixture.tools))
        XCTAssertEqual(session.currentWindow?.id, parent.id)

        fixture.desktop.fileOpenPanel = fixture.fileOpenPanel(parentWindowID: parent.id,
            bounds: CGRect(x: 300, y: 200, width: 700, height: 500), focused: true)
        fixture.desktop.hasUnrecognizedSheets = true
        XCTAssertThrowsError(try session.validate(taskID: "task-1", goal: "Use the default browser", tools: fixture.tools))
    }

    func testOptInDefaultBrowserFaraSelectsDisposableTranslateFileAndStopsBeforeUpload() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_DEFAULT_BROWSER_FILE_PICKER_PROBE"] == "1" else {
            throw XCTSkip("Opt-in: real Fara and native planner select one disposable file in the real Safari picker")
        }
        let began = ContinuousClock.now
        let faraInputs = try await FaraTestAssets.inputs(environment: environment)
        let installedReceipt = await ComputerUseInstaller.nativeText().currentInstallation()
        let receipt = try XCTUnwrap(installedReceipt)
        let runtimeDirectory = try await OSAtlasVisualExecutorLoader.bundledRuntimeDirectoryURL(in: .main)
        let nativeInputs = try OSAtlasRuntimeInputResolver(manifest: .nativeTextV2).resolveNativeText(
            receipt: receipt, runtimeDirectoryURL: runtimeDirectory, enclosingBundleURL: Bundle.main.bundleURL)
        let responseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DefaultBrowserPickerResponse-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: responseURL) }
        let runtime = OSAtlasLlamaRuntime(inspectFaraExchange: { _, response in
            try? response.prefix(65_536).write(to: responseURL, options: .atomic)
        })
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DefaultBrowserFilePicker-" + UUID().uuidString, isDirectory: true)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let fixtureRoot = downloads.appendingPathComponent(".remote-desktop-picker-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixtureRoot); try? FileManager.default.removeItem(at: directory) }
        let name = "Disposable Translate Picker Probe.pdf"
        let expectedURL = fixtureRoot.appendingPathComponent(name)
        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 72, height: 72)
        let consumer = try XCTUnwrap(CGDataConsumer(data: pdfData as CFMutableData))
        let pdf = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        pdf.beginPDFPage(nil); pdf.endPDFPage(); pdf.closePDF()
        try (pdfData as Data).write(to: expectedURL)
        let session = try ComputerUseDefaultBrowserSession(journalDirectory: directory)
        let nativeSteps = ComputerUseRuntimeBrowserStepPlanner(inputs: nativeInputs, runtime: runtime)
        let nativeFileSelectionPlanner = ComputerUseMCPBrowserStepPlanner(nativeTextPlanner: { nativeSteps })
        var proposals: [String] = []
        var actionErrors: [String] = []
        var nativeCalls = 0
        var selectedBeforeUpload = false
        let executor = try ComputerUseDefaultBrowserExecutor(journalDirectory: directory, session: session,
            propose: { input in
                if let error = input.actionError { actionErrors.append(error) }
                if let panel = session.currentFileOpenPanel,
                   panel.selectedFileURLs.count == 1,
                   panel.selectedFileURLs[0].standardizedFileURL.resolvingSymlinksInPath()
                    == expectedURL.standardizedFileURL.resolvingSymlinksInPath(),
                   panel.primaryActionEnabled == true,
                   input.localFileCatalog?.selectedCandidate?.displayName == name {
                    selectedBeforeUpload = true
                    proposals.append("test-stop-before-upload: exact selected URL verified")
                    return .init(response: "Exact disposable file selected. Stop before Upload.",
                        decision: .handoff("Review the selected disposable file before submitting it."))
                }
                guard proposals.count < 12 else { throw ComputerUseDesktopExecutor.Failure.stepLimit }
                let endpoint = try await runtime.activateFara(faraInputs)
                let proposal = try await runtime.proposeFara(endpoint: endpoint, input: input)
                proposals.append(String(describing: proposal.action).prefix(256).description)
                return .init(proposal)
            }, nativeFilePlanner: { input in
                nativeCalls += 1
                return try await nativeFileSelectionPlanner.proposeNativeFileSelection(input: input)
            }, localFileCatalogFactory: { taskID in
                try ComputerUseLocalFileCatalog(taskID: taskID, approvedDirectory: fixtureRoot, pageSize: 8)
            })
        let taskID = UUID().uuidString
        let goal = "In the default browser, open https://translate.google.com/?sl=auto&tl=es&op=docs, choose \(name) from Downloads in the native file picker, then stop before pressing Upload. Do not submit the file."
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true })
        let operation = Task { @MainActor in
            try await executor.execute(taskID: taskID, prompt: goal, trustedUserPrompt: goal,
                tools: tools, progress: { _ in })
        }
        let remaining = max(Int64(1), 150 - (ContinuousClock.now - began).components.seconds)
        let deadline = Task { try? await Task.sleep(for: .seconds(remaining)); operation.cancel() }
        var result: ComputerUseExecutionResult?
        var failure: Error?
        do { result = try await operation.value } catch { failure = error }
        deadline.cancel()
        await runtime.shutdown()
        if let data = try? Data(contentsOf: responseURL) {
            let response = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            response.name = "Raw Fara response at native picker handoff"
            response.lifetime = .keepAlways
            add(response)
        }
        XCTAssertTrue(selectedBeforeUpload, "No exact selected-file handoff. Result=\(String(describing: result)); error=\(String(describing: failure)); sessionFailure=\(String(describing: executor.lastSessionFailureForDiagnostics)); nativeCalls=\(nativeCalls); proposals=\(proposals); actionErrors=\(actionErrors); diagnostic=\(executor.lastActionDiagnosticForTests)")
        guard let result else { XCTFail("No result; error=\(String(describing: failure))"); return }
        if case .userInterventionRequired = result { } else { XCTFail("Expected handoff before picker Upload; got \(result), error=\(String(describing: failure))") }
        let window = try XCTUnwrap(executor.retainedWindowForDiagnostics)
        let page = try XCTUnwrap(ComputerUseDefaultBrowserPageReader().read(
            window: window.accessibilityElement, application: window.application, mayAct: { true }))
        XCTAssertEqual(URL(string: page.url)?.host, "translate.google.com")
        let attachment = XCTAttachment(string: proposals.joined(separator: "\n"))
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Actual model proposals before native picker handoff") { $0.add(attachment) }
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(155))
    }

    func testOptInCurrentDefaultBrowserNativePointerGeometry() throws {
        guard ProcessInfo.processInfo.environment["RUN_DEFAULT_BROWSER_POINTER_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Read-only hit test on the prepared real browser page")
        }
        let handler = try XCTUnwrap(ComputerUseDefaultBrowserTarget.currentDefaultHTTPSHandler())
        let app = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
        XCTAssertEqual(app.bundleIdentifier, handler.bundleIdentifier)
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true })
        let action = ComputerUsePredictedAction.click(x: 1152, y: 401, button: 1, count: 1)
        let frame = try tools.nativePointerTargetFrame(for: action)
        var facts: [String: String] = ["nativeTargetFrame": String(describing: frame)]
        for (name, root) in [("system", AXUIElementCreateSystemWide()),
                             ("application", AXUIElementCreateApplication(app.processIdentifier))] {
            var hit: AXUIElement?
            facts[name + "Result"] = String(AXUIElementCopyElementAtPosition(root, 1152, 401, &hit).rawValue)
            for depth in 0..<4 {
                guard let element = hit else { break }
                for attribute in [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute] {
                    var value: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success {
                        facts["\(name).\(depth).\(attribute)"] = String(describing: value)
                    }
                }
                var parent: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                      let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                hit = (parent as! AXUIElement)
            }
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]),
            uniformTypeIdentifier: "public.json")
        attachment.name = "Native browser point geometry"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertNotNil(frame, "Expected the visible Browse button to have native target geometry")
    }

    func testOptInCaptureRecognizesCurrentDefaultBrowserFilePicker() throws {
        guard ProcessInfo.processInfo.environment["RUN_DEFAULT_BROWSER_PICKER_CAPTURE_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Opt-in read-only capture of the already-open default-browser native picker")
        }
        let began = ContinuousClock.now
        let handler = try XCTUnwrap(ComputerUseDefaultBrowserTarget.currentDefaultHTTPSHandler())
        let app = try XCTUnwrap(NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated && $0.bundleIdentifier == handler.bundleIdentifier
                && $0.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier
        })
        let identity = try XCTUnwrap(ComputerUseApplicationIdentity(runningApplication: app))
        let snapshot = try ComputerUseDefaultBrowserSession.captureWindowsForApplication(identity)
        let elapsedMS = (ContinuousClock.now - began).components.attoseconds / 1_000_000_000_000_000
        let panel = snapshot.fileOpenPanel
        let diagnostic: [String: Any] = [
            "elapsedMilliseconds": elapsedMS,
            "hasSheets": snapshot.hasSheets,
            "hasUnrecognizedSheets": snapshot.hasUnrecognizedSheets,
            "recognizedFileOpenPanel": panel != nil,
            "panelFocused": panel?.isFocused ?? false,
            "focusedWindowMatchesPanelParent": snapshot.focusedWindowID == panel?.parentWindowID,
            "sessionFocusAdmission": panel.map { snapshot.focusedWindowID == $0.parentWindowID || $0.isFocused } ?? false,
            "hasSelectedURL": !(panel?.selectedFileURLs.isEmpty ?? true)
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]),
            uniformTypeIdentifier: "public.json")
        attachment.name = "Default-browser native picker capture facts"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(snapshot.hasSheets)
        XCTAssertFalse(snapshot.hasUnrecognizedSheets)
        XCTAssertNotNil(panel)
        XCTAssertTrue(panel.map { snapshot.focusedWindowID == $0.parentWindowID || $0.isFocused } ?? false,
            "Capture recognized a picker but failed the exact focus condition used by session validation")
    }

    func testOptInLiveBrowserSheetStructureDiagnostic() async throws {
        guard ProcessInfo.processInfo.environment["COMPUTER_USE_DEFAULT_BROWSER_SHEET_AX_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Set COMPUTER_USE_DEFAULT_BROWSER_SHEET_AX_DIAGNOSTIC=1 while the disposable browser picker is open")
        }
        let handler = try XCTUnwrap(ComputerUseDefaultBrowserTarget.currentDefaultHTTPSHandler())
        let matchingApps = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.bundleIdentifier == handler.bundleIdentifier
        }
        XCTAssertEqual(matchingApps.count, 1, "Expected exactly one running default-browser process")
        let app = try XCTUnwrap(matchingApps.first)
        XCTAssertTrue(app.activate(options: []), "Could not activate the existing browser")
        let foregroundDeadline = ContinuousClock.now.advanced(by: .seconds(1.5))
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier,
              ContinuousClock.now < foregroundDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, app.processIdentifier,
            "The diagnostic must inspect the browser only after its existing window is foreground")
        let identity = try XCTUnwrap(ComputerUseApplicationIdentity(runningApplication: app))
        let productionSnapshot = try ComputerUseDefaultBrowserSession.captureWindowsForApplication(identity)
        XCTAssertFalse(productionSnapshot.hasUnrecognizedSheets, "Only the known website file-open sheet may be admitted")
        let productionPanel = try XCTUnwrap(productionSnapshot.fileOpenPanel)
        XCTAssertTrue(productionSnapshot.hasSheets)
        XCTAssertTrue(productionSnapshot.windows.contains { $0.id == productionPanel.parentWindowID })
        let expectedSelectedURL = URL(fileURLWithPath:
            "/Users/michael/Downloads/RemoteDesktop-Disposable-Picker-Probe-20260924.pdf")
        XCTAssertTrue(productionPanel.isNavigatingPath
            || productionPanel.selectedFileURLs.contains(expectedSelectedURL),
            "Expected the disposable fixture selection or its verified nested Go To sheet")
        let root = AXUIElementCreateApplication(app.processIdentifier)
        func copy(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
            return value
        }
        func string(_ element: AXUIElement, _ attribute: CFString) -> String {
            copy(element, attribute) as? String ?? "-"
        }
        func bounds(_ element: AXUIElement) -> CGRect? {
            guard let raw = copy(element, kAXPositionAttribute as CFString),
                  CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
            var origin = CGPoint.zero
            guard AXValueGetValue(raw as! AXValue, .cgPoint, &origin),
                  let sizeRaw = copy(element, kAXSizeAttribute as CFString),
                  CFGetTypeID(sizeRaw) == AXValueGetTypeID() else { return nil }
            var size = CGSize.zero
            guard AXValueGetValue(sizeRaw as! AXValue, .cgSize, &size) else { return nil }
            return CGRect(origin: origin, size: size)
        }
        func elements(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
            copy(element, attribute) as? [AXUIElement] ?? []
        }
        var rows: [String] = []
        let appWindows = elements(root, kAXWindowsAttribute as CFString)
        let focusedValue = copy(root, kAXFocusedWindowAttribute as CFString)
        let focused: AXUIElement? = focusedValue.flatMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        }
        for (windowIndex, window) in appWindows.enumerated() {
            let sheets = elements(window, kAXChildrenAttribute as CFString).enumerated().filter { _, child in
                string(child, kAXRoleAttribute as CFString) == "AXSheet"
                    && string(child, "AXIdentifier" as CFString) == "open-panel"
            }
            guard !sheets.isEmpty else { continue }
            let windowID = string(window, "AXIdentifier" as CFString)
            let windowPath = "AXApplication/AXWindows[\(windowIndex)]"
            let rect = bounds(window).map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" } ?? "-"
            rows.append("path=\(windowPath) role=\(string(window, kAXRoleAttribute as CFString)) id=\(windowID) focused=\(focused.map { CFEqual($0, window) } ?? false) bounds=\(rect)")
            for (childIndex, panel) in sheets {
                var queue: [(AXUIElement, String, Int)] = [(panel, "\(windowPath)/AXChildren[\(childIndex)]", 0)]
                while let (element, path, depth) = queue.first, rows.count < 320 {
                    queue.removeFirst()
                    let rect = bounds(element).map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" } ?? "-"
                    let parentValue = copy(element, kAXParentAttribute as CFString)
                    let parent: AXUIElement? = parentValue.flatMap {
                        CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
                    }
                    let parentDescription = parent.map {
                        "\(string($0, kAXRoleAttribute as CFString))#\(string($0, "AXIdentifier" as CFString))"
                    } ?? "-"
                    rows.append("path=\(path) parent=\(parentDescription) role=\(string(element, kAXRoleAttribute as CFString)) id=\(string(element, "AXIdentifier" as CFString)) bounds=\(rect)")
                    guard depth < 5 else { continue }
                    let children = elements(element, kAXChildrenAttribute as CFString)
                    let nestedSheets = elements(element, "AXSheets" as CFString)
                    for (index, child) in nestedSheets.enumerated() {
                        queue.append((child, "\(path)/AXSheets[\(index)]", depth + 1))
                    }
                    for (index, child) in children.enumerated() where !nestedSheets.contains(where: { CFEqual($0, child) }) {
                        queue.append((child, "\(path)/AXChildren[\(index)]", depth + 1))
                    }
                }
            }
        }
        XCTContext.runActivity(named: "AX picker structure (no labels, values, or file contents)") { activity in
            let attachment = XCTAttachment(string: rows.joined(separator: "\n"))
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        XCTAssertFalse(rows.isEmpty, "Expected structural AX rows from the foreground browser")
    }

    func testLiveSmokeIsOptInAndCreatesOnlyAnEmptyBrowserWindow() async throws {
        guard ProcessInfo.processInfo.environment["COMPUTER_USE_DEFAULT_BROWSER_SESSION_LIVE"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_COMPUTER_USE_DEFAULT_BROWSER_SESSION_LIVE=1 to open an empty default-browser window")
        }
        let directory = ComputerUseTextStepStore.defaultDirectory.appendingPathComponent("Default Browser Session Live", isDirectory: true)
        let session = try ComputerUseDefaultBrowserSession(journalDirectory: directory)
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true })
        let taskID = UUID().uuidString
        let goal = "Open one empty default-browser window"
        let handler = try XCTUnwrap(ComputerUseDefaultBrowserTarget.currentDefaultHTTPSHandler())
        let target = try await session.ensure(taskID: taskID, goal: goal, tools: tools)
        XCTAssertNotNil(target.application.codeIdentity)
        XCTAssertEqual(target.application.bundleIdentifier, handler.bundleIdentifier)
        XCTAssertEqual(target.application.codeIdentity?.canonicalBundlePath,
            handler.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(target.identity.applicationProcessIdentifier, target.application.processIdentifier)
        let resumed = try await session.ensure(taskID: taskID, goal: goal, tools: tools)
        XCTAssertEqual(resumed.id, target.id)
        XCTAssertTrue(CFEqual(resumed.accessibilityElement, target.accessibilityElement))
    }

    @MainActor
    private struct Fixture {
        let desktop: FakeDesktop
        let handler: ComputerUseDefaultBrowserTarget.Handler
        let app: ComputerUseApplicationIdentity
        let original: ComputerUseDefaultBrowserSession.Window
        let tools: ComputerUseHostTools
        let root: URL
        var hasSheets: Bool

        init(createCount: Int = 1) throws {
            desktop = FakeDesktop()
            handler = .init(bundleURL: URL(fileURLWithPath: "/fixture/Browser.app"), bundleIdentifier: "org.example.Browser")
            app = Self.identity(pid: 91, path: handler.bundleURL.path)
            original = Self.makeWindow("existing", pid: 91, hash: 1)
            desktop.windows = [original]
            desktop.focusedID = original.id
            desktop.createCount = createCount
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            hasSheets = false
            tools = Self.tools(app: app, desktop: desktop)
        }

        init(createCount: Int = 1, hasSheets: Bool) throws {
            try self.init(createCount: createCount)
            self.hasSheets = hasSheets
        }

        func session(hasSheets override: Bool? = nil) throws -> ComputerUseDefaultBrowserSession {
            try ComputerUseDefaultBrowserSession(journalDirectory: root,
                resolveHandler: { handler },
                launchApplication: { _, beforeOpen in try beforeOpen(); desktop.launchCount += 1; return app },
                captureWindows: { identity in
                    guard identity == app else { throw ComputerUseDefaultBrowserSession.Failure.targetLost }
                    if desktop.keyCount > 0, desktop.transientWindowFailures > 0 {
                        desktop.transientWindowFailures -= 1
                        throw desktop.transientWindowFailure
                    }
                    if desktop.newWindowCreated && desktop.deferNewWindowFocusCaptures > 0 {
                        desktop.deferNewWindowFocusCaptures -= 1
                        let snapshot = ComputerUseDefaultBrowserSession.WindowSnapshot(
                            application: app, windows: desktop.windows, focusedWindowID: "existing", hasSheets: false)
                        if desktop.deferNewWindowFocusCaptures == 0, let pending = desktop.pendingFocusedID {
                            desktop.focusedID = pending
                        }
                        return snapshot
                    }
                    var snapshot = desktop.snapshot(application: app)
                    if override ?? hasSheets {
                        snapshot = .init(application: app, windows: snapshot.windows, focusedWindowID: snapshot.focusedWindowID, hasSheets: true)
                    }
                    return snapshot
                })
        }

        func window(_ id: String, pid: pid_t, hash: CFHashCode) -> ComputerUseDefaultBrowserSession.Window {
            Self.makeWindow(id, pid: pid, hash: hash)
        }

        func fileOpenPanel(parentWindowID: String, bounds: CGRect, focused: Bool,
                           goToFolderBounds: CGRect? = nil, selectedFileURLs: [URL] = [],
                           primaryActionBounds: CGRect? = nil, primaryActionEnabled: Bool? = nil) -> ComputerUseDefaultBrowserSession.FileOpenPanel {
            .init(parentWindowID: parentWindowID,
                parentWindowElement: desktop.windows.first(where: { $0.id == parentWindowID })?.accessibilityElement
                    ?? AXUIElementCreateApplication(app.processIdentifier + 101),
                accessibilityElement: AXUIElementCreateApplication(app.processIdentifier + 100),
                bounds: bounds, isFocused: focused, goToFolderBounds: goToFolderBounds,
                pathTextFieldElement: goToFolderBounds == nil ? nil : AXUIElementCreateApplication(app.processIdentifier + 102),
                selectedFileURLs: selectedFileURLs, primaryActionElement: nil,
                primaryActionBounds: primaryActionBounds, primaryActionEnabled: primaryActionEnabled)
        }

        private static func makeWindow(_ id: String, pid: pid_t, hash: CFHashCode) -> ComputerUseDefaultBrowserSession.Window {
            let identity = ComputerUseFrontmostWindowCaptureIdentity(applicationProcessIdentifier: pid,
                accessibilityWindowHash: hash, bounds: CGRect(x: 1, y: 2, width: 800, height: 600))
            let uniquePID = pid + pid_t(hash)
            return .init(id: id, application: self.identity(pid: pid, path: "/fixture/Browser.app"),
                accessibilityElement: AXUIElementCreateApplication(uniquePID), identity: identity)
        }

        private static func identity(pid: pid_t, path: String) -> ComputerUseApplicationIdentity {
            let code = ComputerUseApplicationCodeIdentity(authority: .runningCode, bundleIdentifier: "org.example.Browser",
                canonicalBundlePath: path, canonicalExecutablePath: "\(path)/Contents/MacOS/Browser",
                designatedRequirement: "fixture", teamIdentifier: "TEST", platformIdentifier: nil)
            return try! XCTUnwrap(ComputerUseApplicationIdentity(bundleIdentifier: "org.example.Browser",
                processIdentifier: pid, launchGeneration: 1, codeIdentity: code))
        }

        private static func tools(app: ComputerUseApplicationIdentity, desktop: FakeDesktop) -> ComputerUseHostTools {
            ComputerUseHostTools(injector: InputInjector(), mayAct: { true },
                approvalTargetProvider: { _ in .init(context: "Browser focused window", applicationID: app.bundleIdentifier,
                    accessibilityIdentity: "window:\(desktop.focusedID ?? "none")") },
                actionPerformer: { action in
                    guard case .key(let usage, let modifiers) = action, usage == 0x11, modifiers == (1 << 3) else {
                        throw ComputerUseDefaultBrowserSession.Failure.interrupted
                    }
                    desktop.keyCount += 1
                    for index in 0..<desktop.createCount {
                        let window = makeWindow(index == 0 ? "new" : "new-\(index)", pid: app.processIdentifier, hash: CFHashCode(2 + index))
                        desktop.windows.append(window)
                        if index == 0 && desktop.deferNewWindowFocusCaptures > 0 {
                            desktop.newWindowCreated = true
                            desktop.pendingFocusedID = window.id
                            desktop.focusedID = "existing"
                        } else {
                            desktop.focusedID = window.id
                        }
                    }
                }, screenProvider: {
                    .init(image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480)),
                        displayBounds: CGRect(x: 0, y: 0, width: 640, height: 480),
                        frontmostWindowBounds: CGRect(x: 0, y: 0, width: 640, height: 480))
                }, authenticationContextProvider: { nil }, screenCaptureConsentContextProvider: { nil },
                planningAccessibilityIdentityProvider: { "fixture-window" },
                frontmostApplicationIdentityProvider: { app }, frontmostApplicationProvider: { app.bundleIdentifier })
        }
    }
}

import XCTest
import AppKit
@testable import RemoteDesktopHost

/// Native integration probe only: no model, account selection, password, or upload.
/// The opt-in test opens Drive in the task-owned default-browser window and stops at login handoff.
@MainActor
final class ComputerUseDefaultBrowserDriveProbeTests: XCTestCase {
    func testOptInNativeDriveLoginHandoffProbe() async throws {
        guard ProcessInfo.processInfo.environment["COMPUTER_USE_DEFAULT_BROWSER_DRIVE_PROBE"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_COMPUTER_USE_DEFAULT_BROWSER_DRIVE_PROBE=1 to navigate one task-owned browser window to Drive")
        }

        let taskID = UUID().uuidString
        let goal = "Open Google Drive and stop at the account or login handoff"
        let journal = ComputerUseTextStepStore.defaultDirectory
            .appendingPathComponent("Default Browser Drive Probe", isDirectory: true)
        let session = try ComputerUseDefaultBrowserSession(journalDirectory: journal)
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true })
        let handler = try XCTUnwrap(ComputerUseDefaultBrowserTarget.currentDefaultHTTPSHandler())

        let ownedWindow = try await session.ensure(taskID: taskID, goal: goal, tools: tools)
        var dispatchedActions: [String] = []
        func dispatch(_ action: ComputerUsePredictedAction, label: String) async throws {
            for attempt in 0..<3 {
                try session.validate(taskID: taskID, goal: goal, tools: tools)
                try Task.checkCancellation()
                try tools.requireActive()
                let fingerprint = try tools.prepareNativeActionFingerprint(for: action)
                var began = false
                do {
                    try await tools.performNativeAction(action, fingerprint: fingerprint, willBeginEffect: {
                        try session.validate(taskID: taskID, goal: goal, tools: tools)
                        try Task.checkCancellation()
                        try tools.requireActive()
                        began = true
                    })
                    try Task.checkCancellation()
                    try tools.requireActive()
                    try session.validate(taskID: taskID, goal: goal, tools: tools)
                    dispatchedActions.append(label)
                    return
                } catch ComputerUseHostTools.ToolError.approvalTargetChanged where !began && attempt < 2 {
                    // Reobserve a startup transition only when no input began.
                    try await Task.sleep(for: .milliseconds(150))
                }
            }
        }

        try await dispatch(ComputerUseNativeKeyChord.action(["Command", "l"]), label: "focus-location")
        try await dispatch(.typeText("https://drive.google.com"), label: "type-drive-url")
        try await dispatch(ComputerUseNativeKeyChord.action(["Return"]), label: "navigate-once")

        let reader = ComputerUseDefaultBrowserPageReader(access: .live)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var observed: ComputerUseDefaultBrowserPageReader.Observation?
        var loginContextFound = false
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try tools.requireActive()
            try session.validate(taskID: taskID, goal: goal, tools: tools)
            if let page = try reader.read(window: ownedWindow.accessibilityElement,
                                          application: ownedWindow.application,
                                          mayAct: { true }),
               let components = URLComponents(string: page.url),
               let host = components.host?.lowercased(),
               host == "drive.google.com" || host == "accounts.google.com" {
                let text = page.renderedAXText.lowercased()
                let hasLoginContext = ["sign in", "choose an account", "google account"]
                    .contains(where: { text.contains($0) })
                if hasLoginContext {
                    observed = page
                    loginContextFound = true
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        let page = try XCTUnwrap(observed, "Expected a bounded Drive/account login observation within 10 seconds")
        let components = try XCTUnwrap(URLComponents(string: page.url))
        let host = try XCTUnwrap(components.host)
        let path = components.path.isEmpty ? "/" : components.path
        XCTAssertTrue(["drive.google.com", "accounts.google.com"].contains(host.lowercased()))
        XCTAssertTrue(loginContextFound)
        let authentication = try XCTUnwrap(tools.currentAuthenticationContext())
        XCTAssertTrue(ComputerUseAuthenticationBarrierDetector.requiresUserIntervention(authentication),
            "The real account chooser must stop automation before selecting an account. AX context: \(authentication.boundedWindowContext)")

        let resumed = try await session.ensure(taskID: taskID, goal: goal, tools: tools)
        XCTAssertEqual(resumed.id, ownedWindow.id)
        XCTAssertTrue(CFEqual(resumed.accessibilityElement, ownedWindow.accessibilityElement))
        try session.validate(taskID: taskID, goal: goal, tools: tools)

        // Keep only non-content metadata in the artifact; never attach the page text or URL query.
        let report: [String: Any] = [
            "probe": "native-integration-no-model",
            "handlerBundleIdentifier": handler.bundleIdentifier,
            "handlerBundlePath": handler.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path,
            "observedHost": host,
            "observedPath": path,
            "sameTaskWindowOnResume": resumed.id == ownedWindow.id
                && CFEqual(resumed.accessibilityElement, ownedWindow.accessibilityElement),
            "loginContextFound": loginContextFound,
            "nativeActions": dispatchedActions,
            "pageObservationTruncated": page.truncated,
            "iframeContentMayBeOmitted": page.iframeContentMayBeOmitted,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "default-browser-drive-login-handoff-metadata.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

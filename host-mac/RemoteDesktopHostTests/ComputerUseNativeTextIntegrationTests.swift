import AppKit
import ApplicationServices
import CryptoKit
import CoreImage
import ScreenCaptureKit
import XCTest
import Vision
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseNativeTextIntegrationTests: XCTestCase {
    @MainActor private final class DefaultBrowserFixtureState {
        let app: ComputerUseApplicationIdentity
        var windows: [ComputerUseDefaultBrowserSession.Window]
        var focusedID = "existing"
        var inputCount = 0
        var fileOpenPanel: ComputerUseDefaultBrowserSession.FileOpenPanel?
        init() {
            let path = "/fixture/Browser.app"
            let code = ComputerUseApplicationCodeIdentity(authority: .runningCode, bundleIdentifier: "org.example.Browser",
                canonicalBundlePath: path, canonicalExecutablePath: "\(path)/Contents/MacOS/Browser",
                designatedRequirement: "fixture", teamIdentifier: "TEST", platformIdentifier: nil)
            app = try! XCTUnwrap(ComputerUseApplicationIdentity(bundleIdentifier: "org.example.Browser",
                processIdentifier: 91, launchGeneration: 1, codeIdentity: code))
            windows = [Self.window("existing", pid: 91, hash: 1, app: app)]
        }
        static func window(_ id: String, pid: pid_t, hash: CFHashCode,
            app: ComputerUseApplicationIdentity) -> ComputerUseDefaultBrowserSession.Window {
            .init(id: id, application: app, accessibilityElement: AXUIElementCreateApplication(pid + pid_t(hash)),
                identity: .init(applicationProcessIdentifier: pid, accessibilityWindowHash: hash,
                    bounds: CGRect(x: 0, y: 0, width: 640, height: 480)))
        }
        func session(_ journal: URL) throws -> ComputerUseDefaultBrowserSession {
            let handler = ComputerUseDefaultBrowserTarget.Handler(bundleURL: URL(fileURLWithPath: "/fixture/Browser.app"),
                bundleIdentifier: "org.example.Browser")
            return try .init(journalDirectory: journal, resolveHandler: { handler },
                launchApplication: { _, beforeOpen in try beforeOpen(); return self.app },
                captureWindows: { app in
                    guard app == self.app else { throw ComputerUseDefaultBrowserSession.Failure.targetLost }
                    return .init(application: app, windows: self.windows, focusedWindowID: self.focusedID,
                        hasSheets: self.fileOpenPanel != nil, fileOpenPanel: self.fileOpenPanel)
                })
        }
    }

    func testDefaultBrowserFileChoicesStayTaskBoundAndMetadataSurvivesScreenChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("alpha".utf8).write(to: downloads.appendingPathComponent("Alpha.pdf"))
        try Data("bravo".utf8).write(to: downloads.appendingPathComponent("Bravo.pdf"))

        let state = DefaultBrowserFixtureState()
        var captures = 0, screenColors: [Bool] = []
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true },
            approvalTargetProvider: { _ in .init(context: "fixture", applicationID: state.app.bundleIdentifier,
                accessibilityIdentity: "fixture-window") },
            actionPerformer: { action in
                guard case .key(let usage, let modifiers) = action, usage == 0x11, modifiers == 8 else {
                    throw ComputerUseDefaultBrowserSession.Failure.interrupted
                }
                state.inputCount += 1
                let created = DefaultBrowserFixtureState.window("created", pid: 91, hash: 2, app: state.app)
                state.windows.append(created); state.focusedID = created.id
            }, screenProvider: {
                captures += 1
                let isBlack = captures.isMultiple(of: 2)
                screenColors.append(isBlack)
                let color = isBlack ? CIColor.black : CIColor.white
                return .init(image: CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480)),
                    displayBounds: CGRect(x: 0, y: 0, width: 640, height: 480),
                    frontmostWindowBounds: CGRect(x: 0, y: 0, width: 640, height: 480))
            }, authenticationContextProvider: { nil }, screenCaptureConsentContextProvider: { nil },
            frontmostApplicationIdentityProvider: { state.app }, frontmostApplicationProvider: { "Browser" })
        let session = try state.session(root.appendingPathComponent("session"))
        let taskID = "file-choice-\(UUID().uuidString)", goal = "Ask me which PDF to supply to the current page."
        let window = try await session.ensure(taskID: taskID, goal: goal, tools: tools)
        let panelElement = AXUIElementCreateApplication(201)
        state.fileOpenPanel = .init(parentWindowID: window.id, parentWindowElement: window.accessibilityElement,
            accessibilityElement: panelElement, bounds: CGRect(x: 20, y: 20, width: 600, height: 400),
            isFocused: true, goToFolderBounds: nil, pathTextFieldElement: nil, selectedFileURLs: [],
            primaryActionElement: panelElement, primaryActionBounds: CGRect(x: 500, y: 360, width: 80, height: 30),
            primaryActionEnabled: false)
        var calls = 0, nativeCalls = 0, candidateIDs: [String] = [], sawOriginalGoal = false
        let executor = try ComputerUseDefaultBrowserExecutor(journalDirectory: root.appendingPathComponent("executor"),
            session: session, propose: { input in
                calls += 1
                XCTAssertEqual(input.goal, goal)
                XCTAssertTrue(input.history.isEmpty, "Native catalog plans must not enter Fara's action history")
                let endpoint = OSAtlasLlamaEndpoint(generation: 1, variant: nil,
                    baseURL: URL(string: "http://127.0.0.1:43123")!, bearerToken: "fixture")
                let request = try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: input)
                let body = try XCTUnwrap(request.httpBody)
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
                let userContent = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
                let observation = try XCTUnwrap(userContent.compactMap { $0["text"] as? String }
                    .first(where: { $0.contains("\"localFiles\"") }))
                let fileLine = try XCTUnwrap(observation.components(separatedBy: "\n")
                    .first(where: { $0.contains("\"localFiles\"") }))
                let filePayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fileLine.utf8)) as? [String: Any])
                let localFiles = try XCTUnwrap(filePayload["localFiles"] as? [String: Any])
                let panel = try XCTUnwrap(localFiles["nativeOpenPanelSelection"] as? [String: Any],
                    "Current native picker state must be in the current user observation, separate from the catalog choice")
                XCTAssertEqual(panel["candidateSelected"] as? Bool, true)
                XCTAssertEqual(panel["primaryActionEnabled"] as? Bool, true)
                sawOriginalGoal = input.goal == goal && input.localFileCatalog?.selectedCandidate?.id == candidateIDs.first
                return .init(response: "handoff", decision: .handoff("Ready for the next step."))
            }, nativeFilePlanner: { input in
                nativeCalls += 1
                XCTAssertEqual(input.goal, goal)
                XCTAssertEqual(input.surface, .desktop)
                XCTAssertNil(input.selectedLocalFilePath)
                if nativeCalls == 1 {
                    return .init(kind: .localFileOperation, reference: "", text: "", localFileOperation: .listFiles(query: .init(), cursor: nil))
                }
                candidateIDs = try XCTUnwrap(input.localFileCatalog?.page.candidates.map(\.id))
                return .init(kind: .localFileOperation, reference: "", text: "", localFileOperation: .askFile(question: "Which PDF?", candidateIDs: candidateIDs))
            }, localFileCatalogFactory: { id in
                try ComputerUseLocalFileCatalog(taskID: id, approvedDirectory: downloads)
            })
        let first = try await executor.execute(taskID: taskID, prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
        guard case .clarificationRequired = first else { return XCTFail("Expected a typed file choice") }
        XCTAssertEqual(nativeCalls, 2)
        let resumed = try await executor.execute(taskID: taskID, prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
        guard case .clarificationRequired = resumed else { return XCTFail("Resume must preserve the pending choice") }
        XCTAssertEqual(calls, 0)
        let clarification = try XCTUnwrap(executor.clarification(taskID: taskID))
        let choice = try XCTUnwrap(clarification.choices?.first)
        // The user has also selected that row in the native chooser.
        state.fileOpenPanel = .init(parentWindowID: window.id, parentWindowElement: window.accessibilityElement,
            accessibilityElement: panelElement, bounds: CGRect(x: 20, y: 20, width: 600, height: 400),
            isFocused: true, goToFolderBounds: nil, pathTextFieldElement: nil,
            selectedFileURLs: [downloads.appendingPathComponent(choice.label)],
            primaryActionElement: panelElement, primaryActionBounds: CGRect(x: 500, y: 360, width: 80, height: 30),
            primaryActionEnabled: true)
        let result = try await executor.continueClarification(taskID: taskID + "-choice", originatingTaskID: taskID,
            goal: clarification.goal, selectedChoice: choice, progress: { _ in })
        XCTAssertTrue(sawOriginalGoal)
        XCTAssertEqual(state.inputCount, 1, "Only session creation inputs; metadata and choice dispatch no native effects")
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(Set(screenColors).count, 2, "Fresh captures changed while metadata-only operations continued")
        if case .completed = result { XCTFail("File selection cannot establish remote completion") }
        try FileManager.default.removeItem(at: downloads.appendingPathComponent(choice.label))
        let staleReplay = try await executor.continueClarification(taskID: taskID + "-choice", originatingTaskID: taskID,
            goal: clarification.goal, selectedChoice: choice, progress: { _ in })
        XCTAssertEqual(calls, 1, "Replaying after the catalog file changes must fail before another proposal")
        guard case .userInterventionRequired = staleReplay else { XCTFail("A stale candidate must stop the task"); return }
    }

    func testCancellingAsyncLocalFileOperationDoesNotRequestAnotherProposal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let enteredHandler = expectation(description: "async file handler entered")
        var proposals = 0
        let operation = ComputerUseMCPBrowserStepPlanner.Plan.LocalFileOperation.listFiles(query: .init(), cursor: nil)
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposals += 1
            return .init(response: "list files", action: .localFileOperation(operation))
        }, localFileOperationHandler: { _ in
            enteredHandler.fulfill()
            try await Task.sleep(for: .seconds(30))
            return nil
        })
        let run = Task {
            try await executor.execute(taskID: "async-local-file-cancel", prompt: "List files",
                trustedUserPrompt: "List files", tools: desktopTestTools(), progress: { _ in })
        }
        await fulfillment(of: [enteredHandler], timeout: 2)
        run.cancel()
        do {
            _ = try await run.value
            XCTFail("Cancellation should stop the executor after its awaited local operation")
        } catch is CancellationError { }
        XCTAssertEqual(proposals, 1, "No new proposal may follow a cancelled local file operation")
    }

    func testDefaultBrowserFilePanelRequiresTheResolvedCandidateBeforeOpen() {
        let element = AXUIElementCreateSystemWide()
        let panel = ComputerUseDefaultBrowserSession.FileOpenPanel(parentWindowID: "window",
            parentWindowElement: element, accessibilityElement: element,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600), isFocused: true,
            goToFolderBounds: nil, pathTextFieldElement: nil, selectedFileURLs: [],
            primaryActionElement: element, primaryActionBounds: CGRect(x: 700, y: 560, width: 80, height: 30),
            primaryActionEnabled: true)
        let candidate = URL(fileURLWithPath: "/tmp/selected.pptx")
        let open = ComputerUsePredictedAction.click(x: 720, y: 575, button: 1, count: 1)
        let enter = ComputerUsePredictedAction.key(usage: 0x28, modifiers: 0)
        XCTAssertFalse(ComputerUseDefaultBrowserActionScope.permitsFilePanel(open, within: panel.bounds,
            panel: panel, selectedURL: candidate))
        XCTAssertFalse(ComputerUseDefaultBrowserActionScope.permitsFilePanel(enter, within: panel.bounds,
            panel: panel, selectedURL: candidate))
        XCTAssertFalse(ComputerUseDefaultBrowserActionScope.permitsFilePanel(
            .click(x: 720, y: 575, button: 1, count: 2), within: panel.bounds, panel: panel, selectedURL: candidate))

        let selected = ComputerUseDefaultBrowserSession.FileOpenPanel(parentWindowID: "window",
            parentWindowElement: element, accessibilityElement: element,
            bounds: panel.bounds, isFocused: true, goToFolderBounds: nil, pathTextFieldElement: nil,
            selectedFileURLs: [candidate], primaryActionElement: element,
            primaryActionBounds: panel.primaryActionBounds, primaryActionEnabled: true)
        XCTAssertTrue(ComputerUseDefaultBrowserActionScope.permitsFilePanel(open, within: selected.bounds,
            panel: selected, selectedURL: candidate))
        XCTAssertTrue(ComputerUseDefaultBrowserActionScope.permitsFilePanel(enter, within: selected.bounds,
            panel: selected, selectedURL: candidate))
        XCTAssertFalse(ComputerUseDefaultBrowserActionScope.permitsFilePanel(open, within: selected.bounds,
            panel: selected, selectedURL: URL(fileURLWithPath: "/tmp/other.pptx")))
    }

    func testCurrentPanelSelectionRequiresExactSingleResolvedCandidate() {
        let element = AXUIElementCreateSystemWide()
        let candidate = URL(fileURLWithPath: "/tmp/Selected.pptx")
        func panel(selected: [URL], navigating: Bool = false) -> ComputerUseDefaultBrowserSession.FileOpenPanel {
            .init(parentWindowID: "window", parentWindowElement: element, accessibilityElement: element,
                bounds: CGRect(x: 0, y: 0, width: 800, height: 600), isFocused: true,
                goToFolderBounds: navigating ? CGRect(x: 100, y: 100, width: 300, height: 100) : nil,
                pathTextFieldElement: navigating ? element : nil, selectedFileURLs: selected,
                primaryActionElement: element, primaryActionBounds: nil, primaryActionEnabled: true)
        }
        XCTAssertTrue(ComputerUseDefaultBrowserActionScope.candidateIsSelected(
            panel: panel(selected: [candidate]), candidateURL: candidate))
        XCTAssertFalse(ComputerUseDefaultBrowserActionScope.candidateIsSelected(
            panel: panel(selected: [URL(fileURLWithPath: "/tmp/Other.pptx")]), candidateURL: candidate))
        XCTAssertFalse(ComputerUseDefaultBrowserActionScope.candidateIsSelected(
            panel: panel(selected: [candidate, URL(fileURLWithPath: "/tmp/Other.pptx")]), candidateURL: candidate))
        XCTAssertFalse(ComputerUseDefaultBrowserActionScope.candidateIsSelected(
            panel: panel(selected: [candidate], navigating: true), candidateURL: candidate))
        XCTAssertFalse(ComputerUseDefaultBrowserActionScope.candidateIsSelected(
            panel: panel(selected: [candidate]), candidateURL: nil))
    }

    func testNativeFilePlannerTakesOverOnlyForAnObservedUnselectedPicker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("alpha".utf8).write(to: downloads.appendingPathComponent("Alpha.pdf"))
        try Data("bravo".utf8).write(to: downloads.appendingPathComponent("Bravo.pdf"))
        let state = DefaultBrowserFixtureState()
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true },
            approvalTargetProvider: { _ in .init(context: "fixture", applicationID: state.app.bundleIdentifier,
                accessibilityIdentity: "fixture-window") },
            actionPerformer: { action in
                guard case .key(let usage, let modifiers) = action, usage == 0x11, modifiers == 8 else {
                    throw ComputerUseDefaultBrowserSession.Failure.interrupted
                }
                state.inputCount += 1
                let created = DefaultBrowserFixtureState.window("created", pid: 91, hash: 2, app: state.app)
                state.windows.append(created); state.focusedID = created.id
            }, screenProvider: {
                .init(image: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480)),
                    displayBounds: CGRect(x: 0, y: 0, width: 640, height: 480),
                    frontmostWindowBounds: CGRect(x: 0, y: 0, width: 640, height: 480))
            }, authenticationContextProvider: { nil }, screenCaptureConsentContextProvider: { nil },
            frontmostApplicationIdentityProvider: { state.app }, frontmostApplicationProvider: { "Browser" })
        let session = try state.session(root.appendingPathComponent("session"))
        let taskID = "native-file-choice-\(UUID().uuidString)", goal = "Supply one of these files to the open page."
        let window = try await session.ensure(taskID: taskID, goal: goal, tools: tools)
        let panelElement = AXUIElementCreateApplication(201)
        state.fileOpenPanel = .init(parentWindowID: window.id, parentWindowElement: window.accessibilityElement,
            accessibilityElement: panelElement, bounds: CGRect(x: 20, y: 20, width: 600, height: 400),
            isFocused: true, goToFolderBounds: nil, pathTextFieldElement: nil, selectedFileURLs: [],
            primaryActionElement: panelElement, primaryActionBounds: CGRect(x: 500, y: 360, width: 80, height: 30),
            primaryActionEnabled: false)
        var visualCalls = 0, nativeCalls = 0
        let preparedPicker = state.fileOpenPanel
        state.fileOpenPanel = nil
        let executor = try ComputerUseDefaultBrowserExecutor(journalDirectory: root.appendingPathComponent("executor"),
            session: session, propose: { input in
                visualCalls += 1
                XCTAssertNil(state.fileOpenPanel, "Native planner takes over once the picker opens")
                XCTAssertEqual(input.goal, goal)
                XCTAssertEqual(input.localFileCatalog?.inventoryState, .notQueried,
                    "Advertise host file selection before the browser model chooses its next step")
                XCTAssertNil(input.selectedLocalFilePath)
                XCTAssertNil(input.nativeOpenPanelSelection, "No current panel means no current chooser-selection observation")
                return .init(response: "", decision: .handoff("Open the website's file chooser."))
            }, nativeFilePlanner: { input in
                nativeCalls += 1
                XCTAssertEqual(input.goal, goal)
                XCTAssertEqual(input.surface, .desktop)
                XCTAssertNil(input.selectedLocalFilePath)
                if nativeCalls == 1 {
                    return .init(kind: .localFileOperation, reference: "", text: "", localFileOperation: .listFiles(query: .init(), cursor: nil))
                }
                let ids = try XCTUnwrap(input.localFileCatalog?.page.candidates.map(\.id))
                return .init(kind: .localFileOperation, reference: "", text: "", localFileOperation: .askFile(question: "Which file?", candidateIDs: ids))
            }, localFileCatalogFactory: { id in
                try ComputerUseLocalFileCatalog(taskID: id, approvedDirectory: downloads)
            })
        _ = try await executor.execute(taskID: taskID, prompt: goal, trustedUserPrompt: goal,
            tools: tools, progress: { _ in })
        XCTAssertEqual(nativeCalls, 0)
        state.fileOpenPanel = preparedPicker
        let result = try await executor.execute(taskID: taskID, prompt: goal, trustedUserPrompt: goal,
            tools: tools, progress: { _ in })
        guard case .clarificationRequired = result else { return XCTFail("Expected host-owned file choices") }
        XCTAssertEqual(nativeCalls, 2)
        XCTAssertEqual(visualCalls, 1)
        XCTAssertEqual(state.inputCount, 1, "File catalog and clarification require no native input")
    }

    func testNativeFilePickerUsesResolvedPathAndStopsBeforeUpload() {
        let element = AXUIElementCreateSystemWide()
        let candidate = URL(fileURLWithPath: "/tmp/Chosen résumé.pdf")
        func panel(navigating: Bool = true, selected: [URL] = []) -> ComputerUseDefaultBrowserSession.FileOpenPanel {
            .init(parentWindowID: "window", parentWindowElement: element, accessibilityElement: element,
                bounds: CGRect(x: 0, y: 0, width: 800, height: 600), isFocused: true,
                goToFolderBounds: navigating ? CGRect(x: 100, y: 100, width: 400, height: 200) : nil,
                pathTextFieldElement: navigating ? element : nil, selectedFileURLs: selected,
                primaryActionElement: element, primaryActionBounds: CGRect(x: 700, y: 560, width: 80, height: 30),
                primaryActionEnabled: true)
        }
        func next(_ panel: ComputerUseDefaultBrowserSession.FileOpenPanel) -> ComputerUseDesktopProposal? {
            ComputerUseDefaultBrowserActionScope.nativeSelectionProposal(panel: panel, selectedURL: candidate)
        }
        XCTAssertEqual(next(panel(navigating: false))?.action, .key(["Command", "Shift", "g"]))
        var current = panel()
        current.pathFieldIsFocused = true
        current.pathFieldValue = "/tmp/old.pdf"
        current.pathFieldSelection = NSRange(location: 0, length: 0)
        XCTAssertEqual(next(current)?.action, .key(["Command", "a"]))
        current.pathFieldSelection = NSRange(location: 0, length: current.pathFieldValue!.utf16.count)
        XCTAssertEqual(next(current)?.action, .typeText(candidate.path))
        current.pathFieldValue = candidate.path
        current.pathFieldSelection = NSRange(location: candidate.path.utf16.count, length: 0)
        XCTAssertEqual(next(current)?.action, .key(["Return"]))
        current.pathFieldIsFocused = false
        guard case .handoff? = next(current)?.decision else { return XCTFail("Wrong path-field focus must yield") }
        XCTAssertFalse(ComputerUseDefaultBrowserActionScope.permitsFilePanel(.key(usage: 0x28, modifiers: 0),
            within: current.actionBounds, panel: current, selectedURL: candidate))
        XCTAssertNil(next(panel(navigating: false, selected: [candidate])), "The native path adapter never presses Upload")
        XCTAssertEqual(next(panel(navigating: false, selected: [URL(fileURLWithPath: "/tmp/other.pdf")]))?.action,
            .key(["Command", "Shift", "g"]))
    }

    private typealias DocumentRequirement = ComputerUseMCPDocumentProposal.Requirement
    private func compileDocument(_ prompt: String, original: String, requirements: [DocumentRequirement],
        application: String = "Editor", document: String = "Notes.txt") throws -> ComputerUseMCPDocumentEdit? {
        try ComputerUseMCPDocumentEdit.compile(.init(application: application, document: document, requirements: requirements),
            prompt: prompt, application: "Editor", document: "Notes.txt", original: original)
    }

    func testMCPDocumentCompilationPreservesBytesAcrossDifferentTasks() throws {
        let prompt = "Change \"draft\" to \"ready\". Preserve everything else. Save."
        let task = try ComputerUseTextPayloadCatalog(prompt).projectedTask
        let sources = task.components(separatedBy: ". ")
        let result = try compileDocument(prompt, original: "Title\r\nStatus: draft\r\n\r\n", requirements: [
            .init(source: sources[0] + ".", operation: .replaceLiteral, find: "p1", value: "p2"),
            .init(source: sources[1] + ".", operation: .preserveOtherText, find: "", value: ""),
            .init(source: sources[2], operation: .save, find: "", value: "")])
        XCTAssertEqual(result, .init(expected: "Title\r\nStatus: ready\r\n\r\n", save: true))
        let append = "Append \"Done.\" and keep the document open."
        let projected = try ComputerUseTextPayloadCatalog(append).projectedTask
        let split = try XCTUnwrap(projected.range(of: " and "))
        let appended = try compileDocument(append, original: "Notes\n", requirements: [
            .init(source: String(projected[..<split.lowerBound]), operation: .append, find: "", value: "p1"),
            .init(source: String(projected[split.lowerBound...]), operation: .keepWindowOpen, find: "", value: "")])
        XCTAssertEqual(appended, .init(expected: "Notes\nDone.", save: false))
    }

    func testMCPDocumentCompilationRequiresCompleteTaskAndExactTarget() throws {
        let prompt = "Replace red with blue, then print it."
        let edit = DocumentRequirement(source: "Replace red with blue,", operation: .replaceLiteral, find: "red", value: "blue")
        XCTAssertNil(try compileDocument(prompt, original: "red", requirements: [edit]))
        XCTAssertNil(try compileDocument(prompt, original: "red", requirements: [edit,
            .init(source: "then print it.", operation: .unsupported, find: "", value: "")]))
        let simple = "Replace red with blue."
        let requirement = DocumentRequirement(source: simple, operation: .replaceLiteral, find: "red", value: "blue")
        XCTAssertNil(try compileDocument(simple, original: "red", requirements: [requirement], application: "Another App"))
        XCTAssertNil(try compileDocument(simple, original: "red", requirements: [requirement], document: "Other.txt"))
    }

    func testMCPDocumentCompilationRejectsAmbiguousOrMissingLiteral() throws {
        let prompt = "Replace red with blue."
        let item = DocumentRequirement(source: prompt, operation: .replaceLiteral, find: "red", value: "blue")
        for original in ["red red", "green", ""] {
            XCTAssertNil(try compileDocument(prompt, original: original, requirements: [item]), original)
        }
        let every = "Replace every red with blue."
        XCTAssertEqual(try compileDocument(every, original: "red/red\n", requirements: [
            .init(source: every, operation: .replaceEveryLiteral, find: "red", value: "blue")]),
            .init(expected: "blue/blue\n", save: false))
    }

    func testMCPDocumentCompilationRetainsUnicodeDistinctnessAndDeletion() throws {
        let prompt = "Replace \"é\" with \"東京 👩🏽‍💻\"."
        let projected = try ComputerUseTextPayloadCatalog(prompt).projectedTask
        let item = DocumentRequirement(source: projected, operation: .replaceLiteral, find: "p1", value: "p2")
        let result = try XCTUnwrap(compileDocument(prompt, original: "é/e\u{301}\n", requirements: [item]))
        XCTAssertEqual(Data(result.expected.utf8), Data("東京 👩🏽‍💻/e\u{301}\n".utf8))
        XCTAssertNil(try compileDocument(prompt, original: "e\u{301}", requirements: [item]))
        let deletion = "Replace \"old\" with \"\"."
        XCTAssertEqual(try compileDocument(deletion, original: "[old]\n", requirements: [
            .init(source: try ComputerUseTextPayloadCatalog(deletion).projectedTask, operation: .replaceLiteral,
                find: "p1", value: "p2")]), .init(expected: "[]\n", save: false))
    }

    func testMCPDocumentCompilationRejectsOverlappingLiteralMatches() throws {
        let prompt = "Replace aa with b."
        XCTAssertNil(try compileDocument(prompt, original: "aaa", requirements: [
            .init(source: prompt, operation: .replaceLiteral, find: "aa", value: "b")]))
        let every = "Replace every aa with b."
        XCTAssertNil(try compileDocument(every, original: "aaa", requirements: [
            .init(source: every, operation: .replaceEveryLiteral, find: "aa", value: "b")]))
    }

    func testMCPDocumentCompilationRejectsUnboundPayloadAndConflictingOrder() throws {
        let prompt = "Replace red with blue."
        XCTAssertNil(try compileDocument(prompt, original: "red", requirements: [
            .init(source: prompt, operation: .replaceLiteral, find: "red", value: "invented")]))
        let ordered = "Save, then replace red with blue."
        XCTAssertNil(try compileDocument(ordered, original: "red", requirements: [
            .init(source: "Save,", operation: .save, find: "", value: ""),
            .init(source: "then replace red with blue.", operation: .replaceLiteral, find: "red", value: "blue")]))
        let conflict = "Replace the entire document with blue. Keep all other text unchanged."
        XCTAssertNil(try compileDocument(conflict, original: "red", requirements: [
            .init(source: "Replace the entire document with blue.", operation: .replaceAll, find: "", value: "blue"),
            .init(source: "Keep all other text unchanged.", operation: .preserveOtherText, find: "", value: "")]))
        let append = "Append x."
        XCTAssertNil(try compileDocument(append, original: String(repeating: "a", count: 16_384), requirements: [
            .init(source: append, operation: .append, find: "", value: "x")]))
    }

    func testMCPPlainDocumentReadRejectsRichAndOversizedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plain = directory.appendingPathComponent("Notes.txt"), rich = directory.appendingPathComponent("Notes.rtf")
        let data = Data("Exact UTF-8 → 東京\r\n".utf8)
        try data.write(to: plain); try Data("{\\rtf1 Hello}".utf8).write(to: rich)
        XCTAssertEqual(try ComputerUseMCPPlainDocument.read(plain), data)
        XCTAssertThrowsError(try ComputerUseMCPPlainDocument.read(rich))
        try Data(repeating: 65, count: 16_385).write(to: plain)
        XCTAssertThrowsError(try ComputerUseMCPPlainDocument.read(plain))
        XCTAssertThrowsError(try ComputerUseMCPPlainDocument.read(directory))
    }

    func testMCPDocumentSourceRangesPreserveEveryByteAndRejectOmissions() throws {
        for task in ["Append [exact quoted payload p1] to the current document, save it, and leave it open.",
            "In the document, replace Seattle with Zürich → 東京. Keep all other text and line breaks unchanged, save the document, and leave its window open.",
            "Replace v1.2 with v2.0; then save.\n", "Append Tom and Jerry, Inc. to the document. Save it."] {
            let sources = try ComputerUseMCPDocumentSources(projectedTask: task)
            XCTAssertEqual(Data(sources.segments.joined().utf8), Data(task.utf8))
            XCTAssertEqual(try sources.resolve([(1, sources.segments.count)]), [task])
            XCTAssertThrowsError(try sources.resolve([(2, sources.segments.count)]))
            XCTAssertThrowsError(try sources.resolve([(1, sources.segments.count), (sources.segments.count, sources.segments.count)]))
            XCTAssertThrowsError(try sources.resolve([(0, sources.segments.count)]))
            XCTAssertThrowsError(try sources.resolve([(1, sources.segments.count + 1)]))
            XCTAssertThrowsError(try sources.resolve([]))
        }
        let prompt = "Append \"A, B and C.\" to the document."
        let projected = try ComputerUseTextPayloadCatalog(prompt).projectedTask
        XCTAssertEqual(try compileDocument(prompt, original: "", requirements: [
            .init(source: projected, operation: .append, find: "", value: "[exact quoted payload p1]")]),
            .init(expected: "A, B and C.", save: false))
    }

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

    func testOptInManagedHoloScrollsANativeDocumentAndJoinsItsWorker() async throws {
        guard ProcessInfo.processInfo.environment["RUN_MANAGED_HOLO_DESKTOP_ACCEPTANCE"] == "1" else { throw XCTSkip("Opt-in managed Holo with explicit diagnostic 5 GiB worker cap") }
        try await runNativeScrollFixture(useHolo: true, managedHolo: true)
    }

    func testOptInHoloPackageLoaderRunsTheNativeDocumentTask() async throws {
        guard ProcessInfo.processInfo.environment["RUN_HOLO_PACKAGE_ACCEPTANCE"] == "1" else { throw XCTSkip("Opt-in verified Holo package activation and native execution with diagnostic 5 GiB worker cap") }
        try await runNativeScrollFixture(useHolo: true, managedHolo: true, loadedHolo: true)
    }

    func testOptInRealTextEditEditsAndSavesUnicodeWithoutReplay() async throws {
        try await runRealTextEditTask(actualModel: false)
    }

    func testOptInRealTextEditMeasuresBackgroundAndIndependentWindowPixels() async throws {
        try await runRealTextEditTask(actualModel: false, captureOnly: true)
    }

    func testOptInRealTextEditReadUsesMCPBeforeModelFallback() async throws {
        try await runRealTextEditTask(actualModel: false, mcpReadOnly: true)
    }

    func testOptInRealTextEditMCPReadPreservesLongUnicodeAndSelection() async throws {
        let content = "Unicode notes\n" + String(repeating: "Zürich → 東京 👩🏽‍💻 e\u{301}\n", count: 70) + "End of document.\n"
        try await runRealTextEditTask(actualModel: false, mcpReadOnly: true, mcpReadText: content,
            mcpReadPrompt: "Show me all the contents in the current document.", mcpReadSelection: NSRange(location: 0, length: 7))
    }

    func testOptInRealTextEditMCPEditAndSaveCapability() async throws {
        try await runRealTextEditTask(actualModel: false, mcpWriteProbe: true)
    }

    func testOptInRealTextEditNaturalLanguageTaskUsesMCPThroughHostManager() async throws {
        try await runRealTextEditTask(actualModel: false, mcpHostTask: true)
    }

    func testOptInRealTextEditNaturalLanguageTaskUsesManagedHostSession() async throws {
        try await runRealTextEditTask(actualModel: false, managedHostSession: true)
    }

    func testOptInRealTextEditTaskResumesThroughHostMenu() async throws {
        try await runRealTextEditTask(actualModel: false, managedHostSession: true, managedMenuHandoff: true)
    }

    func testOptInRealTextEditMCPAppendAndSaveUsesCurrentDocument() async throws {
        try await runRealTextEditTask(actualModel: false, mcpHostTask: true, mcpTask: (
            prompt: "Append \"Approved by the team.\" to the current document, save it, and leave it open.",
            original: "Release notes\n\n", expected: "Release notes\n\nApproved by the team."))
    }

    func testOptInRealTextEditMCPRejectsAnEditChangedDuringApproval() async throws {
        try await runRealTextEditTask(actualModel: false, mcpHostTask: true, rejectStaleMCPEdit: true)
    }

    func testOptInRealTextEditMCPResumesBeforeFirstApproval() async throws {
        try await runRealTextEditTask(actualModel: false, mcpHostTask: true, mcpHandoffBeforeTool: "set_element_attribute")
    }

    func testOptInRealTextEditMCPResumesBetweenEditAndSave() async throws {
        try await runRealTextEditTask(actualModel: false, mcpHostTask: true, mcpHandoffBeforeTool: "press_key")
    }

    func testOptInRealTextEditMCPPreservesChangesDuringHandoffBeforeEdit() async throws {
        try await runRealTextEditTask(actualModel: false, mcpHostTask: true,
            mcpHandoffBeforeTool: "set_element_attribute", mcpChangeDuringHandoff: true)
    }

    func testOptInRealTextEditMCPPreservesChangesDuringHandoffBeforeSave() async throws {
        try await runRealTextEditTask(actualModel: false, mcpHostTask: true,
            mcpHandoffBeforeTool: "press_key", mcpChangeDuringHandoff: true)
    }

    func testOptInHoloEditsAndSavesUnicodeInRealTextEdit() async throws {
        guard ProcessInfo.processInfo.environment["RUN_HOLO_TEXTEDIT_ACCEPTANCE"] == "1" else { throw XCTSkip("Opt-in Holo in real TextEdit") }
        try await runRealTextEditTask(actualModel: true)
    }

    private func runRealTextEditTask(actualModel: Bool, captureOnly: Bool = false, mcpReadOnly: Bool = false,
        mcpReadText: String? = nil, mcpReadPrompt: String? = nil, mcpReadSelection: NSRange? = nil,
        mcpWriteProbe: Bool = false, mcpHostTask: Bool = false, managedHostSession: Bool = false, managedMenuHandoff: Bool = false,
        mcpTask: (prompt: String, original: String, expected: String)? = nil, rejectStaleMCPEdit: Bool = false,
        mcpHandoffBeforeTool: String? = nil, mcpChangeDuringHandoff: Bool = false) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_REAL_TEXTEDIT_ACCEPTANCE"] == "1" else { throw XCTSkip("Opt-in real TextEdit with a disposable document") }
        guard AXIsProcessTrusted() else { return XCTFail("Accessibility permission is required") }
        let inputs = actualModel ? try await Self.managedHoloInputs(environment) : nil
        let output = URL(fileURLWithPath: try XCTUnwrap(environment["NATIVE_TEXTEDIT_TRIAL_DIRECTORY"]))
        guard !FileManager.default.fileExists(atPath: output.path) else { throw OSAtlasLlamaRuntimeError.invalidLocalInstallation }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeTextEdit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let document = directory.appendingPathComponent("Travel notes.txt")
        let original = mcpTask?.original ?? mcpReadText ?? "Meeting notes\nRoute: Seattle\nStatus: draft\n"
        let expected = mcpTask?.expected ?? "Meeting notes\nRoute: Zürich → 東京\nStatus: draft\n"
        let goal = mcpTask?.prompt ?? "In the open TextEdit document, replace Seattle with Zürich → 東京. Keep all other text and line breaks unchanged, save the document, and leave its window open."
        try Data(original.utf8).write(to: document, options: .withoutOverwriting)
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousInstances = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").map(\.processIdentifier))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true; configuration.activates = true
        configuration.addsToRecentItems = false; configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        let app = try await NSWorkspace.shared.open([document], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: configuration)
        guard !previousInstances.contains(app.processIdentifier) else { return XCTFail("TextEdit did not create an isolated application instance") }
        // Cleanup is restricted to the new instance and our own document.
        defer {
            if !app.isTerminated { app.forceTerminate() }
            previousApp?.activate(options: [])
            if app.isTerminated { try? FileManager.default.removeItem(at: directory) }
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.1)
        func ownsDocument() -> Bool {
            guard !app.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
            let window = unsafeBitCast(value, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(window, 0.1)
            var identity: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &identity) == .success,
                  let raw = identity as? String, let url = URL(string: raw) else { return false }
            return url.standardizedFileURL.resolvingSymlinksInPath() == document.standardizedFileURL.resolvingSymlinksInPath()
        }
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: ownsDocument)
        let launcher = ManagedHoloTestLauncher(), runtime = OSAtlasLlamaRuntime(launcher: launcher)
        var result: ComputerUseExecutionResult?, failure: Error?, executor: ComputerUseDesktopExecutor?
        var scriptCalls = 0, activationSeconds: TimeInterval = 0
        var approvedSaves = 0, approvedEditorClicks = 0, saveEffects = 0, editorClickEffects = 0, rejectedApprovalReplays = 0
        var approvalRequests: [[String: String]] = []
        let started = Date()
        var memory: Task<(UInt64, Int), Never>?
        do {
            for _ in 0..<100 { if ownsDocument() { break }; try await Task.sleep(for: .milliseconds(50)) }
            guard ownsDocument() else { throw NativeTextFixtureFailure.unexpectedOutcome("The new TextEdit instance did not expose the disposable document") }
            if managedHostSession {
                try await runManagedTextEditHostSession(tools: tools, app: app, goal: goal,
                    expected: expected, document: document, output: output, menuHandoff: managedMenuHandoff)
                return
            }
            if mcpHostTask {
                try await runTextEditMCPHostTask(tools: tools, app: app, goal: goal, expected: expected,
                    document: document, output: output, rejectStaleEdit: rejectStaleMCPEdit, handoffBeforeTool: mcpHandoffBeforeTool,
                    changeDuringHandoff: mcpChangeDuringHandoff)
                return
            }
            if mcpWriteProbe {
                try await probeTextEditMCPWrite(tools: tools, app: app, original: original, expected: expected,
                    document: document, output: output)
                return
            }
            if mcpReadOnly {
                if let mcpReadSelection {
                    var focused: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                          let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { throw NativeTextFixtureFailure.unexpectedOutcome("Missing owned editor") }
                    var range = CFRange(location: mcpReadSelection.location, length: mcpReadSelection.length)
                    let axRange = try XCTUnwrap(AXValueCreate(.cfRange, &range))
                    XCTAssertEqual(AXUIElementSetAttributeValue(unsafeBitCast(focused, to: AXUIElement.self), kAXSelectedTextRangeAttribute as CFString, axRange), .success)
                }
                try await readTextEditUsingMacTools(tools: tools, app: app, original: original, document: document, output: output, prompt: mcpReadPrompt)
                return
            }
            let initialEditor = try XCTUnwrap(tools.nativeFocusedEditorObservation())
            XCTAssertEqual(initialEditor.textState?.valuePrefix, original, "TextEdit must observe the complete independent starting document")
            let initialFrame = try XCTUnwrap(tools.nativeFocusedTextFrame())
            let editorPoint = ComputerUsePredictedAction.click(x: Int(initialFrame.midX), y: Int(initialFrame.midY), button: 1, count: 1)
            XCTAssertEqual(try tools.nativePointerTargetFrame(for: editorPoint), initialFrame,
                "An editor's unlabeled AX geometry must remain available for native pointer validation")
            if captureOnly {
                try await measureTextEditBackground(tools: tools, app: app, editorFrame: initialFrame,
                    original: original, document: document, output: output)
                return
            }
            if let inputs {
                let manifest = ComputerUseArtifactManifest.holo31
                let loader = OSAtlasVisualExecutorLoader(resolver: .init(manifest: manifest), runtime: runtime,
                    nativeJournalDirectory: output.appendingPathComponent("journals"))
                let activation = Date()
                executor = try await loader.load(receipt: .init(installationVersion: manifest.installationVersion,
                    modelVariant: manifest.modelVariant, modelDirectory: inputs.modelURL.deletingLastPathComponent().path, installedAt: Date()), progress: { _ in }) as? ComputerUseDesktopExecutor
                activationSeconds = Date().timeIntervalSince(activation)
                memory = Task.detached {
                    var peak: UInt64 = 0, samples = 0
                    while !Task.isCancelled {
                        for process in (try? DarwinOSAtlasProcessInspector().matchingProcesses(for: inputs.llamaServerURL)) ?? [] {
                            if let bytes = OSAtlasProcessMemoryGuard.residentBytes(processID: process.processIdentifier) { peak = max(peak, bytes); samples += 1 }
                        }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    return (peak, samples)
                }
            } else {
                let display = try tools.currentScreen().displayBounds
                executor = try ComputerUseDesktopExecutor(journalDirectory: output.appendingPathComponent("journals"), propose: { input in
                    // A Save may repaint its title/text while completion is
                    // being checked. Reconsider only completion on fresh
                    // evidence; never replay an input to handle that repaint.
                    guard input.actionError == nil || scriptCalls >= 5 else { throw ComputerUseDesktopExecutor.Failure.changedScreen }
                    defer { scriptCalls += 1 }
                    let action: ComputerUseFaraAction
                    switch scriptCalls {
                    case 0:
                        try await Task.sleep(for: .seconds(1))
                        action = .pointer(.leftClick, .init(x: (initialFrame.midX - display.minX) / display.width * 1000,
                            y: (initialFrame.midY - display.minY) / display.height * 1000))
                    case 1: action = .key(["Command", "a"])
                    case 2: action = .typeText(expected)
                    case 3: action = .key(["Command", "s"])
                    case 4...6:
                        guard input.focusedTextState?.valuePrefix == expected else { throw ComputerUseDesktopExecutor.Failure.changedScreen }
                        action = .reportCompletion("Updated the route and saved the document.")
                    default: throw ComputerUseDesktopExecutor.Failure.stepLimit
                    }
                    return .init(response: "scripted native operation \(scriptCalls)", action: action)
                })
            }
            let executor = try XCTUnwrap(executor)
            let run = Task {
                var outcome = try await executor.execute(taskID: "real-textedit", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
                while case .approvalRequired(let message, let action, let continuation) = outcome {
                    result = outcome
                    approvalRequests.append(["message": message, "action": String(describing: action)])
                    // This task authorizes editing/saving only our disposable document.
                    // Exercise the real approval continuation without relaxing
                    // the policy or admitting unrelated desktop effects.
                    guard ownsDocument() else { throw ComputerUseDesktopExecutor.Failure.changedScreen }
                    let isSave = action == (try ComputerUseNativeKeyChord.action(["Command", "s"]))
                    if isSave {
                        guard approvedSaves == 0 else { throw NativeTextFixtureFailure.unexpectedOutcome("The test permits one approved Save") }
                    } else {
                        guard approvedEditorClicks < 3,
                              case .click(let x, let y, 1, 1) = action,
                              let frame = try tools.nativePointerTargetFrame(for: action), frame == initialFrame,
                              frame.contains(CGPoint(x: x, y: y)) else {
                            throw NativeTextFixtureFailure.unexpectedOutcome("The test authorizes only Save or bounded single clicks inside its own current editor")
                        }
                    }
                    let fingerprint = try tools.prepareNativeActionFingerprint(for: action)
                    try await executor.performApprovedVisualAction(continuation, action: action, fingerprint: fingerprint,
                        tools: tools, willBeginEffect: { if isSave { saveEffects += 1 } else { editorClickEffects += 1 } })
                    if isSave { approvedSaves += 1 } else { approvedEditorClicks += 1 }
                    do {
                        try await executor.performApprovedVisualAction(continuation, action: action, fingerprint: fingerprint,
                            tools: tools, willBeginEffect: { if isSave { saveEffects += 1 } else { editorClickEffects += 1 } })
                    } catch ComputerUseDesktopExecutor.Failure.invalidApproval { rejectedApprovalReplays += 1 }
                    guard rejectedApprovalReplays == approvedSaves + approvedEditorClicks,
                          saveEffects == approvedSaves, editorClickEffects == approvedEditorClicks else {
                        throw NativeTextFixtureFailure.unexpectedOutcome("The approved action replay was not rejected before effects")
                    }
                    outcome = try await executor.continueAfterApprovedVisualAction(continuation, action: action, tools: tools, progress: { _ in })
                }
                return outcome
            }
            let deadline = Task { try await Task.sleep(for: .seconds(actualModel ? 120 : 30)); run.cancel() }
            do { result = try await run.value } catch { failure = error }
            deadline.cancel()
            if case .completed = result {
                let count = executor.diagnosticHistory.count, beforeReplay = try Data(contentsOf: document)
                let replay = try await executor.execute(taskID: "real-textedit", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in })
                XCTAssertEqual(replay, result); XCTAssertEqual(executor.diagnosticHistory.count, count)
                XCTAssertEqual(try Data(contentsOf: document), beforeReplay)
            }
        } catch { failure = error }
        await runtime.shutdown(); memory?.cancel()
        let measured = await memory?.value
        let saved = try Data(contentsOf: document)
        try saved.write(to: output.appendingPathComponent("saved-document.txt"), options: .withoutOverwriting)
        let openAtReturn = ownsDocument()
        let stop = await runtime.lastWorkerStop
        let exited = try inputs.map { try DarwinOSAtlasProcessInspector().matchingProcesses(for: $0.llamaServerURL).isEmpty } ?? true
        var report: [String: Any] = ["scope": actualModel ? "Holo-package-loader-real-TextEdit" : "scripted-real-TextEdit", "goal": goal,
            "original": original, "expected": expected, "savedUTF8": String(data: saved, encoding: .utf8) as Any? ?? NSNull(),
            "savedBytesMatch": saved == Data(expected.utf8), "result": result.map { String(describing: $0) } ?? "",
            "failure": failure.map { String(reflecting: $0) } ?? "", "elapsedSeconds": Date().timeIntervalSince(started),
            "loaderActivationSeconds": activationSeconds, "documentOpenAndFrontmostAtReturn": openAtReturn,
            "scriptCalls": scriptCalls, "approvedSaves": approvedSaves, "saveEffects": saveEffects,
            "approvedEditorClicks": approvedEditorClicks, "editorClickEffects": editorClickEffects,
            "approvalRequests": approvalRequests,
            "rejectedApprovalReplays": rejectedApprovalReplays, "supportedApproval": "One Command-S and at most three single clicks inside the disposable document's current editor",
            "revalidation": executor?.lastRevalidationDiagnostic ?? [:],
            "approvalValidation": executor?.lastApprovalDiagnostic ?? [:],
            "responses": executor?.diagnosticHistory.map { ["response": $0.response, "actionError": $0.actionError ?? "",
                "screenshotSHA256": SHA256.hash(data: $0.screenshotPNG).map { String(format: "%02x", $0) }.joined()] } ?? [],
            "managedLaunchCount": launcher.credentialDirectories.count, "ownedWorkersExited": exited,
            "credentialsRemoved": launcher.credentialDirectories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
            "peakWorkerMemoryBytes": measured?.0 ?? 0, "memorySamples": measured?.1 ?? 0,
            "memorySamplingStartsAfterLoaderActivation": true, "diagnosticWorkerLimitGiB": actualModel ? 5 : 0,
            "wholeApp12GBQualified": false]
        if let stop { report["workerStop"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stop)) }
        if openAtReturn, let screen = try? tools.currentScreen() {
            let prepared = try ComputerUseDesktopImage(observation: screen)
            let shot = XCTAttachment(data: prepared.png, uniformTypeIdentifier: "public.png")
            shot.name = "Real TextEdit final screen"; shot.lifetime = .keepAlways; add(shot)
            if let bounds = screen.frontmostWindowBounds { report["finalNativeWindow"] = try tools.nativeControlObservation(displayBounds: screen.displayBounds, windowBounds: bounds)?.window?.jsonObject as Any? ?? NSNull() }
        }
        app.forceTerminate()
        for _ in 0..<60 { if app.isTerminated { break }; try await Task.sleep(for: .milliseconds(50)) }
        report["ownedTextEditExited"] = app.isTerminated
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("workflow.json"), options: .withoutOverwriting)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Real TextEdit workflow"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(app.isTerminated); XCTAssertTrue(exited); XCTAssertTrue(openAtReturn)
        if let failure { return XCTFail("Real TextEdit task failed: \(failure)") }
        guard case .completed = result else { return XCTFail("Real TextEdit task did not complete: \(String(describing: result))") }
        XCTAssertEqual(saved, Data(expected.utf8), "The saved file is the independent completion oracle")
        if actualModel { XCTAssertEqual(launcher.credentialDirectories.count, 2 + approvedSaves + approvedEditorClicks); XCTAssertEqual(stop?.cleanupSucceeded, true) }
        else { XCTAssertTrue((5...7).contains(scriptCalls)); XCTAssertEqual(approvedSaves, 1); XCTAssertEqual(approvedEditorClicks, 1) }
        XCTAssertEqual(saveEffects, approvedSaves); XCTAssertEqual(editorClickEffects, approvedEditorClicks)
        XCTAssertEqual(rejectedApprovalReplays, approvedSaves + approvedEditorClicks)
    }

    private func runManagedTextEditHostSession(tools: ComputerUseHostTools, app: NSRunningApplication,
        goal: String, expected: String, document: URL, output: URL, menuHandoff: Bool = false) async throws {
        let helperReceipt = await MacControlMCPInstaller().currentInstallation()
        let helper = try XCTUnwrap(helperReceipt, "Run the opt-in normal managed installation first")
        let native = ComputerUseInstaller.nativeText(), visual = ComputerUseInstaller()
        let nativeInterrupted = await native.interruptedInstallationExists()
        let visualInterrupted = await visual.interruptedInstallationExists()
        guard !nativeInterrupted, !visualInterrupted else {
            throw XCTSkip("No-inference acceptance cannot resume an incomplete model installation")
        }
        let runtime = try OSAtlasVisualExecutorLoader.bundledRuntimeDirectoryURL(in: .main).appendingPathComponent("llama-server")
        let inspector = DarwinOSAtlasProcessInspector()
        XCTAssertTrue(try inspector.matchingProcesses(for: runtime).isEmpty)
        let ledger = ComputerUseTaskLedger(fileURL: output.appendingPathComponent("host-ledger.json"))
        let session = HostSession(computerUseTaskLedger: ledger, allowsExternalComputerUseServices: true)
        let host = session.computerUse, channel = NativeMCPTaskChannel()
        let taskID = "managed-textedit-" + UUID().uuidString, started = Date()
        var samples = 0, maximumWorkers = 0
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                maximumWorkers = max(maximumWorkers, try inspector.matchingProcesses(for: runtime).count)
                samples += 1
                do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
            }
        }
        var failure: Error?, terminal: ComputerUseTaskUpdate?, approvals = Set<String>()
        var deliveredApprovals = 0, didMenuHandoff = false, menuRetainedNativeFocus = false
        var popoverNativeSnapshotReadable = false
        var editorExact = false, savedExact = false
        do {
            host.start(pairingCode: "123456", additionalChannels: [channel], includeDefaultChannel: false)
            for _ in 0..<300 {
                if host.capability.state == .ready { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard host.capability.state == .ready else {
                throw NativeTextFixtureFailure.unexpectedOutcome("Managed HostSession did not become ready")
            }
            host.authorizePeer(senderID: "TEXTEDIT-TEST")
            let request = ComputerUseEnvelope(id: taskID, senderID: "TEXTEDIT-TEST", targetID: "HOST-ID",
                pairingCode: "123456", sessionID: "TEXTEDIT-SESSION", kind: .prompt,
                body: try ComputerUsePromptRequest(prompt: goal, supportsApprovedActionEvidence: true).encodedBody())
            XCTAssertTrue(host.handle(request, channel: channel))
            let deadline = ContinuousClock.now.advanced(by: .seconds(menuHandoff ? 110 : 30))
            while ContinuousClock.now < deadline {
                let messages = await channel.messages()
                if let message = messages.last(where: { $0.kind == .assistant }) {
                    terminal = try ComputerUseTaskUpdate.decodeBody(message.body); break
                }
                for message in messages where message.kind == .approvalRequest {
                    let approval = try ComputerUseApprovalRequest.decodeBody(message.body)
                    guard approvals.insert(approval.requestID).inserted else { continue }
                    if menuHandoff && !didMenuHandoff {
                        let menu = HostMenuTestSurface(session: session, usesPopover: true)
                        defer { menu.close() }
                        try await menu.waitForControl("Take control") { host.activity == .paused }
                        popoverNativeSnapshotReadable = (try? tools.mcpFocusedTextSnapshot())?.isReadable == true
                        try await menu.waitForControl("Let AI continue") { host.activity != .paused }
                        didMenuHandoff = true
                        menuRetainedNativeFocus = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
                        continue
                    }
                    let detail = try XCTUnwrap(approval.details?.first { $0.label == "Exact local action" })
                    let arguments = try JSONDecoder().decode([String: MCPJSONValue].self, from: Data(detail.value.utf8))
                    let snapshot = try XCTUnwrap(tools.mcpFocusedTextSnapshot())
                    let edit = deliveredApprovals == 0 && arguments["name"] == .string("AXValue") && arguments["value"] == .string(expected)
                    let save = deliveredApprovals == 1 && arguments["key"] == .string("s")
                        && arguments["modifiers"] == .array([.string("command")])
                        && snapshot.text.value.utf8.elementsEqual(expected.utf8)
                    guard approval.taskID == taskID, edit || save,
                          snapshot.window.applicationProcessIdentifier == app.processIdentifier,
                          snapshot.documentIdentity.flatMap(URL.init(string:))?.standardizedFileURL == document.standardizedFileURL else {
                        throw NativeTextFixtureFailure.unexpectedOutcome("Managed approval left the owned edit/save experiment")
                    }
                    XCTAssertTrue(host.handle(ComputerUseEnvelope(senderID: request.senderID, targetID: request.targetID,
                        pairingCode: request.pairingCode, sessionID: request.sessionID, kind: .approvalResponse,
                        body: try ComputerUseApprovalResponse(requestID: approval.requestID, approved: true,
                            taskID: approval.taskID, appliedControlRevision: approval.appliedControlRevision,
                            hostControlEpoch: approval.hostControlEpoch).encodedBody()), channel: channel))
                    deliveredApprovals += 1
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            editorExact = try tools.mcpFocusedTextSnapshot()?.text.value.utf8.elementsEqual(expected.utf8) == true
            savedExact = try Data(contentsOf: document) == Data(expected.utf8)
        } catch { failure = error }
        await session.shutdown()
        monitor.cancel(); try await monitor.value
        let history = try ledger.approvedActionHistory(taskID: taskID, senderID: "TEXTEDIT-TEST", sessionID: "TEXTEDIT-SESSION")
        let messages = await channel.messages()
        let report: [String: Any] = ["scope": "real-TextEdit-managed-HostSession-default-installers-and-executors",
            "goal": goal, "elapsedSeconds": Date().timeIntervalSince(started), "failure": String(reflecting: failure),
            "terminalOutcome": terminal?.outcome?.rawValue as Any? ?? NSNull(), "approvalCount": approvals.count,
            "menuHandoff": menuHandoff, "didMenuHandoff": didMenuHandoff, "menuRetainedNativeFocus": menuRetainedNativeFocus,
            "popoverNativeSnapshotReadable": popoverNativeSnapshotReadable,
            "confirmedActionCount": history.filter { $0.response != nil }.count, "editorExact": editorExact, "savedFileExact": savedExact,
            "workerSamples": samples, "maximumObservedWorkerCount": maximumWorkers, "helperBinaryPath": helper.binaryPath,
            "isolatedDependencies": ["task ledger", "transport"],
            "messages": try JSONSerialization.jsonObject(with: JSONEncoder().encode(messages))]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("managed-host-session-result.json"), options: .withoutOverwriting)
        if let failure { throw failure }
        XCTAssertEqual(terminal?.outcome, .taskCompleted)
        XCTAssertTrue(editorExact); XCTAssertTrue(savedExact); XCTAssertFalse(app.isTerminated)
        XCTAssertEqual(approvals.count, menuHandoff ? 3 : 2); XCTAssertEqual(history.filter { $0.response != nil }.count, 2)
        if menuHandoff { XCTAssertTrue(didMenuHandoff); XCTAssertTrue(menuRetainedNativeFocus) }
        XCTAssertGreaterThan(samples, 0); XCTAssertEqual(maximumWorkers, 0)
        XCTAssertTrue(try inspector.matchingProcesses(for: runtime).isEmpty)
    }

    private func runTextEditMCPHostTask(tools: ComputerUseHostTools, app: NSRunningApplication,
        goal: String, expected: String, document: URL, output: URL, rejectStaleEdit: Bool = false,
        handoffBeforeTool: String? = nil, changeDuringHandoff: Bool = false) async throws {
        let started = Date(), taskID = "real-textedit-mcp-task"
        let helper = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["MAC_CONTROL_HELPER_PATH"]))
        let base = MCPClientPool(mutationLedger: MCPFileMutationCallLedger(fileURL: output.appendingPathComponent("mcp-mutations.json")),
            sessionFactory: { binary, generation in MCPClientSession(validatedBinary: binary, processGeneration: generation,
                stateDirectory: output.appendingPathComponent("helper-state")) })
        let pool = NativeMCPTaskObservedPool(base: base)
        let proposals = NativeMCPDocumentProposalLog()
        let channel = NativeMCPTaskChannel()
        let ledger = ComputerUseTaskLedger(fileURL: output.appendingPathComponent("host-ledger.json"))
        var fallbackCalls = 0, failure: Error?, terminal: ComputerUseTaskUpdate?
        var approvals = Set<String>(), manager: HostComputerUseManager?
        var savedExact = false, editorExact = false
        let externalEdit = "Edited independently during approval.\n"
        var externalEditPreserved = false
        var didHandoff = false, helperJoinedBeforeResume = false, staleApprovalIgnored = false
        var invalidatedResponse: ComputerUseEnvelope?, invalidatedCall: MCPToolCall?
        var staleApprovalAfterResumeIgnored = false
        var selectionChangedDuringHandoff = false
        do {
            let fallback = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in
                fallbackCalls += 1
                return .unableToComplete("Native document task reached model fallback")
            })
            let executor = try await MCPFirstComputerUseExecutor.load(binaryURL: helper, visualFallback: fallback,
                clientPool: pool, planningTimeout: 15, documentPlanner: .init(inspectProposal: { proposals.append($0) }))
            let host = HostComputerUseManager(injector: InputInjector(), executor: executor, taskLedger: ledger,
                allowsExternalServices: false, channelFactory: { _ in channel })
            manager = host
            host.authorizePeer(senderID: "TEXTEDIT-TEST")
            let request = ComputerUseEnvelope(id: taskID, senderID: "TEXTEDIT-TEST", targetID: "HOST-ID",
                pairingCode: "123456", sessionID: "TEXTEDIT-SESSION", kind: .prompt,
                body: try ComputerUsePromptRequest(prompt: goal, supportsApprovedActionEvidence: true).encodedBody())
            XCTAssertTrue(host.handle(request, channel: channel))
            let deadline = ContinuousClock.now.advanced(by: .seconds(25))
            while ContinuousClock.now < deadline {
                let messages = await channel.messages()
                if let message = messages.last(where: { $0.kind == .assistant }) {
                    terminal = try ComputerUseTaskUpdate.decodeBody(message.body)
                    break
                }
                for message in messages where message.kind == .approvalRequest {
                    let approval = try ComputerUseApprovalRequest.decodeBody(message.body)
                    guard approvals.insert(approval.requestID).inserted else { continue }
                    let pendingCall = await pool.latestPrepared()
                    let call = try XCTUnwrap(pendingCall)
                    let snapshot = try XCTUnwrap(tools.mcpFocusedTextSnapshot())
                    guard snapshot.window.applicationProcessIdentifier == app.processIdentifier,
                          snapshot.documentIdentity.flatMap(URL.init(string:))?.standardizedFileURL == document.standardizedFileURL else {
                        throw NativeTextFixtureFailure.unexpectedOutcome("Approval no longer targets the owned document")
                    }
                    let qualifiedEdit = call.toolName == "set_element_attribute" && call.arguments["name"] == .string("AXValue")
                        && call.arguments["value"] == .string(expected)
                    let qualifiedSave = call.toolName == "press_key" && call.arguments["key"] == .string("s")
                        && call.arguments["modifiers"] == .array([.string("command")])
                        && snapshot.text.value.utf8.elementsEqual(expected.utf8)
                    guard call.taskID == taskID, qualifiedEdit || qualifiedSave else {
                        throw NativeTextFixtureFailure.unexpectedOutcome("The proposed action is outside the qualified edit/save experiment")
                    }
                    if let oldResponse = invalidatedResponse, let oldCall = invalidatedCall {
                        let priorCalls = await pool.approvedCalls()
                        XCTAssertTrue(host.handle(oldResponse, channel: channel))
                        try await Task.sleep(for: .milliseconds(100))
                        let afterCalls = await pool.approvedCalls()
                        let current = try tools.mcpFocusedTextSnapshot()
                        staleApprovalAfterResumeIgnored = priorCalls == afterCalls && current == snapshot
                        guard staleApprovalAfterResumeIgnored, call.processGeneration != oldCall.processGeneration else {
                            throw NativeTextFixtureFailure.unexpectedOutcome("Resume reused an old approval or helper generation")
                        }
                        if oldCall.toolName == "press_key" {
                            XCTAssertEqual(call.canonicalDigest, oldCall.canonicalDigest)
                            XCTAssertEqual(call.stepEffectID, oldCall.stepEffectID)
                        }
                        invalidatedResponse = nil
                    }
                    if rejectStaleEdit {
                        guard qualifiedEdit, approvals.count == 1 else {
                            throw NativeTextFixtureFailure.unexpectedOutcome("A changed document must not receive another action")
                        }
                        guard AXUIElementSetAttributeValue(snapshot.focusedElement, kAXValueAttribute as CFString,
                            externalEdit as CFString) == .success else {
                            throw NativeTextFixtureFailure.unexpectedOutcome("The owned interference could not be installed")
                        }
                    }
                    let response = ComputerUseEnvelope(senderID: request.senderID, targetID: request.targetID,
                        pairingCode: request.pairingCode, sessionID: request.sessionID, kind: .approvalResponse,
                        body: try ComputerUseApprovalResponse(requestID: approval.requestID, approved: true,
                            taskID: approval.taskID, appliedControlRevision: approval.appliedControlRevision,
                            hostControlEpoch: approval.hostControlEpoch).encodedBody())
                    if call.toolName == handoffBeforeTool, !didHandoff {
                        didHandoff = true
                        let callsBefore = await pool.approvedCalls()
                        let cancellationsBefore = await pool.cancelledGenerations()
                        func control(_ kind: ComputerUseEnvelope.Kind, revision: UInt64) throws -> ComputerUseEnvelope {
                            .init(senderID: request.senderID, targetID: request.targetID,
                                pairingCode: request.pairingCode, sessionID: request.sessionID, kind: kind,
                                body: try ComputerUseControlRequest(taskID: taskID, revision: revision,
                                    observedHostControlEpoch: ledger.hostControlEpoch(taskID: taskID)).encodedBody())
                        }
                        XCTAssertTrue(host.handle(try control(.pause, revision: 1), channel: channel))
                        XCTAssertEqual(host.activity, .paused)
                        let joinDeadline = ContinuousClock.now.advanced(by: .seconds(3))
                        while ContinuousClock.now < joinDeadline {
                            if await pool.cancelledGenerations().count > cancellationsBefore.count { break }
                            try await Task.sleep(for: .milliseconds(25))
                        }
                        do { _ = try await pool.allowedTools() }
                        catch MCPClientError.notRunning { helperJoinedBeforeResume = true }
                        guard helperJoinedBeforeResume else {
                            throw NativeTextFixtureFailure.unexpectedOutcome("Take Control did not join the old helper")
                        }
                        if changeDuringHandoff {
                            guard AXUIElementSetAttributeValue(snapshot.focusedElement, kAXValueAttribute as CFString,
                                externalEdit as CFString) == .success else {
                                throw NativeTextFixtureFailure.unexpectedOutcome("The owned handoff edit could not be installed")
                            }
                        } else {
                            // Literal document edits and Save do not depend on
                            // the caret. Exercise a normal user selection change.
                            let selection = snapshot.text.selection == NSRange(location: 0, length: 3)
                                ? NSRange(location: 1, length: 2) : NSRange(location: 0, length: 3)
                            var range = CFRange(location: selection.location, length: selection.length)
                            guard let selected = AXValueCreate(.cfRange, &range),
                                  AXUIElementSetAttributeValue(snapshot.focusedElement,
                                    kAXSelectedTextRangeAttribute as CFString, selected) == .success else {
                                throw NativeTextFixtureFailure.unexpectedOutcome("The owned handoff selection could not be installed")
                            }
                            selectionChangedDuringHandoff = try tools.mcpFocusedTextSnapshot()?.text.selection == selection
                            guard selectionChangedDuringHandoff else {
                                throw NativeTextFixtureFailure.unexpectedOutcome("The owned handoff selection was not observed")
                            }
                        }
                        let ownedPausedSnapshot = try tools.mcpFocusedTextSnapshot()
                        // A late response to the invalidated approval cannot
                        // act while the user owns the document.
                        XCTAssertTrue(host.handle(response, channel: channel))
                        try await Task.sleep(for: .milliseconds(100))
                        let callsWhilePaused = await pool.approvedCalls()
                        let pausedSnapshot = try tools.mcpFocusedTextSnapshot()
                        staleApprovalIgnored = callsWhilePaused == callsBefore
                            && pausedSnapshot == ownedPausedSnapshot
                        guard staleApprovalIgnored else {
                            throw NativeTextFixtureFailure.unexpectedOutcome("The stale approval changed the owned document")
                        }
                        invalidatedResponse = response; invalidatedCall = call
                        XCTAssertTrue(host.handle(try control(.resume, revision: 2), channel: channel))
                        continue
                    }
                    XCTAssertTrue(host.handle(response, channel: channel))
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            editorExact = try tools.mcpFocusedTextSnapshot()?.text.value.utf8.elementsEqual(expected.utf8) == true
            savedExact = try Data(contentsOf: document) == Data(expected.utf8)
            externalEditPreserved = try tools.mcpFocusedTextSnapshot()?.text.value.utf8.elementsEqual(externalEdit.utf8) == true
        } catch { failure = error }
        if let manager { await manager.stop().value }
        await pool.cancelAll()
        let calls = await pool.approvedCalls()
        let effects = try JSONSerialization.jsonObject(with: JSONEncoder().encode(calls))
        let history = try? ledger.approvedActionHistory(taskID: taskID, senderID: "TEXTEDIT-TEST", sessionID: "TEXTEDIT-SESSION")
        let sentMessages = await channel.messages()
        let messages = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sentMessages))
        app.forceTerminate()
        for _ in 0..<60 { if app.isTerminated { break }; try await Task.sleep(for: .milliseconds(50)) }
        let report: [String: Any] = ["scope": "real-TextEdit-default-MCP-and-host-manager-natural-language-task",
            "goal": goal, "elapsedSeconds": Date().timeIntervalSince(started), "failure": String(reflecting: failure),
            "terminalOutcome": terminal?.outcome?.rawValue as Any? ?? NSNull(), "terminalText": terminal?.text as Any? ?? NSNull(),
            "fallbackCalls": fallbackCalls, "approvalCount": approvals.count, "approvedCalls": effects, "messages": messages,
            "documentProposals": proposals.values(),
            "staleEditExperiment": rejectStaleEdit, "externalEditPreserved": externalEditPreserved,
            "handoffBeforeTool": handoffBeforeTool as Any? ?? NSNull(), "didHandoff": didHandoff,
            "helperJoinedBeforeResume": helperJoinedBeforeResume, "staleApprovalIgnored": staleApprovalIgnored,
            "changeDuringHandoff": changeDuringHandoff, "staleApprovalAfterResumeIgnored": staleApprovalAfterResumeIgnored,
            "selectionChangedDuringHandoff": selectionChangedDuringHandoff,
            "confirmedActionCount": history?.filter { $0.response != nil }.count as Any? ?? NSNull(),
            "editorExact": editorExact, "savedFileExact": savedExact, "ownedTextEditExited": app.isTerminated]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("mcp-host-task-result.json"), options: .withoutOverwriting)
        XCTAssertTrue(app.isTerminated)
        if let failure { throw failure }
        if changeDuringHandoff {
            let priorEffects = handoffBeforeTool == "press_key" ? 1 : 0
            XCTAssertEqual(terminal?.outcome, .unableToComplete)
            XCTAssertTrue(externalEditPreserved); XCTAssertFalse(editorExact)
            XCTAssertTrue(didHandoff); XCTAssertTrue(helperJoinedBeforeResume); XCTAssertTrue(staleApprovalIgnored)
            XCTAssertEqual(approvals.count, priorEffects + 1); XCTAssertEqual(calls.count, priorEffects)
            XCTAssertEqual(history?.filter { $0.response != nil }.count, priorEffects)
            XCTAssertEqual(fallbackCalls, 0); XCTAssertEqual(proposals.values().count, 1)
            XCTAssertFalse(calls.contains { $0.toolName == "press_key" })
            return
        }
        if rejectStaleEdit {
            XCTAssertEqual(terminal?.outcome, .unableToComplete)
            XCTAssertTrue(externalEditPreserved); XCTAssertFalse(editorExact); XCTAssertFalse(savedExact)
            XCTAssertEqual(approvals.count, 1); XCTAssertEqual(calls.count, 0); XCTAssertEqual(fallbackCalls, 0)
            XCTAssertEqual(history?.filter { $0.response != nil }.count, 0)
            return
        }
        XCTAssertEqual(terminal?.outcome, .taskCompleted)
        XCTAssertTrue(editorExact); XCTAssertTrue(savedExact)
        XCTAssertEqual(fallbackCalls, 0); XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(history?.filter { $0.response != nil }.count, 2)
        if handoffBeforeTool != nil {
            XCTAssertTrue(didHandoff); XCTAssertTrue(helperJoinedBeforeResume); XCTAssertTrue(staleApprovalIgnored)
            XCTAssertTrue(staleApprovalAfterResumeIgnored)
            XCTAssertTrue(selectionChangedDuringHandoff)
            XCTAssertEqual(approvals.count, 3); XCTAssertEqual(proposals.values().count, 1, "Resume must retain the semantic task")
        }
    }

    /// Real helper capability experiment. This owns all input and its target;
    /// it does not claim natural-language planner or whole-product acceptance.
    private func probeTextEditMCPWrite(tools: ComputerUseHostTools, app: NSRunningApplication,
        original: String, expected: String, document: URL, output: URL) async throws {
        let started = Date()
        let helper = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["MAC_CONTROL_HELPER_PATH"]))
        let pool = MCPClientPool(mutationLedger: MCPFileMutationCallLedger(fileURL: output.appendingPathComponent("mcp-mutations.json")),
            sessionFactory: { binary, generation in MCPClientSession(validatedBinary: binary, processGeneration: generation,
                stateDirectory: output.appendingPathComponent("helper-state")) })
        var results: [String: MCPToolResult] = [:], failure: Error?
        var beforeSave = false, editorExact = false, savedExact = false
        do {
            _ = try await pool.start(binaryURL: helper)
            let available = try await pool.allowedTools()
            func tool(_ name: String) throws -> MCPAllowedTool { try XCTUnwrap(available.first { $0.toolName == name }) }
            let before = try XCTUnwrap(tools.mcpFocusedTextSnapshot())
            XCTAssertTrue(before.text.value.utf8.elementsEqual(original.utf8))
            let found = try await pool.execute(tool("find_elements").makeCall(taskID: "mcp-write-discovery", arguments: [
                "pid": .integer(Int(app.processIdentifier)), "role": .string("AXTextArea")]))
            results["discovery"] = found
            let elementID = try XCTUnwrap(ComputerUseMCPFocusedTextRead.elementID(in: found, matching: before))
            guard try tools.mcpFocusedTextSnapshot() == before else { throw NativeTextFixtureFailure.unexpectedOutcome("Target changed before the owned experiment") }
            let edit = try tool("set_element_attribute").makeCall(taskID: "mcp-write-edit", arguments: [
                "element_id": .string(elementID), "name": .string("AXValue"), "value": .string(expected)])
            let approval = try await pool.prepareApproval(edit)
            guard try tools.mcpFocusedTextSnapshot() == before else { throw NativeTextFixtureFailure.unexpectedOutcome("Target changed during preparation") }
            let edited = try await pool.performApproved(edit, fingerprint: approval.fingerprint)
            results["edit"] = edited
            let after = try XCTUnwrap(tools.mcpFocusedTextSnapshot())
            editorExact = after.text.value.utf8.elementsEqual(expected.utf8)
            beforeSave = try Data(contentsOf: document) == Data(original.utf8)
            guard !edited.isError, editorExact else { throw NativeTextFixtureFailure.unexpectedOutcome("The actual helper did not set the complete TextEdit value") }
            let save = try tool("press_key").makeCall(taskID: "mcp-write-save", arguments: [
                "key": .string("s"), "modifiers": .array([.string("command")])])
            let saveApproval = try await pool.prepareApproval(save)
            guard try tools.mcpFocusedTextSnapshot() == after else { throw NativeTextFixtureFailure.unexpectedOutcome("Target changed before Save") }
            results["save"] = try await pool.performApproved(save, fingerprint: saveApproval.fingerprint)
            for _ in 0..<40 {
                savedExact = try Data(contentsOf: document) == Data(expected.utf8)
                if savedExact { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(try tools.mcpFocusedTextSnapshot()?.text.value.utf8.elementsEqual(expected.utf8) == true)
        } catch { failure = error }
        await pool.cancelAll()
        app.forceTerminate()
        for _ in 0..<60 { if app.isTerminated { break }; try await Task.sleep(for: .milliseconds(50)) }
        let jsonResults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(results))
        let report: [String: Any] = ["scope": "signed-MCP-component-experiment-in-real-TextEdit", "results": jsonResults,
            "elapsedSeconds": Date().timeIntervalSince(started), "failure": String(reflecting: failure),
            "fileUnchangedBeforeSave": beforeSave, "editorExactAfterEdit": editorExact, "savedFileExact": savedExact,
            "ownedTextEditExited": app.isTerminated, "modelInference": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("mcp-write-result.json"), options: .withoutOverwriting)
        XCTAssertTrue(app.isTerminated)
        if let failure { throw failure }
        XCTAssertTrue(beforeSave); XCTAssertTrue(editorExact); XCTAssertTrue(savedExact)
    }

    private func readTextEditUsingMacTools(tools: ComputerUseHostTools, app: NSRunningApplication,
        original: String, document: URL, output: URL, prompt: String? = nil) async throws {
        let initialSnapshot = try XCTUnwrap(tools.mcpFocusedTextSnapshot())
        XCTAssertTrue(initialSnapshot.text.value.utf8.elementsEqual(original.utf8))
        let helper = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["MAC_CONTROL_HELPER_PATH"]))
        let mutations = output.appendingPathComponent("mcp-mutations.json")
        let pool = MCPClientPool(mutationLedger: MCPFileMutationCallLedger(fileURL: mutations), sessionFactory: { binary, generation in
            MCPClientSession(validatedBinary: binary, processGeneration: generation, stateDirectory: output.appendingPathComponent("helper-state"))
        })
        var fallbackCalls = 0, result: ComputerUseExecutionResult?, failure: Error?
        var progress: [String] = [], diagnostic: MCPToolResult?, schemas: [String: MCPJSONValue] = [:]
        var targeted: MCPToolResult?, attributes: MCPToolResult?
        var scopeSamples: [String] = []
        let observedTools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true },
            mcpFocusedTextSnapshotProvider: {
                let snapshot = try tools.mcpFocusedTextSnapshot()
                scopeSamples.append(String(reflecting: snapshot))
                return snapshot
            }, frontmostApplicationIdentityProvider: { tools.frontmostApplicationSnapshot().identity },
            frontmostApplicationProvider: { tools.frontmostApplicationSnapshot().localizedName })
        let started = Date()
        do {
            let fallback = ComputerUseCapabilityExecutor(nativeExecution: { _, _, _ in
                fallbackCalls += 1
                return .unableToComplete("The read task was delegated to model fallback")
            })
            let executor = try await MCPFirstComputerUseExecutor.load(binaryURL: helper, visualFallback: fallback,
                clientPool: pool, planningTimeout: 5)
            let goal = prompt ?? "Tell me the complete text of the open TextEdit document."
            result = try await executor.execute(taskID: "textedit-mcp-read", prompt: goal, trustedUserPrompt: goal,
                tools: observedTools, progress: { progress.append($0) })
            // Independently inspect the same helper after the product route.
            // Diagnostic data never supplies the planner's answer or task ID.
            let available = try await pool.allowedTools()
            for tool in available where ["get_ui_tree", "get_element_attributes", "read_value", "find_element", "find_elements", "query_elements"].contains(tool.toolName) {
                schemas[tool.toolName] = tool.inputSchema
            }
            let tree = try XCTUnwrap(available.first { $0.toolName == "get_ui_tree" })
            diagnostic = try await pool.execute(tree.makeCall(taskID: "independent-tree-diagnostic", arguments: [
                "pid": .integer(Int(app.processIdentifier)), "max_depth": .integer(12)]))
            let query = try XCTUnwrap(available.first { $0.toolName == "find_elements" })
            targeted = try await pool.execute(query.makeCall(taskID: "independent-area-diagnostic", arguments: [
                "pid": .integer(Int(app.processIdentifier)), "role": .string("AXTextArea")]))
            if case .object(let root)? = targeted?.structuredContent, case .array(let elements)? = root["elements"],
               elements.count == 1, case .object(let element) = elements[0], case .string(let identifier)? = element["id"] {
                let read = try XCTUnwrap(available.first { $0.toolName == "get_element_attributes" })
                attributes = try await pool.execute(read.makeCall(taskID: "independent-value-diagnostic", arguments: [
                    "element_id": .string(identifier), "names": .array([.string("AXRole"), .string("AXValue"), .string("AXSubrole")])]))
            }
        } catch { failure = error }
        await pool.cancelAll()
        let unchanged = try Data(contentsOf: document) == Data(original.utf8)
        let finalSnapshot = try tools.mcpFocusedTextSnapshot()
        let editorUnchanged = finalSnapshot?.text.value.utf8.elementsEqual(original.utf8) == true
        let selectionUnchanged = finalSnapshot?.text.selection == initialSnapshot.text.selection
        var documentNodes: [MCPJSONValue] = []
        if case .object(let root)? = diagnostic?.structuredContent, case .array(let nodes)? = root["nodes"] {
            documentNodes = nodes.filter { if case .object(let node) = $0 { return node["role"] == .string("AXTextArea") }; return false }
        }
        let schemaJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schemas))
        let nodeJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(documentNodes))
        let targetedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(targeted?.structuredContent ?? .null), options: .fragmentsAllowed)
        let attributesJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(attributes?.structuredContent ?? .null), options: .fragmentsAllowed)
        app.forceTerminate()
        for _ in 0..<60 { if app.isTerminated { break }; try await Task.sleep(for: .milliseconds(50)) }
        let report: [String: Any] = ["scope": "real-TextEdit-default-MCP-planner-read-only",
            "elapsedSeconds": Date().timeIntervalSince(started), "result": String(reflecting: result), "failure": String(reflecting: failure),
            "fallbackCalls": fallbackCalls, "progress": progress, "scopeSamples": scopeSamples, "diagnosticSchemas": schemaJSON, "diagnosticDocumentNodes": nodeJSON,
            "diagnosticError": diagnostic?.isError as Any? ?? NSNull(), "diagnosticTruncated": diagnostic?.wasTruncated as Any? ?? NSNull(),
            "targetedResult": targetedJSON, "targetedError": targeted?.isError as Any? ?? NSNull(), "targetedTruncated": targeted?.wasTruncated as Any? ?? NSNull(),
            "attributeResult": attributesJSON, "attributeError": attributes?.isError as Any? ?? NSNull(), "attributeTruncated": attributes?.wasTruncated as Any? ?? NSNull(),
            "savedBytesMatchOriginal": unchanged, "editorTextUnchanged": editorUnchanged, "selectionUnchanged": selectionUnchanged,
            "inputUTF8Bytes": original.utf8.count, "initialSelection": NSStringFromRange(initialSnapshot.text.selection), "ownedTextEditExited": app.isTerminated,
            "mutationLedgerCreated": FileManager.default.fileExists(atPath: mutations.path)]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("mcp-read-result.json"), options: .withoutOverwriting)
        XCTAssertTrue(unchanged); XCTAssertTrue(editorUnchanged); XCTAssertTrue(selectionUnchanged); XCTAssertTrue(app.isTerminated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mutations.path))
        if let failure { throw failure }
        guard case .completed(let answer) = result else { return XCTFail("MCP did not complete the native document read") }
        XCTAssertTrue(answer.utf8.elementsEqual(original.utf8))
        XCTAssertEqual(fallbackCalls, 0)
    }

    /// Diagnostic only: no inference or input. A single test-owned backdrop
    /// changes behind one real TextEdit window; both capture paths are retained.
    private func measureTextEditBackground(tools: ComputerUseHostTools, app: NSRunningApplication, editorFrame: CGRect,
        original: String, document: URL, output: URL) async throws {
        let started = Date(), screen = try tools.currentScreen()
        let bounds = try XCTUnwrap(screen.frontmostWindowBounds)
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let appWindows = content.windows.filter { $0.owningApplication?.processID == app.processIdentifier }
        let windowMetadata: [String: Any] = ["ownedPID": app.processIdentifier, "axWindowBounds": String(describing: bounds),
            "windows": appWindows.map { ["windowID": $0.windowID, "frame": String(describing: $0.frame), "onScreen": $0.isOnScreen] as [String: Any] }]
        try JSONSerialization.data(withJSONObject: windowMetadata, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("window-metadata.json"), options: .withoutOverwriting)
        // The measured AX bounds include a border outside the WindowServer
        // frame. This diagnostic owns exactly one app window, so it can bind
        // that unique window without guessing a production matching tolerance.
        XCTAssertEqual(appWindows.count, 1, "The diagnostic owns exactly one TextEdit window")
        let window = try XCTUnwrap(appWindows.first)
        XCTAssertTrue(bounds.contains(window.frame))
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
        config.height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
        config.showsCursor = false; config.ignoreShadowsSingleWindow = true; config.shouldBeOpaque = false
        let backdrop = NSWindow(contentRect: try XCTUnwrap(NSScreen.main?.frame), styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false; backdrop.ignoresMouseEvents = true; backdrop.isOpaque = true
        defer { backdrop.close() }
        backdrop.backgroundColor = .white; backdrop.order(.below, relativeTo: Int(window.windowID))
        try await Task.sleep(for: .milliseconds(300))
        let beforeEditor = try tools.nativeFocusedEditorObservation()?.textState
        let beforeScreen = try tools.currentScreen(), before = try ComputerUseDesktopImage(observation: beforeScreen)
        let isolatedBeforeCG = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let isolatedBefore = try ComputerUseDesktopImage(observation: .init(image: CIImage(cgImage: isolatedBeforeCG), displayBounds: window.frame, frontmostWindowBounds: window.frame))
        backdrop.backgroundColor = .black; backdrop.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let afterScreen = try tools.currentScreen(), after = try ComputerUseDesktopImage(observation: afterScreen)
        let isolatedAfterCG = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let isolatedAfter = try ComputerUseDesktopImage(observation: .init(image: CIImage(cgImage: isolatedAfterCG), displayBounds: window.frame, frontmostWindowBounds: window.frame))
        let afterEditor = try tools.nativeFocusedEditorObservation()?.textState
        XCTAssertEqual(beforeEditor, afterEditor); XCTAssertEqual(afterEditor?.valuePrefix, original)
        XCTAssertEqual(beforeScreen.frontmostWindowBounds, afterScreen.frontmostWindowBounds)
        XCTAssertEqual(try tools.nativeFocusedTextFrame(), editorFrame)
        XCTAssertEqual(try Data(contentsOf: document), Data(original.utf8))
        var displayDifference: [String: String] = [:], independentDifference: [String: String] = [:]
        let displayMatches = try before.matchesInsertionPointPixels(of: after, window: bounds, field: editorFrame,
            onDifference: { changed, pixels, field in displayDifference = ["display": String(describing: changed), "pixels": String(describing: pixels), "field": String(describing: field)] })
        let independentMatches = try isolatedBefore.matchesInsertionPointPixels(of: isolatedAfter, window: window.frame, field: editorFrame.intersection(window.frame),
            onDifference: { changed, pixels, field in independentDifference = ["display": String(describing: changed), "pixels": String(describing: pixels), "field": String(describing: field)] })
        for (name, image) in [("display-white.png", before), ("display-black.png", after), ("window-white.png", isolatedBefore), ("window-black.png", isolatedAfter)] {
            try image.png.write(to: output.appendingPathComponent(name), options: .withoutOverwriting)
        }
        backdrop.close(); app.forceTerminate()
        for _ in 0..<60 { if app.isTerminated { break }; try await Task.sleep(for: .milliseconds(50)) }
        let report: [String: Any] = ["scope": "one-real-TextEdit-window-with-test-owned-backdrop-no-input-no-inference",
            "elapsedSeconds": Date().timeIntervalSince(started), "windowBounds": String(describing: bounds),
            "editorFrame": String(describing: editorFrame), "filterContentRect": String(describing: filter.contentRect),
            "filterPointPixelScale": filter.pointPixelScale, "windowImageWidth": isolatedBeforeCG.width, "windowImageHeight": isolatedBeforeCG.height,
            "displayCaptureMatches": displayMatches, "independentWindowCaptureMatches": independentMatches,
            "displayDifference": displayDifference, "independentDifference": independentDifference,
            "textAndSelectionMatch": beforeEditor == afterEditor, "savedBytesMatchOriginal": try Data(contentsOf: document) == Data(original.utf8),
            "ownedTextEditExited": app.isTerminated]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("capture-comparison.json"), options: .withoutOverwriting)
        XCTAssertTrue(app.isTerminated)
        XCTAssertFalse(displayMatches, "The controlled backdrop should reproduce the observed composited-window rejection")
    }

    private static func managedHoloInputs(_ environment: [String: String]) async throws -> ComputerUseHoloRuntimeInputs {
        let directory = URL(fileURLWithPath: try XCTUnwrap(environment["HOLO_ASSETS"]))
        for (name, expected) in [(ComputerUseHoloRuntimeInputs.modelFileName, "cfdd26e8e9ee34de0c052ea68fb5c61dd8f34986fa3e1b631e2bab6ab1b44ac9"),
            (ComputerUseHoloRuntimeInputs.projectorFileName, "4eca6e6633c5384c4f6e220e1076fd6b96c53bc75baf421c553a8d8ba9649f5f")] {
            let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent(name)); defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty { hash.update(data: chunk) }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw OSAtlasLlamaRuntimeError.invalidLocalInstallation }
        }
        let runtimeDirectory = try OSAtlasVisualExecutorLoader.bundledRuntimeDirectoryURL(in: .main)
        let executable = runtimeDirectory.appendingPathComponent("llama-server")
        guard executable.standardizedFileURL == URL(fileURLWithPath: try XCTUnwrap(environment["HOLO_BINARY"])).standardizedFileURL,
              try DarwinOSAtlasProcessInspector().matchingProcesses(for: executable).isEmpty else { throw OSAtlasLlamaRuntimeError.inactiveSession }
        return .init(modelURL: directory.appendingPathComponent(ComputerUseHoloRuntimeInputs.modelFileName),
            projectorURL: directory.appendingPathComponent(ComputerUseHoloRuntimeInputs.projectorFileName), llamaServerURL: executable)
    }

    /// Only this opt-in XCTest launcher changes the process ceiling. The
    /// standard launcher still owns credentials, identity, signals and joins.
    private final class ManagedHoloTestLauncher: OSAtlasLlamaServerLaunching, @unchecked Sendable {
        private let lock = NSLock()
        private var directories: [URL] = []
        var credentialDirectories: [URL] { lock.lock(); defer { lock.unlock() }; return directories }
        private func record(_ directory: URL) { lock.lock(); defer { lock.unlock() }; directories.append(directory) }
        func launch(configuration: OSAtlasLlamaLaunchConfiguration) async throws -> any OSAtlasLlamaServerProcess {
            guard configuration.arguments.contains(ComputerUseHoloModel.modelAlias), let projector = configuration.multimodalProjectorURL,
                  let credential = configuration.authenticationFile else { throw OSAtlasLlamaRuntimeError.invalidLocalInstallation }
            let base = configuration.resourceProfile
            let diagnostic = OSAtlasLlamaResourceProfile(tier: base.tier, contextSize: base.contextSize,
                logicalBatchSize: base.logicalBatchSize, physicalBatchSize: base.physicalBatchSize,
                maximumResidentMemoryBytes: 5 * 1_024 * 1_024 * 1_024,
                minimumLaunchMemoryBytes: base.minimumLaunchMemoryBytes, minimumInferenceMemoryBytes: base.minimumInferenceMemoryBytes)
            let inputs = ComputerUseHoloRuntimeInputs(modelURL: configuration.modelFirstSplitURL, projectorURL: projector, llamaServerURL: configuration.executableURL)
            record(credential.directoryURL)
            return try await FoundationOSAtlasLlamaServerLauncher().launch(configuration: .init(holoInputs: inputs,
                port: configuration.port, bearerToken: configuration.bearerToken, authenticationFile: credential, resourceProfile: diagnostic))
        }
    }

    private func runNativeScrollFixture(useHolo: Bool, managedHolo: Bool = false, loadedHolo: Bool = false) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_COMPUTER_USE_NATIVE_SCROLL_ACCEPTANCE"] == "1" else { throw XCTSkip("Opt-in disposable AppKit scroll fixture") }
        guard AXIsProcessTrusted() else { return XCTFail("Accessibility permission is required") }
        let managedInputs = managedHolo ? try await Self.managedHoloInputs(environment) : nil
        let managedLauncher = ManagedHoloTestLauncher()
        let managedRuntime = managedHolo ? OSAtlasLlamaRuntime(launcher: managedLauncher) : nil
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
        let observedExecutor = try ComputerUseDesktopExecutor(journalDirectory: directory.appendingPathComponent("journals"), propose: { input in
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
                if let managedRuntime, let managedInputs {
                    let endpoint = try await managedRuntime.activateHolo(managedInputs)
                    proposal = try await .init(managedRuntime.proposeHolo(endpoint: endpoint, input: input))
                    try Data(proposal.response.utf8).write(to: proposalDirectory.appendingPathComponent("response-\(responses.count).json"), options: .withoutOverwriting)
                } else {
                    proposal = try await .init(HoloTestProposalRunner.propose(input: input, directory: proposalDirectory,
                        index: responses.count, environment: environment, memoryLimitGiB: 5, registerProbe: { diagnosticProbe = $0 }))
                }
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
        }, finishRun: { await diagnosticProbe?.cancelAndWait(); diagnosticProbe = nil; await managedRuntime?.shutdown() })
        let executor: ComputerUseDesktopExecutor
        var loaderActivationSeconds: TimeInterval = 0
        if loadedHolo {
            let manifest = ComputerUseArtifactManifest.holo31
            let loader = OSAtlasVisualExecutorLoader(resolver: .init(manifest: manifest), runtime: try XCTUnwrap(managedRuntime),
                nativeJournalDirectory: directory.appendingPathComponent("journals"))
            let beforeLoad = Date()
            let loaded = try await loader.load(receipt: .init(installationVersion: manifest.installationVersion, modelVariant: manifest.modelVariant,
                modelDirectory: try XCTUnwrap(managedInputs).modelURL.deletingLastPathComponent().path, installedAt: Date()), progress: { _ in })
            loaderActivationSeconds = Date().timeIntervalSince(beforeLoad)
            executor = try XCTUnwrap(loaded as? ComputerUseDesktopExecutor, "The Holo package must create the native executor")
            XCTAssertTrue(executor.isReady); XCTAssertFalse(executor.requiresMacControlHelper)
        } else { executor = observedExecutor }
        let memory = managedInputs.map { inputs in Task.detached { () -> (UInt64, Int) in
            var peak: UInt64 = 0, samples = 0
            while !Task.isCancelled {
                for process in (try? DarwinOSAtlasProcessInspector().matchingProcesses(for: inputs.llamaServerURL)) ?? [] {
                    if let bytes = OSAtlasProcessMemoryGuard.residentBytes(processID: process.processIdentifier) { peak = max(peak, bytes); samples += 1 }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return (peak, samples)
        } }
        defer { memory?.cancel() }
        let run = Task { try await executor.execute(taskID: "native-scroll", prompt: goal, trustedUserPrompt: goal, tools: tools, progress: { _ in }) }
        let deadline = Task { try await Task.sleep(for: .seconds(useHolo ? 90 : 40)); run.cancel() }
        var result: ComputerUseExecutionResult?, failure: Error?
        do { result = try await run.value } catch { failure = error }
        deadline.cancel()
        memory?.cancel()
        let memoryResult = await memory?.value
        let final = try read(), journals = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("journals"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
        let dispatches = journals.filter { $0.stepIDs == ["native-dispatch-returned"] }.count
        let workersGone = useHolo ? try DarwinOSAtlasProcessInspector().matchingProcesses(for: URL(fileURLWithPath: XCTUnwrap(environment["HOLO_BINARY"]))).isEmpty : true
        let workerStop = await managedRuntime?.lastWorkerStop
        if loadedHolo {
            responses = executor.diagnosticHistory.map { ["response": $0.response, "actionError": $0.actionError ?? "",
                "screenshotSHA256": SHA256.hash(data: $0.screenshotPNG).map { String(format: "%02x", $0) }.joined()] }
        }
        var report: [String: Any] = ["scope": loadedHolo ? "loader-Holo-native-scroll" : managedHolo ? "managed-Holo-native-scroll" : useHolo ? "actual-Holo-native-scroll" : "scripted-native-scroll", "goal": goal,
            "responses": responses, "fixtureState": final, "dispatchJournalCount": dispatches, "elapsedSeconds": Date().timeIntervalSince(started),
            "result": result.map { String(describing: $0) } ?? "", "failure": failure.map { String(reflecting: $0) } ?? "",
            "revalidation": executor.lastRevalidationDiagnostic, "ownedWorkerExited": workersGone, "diagnosticWorkerLimitGiB": useHolo ? 5 : 0,
            "wholeApp12GBQualified": false, "fixtureFrontmostAtReturn": NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier]
        if managedHolo {
            report["managedRuntime"] = true; report["managedLaunchCount"] = managedLauncher.credentialDirectories.count
            report["peakWorkerMemoryBytes"] = memoryResult?.0 ?? 0; report["memorySamples"] = memoryResult?.1 ?? 0
            report["memoryMetric"] = "sampled max of resident size and physical footprint"
            report["credentialsRemoved"] = managedLauncher.credentialDirectories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
            if let workerStop { report["workerStop"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(workerStop)) }
        }
        if loadedHolo {
            report["productionLoaderUsed"] = true; report["loaderActivationSeconds"] = loaderActivationSeconds
            report["modelResponseTraceAvailable"] = true; report["memorySamplingStartsAfterLoaderActivation"] = true
            report["proposalTraceSource"] = "bounded executor history after return"
            let screen = try tools.currentScreen(), window = try XCTUnwrap(screen.frontmostWindowBounds)
            let nativeWindow = try tools.nativeControlObservation(displayBounds: screen.displayBounds, windowBounds: window)?.window
            report["finalNativeWindow"] = nativeWindow?.jsonObject as Any? ?? NSNull()
            XCTAssertEqual(nativeWindow?.role, "AXWindow")
            XCTAssertEqual(nativeWindow?.subrole, "AXStandardWindow")
            XCTAssertEqual(nativeWindow?.modal, false, "The controlled document is an ordinary nonmodal window")
            let prepared = try ComputerUseDesktopImage(observation: screen)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: prepared.png)), image = try XCTUnwrap(bitmap.cgImage)
            let crop = CGRect(x: (window.minX - screen.displayBounds.minX) / screen.displayBounds.width * CGFloat(image.width),
                y: (window.minY - screen.displayBounds.minY) / screen.displayBounds.height * CGFloat(image.height),
                width: window.width / screen.displayBounds.width * CGFloat(image.width), height: window.height / screen.displayBounds.height * CGFloat(image.height)).integral
            let imageAttachment = XCTAttachment(image: NSImage(cgImage: try XCTUnwrap(image.cropping(to: crop)), size: .zero))
            imageAttachment.name = "Loaded Holo final native document"; imageAttachment.lifetime = .keepAlways; add(imageAttachment)
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "Native scroll workflow"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(workersGone)
        if managedHolo {
            XCTAssertEqual(managedLauncher.credentialDirectories.count, loadedHolo ? 2 : 1, "One activation check, when loading the package, then one worker for the task")
            XCTAssertTrue(managedLauncher.credentialDirectories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            XCTAssertEqual(workerStop?.cleanupSucceeded, true)
        }
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
        if loadedHolo { XCTAssertEqual(executor.diagnosticHistory.count, calls) }
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

    func testScopedDesktopRejectsForeignAppOrWindowBeforeProposing() async throws {
        for (scenario, appMatches, windowMatches) in [("foreign app", false, true), ("foreign window", true, false)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var proposals = 0, effects = 0
            let tools = desktopTestTools(perform: { _ in effects += 1 })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
                proposals += 1
                return .init(response: "candidate", action: .reportCompletion("Done"))
            }, surfaceScopeCheck: { _ in
                guard appMatches && windowMatches else { throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged }
            })
            do {
                _ = try await executor.execute(taskID: "foreign-surface-\(scenario)", prompt: "Click", trustedUserPrompt: "Click", tools: tools, progress: { _ in })
                XCTFail("A foreign app/window must stop before proposal: \(scenario)")
            } catch ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged {}
            XCTAssertEqual(proposals, 0, scenario)
            XCTAssertEqual(effects, 0, scenario)
        }
    }

    func testScopedDesktopStopsAfterEffectWhenOwnedWindowChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var proposals = 0, effects = 0, scopeValid = true
        let tools = desktopTestTools(perform: { _ in effects += 1; scopeValid = false })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposals += 1
            if proposals > 1 { return .init(response: "review", decision: .handoff("Review the page.")) }
            return .init(response: "click", action: .pointer(.leftClick, .init(x: 500, y: 500)))
        }, surfaceScopeCheck: { _ in
            guard scopeValid else { throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged }
        })
        do {
            _ = try await executor.execute(taskID: "changed-owned-window", prompt: "Click", trustedUserPrompt: "Click", tools: tools, progress: { _ in })
            XCTFail("A changed owned window must stop before the next proposal or completion")
        } catch ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged {}
        XCTAssertEqual(proposals, 1)
        XCTAssertEqual(effects, 1)
        scopeValid = true
        let resumed = try await executor.execute(taskID: "changed-owned-window", prompt: "Resume", trustedUserPrompt: "Click", tools: tools, progress: { _ in })
        XCTAssertEqual(resumed, .userInterventionRequired("Review the page."))
        XCTAssertEqual(proposals, 2, "Restoring the same window should permit a fresh observation")
        XCTAssertEqual(effects, 1, "Resume must not repeat the prior click")
        XCTAssertEqual(executor.diagnosticHistory.filter { $0.response == "click" }.count, 1)
    }

    func testScopedDesktopWaitsForPostClickTransitionBeforeObservingAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var proposals = 0, effects = 0, scopeValid = true
        let tools = desktopTestTools(perform: { _ in
            effects += 1
            scopeValid = false
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                scopeValid = true
            }
        })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
            proposals += 1
            if proposals == 1 {
                return .init(response: "click", action: .pointer(.leftClick, .init(x: 500, y: 500)))
            }
            XCTAssertEqual(input.history.count, 1, "The returned click should be recorded before the next proposal")
            XCTAssertEqual(input.history.first?.response, "click")
            return .init(response: "handoff", decision: .handoff("The page is ready for review."))
        }, surfaceScopeCheck: { _ in
            guard scopeValid else { throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged }
        })

        let result = try await executor.execute(taskID: "post-click-transition", prompt: "Open the picker", trustedUserPrompt: "Open the picker", tools: tools, progress: { _ in })
        XCTAssertEqual(result, .userInterventionRequired("The page is ready for review."))
        XCTAssertEqual(effects, 1)
        XCTAssertEqual(proposals, 2)
        XCTAssertEqual(executor.diagnosticHistory.filter { $0.response == "click" }.count, 1)
        XCTAssertEqual(executor.diagnosticHistory.first?.response, "click")
    }

    func testScopedDesktopWaitsForDelayedFocusedEditorRetirementBeforeReplanning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var current = ComputerUseTextSnapshot(targetID: "A", value: "", selection: NSRange(location: 0, length: 0),
            isEditable: true, isSecure: false)
        let editor = ComputerUseTextEditor(read: { current }, select: { _, _ in false },
            replaceSelectedText: { _, _ in false }, postUnicode: { _, _ in }, mayAct: { true })
        var effects = 0, proposals = 0
        var effectStarted: Date?
        var retirement: Task<Void, Never>?
        defer { retirement?.cancel() }
        let tools = desktopTestTools(focus: { current.preconditionDigest }, textEditor: editor, perform: { _ in
            effects += 1
            effectStarted = Date()
            current = ComputerUseTextSnapshot(targetID: "B", value: "", selection: NSRange(location: 0, length: 0),
                isEditable: true, isSecure: false)
            retirement = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                current = ComputerUseTextSnapshot(targetID: "C", value: "", selection: NSRange(location: 0, length: 0),
                    isEditable: true, isSecure: false)
            }
        })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
            proposals += 1
            if proposals == 1 {
                XCTAssertEqual(current.targetID, "A")
                return .init(response: "open-compose", action: .pointer(.leftClick, .init(x: 500, y: 500)))
            }
            XCTAssertEqual(current.targetID, "C", "The delayed title-change retirement must settle before replanning")
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(effectStarted ?? Date()), 1.8,
                "The next proposal must wait for the new focused target to remain stable")
            XCTAssertEqual(input.history.count, 1)
            XCTAssertEqual(input.history.first?.response, "open-compose")
            return .init(response: "ready", decision: .handoff("The recipient field is ready for review."))
        }, surfaceScopeCheck: { _ in })

        let result = try await executor.execute(taskID: "delayed-editor-retirement", prompt: "Open a compose editor.",
            trustedUserPrompt: "Open a compose editor.", tools: tools, progress: { _ in })
        XCTAssertEqual(result, .userInterventionRequired("The recipient field is ready for review."))
        XCTAssertEqual(effects, 1)
        XCTAssertEqual(proposals, 2)
    }

    func testScopedDesktopCancellationDuringEditorQuietWaitPreventsNextProposal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var current = ComputerUseTextSnapshot(targetID: "A", value: "", selection: NSRange(location: 0, length: 0),
            isEditable: true, isSecure: false)
        let editor = ComputerUseTextEditor(read: { current }, select: { _, _ in false },
            replaceSelectedText: { _, _ in false }, postUnicode: { _, _ in }, mayAct: { true })
        var run: Task<ComputerUseExecutionResult, Error>?
        var cancellation: Task<Void, Never>?
        defer { cancellation?.cancel(); run?.cancel() }
        var effects = 0, proposals = 0
        let tools = desktopTestTools(focus: { current.preconditionDigest }, textEditor: editor, perform: { _ in
            effects += 1
            current = ComputerUseTextSnapshot(targetID: "B", value: "", selection: NSRange(location: 0, length: 0),
                isEditable: true, isSecure: false)
            cancellation = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                run?.cancel()
            }
        })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposals += 1
            if proposals == 1 { return .init(response: "open-compose", action: .pointer(.leftClick, .init(x: 500, y: 500))) }
            return .init(response: "late", decision: .handoff("Review the editor."))
        }, surfaceScopeCheck: { _ in })
        run = Task { try await executor.execute(taskID: "editor-wait-cancel", prompt: "Open a compose editor.",
            trustedUserPrompt: "Open a compose editor.", tools: tools, progress: { _ in }) }
        do { _ = try await run?.value; XCTFail("Cancellation during the quiet wait must stop replanning") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(effects, 1)
        XCTAssertEqual(proposals, 1)
        XCTAssertEqual(executor.diagnosticHistory.filter { $0.response == "open-compose" }.count, 1)
    }

    func testScopedDesktopEditorChurnStopsAndResumeDoesNotReplayClick() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var current = ComputerUseTextSnapshot(targetID: "A", value: "", selection: NSRange(location: 0, length: 0),
            isEditable: true, isSecure: false)
        let editor = ComputerUseTextEditor(read: { current }, select: { _, _ in false },
            replaceSelectedText: { _, _ in false }, postUnicode: { _, _ in }, mayAct: { true })
        var churn: Task<Void, Never>?
        defer { churn?.cancel() }
        var effects = 0, proposals = 0
        let tools = desktopTestTools(focus: { current.preconditionDigest }, textEditor: editor, perform: { _ in
            effects += 1
            current = ComputerUseTextSnapshot(targetID: "B", value: "", selection: NSRange(location: 0, length: 0),
                isEditable: true, isSecure: false)
            churn = Task { @MainActor in
                var index = 0
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    index += 1
                    current = ComputerUseTextSnapshot(targetID: "churn-\(index)", value: "", selection: NSRange(location: 0, length: 0),
                        isEditable: true, isSecure: false)
                }
            }
        })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
            proposals += 1
            if proposals == 1 { return .init(response: "open-compose", action: .pointer(.leftClick, .init(x: 500, y: 500))) }
            XCTAssertEqual(input.history.count, 1)
            return .init(response: "ready", decision: .handoff("Review the editor."))
        }, surfaceScopeCheck: { _ in })
        do {
            _ = try await executor.execute(taskID: "editor-churn", prompt: "Open a compose editor.",
                trustedUserPrompt: "Open a compose editor.", tools: tools, progress: { _ in })
            XCTFail("A continuously changing focused target must stop safely")
        } catch ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged {}
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(proposals, 1)
        XCTAssertEqual(effects, 1)
        XCTAssertEqual(executor.diagnosticHistory.filter { $0.response == "open-compose" }.count, 1)

        churn?.cancel()
        churn = nil
        current = ComputerUseTextSnapshot(targetID: "stable-after-stop", value: "", selection: NSRange(location: 0, length: 0),
            isEditable: true, isSecure: false)
        let resumed = try await executor.execute(taskID: "editor-churn", prompt: "Resume editor observation.",
            trustedUserPrompt: "Open a compose editor.", tools: tools, progress: { _ in })
        XCTAssertEqual(resumed, .userInterventionRequired("Review the editor."))
        XCTAssertEqual(proposals, 2)
        XCTAssertEqual(effects, 1, "Resume observes the stable editor without replaying the earlier click")
        XCTAssertEqual(executor.diagnosticHistory.filter { $0.response == "open-compose" }.count, 1)
    }

    func testScopedDesktopEditorScopeLossDuringQuietWaitPreventsNextProposal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var current = ComputerUseTextSnapshot(targetID: "A", value: "", selection: NSRange(location: 0, length: 0),
            isEditable: true, isSecure: false)
        let editor = ComputerUseTextEditor(read: { current }, select: { _, _ in false },
            replaceSelectedText: { _, _ in false }, postUnicode: { _, _ in }, mayAct: { true })
        var scopeValid = true
        var transition: Task<Void, Never>?
        defer { transition?.cancel() }
        var effects = 0, proposals = 0
        let tools = desktopTestTools(focus: { current.preconditionDigest }, textEditor: editor, perform: { _ in
            effects += 1
            current = ComputerUseTextSnapshot(targetID: "B", value: "", selection: NSRange(location: 0, length: 0),
                isEditable: true, isSecure: false)
            transition = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                scopeValid = false
            }
        })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposals += 1
            if proposals == 1 { return .init(response: "open-compose", action: .pointer(.leftClick, .init(x: 500, y: 500))) }
            return .init(response: "late", decision: .handoff("Review the editor."))
        }, surfaceScopeCheck: { _ in
            guard scopeValid else { throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged }
        })
        do {
            _ = try await executor.execute(taskID: "editor-scope-loss", prompt: "Open a compose editor.",
                trustedUserPrompt: "Open a compose editor.", tools: tools, progress: { _ in })
            XCTFail("Scope loss during the quiet wait must stop replanning")
        } catch ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged {}
        XCTAssertEqual(proposals, 1)
        XCTAssertEqual(effects, 1)
        XCTAssertEqual(executor.diagnosticHistory.filter { $0.response == "open-compose" }.count, 1)
    }

    func testScopedCompletionUsesOwnedWindowPixelsAndHandoffDoesNotNeedPixelEquality() async throws {
        for scenario in ["outside completion", "inside completion", "outside handoff"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let display = CGRect(x: 0, y: 0, width: 640, height: 400)
            let window = CGRect(x: 100, y: 50, width: 400, height: 300)
            let changedRect = scenario == "inside completion" ? CGRect(x: 200, y: 100, width: 30, height: 30)
                : CGRect(x: 10, y: 10, width: 30, height: 30)
            var changed = false, effects = 0, proposals = 0
            let code = ComputerUseApplicationCodeIdentity(authority: .runningCode, bundleIdentifier: "com.apple.Safari",
                canonicalBundlePath: "/Applications/Safari.app", canonicalExecutablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
                designatedRequirement: "test", teamIdentifier: nil, platformIdentifier: nil)
            let app = ComputerUseApplicationIdentity(bundleIdentifier: "com.apple.Safari", processIdentifier: 91,
                launchGeneration: 1, codeIdentity: code)!
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, actionPerformer: { _ in effects += 1 },
                screenProvider: {
                    let base = CIImage(color: .black).cropped(to: display)
                    let image = changed ? CIImage(color: .blue).cropped(to: changedRect).composited(over: base) : base
                    return .init(image: image, displayBounds: display, frontmostWindowBounds: window)
                }, transientSystemOverlayProvider: { _ in false }, accessibilityContextProvider: { _ in "" },
                authenticationContextProvider: { nil }, screenCaptureConsentContextProvider: { nil },
                planningAccessibilityIdentityProvider: { "safari-window" },
                frontmostApplicationIdentityProvider: { app }, frontmostApplicationProvider: { "Safari" })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
                proposals += 1
                changed = true
                if scenario == "outside handoff" { return .init(response: "Pause", decision: .handoff("Please review the sign-in page.")) }
                return .init(response: "Done", action: .reportCompletion("The requested page is open."))
            }, surfaceScopeCheck: { _ in })
            let result = try await executor.execute(taskID: scenario, prompt: "Open the requested page.",
                trustedUserPrompt: "Open the requested page.", tools: tools, progress: { _ in })
            if scenario == "inside completion" {
                XCTAssertEqual(result, .completed("The requested page is open."))
                XCTAssertEqual(proposals, 2, "A stale completion claim should be reconsidered from a stable fresh frame")
            } else if scenario == "outside handoff" {
                XCTAssertEqual(result, .userInterventionRequired("Please review the sign-in page."))
            } else {
                XCTAssertEqual(result, .completed("The requested page is open."))
            }
            XCTAssertEqual(effects, 0, scenario)
            if scenario != "inside completion" {
                XCTAssertEqual(proposals, 1, "A terminal decision must not trigger more actions")
            }
        }
    }

    func testScopedVisualClickWithoutAXTargetIgnoresPixelsOutsideOwnedWindow() async throws {
        let display = CGRect(x: 0, y: 0, width: 1728, height: 1050)
        let window = CGRect(x: 0, y: 33, width: 1728, height: 999)
        let code = ComputerUseApplicationCodeIdentity(authority: .runningCode, bundleIdentifier: "com.apple.Safari",
            canonicalBundlePath: "/Applications/Safari.app", canonicalExecutablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
            designatedRequirement: "test", teamIdentifier: nil, platformIdentifier: nil)
        let app = ComputerUseApplicationIdentity(bundleIdentifier: "com.apple.Safari", processIdentifier: 91,
            launchGeneration: 1, codeIdentity: code)!

        for (mode, scenario) in [("click", "outside"), ("click", "elsewhere in window"), ("click", "target"),
                                 ("key", "elsewhere in window"), ("key", "focus")] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var changed = false, proposals = 0, effects = 0
            var focus = "original-control"
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true },
                approvalTargetProvider: { _ in .init(context: "AXButton", applicationID: "fixture", accessibilityIdentity: "visual-target", frame: nil) }, actionPerformer: { _ in effects += 1 },
                screenProvider: {
                    let base = CIImage(color: .black).cropped(to: display)
                    let changedRect = scenario == "outside"
                        ? CGRect(x: 5, y: 1030, width: 20, height: 20)
                        : (scenario == "target" ? CGRect(x: 1144, y: 641, width: 20, height: 20)
                            : CGRect(x: 500, y: 200, width: 20, height: 20))
                    let image = changed ? CIImage(color: .blue).cropped(to: changedRect).composited(over: base) : base
                    return .init(image: image, displayBounds: display, frontmostWindowBounds: window)
                }, transientSystemOverlayProvider: { _ in false }, accessibilityContextProvider: { _ in "AXButton Browse" },
                authenticationContextProvider: { nil }, screenCaptureConsentContextProvider: { nil },
                planningAccessibilityIdentityProvider: { focus },
                frontmostApplicationIdentityProvider: { app }, frontmostApplicationProvider: { "Safari" })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
                proposals += 1
                changed = true
                if proposals == 1 {
                    if scenario == "focus" { focus = "another-control" }
                    if mode == "key" { return .init(response: "tab", action: .key(["Tab"])) }
                    return .init(response: "click", action: .pointer(.leftClick, .init(x: 2000.0 / 3.0, y: 401000.0 / 1050.0)))
                }
                return .init(response: "handoff", decision: .handoff("Review the page."))
            }, surfaceScopeCheck: { _ in })

            let result = try await executor.execute(taskID: "nil-ax-\(scenario)", prompt: "Click in the owned window.",
                trustedUserPrompt: "Click in the owned window.", tools: tools, progress: { _ in })
            if scenario != "target" && scenario != "focus" {
                XCTAssertEqual(result, .userInterventionRequired("Review the page."))
                XCTAssertEqual(effects, 1, "A change outside the click context must not block its visual click")
                XCTAssertEqual(proposals, 2)
            } else {
                XCTAssertEqual(effects, 0, "Changed target pixels or keyboard focus must invalidate the action")
                XCTAssertEqual(proposals, 2)
            }
        }
    }

    func testScopedDesktopCompletesOnlyAfterValidatorAccepts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var proposals = 0, checks = 0, scopeChecks = 0
        let tools = desktopTestTools()
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposals += 1
            return .init(response: "candidate", action: .reportCompletion("Verified"))
        }, surfaceScopeCheck: { _ in scopeChecks += 1 }, completeCheck: { answer in
            checks += 1
            XCTAssertEqual(answer, "Verified")
            return true
        })
        let result = try await executor.execute(taskID: "verified-completion-candidate", prompt: "Finish", trustedUserPrompt: "Finish", tools: tools, progress: { _ in })
        XCTAssertEqual(result, .completed("Verified"))
        XCTAssertEqual(proposals, 1)
        XCTAssertEqual(checks, 1)
        XCTAssertGreaterThan(scopeChecks, 0)
    }

    func testScopedCompletionScreenChangeRequiresFreshEvidenceBeforeCompleting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let display = CGRect(x: 0, y: 0, width: 640, height: 400)
        let window = CGRect(x: 100, y: 50, width: 400, height: 300)
        var screenChanged = false, proposals = 0, completionChecks = 0, effects = 0
        var firstScreenshot: Data?
        let code = ComputerUseApplicationCodeIdentity(authority: .runningCode, bundleIdentifier: "com.apple.Safari",
            canonicalBundlePath: "/Applications/Safari.app", canonicalExecutablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
            designatedRequirement: "test", teamIdentifier: nil, platformIdentifier: nil)
        let app = ComputerUseApplicationIdentity(bundleIdentifier: "com.apple.Safari", processIdentifier: 91,
            launchGeneration: 1, codeIdentity: code)!
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, actionPerformer: { _ in effects += 1 },
            screenProvider: {
                let color = screenChanged ? CIColor(red: 0, green: 0, blue: 1, alpha: 1)
                    : CIColor(red: 0, green: 0, blue: 0, alpha: 1)
                return .init(image: CIImage(color: color).cropped(to: display), displayBounds: display,
                    frontmostWindowBounds: window)
            }, transientSystemOverlayProvider: { _ in false }, accessibilityContextProvider: { _ in "" },
            authenticationContextProvider: { nil }, screenCaptureConsentContextProvider: { nil },
            planningAccessibilityIdentityProvider: { "safari-window" },
            frontmostApplicationIdentityProvider: { app }, frontmostApplicationProvider: { "Safari" })
        let goal = "Upload the selected presentation and verify it finished uploading."
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
            proposals += 1
            XCTAssertEqual(input.goal, goal)
            if proposals == 1 {
                XCTAssertTrue(input.history.isEmpty)
                XCTAssertNil(input.actionError)
                firstScreenshot = input.screenshotPNG
                screenChanged = true // Simulate the completion toast changing while the model was planning.
                return .init(response: "The upload is finished.", action: .reportCompletion("Verified upload"))
            }
            XCTAssertNotEqual(input.screenshotPNG, firstScreenshot, "The rejected claim must be reconsidered against fresh pixels")
            XCTAssertEqual(input.history.count, 1)
            XCTAssertEqual(input.history.first?.response, "The upload is finished.")
            XCTAssertTrue(input.actionError?.localizedCaseInsensitiveContains("completion") == true,
                "A stale completion claim should receive completion-specific feedback")
            return .init(response: "The fresh page confirms the upload.", action: .reportCompletion("Freshly verified upload"))
        }, surfaceScopeCheck: { _ in }, completeCheck: { _ in
            completionChecks += 1
            return true
        })

        let result = try await executor.execute(taskID: "completion-observation-refresh", prompt: goal,
            trustedUserPrompt: goal, tools: tools, progress: { _ in })
        XCTAssertEqual(result, .completed("Freshly verified upload"))
        XCTAssertEqual(proposals, 2, "A changed completion observation must be replanned once from fresh evidence")
        XCTAssertEqual(completionChecks, 1, "Only the stable second completion claim reaches the validator")
        XCTAssertEqual(effects, 0, "Completion recovery must not synthesize input")
    }

    func testScopedCompletionScreenChangesHandOffBoundedlyAndScopeLossFailsSafely() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let display = CGRect(x: 0, y: 0, width: 640, height: 400)
        let window = CGRect(x: 100, y: 50, width: 400, height: 300)
        var screenChanged = false, proposals = 0, completionChecks = 0, effects = 0
        var scopeValid = true
        let code = ComputerUseApplicationCodeIdentity(authority: .runningCode, bundleIdentifier: "com.apple.Safari",
            canonicalBundlePath: "/Applications/Safari.app", canonicalExecutablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
            designatedRequirement: "test", teamIdentifier: nil, platformIdentifier: nil)
        let app = ComputerUseApplicationIdentity(bundleIdentifier: "com.apple.Safari", processIdentifier: 91,
            launchGeneration: 1, codeIdentity: code)!
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true }, actionPerformer: { _ in effects += 1 },
            screenProvider: {
                let color = screenChanged ? CIColor(red: 0, green: 0, blue: 1, alpha: 1)
                    : CIColor(red: 0, green: 0, blue: 0, alpha: 1)
                return .init(image: CIImage(color: color).cropped(to: display), displayBounds: display,
                    frontmostWindowBounds: window)
            }, transientSystemOverlayProvider: { _ in false }, accessibilityContextProvider: { _ in "" },
            authenticationContextProvider: { nil }, screenCaptureConsentContextProvider: { nil },
            planningAccessibilityIdentityProvider: { "safari-window" },
            frontmostApplicationIdentityProvider: { app }, frontmostApplicationProvider: { "Safari" })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposals += 1
            screenChanged.toggle()
            return .init(response: "Still uploading.", action: .reportCompletion("Verified upload"))
        }, surfaceScopeCheck: { _ in
            guard scopeValid else { throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged }
        }, completeCheck: { _ in
            completionChecks += 1
            return true
        })
        let goal = "Upload the selected presentation and verify it finished uploading."
        let unstable = try await executor.execute(taskID: "unstable-completion-observations", prompt: goal,
            trustedUserPrompt: goal, tools: tools, progress: { _ in })
        XCTAssertEqual(unstable, .userInterventionRequired("I couldn't verify the next desktop action. Complete this step, then choose Resume."))
        XCTAssertEqual(proposals, 3, "Repeated stale completion claims must hit the existing rejection bound")
        XCTAssertEqual(completionChecks, 0)
        XCTAssertEqual(effects, 0)

        let scopeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scopeDirectory) }
        scopeValid = false
        let scopeLostExecutor = try ComputerUseDesktopExecutor(journalDirectory: scopeDirectory, propose: { _ in
            XCTFail("A lost scoped window must fail before asking for completion")
            return .init(response: "Done", action: .reportCompletion("Verified upload"))
        }, surfaceScopeCheck: { _ in
            guard scopeValid else { throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged }
        }, completeCheck: { _ in
            completionChecks += 1
            return true
        })
        do {
            _ = try await scopeLostExecutor.execute(taskID: "scope-loss-completion", prompt: goal,
                trustedUserPrompt: goal, tools: tools, progress: { _ in })
            XCTFail("Loss of the scoped window must not accept a completion claim")
        } catch {
            XCTAssertEqual(error as? ComputerUseDesktopExecutor.Failure, .scopedSurfaceChanged)
            XCTAssertEqual(effects, 0)
        }
    }

    func testScopedDesktopRequiresCompletionValidatorAcceptance() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var proposals = 0, checks = 0
        let tools = desktopTestTools()
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            proposals += 1
            if proposals == 1 { return .init(response: "candidate", action: .reportCompletion("Done")) }
            return .init(response: "handoff", decision: .handoff("Please inspect the page."))
        }, surfaceScopeCheck: { _ in }, completeCheck: { answer in
            checks += 1
            XCTAssertEqual(answer, "Done")
            return false
        })
        let result = try await executor.execute(taskID: "completion-candidate", prompt: "Finish", trustedUserPrompt: "Finish", tools: tools, progress: { _ in })
        XCTAssertEqual(result, .userInterventionRequired("Please inspect the page."))
        XCTAssertEqual(proposals, 2)
        XCTAssertEqual(checks, 1)
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
            Set(["key", "type", "left_click", "right_click", "double_click", "triple_click", "scroll", "hscroll", "wait", "pause_and_memorize_fact", "ask_user_question", "terminate"]))
        XCTAssertEqual(function["name"] as? String, "computer_use")
        XCTAssertTrue(prompt.contains("macOS")); XCTAssertTrue(prompt.contains("Command"))
        XCTAssertTrue(prompt.contains("<tool_call>"))
        XCTAssertEqual(try system(.init(goal: goal, screenshotPNG: image.png)), try ComputerUseFaraModel.browserSystemPrompt())
        var mixed = native; mixed.currentURL = URL(string: "https://example.com")
        XCTAssertThrowsError(try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: mixed))
        mixed = native; mixed.userResponse = "An answer from another surface"
        XCTAssertThrowsError(try ComputerUseFaraModel.makeRequest(endpoint: endpoint, input: mixed))
        XCTAssertThrowsError(try ComputerUseHoloModel.makeRequest(endpoint: endpoint, input: mixed))
        XCTAssertThrowsError(try ComputerUseGUIOwlModel.makeRequest(endpoint: endpoint, input: mixed))
    }

    func testNativePointerIgnoresBackgroundBeyondItsWindowButRejectsChangedTargetContext() async throws {
        let display = CGRect(x: 0, y: 0, width: 640, height: 400)
        let window = CGRect(x: 100, y: 50, width: 300, height: 250)
        for (name, target, change, admitted) in [
            ("left background", CGRect(x: 100, y: 100, width: 300, height: 100), CGRect(x: 90, y: 110, width: 9, height: 40), true),
            ("right background", CGRect(x: 100, y: 100, width: 300, height: 100), CGRect(x: 401, y: 110, width: 9, height: 40), true),
            ("top background", CGRect(x: 150, y: 50, width: 100, height: 250), CGRect(x: 160, y: 40, width: 40, height: 9), true),
            ("bottom background", CGRect(x: 150, y: 50, width: 100, height: 250), CGRect(x: 160, y: 301, width: 40, height: 9), true),
            ("target content", CGRect(x: 100, y: 100, width: 300, height: 100), CGRect(x: 160, y: 120, width: 10, height: 20), false),
            ("surrounding context", CGRect(x: 100, y: 100, width: 300, height: 100), CGRect(x: 160, y: 70, width: 40, height: 10), false)
        ] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var changed = false, calls = 0, effects = 0
            var rejectionPairs: [(ComputerUseDesktopImage, ComputerUseDesktopImage, ComputerUsePredictedAction?, [String: String])] = []
            let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { true },
                approvalTargetProvider: { _ in .init(context: "AXTextField Query", applicationID: "fixture", accessibilityIdentity: "editor", frame: target) },
                actionPerformer: { _ in effects += 1 }, screenProvider: {
                    let base = CIImage(color: .white).cropped(to: display)
                    let local = CGRect(x: change.minX, y: display.maxY - change.maxY, width: change.width, height: change.height)
                    let image = changed ? CIImage(color: .blue).cropped(to: local).composited(over: base) : base
                    return .init(image: image, displayBounds: display, frontmostWindowBounds: window)
                }, transientSystemOverlayProvider: { _ in false }, accessibilityContextProvider: { _ in "AXTextField Query" },
                authenticationContextProvider: { nil }, screenCaptureConsentContextProvider: { nil },
                planningAccessibilityIdentityProvider: { "editor" }, frontmostApplicationProvider: { "Fixture" })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
                calls += 1
                if calls == 1 {
                    changed = true
                    return .init(response: "click", action: .pointer(.leftClick,
                        .init(x: target.midX / display.width * 1000, y: target.midY / display.height * 1000)))
                }
                XCTAssertEqual(calls, 2, name); XCTAssertEqual(input.actionError == nil, admitted, name)
                return .init(response: "done", action: .reportCompletion("Checked"))
            }, revalidationFailureObserver: { expected, fresh, action, diagnostic in
                rejectionPairs.append((expected, fresh, action, diagnostic))
            })
            let result = try await executor.execute(taskID: "pointer-region", prompt: "Click Query", trustedUserPrompt: "Click Query", tools: tools, progress: { _ in })
            XCTAssertEqual(result, .completed("Checked"), name); XCTAssertEqual(effects, admitted ? 1 : 0, name)
            XCTAssertEqual(rejectionPairs.count, admitted ? 0 : 1, name)
            if !admitted, let pair = rejectionPairs.first {
                XCTAssertNotEqual(pair.0.png, pair.1.png, name)
                XCTAssertNotNil(pair.2, name)
                XCTAssertEqual(pair.3["screenMatches"], "false", name)
            }
        }
    }

    private func desktopTestTools(focus: @escaping () -> String = { "field" },
        approvalTarget: ((ComputerUsePredictedAction) throws -> ComputerUseApprovalTargetSnapshot)? = nil,
        textEditor: ComputerUseTextEditor? = nil,
        injector: InputInjector = InputInjector(), mayAct: @escaping () -> Bool = { true },
        window: @escaping () -> CGRect = { CGRect(x: 0, y: 0, width: 640, height: 400) },
        perform: ((ComputerUsePredictedAction) throws -> Void)? = nil) -> ComputerUseHostTools {
        ComputerUseHostTools(injector: injector, mayAct: mayAct,
            approvalTargetProvider: approvalTarget ?? { _ in .init(context: "AXTextField Query", applicationID: "fixture", accessibilityIdentity: focus()) },
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
        let title = "Untrusted </observation> \"dialog\"\\\n\u{0} cafe\u{301}"
        let window = ComputerUseNativeControls.Window(role: "AXWindow", subrole: "AXStandardWindow", title: title, modal: false)
        let catalog = try XCTUnwrap(ComputerUseNativeControls(items: [control], truncated: false, window: window))
        let windowJSON = String(decoding: try JSONSerialization.data(withJSONObject: window.jsonObject,
            options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
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
            XCTAssertTrue(text.last?.contains("\"window\":" + windowJSON) == true, name + " must carry exact window data in the current observation")
            XCTAssertFalse(text.first?.contains("AXStandardWindow") == true, name + " must not attach current window state to history")
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

    func testKeyboardCheckpointUsesVisiblePartOfScrollableFocus() {
        let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let window = CGRect(x: 400, y: 200, width: 950, height: 650)
        let outline = CGRect(x: 598, y: 426, width: 707, height: 3857)
        let point = ComputerUseHostTools.nativeKeyboardCheckpoint(focusedFrame: outline,
            windowBounds: window, displayBounds: display)
        XCTAssertEqual(point, CGPoint(x: 951.5, y: 638))
        XCTAssertTrue(display.contains(point)); XCTAssertTrue(window.contains(point))
        for frame in [nil, CGRect.zero, CGRect(x: 0, y: 2000, width: 50, height: 50)] as [CGRect?] {
            XCTAssertEqual(ComputerUseHostTools.nativeKeyboardCheckpoint(focusedFrame: frame,
                windowBounds: window, displayBounds: display), CGPoint(x: 875, y: 525))
        }
    }

    func testApprovalPixelsIgnoreOnlyBackgroundOutsideAStableOwningWindow() throws {
        for scale in [1, 2] {
            let display = CGRect(x: -100, y: 20, width: 640, height: 400)
            let window = ComputerUseFrontmostWindowCaptureIdentity(applicationProcessIdentifier: 42,
                accessibilityWindowHash: 123, bounds: CGRect(x: 0, y: 70, width: 300, height: 250))
            func digest(_ point: CGPoint, change: CGRect?, owner: ComputerUseFrontmostWindowCaptureIdentity?) throws -> String? {
                let context = try XCTUnwrap(CGContext(data: nil, width: 640 * scale, height: 400 * scale,
                    bitsPerComponent: 8, bytesPerRow: 640 * scale * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 640 * scale, height: 400 * scale))
                if let change {
                    context.setFillColor(CGColor(gray: 0, alpha: 1))
                    context.fill(CGRect(x: (change.minX - display.minX) * CGFloat(scale),
                        y: (display.maxY - change.maxY) * CGFloat(scale), width: change.width * CGFloat(scale), height: change.height * CGFloat(scale)))
                }
                return try ComputerUseHostTools.approvalVisualDigest(around: [point], image: XCTUnwrap(context.makeImage()),
                    displayBounds: display, window: owner)
            }
            for (point, outside, inside) in [
                (CGPoint(x: 10, y: 150), CGRect(x: -8, y: 145, width: 7, height: 10), CGRect(x: 1, y: 145, width: 7, height: 10)),
                (CGPoint(x: 290, y: 150), CGRect(x: 301, y: 145, width: 7, height: 10), CGRect(x: 292, y: 145, width: 7, height: 10)),
                (CGPoint(x: 150, y: 80), CGRect(x: 145, y: 62, width: 10, height: 7), CGRect(x: 145, y: 71, width: 10, height: 7)),
                (CGPoint(x: 150, y: 310), CGRect(x: 145, y: 321, width: 10, height: 7), CGRect(x: 145, y: 312, width: 10, height: 7))
            ] {
                let base = try digest(point, change: nil, owner: window)
                XCTAssertEqual(try digest(point, change: outside, owner: window), base, "Outside window at \(scale)x, \(point)")
                XCTAssertNotEqual(try digest(point, change: inside, owner: window), base, "Changed target must invalidate approval")
                XCTAssertNotEqual(try digest(point, change: outside, owner: nil), try digest(point, change: nil, owner: nil), "Unknown owner must retain display pixels")
            }
            let outsidePoint = CGPoint(x: -10, y: 150), outsideChange = CGRect(x: -12, y: 145, width: 7, height: 10)
            XCTAssertNotEqual(try digest(outsidePoint, change: outsideChange, owner: window), try digest(outsidePoint, change: nil, owner: window),
                "A target outside the frontmost window must retain its display pixels")
            let point = CGPoint(x: 150, y: 150), base = try digest(point, change: nil, owner: window)
            for changed in [
                ComputerUseFrontmostWindowCaptureIdentity(applicationProcessIdentifier: 43, accessibilityWindowHash: 123, bounds: window.bounds),
                .init(applicationProcessIdentifier: 42, accessibilityWindowHash: 124, bounds: window.bounds),
                .init(applicationProcessIdentifier: 42, accessibilityWindowHash: 123, bounds: window.bounds.offsetBy(dx: 1, dy: 0))
            ] {
                XCTAssertNotEqual(try digest(point, change: nil, owner: changed), base, "Identical pixels cannot revive a different owning window")
            }
            XCTAssertNotEqual(try digest(point, change: nil, owner: nil), base, "Lost window authority must invalidate approval")
        }
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

    func testNativeApprovedSuccessClearsThePriorErrorAndResetsConsecutiveRejections() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var effects = 0, calls = 0
        let tools = desktopTestTools(perform: { _ in effects += 1 })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
            calls += 1
            XCTAssertEqual(input.goal, "Continue the same task")
            switch calls {
            case 1: return .init(response: "unsupported before approval", decision: .unsupported)
            case 2:
                XCTAssertNotNil(input.actionError)
                return .init(response: "approved Return", action: .key(["Return"]))
            case 3:
                XCTAssertNil(input.actionError, "A verified approved effect must not be reported as the previous failure")
                XCTAssertEqual(input.history.map(\.response), ["unsupported before approval", "approved Return"])
                return .init(response: "first rejection after success", decision: .unsupported)
            case 4: return .init(response: "second rejection after success", decision: .unsupported)
            case 5: return .init(response: "done", action: .reportCompletion("Done"))
            default: throw ComputerUseDesktopExecutor.Failure.stepLimit
            }
        })
        let pending = try await executor.execute(taskID: "approval-recovery", prompt: "Continue the same task",
            trustedUserPrompt: "Continue the same task", tools: tools, progress: { _ in })
        guard case .approvalRequired(_, let action, let token) = pending else { return XCTFail("Expected native approval") }
        try await executor.performApprovedVisualAction(token, action: action,
            fingerprint: tools.prepareNativeActionFingerprint(for: action), tools: tools, willBeginEffect: {})
        let result = try await executor.continueAfterApprovedVisualAction(token, action: action, tools: tools, progress: { _ in })
        XCTAssertEqual(result, .completed("Done"), "Only consecutive failures may exhaust the rejection allowance")
        XCTAssertEqual(calls, 5); XCTAssertEqual(effects, 1)
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

    func testNativeDesktopUnsentTypePreconditionFailureRetiresAndReplans() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = ComputerUseTextSnapshot(targetID: "address-field", value: "old value",
            selection: NSRange(location: 9, length: 0), isEditable: true, isSecure: false)
        let changed = ComputerUseTextSnapshot(targetID: "address-field", value: "fresh value",
            selection: NSRange(location: 11, length: 0), isEditable: true, isSecure: false)
        var current = initial, setterPreconditions = 0, postedText = 0, proposals = 0
        let editor = ComputerUseTextEditor(read: { current }, select: { _, _ in
            XCTFail("Insert mode must not change the selection before typing")
            return false
        }, replaceSelectedText: { _, expected in
            XCTAssertEqual(current, expected)
            setterPreconditions += 1
            current = changed // Simulate the target changing before its AX write.
            throw ComputerUseTextEditError.preconditionChanged
        }, postUnicode: { _, _ in
            postedText += 1
            XCTFail("A precondition rejection must not post Unicode input")
        }, mayAct: { true })
        let tools = desktopTestTools(textEditor: editor)
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
            proposals += 1
            XCTAssertEqual(input.goal, "Type the requested text")
            if proposals == 1 {
                XCTAssertEqual(input.focusedTextState?.valuePrefix, "old value")
                return .init(response: "stale type proposal", action: .typeText("Tokyo"))
            }
            XCTAssertEqual(proposals, 2)
            XCTAssertEqual(input.history.count, 1)
            XCTAssertEqual(input.history.first?.response, "stale type proposal")
            XCTAssertEqual(input.history.first?.action, .typeText("Tokyo"))
            XCTAssertTrue(input.actionError?.contains("No mouse or keyboard input was sent") == true)
            XCTAssertTrue(input.actionError?.contains("fresh action") == true)
            XCTAssertEqual(input.focusedTextState?.valuePrefix, "fresh value",
                "The retry proposal must observe the changed current field")
            return .init(response: "handoff after fresh observation", decision: .handoff("Review the current field."))
        })

        let result = try await executor.execute(taskID: "unsent-type", prompt: "Type the requested text",
            trustedUserPrompt: "Type the requested text", tools: tools, progress: { _ in })
        XCTAssertEqual(result, .userInterventionRequired("Review the current field."))
        XCTAssertEqual(proposals, 2)
        XCTAssertEqual(setterPreconditions, 1)
        XCTAssertEqual(postedText, 0)

        let journals = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(ComputerUseTaskJournal.self, from: Data(contentsOf: $0)) }
        let retired = journals.filter { $0.retirementDigest != nil }
        XCTAssertEqual(retired.count, 1)
        XCTAssertEqual(try XCTUnwrap(retired.first).statuses, [.attempted],
            "Proven-unsent remains attempted and is tombstoned, never mislabeled verified")
        XCTAssertFalse(journals.contains { $0.statuses.contains(.uncertain) }, "A proven-unsent text attempt is not an uncertain effect")
        XCTAssertFalse(journals.contains { $0.statuses.contains(.verified) }, "No input returned successfully")
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

    func testApprovalTargetChangedBeforeDispatchBecomesRejectedActionFeedback() async throws {
        for failureStage in ["preparation", "dispatch"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var approvalQueries = 0, identity = "observed-target", calls = 0, effects = 0
            let tools = desktopTestTools(approvalTarget: { _ in
                approvalQueries += 1
                if failureStage == "preparation", approvalQueries == 1 {
                    throw ComputerUseHostTools.ToolError.approvalTargetChanged
                }
                return .init(context: "AXTextField Query", applicationID: "fixture", accessibilityIdentity: identity)
            }, perform: { _ in effects += 1 })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { input in
                calls += 1
                if calls == 1 { return .init(response: "tab", action: .key(["Tab"])) }
                XCTAssertEqual(input.history.count, 1)
                XCTAssertEqual(input.history.first?.action, .key(["Tab"]))
                XCTAssertTrue(input.actionError?.contains("No mouse or keyboard input was sent") == true)
                return .init(response: "handoff", decision: .handoff("Review the current field."))
            })
            let result = try await executor.execute(taskID: "approval-target-\(failureStage)", prompt: "Continue",
                trustedUserPrompt: "Continue", tools: tools, progress: { message in
                    if failureStage == "dispatch", message == "Using the desktop…" { identity = "changed-target" }
                })
            XCTAssertEqual(result, .userInterventionRequired("Review the current field."))
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(effects, 0)
            XCTAssertEqual(executor.lastRevalidationDiagnostic["blockedAt"],
                failureStage == "preparation" ? "approval-fingerprint-preparation" : "approval-fingerprint-dispatch")
        }
    }

    func testApprovalTargetChangedAfterDispatchRemainsUncertainAndCannotReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0, effects = 0
        let tools = desktopTestTools(perform: { _ in
            effects += 1
            throw ComputerUseHostTools.ToolError.approvalTargetChanged
        })
        let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
            calls += 1
            return .init(response: "tab", action: .key(["Tab"]))
        })
        do {
            _ = try await executor.execute(taskID: "approval-target-after-effect", prompt: "Continue",
                trustedUserPrompt: "Continue", tools: tools, progress: { _ in })
            XCTFail("A target change after dispatch must remain uncertain")
        } catch ComputerUseHostTools.ToolError.approvalTargetChanged {
        }
        let resumed = try await executor.execute(taskID: "approval-target-after-effect", prompt: "Continue",
            trustedUserPrompt: "Continue", tools: tools, progress: { _ in })
        guard case .unableToComplete = resumed else { return XCTFail("An uncertain target change must not be replayed") }
        XCTAssertEqual(effects, 1)
        XCTAssertEqual(calls, 1)
    }

    func testSuccessfulDispatchObserverRunsOnceOnlyAfterInputReturnsVerified() async throws {
        // Ordinary native dispatch reports only after its verified journal save.
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var calls = 0, effects = 0
            var observed: [ComputerUsePredictedAction] = []
            let tools = desktopTestTools(perform: { _ in effects += 1 })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
                calls += 1
                if calls == 1 { return .init(response: "tab", action: .key(["Tab"])) }
                return .init(response: "handoff", decision: .handoff("Review the current field."))
            }, onSuccessfulDispatch: { observed.append($0) })
            let result = try await executor.execute(taskID: "observer-ordinary", prompt: "Continue",
                trustedUserPrompt: "Continue", tools: tools, progress: { _ in })
            XCTAssertEqual(result, .userInterventionRequired("Review the current field."))
            XCTAssertEqual(effects, 1)
            XCTAssertEqual(observed, [.key(usage: 0x2B, modifiers: 0)])
        }

        // An approval request alone reports no dispatch. A successful approved
        // dispatch reports once; retrying the same continuation cannot replay it.
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var effects = 0
            var observed: [ComputerUsePredictedAction] = []
            let tools = desktopTestTools(perform: { _ in effects += 1 })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
                .init(response: "return", action: .key(["Return"]))
            }, onSuccessfulDispatch: { observed.append($0) })
            let pending = try await executor.execute(taskID: "observer-approved", prompt: "Submit",
                trustedUserPrompt: "Submit", tools: tools, progress: { _ in })
            guard case .approvalRequired(_, let action, let continuation) = pending else {
                return XCTFail("Expected pending approval")
            }
            XCTAssertTrue(observed.isEmpty, "Approval pending is not evidence that input was dispatched")
            let fingerprint = try tools.prepareNativeActionFingerprint(for: action)
            try await executor.performApprovedVisualAction(continuation, action: action, fingerprint: fingerprint,
                tools: tools, willBeginEffect: {})
            XCTAssertEqual(effects, 1)
            XCTAssertEqual(observed, [.key(usage: 0x28, modifiers: 0)])
            do {
                try await executor.performApprovedVisualAction(continuation, action: action, fingerprint: fingerprint,
                    tools: tools, willBeginEffect: {})
                XCTFail("A completed approval continuation must not replay input")
            } catch {}
            XCTAssertEqual(effects, 1)
            XCTAssertEqual(observed, [.key(usage: 0x28, modifiers: 0)])
        }

        // Rejected-before-input and throwing-after-begin dispatches never report
        // a successful completion; the latter remains uncertain and cannot replay.
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var focus = "first", calls = 0, effects = 0
            var observed: [ComputerUsePredictedAction] = []
            let tools = desktopTestTools(focus: { focus }, perform: { _ in effects += 1 })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
                calls += 1
                if calls == 1 { focus = "changed"; return .init(response: "tab", action: .key(["Tab"])) }
                XCTAssertTrue(observed.isEmpty)
                return .init(response: "handoff", decision: .handoff("Review the current field."))
            }, onSuccessfulDispatch: { observed.append($0) })
            _ = try await executor.execute(taskID: "observer-rejected", prompt: "Continue",
                trustedUserPrompt: "Continue", tools: tools, progress: { _ in })
            XCTAssertEqual(effects, 0)
            XCTAssertTrue(observed.isEmpty)
        }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var calls = 0, effects = 0
            var observed: [ComputerUsePredictedAction] = []
            let tools = desktopTestTools(perform: { _ in
                effects += 1
                throw ComputerUseHostTools.ToolError.approvalTargetChanged
            })
            let executor = try ComputerUseDesktopExecutor(journalDirectory: directory, propose: { _ in
                calls += 1
                return .init(response: "tab", action: .key(["Tab"]))
            }, onSuccessfulDispatch: { observed.append($0) })
            do {
                _ = try await executor.execute(taskID: "observer-uncertain", prompt: "Continue",
                    trustedUserPrompt: "Continue", tools: tools, progress: { _ in })
                XCTFail("A post-input dispatch error must remain uncertain")
            } catch ComputerUseHostTools.ToolError.approvalTargetChanged {}
            let resumed = try await executor.execute(taskID: "observer-uncertain", prompt: "Continue",
                trustedUserPrompt: "Continue", tools: tools, progress: { _ in })
            guard case .unableToComplete = resumed else { return XCTFail("Uncertain input must not replay") }
            XCTAssertEqual(effects, 1)
            XCTAssertEqual(calls, 1)
            XCTAssertTrue(observed.isEmpty, "An uncertain effect is not a successful dispatch receipt")
        }
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
                XCTAssertTrue(rejectedFeedback?.contains("No mouse or keyboard input was sent") == true)
                XCTAssertTrue(rejectedFeedback?.localizedCaseInsensitiveContains("waiting will not complete the rejected action") == true)
                XCTAssertEqual(input.history.count, 1)
                XCTAssertNil(input.history.first?.actionError)
                return .init(response: "wait", action: .wait(0))
            case 3:
                XCTAssertEqual(input.actionError, rejectedFeedback,
                    "A passive wait must not clear an unresolved rejected-action result")
                XCTAssertEqual(input.history.count, 2)
                XCTAssertEqual(input.history[1].actionError, rejectedFeedback,
                    "The observation after rejection must retain that result when it becomes history")
                return .init(response: "remember", action: .remember("The rejected input was not sent"))
            case 4:
                XCTAssertEqual(input.actionError, rejectedFeedback,
                    "A passive remember step must not clear an unresolved rejected-action result")
                return .init(response: "", decision: .refreshObservation, includeInModelHistory: false)
            case 5:
                XCTAssertEqual(input.actionError, rejectedFeedback,
                    "Refreshing a specialist's screenshot must preserve unresolved rejection feedback")
                XCTAssertEqual(input.history.count, 3, "A host observation refresh is not a model action")
                XCTAssertEqual(effects, 0, "Refreshing the screen must not replay the rejected input")
                return .init(response: "fresh key", action: .key(["a"]))
            case 6:
                XCTAssertNil(input.actionError, "A successfully dispatched input resolves the prior rejection")
                XCTAssertEqual(input.history.last?.action, .key(["a"]))
                return .init(response: "done", action: .reportCompletion("Done"))
            default: throw ComputerUseDesktopExecutor.Failure.stepLimit
            }
        })
        let result = try await executor.execute(taskID: "feedback", prompt: "Use the current field", trustedUserPrompt: "Use the current field", tools: tools, progress: { _ in })
        XCTAssertEqual(result, .completed("Done")); XCTAssertEqual(calls, 6); XCTAssertEqual(effects, 1)
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

    func testNativePointerPixelsTolerateOnlyAProvenEditorCaretAndPreserveWindowContext() throws {
        let display = CGRect(x: 0, y: 0, width: 640, height: 400)
        let window = CGRect(x: 100, y: 50, width: 300, height: 250)
        let field = CGRect(x: 100, y: 100, width: 300, height: 200)
        func image(changing rect: CGRect? = nil) throws -> ComputerUseDesktopImage {
            let base = CIImage(color: .white).cropped(to: display)
            let image: CIImage
            if let rect {
                let local = CGRect(x: rect.minX, y: display.maxY - rect.maxY, width: rect.width, height: rect.height)
                image = CIImage(color: .blue).cropped(to: local).composited(over: base)
            } else { image = base }
            return try .init(observation: .init(image: image, displayBounds: display))
        }
        let before = try image(), caret = try image(changing: CGRect(x: 130, y: 130, width: 1, height: 16))
        XCTAssertTrue(try before.matchesPointerPixels(of: caret, window: window, target: field, unchangedFocusedField: field))
        XCTAssertFalse(try before.matchesPointerPixels(of: caret, window: window, target: field), "No editor proof means no caret exception")
        XCTAssertFalse(try before.matchesPointerPixels(of: caret, window: window, target: field,
            unchangedFocusedField: CGRect(x: 110, y: 55, width: 200, height: 20)), "A noncontained field cannot authorize the exception")
        for change in [CGRect(x: 130, y: 130, width: 8, height: 16), CGRect(x: 130, y: 70, width: 1, height: 16),
                       CGRect(x: 130, y: 150, width: 20, height: 1)] {
            XCTAssertFalse(try before.matchesPointerPixels(of: image(changing: change), window: window, target: field,
                unchangedFocusedField: field), "Text, window context and horizontal paint changes remain significant: \(change)")
        }
        for change in [CGRect(x: 90, y: 110, width: 9, height: 40), CGRect(x: 401, y: 110, width: 9, height: 40)] {
            XCTAssertTrue(try before.matchesPointerPixels(of: image(changing: change), window: window, target: field), "Outside-window context cannot invalidate an in-window target")
            XCTAssertTrue(try before.matchesPointerPixels(of: image(changing: change), window: window, target: field, unchangedFocusedField: field))
        }
    }

    func testFocusedEditorPointerUsesSameLocalContextAsOrdinaryPointer() throws {
        let display = CGRect(x: 0, y: 0, width: 640, height: 400)
        let window = CGRect(x: 50, y: 40, width: 500, height: 320)
        let field = CGRect(x: 100, y: 100, width: 100, height: 30)
        func image(changing rect: CGRect? = nil) throws -> ComputerUseDesktopImage {
            let base = CIImage(color: .white).cropped(to: display)
            let result: CIImage
            if let rect {
                let local = CGRect(x: rect.minX, y: display.maxY - rect.maxY, width: rect.width, height: rect.height)
                result = CIImage(color: .blue).cropped(to: local).composited(over: base)
            } else { result = base }
            return try .init(observation: .init(image: result, displayBounds: display))
        }
        let before = try image()
        let unrelatedWindowChange = try image(changing: CGRect(x: 350, y: 200, width: 1, height: 1))
        XCTAssertTrue(try before.matchesPointerPixels(of: unrelatedWindowChange, window: window, target: field),
            "Ordinary pointers ignore pixels outside their target context")
        XCTAssertTrue(try before.matchesPointerPixels(of: unrelatedWindowChange, window: window, target: field,
            unchangedFocusedField: field),
            "An unchanged focused-editor proof should preserve the same local target policy")
        let changedTargetContext = try image(changing: CGRect(x: 110, y: 110, width: 1, height: 1))
        XCTAssertFalse(try before.matchesPointerPixels(of: changedTargetContext, window: window, target: field,
            unchangedFocusedField: field), "Changes inside the target context must still reject the pointer")
    }

    func testFocusedEditorCaretExceptionUsesContainedFieldWhenPointerTargetIsLarger() throws {
        let display = CGRect(x: 0, y: 0, width: 640, height: 400)
        let window = CGRect(x: 50, y: 40, width: 500, height: 320)
        let field = CGRect(x: 100, y: 100, width: 300, height: 30)
        let target = CGRect(x: 96, y: 96, width: 308, height: 38)
        func image(changing rect: CGRect? = nil) throws -> ComputerUseDesktopImage {
            let base = CIImage(color: .white).cropped(to: display)
            let result: CIImage
            if let rect {
                let local = CGRect(x: rect.minX, y: display.maxY - rect.maxY, width: rect.width, height: rect.height)
                result = CIImage(color: .blue).cropped(to: local).composited(over: base)
            } else { result = base }
            return try .init(observation: .init(image: result, displayBounds: display))
        }

        let before = try image()
        let caret = try image(changing: CGRect(x: 130, y: 106, width: 1, height: 18))
        XCTAssertTrue(target.contains(CGPoint(x: 99, y: 110)), "The click can be in the AX target but just outside the text frame")
        XCTAssertFalse(field.contains(CGPoint(x: 99, y: 110)))
        XCTAssertTrue(try before.matchesPointerPixels(of: caret, window: window, target: target,
            unchangedFocusedField: field), "A larger pointer target should use the contained, unchanged editor bounds for the caret-only exception")

        let caretOutsideField = try image(changing: CGRect(x: 97, y: 106, width: 1, height: 18))
        XCTAssertFalse(try before.matchesPointerPixels(of: caretOutsideField, window: window, target: target,
            unchangedFocusedField: field), "Caret paint outside the actual focused field must still reject")

        let nonContainingTarget = CGRect(x: 102, y: 96, width: 308, height: 38)
        XCTAssertFalse(try before.matchesPointerPixels(of: caret, window: window, target: nonContainingTarget,
            unchangedFocusedField: field), "A pointer target that does not contain the focused field cannot borrow its caret exception")
    }

    func testFinalDispatchCaretEvidenceMatchesOnlyWhenItsPixelsAndSnapshotPermitIt() throws {
        let action = ComputerUsePredictedAction.key(usage: 0x28, modifiers: 0)
        let window = CGRect(x: 50, y: 40, width: 500, height: 320)
        let field = CGRect(x: 100, y: 100, width: 300, height: 30)
        let base = try finalDispatchImage()
        let caret = try finalDispatchImage(changes: [(130, 110, 0, 0, 0, 255), (130, 111, 0, 0, 0, 255),
            (130, 112, 0, 0, 0, 255), (130, 113, 0, 0, 0, 255), (130, 114, 0, 0, 0, 255),
            (130, 115, 0, 0, 0, 255), (130, 116, 0, 0, 0, 255), (130, 117, 0, 0, 0, 255),
            (130, 118, 0, 0, 0, 255), (130, 119, 0, 0, 0, 255), (130, 120, 0, 0, 0, 255),
            (130, 121, 0, 0, 0, 255)])
        XCTAssertTrue(try base.matchesInsertionPointPixels(of: caret, window: window, field: field))

        let text = ComputerUseTextSnapshot(targetID: "field", value: "Gmail address",
            selection: NSRange(location: 13, length: 0), isEditable: true, isSecure: false)
        let signedApp = try finalDispatchApplicationIdentity()
        let identity = ComputerUseFrontmostWindowCaptureIdentity(applicationProcessIdentifier: 7,
            accessibilityWindowHash: 9, bounds: window)
        let beforeEvidence = ComputerUseKeyboardCaretEvidence(applicationIdentity: signedApp, window: identity,
            text: text, frame: field, image: base)
        let afterEvidence = ComputerUseKeyboardCaretEvidence(applicationIdentity: signedApp, window: identity,
            text: text, frame: field, image: caret)
        let before = ComputerUseApprovalFingerprint(action: action, applicationID: signedApp.bundleIdentifier,
            accessibilityIdentity: "focused-field", visualDigest: "before", keyboardCaretEvidence: beforeEvidence)
        let after = ComputerUseApprovalFingerprint(action: action, applicationID: signedApp.bundleIdentifier,
            accessibilityIdentity: "focused-field", visualDigest: "after", keyboardCaretEvidence: afterEvidence)
        XCTAssertNotEqual(before, after, "Legacy equality must remain exact over its original four fields")
        XCTAssertTrue(before.matchesForFinalDispatch(after), "A proven caret-only repaint may qualify for the final keyboard check")

        let sameLegacyFieldsDifferentEvidence = ComputerUseApprovalFingerprint(action: action, applicationID: signedApp.bundleIdentifier,
            accessibilityIdentity: "focused-field", visualDigest: "before",
            keyboardCaretEvidence: ComputerUseKeyboardCaretEvidence(applicationIdentity: signedApp, window: identity,
                text: .init(targetID: "field", value: "different text", selection: text.selection,
                    isEditable: true, isSecure: false), frame: field, image: base))
        XCTAssertFalse(before.matchesForFinalDispatch(sameLegacyFieldsDifferentEvidence),
            "Evidence-bearing fingerprints must compare the editor snapshot even when the legacy fields match")
    }

    func testFinalDispatchCaretComparisonAllowsOnlyOneLevelRGBNoiseOutsideTheCaret() throws {
        let action = ComputerUsePredictedAction.key(usage: 0x28, modifiers: 0)
        let window = CGRect(x: 50, y: 40, width: 500, height: 320)
        let field = CGRect(x: 100, y: 100, width: 300, height: 30)
        let base = try finalDispatchImage()
        let noisyCaret = try finalDispatchImage(changes: [
            (130, 110, 0, 0, 0, 255), (130, 111, 0, 0, 0, 255), (130, 112, 0, 0, 0, 255),
            (130, 113, 0, 0, 0, 255), (130, 114, 0, 0, 0, 255), (130, 115, 0, 0, 0, 255),
            (130, 116, 0, 0, 0, 255), (130, 117, 0, 0, 0, 255), (130, 118, 0, 0, 0, 255),
            (130, 119, 0, 0, 0, 255), (130, 120, 0, 0, 0, 255), (130, 121, 0, 0, 0, 255),
            (450, 250, 129, 127, 129, 255)])
        XCTAssertTrue(try base.matchesInsertionPointPixels(of: noisyCaret, window: window, field: field),
            "A one-level RGB capture fluctuation outside the caret should pass the bounded helper")

        let signedApp = try finalDispatchApplicationIdentity()
        let identity = ComputerUseFrontmostWindowCaptureIdentity(applicationProcessIdentifier: 7,
            accessibilityWindowHash: 9, bounds: window)
        let text = ComputerUseTextSnapshot(targetID: "field", value: "unchanged", selection: NSRange(location: 9, length: 0),
            isEditable: true, isSecure: false)
        func fingerprint(image: ComputerUseDesktopImage, digest: String) -> ComputerUseApprovalFingerprint {
            let evidence = ComputerUseKeyboardCaretEvidence(applicationIdentity: signedApp, window: identity,
                text: text, frame: field, image: image)
            return .init(action: action, applicationID: signedApp.bundleIdentifier, accessibilityIdentity: "focused-field",
                visualDigest: digest, keyboardCaretEvidence: evidence)
        }
        XCTAssertTrue(fingerprint(image: base, digest: "before").matchesForFinalDispatch(
            fingerprint(image: noisyCaret, digest: "after")))
    }

    func testFinalDispatchCaretComparisonRejectsLargerRGBAndAlphaChanges() throws {
        let action = ComputerUsePredictedAction.key(usage: 0x28, modifiers: 0)
        let window = CGRect(x: 50, y: 40, width: 500, height: 320)
        let field = CGRect(x: 100, y: 100, width: 300, height: 30)
        let base = try finalDispatchImage()
        let caretAndNoise: [(Int, Int, UInt8, UInt8, UInt8, UInt8)] = [
            (130, 110, 0, 0, 0, 255), (130, 111, 0, 0, 0, 255), (130, 112, 0, 0, 0, 255),
            (130, 113, 0, 0, 0, 255), (130, 114, 0, 0, 0, 255), (130, 115, 0, 0, 0, 255),
            (130, 116, 0, 0, 0, 255), (130, 117, 0, 0, 0, 255), (130, 118, 0, 0, 0, 255),
            (130, 119, 0, 0, 0, 255), (130, 120, 0, 0, 0, 255), (130, 121, 0, 0, 0, 255),
        ]
        let twoLevel = try finalDispatchImage(changes: caretAndNoise + [(450, 250, 130, 128, 128, 255)])
        let alphaNoise = try finalDispatchImage(changes: caretAndNoise + [(450, 250, 127, 127, 127, 254)])
        let inFieldNoise = try finalDispatchImage(changes: caretAndNoise + [(180, 120, 129, 128, 128, 255)])
        let signedApp = try finalDispatchApplicationIdentity()
        let identity = ComputerUseFrontmostWindowCaptureIdentity(applicationProcessIdentifier: 7,
            accessibilityWindowHash: 9, bounds: window)
        let text = ComputerUseTextSnapshot(targetID: "field", value: "unchanged", selection: NSRange(location: 9, length: 0),
            isEditable: true, isSecure: false)
        func fingerprint(image: ComputerUseDesktopImage, digest: String) -> ComputerUseApprovalFingerprint {
            .init(action: action, applicationID: signedApp.bundleIdentifier, accessibilityIdentity: "focused-field", visualDigest: digest,
                keyboardCaretEvidence: .init(applicationIdentity: signedApp, window: identity, text: text, frame: field, image: image))
        }
        for changed in [twoLevel, alphaNoise, inFieldNoise] {
            XCTAssertFalse(fingerprint(image: base, digest: "before").matchesForFinalDispatch(
                fingerprint(image: changed, digest: "after")))
        }
    }

    func testFinalDispatchCaretEvidenceRequiresSameEligibleKeyboardTarget() throws {
        let action = ComputerUsePredictedAction.key(usage: 0x28, modifiers: 0)
        let window = CGRect(x: 50, y: 40, width: 500, height: 320)
        let field = CGRect(x: 100, y: 100, width: 300, height: 30)
        let image = try finalDispatchImage()
        let baseText = ComputerUseTextSnapshot(targetID: "field", value: "unchanged",
            selection: NSRange(location: 9, length: 0), isEditable: true, isSecure: false)
        let signedApp = try finalDispatchApplicationIdentity()
        let identity = ComputerUseFrontmostWindowCaptureIdentity(applicationProcessIdentifier: 7,
            accessibilityWindowHash: 9, bounds: window)
        func fingerprint(action: ComputerUsePredictedAction, evidence: ComputerUseKeyboardCaretEvidence?) -> ComputerUseApprovalFingerprint {
            .init(action: action, applicationID: signedApp.bundleIdentifier, accessibilityIdentity: "focused-field",
                visualDigest: "same", keyboardCaretEvidence: evidence)
        }
        let baseEvidence = ComputerUseKeyboardCaretEvidence(applicationIdentity: signedApp, window: identity,
            text: baseText, frame: field, image: image)
        let original = fingerprint(action: action, evidence: baseEvidence)
        var invalid = [ComputerUseApprovalFingerprint]()
        invalid.append(fingerprint(action: action, evidence: nil))
        invalid.append(fingerprint(action: action, evidence: .init(applicationIdentity: try finalDispatchApplicationIdentity(bundleIdentifier: "org.example.Other"), window: identity, text: baseText, frame: field, image: image)))
        invalid.append(fingerprint(action: action, evidence: .init(applicationIdentity: try finalDispatchApplicationIdentity(processIdentifier: 8),
            window: identity, text: baseText, frame: field, image: image)))
        invalid.append(fingerprint(action: action, evidence: .init(applicationIdentity: signedApp,
            window: .init(applicationProcessIdentifier: 7, accessibilityWindowHash: 10, bounds: window),
            text: baseText, frame: field, image: image)))
        invalid.append(fingerprint(action: action, evidence: .init(applicationIdentity: signedApp,
            window: .init(applicationProcessIdentifier: 8, accessibilityWindowHash: 9, bounds: window),
            text: baseText, frame: field, image: image)))
        invalid.append(fingerprint(action: action, evidence: .init(applicationIdentity: try finalDispatchApplicationIdentity(launchGeneration: 2),
            window: identity, text: baseText, frame: field, image: image)))
        invalid.append(fingerprint(action: action, evidence: .init(applicationIdentity: try finalDispatchApplicationIdentity(teamIdentifier: "OTHER"),
            window: identity, text: baseText, frame: field, image: image)))
        let unsignedApp = try XCTUnwrap(ComputerUseApplicationIdentity(bundleIdentifier: signedApp.bundleIdentifier,
            processIdentifier: signedApp.processIdentifier, launchGeneration: signedApp.launchGeneration))
        invalid.append(fingerprint(action: action, evidence: .init(applicationIdentity: unsignedApp, window: identity,
            text: baseText, frame: field, image: image)))
        invalid.append(fingerprint(action: action, evidence: .init(applicationIdentity: signedApp, window: identity,
            text: baseText, frame: CGRect(x: 499, y: 100, width: 300, height: 30), image: image)))
        invalid.append(fingerprint(action: action, evidence: .init(applicationIdentity: signedApp, window: identity,
            text: baseText, frame: field, image: try finalDispatchImage(displayBounds: CGRect(x: 1, y: 0, width: 640, height: 400)))))
        invalid.append(fingerprint(action: action, evidence: .init(applicationIdentity: signedApp, window: identity,
            text: .init(targetID: "replacement", value: baseText.value, selection: baseText.selection,
                isEditable: true, isSecure: false), frame: field, image: image)))
        invalid.append(fingerprint(action: action, evidence: .init(applicationIdentity: signedApp, window: identity,
            text: .init(targetID: "field", value: "changed", selection: baseText.selection,
                isEditable: true, isSecure: false), frame: field, image: image)))
        invalid.append(fingerprint(action: action, evidence: .init(applicationIdentity: signedApp, window: identity,
            text: .init(targetID: "field", value: baseText.value, selection: NSRange(location: 8, length: 1),
                isEditable: true, isSecure: false), frame: field, image: image)))
        invalid.append(fingerprint(action: action, evidence: .init(applicationIdentity: signedApp, window: identity,
            text: .init(targetID: "field", value: baseText.value, selection: baseText.selection,
                isEditable: false, isSecure: false), frame: field, image: image)))
        invalid.append(fingerprint(action: action, evidence: .init(applicationIdentity: signedApp, window: identity,
            text: baseText, frame: CGRect(x: 101, y: 100, width: 300, height: 30), image: image)))
        invalid.append(fingerprint(action: action, evidence: .init(applicationIdentity: signedApp, window: identity,
            text: .init(targetID: "field", value: baseText.value, selection: baseText.selection,
                isEditable: true, isSecure: true), frame: field, image: image)))
        invalid.append(fingerprint(action: action, evidence: .init(applicationIdentity: signedApp, window: identity,
            text: .init(targetID: "field", value: baseText.value, selection: NSRange(location: 8, length: 1),
                isEditable: true, isSecure: false), frame: field, image: image)))
        invalid.append(fingerprint(action: .click(x: 120, y: 110, button: 1, count: 1), evidence: baseEvidence))
        for candidate in invalid {
            XCTAssertFalse(original.matchesForFinalDispatch(candidate))
        }
    }

    private func finalDispatchImage(displayBounds: CGRect = CGRect(x: 0, y: 0, width: 640, height: 400),
        changes: [(Int, Int, UInt8, UInt8, UInt8, UInt8)] = []) throws -> ComputerUseDesktopImage {
        let width = 640, height = 400
        var bytes = Data(repeating: 128, count: width * height * 4)
        for pixel in 0..<(width * height) { bytes[pixel * 4 + 3] = 255 }
        for (x, y, red, green, blue, alpha) in changes {
            let offset = (y * width + x) * 4
            bytes[offset] = red; bytes[offset + 1] = green; bytes[offset + 2] = blue; bytes[offset + 3] = alpha
        }
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return try ComputerUseDesktopImage(observation: .init(image: CIImage(cgImage: image),
            displayBounds: displayBounds))
    }

    private func finalDispatchApplicationIdentity(bundleIdentifier: String = "org.example.Browser",
        processIdentifier: pid_t = 7, launchGeneration: UInt64 = 1, teamIdentifier: String? = "TEST") throws -> ComputerUseApplicationIdentity {
        let path = "/fixture/\(bundleIdentifier).app"
        let code = ComputerUseApplicationCodeIdentity(authority: .runningCode, bundleIdentifier: bundleIdentifier,
            canonicalBundlePath: path, canonicalExecutablePath: "\(path)/Contents/MacOS/Browser",
            designatedRequirement: "fixture requirement", teamIdentifier: teamIdentifier, platformIdentifier: nil)
        return try XCTUnwrap(ComputerUseApplicationIdentity(bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier, launchGeneration: launchGeneration, codeIdentity: code))
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

private final class NativeMCPDocumentProposalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [String] = []
    func append(_ value: String) { lock.withLock { contents.append(value) } }
    func values() -> [String] { lock.withLock { contents } }
}

private actor NativeMCPTaskObservedPool: MCPClientPooling {
    let base: MCPClientPool
    private var pending: MCPToolCall?
    private var approved: [MCPToolCall] = []
    private var cancellations: [UInt64] = []
    init(base: MCPClientPool) { self.base = base }
    func start(binaryURL: URL) async throws -> MCPProcessIdentity { try await base.start(binaryURL: binaryURL) }
    func allowedTools() async throws -> [MCPAllowedTool] { try await base.allowedTools() }
    func execute(_ call: MCPToolCall) async throws -> MCPToolResult { try await base.execute(call) }
    func prepareApproval(_ call: MCPToolCall) async throws -> MCPPreparedApproval {
        let result = try await base.prepareApproval(call)
        pending = call
        return result
    }
    func performApproved(_ call: MCPToolCall, fingerprint: MCPApprovalFingerprint) async throws -> MCPToolResult {
        approved.append(call)
        return try await base.performApproved(call, fingerprint: fingerprint)
    }
    func cancel(processGeneration: UInt64) async {
        await base.cancel(processGeneration: processGeneration)
        cancellations.append(processGeneration)
    }
    func cancelAll() async { await base.cancelAll() }
    func latestPrepared() -> MCPToolCall? { pending }
    func approvedCalls() -> [MCPToolCall] { approved }
    func cancelledGenerations() -> [UInt64] { cancellations }
}

private actor NativeMCPTaskChannel: HostComputerUseChannel {
    private var sent: [ComputerUseEnvelope] = []
    func send(kind: ComputerUseEnvelope.Kind, body: String, to targetID: String?, sessionID: String?,
        messageID: String?) async throws -> ComputerUseEnvelope {
        let envelope = ComputerUseEnvelope(id: messageID ?? UUID().uuidString, senderID: "HOST-ID",
            targetID: targetID ?? "TEXTEDIT-TEST", pairingCode: "123456", sessionID: sessionID ?? "TEXTEDIT-SESSION",
            kind: kind, body: body)
        sent.append(envelope)
        return envelope
    }
    func poll() async throws -> [ComputerUseEnvelope] { [] }
    func acknowledge(_ envelopes: [ComputerUseEnvelope]) async throws {}
    func messages() -> [ComputerUseEnvelope] { sent }
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

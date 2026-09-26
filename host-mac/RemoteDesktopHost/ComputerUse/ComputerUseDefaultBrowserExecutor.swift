import AppKit
import Foundation

typealias ComputerUseDefaultBrowserFileCatalogFactory = @MainActor (String) throws -> ComputerUseLocalFileCatalog

/// Keyboard admission for a retained browser window. No shortcut here can
/// create, close, or switch a browser tab/window or application.
enum ComputerUseDefaultBrowserActionScope {
    /// The model has already resolved the user's file. Navigate the native
    /// picker from its current AX state without guessing a visible file row.
    static func nativeSelectionProposal(panel: ComputerUseDefaultBrowserSession.FileOpenPanel,
                                        selectedURL: URL) -> ComputerUseDesktopProposal? {
        func action(_ action: ComputerUseFaraAction) -> ComputerUseDesktopProposal {
            .init(response: "", action: action, includeInModelHistory: false)
        }
        func handoff(_ message: String) -> ComputerUseDesktopProposal {
            .init(response: "", decision: .handoff(message), includeInModelHistory: false)
        }
        if panel.selectedFileURLs.count == 1,
           panel.selectedFileURLs[0].standardizedFileURL.resolvingSymlinksInPath()
            == selectedURL.standardizedFileURL.resolvingSymlinksInPath(), !panel.isNavigatingPath {
            return panel.primaryActionEnabled == true ? nil
                : handoff("The chosen file is selected, but this dialog cannot open it. Check the accepted file types.")
        }
        guard panel.isNavigatingPath else { return action(.key(["Command", "Shift", "g"])) }
        guard panel.pathFieldIsFocused, let value = panel.pathFieldValue,
              let selection = panel.pathFieldSelection, selectedURL.path.utf8.count <= 32_768 else {
            return handoff("The file path field is not ready. Focus it, then choose Resume.")
        }
        if value == selectedURL.path { return action(.key(["Return"])) }
        if value.isEmpty || selection == NSRange(location: 0, length: value.utf16.count) {
            return action(.typeText(selectedURL.path))
        }
        return action(.key(["Command", "a"]))
    }

    static func permits(_ action: ComputerUsePredictedAction?, within bounds: CGRect) -> Bool {
        guard let action else { return true }
        switch action {
        case .click(let x, let y, _, _): return bounds.contains(CGPoint(x: x, y: y))
        case .drag(let x, let y, let tx, let ty): return bounds.contains(CGPoint(x: x, y: y)) && bounds.contains(CGPoint(x: tx, y: ty))
        case .scroll(let x, let y, _, _): return bounds.contains(CGPoint(x: x, y: y))
        case .typeText: return true
        case .key(let key, let modifiers):
            if modifiers == 0 || modifiers == 1 { return true } // ordinary keys and Shift variants
            if modifiers == 9 { return key == 0x1D } // Cmd-Shift-Z (redo)
            if modifiers == 8 { return [0x04, 0x06, 0x09, 0x0F, 0x19, 0x1B, 0x1D].contains(key) } // Cmd-A/C/F/L/V/X/Z
            return false // includes Ctrl-Tab/PageUp/PageDown and all other chords
        case .requestApproval(_, let nested): return permits(nested, within: bounds)
        case .wait, .done: return true
        }
    }

    static func permitsFilePanel(_ action: ComputerUsePredictedAction?, within bounds: CGRect,
        panel: ComputerUseDefaultBrowserSession.FileOpenPanel, selectedURL: URL?) -> Bool {
        guard let action else { return true }
        func selectedExactlyOneEnabledFile() -> Bool {
            guard let selectedURL, panel.primaryActionEnabled == true,
                  panel.selectedFileURLs.count == 1 else { return false }
            return panel.selectedFileURLs[0].standardizedFileURL.resolvingSymlinksInPath()
                == selectedURL.standardizedFileURL.resolvingSymlinksInPath()
        }
        switch action {
        case .click(let x, let y, let button, let count):
            let point = CGPoint(x: x, y: y)
            guard button == 1, count == 1, bounds.contains(point), let primary = panel.primaryActionBounds else { return false }
            return !primary.contains(point) || selectedExactlyOneEnabledFile()
        case .scroll(let x, let y, _, _): return bounds.contains(CGPoint(x: x, y: y))
        case .key(let usage, let modifiers):
            if modifiers == 9, usage == 0x0A { return panel.goToFolderBounds == nil } // Cmd-Shift-G
            if modifiers == 8, usage == 0x04 { return panel.isNavigatingPath && panel.pathFieldIsFocused } // Cmd-A replaces Go To path
            guard modifiers == 0 else { return false }
            if usage == 0x28 { // Return/Enter opens a selected file, except in Go To Folder.
                return panel.isNavigatingPath ? panel.pathFieldIsFocused : selectedExactlyOneEnabledFile()
            }
            return [0x29, 0x2B, 0x4F, 0x50, 0x51, 0x52].contains(usage) // Escape, Tab, arrows
        case .typeText:
            return panel.isNavigatingPath && panel.pathFieldIsFocused
        case .requestApproval(_, let nested):
            return permitsFilePanel(nested, within: bounds, panel: panel, selectedURL: selectedURL)
        case .drag, .wait, .done: return false
        }
    }
}

@MainActor
final class ComputerUseDefaultBrowserExecutor: ComputerUseTaskAwareExecuting, ComputerUseVisualApprovalContinuing,
    ComputerUseTextClarificationContinuing {
    typealias CompletionCheck = @MainActor @Sendable (String) async throws -> Bool
    typealias NativeFilePlanner = @MainActor @Sendable (ComputerUseFaraModel.Input) async throws -> ComputerUseMCPBrowserStepPlanner.Plan?
    typealias LocalFileCatalogFactory = ComputerUseDefaultBrowserFileCatalogFactory
    enum Failure: Error { case taskAlreadyBound, noRetainedWindow, invalidFileChoice, selectedFileStale, selectedFileChangeNeedsConfirmation }

    @MainActor private final class Scope {
        let session: ComputerUseDefaultBrowserSession
        var window: ComputerUseDefaultBrowserSession.Window?
        var taskID: String?
        var goal: String?
        var attempted = false
        var tools: ComputerUseHostTools?
        var continuingClarification = false
        let localFileCatalogFactory: ComputerUseDefaultBrowserFileCatalogFactory
        var fileCatalog: ComputerUseLocalFileCatalog?
        var fileContext: ComputerUseMCPBrowserStepPlanner.LocalFileContext?
        var selectedCandidate: ComputerUseLocalFileCatalog.Candidate?
        var userSelectedCandidateID: String?
        var pendingClarification: ComputerUseNativeTextExecutor.Clarification?
        var pendingChoiceCandidates: [String: ComputerUseLocalFileCatalog.Candidate] = [:]
        var executionTaskID: String?
        var selectedChoice: ComputerUseClarificationChoice?
        var clarifiedGoal: ComputerUseUnresolvedTextGoal?
        var answerOriginTaskID: String?
        var clarificationNonce: UUID?
        var clarificationRetired = false
        var nativeFileOperationReady = false
        private var fileOperationRevision: UInt64 = 0
        var lastSessionFailureForDiagnostics: ComputerUseDefaultBrowserSession.Failure?
        init(session: ComputerUseDefaultBrowserSession,
             localFileCatalogFactory: @escaping ComputerUseDefaultBrowserFileCatalogFactory) {
            self.session = session; self.localFileCatalogFactory = localFileCatalogFactory
        }
        func prepare(_ id: String, _ goal: String, _ tools: ComputerUseHostTools) async throws {
            self.tools = tools
            if let taskID, taskID != id { throw Failure.taskAlreadyBound }
            if let previousGoal = self.goal, !previousGoal.utf8.elementsEqual(goal.utf8) { throw Failure.taskAlreadyBound }
            taskID = id; self.goal = goal
            if executionTaskID == nil { executionTaskID = id }
            if window != nil {
                try session.validate(taskID: id, goal: goal, tools: tools)
                window = session.currentWindow
                return
            }
            guard !attempted else { throw ComputerUseDefaultBrowserSession.Failure.targetLost }
            attempted = true; window = try await session.ensure(taskID: id, goal: goal, tools: tools)
        }
        func check(_ action: ComputerUsePredictedAction?, _ tools: ComputerUseHostTools) throws {
            guard let taskID, let goal else { throw Failure.noRetainedWindow }
            lastSessionFailureForDiagnostics = nil
            do { try session.validate(taskID: taskID, goal: goal, tools: tools) }
            catch let failure as ComputerUseDefaultBrowserSession.Failure {
                lastSessionFailureForDiagnostics = failure
                throw failure
            }
            guard let window = session.currentWindow else { throw Failure.noRetainedWindow }
            self.window = window
            if let panel = session.currentFileOpenPanel {
                let selectedURL = try selectedFileURL()
                guard panel.parentWindowID == window.id,
                      CFEqual(panel.parentWindowElement, window.accessibilityElement),
                      let bounds = session.currentActionBounds,
                      ComputerUseDefaultBrowserActionScope.permitsFilePanel(action, within: bounds,
                        panel: panel, selectedURL: selectedURL) else {
                    throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged
                }
            } else if !ComputerUseDefaultBrowserActionScope.permits(action, within: window.identity.bounds) {
                throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged
            }
        }

        func modelInput(_ input: ComputerUseFaraModel.Input,
            includeUnselectedCatalog: Bool = false, advertiseFilePicker: Bool = false) throws -> ComputerUseFaraModel.Input {
            guard let tools else { throw Failure.noRetainedWindow }
            try check(nil, tools)
            if selectedCandidate != nil { _ = try selectedFileURL() }
            var enriched = input
            if includeUnselectedCatalog {
                enriched.localFileCatalog = fileContext ?? Self.notQueriedFileContext
            } else if let selectedCandidate, let fileContext {
                let selectedPage = ComputerUseLocalFileCatalog.Page(candidates: [selectedCandidate],
                    isComplete: fileContext.page.isComplete, nextCursor: fileContext.page.nextCursor,
                    hasTiedSortValues: fileContext.page.hasTiedSortValues,
                    hasMissingSortValues: fileContext.page.hasMissingSortValues)
                enriched.localFileCatalog = .init(query: fileContext.query, page: selectedPage,
                    selectedCandidate: selectedCandidate, inventoryState: fileContext.inventoryState)
            } else {
                enriched.localFileCatalog = advertiseFilePicker ? Self.notQueriedFileContext : nil
            }
            enriched.selectedLocalFilePath = session.currentFileOpenPanel == nil ? nil : try selectedFileURL()?.path
            return enriched
        }

        func apply(_ operation: ComputerUseMCPBrowserStepPlanner.Plan.LocalFileOperation) async throws
            -> ComputerUseExecutionResult? {
            guard let taskID, let goal, let tools else { throw Failure.noRetainedWindow }
            guard nativeFileOperationReady else { throw ComputerUseDesktopExecutor.Failure.unsupportedAction }
            nativeFileOperationReady = false
            fileOperationRevision &+= 1
            let revision = fileOperationRevision
            let operationTaskID = taskID
            let operationGoal = goal
            try Task.checkCancellation(); try tools.requireActive(); try check(nil, tools)
            switch operation {
            case .listFiles(let query, let cursor):
                var catalog = try fileCatalog ?? localFileCatalogFactory(taskID)
                let page: ComputerUseLocalFileCatalog.Page
                if let cursor {
                    guard let context = fileContext, context.query == query, context.page.nextCursor == cursor else {
                        throw Failure.invalidFileChoice
                    }
                    page = try catalog.nextPage(after: cursor)
                } else {
                    let discovery: ComputerUseLocalFileCatalog.Discovery
                    do {
                        discovery = try await catalog.discoverOffMainActor(query: query)
                    } catch ComputerUseBlockingOperationWorker.Failure.busy {
                        return .userInterventionRequired("File access is waiting. Allow macOS Downloads access if prompted, then Resume.")
                    } catch ComputerUseBlockingOperationWorker.Failure.timedOut {
                        return .userInterventionRequired("File access is waiting. Allow macOS Downloads access if prompted, then Resume.")
                    }
                    try Task.checkCancellation()
                    try tools.requireActive()
                    try check(nil, tools)
                    guard fileOperationRevision == revision, self.taskID == operationTaskID,
                          self.goal == operationGoal else {
                        throw ComputerUseDesktopExecutor.Failure.changedTask
                    }
                    catalog = discovery.catalog
                    page = discovery.page
                    if userSelectedCandidateID == nil { selectedCandidate = nil }
                }
                guard page.candidates.count <= 8 else { throw Failure.invalidFileChoice }
                fileCatalog = catalog
                fileContext = .init(query: query, page: page, selectedCandidate: selectedCandidate, inventoryState: .available)
            case .selectFile(let candidateID):
                let candidate = try currentCandidate(candidateID, taskID: taskID)
                if let userSelectedCandidateID, userSelectedCandidateID != candidateID {
                    throw Failure.selectedFileChangeNeedsConfirmation
                }
                selectedCandidate = candidate
                if let context = fileContext {
                    fileContext = .init(query: context.query, page: context.page,
                        selectedCandidate: candidate, inventoryState: context.inventoryState)
                }
            case .askFile(let question, let candidateIDs):
                guard let context = fileContext, (2...8).contains(candidateIDs.count),
                      Set(candidateIDs).count == candidateIDs.count,
                      !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      question.utf8.count <= 512 else { throw Failure.invalidFileChoice }
                var candidates: [String: ComputerUseLocalFileCatalog.Candidate] = [:]
                var choices: [ComputerUseClarificationChoice] = []
                let formatter = ISO8601DateFormatter()
                for id in candidateIDs {
                    guard let candidate = context.page.candidates.first(where: { $0.id == id }) else {
                        throw Failure.invalidFileChoice
                    }
                    _ = try resolve(candidate, taskID: taskID)
                    candidates[id] = candidate
                    var detail = "\(candidate.fileExtension.uppercased()) · \(candidate.byteCount) bytes"
                    if let modified = candidate.modifiedAt { detail += " · Modified \(formatter.string(from: modified))" }
                    if let created = candidate.createdAt { detail += " · Created \(formatter.string(from: created))" }
                    choices.append(try .init(id: candidate.id, label: candidate.displayName, detail: detail))
                }
                let unresolved = try ComputerUseUnresolvedTextGoal(userRequest: goal)
                let clarificationTaskID = executionTaskID ?? taskID
                let nonce = UUID()
                let scopeDigest = ComputerUseTaskContract.digest(["default-browser-file-choice-v1", taskID,
                    clarificationTaskID, unresolved.taskIdentityText, session.currentWindow?.id ?? "", nonce.uuidString])
                let expiresAt = Date().addingTimeInterval(600)
                pendingClarification = .init(taskID: clarificationTaskID, goal: unresolved, question: question,
                    scope: scopeDigest, expiresAt: expiresAt, choices: choices)
                clarificationRetired = false
                pendingChoiceCandidates = candidates
                executionTaskID = clarificationTaskID
                clarificationNonce = nonce
                return .clarificationRequired(question)
            case .selectLocalFile:
                throw ComputerUseDesktopExecutor.Failure.unsupportedAction
            }
            try Task.checkCancellation(); try tools.requireActive(); try check(nil, tools)
            return nil
        }

        func selectedFileURL() throws -> URL? {
            guard let candidate = selectedCandidate, let fileCatalog, let taskID else { return nil }
            return try resolve(candidate, taskID: taskID, catalog: fileCatalog)
        }

        private func currentCandidate(_ candidateID: String, taskID: String) throws -> ComputerUseLocalFileCatalog.Candidate {
            guard let context = fileContext, let candidate = context.page.candidates.first(where: { $0.id == candidateID }) else {
                throw Failure.invalidFileChoice
            }
            _ = try resolve(candidate, taskID: taskID)
            return candidate
        }

        func resolve(_ candidate: ComputerUseLocalFileCatalog.Candidate, taskID: String,
                             catalog: ComputerUseLocalFileCatalog? = nil) throws -> URL {
            guard let catalog = catalog ?? fileCatalog else { throw Failure.selectedFileStale }
            do { return try catalog.resolve(candidateID: candidate.id, taskID: taskID) }
            catch { throw Failure.selectedFileStale }
        }

        static var notQueriedFileContext: ComputerUseMCPBrowserStepPlanner.LocalFileContext {
            .init(query: .init(), page: .init(candidates: [], isComplete: false, nextCursor: nil,
                hasTiedSortValues: false, hasMissingSortValues: false), inventoryState: .notQueried)
        }
    }

    private let scope: Scope
    private let desktop: ComputerUseDesktopExecutor
    /// Optional task-specific verification supplements the model's decision
    /// from the fresh screenshot. Real-site acceptance checks outcomes separately.
    var retainedWindowForDiagnostics: ComputerUseDefaultBrowserSession.Window? { scope.window }
    private(set) var lastSessionFailureForDiagnostics: ComputerUseDefaultBrowserSession.Failure?
    var lastActionDiagnosticForTests: [String: String] { desktop.lastRevalidationDiagnostic }
    var isReady: Bool { desktop.isReady }
    var runtimeName: String { "Default-browser desktop computer use" }
    var requiresMacControlHelper: Bool { desktop.requiresMacControlHelper }
    var hasAdditionalSetup: Bool { desktop.hasAdditionalSetup }
    var supportsNativeTextTasks: Bool { desktop.supportsNativeTextTasks }
    var readyDetail: String { desktop.readyDetail }

    init(journalDirectory: URL, session suppliedSession: ComputerUseDefaultBrowserSession? = nil,
         propose: @escaping ComputerUseDesktopExecutor.Propose,
         nativeFilePlanner: NativeFilePlanner? = nil,
         finishRun: @escaping @MainActor @Sendable () async -> Void = {},
         completionCheck: CompletionCheck? = nil,
         localFileCatalogFactory: @escaping LocalFileCatalogFactory = { taskID in
             let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                 ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
             return try ComputerUseLocalFileCatalog(taskID: taskID, approvedDirectory: downloads, pageSize: 8)
         }) throws {
        let session: ComputerUseDefaultBrowserSession
        if let suppliedSession { session = suppliedSession }
        else { session = try ComputerUseDefaultBrowserSession(journalDirectory: journalDirectory) }
        let scope = Scope(session: session,
            localFileCatalogFactory: localFileCatalogFactory)
        self.scope = scope
        desktop = try ComputerUseDesktopExecutor(journalDirectory: journalDirectory, propose: { input in
            scope.nativeFileOperationReady = false
            if scope.session.currentFileOpenPanel != nil && scope.selectedCandidate == nil {
                guard let nativeFilePlanner else {
                    return .init(response: "", decision: .handoff("Choose a file in the native picker before continuing."),
                        includeInModelHistory: false)
                }
                let nativeInput = try scope.modelInput(input, includeUnselectedCatalog: true)
                guard let plan = try await nativeFilePlanner(nativeInput) else {
                    return .init(response: "", decision: .handoff("The native file chooser needs your input before continuing."),
                        includeInModelHistory: false)
                }
                if plan.kind == .localFileOperation, let operation = plan.localFileOperation {
                    switch operation {
                    case .listFiles, .selectFile, .askFile:
                        scope.nativeFileOperationReady = true
                        return .init(response: plan.text, action: .localFileOperation(operation))
                    case .selectLocalFile:
                        return .init(response: plan.text, decision: .handoff("Select the listed file in the native picker to continue."),
                            includeInModelHistory: false)
                    }
                }
                if plan.kind == .askUser || plan.kind == .incomplete {
                    let message = plan.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return .init(response: plan.text, decision: .handoff(message.isEmpty
                        ? "Choose a file in the native picker before continuing." : message), includeInModelHistory: false)
                }
                return .init(response: plan.text,
                    decision: .handoff("The native file chooser did not return a supported file choice."),
                    includeInModelHistory: false)
            }
            let enriched = try scope.modelInput(input, advertiseFilePicker: nativeFilePlanner != nil)
            if let panel = scope.session.currentFileOpenPanel,
               let selectedURL = try scope.selectedFileURL(),
               let native = ComputerUseDefaultBrowserActionScope.nativeSelectionProposal(panel: panel, selectedURL: selectedURL) {
                return native
            }
            return try await propose(enriched)
        },
            surfaceScopeCheck: { action in
                guard let tools = scope.tools else { throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged }
                do { try scope.check(action, tools) }
                catch is CancellationError { throw CancellationError() }
                catch { throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged }
            }, completeCheck: completionCheck,
            localFileOperationHandler: { try await scope.apply($0) }, finishRun: finishRun)
    }

    func execute(prompt: String, tools: ComputerUseHostTools, progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        try await execute(taskID: UUID().uuidString, prompt: prompt, trustedUserPrompt: prompt, tools: tools, progress: progress)
    }
    func execute(taskID: String, prompt: String, trustedUserPrompt: String, tools: ComputerUseHostTools,
                 progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        lastSessionFailureForDiagnostics = nil
        if scope.clarificationRetired {
            return .userInterventionRequired("The file choice expired or was dismissed. Start a new file choice to continue.")
        }
        if let pending = scope.pendingClarification, pending.taskID == taskID,
           scope.executionTaskID == taskID {
            return .clarificationRequired(pending.question)
        }
        do {
            try await scope.prepare(taskID, trustedUserPrompt, tools)
            return try await desktop.execute(taskID: taskID, prompt: prompt, trustedUserPrompt: trustedUserPrompt, tools: tools, progress: progress)
        } catch is CancellationError { throw CancellationError() }
        catch let failure as ComputerUseDefaultBrowserSession.Failure {
            lastSessionFailureForDiagnostics = failure
            if failure == .authenticationHandoff {
                return .userInterventionRequired("Complete sign-in or macOS permission in the intended browser window, then choose Resume.")
            }
            return .userInterventionRequired("The intended browser window changed or is unavailable. Restore it, then choose Resume.")
        }
        catch Failure.taskAlreadyBound { return .userInterventionRequired("This browser task is bound to its original goal. Resume that task to continue.") }
        catch Failure.noRetainedWindow { return .userInterventionRequired("The intended browser window changed or is unavailable. Restore it, then choose Resume.") }
        catch Failure.selectedFileStale { return .userInterventionRequired("The selected local file changed. Choose it again before continuing.") }
        catch Failure.selectedFileChangeNeedsConfirmation { return .userInterventionRequired("A different file was requested after your choice. Choose the new file explicitly before continuing.") }
        catch ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged {
            lastSessionFailureForDiagnostics = scope.lastSessionFailureForDiagnostics
            return .userInterventionRequired("The intended browser window changed or is unavailable. Restore it, then choose Resume.")
        }
        catch { throw error }
    }

    func performApprovedVisualAction(_ continuation: ComputerUseVisualApprovalContinuation, action: ComputerUsePredictedAction,
        fingerprint: ComputerUseApprovalFingerprint, tools: ComputerUseHostTools, willBeginEffect: () -> Void) async throws {
        do {
            scope.tools = tools
            try scope.check(action, tools)
            try await desktop.performApprovedVisualAction(continuation, action: action, fingerprint: fingerprint,
                                                         tools: tools, willBeginEffect: willBeginEffect)
        } catch is CancellationError { throw CancellationError() }
        catch ComputerUseHostTools.ToolError.approvedActionEffectMayHaveOccurred { throw ComputerUseHostTools.ToolError.approvedActionEffectMayHaveOccurred }
        catch {
            desktop.cancelVisualApprovalContinuation(continuation)
            throw ComputerUseDesktopExecutor.Failure.scopedSurfaceChanged
        }
    }

    func continueAfterApprovedVisualAction(_ continuation: ComputerUseVisualApprovalContinuation, action: ComputerUsePredictedAction,
        tools: ComputerUseHostTools, progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        do {
            scope.tools = tools
            try scope.check(action, tools)
            return try await desktop.continueAfterApprovedVisualAction(continuation, action: action, tools: tools, progress: progress)
        } catch is CancellationError { throw CancellationError() }
        catch ComputerUseDefaultBrowserSession.Failure.authenticationHandoff { return .userInterventionRequired("Complete sign-in or macOS permission in the intended browser window, then choose Resume.") }
        catch { return .userInterventionRequired("The intended browser window changed or is unavailable. Restore it, then choose Resume.") }
    }

    func cancelVisualApprovalContinuation(_ continuation: ComputerUseVisualApprovalContinuation) {
        desktop.cancelVisualApprovalContinuation(continuation)
    }

    func clarification(taskID: String) throws -> ComputerUseNativeTextExecutor.Clarification? {
        guard let pending = scope.pendingClarification, scope.executionTaskID == taskID else { return nil }
        guard pending.expiresAt > Date(), pending.taskID == taskID,
              scope.clarificationNonce != nil else {
            scope.pendingClarification = nil
            scope.pendingChoiceCandidates.removeAll()
            scope.clarificationRetired = true
            throw Failure.invalidFileChoice
        }
        return pending
    }

    func invalidateClarification(taskID: String?) {
        guard taskID == nil || scope.executionTaskID == taskID else { return }
        scope.pendingClarification = nil
        scope.pendingChoiceCandidates.removeAll()
        scope.clarificationRetired = true
    }

    func continueClarification(taskID: String, originatingTaskID: String,
        goal: ComputerUseUnresolvedTextGoal, progress: @escaping (String) -> Void) async throws
        -> ComputerUseExecutionResult {
        try await continueClarification(taskID: taskID, originatingTaskID: originatingTaskID,
            goal: goal, selectedChoice: nil, progress: progress)
    }

    func continueClarification(taskID: String, originatingTaskID: String,
        goal: ComputerUseUnresolvedTextGoal, selectedChoice: ComputerUseClarificationChoice?,
        progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        guard !scope.continuingClarification else { throw ComputerUseTaskExecutionError.alreadyExecuting }
        scope.continuingClarification = true
        defer { scope.continuingClarification = false }
        guard taskID != originatingTaskID else { throw Failure.invalidFileChoice }
        guard let selectedChoice else { throw Failure.invalidFileChoice }
        guard let rootTaskID = scope.taskID, let rootGoal = scope.goal, let tools = scope.tools else {
            throw ComputerUseCapabilityExecutor.RoutingError.missingContinuation
        }
        if scope.executionTaskID == taskID {
            guard scope.answerOriginTaskID == originatingTaskID,
                  scope.clarifiedGoal == goal, scope.selectedChoice == selectedChoice,
                  scope.userSelectedCandidateID == selectedChoice.id else { throw Failure.invalidFileChoice }
        } else {
            guard scope.executionTaskID == originatingTaskID,
                  let pending = try clarification(taskID: originatingTaskID),
                  pending.goal == goal, pending.choices?.contains(selectedChoice) == true,
                  let candidate = scope.pendingChoiceCandidates[selectedChoice.id],
                  candidate.id == selectedChoice.id else { throw Failure.invalidFileChoice }
            _ = try scope.resolve(candidate, taskID: rootTaskID)
            scope.selectedCandidate = candidate
            scope.userSelectedCandidateID = candidate.id
            scope.selectedChoice = selectedChoice
            scope.clarifiedGoal = goal
            scope.answerOriginTaskID = originatingTaskID
            scope.executionTaskID = taskID
            scope.pendingClarification = nil
            scope.pendingChoiceCandidates.removeAll()
            scope.clarificationNonce = nil
            if let context = scope.fileContext {
                scope.fileContext = .init(query: context.query, page: context.page,
                    selectedCandidate: candidate, inventoryState: context.inventoryState)
            }
        }
        return try await execute(taskID: rootTaskID, prompt: rootGoal,
            trustedUserPrompt: rootGoal, tools: tools, progress: progress)
    }
}

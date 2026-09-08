import Foundation

/// Compile the entire explicit request before opening a page. This is the
/// deterministic entry to the browser driver, not a research-goal interpreter.
/// Future semantic plans must carry equally complete, reviewed requirements.
struct ComputerUseBrowserWorkflowRequest {
    enum Kind { case navigation, edits, link(String), formQuery(String) }
    struct Stage {
        let source: String
        let kind: Kind
        var kindID: String {
            switch kind {
            case .navigation: return "navigation"
            case .edits: return "edits"
            case .link: return "link"
            case .formQuery: return "form-query"
            }
        }
    }
    let prompt: String
    let stages: [Stage]
    var promptDigest: String { ComputerUseTextTaskContract.digest(prompt) }

    private init(prompt: String, stages: [Stage]) { self.prompt = prompt; self.stages = stages }

    static func compile(_ prompt: String) throws -> Self? {
        guard !prompt.isEmpty, prompt.utf8.count <= 32 * 1_024,
              let pieces = clauses(prompt), pieces.count <= 32 else { return nil }
        var stages: [Stage] = [], edits: [String] = []
        func flushEdits() throws -> Bool {
            guard !edits.isEmpty else { return true }
            let source = edits.joined(separator: " then ")
            // Empty fields intentionally yield clarification for a complete
            // command. Target lookup is deferred until its page is current.
            guard (try? ComputerUseQuotedTextRequest.compile(prompt: source, fields: [])) != nil else { return false }
            stages.append(.init(source: source, kind: .edits))
            edits.removeAll()
            return true
        }
        for piece in pieces {
            let kind: Kind?
            if ComputerUseBrowserNavigationRequest.urls(in: piece) != nil { kind = .navigation }
            else if let label = quotedArgument(piece, prefixes: ["open the link ", "open link "]) { kind = .link(label) }
            else if let label = quotedArgument(piece, prefixes: ["open the form query using ", "open form query using "]) { kind = .formQuery(label) }
            else { kind = nil }
            if let kind {
                guard try flushEdits() else { return nil }
                stages.append(.init(source: piece, kind: kind))
            } else { edits.append(piece) }
        }
        guard try flushEdits(), (2...16).contains(stages.count),
              stages.contains(where: { if case .navigation = $0.kind { return false }; return true }) else { return nil }
        return .init(prompt: prompt, stages: stages)
    }

    private static func quotedArgument(_ source: String, prefixes: [String]) -> String? {
        guard let prefix = prefixes.first(where: { source.lowercased().hasPrefix($0) }) else { return nil }
        let value = String(source.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let opening = value.first, opening == "\"" || opening == "“" else { return nil }
        let closing: Character = opening == "“" ? "”" : "\""
        guard value.count >= 3, value.last == closing else { return nil }
        let label = String(value.dropFirst().dropLast())
        guard !label.contains(closing), !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              label.utf8.count <= 512 else { return nil }
        return label
    }

    private static func clauses(_ source: String) -> [String]? {
        var pieces: [String] = [], start = source.startIndex, cursor = start
        var closingQuote: Character?
        while cursor < source.endIndex {
            let character = source[cursor]
            if let closing = closingQuote {
                if character == closing { closingQuote = nil }
            } else if character == "\"" || character == "“" {
                closingQuote = character == "“" ? "”" : "\""
            } else if source[cursor...].prefix(4).lowercased() == "then",
                      cursor > source.startIndex, source[source.index(before: cursor)].isWhitespace,
                      let end = source.index(cursor, offsetBy: 4, limitedBy: source.endIndex),
                      end < source.endIndex, source[end].isWhitespace {
                var piece = String(source[start..<cursor]).trimmingCharacters(in: .whitespacesAndNewlines)
                if piece.lowercased().hasSuffix(" and") { piece = String(piece.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines) }
                if piece.last == "," || piece.last == ";" { piece.removeLast(); piece = piece.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard !piece.isEmpty else { return nil }
                pieces.append(piece)
                start = end; cursor = end
                continue
            }
            cursor = source.index(after: cursor)
        }
        guard closingQuote == nil else { return nil }
        let last = String(source[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !last.isEmpty else { return nil }
        pieces.append(last)
        return pieces
    }
}

/// Sequences child capabilities under one original request and browser owner.
/// The parent journal records delegation/progress; only each child's journal
/// and native observations establish its effects. An attempted parent stage
/// resumes that same child rather than authorizing its inputs anew.
@MainActor
final class ComputerUseBrowserWorkflowTask {
    private struct NoAdditionalPlanner: ComputerUseTextGoalPlanning {
        func propose(prompt: String, fields: [ComputerUseTextField]) async throws -> ComputerUseTextGoalProposal { .unsupported }
    }
    let taskID: String
    let request: ComputerUseBrowserWorkflowRequest
    private let browser: ComputerUseOwnedBrowser
    private let directory: URL
    private let injector: InputInjector
    private let observedNavigationStore: (URL) throws -> ComputerUseTaskJournalStore
    private var session: ComputerUseBrowserHandbackRequirement?
    private var navigationChildren: [Int: ComputerUseBrowserNavigationTask] = [:]
    private var textChildren: [Int: ComputerUseNativeTextExecutor] = [:]
    private var preparedDestinations: [Int: ComputerUseBrowserNavigationTarget] = [:]
    private var unconfirmedDestinations: [Int: ComputerUseBrowserNavigationTarget] = [:]
    private var isExecuting = false

    init(taskID: String, request: ComputerUseBrowserWorkflowRequest, browser: ComputerUseOwnedBrowser,
         directory: URL, injector: InputInjector,
         observedNavigationStore: @escaping (URL) throws -> ComputerUseTaskJournalStore = { try .init(directory: $0) }) {
        self.taskID = taskID; self.request = request; self.browser = browser
        self.directory = directory; self.injector = injector
        self.observedNavigationStore = observedNavigationStore
    }

    func run(progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        guard !isExecuting else { throw ComputerUseTaskExecutionError.alreadyExecuting }
        isExecuting = true
        defer { isExecuting = false }
        if session == nil {
            if case .navigation = request.stages[0].kind { /* The child presents its new page. */ }
            else { _ = try await browser.acquireObservedDocument(taskID: taskID) }
            session = try browser.prepareWorkflowSession(taskID: taskID)
        }
        guard let session else { throw ComputerUseBrowserError.handbackContextLost }
        try browser.validateWorkflowSession(session)
        let stepIDs = request.stages.enumerated().map { index, stage in
            ComputerUseTaskContract.digest(["browser-workflow-stage-v1", taskID, request.promptDigest,
                String(index), stage.kindID, stage.source])
        }
        let contractDigest = ComputerUseTaskContract.digest(["browser-workflow-v1", taskID,
            request.promptDigest, session.sessionBindingDigest] + stepIDs)
        let store = try ComputerUseTaskJournalStore(directory: directory)
        var persisted = try store.load(taskID: taskID)
        var journal = ComputerUseTaskJournal(taskID: taskID, promptDigest: request.promptDigest,
            contractDigest: contractDigest, stepIDs: stepIDs, statuses: stepIDs.map { _ in .planned })
        if let saved = persisted {
            guard saved.taskID == taskID, saved.promptDigest == journal.promptDigest,
                  saved.contractDigest == contractDigest, saved.stepIDs == stepIDs,
                  saved.statuses.count == stepIDs.count else { throw ComputerUseTaskExecutionError.journalMismatch }
            var unfinished = false
            for status in saved.statuses {
                guard status != .uncertain, !unfinished || status == .planned else { throw ComputerUseTaskExecutionError.journalMismatch }
                if status != .verified { unfinished = true }
            }
            journal = saved
        }
        let lease = try store.acquireExecution(taskID: taskID, expected: persisted)
        defer { lease.release() }
        func checkOwnership() throws {
            try lease.assertOwnership()
            try browser.validateWorkflowSession(session)
        }
        func save() throws {
            try checkOwnership()
            try store.save(journal, replacing: persisted)
            persisted = journal
        }
        if persisted == nil { try save() }
        for (index, stage) in request.stages.enumerated() {
            try checkOwnership()
            if journal.statuses[index] == .verified { continue }
            progress("Browser step \(index + 1) of \(request.stages.count)…")
            if journal.statuses[index] == .planned {
                journal.statuses[index] = .attempted
                try save()
            }
            let childDirectory = directory.appendingPathComponent("Stages")
                .appendingPathComponent(stepIDs[index], isDirectory: true)
            let result: ComputerUseExecutionResult
            switch stage.kind {
            case .navigation:
                let child = navigationChild(index, directory: childDirectory, stepID: stepIDs[index])
                guard let navigationResult = try await child.execute(taskID: taskID, prompt: stage.source, progress: progress) else {
                    throw ComputerUseTaskExecutionError.invalidContract
                }
                result = navigationResult
            case .edits:
                let child: ComputerUseNativeTextExecutor
                if let retained = textChildren[index] { child = retained }
                else {
                    child = ComputerUseNativeTextExecutor(injector: injector,
                        mayAct: { [browser, taskID] in browser.hasOwnership(taskID: taskID) },
                        journalDirectory: childDirectory, planner: NoAdditionalPlanner(),
                        browserTargetProvider: { [browser, taskID] requestedID in
                            guard requestedID == taskID, browser.hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
                            let document = try await browser.acquireObservedDocument(taskID: taskID)
                            guard browser.hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
                            // A displayed browser passed the foreground guard;
                            // only an explicitly headless fixture has no window.
                            return ComputerUseBrowserTextTarget(browser: browser, document: document,
                                requiresFrontmost: browser.isFrontmostWindow)
                        })
                    textChildren[index] = child
                }
                guard let editResult = try await child.execute(taskID: taskID, prompt: stage.source, progress: progress) else {
                    return .userInterventionRequired("The current page cannot support the requested form edit. Open the intended form, then choose Resume.")
                }
                if case .clarificationRequired = editResult {
                    // No compiled edit exists yet. A manual page correction
                    // may resolve the exact labels without changing the goal.
                    child.invalidateClarification(taskID: taskID)
                    return .userInterventionRequired("I could not uniquely identify the requested fields. Open the intended form, then choose Resume to continue the original request.")
                }
                result = editResult
            case .link(let label), .formQuery(let label):
                let child = navigationChild(index, directory: childDirectory, stepID: stepIDs[index])
                let candidate: ComputerUseBrowserNavigationTarget?
                if var retained = preparedDestinations[index] {
                    if let replacement = unconfirmedDestinations[index] {
                        retained = try child.resolveUnconfirmedObservedDestination(retained, replacement: replacement,
                            promptDigest: request.promptDigest, operationID: stepIDs[index], checkCurrent: checkOwnership)
                        preparedDestinations[index] = retained
                        unconfirmedDestinations[index] = nil
                    }
                    // A previous run may have stopped after preparing a link
                    // but before any request (for example, inline login).
                    // The child checks durable AND native attempts before it
                    // allows fresh observation under the original stage ID.
                    var proposed: ComputerUseBrowserNavigationTarget?
                    do {
                        candidate = try await child.refreshUnsentObservedDestination(retained,
                            promptDigest: request.promptDigest, operationID: stepIDs[index]) {
                                proposed = try await self.prepareDestination(index: index, stage: stage, label: label)
                                return proposed
                            }
                    } catch {
                        // This is an alternative to reconcile, not a new
                        // prepared target or permission to repeat the action.
                        unconfirmedDestinations[index] = proposed
                        try checkOwnership()
                        throw error
                    }
                } else {
                    candidate = try await prepareDestination(index: index, stage: stage, label: label)
                }
                guard let target = candidate else {
                    return .userInterventionRequired("I could not uniquely identify the requested link or form query. Open the intended page, then choose Resume.")
                }
                preparedDestinations[index] = target
                unconfirmedDestinations[index] = nil
                _ = try await child.openObservedDestination(target,
                    promptDigest: request.promptDigest, operationID: stepIDs[index], willBeginEffect: {})
                result = .completed("Browser destination confirmed")
            }
            try checkOwnership()
            guard case .completed = result else { return result }
            journal.statuses[index] = .verified
            try save()
        }
        try checkOwnership()
        guard let document = browser.currentDocument(taskID: taskID), browser.hasRequiredPresentation else {
            throw ComputerUseBrowserError.pageChanged
        }
        _ = try await browser.observePage(document: document)
        try checkOwnership()
        return .completed("Completed the requested page openings and form edits. Website: \(ComputerUseBrowserSite.displayName(for: document.committedURL))")
    }

    private func prepareDestination(index: Int, stage: ComputerUseBrowserWorkflowRequest.Stage,
        label: String) async throws -> ComputerUseBrowserNavigationTarget? {
        let document = try await browser.acquireObservedDocument(taskID: taskID)
        let evidence = try await browser.observePage(document: document)
        switch stage.kind {
        case .link:
            let matches = evidence.page.links.filter { $0.label.caseInsensitiveCompare(label) == .orderedSame }
            guard matches.count == 1, let link = matches.first else { return nil }
            return try await browser.prepareLinkNavigation(linkID: link.id, evidence: evidence)
        case .formQuery:
            let matches = evidence.page.controls.filter { $0.label.caseInsensitiveCompare(label) == .orderedSame && !$0.disabled }
            guard matches.count == 1, let control = matches.first else { return nil }
            if index > 0, case .edits = request.stages[index - 1].kind {
                // Re-observation cannot replace the original edit requirements
                // with whatever values manual control left on the page.
                guard let child = textChildren[index - 1] else { throw ComputerUseBrowserError.formQueryUnavailable }
                return try await child.prepareFormQuery(taskID: taskID,
                    promptDigest: ComputerUseTextTaskContract.digest(request.stages[index - 1].source),
                    controlID: control.id, evidence: evidence)
            }
            return try await browser.prepareFormQuery(controlID: control.id, evidence: evidence)
        default: throw ComputerUseTaskExecutionError.invalidContract
        }
    }

    private func navigationChild(_ index: Int, directory: URL, stepID: String) -> ComputerUseBrowserNavigationTask {
        if let child = navigationChildren[index] { return child }
        let child = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory, effectNamespace: stepID,
            observedNavigationStore: observedNavigationStore)
        navigationChildren[index] = child
        return child
    }
}

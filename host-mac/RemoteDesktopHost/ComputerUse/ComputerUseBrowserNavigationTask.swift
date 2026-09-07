import Foundation

/// A complete, bounded URL-navigation command. A mixed request must continue
/// to whole-goal planning without opening an unrelated partial workflow.
enum ComputerUseBrowserNavigationRequest {
    static func urls(in prompt: String) -> [URL]? {
        guard prompt.utf8.count <= 32 * 1_024 else { return nil }
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["navigate to ", "go to ", "visit ", "open "]
        if let prefix = prefixes.first(where: { text.lowercased().hasPrefix($0) }) {
            text.removeFirst(prefix.count)
        } else if !text.lowercased().hasPrefix("https://") && !text.lowercased().hasPrefix("http://") {
            return nil
        }
        let pattern = #"\"(https?://[^\"\s]+)\"|(https?://[^\s,]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard (1...4).contains(matches.count) else { return nil }
        var urls: [URL] = []
        var offset = 0
        for (index, match) in matches.enumerated() {
            var separator = source.substring(with: NSRange(location: offset, length: match.range.location - offset))
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if index > 0, let verb = prefixes.map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { separator.hasSuffix(" " + $0) }) {
                separator.removeLast(verb.count)
                separator = separator.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard index == 0 ? separator.isEmpty : [",", "then", ", then", "and", "and then"].contains(separator) else { return nil }
            let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            guard let url = URL(string: source.substring(with: range)),
                  let validated = ComputerUseOwnedBrowser.validatedURL(url) else { return nil }
            urls.append(validated)
            offset = NSMaxRange(match.range)
        }
        guard source.substring(from: offset).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return urls
    }
}

@MainActor
final class ComputerUseBrowserNavigationTask {
    private let browser: ComputerUseOwnedBrowser
    private let journalDirectory: URL
    /// Controlled fixtures can suspend after the durable attempt and before
    /// dispatch. Production supplies no callback; document validation always
    /// remains inside the browser's actual navigation boundary.
    private let beforeNavigationDispatch: (@MainActor (Int) async throws -> Void)?
    private let observedNavigationStore: (URL) throws -> ComputerUseTaskJournalStore
    private var execution: ComputerUseTaskExecution?
    private var retainedURLs: [URL] = []

    init(browser: ComputerUseOwnedBrowser, journalDirectory: URL,
         beforeNavigationDispatch: (@MainActor (Int) async throws -> Void)? = nil,
         observedNavigationStore: @escaping (URL) throws -> ComputerUseTaskJournalStore = { try .init(directory: $0) }) {
        self.browser = browser
        self.journalDirectory = journalDirectory
        self.beforeNavigationDispatch = beforeNavigationDispatch
        self.observedNavigationStore = observedNavigationStore
    }

    func execute(taskID: String, prompt: String, progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult? {
        guard let urls = ComputerUseBrowserNavigationRequest.urls(in: prompt) else { return nil }
        let promptDigest = ComputerUseTextTaskContract.digest(prompt)
        if let execution, execution.contract.taskID == taskID {
            guard execution.contract.promptDigest == promptDigest else { throw ComputerUseTaskExecutionError.journalMismatch }
        } else {
            try browser.claim(taskID: taskID)
            let authority = ComputerUseTaskContract.digest([browser.contextID, taskID])
            var predicates = [ComputerUseTaskContract.Predicate(id: "owned-context", entityID: "browser",
                kind: "task-ownership", expectedDigest: authority)]
            var steps: [ComputerUseTaskContract.Step] = []
            for (index, url) in urls.enumerated() {
                let id = ComputerUseTaskContract.digest([taskID, String(index), url.absoluteString])
                predicates.append(.init(id: "navigation-\(index)", entityID: "browser", kind: "navigation-receipt",
                    expectedDigest: ComputerUseTaskContract.digest([url.absoluteString])))
                predicates.append(.init(id: "current-\(index)", entityID: "browser", kind: "current-document",
                    expectedDigest: ComputerUseTaskContract.digest([url.absoluteString])))
                steps.append(.init(id: id, dependencies: steps.last.map { [$0.id] } ?? [],
                    operation: .init(capabilityID: "browser.navigate", entityID: "browser",
                        payloadDigest: ComputerUseTaskContract.digest([url.absoluteString]), payloadVersion: 1),
                    preconditions: index == 0 ? ["owned-context"] : ["owned-context", "current-\(index - 1)"],
                    postconditions: ["navigation-\(index)", "current-\(index)"]))
            }
            let contract = try ComputerUseTaskContract(taskID: taskID, promptDigest: promptDigest,
                entities: [.init(id: "browser", authorityDigest: authority)], predicates: predicates, steps: steps,
                invariants: ["owned-context"],
                outcomes: urls.indices.map { "navigation-\($0)" } + ["current-\(urls.count - 1)"])
            let store = try ComputerUseTaskJournalStore(directory: journalDirectory)
            var persistedJournal = try store.load(taskID: taskID)
            let indices = Dictionary(uniqueKeysWithValues: steps.enumerated().map { ($0.element.id, $0.offset) })
            execution = try ComputerUseTaskExecution(contract: contract, recovered: persistedJournal,
                observe: { [browser] predicate in
                    if predicate.id == "owned-context" { return browser.hasOwnership(taskID: taskID) }
                    guard let suffix = predicate.id.split(separator: "-").last, let index = Int(suffix),
                          urls.indices.contains(index) else { return false }
                    let operationID = contract.effectIdentity(for: contract.steps[index])
                    guard let receipt = browser.receipt(taskID: taskID, operationID: operationID),
                          receipt.requestedURL == urls[index] else { return false }
                    return predicate.kind == "navigation-receipt" || (browser.validate(receipt) && browser.hasRequiredPresentation)
                }, perform: { [browser, beforeNavigationDispatch] step, operationID in
                    guard let index = indices[step.id] else { throw ComputerUseTaskExecutionError.invalidContract }
                    let prerequisite: ComputerUseBrowserDocument?
                    if index > 0 {
                        let previousOperation = contract.effectIdentity(for: contract.steps[index - 1])
                        guard let previous = browser.receipt(taskID: taskID, operationID: previousOperation) else {
                            throw ComputerUseTaskExecutionError.preconditionFailed("current-\(index - 1)")
                        }
                        prerequisite = previous
                    } else { prerequisite = nil }
                    if let beforeNavigationDispatch { try await beforeNavigationDispatch(index) }
                    _ = try await browser.navigate(taskID: taskID, operationID: operationID,
                        to: urls[index], from: prerequisite)
                }, persist: { journal in
                    try store.save(journal, replacing: persistedJournal)
                    persistedJournal = journal
                }, acquireExecutionLease: {
                    try store.acquireExecution(taskID: taskID, expected: persistedJournal)
                }, assertOwnership: { [browser] in
                    guard browser.hasOwnership(taskID: taskID) else { throw ComputerUseBrowserError.ownershipLost }
                })
            retainedURLs = urls
        }
        guard let execution else { throw ComputerUseTaskExecutionError.invalidContract }
        do {
            try await execution.run { completed, total in progress("Opened page \(completed) of \(total)…") }
            guard let document = browser.currentDocument(taskID: taskID) else { throw ComputerUseBrowserError.pageChanged }
            return .completed("Opened \(retainedURLs.count == 1 ? "the page" : "all \(retainedURLs.count) pages") in the AI browser. Website: \(ComputerUseBrowserSite.displayName(for: document.committedURL))")
        } catch is CancellationError {
            throw CancellationError()
        } catch ComputerUseBrowserError.windowNotActive {
            return .userInterventionRequired(ComputerUseBrowserError.windowNotActive.localizedDescription)
        } catch ComputerUseTaskExecutionError.uncertainEffect {
            return .userInterventionRequired("The browser navigation was interrupted and cannot be verified. Check the AI browser before starting a new request.")
        } catch ComputerUseTaskExecutionError.preconditionFailed {
            return .userInterventionRequired("The AI browser page changed before the next navigation. Check it before starting a new request.")
        } catch ComputerUseBrowserError.pageChanged {
            return .userInterventionRequired("The AI browser page changed before the next navigation. Check it before starting a new request.")
        }
    }

    func close() { browser.close() }

    func stopBrowserActivity() { browser.stop() }

    func updateTaskControls(_ controls: ComputerUseBrowserTaskControls?,
        handler: @escaping (ComputerUseBrowserTaskControls, ComputerUseBrowserTaskControls.Action) -> Void) {
        browser.updateTaskControls(controls, handler: handler)
    }

    func reacquireAfterUserControl(taskID: String) async throws {
        try await browser.reacquireAfterUserControl(taskID: taskID)
    }

    func textTargetIfFrontmost(taskID: String) async throws -> ComputerUseBrowserTextTarget? {
        guard browser.isFrontmostWindow else { return nil }
        return ComputerUseBrowserTextTarget(browser: browser, document: try await browser.acquireObservedDocument(taskID: taskID))
    }

    func pageEvidenceIfFrontmost(taskID: String) async throws -> ComputerUseBrowserPageEvidence? {
        // Production requires the actual foreground browser window. An
        // explicitly headless fixture uses the same document/ownership path.
        guard browser.hasRequiredPresentation, browser.taskID != nil else { return nil }
        let document = try await browser.acquireObservedDocument(taskID: taskID)
        return try await browser.observePage(document: document)
    }

    func validatePageEvidence(_ evidence: ComputerUseBrowserPageEvidence) async throws {
        try await browser.validatePageEvidence(evidence)
    }

    func prepareLinkNavigation(linkID: String, evidence: ComputerUseBrowserPageEvidence) async throws -> ComputerUseBrowserNavigationTarget {
        try await browser.prepareLinkNavigation(linkID: linkID, evidence: evidence)
    }

    func prepareFormQuery(controlID: String, evidence: ComputerUseBrowserPageEvidence) async throws -> ComputerUseBrowserNavigationTarget {
        try await browser.prepareFormQuery(controlID: controlID, evidence: evidence)
    }

    /// Persist one host-selected effect independently of the whole task's
    /// remaining goals. The caller must supply the original prompt digest and
    /// a stable task-step operation ID; a page reference supplies neither.
    /// This journal records only identities/status, never URLs or form values.
    func openObservedDestination(_ target: ComputerUseBrowserNavigationTarget, promptDigest: String, operationID: String,
                                 willBeginEffect: () -> Void) async throws -> ComputerUseBrowserNavigationReceipt {
        func validDigest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        func checkOwnership() throws {
            try Task.checkCancellation()
            guard browser.contextID == target.contextID, browser.hasOwnership(taskID: target.taskID) else {
                throw ComputerUseBrowserError.ownershipLost
            }
        }
        try checkOwnership()
        guard validDigest(promptDigest), validDigest(operationID) else { throw ComputerUseTaskExecutionError.invalidContract }
        // The lookup key excludes document/context/payload: replacement
        // browsers and newly prepared targets must find the earlier record
        // and reject changed identity instead of treating it as a new effect.
        let journalID = ComputerUseTaskContract.digest(["observed-browser-effect-record-v1", target.taskID, operationID])
        let identity = ComputerUseTaskJournal(taskID: journalID, promptDigest: promptDigest,
            contractDigest: ComputerUseTaskContract.digest(["observed-browser-effect-binding-v1", target.taskID, operationID, target.payloadDigest]),
            stepIDs: [operationID], statuses: [.planned])
        let store = try observedNavigationStore(journalDirectory.appendingPathComponent("Observed Destinations", isDirectory: true))
        var persisted = try store.load(taskID: journalID)
        if let persisted {
            guard persisted.taskID == identity.taskID, persisted.promptDigest == identity.promptDigest,
                  persisted.contractDigest == identity.contractDigest, persisted.stepIDs == identity.stepIDs,
                  persisted.statuses.count == 1 else { throw ComputerUseTaskExecutionError.journalMismatch }
        }
        let lease = try store.acquireExecution(taskID: journalID, expected: persisted)
        defer { lease.release() }
        func save(_ status: ComputerUseTaskStepStatus) throws {
            try lease.assertOwnership()
            var next = identity
            next.statuses = [status]
            try store.save(next, replacing: persisted)
            persisted = next
        }
        try checkOwnership()
        if let status = persisted?.statuses.first, status != .planned {
            // No call to the effectful API during recovery. Even a verified
            // journal is insufficient to recreate a lost browser document.
            guard let receipt = browser.observedNavigationReceipt(for: target, operationID: operationID) else {
                if status == .attempted { try save(.uncertain) }
                throw ComputerUseBrowserError.observedNavigationUncertain
            }
            if status != .verified { try save(.verified) }
            try checkOwnership()
            return receipt
        }
        if persisted == nil { try save(.planned) }
        do {
            let receipt = try await browser.openObservedDestination(target, operationID: operationID, willBeginEffect: {
                try checkOwnership()
                // This throwing callback runs after DOM validation and before
                // any WebKit load. Storage failure cannot authorize a request.
                try save(.attempted)
                willBeginEffect()
            })
            guard browser.observedNavigationReceipt(for: target, operationID: operationID) == receipt,
                  persisted?.statuses.first == .attempted else { throw ComputerUseBrowserError.observedNavigationUncertain }
            try save(.verified)
            try checkOwnership()
            return receipt
        } catch {
            // Keep late native confirmation without converting Pause/Stop or
            // cancellation into a successful caller result. Failed persistence
            // leaves the durable attempt to be reconciled, never replayed.
            if persisted?.statuses.first == .attempted {
                try? save(browser.observedNavigationReceipt(for: target, operationID: operationID) == nil ? .uncertain : .verified)
            }
            throw error
        }
    }

    func scrollViewport(_ direction: OSAtlasScrollDirection, evidence: ComputerUseBrowserPageEvidence,
                        operationID: String, willBeginEffect: () -> Void) async throws -> ComputerUseBrowserViewportScrollReceipt {
        try await browser.scrollViewport(direction, evidence: evidence, operationID: operationID, willBeginEffect: willBeginEffect)
    }

    static var journalDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Remote Desktop Host/Computer Use Tasks/Browser Steps", isDirectory: true)
    }
}

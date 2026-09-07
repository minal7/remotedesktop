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
    private var execution: ComputerUseTaskExecution?
    private var retainedURLs: [URL] = []

    init(browser: ComputerUseOwnedBrowser, journalDirectory: URL,
         beforeNavigationDispatch: (@MainActor (Int) async throws -> Void)? = nil) {
        self.browser = browser
        self.journalDirectory = journalDirectory
        self.beforeNavigationDispatch = beforeNavigationDispatch
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

    func openObservedDestination(_ target: ComputerUseBrowserNavigationTarget, operationID: String,
                             willBeginEffect: () -> Void) async throws -> ComputerUseBrowserNavigationReceipt {
        try await browser.openObservedDestination(target, operationID: operationID, willBeginEffect: willBeginEffect)
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

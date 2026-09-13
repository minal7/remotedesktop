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
final class ComputerUseBrowserNavigationTask: ComputerUseBrowserResearchAdmitting {
    private let browser: ComputerUseOwnedBrowser
    private let journalDirectory: URL
    private let effectNamespace: String?
    /// Controlled fixtures can suspend after the durable attempt and before
    /// dispatch. Production supplies no callback; document validation always
    /// remains inside the browser's actual navigation boundary.
    private let beforeNavigationDispatch: (@MainActor (Int) async throws -> Void)?
    private let observedNavigationStore: (URL) throws -> ComputerUseTaskJournalStore
    private var execution: ComputerUseTaskExecution?
    private var retainedURLs: [URL] = []
    private var workflow: ComputerUseBrowserWorkflowTask?
    private var research: ComputerUseBrowserResearchTask?

    init(browser: ComputerUseOwnedBrowser, journalDirectory: URL, effectNamespace: String? = nil,
         beforeNavigationDispatch: (@MainActor (Int) async throws -> Void)? = nil,
         observedNavigationStore: @escaping (URL) throws -> ComputerUseTaskJournalStore = { try .init(directory: $0) }) {
        self.browser = browser
        self.journalDirectory = journalDirectory
        self.effectNamespace = effectNamespace
        self.beforeNavigationDispatch = beforeNavigationDispatch
        self.observedNavigationStore = observedNavigationStore
    }

    func execute(taskID: String, prompt: String, progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult? {
        guard let urls = ComputerUseBrowserNavigationRequest.urls(in: prompt) else { return nil }
        if let effectNamespace {
            guard effectNamespace.utf8.count == 64,
                  effectNamespace.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw ComputerUseTaskExecutionError.invalidContract
            }
        }
        let promptDigest = ComputerUseTextTaskContract.digest(prompt)
        if let research, research.taskID != taskID { research.retire() }
        if let execution, execution.contract.taskID == taskID {
            guard execution.contract.promptDigest == promptDigest else { throw ComputerUseTaskExecutionError.journalMismatch }
        } else {
            try browser.claim(taskID: taskID)
            let authority = ComputerUseTaskContract.digest([browser.contextID, taskID])
            var predicates = [ComputerUseTaskContract.Predicate(id: "owned-context", entityID: "browser",
                kind: "task-ownership", expectedDigest: authority)]
            var steps: [ComputerUseTaskContract.Step] = []
            for (index, url) in urls.enumerated() {
                let identity = [taskID, String(index), url.absoluteString]
                let id = ComputerUseTaskContract.digest(effectNamespace.map { ["browser-workflow-child-v1", $0] + identity } ?? identity)
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

    func executeWorkflow(taskID: String, request: ComputerUseBrowserWorkflowRequest, injector: InputInjector,
                         progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        if let research, research.taskID != taskID { research.retire() }
        if let workflow, workflow.taskID == taskID {
            guard workflow.request.prompt.utf8.elementsEqual(request.prompt.utf8) else {
                throw ComputerUseTaskExecutionError.journalMismatch
            }
        } else {
            workflow = ComputerUseBrowserWorkflowTask(taskID: taskID, request: request, browser: browser,
                directory: journalDirectory.appendingPathComponent("Workflows", isDirectory: true), injector: injector,
                observedNavigationStore: observedNavigationStore)
        }
        guard let workflow else { throw ComputerUseTaskExecutionError.invalidContract }
        do { return try await workflow.run(progress: progress) }
        catch ComputerUseBrowserError.ownershipLost {
            return .userInterventionRequired("Control changed during the browser task. Finish the manual step, then choose Resume to continue the original request.")
        }
        catch ComputerUseBrowserError.windowNotActive {
            return .userInterventionRequired(ComputerUseBrowserError.windowNotActive.localizedDescription)
        } catch ComputerUseBrowserError.pageChanged, ComputerUseBrowserError.formQueryUnavailable,
                ComputerUseBrowserError.observedNavigationUncertain, ComputerUseTaskExecutionError.uncertainEffect,
                ComputerUseTaskExecutionError.preconditionFailed, ComputerUseTaskExecutionError.incompleteOutcome,
                ComputerUseTextTaskError.staleTarget, ComputerUseTextTaskError.uncertainEffect,
                ComputerUseTextTaskError.incompleteOutcome {
            return .userInterventionRequired("The browser state or an earlier action could not be verified. The original request is still pending; check the page before continuing.")
        }
    }

    /// The first call fixes the goal's clock. Resume/retrieval never rebuilds
    /// it from a later wall clock or replaces the exact original request.
    func prepareResearchTask(taskID: String, prompt: String, goalPlanner: any ComputerUseBrowserGoalPlanning,
                             resultPlanner: any ComputerUseBrowserResultPlanning, mayAct: @escaping @MainActor () -> Bool,
                             referenceDate: Date = Date(), timeZoneIdentifier: String = TimeZone.current.identifier,
                             planningWorker: ComputerUsePlanningWorker = .shared, planningTimeout: TimeInterval = 30,
                             workBudget: ComputerUseBrowserWorkBudget? = nil) throws -> ComputerUseBrowserResearchTask {
        if let research, research.taskID == taskID {
            guard research.input.prompt.utf8.elementsEqual(prompt.utf8) else { throw ComputerUseBrowserResearchTask.Failure.goalChanged }
            return research
        }
        let input = try ComputerUseBrowserGoalInput(taskID: taskID, prompt: prompt, referenceDate: referenceDate, timeZoneIdentifier: timeZoneIdentifier)
        guard research?.isOperating != true else { throw ComputerUseBrowserResearchTask.Failure.busy }
        let replacement = ComputerUseBrowserResearchTask(input: input, browser: browser, goalPlanner: goalPlanner,
            resultPlanner: resultPlanner, navigationJournalDirectory: journalDirectory.appendingPathComponent("Research", isDirectory: true),
            navigationStore: observedNavigationStore, browserAdmission: self,
            planningWorker: planningWorker, planningTimeout: planningTimeout, workBudget: workBudget, mayAct: mayAct)
        research?.retire()
        research = replacement
        return replacement
    }

    func admitBrowser(for owner: ComputerUseBrowserResearchTask, admissionID: UUID, checkCurrent: () throws -> Void) async throws -> ComputerUseBrowserHandbackRequirement {
        try Task.checkCancellation(); try checkCurrent()
        guard research === owner else { throw ComputerUseBrowserError.handbackContextLost }
        try owner.validateBrowserAdmission(admissionID)
        return try await browser.admitResearchSession(taskID: owner.taskID, assertAdmission: {
            try checkCurrent()
            guard self.research === owner else { throw ComputerUseBrowserError.handbackContextLost }
            try owner.validateBrowserAdmission(admissionID)
        })
    }

    func researchTask(taskID: String) -> ComputerUseBrowserResearchTask? { research?.taskID == taskID ? research : nil }
    func browserTaskID(forExecution taskID: String) -> String {
        research?.executionTaskID == taskID ? (research?.taskID ?? taskID) : taskID
    }
    func pauseForUserControl(taskID: String) {
        if let research, research.executionTaskID == taskID {
            // An accepted answer may own a different execution ID from the
            // browser root. A stale root command cannot pause that successor.
            let requirement = browser.handbackRequirement(taskID: research.taskID, required: true)
            research.pause()
            guard self.research === research, research.executionTaskID == taskID,
                  browser.handbackRequirement(taskID: research.taskID, required: true) == requirement else { return }
            browser.prepareForUserControl(taskID: research.taskID)
        } else {
            guard research?.taskID != taskID else { return }
            browser.prepareForUserControl(taskID: taskID)
        }
    }
    func resumeResearchTask(taskID: String) async throws {
        if research?.executionTaskID == taskID { try await research?.resumeAfterUserControl() }
    }
    func retireResearchTask(taskID: String) { if research?.executionTaskID == taskID { research?.retire() } }

    func close() { research?.retire(); browser.close() }

    var hasFrontmostOwnedWindow: Bool { browser.hasFrontmostOwnedWindow }

    func stopBrowserActivity() { research?.retire(); browser.stop() }

    func stopBrowserActivity(taskID: String) {
        let browserTaskID = browserTaskID(forExecution: taskID)
        retireResearchTask(taskID: taskID)
        guard browser.taskID == browserTaskID else { return }
        browser.stop()
    }

    func updateTaskControls(_ controls: ComputerUseBrowserTaskControls?,
        handler: @escaping (ComputerUseBrowserTaskControls, ComputerUseBrowserTaskControls.Action) -> Void) {
        browser.updateTaskControls(controls, handler: handler)
    }

    func handbackRequirement(taskID: String, required: Bool = false) -> ComputerUseBrowserHandbackRequirement? {
        browser.handbackRequirement(taskID: taskID, required: required)
    }

    func reacquireAfterUserControl(_ requirement: ComputerUseBrowserHandbackRequirement) async throws {
        try await browser.reacquireAfterUserControl(taskID: requirement.taskID, requirement: requirement)
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

    func captureAgentObservation(taskID: String, preserving session: ComputerUseOwnedBrowser.AgentObservation? = nil) async throws -> ComputerUseOwnedBrowser.AgentObservation {
        // Live pages can apply sticky layout after a multi-second anchor
        // transition. Bound fresh reads while that layout settles; retain
        // immediate cancellation/ownership failure and never replay input.
        let retryDeadline = ContinuousClock.now + .seconds(8)
        while true {
            do {
                if let session { try browser.validateAgentSession(session) }
                let document = try await browser.acquireObservedDocument(taskID: taskID)
                if let session { try browser.validateAgentSession(session) }
                return try await browser.captureAgentObservation(document: document)
            } catch let error as ComputerUseBrowserError {
                // A native click can start navigation between acquiring the
                // document and taking its image. Retry only this read, never
                // the click, proposal or navigation. Ownership, sign-in and
                // source-policy failures still return immediately.
                guard (error == .pageChanged || error == .busy), ContinuousClock.now < retryDeadline else { throw error }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func captureInitialAgentObservation(taskID: String, expectedSessionIdentity: String?) async throws -> ComputerUseOwnedBrowser.InitialAgentObservation? {
        try await browser.captureInitialAgentObservation(taskID: taskID, expectedSessionIdentity: expectedSessionIdentity)
    }

    func validateInitialAgentObservation(_ observation: ComputerUseOwnedBrowser.InitialAgentObservation) throws {
        try browser.validateInitialAgentObservation(observation)
    }

    func performInitialAgentNavigation(_ url: URL, observation: ComputerUseOwnedBrowser.InitialAgentObservation,
        operationID: String, willBeginEffect: () throws -> Void) async throws {
        try await browser.performInitialAgentNavigation(url, observation: observation, operationID: operationID, willBeginEffect: willBeginEffect)
    }

    func validateAgentObservation(_ observation: ComputerUseOwnedBrowser.AgentObservation) async throws {
        try await browser.validateAgentObservation(observation)
    }

    func predictedAgentAction(_ action: ComputerUseFaraAction, observation: ComputerUseOwnedBrowser.AgentObservation) throws -> ComputerUsePredictedAction? {
        try browser.predictedAgentAction(action, observation: observation)
    }

    func inspectAgentTarget(_ action: ComputerUseFaraAction, observation: ComputerUseOwnedBrowser.AgentObservation) async throws -> ComputerUseOwnedBrowser.AgentTarget? {
        try await browser.inspectAgentTarget(action, observation: observation)
    }

    func validateAgentTarget(_ target: ComputerUseOwnedBrowser.AgentTarget) async throws {
        try await browser.validateAgentTarget(target)
    }

    func performAgentInput(_ action: ComputerUseFaraAction, observation: ComputerUseOwnedBrowser.AgentObservation, operationID: String? = nil,
                           target: ComputerUseOwnedBrowser.AgentTarget? = nil,
                           willBeginEffect: () throws -> Void) async throws {
        try await browser.performAgentInput(action, observation: observation, operationID: operationID, target: target, willBeginEffect: willBeginEffect)
    }

    func prepareLinkNavigation(linkID: String, evidence: ComputerUseBrowserPageEvidence) async throws -> ComputerUseBrowserNavigationTarget {
        try await browser.prepareLinkNavigation(linkID: linkID, evidence: evidence)
    }

    func prepareFormQuery(controlID: String, evidence: ComputerUseBrowserPageEvidence) async throws -> ComputerUseBrowserNavigationTarget {
        try await browser.prepareFormQuery(controlID: controlID, evidence: evidence)
    }

    /// Called on a later run with the original stage's retained target. Only
    /// a proven-unsent plan may select a fresh page reference. Hold the same
    /// execution lease through preparation and replacement so an older runner
    /// cannot dispatch while this binding changes. No navigation occurs here.
    func refreshUnsentObservedDestination(_ target: ComputerUseBrowserNavigationTarget,
        promptDigest: String, operationID: String,
        prepare: () async throws -> ComputerUseBrowserNavigationTarget?) async throws -> ComputerUseBrowserNavigationTarget? {
        switch try await replanUnsentObservedDestination(target, promptDigest: promptDigest, operationID: operationID, prepare: prepare) {
        case .refreshed(let target), .requiresReconciliation(let target): return target
        case .noSelection: return nil
        }
    }

    enum ObservedReplanResult {
        case refreshed(ComputerUseBrowserNavigationTarget)
        case requiresReconciliation(ComputerUseBrowserNavigationTarget)
        case noSelection
    }

    /// A failed replacement can leave either known binding visible. Resolve
    /// only that metadata under a fresh lease: no reading, selection, write or
    /// navigation occurs. The next open/replan acquires its own lease and
    /// revalidates this identity, so an intervening writer cannot grant effect
    /// authority through this result.
    func resolveUnconfirmedObservedDestination(_ target: ComputerUseBrowserNavigationTarget,
        replacement: ComputerUseBrowserNavigationTarget, promptDigest: String, operationID: String,
        checkCurrent: () throws -> Void) throws -> ComputerUseBrowserNavigationTarget {
        try Task.checkCancellation(); try checkCurrent()
        guard target.taskID.utf8.elementsEqual(replacement.taskID.utf8), target.contextID == replacement.contextID,
              browser.contextID == target.contextID,
              let session = browser.handbackRequirement(taskID: target.taskID, required: true) else {
            throw ComputerUseTaskExecutionError.journalMismatch
        }
        try browser.validateWorkflowSession(session)
        let identity = try Self.observedIdentity(target, promptDigest: promptDigest, operationID: operationID)
        let alternative = try Self.observedIdentity(replacement, promptDigest: promptDigest, operationID: operationID)
        let store = try observedNavigationStore(journalDirectory.appendingPathComponent("Observed Destinations", isDirectory: true))
        let persisted = try store.load(taskID: identity.taskID)
        let resolved: ComputerUseBrowserNavigationTarget
        if let persisted {
            if Self.matchesObservedIdentity(persisted, identity) { resolved = target }
            else if Self.matchesObservedIdentity(persisted, alternative) { resolved = replacement }
            else { throw ComputerUseTaskExecutionError.journalMismatch }
        } else { resolved = target }
        let lease = try store.acquireExecution(taskID: identity.taskID, expected: persisted)
        defer { lease.release() }
        try Task.checkCancellation(); try checkCurrent()
        try lease.assertOwnership(); try browser.validateWorkflowSession(session)
        try browser.validateUnretiredNavigation(operationID: operationID)
        return resolved
    }

    /// Distinguish a committed refresh from a retained attempted target, even
    /// when both have the same payload. Target equality is not replan authority.
    func replanUnsentObservedDestination(_ target: ComputerUseBrowserNavigationTarget,
        promptDigest: String, operationID: String,
        prepare: () async throws -> ComputerUseBrowserNavigationTarget?) async throws -> ObservedReplanResult {
        let identity = try Self.observedIdentity(target, promptDigest: promptDigest, operationID: operationID)
        guard browser.contextID == target.contextID,
              let session = browser.handbackRequirement(taskID: target.taskID, required: true) else {
            throw ComputerUseBrowserError.ownershipLost
        }
        try browser.validateWorkflowSession(session)
        let store = try observedNavigationStore(journalDirectory.appendingPathComponent("Observed Destinations", isDirectory: true))
        let persisted = try store.load(taskID: identity.taskID)
        if let persisted { try Self.validateObservedIdentity(persisted, identity) }
        let lease = try store.acquireExecution(taskID: identity.taskID, expected: persisted)
        defer { lease.release() }
        func checkOwnership() throws {
            try Task.checkCancellation()
            try lease.assertOwnership()
            try browser.validateWorkflowSession(session)
            try browser.validateUnretiredNavigation(operationID: operationID)
        }
        try checkOwnership()
        guard persisted == nil || persisted?.statuses == [.planned],
              !browser.hasObservedNavigationAttempt(operationID: operationID) else { return .requiresReconciliation(target) }
        guard let fresh = try await prepare() else { return .noSelection }
        try checkOwnership()
        guard fresh.taskID.utf8.elementsEqual(target.taskID.utf8), fresh.contextID == target.contextID else {
            throw ComputerUseTaskExecutionError.journalMismatch
        }
        try await browser.validateObservedDestination(fresh)
        try checkOwnership()
        guard !browser.hasObservedNavigationAttempt(operationID: operationID) else { return .requiresReconciliation(target) }
        let replacement = try Self.observedIdentity(fresh, promptDigest: promptDigest, operationID: operationID)
        if let persisted { try store.replaceUnattemptedBinding(replacement, replacing: persisted) }
        else { try store.save(replacement, replacing: nil) }
        // A failed durable write must not publish a replacement to the caller.
        return .refreshed(fresh)
    }

    private static func observedIdentity(_ target: ComputerUseBrowserNavigationTarget,
        promptDigest: String, operationID: String) throws -> ComputerUseTaskJournal {
        func validDigest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard validDigest(promptDigest), validDigest(operationID) else { throw ComputerUseTaskExecutionError.invalidContract }
        // Excluding document/context/payload makes a changed target find the
        // earlier record, rather than silently becoming a second operation.
        return ComputerUseTaskJournal(
            taskID: ComputerUseTaskContract.digest(["observed-browser-effect-record-v1", target.taskID, operationID]),
            promptDigest: promptDigest,
            contractDigest: ComputerUseTaskContract.digest(["observed-browser-effect-binding-v1", target.taskID, operationID, target.payloadDigest]),
            stepIDs: [operationID], statuses: [.planned])
    }

    private static func matchesObservedBinding(_ saved: ComputerUseTaskJournal, _ identity: ComputerUseTaskJournal) -> Bool {
        saved.taskID == identity.taskID && saved.promptDigest == identity.promptDigest
            && saved.contractDigest == identity.contractDigest && saved.stepIDs == identity.stepIDs && saved.statuses.count == 1
    }

    private static func matchesObservedIdentity(_ saved: ComputerUseTaskJournal, _ identity: ComputerUseTaskJournal) -> Bool {
        matchesObservedBinding(saved, identity) && saved.retirementDigest == nil && saved.retainedPrefixCount == nil
    }

    private static func validateObservedIdentity(_ saved: ComputerUseTaskJournal, _ identity: ComputerUseTaskJournal) throws {
        guard matchesObservedIdentity(saved, identity) else { throw ComputerUseTaskExecutionError.journalMismatch }
    }

    /// Permanently cancel one proven-unsent operation before another proposal
    /// gets a new identity. Never clear attempted/uncertain/verified history.
    /// A matching tombstone is rewritten to resolve an earlier flush failure.
    func retireUnsentObservedDestination(_ target: ComputerUseBrowserNavigationTarget,
        promptDigest: String, operationID: String, checkCurrent: () throws -> Void) throws -> String? {
        try Task.checkCancellation(); try checkCurrent()
        guard browser.contextID == target.contextID,
              let session = browser.handbackRequirement(taskID: target.taskID, required: true) else {
            throw ComputerUseBrowserError.ownershipLost
        }
        try browser.validateWorkflowSession(session)
        let identity = try Self.observedIdentity(target, promptDigest: promptDigest, operationID: operationID)
        let digest = ComputerUseTaskContract.digest(["observed-browser-unsent-retirement-v1",
            identity.taskID, identity.promptDigest, identity.contractDigest])
        let store = try observedNavigationStore(journalDirectory.appendingPathComponent("Observed Destinations", isDirectory: true))
        let persisted = try store.load(taskID: identity.taskID)
        let lease = try store.acquireExecution(taskID: identity.taskID, expected: persisted)
        defer { lease.release() }
        if let persisted {
            guard Self.matchesObservedBinding(persisted, identity), persisted.retainedPrefixCount == nil,
                  persisted.retirementDigest == nil || persisted.retirementDigest == digest else {
                throw ComputerUseTaskExecutionError.journalMismatch
            }
            guard persisted.statuses == [.planned] else { return nil }
        }
        func check() throws {
            try Task.checkCancellation(); try checkCurrent(); try lease.assertOwnership()
            try browser.validateWorkflowSession(session)
        }
        try check()
        guard try browser.retireUnsentObservedDestination(target, operationID: operationID) else { return nil }
        try check()
        let retired = ComputerUseTaskJournal(taskID: identity.taskID, promptDigest: identity.promptDigest,
            contractDigest: identity.contractDigest, stepIDs: identity.stepIDs, statuses: persisted?.statuses ?? identity.statuses,
            retirementDigest: digest)
        try store.retireUnsent(retired, replacing: persisted)
        // Publish the durable fact before the owner's post-operation control
        // check. A late Pause must not erase a successful retirement.
        return digest
    }

    /// Persist one host-selected effect independently of the whole task's
    /// remaining goals. The caller must supply the original prompt digest and
    /// a stable task-step operation ID; a page reference supplies neither.
    /// This journal records only identities/status, never URLs or form values.
    func openObservedDestination(_ target: ComputerUseBrowserNavigationTarget, promptDigest: String, operationID: String,
                                 willBeginEffect: () -> Void) async throws -> ComputerUseBrowserNavigationReceipt {
        func checkOwnership() throws {
            try Task.checkCancellation()
            guard browser.contextID == target.contextID, browser.hasOwnership(taskID: target.taskID) else {
                throw ComputerUseBrowserError.ownershipLost
            }
        }
        try checkOwnership()
        let identity = try Self.observedIdentity(target, promptDigest: promptDigest, operationID: operationID)
        let journalID = identity.taskID
        let store = try observedNavigationStore(journalDirectory.appendingPathComponent("Observed Destinations", isDirectory: true))
        var persisted = try store.load(taskID: journalID)
        if let persisted { try Self.validateObservedIdentity(persisted, identity) }
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
        try browser.validateUnretiredNavigation(operationID: operationID)
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
        guard !browser.hasNavigationAttempt(operationID: operationID) else { throw ComputerUseBrowserError.observedNavigationUncertain }
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

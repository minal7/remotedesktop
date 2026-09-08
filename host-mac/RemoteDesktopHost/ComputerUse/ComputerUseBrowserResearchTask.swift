import Foundation

@MainActor
protocol ComputerUseBrowserResearchAdmitting: AnyObject {
    func admitBrowser(for owner: ComputerUseBrowserResearchTask, admissionID: UUID, checkCurrent: () throws -> Void) async throws -> ComputerUseBrowserHandbackRequirement
}

/// Only the admission path can request this pre-session handoff. A busy or
/// inactive previous page is not a terminal failure of the new research goal.
struct ComputerUseBrowserResearchAdmissionPause: Error {
    let reason: ComputerUseBrowserError
    fileprivate init(_ reason: ComputerUseBrowserError) { self.reason = reason }
}

/// Historical navigation only. A receipt is neither a verified offer nor an
/// answer. No URL, account state or model-authored description is retained here.
struct ComputerUseBrowserResearchVisit: Equatable, Sendable {
    enum Kind: String, Sendable { case search, resultLink }
    let kind: Kind
    let operationID: String
    let goalRevision: String
    let rootDigest: String
    fileprivate init(kind: Kind, document: ComputerUseBrowserDocument, goal: ComputerUseBrowserGoalInput) {
        self.kind = kind; operationID = document.operationID; goalRevision = goal.digest; rootDigest = goal.rootDigest
    }
}

/// Owns the canonical goal revision and read/planning work for one browser
/// research task, including retained result-link navigation. It does not
/// compile the complete research action plan or terminal research answers.
@MainActor
final class ComputerUseBrowserResearchTask {
    enum Failure: Error, Equatable { case busy, paused, retired, goalChanged, interpretationRequired, questionPending, browserRequired, navigationPending, navigationUnavailable }
    struct Interpretation: Sendable {
        let proposal: ComputerUseBrowserGoalProposal
        let scalars: ComputerUseBrowserScalarRequirements
        var sources: ComputerUseBrowserSourceRequirements { .init(proposal: proposal) }
    }
    struct LinkChoice: Sendable { let candidateID: String; let linkID: String }
    enum InitialSearchState: Equatable, Sendable { case notPrepared, pending, confirmed }
    let taskID: String
    private let browser: ComputerUseOwnedBrowser
    private let goalPlanner: any ComputerUseBrowserGoalPlanning
    private let resultPlanner: any ComputerUseBrowserResultPlanning
    private let mayAct: @MainActor () -> Bool
    private let clarification: ComputerUseBrowserGoalClarification
    private let navigation: ComputerUseBrowserResearchNavigation?
    private let navigationDirectory: URL?
    private let navigationStore: (URL) throws -> ComputerUseTaskJournalStore
    private weak var browserAdmission: (any ComputerUseBrowserResearchAdmitting)?
    private let requiresBrowserAdmission: Bool
    private var browserAdmissionID: UUID?
    private var initialSearch: ComputerUseBrowserInitialSearch?
    private var sourcePolicy: ComputerUseBrowserSourcePolicy?
    private var researchSources: ComputerUseBrowserResearchSources?
    private var sourcePolicyInstalled = false
    private var interpretation: Interpretation?
    private var latestCandidates: ComputerUseBrowserResultCandidates?
    private var session: ComputerUseBrowserHandbackRequirement?
    private var handback: ComputerUseBrowserHandbackRequirement?
    private var isPaused = false
    private var isRetired = false
    private var operationID: UUID?
    private var cancelOperation: (() -> Void)?
    private var controlEpoch = UUID()
    private var hasQuestion = false
    private(set) var confirmedNavigationHistory: [ComputerUseBrowserResearchVisit] = []

    var input: ComputerUseBrowserGoalInput { clarification.input }
    /// Transport correlation advances with accepted answers; browser effects,
    /// session identity and the original goal keep taskID as their root.
    var executionTaskID: String { input.clarifications.last?.answerTaskID ?? taskID }
    var isOperating: Bool { operationID != nil }
    var hasPendingNavigation: Bool { initialSearch?.isPending == true || navigation?.pendingSelection != nil }
    /// Confirmed means a historical navigation receipt, never a completed
    /// research answer. A driver can continue without proposing a second first
    /// search after handback or an accepted clarification answer.
    var initialSearchState: InitialSearchState {
        guard let initialSearch else { return .notPrepared }
        return initialSearch.isPending ? .pending : .confirmed
    }

    /// The capability router checks the retained revision and local lifecycle
    /// around delegation. Individual owner operations still validate the actual
    /// browser session, page and effect evidence at their own boundaries.
    func validateDriverContinuation(_ expected: ComputerUseBrowserGoalInput) throws {
        try requireIdle()
        guard !hasQuestion else { throw Failure.questionPending }
        guard input == expected else { throw Failure.goalChanged }
    }

    /// Configure one immutable policy per accepted goal revision. Pending
    /// effects retain their original policy; no browser is allocated here.
    func configureSourcePolicy(_ policy: ComputerUseBrowserSourcePolicy) throws {
        try configureSourcePolicy(policy, sources: nil)
    }

    private func configureSourcePolicy(_ policy: ComputerUseBrowserSourcePolicy, sources: ComputerUseBrowserResearchSources?) throws {
        try requireIdle()
        guard !hasPendingNavigation, !hasQuestion, policy.taskID == taskID,
              policy.rootDigest == input.rootDigest, policy.goalRevision == input.digest else { throw Failure.goalChanged }
        if let sourcePolicy, sourcePolicy.goalRevision == policy.goalRevision, sourcePolicy != policy { throw Failure.goalChanged }
        let captured = input, epoch = controlEpoch
        if let session { try browser.installSourcePolicy(policy, replacing: sourcePolicyInstalled ? sourcePolicy?.digest : nil, session: session) }
        if !isRetired, input == captured {
            sourcePolicy = policy; sourcePolicyInstalled = session != nil; latestCandidates = nil
            // Retain the complete selected plan alongside a known native
            // installation before a reentrant Pause can reject publication.
            if let sources { researchSources = sources }
        }
        try checkCurrent(captured)
        guard controlEpoch == epoch else { throw Failure.paused }
    }

    func configureResearchSources(_ sources: ComputerUseBrowserResearchSources) throws {
        try requireIdle()
        guard sources.answerPolicy.goalRevision == input.digest else { throw Failure.goalChanged }
        if let previous = researchSources, previous.policy.goalRevision == input.digest,
           previous.digest != sources.digest { throw Failure.goalChanged }
        try configureSourcePolicy(sources.policy, sources: sources)
    }

    init(input: ComputerUseBrowserGoalInput, browser: ComputerUseOwnedBrowser,
         goalPlanner: any ComputerUseBrowserGoalPlanning, resultPlanner: any ComputerUseBrowserResultPlanning,
         navigationJournalDirectory: URL? = nil,
         navigationStore: @escaping (URL) throws -> ComputerUseTaskJournalStore = { try .init(directory: $0) },
         browserAdmission: (any ComputerUseBrowserResearchAdmitting)? = nil,
         mayAct: @escaping @MainActor () -> Bool, now: @escaping () -> Date = Date.init) {
        taskID = input.taskID; self.browser = browser; self.goalPlanner = goalPlanner; self.resultPlanner = resultPlanner
        self.mayAct = mayAct; clarification = .init(input: input, now: now)
        navigationDirectory = navigationJournalDirectory; self.navigationStore = navigationStore
        self.browserAdmission = browserAdmission; requiresBrowserAdmission = browserAdmission != nil
        navigation = navigationJournalDirectory.map { .init(input: input, browser: browser, journalDirectory: $0, navigationStore: navigationStore) }
    }

    func interpretGoal() async throws -> Interpretation {
        try requireIdle()
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        if let interpretation, interpretation.proposal.input.digest == input.digest { return interpretation }
        let captured = input
        let result = try await operate { [self] in
            // When this task already owns a page, discover login/control loss
            // before asking the model. No browser is created or claimed here.
            try await checkPageBeforePlanning(goal: captured)
            let proposal = try await goalPlanner.propose(captured)
            try checkCurrent(captured)
            guard proposal.input.digest == captured.digest else { throw Failure.goalChanged }
            return Interpretation(proposal: proposal, scalars: .init(proposal: proposal))
        }
        interpretation = result
        return result
    }

    /// Converts only this owner's current, validated model interpretation to
    /// a host question request. This neither issues a reference nor asks for
    /// another proposal; the host still binds the live controller/session.
    func proposedQuestionRequest() throws -> ComputerUseBrowserQuestionRequest? {
        try requireIdle()
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let interpretation, interpretation.proposal.input.digest == input.digest else { throw Failure.interpretationRequired }
        if let question = interpretation.proposal.question {
            return .init(taskID: taskID, inputDigest: input.digest, topic: question.topic, requirementIDs: question.requirementIDs)
        }
        guard interpretation.proposal.disposition == .research else { return nil }
        let unresolved = Set(interpretation.sources.unresolved.map(\.requirementID))
        let scope = interpretation.proposal.requirements.filter { unresolved.contains($0.id) && ComputerUseBrowserClarificationTopic.source.accepts($0) }
        guard !scope.isEmpty else { return nil }
        return .init(taskID: taskID, inputDigest: input.digest, topic: .source, requirementIDs: Array(scope.prefix(8)).map(\.id))
    }

    /// Propose a first search from the complete retained user source. This
    /// neither chooses a website nor opens a page, and cannot replace a pending
    /// navigation or a question. Dispatch requires its own retained action.
    func planInitialSearch(using planner: any ComputerUseBrowserSearchPlanning) async throws -> ComputerUseBrowserSearchQuery {
        try requireIdle()
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let interpretation, interpretation.proposal.input.digest == input.digest,
              interpretation.proposal.disposition == .research else { throw Failure.interpretationRequired }
        let captured = input
        return try await operate { [self] in
            try await checkPageBeforePlanning(goal: captured)
            let query = try await planner.propose(interpretation.proposal)
            try checkCurrent(captured)
            guard query.goalDigest == captured.digest, query.interpretationDigest == interpretation.proposal.digest else {
                throw Failure.goalChanged
            }
            return query
        }
    }

    /// Provider selection is host-owned and must respect the complete goal.
    /// Neither copied query terms nor a successful first load complete it.
    func openInitialSearch(_ query: ComputerUseBrowserSearchQuery, provider: ComputerUseBrowserSearchProvider) async throws -> ComputerUseBrowserDocument {
        try requireIdle()
        guard !hasQuestion else { throw Failure.questionPending }
        guard navigation?.pendingSelection == nil else { throw Failure.navigationPending }
        guard let directory = navigationDirectory else { throw Failure.navigationUnavailable }
        guard let interpretation, interpretation.proposal.input.digest == input.digest else { throw Failure.interpretationRequired }
        let request = try ComputerUseBrowserInitialSearchRequest(interpretation: interpretation.proposal, query: query,
            provider: provider, sourcePolicy: sourcePolicy)
        if let initialSearch, initialSearch.request != request { throw ComputerUseBrowserInitialSearchError.pendingStage }
        let captured = input
        latestCandidates = nil
        return try await operate { [self] in
            try checkCurrent(captured)
            if initialSearch == nil {
                let prepared = try await prepareBrowser(goal: captured)
                guard session == prepared else { throw ComputerUseBrowserError.handbackContextLost }
                let startingPage: ComputerUseBrowserPageEvidence?
                if requiresBrowserAdmission, try !browser.isUnnavigatedSession(prepared) {
                    startingPage = try await observeOwnedPage(goal: captured)
                } else { startingPage = nil }
                try checkCurrent(captured)
                initialSearch = try .init(request: request, session: prepared, browser: browser, directory: directory,
                    startingPage: startingPage, makeStore: navigationStore)
            }
            guard let initialSearch else { throw Failure.navigationUnavailable }
            let document = try await initialSearch.open(checkCurrent: { try self.checkCurrent(captured) })
            try recordNavigation(.search, document: document, goal: captured)
            return document
        }
    }

    /// Reconcile the retained initial action before choosing another query or
    /// asking a question. No proposal, provider selection or answer is repeated.
    func resumeInitialSearch() async throws -> ComputerUseBrowserDocument? {
        try requireIdle()
        guard !hasQuestion else { throw Failure.questionPending }
        guard navigation?.pendingSelection == nil else { throw Failure.navigationPending }
        guard let initialSearch, initialSearch.isPending else { return nil }
        let captured = input
        return try await operate { [self] in
            let document = try await initialSearch.open(checkCurrent: { try self.checkCurrent(captured) })
            try recordNavigation(.search, document: document, goal: captured)
            return document
        }
    }

    /// Called after explicit handback when a real page change invalidated an
    /// unsent first search. Refresh only its starting document, never its goal,
    /// query/provider or operation ID. Attempted actions must reconcile first.
    func refreshInitialSearchStartingPage() async throws -> ComputerUseBrowserInitialSearch.RefreshResult {
        try requireIdle()
        guard !hasQuestion else { throw Failure.questionPending }
        guard navigation?.pendingSelection == nil else { throw Failure.navigationPending }
        guard let initialSearch, initialSearch.isPending else { return .noPendingStage }
        guard initialSearch.request.goal.digest == input.digest else { throw Failure.goalChanged }
        let captured = input
        latestCandidates = nil
        return try await operate { [self] in
            try await initialSearch.refreshStartingPage(checkCurrent: { try self.checkCurrent(captured) })
        }
    }

    func readCandidates() async throws -> ComputerUseBrowserResultCandidates {
        try requireIdle()
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let interpretation, interpretation.proposal.input.digest == input.digest,
              interpretation.proposal.disposition == .research else { throw Failure.interpretationRequired }
        let captured = input
        latestCandidates = nil
        let batch = try await operate { [self] in
            try await readCurrentCandidates(goal: captured)
        }
        latestCandidates = batch
        return batch
    }

    /// Returns only a newly revalidated reading, still not verified offer
    /// semantics or a complete answer. Failed validation retires the cache.
    func revalidateCandidates() async throws -> ComputerUseBrowserResultCandidates {
        try requireIdle()
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let retained = latestCandidates else { throw Failure.interpretationRequired }
        let captured = input
        latestCandidates = nil
        let batch = try await operate { [self] in
            try checkCurrent(captured)
            try await browser.validateResultCandidates(retained, goal: captured)
            try checkCurrent(captured)
            return retained
        }
        latestCandidates = batch
        return batch
    }

    func openCandidateLink(candidateID: String, linkID: String) async throws -> ComputerUseBrowserNavigationReceipt {
        try requireIdle()
        guard initialSearch?.isPending != true else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let navigation else { throw Failure.navigationUnavailable }
        guard let interpretation, interpretation.proposal.input.digest == input.digest,
              interpretation.proposal.disposition == .research else { throw Failure.interpretationRequired }
        let captured = input, candidates = latestCandidates
        let selection = ComputerUseBrowserResearchNavigation.Selection(goalRevision: captured.digest, candidateID: candidateID, linkID: linkID)
        latestCandidates = nil
        return try await operate { [self] in
            let receipt = try await navigation.open(selection, goal: captured, candidates: candidates, checkCurrent: { try self.checkCurrent(captured) })
            try recordNavigation(.resultLink, document: receipt.document, goal: captured)
            return receipt
        }
    }

    /// Keep fresh reading and no-effect link selection inside the same owner
    /// operation. Pause must cancel/join the selector before another owner can
    /// take over. The selected link is still natively bound again when opened.
    func planCandidateNavigation(select: @escaping @MainActor @Sendable
        (ComputerUseBrowserGoalInput, ComputerUseBrowserResultCandidates) async throws -> LinkChoice?) async throws -> LinkChoice? {
        try requireIdle()
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let interpretation, interpretation.proposal.input.digest == input.digest,
              interpretation.proposal.disposition == .research else { throw Failure.interpretationRequired }
        let captured = input, epoch = controlEpoch
        latestCandidates = nil
        let result = try await operate { [self] in
            let candidates = try await readCurrentCandidates(goal: captured)
            let choice = try await select(captured, candidates)
            try checkCurrent(captured)
            try await browser.validateResultCandidates(candidates, goal: captured)
            try checkCurrent(captured)
            if let choice {
                guard let candidate = candidates.candidates.first(where: { $0.id == choice.candidateID }),
                      candidate.selectedLinkIDs.contains(choice.linkID) else { throw ComputerUseBrowserResultError.invalidProposal }
            }
            return (choice, candidates)
        }
        try checkCurrent(captured)
        guard controlEpoch == epoch else { throw Failure.paused }
        latestCandidates = result.1
        return result.0
    }

    /// Resume the retained stage before planning another action or question.
    /// Its journal reconciles attempts; missing receipts never authorize replay.
    func resumeCandidateNavigation() async throws -> ComputerUseBrowserNavigationReceipt? {
        try requireIdle()
        guard initialSearch?.isPending != true else { throw Failure.navigationPending }
        guard let navigation, let selection = navigation.pendingSelection else { return nil }
        guard !hasQuestion else { throw Failure.questionPending }
        let captured = input
        return try await operate { [self] in
            let receipt = try await navigation.open(selection, goal: captured, candidates: nil, checkCurrent: { try self.checkCurrent(captured) })
            try recordNavigation(.resultLink, document: receipt.document, goal: captured)
            return receipt
        }
    }

    /// Only the proven-unsent pending stage may read/select fresh candidates.
    /// The caller must choose for the whole goal; no first-result shortcut or
    /// automatic navigation follows this read-only replacement.
    func replanPendingCandidateNavigation(select: @escaping @MainActor @Sendable
        (ComputerUseBrowserGoalInput, ComputerUseBrowserResultCandidates) async throws -> LinkChoice?) async throws -> ComputerUseBrowserResearchNavigation.ReplanResult {
        try requireIdle()
        guard initialSearch?.isPending != true else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let navigation else { throw Failure.navigationUnavailable }
        guard let interpretation, interpretation.proposal.input.digest == input.digest,
              interpretation.proposal.disposition == .research else { throw Failure.interpretationRequired }
        let captured = input
        latestCandidates = nil
        return try await operate { [self] in
            try await navigation.replan(goal: captured, prepare: {
                let candidates = try await self.readCurrentCandidates(goal: captured)
                guard let choice = try await select(captured, candidates) else { return nil }
                try self.checkCurrent(captured)
                return (.init(goalRevision: captured.digest, candidateID: choice.candidateID, linkID: choice.linkID), candidates)
            }, checkCurrent: { try self.checkCurrent(captured) })
        }
    }

    /// Controller identifiers must come from authenticated host transport.
    /// Browser scope is derived here from this owner's actual live session,
    /// never accepted as a client-supplied digest.
    func issueQuestion(topic: ComputerUseBrowserClarificationTopic, requirementIDs: [String],
                       controllerID: String, controllerSessionID: String) throws -> ComputerUseBrowserGoalClarification.Question {
        try requireIdle()
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard let interpretation, interpretation.proposal.input.digest == input.digest else { throw Failure.interpretationRequired }
        let context = try questionContext(controllerID: controllerID, controllerSessionID: controllerSessionID)
        let question = try clarification.issue(proposal: interpretation.proposal, topic: topic, requirementIDs: requirementIDs, context: context)
        hasQuestion = true; latestCandidates = nil
        return question
    }

    func answerQuestion(questionID: String, answerTaskID: String, answer: String,
                        controllerID: String, controllerSessionID: String) throws -> ComputerUseBrowserGoalInput {
        try requireIdle()
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        let context = try questionContext(controllerID: controllerID, controllerSessionID: controllerSessionID)
        let updated: ComputerUseBrowserGoalInput
        do { updated = try clarification.consume(questionID: questionID, answerTaskID: answerTaskID, answer: answer, context: context) }
        catch ComputerUseBrowserGoalClarification.Failure.expired {
            hasQuestion = false
            throw ComputerUseBrowserGoalClarification.Failure.expired
        }
        interpretation = nil; latestCandidates = nil; hasQuestion = false
        return updated
    }

    func pendingQuestion(controllerID: String, controllerSessionID: String) throws -> ComputerUseBrowserGoalClarification.Question? {
        try requireIdle()
        let context = try questionContext(controllerID: controllerID, controllerSessionID: controllerSessionID)
        do {
            let pending = try clarification.pendingQuestion(context: context)
            hasQuestion = pending != nil
            return pending
        } catch ComputerUseBrowserGoalClarification.Failure.expired {
            hasQuestion = false
            throw ComputerUseBrowserGoalClarification.Failure.expired
        }
    }

    /// Invalidate speculative results/questions immediately, but hold the
    /// operation slot until the actual child task unwinds after cancellation.
    func pause() {
        guard !isRetired else { return }
        isPaused = true; controlEpoch = UUID()
        if handback == nil {
            handback = session ?? (browser.taskID == taskID ? browser.handbackRequirement(taskID: taskID, required: true) : nil)
        }
        latestCandidates = nil; clarification.invalidateQuestion(); hasQuestion = false
        cancelOperation?()
    }

    /// Called only for an explicit handback. The same session may have moved
    /// through a login redirect; a stopped/replaced browser cannot be adopted.
    func resumeAfterUserControl() async throws {
        guard !isRetired else { throw Failure.retired }
        guard operationID == nil else { throw Failure.busy }
        guard isPaused else { return }
        try Task.checkCancellation()
        guard mayAct() else { throw ComputerUseBrowserError.ownershipLost }
        let epoch = controlEpoch, id = UUID(), captured = input
        let expected = handback
        operationID = id
        let child = Task<ComputerUseBrowserHandbackRequirement?, Error> { @MainActor [self] in
            if let expected {
                try await browser.reacquireAfterUserControl(taskID: taskID, requirement: expected)
                try Task.checkCancellation()
                if try !browser.isUnnavigatedSession(expected) {
                    let document = try await browser.acquireObservedDocument(taskID: taskID)
                    try Task.checkCancellation()
                    _ = try await browser.observePage(document: document)
                    try Task.checkCancellation()
                }
                try browser.validateWorkflowSession(expected)
                return expected
            }
            if session == nil, requiresBrowserAdmission, browser.hasSession {
                let prepared = try await performBrowserAdmission(checkCurrent: {
                    try Task.checkCancellation()
                    guard !self.isRetired, self.isPaused, self.controlEpoch == epoch, self.operationID == id,
                          self.input.digest == captured.digest, self.mayAct() else { throw Failure.paused }
                })
                // Admission is now a native fact. Retain its seal before a
                // page/authentication check can require another handback.
                if !isRetired, controlEpoch == epoch, operationID == id { session = prepared; handback = prepared }
                try Task.checkCancellation()
                if try !browser.isUnnavigatedSession(prepared) {
                    let document = try await browser.acquireObservedDocument(taskID: taskID)
                    _ = try await browser.observePage(document: document)
                }
                try Task.checkCancellation(); try browser.validateWorkflowSession(prepared)
                return prepared
            }
            guard session == nil, browser.taskID == nil else { throw ComputerUseBrowserError.handbackContextLost }
            return nil
        }
        cancelOperation = { child.cancel() }
        defer { if operationID == id { operationID = nil; cancelOperation = nil } }
        let resumed = try await withTaskCancellationHandler { try await child.value } onCancel: { child.cancel() }
        try Task.checkCancellation()
        guard !isRetired, isPaused, epoch == controlEpoch, operationID == id, input.digest == captured.digest, mayAct() else { throw Failure.paused }
        session = resumed; self.handback = nil; isPaused = false
    }

    func retire() {
        isRetired = true; controlEpoch = UUID(); latestCandidates = nil; interpretation = nil
        confirmedNavigationHistory.removeAll()
        clarification.retire(); navigation?.retire(); initialSearch?.retire(); hasQuestion = false; cancelOperation?()
    }

    /// Retain native facts inside the serialized child before the outer
    /// operation checks cancellation. Pause cannot erase a completed visit;
    /// retirement must never publish late history into a replacement task.
    private func recordNavigation(_ kind: ComputerUseBrowserResearchVisit.Kind,
        document: ComputerUseBrowserDocument, goal: ComputerUseBrowserGoalInput) throws {
        guard !isRetired else { return }
        guard document.taskID == taskID, goal.taskID == taskID else { throw Failure.goalChanged }
        let visit = ComputerUseBrowserResearchVisit(kind: kind, document: document, goal: goal)
        if let previous = confirmedNavigationHistory.first(where: { $0.operationID == visit.operationID }) {
            guard previous == visit else { throw Failure.goalChanged }
        } else { confirmedNavigationHistory.append(visit) }
    }

    private func questionContext(controllerID: String, controllerSessionID: String) throws -> ComputerUseBrowserGoalClarification.Context {
        if browser.taskID == taskID { try captureSession() }
        else if session != nil { throw ComputerUseBrowserError.handbackContextLost }
        return try .init(controllerID: controllerID, controllerSessionID: controllerSessionID, browserSessionDigest: session?.sessionBindingDigest)
    }

    private func captureSession() throws {
        guard browser.taskID == taskID else { throw Failure.browserRequired }
        if let session { try browser.validateWorkflowSession(session) }
        else {
            guard let captured = browser.handbackRequirement(taskID: taskID, required: true) else { throw Failure.browserRequired }
            try browser.validateWorkflowSession(captured)
            session = captured
        }
    }

    private func observeOwnedPage(goal: ComputerUseBrowserGoalInput, enforceSources: Bool = false) async throws -> ComputerUseBrowserPageEvidence {
        try checkCurrent(goal); try captureSession()
        let document = try await browser.acquireObservedDocument(taskID: taskID)
        try checkCurrent(goal)
        if enforceSources { try browser.validateSourceDocument(document) }
        let evidence = try await browser.observePage(document: document)
        try checkCurrent(goal)
        if enforceSources { try browser.validateSourceDocument(document) }
        return evidence
    }

    private func checkPageBeforePlanning(goal: ComputerUseBrowserGoalInput) async throws {
        try checkCurrent(goal)
        if session == nil, requiresBrowserAdmission, browser.hasSession { _ = try await prepareBrowser(goal: goal) }
        guard browser.taskID == taskID else { return }
        try captureSession()
        if let session, try browser.isUnnavigatedSession(session) { return }
        _ = try await observeOwnedPage(goal: goal)
    }

    private func prepareBrowser(goal: ComputerUseBrowserGoalInput) async throws -> ComputerUseBrowserHandbackRequirement {
        try checkCurrent(goal)
        if let session {
            try installSourcePolicyIfNeeded(session: session)
            return session
        }
        let prepared: ComputerUseBrowserHandbackRequirement
        if requiresBrowserAdmission {
            prepared = try await performBrowserAdmission(checkCurrent: { try self.checkCurrent(goal) })
        } else {
            guard browser.taskID == nil || browser.taskID == taskID else { throw ComputerUseBrowserError.ownershipLost }
            prepared = try browser.prepareWorkflowSession(taskID: taskID)
        }
        if !isRetired, input.digest == goal.digest { session = prepared }
        try installSourcePolicyIfNeeded(session: prepared)
        try checkCurrent(goal)
        try captureSession()
        return prepared
    }

    private func installSourcePolicyIfNeeded(session: ComputerUseBrowserHandbackRequirement) throws {
        guard let sourcePolicy, !sourcePolicyInstalled else { return }
        try browser.installSourcePolicy(sourcePolicy, replacing: nil, session: session)
        if !isRetired { sourcePolicyInstalled = true }
    }

    private func performBrowserAdmission(checkCurrent: () throws -> Void) async throws -> ComputerUseBrowserHandbackRequirement {
        guard browserAdmissionID == nil, let browserAdmission else { throw ComputerUseBrowserError.handbackContextLost }
        let id = UUID(); browserAdmissionID = id
        defer { if browserAdmissionID == id { browserAdmissionID = nil } }
        do { return try await browserAdmission.admitBrowser(for: self, admissionID: id, checkCurrent: checkCurrent) }
        catch let reason as ComputerUseBrowserError {
            try Task.checkCancellation()
            switch reason {
            case .busy, .windowNotActive, .pageChanged, .documentUnresponsive, .signInWindowOpen:
                throw ComputerUseBrowserResearchAdmissionPause(reason)
            default: throw reason
            }
        }
    }

    func validateBrowserAdmission(_ id: UUID) throws {
        try Task.checkCancellation()
        guard !isRetired else { throw Failure.retired }
        guard operationID != nil, browserAdmissionID == id else { throw ComputerUseBrowserError.handbackContextLost }
    }

    private func readCurrentCandidates(goal: ComputerUseBrowserGoalInput) async throws -> ComputerUseBrowserResultCandidates {
        // Authentication observation may inspect a manually reached page,
        // but its contents cannot enter result inference outside task scope.
        guard sourcePolicy == nil || sourcePolicyInstalled else { throw Failure.navigationUnavailable }
        let evidence = try await observeOwnedPage(goal: goal, enforceSources: true)
        let page = try ComputerUseBrowserResultPageInput(page: evidence.page)
        let proposal = try await resultPlanner.propose(goal: goal, page: page)
        try checkCurrent(goal)
        let answerPolicy = researchSources?.answerPolicy
        guard answerPolicy == nil || answerPolicy?.goalRevision == goal.digest else { throw Failure.goalChanged }
        let bound = try await browser.prepareResultCandidates(proposal, goal: goal, evidence: evidence, answerPolicy: answerPolicy)
        try checkCurrent(goal)
        return bound
    }

    private func requireIdle() throws {
        try Task.checkCancellation()
        guard !isRetired else { throw Failure.retired }
        guard !isPaused else { throw Failure.paused }
        guard mayAct() else { throw ComputerUseBrowserError.ownershipLost }
        guard operationID == nil else { throw Failure.busy }
    }

    private func checkCurrent(_ goal: ComputerUseBrowserGoalInput) throws {
        try Task.checkCancellation()
        guard !isRetired else { throw Failure.retired }
        guard !isPaused else { throw Failure.paused }
        guard mayAct() else { throw ComputerUseBrowserError.ownershipLost }
        guard goal.digest == input.digest, goal.taskID.utf8.elementsEqual(taskID.utf8) else { throw Failure.goalChanged }
        if let session {
            try browser.validateWorkflowSession(session)
            try browser.validateSourcePolicy(sourcePolicyInstalled ? sourcePolicy : nil, session: session)
        }
    }

    private func operate<Value: Sendable>(_ body: @escaping @MainActor @Sendable () async throws -> Value) async throws -> Value {
        try requireIdle()
        let id = UUID(), epoch = controlEpoch, captured = input
        operationID = id
        let child = Task { @MainActor in try await body() }
        cancelOperation = { child.cancel() }
        defer {
            if operationID == id { operationID = nil; cancelOperation = nil }
        }
        let value = try await withTaskCancellationHandler { try await child.value } onCancel: { child.cancel() }
        try checkCurrent(captured)
        guard controlEpoch == epoch, operationID == id else { throw Failure.paused }
        return value
    }
}

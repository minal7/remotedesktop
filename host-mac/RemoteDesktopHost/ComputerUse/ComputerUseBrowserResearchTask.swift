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
    enum Kind: String, Sendable { case search, resultLink, formQuery, revisit }
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
/// compile arbitrary research actions or certify independent inventory truth.
@MainActor
final class ComputerUseBrowserResearchTask {
    enum Failure: Error, Equatable { case busy, paused, retired, goalChanged, observedCriteriaChanged, interpretationRequired, questionPending, browserRequired, navigationPending, navigationUnavailable, formPending, formUnavailable, popupPending, popupLimit, optionSelectionPending, optionSelectionLimit, optionSelectionCriteriaChanged }
    struct Interpretation: Sendable {
        let proposal: ComputerUseBrowserGoalProposal
        let scalars: ComputerUseBrowserScalarRequirements
        var sources: ComputerUseBrowserSourceRequirements { .init(proposal: proposal) }
    }
    struct LinkChoice: Sendable { let candidateID: String; let linkID: String }
    enum Decision: Sendable {
        case link(LinkChoice), answer(ComputerUseBrowserResearchAnswer.Selection), revisit(ComputerUseBrowserHistoryOption), unresolved
    }
    @MainActor
    private final class PreparedForm {
        let target: ComputerUseBrowserTextTarget
        let input: ComputerUseBrowserResearchFormInput
        init(target: ComputerUseBrowserTextTarget, input: ComputerUseBrowserResearchFormInput) {
            self.target = target; self.input = input
        }
    }
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
    private var latestForm: PreparedForm?
    private var formPreparation: ComputerUseBrowserResearchFormPreparation?
    private var latestAction: ComputerUseBrowserActionProposal?
    private var formStage: ComputerUseBrowserResearchFormStage?
    private var lastVerifiedFormStage: ComputerUseBrowserResearchFormStage?
    private var formStageSequence = 0
    private var formNavigation: ComputerUseBrowserResearchFormNavigation?
    private var historyNavigation: ComputerUseBrowserResearchHistoryNavigation?
    private var historySequence = 0
    private var popupStage: ComputerUseBrowserPopupStage?
    private var popupSequence = 0
    private var popupNeedsReopen = false
    private var optionSelectionStage: ComputerUseBrowserOptionSelectionStage?
    private var optionSelectionSequence = 0
    private var optionSelectionNeedsReopen = false
    private var retainedEvidence: ComputerUseBrowserResearchEvidence
    private var session: ComputerUseBrowserHandbackRequirement?
    private var handback: ComputerUseBrowserHandbackRequirement?
    private var isPaused = false
    private var isRetired = false
    private var operationID: UUID?
    private var cancelOperation: (() -> Void)?
    private var controlEpoch = UUID()
    private var hasQuestion = false
    private(set) var confirmedNavigationHistory: [ComputerUseBrowserResearchVisit] = []
    private(set) var confirmedFormHistory: [ComputerUseBrowserResearchFormReceipt] = []
    private(set) var retiredFormHistory: [ComputerUseBrowserResearchFormStage.Retirement] = []
    private(set) var retiredHistoryNavigations: [ComputerUseBrowserResearchHistoryNavigation.Retirement] = []
    private(set) var popupHistory: [ComputerUseBrowserResearchPopupRecord] = []
    private(set) var optionSelectionHistory: [ComputerUseBrowserResearchOptionSelectionRecord] = []

    var input: ComputerUseBrowserGoalInput { clarification.input }
    /// Available during the serialized selector operation as well as idle.
    /// Pause/retirement still close model access to historical page content.
    func researchEvidence(for expected: ComputerUseBrowserGoalInput) throws -> ComputerUseBrowserResearchEvidence {
        try checkCurrent(expected)
        try retainedEvidence.validate(goal: expected)
        return retainedEvidence
    }
    /// Transport correlation advances with accepted answers; browser effects,
    /// session identity and the original goal keep taskID as their root.
    var executionTaskID: String { input.clarifications.last?.answerTaskID ?? taskID }
    var isOperating: Bool { operationID != nil }
    var hasPendingPopup: Bool { popupStage != nil }
    var hasPendingOptionSelection: Bool { optionSelectionStage != nil }
    var hasPendingNavigation: Bool { initialSearch?.isPending == true || navigation?.pendingSelection != nil || hasPendingFormNavigation || hasPendingHistoryNavigation }
    var hasPendingHistoryNavigation: Bool {
        guard let historyNavigation else { return false }
        return !confirmedNavigationHistory.contains { $0.operationID == historyNavigation.operationID && $0.kind == .revisit }
    }
    var hasPendingFormNavigation: Bool {
        guard let formNavigation else { return false }
        return !confirmedNavigationHistory.contains { $0.operationID == formNavigation.operationID && $0.kind == .formQuery }
    }
    var hasPendingForm: Bool {
        hasPendingFormPreparation || hasPendingFormExecution
    }
    var hasPendingFormPreparation: Bool { formPreparation != nil }
    /// An accepted answer changes interpretation, not the retained native
    /// baseline. Goal review may continue while effect preparation stays held.
    var hasRevisedFormPreparationGoal: Bool {
        formPreparation.map { $0.interpretation.input != input } ?? false
    }
    private var hasPendingFormExecution: Bool {
        guard let formStage else { return false }
        return !confirmedFormHistory.contains { $0.stageID == formStage.id }
    }
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
        try requireIdle(allowPendingPopup: true, allowPendingOptionSelection: true)
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
        try requireFormGoalReview()
        if formPreparation != nil {
            guard interpretation?.proposal.input == input, interpretation?.proposal.disposition == .research else { throw Failure.interpretationRequired }
        }
        guard !hasPendingNavigation, !hasQuestion, policy.taskID == taskID,
              policy.rootDigest == input.rootDigest, policy.goalRevision == input.digest else { throw Failure.goalChanged }
        if let sourcePolicy, sourcePolicy.goalRevision == policy.goalRevision, sourcePolicy != policy { throw Failure.goalChanged }
        let captured = input, epoch = controlEpoch
        if let session { try browser.installSourcePolicy(policy, replacing: sourcePolicyInstalled ? sourcePolicy?.digest : nil, session: session) }
        if !isRetired, input == captured {
            sourcePolicy = policy; sourcePolicyInstalled = session != nil; latestCandidates = nil; latestForm = nil; latestAction = nil
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
        retainedEvidence = .init(goal: input)
        self.mayAct = mayAct; clarification = .init(input: input, now: now)
        navigationDirectory = navigationJournalDirectory; self.navigationStore = navigationStore
        self.browserAdmission = browserAdmission; requiresBrowserAdmission = browserAdmission != nil
        navigation = navigationJournalDirectory.map { .init(input: input, browser: browser, journalDirectory: $0, navigationStore: navigationStore) }
    }

    func interpretGoal() async throws -> Interpretation {
        try requireIdle()
        try requireFormGoalReview()
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
        try requireFormGoalReview()
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

    /// Interpreting the complete retained conversation is not a form effect.
    /// A pending execution still owns its old contract; only an unstarted
    /// preparation may coexist with review of a continuing goal revision.
    private func requireFormGoalReview() throws {
        guard !hasPendingFormExecution else { throw Failure.formPending }
        if let preparation = formPreparation {
            guard input.continues(preparation.interpretation.input) else { throw Failure.goalChanged }
        }
    }

    /// Propose a first search from the complete retained user source. This
    /// neither chooses a website nor opens a page, and cannot replace a pending
    /// navigation or a question. Dispatch requires its own retained action.
    func planInitialSearch(using planner: any ComputerUseBrowserSearchPlanning) async throws -> ComputerUseBrowserSearchQuery {
        try requireIdle()
        guard !hasPendingForm else { throw Failure.formPending }
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
        guard !hasPendingForm else { throw Failure.formPending }
        guard navigation?.pendingSelection == nil, !hasPendingFormNavigation else { throw Failure.navigationPending }
        guard let directory = navigationDirectory else { throw Failure.navigationUnavailable }
        guard let interpretation, interpretation.proposal.input.digest == input.digest else { throw Failure.interpretationRequired }
        let request = try ComputerUseBrowserInitialSearchRequest(interpretation: interpretation.proposal, query: query,
            provider: provider, sourcePolicy: sourcePolicy)
        if let initialSearch, initialSearch.request != request { throw ComputerUseBrowserInitialSearchError.pendingStage }
        let captured = input
        latestCandidates = nil; latestForm = nil; latestAction = nil
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
        guard !hasPendingForm else { throw Failure.formPending }
        guard navigation?.pendingSelection == nil, !hasPendingFormNavigation else { throw Failure.navigationPending }
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
        guard !hasPendingForm else { throw Failure.formPending }
        guard navigation?.pendingSelection == nil, !hasPendingFormNavigation else { throw Failure.navigationPending }
        guard let initialSearch, initialSearch.isPending else { return .noPendingStage }
        guard initialSearch.request.goal.digest == input.digest else { throw Failure.goalChanged }
        let captured = input
        latestCandidates = nil; latestForm = nil; latestAction = nil
        return try await operate { [self] in
            try await initialSearch.refreshStartingPage(checkCurrent: { try self.checkCurrent(captured) })
        }
    }

    /// Select an interaction capability before interpreting a page as offers.
    /// Observation and planning preserve retained native field receipts.
    func planNextAction(using planner: any ComputerUseBrowserActionPlanning, budget: Duration = .seconds(30)) async throws -> ComputerUseBrowserActionProposal {
        try requireIdle()
        guard !hasPendingForm else { throw Failure.formPending }
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let interpretation, interpretation.proposal.input == input,
              interpretation.proposal.disposition == .research else { throw Failure.interpretationRequired }
        guard sourcePolicy == nil || (sourcePolicyInstalled && sourcePolicy?.goalRevision == input.digest) else { throw Failure.navigationUnavailable }
        let captured = input
        let deadline = ContinuousClock.now.advanced(by: min(.seconds(30), max(.zero, budget)))
        latestCandidates = nil; latestForm = nil; latestAction = nil
        let action = try await operate { [self] in
            try await withThrowingTaskGroup(of: ComputerUseBrowserActionProposal.self) { group in
                group.addTask { @MainActor [self] in
                    try await selectAction(using: planner, interpretation: interpretation.proposal, deadline: deadline)
                }
                group.addTask {
                    try await Task.sleep(until: deadline, clock: .continuous)
                    try Task.checkCancellation()
                    throw ComputerUseBrowserActionPlanError.deadlineExceeded
                }
                defer { group.cancelAll() }
                guard let proposal = try await group.next() else { throw ComputerUseBrowserActionPlanError.invalidProposal }
                try checkCurrent(captured)
                guard ContinuousClock.now < deadline else { throw ComputerUseBrowserActionPlanError.deadlineExceeded }
                return proposal
            }
        }
        latestAction = action
        return action
    }

    /// Reconsider metadata under an accepted answer without rediscovering
    /// fields or consuming the original preparation. The returned proposal is
    /// held separately until native preparation can carry the revised scope.
    func reviewFormPreparation(using planner: any ComputerUseBrowserActionPlanning, budget: Duration = .seconds(30)) async throws -> ComputerUseBrowserActionProposal {
        try requireIdle(); try requireFormGoalReview()
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let preparation = formPreparation, hasRevisedFormPreparationGoal,
              let interpretation, interpretation.proposal.input == input,
              interpretation.proposal.disposition == .research else { throw Failure.interpretationRequired }
        guard sourcePolicy == nil || (sourcePolicyInstalled && sourcePolicy?.goalRevision == input.digest) else { throw Failure.navigationUnavailable }
        let captured = input
        let deadline = ContinuousClock.now.advanced(by: min(.seconds(30), max(.zero, budget)))
        latestCandidates = nil; latestForm = nil; latestAction = nil
        return try await operate { [self] in
            return try await withThrowingTaskGroup(of: ComputerUseBrowserActionProposal.self) { group in
                group.addTask { @MainActor [self] in
                    guard ContinuousClock.now < deadline else { throw ComputerUseBrowserActionPlanError.deadlineExceeded }
                    if let cached = preparation.revisedAction, cached.input.interpretation == interpretation.proposal {
                        _ = try await preparation.restoreForReview(browser: browser, checkCurrent: { try self.checkCurrent(captured) })
                        return cached
                    }
                    return try await selectAction(using: planner, interpretation: interpretation.proposal, deadline: deadline, preparation: preparation)
                }
                group.addTask {
                    try await Task.sleep(until: deadline, clock: .continuous)
                    try Task.checkCancellation()
                    throw ComputerUseBrowserActionPlanError.deadlineExceeded
                }
                defer { group.cancelAll() }
                guard let action = try await group.next() else { throw ComputerUseBrowserActionPlanError.invalidProposal }
                try checkCurrent(captured)
                guard formPreparation === preparation, ContinuousClock.now < deadline else { throw ComputerUseBrowserActionPlanError.deadlineExceeded }
                switch action.step {
                case .editForm: try preparation.retainRevisedAction(action)
                case .question, .unavailable: break
                default: throw ComputerUseBrowserActionPlanError.invalidProposal
                }
                return action
            }
        }
    }

    private func selectAction(using planner: any ComputerUseBrowserActionPlanning,
                              interpretation: ComputerUseBrowserGoalProposal,
                              deadline: ContinuousClock.Instant,
                              preparation: ComputerUseBrowserResearchFormPreparation? = nil) async throws -> ComputerUseBrowserActionProposal {
        let captured = interpretation.input
        func check() throws {
            try checkCurrent(captured)
            guard self.interpretation?.proposal == interpretation else { throw Failure.interpretationRequired }
            guard ContinuousClock.now < deadline else { throw ComputerUseBrowserActionPlanError.deadlineExceeded }
        }
        try check()
        var page: ComputerUseBrowserPageEvidence
        if let preparation {
            page = try await preparation.restoreForReview(browser: browser, checkCurrent: check)
            try browser.validateSourceDocument(page.document)
        } else { page = try await observeOwnedPage(goal: captured, enforceSources: true) }
        do {
            let archive = try researchEvidence(for: captured)
            var recalled: [Int] = [], optionReads = try preparation?.reviewContext.readings(in: interpretation) ?? []
            var effectReviews: [ComputerUseBrowserEffectControlReview] = []
            var formScope = try preparation.map { try ComputerUseBrowserFormEffectScope(preparationReview: $0.reviewContext,
                interpretation: interpretation, evidence: page) }
            var selectedFormScopes: Set<String> = []
            while true {
                var changed: Set<String> = []
                if let stage = formStage, let receipt = stage.nativeReceipt, confirmedFormHistory.last == receipt,
                   captured.continues(stage.input.interpretation.input), stage.input.evidence.page.document == page.document,
                   stage.input.evidence.page.documentID == page.documentID {
                    changed = try await stage.inspectChangedCriteria(page: page, checkCurrent: { try self.checkCurrent(captured) })
                }
                try check()
                let historyOptions = try browser.historyOptions(goal: captured, visits: confirmedNavigationHistory, evidence: page)
                let popupControls = formScope == nil && popupSequence < 32 && navigationDirectory != nil && page.page.controls.contains(where: {
                    $0.compositeRole == "combobox" && !$0.disabled && ComputerUseBrowserControlRead.allows($0)
                }) ? try await browser.popupControlIDs(in: page) : []
                let optionChoices = formScope == nil && optionSelectionSequence < 32 && navigationDirectory != nil && !optionReads.isEmpty
                    ? try await browser.optionSelectionChoices(in: page) : []
                try check()
                guard retainedEvidence.digest == archive.digest else { throw ComputerUseBrowserResearchEvidenceError.inputChanged }
                let context = try ComputerUseBrowserActionInput(interpretation: interpretation, evidence: page,
                    navigationHistory: confirmedNavigationHistory, formHistory: confirmedFormHistory, latestForm: formStage,
                    changedFormTargetIDs: changed, researchEvidence: archive, recalledReadings: recalled, historyOptions: historyOptions,
                    popupControlIDs: popupControls, popupHistory: popupHistory,
                    allowOptionInspection: optionSelectionSequence < 32 && navigationDirectory != nil && optionReads.isEmpty,
                    optionReadControls: optionReads, optionChoices: optionChoices, optionSelectionHistory: optionSelectionHistory,
                    effectControlReviews: effectReviews, formEffectScope: formScope, preparationReview: preparation?.reviewContext)
                // Retain the selected form/query through metadata review. Newly
                // read query criteria still require an explicit model decision.
                let readyScope = context.effectScopeAllowsActions ? formScope : nil
                let releasedScope = readyScope?.queryControlID != nil && !optionReads.isEmpty ? nil : readyScope
                let proposal: ComputerUseBrowserActionProposal
                if let releasedScope { proposal = try .decode(content: releasedScope.actionContent, input: context) }
                else { proposal = try await planner.propose(context) }
                try check()
                try proposal.validate(for: context)
                // Recall never refreshes or replaces native authority. A
                // changed page invalidates even a no-effect recall decision.
                try await browser.validatePageEvidence(page)
                try check(); try browser.validateSourceDocument(page.document)
                if releasedScope == nil {
                    switch proposal.step {
                    case .openQuery(let id, let receipt) where readyScope?.kind == .query(id, receipt):
                        break // The model has now assessed the newly read query criteria.
                    case .editForm, .openQuery:
                        let next = try ComputerUseBrowserFormEffectScope(action: proposal)
                        guard next != formScope, selectedFormScopes.count < 64,
                              selectedFormScopes.insert(next.digest).inserted else { throw ComputerUseBrowserActionPlanError.invalidProposal }
                        formScope = next; effectReviews = []; continue
                    case .preserveControls:
                        guard let scope = formScope else { throw ComputerUseBrowserActionPlanError.invalidProposal }
                        formScope = try scope.extending(proposal.preservedControls); effectReviews = []; continue
                    case .planFields(let intents):
                        guard let scope = formScope else { throw ComputerUseBrowserActionPlanError.invalidProposal }
                        formScope = try scope.planning(intents); effectReviews = []; continue
                    default: break
                    }
                }
                if case .recall(let index) = proposal.step { recalled.append(index); continue }
                if case .reviewControls(let review) = proposal.step { effectReviews.append(review); continue }
                if proposal.step == .inspectOptions || proposal.step == .extendInspection {
                    page = try await browser.observeResearchControls(for: proposal)
                    optionReads = proposal.readControls
                    effectReviews = [] // A new scoped snapshot requires a fresh metadata review.
                    formScope = try formScope?.continuingQuery(with: page)
                    try check()
                    continue
                }
                return proposal
            }
        } catch {
            await browser.joinDOMCompletion(document: page.document)
            throw error
        }
    }

    private func validateAction(_ action: ComputerUseBrowserActionProposal) throws {
        try requireIdle()
        guard !hasPendingForm else { throw Failure.formPending }
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard latestAction == action, action.input.interpretation.input == input,
              action.input.interpretation == interpretation?.proposal else { throw ComputerUseBrowserActionPlanError.inputChanged }
    }

    func openFormQuery(for action: ComputerUseBrowserActionProposal) async throws -> ComputerUseBrowserNavigationReceipt {
        try validateAction(action)
        guard case .openQuery(let controlID, let receipt) = action.step else { throw ComputerUseBrowserActionPlanError.invalidProposal }
        latestAction = nil
        let review = try ComputerUseBrowserEffectScopeReview(input: action.input)
        guard review.formScope?.kind == .query(controlID, receipt) else { throw ComputerUseBrowserActionPlanError.invalidProposal }
        return try await openFormQuery(after: receipt, controlID: controlID, evidence: action.input.evidence, scopeReview: review)
    }

    func openPopup(for action: ComputerUseBrowserActionProposal) async throws -> ComputerUseBrowserPopupReceipt {
        try validateAction(action)
        guard case .openPopup(let controlID, let requirement) = action.step,
              action.input.popupControlIDs.contains(controlID), let navigationDirectory else { throw ComputerUseBrowserActionPlanError.invalidProposal }
        guard popupSequence < 32 else { throw Failure.popupLimit }
        let captured = input
        let intent = try ComputerUseBrowserPopupIntent(interpretation: action.input.interpretation,
            evidence: action.input.evidence, controlID: controlID, requirementIndex: requirement,
            scopeReview: ComputerUseBrowserEffectScopeReview(input: action.input))
        latestAction = nil; latestCandidates = nil; latestForm = nil
        try requireOriginalPopupCriteria(in: intent.evidence)
        try await operate { [self] in
            do {
                let target = try await browser.preparePopup(intent)
                try checkCurrent(captured)
                let next = try ComputerUseBrowserPopupStage(target: target, sequence: popupSequence, browser: browser,
                    journalDirectory: navigationDirectory.appendingPathComponent("Popups"), makeStore: navigationStore)
                popupStage = next; popupSequence += 1; popupNeedsReopen = false
            } catch {
                await browser.joinDOMCompletion(document: intent.evidence.document)
                throw error
            }
        }
        return try await resumePopup()
    }

    func resumePopup() async throws -> ComputerUseBrowserPopupReceipt {
        try requireIdle(allowPendingPopup: true)
        guard !hasPendingForm, !hasPendingNavigation, !hasQuestion, popupStage != nil else { throw Failure.popupPending }
        let captured = input
        return try await operate(allowPendingPopup: true) { [self] in
            let stage = try currentPopupStage()
            guard stage.target.intent.interpretation.input == captured else { throw Failure.goalChanged }
            do {
                let receipt = try await stage.run(checkCurrent: { try self.checkCurrent(captured) })
                let digest = ComputerUseTaskContract.digest(["browser-research-popup-opened-v1",stage.contract.contractDigest,
                    receipt.operationID,receipt.bindingID,receipt.controlID,receipt.documentID])
                try recordPopup(stage, outcome: .opened, digest: digest)
                return receipt
            } catch {
                if error is ComputerUseTaskJournalStore.StoreError, popupStage === stage { popupNeedsReopen = true }
                throw error
            }
        }
    }

    func retirePendingUnsentPopup() async throws -> ComputerUseBrowserResearchPopupRecord? {
        try requireIdle(allowPendingPopup: true)
        guard !hasPendingForm, !hasPendingNavigation, !hasQuestion else { throw Failure.popupPending }
        guard popupStage != nil else { return nil }
        let captured = input
        return try await operate(allowPendingPopup: true) { [self] in
            let stage = try currentPopupStage()
            guard stage.target.intent.interpretation.input == captured else { throw Failure.goalChanged }
            do {
                guard let digest = try await stage.retireUnsent(checkCurrent: { try self.checkCurrent(captured) }) else { return nil }
                try recordPopup(stage, outcome: .retiredUnsent, digest: digest)
                return popupHistory.last
            } catch {
                if error is ComputerUseTaskJournalStore.StoreError, popupStage === stage { popupNeedsReopen = true }
                throw error
            }
        }
    }

    private func currentPopupStage() throws -> ComputerUseBrowserPopupStage {
        guard let stage = popupStage else { throw Failure.popupPending }
        if !popupNeedsReopen { return stage }
        let replacement = try stage.reopened(makeStore: navigationStore)
        stage.retire(); popupStage = replacement; popupNeedsReopen = false
        return replacement
    }

    private func recordPopup(_ stage: ComputerUseBrowserPopupStage, outcome: ComputerUseBrowserResearchPopupRecord.Outcome, digest: String) throws {
        guard !isRetired else { return }
        guard popupStage === stage, stage.sequence == popupHistory.count,
              stage.target.intent.interpretation.input == input else { throw Failure.goalChanged }
        popupHistory.append(.init(stage: stage, outcome: outcome, digest: digest))
        popupStage = nil; popupNeedsReopen = false; stage.retire()
        latestAction = nil; latestCandidates = nil; latestForm = nil
    }

    func selectOption(for action: ComputerUseBrowserActionProposal) async throws -> ComputerUseBrowserOptionSelectionReceipt {
        try validateAction(action)
        guard case .selectOption(let controlID, let optionID, let requirement) = action.step,
              action.input.optionChoices.contains(where: { $0.controlID == controlID && $0.optionIDs.contains(optionID) }), let navigationDirectory else { throw ComputerUseBrowserActionPlanError.invalidProposal }
        guard optionSelectionSequence < 32 else { throw Failure.optionSelectionLimit }
        let captured = input
        let intent = try ComputerUseBrowserOptionSelectionIntent(interpretation: action.input.interpretation,
            evidence: action.input.evidence, controlID: controlID, optionID: optionID, requirementIndex: requirement,
            scopeReview: ComputerUseBrowserEffectScopeReview(input: action.input))
        latestAction = nil; latestCandidates = nil; latestForm = nil
        try requireOriginalPopupCriteria(in: intent.evidence)
        try requireOriginalOptionSelectionCriteria(intent)
        try await operate { [self] in
            do {
                let target = try await browser.prepareOptionSelection(intent)
                try checkCurrent(captured)
                let next = try ComputerUseBrowserOptionSelectionStage(target: target, sequence: optionSelectionSequence, browser: browser,
                    journalDirectory: navigationDirectory.appendingPathComponent("OptionSelections"), makeStore: navigationStore)
                optionSelectionStage = next; optionSelectionSequence += 1; optionSelectionNeedsReopen = false
            } catch {
                await browser.joinDOMCompletion(document: intent.evidence.document)
                throw error
            }
        }
        return try await resumeOptionSelection()
    }

    func resumeOptionSelection() async throws -> ComputerUseBrowserOptionSelectionReceipt {
        try requireIdle(allowPendingOptionSelection: true)
        guard !hasPendingForm, !hasPendingNavigation, !hasQuestion, optionSelectionStage != nil else { throw Failure.optionSelectionPending }
        let captured = input
        return try await operate(allowPendingOptionSelection: true) { [self] in
            let stage = try currentOptionSelectionStage()
            guard stage.target.intent.interpretation.input == captured else { throw Failure.goalChanged }
            do {
                let receipt = try await stage.run(checkCurrent: { try self.checkCurrent(captured) })
                let digest = ComputerUseTaskContract.digest(["browser-research-option-selection-selected-v1",stage.contract.contractDigest,
                    receipt.operationID,receipt.bindingID,receipt.controlID,receipt.optionID,receipt.documentID,
                    String(receipt.didDispatch),receipt.afterValue])
                try recordOptionSelection(stage, receipt: receipt, digest: digest)
                return receipt
            } catch {
                if error is ComputerUseTaskJournalStore.StoreError, optionSelectionStage === stage { optionSelectionNeedsReopen = true }
                throw error
            }
        }
    }

    func retirePendingUnsentOptionSelection() async throws -> ComputerUseBrowserResearchOptionSelectionRecord? {
        try requireIdle(allowPendingOptionSelection: true)
        guard !hasPendingForm, !hasPendingNavigation, !hasQuestion else { throw Failure.optionSelectionPending }
        guard optionSelectionStage != nil else { return nil }
        let captured = input
        return try await operate(allowPendingOptionSelection: true) { [self] in
            let stage = try currentOptionSelectionStage()
            guard stage.target.intent.interpretation.input == captured else { throw Failure.goalChanged }
            do {
                guard let digest = try await stage.retireUnsent(checkCurrent: { try self.checkCurrent(captured) }) else { return nil }
                try recordOptionSelection(stage, receipt: nil, digest: digest)
                return optionSelectionHistory.last
            } catch {
                if error is ComputerUseTaskJournalStore.StoreError, optionSelectionStage === stage { optionSelectionNeedsReopen = true }
                throw error
            }
        }
    }

    private func currentOptionSelectionStage() throws -> ComputerUseBrowserOptionSelectionStage {
        guard let stage = optionSelectionStage else { throw Failure.optionSelectionPending }
        if !optionSelectionNeedsReopen { return stage }
        let replacement = try stage.reopened(makeStore: navigationStore)
        stage.retire(); optionSelectionStage = replacement; optionSelectionNeedsReopen = false
        return replacement
    }

    private func recordOptionSelection(_ stage: ComputerUseBrowserOptionSelectionStage, receipt: ComputerUseBrowserOptionSelectionReceipt?, digest: String) throws {
        guard !isRetired else { return }
        guard optionSelectionStage === stage, stage.sequence == optionSelectionHistory.count,
              stage.target.intent.interpretation.input == input else { throw Failure.goalChanged }
        optionSelectionHistory.append(try .init(stage: stage, receipt: receipt, digest: digest))
        optionSelectionStage = nil; optionSelectionNeedsReopen = false; stage.retire()
        latestAction = nil; latestCandidates = nil; latestForm = nil
    }

    /// An opened or proven-unsent popup cannot turn an overwritten criterion
    /// into a new starting value. Selection alone does not discharge unrelated
    /// criteria; explicit task-backed replacements need their own reconciliation.
    private func requireOriginalPopupCriteria(in evidence: ComputerUseBrowserPageEvidence) throws {
        do {
            for record in popupHistory {
                guard input.continues(record.intent.interpretation.input) else { throw Failure.observedCriteriaChanged }
                try ComputerUseBrowserObservedCriteria.requireUnchanged(controlIDs: record.intent.observedPreservedControlIDs,
                    original: record.intent.evidence, current: evidence)
            }
        } catch { throw Failure.observedCriteriaChanged }
    }

    /// A proven-unsent retirement releases the old native target, not its
    /// original observed baseline. A replacement selection must still observe
    /// those criteria before it can prepare an executable binding.
    private func requireOriginalOptionSelectionCriteria(_ intent: ComputerUseBrowserOptionSelectionIntent) throws {
        for record in optionSelectionHistory.reversed() {
            if record.outcome == .selected { break }
            let original = record.intent
            let ids = original.observedPreservedControlIDs
            if ids.isEmpty { continue }
            guard intent.interpretation.input.continues(original.interpretation.input),
                  intent.evidence.document == original.evidence.document,
                  intent.evidence.documentID == original.evidence.documentID else { throw Failure.optionSelectionCriteriaChanged }
            do {
                let before = try ComputerUseBrowserOptionSelectionState.baselineDigest(controlIDs: ids, page: original.evidence.page)
                let current = try ComputerUseBrowserOptionSelectionState.baselineDigest(controlIDs: ids, page: intent.evidence.page)
                guard before == current else { throw Failure.optionSelectionCriteriaChanged }
            } catch { throw Failure.optionSelectionCriteriaChanged }
        }
    }

    func revisit(for action: ComputerUseBrowserActionProposal) async throws -> ComputerUseBrowserNavigationReceipt {
        try validateAction(action)
        guard case .revisit(let index) = action.step,
              let option = action.input.historyOptions.first(where: { $0.visit == index }) else { throw ComputerUseBrowserActionPlanError.invalidProposal }
        return try await beginHistoryNavigation(option)
    }

    func revisitAfterReading(_ option: ComputerUseBrowserHistoryOption) async throws -> ComputerUseBrowserNavigationReceipt {
        try requireIdle(); try checkCurrent(input)
        guard !hasPendingForm, !hasPendingNavigation, !hasQuestion,
              latestCandidates?.historyOptions.contains(option) == true else { throw Failure.navigationUnavailable }
        return try await beginHistoryNavigation(option)
    }

    private func beginHistoryNavigation(_ option: ComputerUseBrowserHistoryOption) async throws -> ComputerUseBrowserNavigationReceipt {
        guard let navigationDirectory else { throw Failure.navigationUnavailable }
        let next = try ComputerUseBrowserResearchHistoryNavigation(option: option, goal: input, sequence: historySequence,
            browser: browser, journalDirectory: navigationDirectory.appendingPathComponent("History"), makeStore: navigationStore)
        latestAction = nil; latestCandidates = nil; latestForm = nil
        historyNavigation?.retire(); historyNavigation = next; historySequence += 1
        return try await resumeHistoryNavigation()
    }

    func resumeHistoryNavigation() async throws -> ComputerUseBrowserNavigationReceipt {
        try requireIdle()
        guard !hasPendingForm, initialSearch?.isPending != true, !hasPendingFormNavigation,
              navigation?.pendingSelection == nil, !hasQuestion,
              let stage = historyNavigation, stage.goal == input else { throw Failure.navigationPending }
        let captured = input
        return try await operate { [self] in
            let receipt = try await stage.run(prepareCurrent: { try await self.observeOwnedPage(goal: captured, enforceSources: true) },
                checkCurrent: { try self.checkCurrent(captured) })
            try recordNavigation(.revisit, document: receipt.document, goal: captured)
            return receipt
        }
    }

    /// A changed visit can release the planner only after the original
    /// operation is natively revoked and durably retired as never attempted.
    func retirePendingUnsentHistoryNavigation() async throws -> ComputerUseBrowserResearchHistoryNavigation.Retirement? {
        try requireIdle()
        guard !hasPendingForm, initialSearch?.isPending != true, !hasPendingFormNavigation,
              navigation?.pendingSelection == nil, !hasQuestion else { throw Failure.navigationPending }
        guard hasPendingHistoryNavigation, let stage = historyNavigation else { return nil }
        guard stage.goal == input else { throw Failure.goalChanged }
        let captured = input
        latestAction = nil; latestCandidates = nil; latestForm = nil
        return try await operate { [self] in
            guard let receipt = try stage.retireUnsent(checkCurrent: { try self.checkCurrent(captured) }) else { return nil }
            try checkCurrent(captured)
            guard historyNavigation === stage else { throw Failure.navigationUnavailable }
            if !retiredHistoryNavigations.contains(receipt) { retiredHistoryNavigations.append(receipt) }
            historyNavigation = nil
            stage.retire()
            return receipt
        }
    }

    /// Prepare native field correspondence before semantic form planning.
    /// This only observes; it neither runs a model nor edits/submits a form.
    func prepareFormInput() async throws -> ComputerUseBrowserResearchFormInput {
        try await prepareFormInput(action: nil)
    }

    func prepareFormInput(for action: ComputerUseBrowserActionProposal) async throws -> ComputerUseBrowserResearchFormInput {
        try validateAction(action)
        guard case .editForm(let formID) = action.step else { throw ComputerUseBrowserActionPlanError.invalidProposal }
        let review = try ComputerUseBrowserEffectScopeReview(input: action.input)
        guard review.formScope?.formID == formID, review.formScope?.preservedControls == action.preservedControls else {
            throw ComputerUseBrowserActionPlanError.invalidProposal
        }
        return try await prepareFormInput(action: action)
    }

    private func prepareFormInput(action: ComputerUseBrowserActionProposal?) async throws -> ComputerUseBrowserResearchFormInput {
        try requireIdle()
        guard !hasPendingForm else { throw Failure.formPending }
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let interpretation, interpretation.proposal.input == input,
              interpretation.proposal.disposition == .research else { throw Failure.interpretationRequired }
        guard sourcePolicy == nil || (sourcePolicyInstalled && sourcePolicy?.goalRevision == input.digest) else { throw Failure.navigationUnavailable }
        let captured = input
        latestCandidates = nil; latestForm = nil; latestAction = nil
        let prepared = try await operate { [self] in
            let page: ComputerUseBrowserPageEvidence
            if let action, case .editForm = action.step {
                try checkCurrent(captured)
                try await browser.validatePageEvidence(action.input.evidence)
                try browser.validateSourceDocument(action.input.evidence.document)
                page = action.input.evidence
            } else {
                page = try await observeOwnedPage(goal: captured, enforceSources: true)
            }
            try requireOriginalPopupCriteria(in: page)
            guard browser.hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
            if let action {
                // Keep a verified form's original adapter and receipts. A
                // failed extension cannot fall back to fresh discovery.
                let parent = formStage.flatMap { stage in
                    stage.nativeReceipt != nil && stage.input.evidence.page.document == page.document ? stage : nil
                }
                let preparation = try ComputerUseBrowserResearchFormPreparation(action: action, browser: browser, parent: parent)
                formPreparation = preparation // Publish intent before the first private read.
                let prepared = try await preparation.prepare(browser: browser, checkCurrent: { try self.checkCurrent(captured) })
                try checkCurrent(captured)
                return PreparedForm(target: preparation.target, input: prepared)
            }
            let target = ComputerUseBrowserTextTarget(browser: browser, document: page.document,
                requiresFrontmost: browser.isFrontmostWindow)
            let fields = try await target.fields()
            let evidence = try await target.bindFields(fields, to: page)
            try checkCurrent(captured)
            guard browser.hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
            return PreparedForm(target: target, input: try .init(interpretation: interpretation.proposal, evidence: evidence))
        }
        latestForm = prepared
        return prepared.input
    }

    /// Resume the original private preparation after explicit handback. This
    /// neither asks for another action selection nor discovers a new baseline.
    func resumeFormPreparation() async throws -> ComputerUseBrowserResearchFormInput {
        try requireIdle()
        guard !hasPendingFormExecution, !hasPendingNavigation, !hasQuestion, let preparation = formPreparation else {
            throw Failure.formUnavailable
        }
        guard preparation.interpretation.input == input, interpretation?.proposal == preparation.interpretation else { throw Failure.goalChanged }
        let captured = input
        let prepared = try await operate { [self] in
            guard formPreparation === preparation else { throw Failure.formUnavailable }
            let value = try await preparation.prepare(browser: browser, checkCurrent: { try self.checkCurrent(captured) })
            try checkCurrent(captured)
            guard formPreparation === preparation else { throw Failure.formUnavailable }
            return PreparedForm(target: preparation.target, input: value)
        }
        latestForm = prepared
        return prepared.input
    }

    /// Reuse the exact adapter, page and field set. A failed or interrupted
    /// check cannot leave a planning input eligible for later consumption.
    func revalidateFormInput(_ proposed: ComputerUseBrowserResearchFormInput) async throws {
        try requireIdle()
        guard !hasPendingFormExecution else { throw Failure.formPending }
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let retained = latestForm, retained.input == proposed,
              interpretation?.proposal == proposed.interpretation,
              proposed.interpretation.input == input else { throw ComputerUseBrowserResearchFormError.inputChanged }
        let captured = input
        defer {
            // A cancelled private validation must not discard the only
            // adapter holding this baseline. Reuse still revalidates it.
            if proposed.nativePreservation != nil, input == captured, !isRetired { latestForm = retained }
        }
        latestForm = nil; latestAction = nil
        try await operate { [self] in
            try await validatePreparedForm(retained, goal: captured)
        }
        latestForm = retained
    }

    /// Planning and native preflight share the owner's operation. Pause joins
    /// the actual planner before releasing it; no edit is dispatched here.
    func planForm(_ proposed: ComputerUseBrowserResearchFormInput, using planner: any ComputerUseBrowserFormPlanning) async throws -> ComputerUseBrowserFormProposal {
        try requireIdle()
        guard !hasPendingFormExecution else { throw Failure.formPending }
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let retained = latestForm, retained.input == proposed,
              interpretation?.proposal == proposed.interpretation, proposed.interpretation.input == input else {
            throw ComputerUseBrowserResearchFormError.inputChanged
        }
        let captured = input
        defer {
            if proposed.nativePreservation != nil, input == captured, !isRetired { latestForm = retained }
        }
        latestForm = nil; latestAction = nil
        let result = try await operate { [self] in
            try await validatePreparedForm(retained, goal: captured)
            let proposal = try await planner.propose(proposed)
            try checkCurrent(captured)
            try proposal.validate(for: proposed)
            try await validatePreparedForm(retained, goal: captured)
            if let contract = try proposal.textContract(for: proposed) {
                try await retained.target.validateRepresentability(of: contract)
                try await validatePreparedForm(retained, goal: captured)
            }
            return proposal
        }
        latestForm = retained
        return result
    }

    private func validatePreparedForm(_ prepared: PreparedForm, goal: ComputerUseBrowserGoalInput) async throws {
        try checkCurrent(goal)
        guard prepared.input.nativePreservation == prepared.target.formPreservation else { throw ComputerUseBrowserResearchFormError.inputChanged }
        guard browser.hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        try browser.validateSourceDocument(prepared.input.evidence.page.document)
        if prepared.input.scopeReview != nil {
            try await ComputerUseBrowserResearchFormStage.validateOriginalInput(prepared.input, target: prepared.target,
                browser: browser, checkCurrent: { try self.checkCurrent(goal) })
        } else { try await prepared.target.validateFormEvidence(prepared.input.evidence) }
        try checkCurrent(goal)
        guard browser.hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        try browser.validateSourceDocument(prepared.input.evidence.page.document)
    }

    /// Accept one native edit stage. Repeating its original request resumes
    /// that stage, including after Pause; it cannot create a replacement plan.
    func executeForm(_ proposal: ComputerUseBrowserFormProposal, input expected: ComputerUseBrowserResearchFormInput) async throws -> ComputerUseBrowserResearchFormReceipt {
        try requireIdle()
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        // A repeated request for the verified predecessor must not consume
        // preparation for a later stage that borrows its adapter and receipts.
        if let formPreparation, formPreparation.preparedInput != expected { throw Failure.formPending }
        guard expected.interpretation.input == input, interpretation?.proposal == expected.interpretation else { throw Failure.goalChanged }
        try proposal.validate(for: expected)
        let stage: ComputerUseBrowserResearchFormStage
        if let formStage, formStage.input == expected, formStage.proposal == proposal { stage = formStage }
        else {
            guard !hasPendingFormExecution else { throw Failure.formPending }
            guard let prepared = latestForm, prepared.input == expected, let directory = navigationDirectory else { throw Failure.formUnavailable }
            stage = try .init(input: expected, proposal: proposal, target: prepared.target, browser: browser,
                index: confirmedFormHistory.count, sequence: formStageSequence, journalDirectory: directory, makeStore: navigationStore)
            formStageSequence += 1
            formStage = stage // Retain before any disk write, native await or effect.
        }
        formPreparation = nil // The retained execution stage now owns the same input and adapter.
        latestForm = nil; latestAction = nil; latestCandidates = nil
        return try await runForm(stage)
    }

    func resumeForm() async throws -> ComputerUseBrowserResearchFormReceipt? {
        try requireIdle()
        guard !hasPendingFormPreparation else { throw Failure.formPending }
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let formStage else { return nil }
        guard formStage.input.interpretation.input == input
                || (formStage.nativeReceipt != nil && input.continues(formStage.input.interpretation.input)) else { throw Failure.goalChanged }
        latestForm = nil; latestAction = nil; latestCandidates = nil
        return try await runForm(formStage)
    }

    /// Release a stale pending stage only after its original native IDs have
    /// been revoked as unsent and its exact disk journal is tombstoned. Keep
    /// the latest completed form's adapter and history for the new proposal.
    func retirePendingUnsentForm() async throws -> ComputerUseBrowserResearchFormStage.Retirement? {
        try requireIdle()
        guard !hasPendingFormPreparation else { throw Failure.formPending }
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard hasPendingFormExecution, let stage = formStage else { return nil }
        guard stage.input.interpretation.input == input else { throw Failure.goalChanged }
        let captured = input
        latestForm = nil; latestAction = nil; latestCandidates = nil
        return try await operate { [self] in
            guard let receipt = try await stage.retireUnsent(checkCurrent: { try self.checkCurrent(captured) }) else { return nil }
            try checkCurrent(captured)
            guard formStage === stage else { throw Failure.formUnavailable }
            if !retiredFormHistory.contains(receipt) { retiredFormHistory.append(receipt) }
            formStage = lastVerifiedFormStage
            stage.retire()
            return receipt
        }
    }

    /// Preserve only a natively verified prefix, together with the explicit
    /// unfinished-edit obligations. The same adapter remains the next stage's
    /// authority; this does not publish whole-stage or research completion.
    func retainPendingFormPrefix() async throws -> ComputerUseBrowserResearchFormReceipt? {
        try requireIdle()
        guard !hasPendingFormPreparation else { throw Failure.formPending }
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard hasPendingFormExecution, let stage = formStage else { return nil }
        guard stage.input.interpretation.input == input else { throw Failure.goalChanged }
        let captured = input
        latestForm = nil; latestAction = nil; latestCandidates = nil
        return try await operate { [self] in
            guard let resolution = try await stage.retainVerifiedPrefix(checkCurrent: { try self.checkCurrent(captured) }) else { return nil }
            try recordForm(resolution.receipt, stage: stage, goal: captured)
            try checkCurrent(captured)
            return resolution.receipt
        }
    }

    private func recordForm(_ receipt: ComputerUseBrowserResearchFormReceipt, stage: ComputerUseBrowserResearchFormStage,
                            goal: ComputerUseBrowserGoalInput) throws {
        guard !isRetired else { return }
        guard formStage === stage, stage.nativeReceipt == receipt,
              receipt.taskID == taskID, receipt.rootDigest == goal.rootDigest else { throw Failure.goalChanged }
        if let previous = confirmedFormHistory.first(where: { $0.stageID == receipt.stageID }) {
            guard previous == receipt else { throw Failure.goalChanged }
        } else {
            guard receipt.goalRevision == goal.digest, receipt.index == confirmedFormHistory.count else { throw Failure.goalChanged }
            confirmedFormHistory.append(receipt)
        }
        if let resolution = stage.nativePrefixResolution {
            guard resolution.receipt == receipt else { throw Failure.goalChanged }
            if !retiredFormHistory.contains(resolution.retirement) { retiredFormHistory.append(resolution.retirement) }
        }
        lastVerifiedFormStage = stage
    }

    private func runForm(_ stage: ComputerUseBrowserResearchFormStage) async throws -> ComputerUseBrowserResearchFormReceipt {
        let captured = input
        return try await operate { [self] in
            let receipt = try await stage.run(checkCurrent: { try self.checkCurrent(captured) })
            try recordForm(receipt, stage: stage, goal: captured)
            try checkCurrent(captured)
            return receipt
        }
    }

    /// Observe the result of the verified form stage before selecting a next
    /// step. This does not rediscover fields or discard their input receipts.
    func observeFormResultPage(after receipt: ComputerUseBrowserResearchFormReceipt) async throws -> ComputerUseBrowserPageEvidence {
        try requireIdle()
        try requireCompletedForm(receipt)
        let captured = input
        return try await operate { [self] in try await observeOwnedPage(goal: captured, enforceSources: true) }
    }

    /// Prepare only. The driver must separately retain and journal the selected
    /// navigation; the query still validates exact values and native receipts.
    func prepareFormQuery(after receipt: ComputerUseBrowserResearchFormReceipt, controlID: String,
                          evidence: ComputerUseBrowserPageEvidence) async throws -> ComputerUseBrowserNavigationTarget {
        try requireIdle()
        try requireCompletedForm(receipt)
        guard let formStage else { throw Failure.formUnavailable }
        let captured = input
        return try await operate { [self] in
            try await formStage.prepareQuery(controlID: controlID, evidence: evidence, checkCurrent: { try self.checkCurrent(captured) })
        }
    }

    /// Accept a query intent only from this owner's latest verified edit stage.
    /// Retain the intent before preparation; its child journals native loading.
    func openFormQuery(after receipt: ComputerUseBrowserResearchFormReceipt, controlID: String,
                       evidence: ComputerUseBrowserPageEvidence, scopeReview: ComputerUseBrowserEffectScopeReview? = nil) async throws -> ComputerUseBrowserNavigationReceipt {
        try requireIdle()
        guard initialSearch?.isPending != true, navigation?.pendingSelection == nil else { throw Failure.navigationPending }
        guard !hasPendingForm else { throw Failure.formPending }
        guard !hasQuestion else { throw Failure.questionPending }
        let query: ComputerUseBrowserResearchFormNavigation
        if let retained = formNavigation, retained.form == receipt {
            guard retained.controlID == controlID, retained.evidence == evidence, retained.scopeReview == scopeReview else { throw Failure.formUnavailable }
            query = retained
        } else {
            try requireCompletedForm(receipt)
            guard let formStage, let directory = navigationDirectory else { throw Failure.formUnavailable }
            query = try .init(form: receipt, controlID: controlID, evidence: evidence, stage: formStage,
                browser: browser, journalDirectory: directory, currentGoal: input, scopeReview: scopeReview, makeStore: navigationStore)
            formNavigation = query
        }
        guard query.goal == input else { throw Failure.goalChanged }
        latestForm = nil; latestAction = nil; latestCandidates = nil
        return try await runFormNavigation(query)
    }

    func resumeFormNavigation() async throws -> ComputerUseBrowserNavigationReceipt? {
        try requireIdle()
        guard initialSearch?.isPending != true, navigation?.pendingSelection == nil else { throw Failure.navigationPending }
        guard !hasPendingForm else { throw Failure.formPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let formNavigation else { return nil }
        guard formNavigation.goal == input else { throw Failure.goalChanged }
        latestForm = nil; latestAction = nil; latestCandidates = nil
        return try await runFormNavigation(formNavigation)
    }

    private func runFormNavigation(_ query: ComputerUseBrowserResearchFormNavigation) async throws -> ComputerUseBrowserNavigationReceipt {
        let captured = input
        return try await operate { [self] in
            let receipt = try await query.run(checkCurrent: { try self.checkCurrent(captured) })
            try recordNavigation(.formQuery, document: receipt.document, goal: captured)
            try checkCurrent(captured)
            return receipt
        }
    }

    private func requireCompletedForm(_ receipt: ComputerUseBrowserResearchFormReceipt) throws {
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasPendingForm else { throw Failure.formPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let formStage, formStage.id == receipt.stageID, confirmedFormHistory.last == receipt,
              input.continues(formStage.input.interpretation.input) else { throw Failure.formUnavailable }
        guard sourcePolicy == nil || (sourcePolicyInstalled && sourcePolicy?.goalRevision == input.digest) else { throw Failure.navigationUnavailable }
    }

    func readCandidates(for action: ComputerUseBrowserActionProposal? = nil) async throws -> ComputerUseBrowserResultCandidates {
        try requireIdle()
        if let action {
            try validateAction(action)
            guard case .readResults = action.step else { throw ComputerUseBrowserActionPlanError.inputChanged }
        }
        guard !hasPendingForm else { throw Failure.formPending }
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let interpretation, interpretation.proposal.input.digest == input.digest,
              interpretation.proposal.disposition == .research else { throw Failure.interpretationRequired }
        let captured = input
        latestCandidates = nil; latestForm = nil; latestAction = nil
        let batch = try await operate { [self] in
            try await readCurrentCandidates(goal: captured, action: action)
        }
        latestCandidates = batch
        return batch
    }

    /// Returns only a newly revalidated reading, still not verified offer
    /// semantics or a complete answer. Failed validation retires the cache.
    func revalidateCandidates() async throws -> ComputerUseBrowserResultCandidates {
        try requireIdle()
        guard !hasPendingForm else { throw Failure.formPending }
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let retained = latestCandidates else { throw Failure.interpretationRequired }
        let captured = input
        latestCandidates = nil; latestForm = nil; latestAction = nil
        let batch = try await operate { [self] in
            try checkCurrent(captured)
            try await browser.validateResultCandidates(retained, goal: captured)
            try checkCurrent(captured)
            return retained
        }
        latestCandidates = batch
        return batch
    }

    /// User-visible partial findings from the current permitted document.
    /// No new planning, navigation, completion claim or historical promotion.
    func validateProgressReport(_ report: ComputerUseBrowserResearchReport) throws {
        try requireIdle()
        try checkCurrent(input)
        guard report.rootTaskID == taskID, report.goalRevision == input.digest,
              report.readingIdentity == latestCandidates?.requirementAssessmentIdentity else { throw Failure.goalChanged }
    }

    func prepareProgressReport() async throws -> ComputerUseBrowserResearchReport? {
        try requireIdle()
        guard !hasPendingForm else { throw Failure.formPending }
        guard initialSearch?.isPending != true, !hasPendingNavigation, !hasPendingFormNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let retained = latestCandidates, let policy = researchSources?.answerPolicy else { return nil }
        let captured = input
        return try await operate { [self] in
            try checkCurrent(captured)
            let report = try await browser.prepareResearchReport(retained, goal: captured, policy: policy)
            try checkCurrent(captured)
            guard report == nil || (report?.goalRevision == captured.digest
                && report?.readingIdentity == retained.requirementAssessmentIdentity) else { throw Failure.goalChanged }
            return report
        }
    }

    func validateAnswer(_ answer: ComputerUseBrowserResearchAnswer) throws {
        try requireIdle(); try checkCurrent(input)
        guard !hasPendingForm else { throw Failure.formPending }
        guard initialSearch?.isPending != true, !hasPendingNavigation, !hasPendingFormNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard answer.rootTaskID == taskID, answer.goalRevision == input.digest,
              let reading = latestCandidates, answer.readingIdentity == reading.requirementAssessmentIdentity,
              let eligibility = try reading.answerEligibility(goal: input, evidence: retainedEvidence, recalledReadings: answer.recalledReadings) else { throw Failure.goalChanged }
        try answer.validate(for: eligibility)
        try browser.validateResearchAnswerBinding(answer, reading: reading, goal: input, evidence: retainedEvidence)
    }

    func prepareAnswer(_ selection: ComputerUseBrowserResearchAnswer.Selection) async throws -> ComputerUseBrowserResearchAnswer {
        try requireIdle()
        guard !hasPendingForm else { throw Failure.formPending }
        guard initialSearch?.isPending != true, !hasPendingNavigation, !hasPendingFormNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let reading = latestCandidates, let policy = researchSources?.answerPolicy else { throw Failure.interpretationRequired }
        let captured = input
        return try await operate { [self] in
            try checkCurrent(captured)
            let answer = try await browser.prepareResearchAnswer(selection, reading: reading, goal: captured, policy: policy, evidence: retainedEvidence)
            try checkCurrent(captured)
            return answer
        }
    }

    func openCandidateLink(candidateID: String, linkID: String) async throws -> ComputerUseBrowserNavigationReceipt {
        try requireIdle()
        guard !hasPendingForm else { throw Failure.formPending }
        guard initialSearch?.isPending != true, !hasPendingFormNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let navigation else { throw Failure.navigationUnavailable }
        guard let interpretation, interpretation.proposal.input.digest == input.digest,
              interpretation.proposal.disposition == .research else { throw Failure.interpretationRequired }
        let captured = input, candidates = latestCandidates
        let selection = ComputerUseBrowserResearchNavigation.Selection(goalRevision: captured.digest, candidateID: candidateID, linkID: linkID)
        latestCandidates = nil; latestForm = nil; latestAction = nil
        return try await operate { [self] in
            let receipt = try await navigation.open(selection, goal: captured, candidates: candidates, checkCurrent: { try self.checkCurrent(captured) })
            try recordNavigation(.resultLink, document: receipt.document, goal: captured)
            return receipt
        }
    }

    /// Keep fresh reading and no-effect link selection inside the same owner
    /// operation. Pause must cancel/join the selector before another owner can
    /// take over. The selected link is still natively bound again when opened.
    func planCandidateNavigation(budget: Duration = .seconds(30), select: @escaping @MainActor @Sendable
        (ComputerUseBrowserGoalInput, ComputerUseBrowserResultCandidates) async throws -> LinkChoice?) async throws -> LinkChoice? {
        let decision = try await planResearchDecision(budget: budget) { goal, candidates in
            try await select(goal, candidates).map { .link($0) } ?? .unresolved
        }
        switch decision { case .link(let choice): return choice; case .unresolved: return nil; case .answer, .revisit: throw ComputerUseBrowserLinkPlanError.invalidProposal }
    }

    func planResearchDecision(for action: ComputerUseBrowserActionProposal? = nil, budget: Duration = .seconds(30), select: @escaping @MainActor @Sendable
        (ComputerUseBrowserGoalInput, ComputerUseBrowserResultCandidates) async throws -> Decision) async throws -> Decision {
        try requireIdle()
        if let action {
            try validateAction(action)
            guard case .readResults = action.step else { throw ComputerUseBrowserActionPlanError.inputChanged }
        }
        guard !hasPendingForm else { throw Failure.formPending }
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let interpretation, interpretation.proposal.input.digest == input.digest,
              interpretation.proposal.disposition == .research else { throw Failure.interpretationRequired }
        guard budget > .zero else { throw ComputerUseBrowserLinkPlanError.deadlineExceeded }
        let captured = input, epoch = controlEpoch
        latestCandidates = nil; latestForm = nil; latestAction = nil
        let result = try await operate { [self] in
            let candidates = try await readCurrentCandidates(goal: captured, action: action)
            let choice = try await selectCandidateDecision(goal: captured, candidates: candidates, budget: budget, select: select)
            return (choice, candidates)
        }
        try checkCurrent(captured)
        guard controlEpoch == epoch else { throw Failure.paused }
        latestCandidates = result.1
        return result.0
    }

    /// One deadline covers the entire no-effect decision, including recalled
    /// readings and final native validation. The preceding reading/review has
    /// its own admission; selecting another recall cannot restart this clock.
    /// Structured cancellation joins the selector before releasing the owner.
    private func selectCandidateLink(goal: ComputerUseBrowserGoalInput, candidates: ComputerUseBrowserResultCandidates,
        budget: Duration, select: @escaping @MainActor @Sendable
        (ComputerUseBrowserGoalInput, ComputerUseBrowserResultCandidates) async throws -> LinkChoice?) async throws -> LinkChoice? {
        let decision = try await selectCandidateDecision(goal: goal, candidates: candidates, budget: budget) { goal, candidates in
            try await select(goal, candidates).map { .link($0) } ?? .unresolved
        }
        switch decision { case .link(let choice): return choice; case .unresolved: return nil; case .answer, .revisit: throw ComputerUseBrowserLinkPlanError.invalidProposal }
    }

    private func selectCandidateDecision(goal: ComputerUseBrowserGoalInput, candidates: ComputerUseBrowserResultCandidates,
        budget: Duration, select: @escaping @MainActor @Sendable
        (ComputerUseBrowserGoalInput, ComputerUseBrowserResultCandidates) async throws -> Decision) async throws -> Decision {
        let deadline = ContinuousClock.now.advanced(by: min(.seconds(30), max(.zero, budget)))
        try checkCandidateLinkDecision(goal: goal, deadline: deadline)
        return try await withThrowingTaskGroup(of: Decision.self) { group in
            group.addTask { @MainActor [self] in
                try checkCandidateLinkDecision(goal: goal, deadline: deadline)
                let choice = try await select(goal, candidates)
                try checkCandidateLinkDecision(goal: goal, deadline: deadline)
                try await browser.validateResultCandidates(candidates, goal: goal)
                try checkCandidateLinkDecision(goal: goal, deadline: deadline)
                switch choice {
                case .revisit(let option):
                    guard candidates.historyOptions.contains(option) else { throw ComputerUseBrowserLinkPlanError.inputChanged }
                    try await browser.validateObservedDestination(option.target)
                    try checkCandidateLinkDecision(goal: goal, deadline: deadline)
                case .link(let choice):
                    guard let candidate = candidates.candidates.first(where: { $0.id == choice.candidateID }),
                          candidate.selectedLinkIDs.contains(choice.linkID) else { throw ComputerUseBrowserResultError.invalidProposal }
                case .answer(let selection):
                    guard let eligibility = try candidates.answerEligibility(goal: goal, evidence: retainedEvidence, recalledReadings: selection.recalledReadings) else { throw ComputerUseBrowserLinkPlanError.inputChanged }
                    _ = try eligibility.answer(for: selection)
                case .unresolved: break
                }
                return choice
            }
            group.addTask {
                try await Task.sleep(until: deadline, clock: .continuous)
                try Task.checkCancellation()
                throw ComputerUseBrowserLinkPlanError.deadlineExceeded
            }
            defer { group.cancelAll() }
            guard let choice = try await group.next() else { throw ComputerUseBrowserLinkPlanError.invalidProposal }
            try checkCandidateLinkDecision(goal: goal, deadline: deadline)
            return choice
        }
    }

    private func checkCandidateLinkDecision(goal: ComputerUseBrowserGoalInput, deadline: ContinuousClock.Instant) throws {
        try checkCurrent(goal)
        guard ContinuousClock.now < deadline else { throw ComputerUseBrowserLinkPlanError.deadlineExceeded }
    }

    /// Resume the retained stage before planning another action or question.
    /// Its journal reconciles attempts; missing receipts never authorize replay.
    func resumeCandidateNavigation() async throws -> ComputerUseBrowserNavigationReceipt? {
        try requireIdle()
        guard !hasPendingForm else { throw Failure.formPending }
        guard initialSearch?.isPending != true, !hasPendingFormNavigation else { throw Failure.navigationPending }
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
    func replanPendingCandidateNavigation(budget: Duration = .seconds(30), select: @escaping @MainActor @Sendable
        (ComputerUseBrowserGoalInput, ComputerUseBrowserResultCandidates) async throws -> LinkChoice?) async throws -> ComputerUseBrowserResearchNavigation.ReplanResult {
        try requireIdle()
        guard !hasPendingForm else { throw Failure.formPending }
        guard initialSearch?.isPending != true, !hasPendingFormNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let navigation else { throw Failure.navigationUnavailable }
        guard let interpretation, interpretation.proposal.input.digest == input.digest,
              interpretation.proposal.disposition == .research else { throw Failure.interpretationRequired }
        guard budget > .zero else { throw ComputerUseBrowserLinkPlanError.deadlineExceeded }
        let captured = input
        latestCandidates = nil; latestForm = nil; latestAction = nil
        return try await operate { [self] in
            try await navigation.replan(goal: captured, prepare: {
                let candidates = try await self.readCurrentCandidates(goal: captured)
                guard let choice = try await self.selectCandidateLink(goal: captured, candidates: candidates, budget: budget, select: select) else { return nil }
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
        guard !hasPendingFormExecution else { throw Failure.formPending }
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard let interpretation, interpretation.proposal.input.digest == input.digest else { throw Failure.interpretationRequired }
        let context = try questionContext(controllerID: controllerID, controllerSessionID: controllerSessionID)
        let question = try clarification.issue(proposal: interpretation.proposal, topic: topic, requirementIDs: requirementIDs, context: context)
        hasQuestion = true; latestCandidates = nil; latestForm = nil; latestAction = nil
        return question
    }

    func answerQuestion(questionID: String, answerTaskID: String, answer: String,
                        controllerID: String, controllerSessionID: String) throws -> ComputerUseBrowserGoalInput {
        try requireIdle()
        guard !hasPendingFormExecution else { throw Failure.formPending }
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        let context = try questionContext(controllerID: controllerID, controllerSessionID: controllerSessionID)
        let updated: ComputerUseBrowserGoalInput
        do { updated = try clarification.consume(questionID: questionID, answerTaskID: answerTaskID, answer: answer, context: context) }
        catch ComputerUseBrowserGoalClarification.Failure.expired {
            hasQuestion = false
            throw ComputerUseBrowserGoalClarification.Failure.expired
        }
        // A new user answer can replace an unstarted plan with no retained
        // preservation/read obligations or previously verified criteria. Keep
        // all other original frames
        // until goal-revision reconciliation can explicitly carry them.
        if formPreparation?.hasPreservationObligations == false { formPreparation = nil }
        interpretation = nil; latestCandidates = nil; latestForm = nil; latestAction = nil; hasQuestion = false
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
        retainedEvidence.invalidateAnswerReadings()
        isPaused = true; controlEpoch = UUID()
        if handback == nil {
            handback = session ?? (browser.taskID == taskID ? browser.handbackRequirement(taskID: taskID, required: true) : nil)
        }
        latestCandidates = nil
        // Retain private invariants through an idle Pause too. This is not
        // permission to act: explicit handback and original-input validation
        // are still required before planning or executing the retained form.
        if latestForm?.input.nativePreservation == nil { latestForm = nil }
        latestAction = nil; clarification.invalidateQuestion(); hasQuestion = false
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
        isRetired = true; controlEpoch = UUID(); latestCandidates = nil; latestForm = nil; latestAction = nil; interpretation = nil
        formPreparation = nil
        confirmedNavigationHistory.removeAll()
        formStage?.retire(); formStage = nil; lastVerifiedFormStage?.retire(); lastVerifiedFormStage = nil
        confirmedFormHistory.removeAll(); retiredFormHistory.removeAll()
        formNavigation?.retire(); formNavigation = nil
        historyNavigation?.retire(); historyNavigation = nil
        retiredHistoryNavigations.removeAll()
        popupStage?.retire(); popupStage = nil; popupNeedsReopen = false; popupHistory.removeAll()
        optionSelectionStage?.retire(); optionSelectionStage = nil; optionSelectionNeedsReopen = false; optionSelectionHistory.removeAll()
        retainedEvidence = .init(goal: input)
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

    private func observeOwnedPage(goal: ComputerUseBrowserGoalInput, enforceSources: Bool = false,
                                  includingControlState: Bool = false) async throws -> ComputerUseBrowserPageEvidence {
        try checkCurrent(goal); try captureSession()
        let document = try await browser.acquireObservedDocument(taskID: taskID)
        do {
            try checkCurrent(goal)
            if enforceSources { try browser.validateSourceDocument(document) }
            let evidence = try await browser.observePage(document: document, includingControlState: includingControlState)
            try checkCurrent(goal)
            if enforceSources { try browser.validateSourceDocument(document) }
            return evidence
        } catch {
            await browser.joinDOMCompletion(document: document)
            throw error
        }
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

    private func readCurrentCandidates(goal: ComputerUseBrowserGoalInput, action: ComputerUseBrowserActionProposal? = nil) async throws -> ComputerUseBrowserResultCandidates {
        // Authentication observation may inspect a manually reached page,
        // but its contents cannot enter result inference outside task scope.
        guard sourcePolicy == nil || sourcePolicyInstalled else { throw Failure.navigationUnavailable }
        guard let interpretation, interpretation.proposal.input == goal else { throw Failure.interpretationRequired }
        try retainedEvidence.requireCapacity()
        let evidence: ComputerUseBrowserPageEvidence
        if let action, !action.readControls.isEmpty {
            try checkCurrent(goal); try captureSession()
            guard action.input.interpretation == interpretation.proposal else { throw ComputerUseBrowserActionPlanError.inputChanged }
            do {
                evidence = try await browser.observeResearchControls(for: action)
                try checkCurrent(goal)
            } catch {
                await browser.joinDOMCompletion(document: action.input.evidence.document)
                throw error
            }
        } else if let action, !action.input.optionReadControls.isEmpty {
            try checkCurrent(goal); try captureSession()
            guard action.input.interpretation == interpretation.proposal else { throw ComputerUseBrowserActionPlanError.inputChanged }
            do {
                try await browser.validatePageEvidence(action.input.evidence)
                try checkCurrent(goal); try browser.validateSourceDocument(action.input.evidence.document)
                evidence = action.input.evidence
            } catch {
                await browser.joinDOMCompletion(document: action.input.evidence.document)
                throw error
            }
        } else {
            evidence = try await observeOwnedPage(goal: goal, enforceSources: true, includingControlState: true)
        }
        try requireOriginalPopupCriteria(in: evidence)
        let page = try ComputerUseBrowserResultPageInput(page: evidence.page)
        let proposal = try await resultPlanner.propose(interpretation: interpretation.proposal, page: page)
        try checkCurrent(goal)
        let answerPolicy = researchSources?.answerPolicy
        guard answerPolicy == nil || answerPolicy?.goalRevision == goal.digest else { throw Failure.goalChanged }
        guard self.interpretation?.proposal == interpretation.proposal else { throw Failure.interpretationRequired }
        let bound = try await browser.prepareResultCandidates(proposal, goal: goal, evidence: evidence,
            answerPolicy: answerPolicy, interpretation: interpretation.proposal,
            historyOptions: browser.historyOptions(goal: goal, visits: confirmedNavigationHistory, evidence: evidence))
        try checkCurrent(goal)
        try retainedEvidence.record(bound, goal: goal)
        return bound
    }

    private func requireIdle(allowPendingPopup: Bool = false, allowPendingOptionSelection: Bool = false) throws {
        try Task.checkCancellation()
        guard !isRetired else { throw Failure.retired }
        guard !isPaused else { throw Failure.paused }
        guard mayAct() else { throw ComputerUseBrowserError.ownershipLost }
        guard operationID == nil else { throw Failure.busy }
        guard allowPendingPopup || !hasPendingPopup else { throw Failure.popupPending }
        guard allowPendingOptionSelection || !hasPendingOptionSelection else { throw Failure.optionSelectionPending }
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

    private func operate<Value: Sendable>(allowPendingPopup: Bool = false, allowPendingOptionSelection: Bool = false, _ body: @escaping @MainActor @Sendable () async throws -> Value) async throws -> Value {
        try requireIdle(allowPendingPopup: allowPendingPopup, allowPendingOptionSelection: allowPendingOptionSelection)
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

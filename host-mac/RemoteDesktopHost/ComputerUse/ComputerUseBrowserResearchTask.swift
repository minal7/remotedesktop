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
    enum Kind: String, Sendable { case search, resultLink, formQuery }
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
    enum Failure: Error, Equatable { case busy, paused, retired, goalChanged, interpretationRequired, questionPending, browserRequired, navigationPending, navigationUnavailable, formPending, formUnavailable }
    struct Interpretation: Sendable {
        let proposal: ComputerUseBrowserGoalProposal
        let scalars: ComputerUseBrowserScalarRequirements
        var sources: ComputerUseBrowserSourceRequirements { .init(proposal: proposal) }
    }
    struct LinkChoice: Sendable { let candidateID: String; let linkID: String }
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
    private var latestAction: ComputerUseBrowserActionProposal?
    private var formStage: ComputerUseBrowserResearchFormStage?
    private var formNavigation: ComputerUseBrowserResearchFormNavigation?
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
    var hasPendingNavigation: Bool { initialSearch?.isPending == true || navigation?.pendingSelection != nil || hasPendingFormNavigation }
    var hasPendingFormNavigation: Bool {
        guard let formNavigation else { return false }
        return !confirmedNavigationHistory.contains { $0.operationID == formNavigation.operationID && $0.kind == .formQuery }
    }
    var hasPendingForm: Bool {
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
        guard !hasPendingForm else { throw Failure.formPending }
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
        guard !hasPendingForm else { throw Failure.formPending }
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
        guard !hasPendingForm else { throw Failure.formPending }
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
    func planNextAction(using planner: any ComputerUseBrowserActionPlanning) async throws -> ComputerUseBrowserActionProposal {
        try requireIdle()
        guard !hasPendingForm else { throw Failure.formPending }
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let interpretation, interpretation.proposal.input == input,
              interpretation.proposal.disposition == .research else { throw Failure.interpretationRequired }
        guard sourcePolicy == nil || sourcePolicyInstalled else { throw Failure.navigationUnavailable }
        let captured = input
        latestCandidates = nil; latestForm = nil; latestAction = nil
        let action = try await operate { [self] in
            let page = try await observeOwnedPage(goal: captured, enforceSources: true)
            let context = try ComputerUseBrowserActionInput(interpretation: interpretation.proposal, evidence: page,
                navigationHistory: confirmedNavigationHistory, formHistory: confirmedFormHistory, latestForm: formStage)
            let proposal = try await planner.propose(context)
            try checkCurrent(captured)
            try proposal.validate(for: context)
            try await browser.validatePageEvidence(page)
            try checkCurrent(captured); try browser.validateSourceDocument(page.document)
            return proposal
        }
        latestAction = action
        return action
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
        return try await openFormQuery(after: receipt, controlID: controlID, evidence: action.input.evidence)
    }

    /// Prepare native field correspondence before semantic form planning.
    /// This only observes; it neither runs a model nor edits/submits a form.
    func prepareFormInput() async throws -> ComputerUseBrowserResearchFormInput {
        try await prepareFormInput(action: nil)
    }

    func prepareFormInput(for action: ComputerUseBrowserActionProposal) async throws -> ComputerUseBrowserResearchFormInput {
        try validateAction(action)
        guard case .editForm = action.step else { throw ComputerUseBrowserActionPlanError.invalidProposal }
        return try await prepareFormInput(action: action)
    }

    private func prepareFormInput(action: ComputerUseBrowserActionProposal?) async throws -> ComputerUseBrowserResearchFormInput {
        try requireIdle()
        guard !hasPendingForm else { throw Failure.formPending }
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let interpretation, interpretation.proposal.input == input,
              interpretation.proposal.disposition == .research else { throw Failure.interpretationRequired }
        guard sourcePolicy == nil || sourcePolicyInstalled else { throw Failure.navigationUnavailable }
        let captured = input
        latestCandidates = nil; latestForm = nil; latestAction = nil
        let prepared = try await operate { [self] in
            let page: ComputerUseBrowserPageEvidence
            let selectedFormID: String?
            if let action, case .editForm(let formID) = action.step {
                try checkCurrent(captured)
                try await browser.validatePageEvidence(action.input.evidence)
                try browser.validateSourceDocument(action.input.evidence.document)
                page = action.input.evidence; selectedFormID = formID
            } else {
                page = try await observeOwnedPage(goal: captured, enforceSources: true)
                selectedFormID = nil
            }
            guard browser.hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
            // New discovery clears native input receipts. Until retained
            // field extension/aggregate continuations are implemented, an
            // automatic dependent edit must preserve that earlier authority.
            if action != nil, let formStage, formStage.nativeReceipt != nil,
               formStage.input.evidence.page.document == page.document {
                throw ComputerUseBrowserActionPlanError.retainedFormRequiresExtension
            }
            let target = ComputerUseBrowserTextTarget(browser: browser, document: page.document,
                requiresFrontmost: browser.isFrontmostWindow)
            let fields = try await target.fields()
            let evidence = try await target.bindFields(fields, to: page)
            try checkCurrent(captured)
            guard browser.hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
            return PreparedForm(target: target, input: try .init(interpretation: interpretation.proposal, evidence: evidence, selectedFormID: selectedFormID))
        }
        latestForm = prepared
        return prepared.input
    }

    /// Reuse the exact adapter, page and field set. A failed or interrupted
    /// check cannot leave a planning input eligible for later consumption.
    func revalidateFormInput(_ proposed: ComputerUseBrowserResearchFormInput) async throws {
        try requireIdle()
        guard !hasPendingForm else { throw Failure.formPending }
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let retained = latestForm, retained.input == proposed,
              interpretation?.proposal == proposed.interpretation,
              proposed.interpretation.input == input else { throw ComputerUseBrowserResearchFormError.inputChanged }
        let captured = input
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
        guard !hasPendingForm else { throw Failure.formPending }
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let retained = latestForm, retained.input == proposed,
              interpretation?.proposal == proposed.interpretation, proposed.interpretation.input == input else {
            throw ComputerUseBrowserResearchFormError.inputChanged
        }
        let captured = input
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
        guard browser.hasRequiredPresentation else { throw ComputerUseBrowserError.windowNotActive }
        try browser.validateSourceDocument(prepared.input.evidence.page.document)
        try await prepared.target.validateFormEvidence(prepared.input.evidence)
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
        guard expected.interpretation.input == input, interpretation?.proposal == expected.interpretation else { throw Failure.goalChanged }
        try proposal.validate(for: expected)
        let stage: ComputerUseBrowserResearchFormStage
        if let formStage, formStage.input == expected, formStage.proposal == proposal { stage = formStage }
        else {
            guard !hasPendingForm else { throw Failure.formPending }
            guard let prepared = latestForm, prepared.input == expected, let directory = navigationDirectory else { throw Failure.formUnavailable }
            stage = try .init(input: expected, proposal: proposal, target: prepared.target, browser: browser,
                index: confirmedFormHistory.count, journalDirectory: directory, makeStore: navigationStore)
            formStage = stage // Retain before any disk write, native await or effect.
        }
        latestForm = nil; latestAction = nil; latestCandidates = nil
        return try await runForm(stage)
    }

    func resumeForm() async throws -> ComputerUseBrowserResearchFormReceipt? {
        try requireIdle()
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let formStage else { return nil }
        guard formStage.input.interpretation.input == input else { throw Failure.goalChanged }
        latestForm = nil; latestAction = nil; latestCandidates = nil
        return try await runForm(formStage)
    }

    private func runForm(_ stage: ComputerUseBrowserResearchFormStage) async throws -> ComputerUseBrowserResearchFormReceipt {
        let captured = input
        return try await operate { [self] in
            let receipt = try await stage.run(checkCurrent: { try self.checkCurrent(captured) })
            if !isRetired {
                if let previous = confirmedFormHistory.first(where: { $0.stageID == receipt.stageID }) {
                    guard previous == receipt else { throw Failure.goalChanged }
                } else {
                    guard receipt.taskID == taskID, receipt.goalRevision == captured.digest,
                          receipt.index == confirmedFormHistory.count else { throw Failure.goalChanged }
                    confirmedFormHistory.append(receipt)
                }
            }
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
                       evidence: ComputerUseBrowserPageEvidence) async throws -> ComputerUseBrowserNavigationReceipt {
        try requireIdle()
        guard initialSearch?.isPending != true, navigation?.pendingSelection == nil else { throw Failure.navigationPending }
        guard !hasPendingForm else { throw Failure.formPending }
        guard !hasQuestion else { throw Failure.questionPending }
        let query: ComputerUseBrowserResearchFormNavigation
        if let retained = formNavigation, retained.form == receipt {
            guard retained.controlID == controlID, retained.evidence == evidence else { throw Failure.formUnavailable }
            query = retained
        } else {
            try requireCompletedForm(receipt)
            guard let formStage, let directory = navigationDirectory else { throw Failure.formUnavailable }
            query = try .init(form: receipt, controlID: controlID, evidence: evidence, stage: formStage,
                browser: browser, journalDirectory: directory, makeStore: navigationStore)
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
              formStage.input.interpretation.input == input else { throw Failure.formUnavailable }
    }

    func readCandidates() async throws -> ComputerUseBrowserResultCandidates {
        try requireIdle()
        guard !hasPendingForm else { throw Failure.formPending }
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let interpretation, interpretation.proposal.input.digest == input.digest,
              interpretation.proposal.disposition == .research else { throw Failure.interpretationRequired }
        let captured = input
        latestCandidates = nil; latestForm = nil; latestAction = nil
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
    func planCandidateNavigation(select: @escaping @MainActor @Sendable
        (ComputerUseBrowserGoalInput, ComputerUseBrowserResultCandidates) async throws -> LinkChoice?) async throws -> LinkChoice? {
        try requireIdle()
        guard !hasPendingForm else { throw Failure.formPending }
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let interpretation, interpretation.proposal.input.digest == input.digest,
              interpretation.proposal.disposition == .research else { throw Failure.interpretationRequired }
        let captured = input, epoch = controlEpoch
        latestCandidates = nil; latestForm = nil; latestAction = nil
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
    func replanPendingCandidateNavigation(select: @escaping @MainActor @Sendable
        (ComputerUseBrowserGoalInput, ComputerUseBrowserResultCandidates) async throws -> LinkChoice?) async throws -> ComputerUseBrowserResearchNavigation.ReplanResult {
        try requireIdle()
        guard !hasPendingForm else { throw Failure.formPending }
        guard initialSearch?.isPending != true, !hasPendingFormNavigation else { throw Failure.navigationPending }
        guard !hasQuestion else { throw Failure.questionPending }
        guard let navigation else { throw Failure.navigationUnavailable }
        guard let interpretation, interpretation.proposal.input.digest == input.digest,
              interpretation.proposal.disposition == .research else { throw Failure.interpretationRequired }
        let captured = input
        latestCandidates = nil; latestForm = nil; latestAction = nil
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
        guard !hasPendingForm else { throw Failure.formPending }
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
        guard !hasPendingForm else { throw Failure.formPending }
        guard !hasPendingNavigation else { throw Failure.navigationPending }
        let context = try questionContext(controllerID: controllerID, controllerSessionID: controllerSessionID)
        let updated: ComputerUseBrowserGoalInput
        do { updated = try clarification.consume(questionID: questionID, answerTaskID: answerTaskID, answer: answer, context: context) }
        catch ComputerUseBrowserGoalClarification.Failure.expired {
            hasQuestion = false
            throw ComputerUseBrowserGoalClarification.Failure.expired
        }
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
        isPaused = true; controlEpoch = UUID()
        if handback == nil {
            handback = session ?? (browser.taskID == taskID ? browser.handbackRequirement(taskID: taskID, required: true) : nil)
        }
        latestCandidates = nil; latestForm = nil; latestAction = nil; clarification.invalidateQuestion(); hasQuestion = false
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
        confirmedNavigationHistory.removeAll()
        formStage?.retire(); formStage = nil; confirmedFormHistory.removeAll()
        formNavigation?.retire(); formNavigation = nil
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
        try retainedEvidence.requireCapacity()
        let evidence = try await observeOwnedPage(goal: goal, enforceSources: true)
        let page = try ComputerUseBrowserResultPageInput(page: evidence.page)
        let proposal = try await resultPlanner.propose(goal: goal, page: page)
        try checkCurrent(goal)
        let answerPolicy = researchSources?.answerPolicy
        guard answerPolicy == nil || answerPolicy?.goalRevision == goal.digest else { throw Failure.goalChanged }
        guard let interpretation, interpretation.proposal.input == goal else { throw Failure.interpretationRequired }
        let bound = try await browser.prepareResultCandidates(proposal, goal: goal, evidence: evidence,
            answerPolicy: answerPolicy, interpretation: interpretation.proposal)
        try checkCurrent(goal)
        try retainedEvidence.record(bound, goal: goal)
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

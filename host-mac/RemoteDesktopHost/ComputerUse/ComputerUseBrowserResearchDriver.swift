import Foundation

/// Provider policy is host-owned; link selection is a no-effect proposal.
/// Implementations must consider the entire goal, including source limits.
/// Native candidate binding and action journals remain the owner's authority.
@MainActor
protocol ComputerUseBrowserResearchPlanning {
    func sources(for interpretation: ComputerUseBrowserResearchTask.Interpretation) throws -> ComputerUseBrowserResearchSources?
    func selectLink(goal: ComputerUseBrowserGoalInput, candidates: ComputerUseBrowserResultCandidates,
                    history: [ComputerUseBrowserResearchVisit], evidence: ComputerUseBrowserResearchEvidence?) async throws -> ComputerUseBrowserResearchTask.LinkChoice?
}

extension ComputerUseBrowserResearchPlanning {
    func selectLink(goal: ComputerUseBrowserGoalInput, candidates: ComputerUseBrowserResultCandidates,
                    history: [ComputerUseBrowserResearchVisit]) async throws -> ComputerUseBrowserResearchTask.LinkChoice? {
        try await selectLink(goal: goal, candidates: candidates, history: history, evidence: nil)
    }
}

/// Concrete navigation orchestration for retained research. Policy is supplied
/// separately; supported native forms use retained edit/query stages. General
/// widgets and verified research answers remain incomplete. A page load cannot declare research success.
@MainActor
final class ComputerUseBrowserResearchDriver: ComputerUseBrowserResearchExecuting {
    enum Failure: Error, Equatable { case busy, alreadyAdmitted, invalidContinuation, invalidProposal }
    private struct SeededGoalPlanner: ComputerUseBrowserGoalPlanning {
        let seed: ComputerUseBrowserGoalProposal
        let base: any ComputerUseBrowserGoalPlanning
        func propose(_ input: ComputerUseBrowserGoalInput) async throws -> ComputerUseBrowserGoalProposal {
            try Task.checkCancellation()
            if input == seed.input { return seed }
            return try await base.propose(input)
        }
    }
    @MainActor private final class Run {
        let owner: ComputerUseBrowserResearchTask
        var input: ComputerUseBrowserGoalInput
        var visits: [ComputerUseBrowserResearchVisit] = []
        var sources: ComputerUseBrowserResearchSources?
        init(owner: ComputerUseBrowserResearchTask) { self.owner = owner; input = owner.input }
    }
    private let goalPlanner: any ComputerUseBrowserGoalPlanning
    private let resultPlanner: any ComputerUseBrowserResultPlanning
    private let searchPlanner: any ComputerUseBrowserSearchPlanning
    private let actionPlanner: any ComputerUseBrowserActionPlanning
    private let formPlanner: any ComputerUseBrowserFormPlanning
    private let planning: any ComputerUseBrowserResearchPlanning
    private let now: () -> Date
    private let timeZoneIdentifier: () -> String
    private let navigationLimit: Int
    private var retained: Run?
    private var isExecuting = false

    init(goalPlanner: any ComputerUseBrowserGoalPlanning, resultPlanner: any ComputerUseBrowserResultPlanning,
         searchPlanner: any ComputerUseBrowserSearchPlanning, actionPlanner: any ComputerUseBrowserActionPlanning,
         formPlanner: any ComputerUseBrowserFormPlanning, planning: any ComputerUseBrowserResearchPlanning,
         navigationLimit: Int = 24, now: @escaping () -> Date = Date.init,
         timeZoneIdentifier: @escaping () -> String = { TimeZone.current.identifier }) {
        self.goalPlanner = goalPlanner; self.resultPlanner = resultPlanner; self.searchPlanner = searchPlanner
        self.actionPlanner = actionPlanner; self.formPlanner = formPlanner
        self.planning = planning; self.now = now; self.timeZoneIdentifier = timeZoneIdentifier
        self.navigationLimit = min(32, max(1, navigationLimit))
    }

    func executeBrowserResearch(taskID: String, prompt: String, tools: ComputerUseHostTools,
        progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult? {
        guard !isExecuting else { throw Failure.busy }
        guard retained?.owner.taskID != taskID else { throw Failure.alreadyAdmitted }
        guard tools.ownedBrowserResearch(taskID: taskID) == nil else { throw Failure.invalidContinuation }
        isExecuting = true
        defer { isExecuting = false }
        try tools.validateBrowserResearchAdmission()
        let date = now(), zone = timeZoneIdentifier()
        let input = try ComputerUseBrowserGoalInput(taskID: taskID, prompt: prompt, referenceDate: date, timeZoneIdentifier: zone)
        // Text-only admission can decline before a browser owner is retained.
        // It sees no page/account data and cannot open or alter the browser.
        progress("Understanding the complete research request…")
        try tools.validateBrowserResearchAdmission()
        let proposal = try await goalPlanner.propose(input)
        try tools.validateBrowserResearchAdmission()
        guard proposal.input == input else { throw Failure.invalidProposal }
        if proposal.disposition == .unsupported { return nil }
        guard tools.ownedBrowserResearch(taskID: taskID) == nil else { throw Failure.invalidContinuation }
        let owner = try tools.prepareOwnedBrowserResearch(taskID: taskID, prompt: prompt,
            goalPlanner: SeededGoalPlanner(seed: proposal, base: goalPlanner), resultPlanner: resultPlanner,
            referenceDate: date, timeZoneIdentifier: zone, didPrepare: { [self] owner in
                guard owner.input == input else { throw Failure.invalidContinuation }
                retained = Run(owner: owner) // Survives a later admission-observer error.
            })
        guard let run = retained, run.owner === owner else { throw Failure.invalidContinuation }
        return try await advance(run, tools: tools, progress: progress)
    }

    func continueBrowserResearch(taskID: String, research: ComputerUseBrowserResearchTask,
        tools: ComputerUseHostTools, progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        guard !isExecuting else { throw Failure.busy }
        guard let run = retained, run.owner === research, research.executionTaskID == taskID,
              tools.ownedBrowserResearch(taskID: research.taskID) === research else { throw Failure.invalidContinuation }
        isExecuting = true
        defer { isExecuting = false }
        let input = research.input
        if input != run.input {
            guard input.rootDigest == run.input.rootDigest,
                  input.clarifications.count == run.input.clarifications.count + 1,
                  Array(input.clarifications.dropLast()) == run.input.clarifications,
                  input.clarifications.last?.answerTaskID == taskID else { throw Failure.invalidContinuation }
        }
        try research.validateDriverContinuation(input)
        run.input = input
        return try await advance(run, tools: tools, progress: progress)
    }

    private func advance(_ run: Run, tools: ComputerUseHostTools,
                         progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        do { return try await navigate(run, tools: tools, progress: progress) }
        catch ComputerUseBrowserError.observedNavigationUncertain, ComputerUseTaskExecutionError.uncertainEffect,
              ComputerUseTaskExecutionError.journalMismatch, ComputerUseTextTaskError.uncertainEffect,
              ComputerUseTextTaskError.journalMismatch, ComputerUseTextEditError.deliveryUncertain {
            try validate(run, tools: tools)
            return reconciliationRequired
        } catch is ComputerUseTaskJournalStore.StoreError {
            try validate(run, tools: tools)
            return .userInterventionRequired("The browser could not safely save or recover this action. The original request remains pending; check the Mac before continuing.")
        } catch ComputerUseBrowserError.pageChanged, ComputerUseBrowserError.linkNavigationUnavailable {
            try validate(run, tools: tools)
            return .userInterventionRequired("The page changed before the next browser action. Check the page, then choose Resume to continue the original request.")
        } catch ComputerUseBrowserError.formQueryUnavailable, ComputerUseBrowserError.formQueryInvalid,
                ComputerUseBrowserResearchFormError.inputChanged, ComputerUseTextTaskError.staleTarget,
                ComputerUseTextTaskError.incompleteOutcome {
            try validate(run, tools: tools)
            return .userInterventionRequired("The retained form or search cannot be verified on this page. The original request remains pending; review the form before continuing.")
        } catch ComputerUseBrowserError.sourceNotAllowed {
            try validate(run, tools: tools)
            return .userInterventionRequired(ComputerUseBrowserError.sourceNotAllowed.localizedDescription)
        } catch ComputerUseBrowserResultReviewError.deadlineExceeded {
            try validate(run, tools: tools)
            return .userInterventionRequired("The research review ran out of time. The original task is still pending. Review the page, then choose Resume to continue.")
        } catch is ComputerUseBrowserResultReviewError {
            try validate(run, tools: tools)
            return .userInterventionRequired("I could not determine how this page’s details belong to individual offers. The original request is still pending. Review the page, then choose Resume to continue.")
        } catch is ComputerUseBrowserResearchEvidenceError {
            try validate(run, tools: tools)
            return .userInterventionRequired("The browser could not retain another reading for this research task. Earlier findings and the original request remain pending.")
        } catch is ComputerUseBrowserActionPlanError, is ComputerUseBrowserResearchFormError {
            try validate(run, tools: tools)
            return .userInterventionRequired("The browser could not prepare the next form or reading action from the complete request. Earlier work and the original task remain pending.")
        } catch is ComputerUseBrowserLinkPlanError {
            try validate(run, tools: tools)
            return .userInterventionRequired("I could not choose the next step from the complete request and available readings. Earlier findings and the original task remain pending.")
        }
    }

    private func validate(_ run: Run, tools: ComputerUseHostTools) throws {
        try Task.checkCancellation()
        guard retained === run, tools.ownedBrowserResearch(taskID: run.owner.taskID) === run.owner else {
            throw Failure.invalidContinuation
        }
        try run.owner.validateDriverContinuation(run.input)
    }

    private func navigate(_ run: Run, tools: ComputerUseHostTools,
                          progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        let owner = run.owner
        func check() throws { try validate(run, tools: tools) }
        func synchronizeHistory() throws {
            let confirmed = owner.confirmedNavigationHistory
            guard confirmed.count >= run.visits.count,
                  Array(confirmed.prefix(run.visits.count)) == run.visits else { throw Failure.invalidContinuation }
            run.visits = confirmed
        }
        func record(_ kind: ComputerUseBrowserResearchVisit.Kind, _ document: ComputerUseBrowserDocument) throws -> Bool {
            guard retained === run, document.taskID == owner.taskID else { throw Failure.invalidProposal }
            let fresh = !run.visits.contains(where: { $0.operationID == document.operationID })
            try synchronizeHistory()
            guard run.visits.contains(where: { $0.operationID == document.operationID && $0.kind == kind
                && $0.goalRevision == run.input.digest }) else { throw Failure.invalidProposal }
            try check()
            return fresh
        }
        try check()
        // The owner may have received a confirmed child result immediately
        // before Pause cancelled its outer return. Recover those native facts
        // before applying the task limit or selecting another action.
        try synchronizeHistory()
        while run.visits.count < navigationLimit {
            try check()
            if owner.initialSearchState == .pending {
                progress("Checking the pending search…")
                let document: ComputerUseBrowserDocument?
                do { document = try await owner.resumeInitialSearch() }
                catch ComputerUseBrowserError.pageChanged {
                    let refresh = try await owner.refreshInitialSearchStartingPage()
                    try check()
                    guard refresh == .updated || refresh == .unchanged else { return reconciliationRequired }
                    document = try await owner.resumeInitialSearch()
                }
                guard let document, try record(.search, document) else { return reconciliationRequired }
                continue
            }
            if owner.hasPendingForm {
                progress("Checking the pending form entries…")
                do {
                    guard try await owner.resumeForm() != nil else { throw Failure.invalidContinuation }
                } catch {
                    guard try await retireProvenUnsentForm(owner, after: error) else { throw error }
                }
                try check()
                continue // Choose the next capability using the retained verified stage.
            }
            if owner.hasPendingFormNavigation {
                progress("Checking the pending form search…")
                guard let receipt = try await owner.resumeFormNavigation(),
                      try record(.formQuery, receipt.document) else { return reconciliationRequired }
                continue
            }
            if owner.hasPendingNavigation {
                progress("Checking the pending result link…")
                let history = run.visits
                let result = try await owner.replanPendingCandidateNavigation(select: { [planning] goal, candidates in
                    try await planning.selectLink(goal: goal, candidates: candidates, history: history, evidence: owner.researchEvidence(for: goal))
                })
                try check()
                switch result {
                case .requiresReconciliation, .updated:
                    guard let receipt = try await owner.resumeCandidateNavigation(),
                          try record(.resultLink, receipt.document) else { return reconciliationRequired }
                case .noSelection: return selectionRequired
                case .noPendingStage: throw Failure.invalidContinuation
                }
                continue
            }
            let interpretation = try await owner.interpretGoal()
            try check()
            if let question = try owner.proposedQuestionRequest() { return .browserClarificationRequired(question) }
            guard interpretation.proposal.disposition == .research else {
                return .userInterventionRequired("The complete request still has unresolved work. Review the original task before continuing.")
            }
            if run.sources?.policy.goalRevision != run.input.digest {
                let sources = try planning.sources(for: interpretation)
                try check()
                guard let sources else {
                    return .userInterventionRequired("I need a search source that matches your request. The original task is still pending.")
                }
                try owner.configureResearchSources(sources)
                run.sources = sources
            }
            if owner.initialSearchState == .notPrepared {
                guard let sources = run.sources else { throw Failure.invalidContinuation }
                let query = try await owner.planInitialSearch(using: searchPlanner)
                try check()
                guard query.query != nil else {
                    return .userInterventionRequired("I could not form a search for the complete request. The original task is still pending.")
                }
                progress("Searching for the requested information…")
                let document = try await owner.openInitialSearch(query, provider: sources.provider)
                guard try record(.search, document) else { return reconciliationRequired }
            } else {
                progress("Choosing the next step for the complete request…")
                let action = try await owner.planNextAction(using: actionPlanner)
                try check()
                switch action.step {
                case .editForm:
                    guard owner.confirmedFormHistory.count < 32 else {
                        return .userInterventionRequired("The browser reached this task's form-action limit. The original request remains pending.")
                    }
                    let input = try await owner.prepareFormInput(for: action)
                    progress("Preparing the requested form entries…")
                    let proposal = try await owner.planForm(input, using: formPlanner)
                    try check()
                    if let question = try proposal.questionRequest(for: input) { return .browserClarificationRequired(question) }
                    guard !proposal.isUnavailable else {
                        return .userInterventionRequired("I could not prepare justified entries for this form. The original request remains pending.")
                    }
                    do { _ = try await owner.executeForm(proposal, input: input) }
                    catch {
                        guard try await retireProvenUnsentForm(owner, after: error) else { throw error }
                    }
                    try check()
                    continue
                case .openQuery:
                    progress("Opening the verified form search…")
                    let receipt = try await owner.openFormQuery(for: action)
                    guard try record(.formQuery, receipt.document) else { return reconciliationRequired }
                    continue
                case .question:
                    guard let question = action.questionRequest else { throw Failure.invalidProposal }
                    return .browserClarificationRequired(question)
                case .unavailable:
                    return .userInterventionRequired("I could not choose a supported next step for the complete request on this page. The original task remains pending.")
                case .readResults: break
                }
                progress("Reading the page against the original request…")
                let history = run.visits
                let choice = try await owner.planCandidateNavigation(select: { [planning] goal, candidates in
                    try await planning.selectLink(goal: goal, candidates: candidates, history: history, evidence: owner.researchEvidence(for: goal))
                })
                try check()
                guard let choice else {
                    if let report = try await owner.prepareProgressReport() {
                        try check()
                        return .browserResearchProgress(report)
                    }
                    try check()
                    return selectionRequired
                }
                let receipt = try await owner.openCandidateLink(candidateID: choice.candidateID, linkID: choice.linkID)
                guard try record(.resultLink, receipt.document) else { return reconciliationRequired }
            }
        }
        try check()
        return .userInterventionRequired("The browser reached this task's navigation limit. The research answer is not yet verified; the original request remains pending.")
    }

    private var selectionRequired: ComputerUseExecutionResult {
        .userInterventionRequired("I could not select another result link that advances the complete request. More page interaction or result verification is needed; the original task is still pending.")
    }
    private func retireProvenUnsentForm(_ owner: ComputerUseBrowserResearchTask, after error: Error) async throws -> Bool {
        guard error as? ComputerUseBrowserError == .pageChanged
                || error as? ComputerUseBrowserResearchFormError == .inputChanged
                || error as? ComputerUseTextTaskError == .staleTarget
                || error as? ComputerUseTextTaskError == .uncertainEffect
                || error as? ComputerUseTextTaskError == .incompleteOutcome
                || error as? ComputerUseTextEditError == .deliveryUncertain
                || error as? ComputerUseBrowserResearchFormStage.Failure == .retirementPending else { return false }
        if try await owner.retainPendingFormPrefix() != nil { return true }
        return try await owner.retirePendingUnsentForm() != nil
    }
    private var reconciliationRequired: ComputerUseExecutionResult {
        .userInterventionRequired("An earlier browser action needs to be checked before continuing. The original request remains pending.")
    }
}

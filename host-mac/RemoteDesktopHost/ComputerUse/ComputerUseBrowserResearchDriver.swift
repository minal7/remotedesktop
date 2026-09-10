import Foundation

/// Cumulative driver-active time, not wall time or a measure of model/GPU
/// lifetime. Native stages admitted before expiry keep their cleanup/receipts.
/// Only explicit execution segments charge time; manual handback is outside.
@MainActor
final class ComputerUseBrowserWorkBudget {
    nonisolated static let defaultAllowance: Duration = .seconds(600)
    nonisolated static let maximumAllowance: Duration = .seconds(3_600)
    enum Failure: Error, Equatable, LocalizedError {
        case exhausted, invalidAllowance, alreadyActive
        var errorDescription: String? {
            switch self {
            case .exhausted:
                return "The browser reached this task's research time limit. The original request remains pending. You can continue manually; Resume does not extend this limit."
            case .invalidAllowance: return "Browser research could not start because its research time limit was invalid."
            case .alreadyActive: return "The browser is already working on this research task."
            }
        }
    }
    private let allowance: Duration
    private let clock: @MainActor () -> ContinuousClock.Instant
    private var remaining: Duration
    private var activeAt: ContinuousClock.Instant?

    init(allowance: Duration = ComputerUseBrowserWorkBudget.defaultAllowance, clock: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        self.allowance = allowance; remaining = allowance; self.clock = clock
    }
    func begin() throws {
        guard activeAt == nil else { throw Failure.alreadyActive }
        guard allowance > .zero, allowance <= Self.maximumAllowance else { throw Failure.invalidAllowance }
        guard remaining > .zero else { throw Failure.exhausted }
        activeAt = clock()
    }
    func finish() {
        chargeActiveTime()
        activeAt = nil
    }
    func admit() throws {
        guard activeAt != nil else { throw Failure.exhausted }
        chargeActiveTime()
        guard remaining > .zero else { throw Failure.exhausted }
    }
    /// Direct owner inspection/handback does not open an autonomous segment.
    /// The driver owns begin/finish; a late model callback cannot refill it.
    func planningTimeout(maximum: TimeInterval) throws -> TimeInterval {
        guard maximum.isFinite, maximum > 0, maximum <= ComputerUsePlanningWorker.maximumWait else {
            throw ComputerUsePlanningWorker.Failure.invalidDeadline
        }
        guard allowance > .zero, allowance <= Self.maximumAllowance else { throw Failure.invalidAllowance }
        chargeActiveTime()
        guard remaining > .zero else { throw Failure.exhausted }
        return min(maximum, Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18)
    }
    private func chargeActiveTime() {
        guard let previous = activeAt else { return }
        let current = clock()
        // A faulty injected clock must not refund already consumed work.
        if current < previous { remaining = .zero }
        else { remaining = max(.zero, remaining - previous.duration(to: current)) }
        activeAt = current
    }
}

/// Provider policy is host-owned; link selection is a no-effect proposal.
/// Implementations must consider the entire goal, including source limits.
/// Native candidate binding and action journals remain the owner's authority.
@MainActor
protocol ComputerUseBrowserResearchPlanning {
    func sources(for interpretation: ComputerUseBrowserResearchTask.Interpretation) throws -> ComputerUseBrowserResearchSources?
    func selectLink(goal: ComputerUseBrowserGoalInput, candidates: ComputerUseBrowserResultCandidates,
                    history: [ComputerUseBrowserResearchVisit], evidence: ComputerUseBrowserResearchEvidence?) async throws -> ComputerUseBrowserResearchTask.LinkChoice?
    func selectDecision(goal: ComputerUseBrowserGoalInput, candidates: ComputerUseBrowserResultCandidates,
                    history: [ComputerUseBrowserResearchVisit], evidence: ComputerUseBrowserResearchEvidence?) async throws -> ComputerUseBrowserResearchTask.Decision
}

extension ComputerUseBrowserResearchPlanning {
    func selectDecision(goal: ComputerUseBrowserGoalInput, candidates: ComputerUseBrowserResultCandidates,
                    history: [ComputerUseBrowserResearchVisit], evidence: ComputerUseBrowserResearchEvidence?) async throws -> ComputerUseBrowserResearchTask.Decision {
        try await selectLink(goal: goal, candidates: candidates, history: history, evidence: evidence).map { .link($0) } ?? .unresolved
    }
    func selectLink(goal: ComputerUseBrowserGoalInput, candidates: ComputerUseBrowserResultCandidates,
                    history: [ComputerUseBrowserResearchVisit]) async throws -> ComputerUseBrowserResearchTask.LinkChoice? {
        try await selectLink(goal: goal, candidates: candidates, history: history, evidence: nil)
    }
}

/// Concrete navigation orchestration for retained research. Policy is supplied
/// separately; supported native forms use retained edit/query stages. General
/// widgets remain incomplete. Informational answers combine eligible current
/// and fully recalled readings with typed selection and native source binding.
/// A page load alone cannot declare research success.
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
        let budget: ComputerUseBrowserWorkBudget
        var input: ComputerUseBrowserGoalInput
        var visits: [ComputerUseBrowserResearchVisit] = []
        var sources: ComputerUseBrowserResearchSources?
        init(owner: ComputerUseBrowserResearchTask, budget: ComputerUseBrowserWorkBudget) { self.owner = owner; self.budget = budget; input = owner.input }
    }
    private struct AdmissionInput {
        let input: ComputerUseBrowserGoalInput
        let date: Date
        let zone: String
        let budget: ComputerUseBrowserWorkBudget
    }
    private var admissionInput: AdmissionInput?
    private let goalPlanner: any ComputerUseBrowserGoalPlanning
    private let resultPlanner: any ComputerUseBrowserResultPlanning
    private let searchPlanner: any ComputerUseBrowserSearchPlanning
    private let actionPlanner: any ComputerUseBrowserActionPlanning
    private let formPlanner: any ComputerUseBrowserFormPlanning
    private let planning: any ComputerUseBrowserResearchPlanning
    private let planningWorker: ComputerUsePlanningWorker
    private let planningTimeout: TimeInterval
    private let activeWorkLimit: Duration
    private let monotonicNow: @MainActor () -> ContinuousClock.Instant
    private let now: () -> Date
    private let timeZoneIdentifier: () -> String
    private let navigationLimit: Int
    private var retained: Run?
    private var isExecuting = false

    init(goalPlanner: any ComputerUseBrowserGoalPlanning, resultPlanner: any ComputerUseBrowserResultPlanning,
         searchPlanner: any ComputerUseBrowserSearchPlanning, actionPlanner: any ComputerUseBrowserActionPlanning,
         formPlanner: any ComputerUseBrowserFormPlanning, planning: any ComputerUseBrowserResearchPlanning,
         navigationLimit: Int = 24, now: @escaping () -> Date = Date.init,
         timeZoneIdentifier: @escaping () -> String = { TimeZone.current.identifier },
         planningWorker: ComputerUsePlanningWorker = .shared, planningTimeout: TimeInterval = 30,
         activeWorkLimit: Duration = ComputerUseBrowserWorkBudget.defaultAllowance,
         monotonicNow: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        self.goalPlanner = goalPlanner; self.resultPlanner = resultPlanner; self.searchPlanner = searchPlanner
        self.actionPlanner = actionPlanner; self.formPlanner = formPlanner
        self.planning = planning; self.now = now; self.timeZoneIdentifier = timeZoneIdentifier
        self.planningWorker = planningWorker; self.planningTimeout = planningTimeout
        self.activeWorkLimit = activeWorkLimit; self.monotonicNow = monotonicNow
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
        let previousAdmission = admissionInput
        let admission: AdmissionInput
        if let original = admissionInput, original.input.taskID == taskID {
            guard original.input.prompt.utf8.elementsEqual(prompt.utf8) else { throw Failure.invalidContinuation }
            admission = original
        } else {
            let date = now(), zone = timeZoneIdentifier()
            admission = .init(input: try ComputerUseBrowserGoalInput(taskID: taskID, prompt: prompt, referenceDate: date, timeZoneIdentifier: zone), date: date, zone: zone,
                budget: .init(allowance: activeWorkLimit, clock: monotonicNow))
            admissionInput = admission
        }
        let input = admission.input
        try admission.budget.begin()
        defer { admission.budget.finish() }
        // Text-only admission can decline before a browser owner is retained.
        // It sees no page/account data and cannot open or alter the browser.
        progress("Understanding the complete research request…")
        try tools.validateBrowserResearchAdmission()
        let proposal: ComputerUseBrowserGoalProposal
        do {
            proposal = try await planningWorker.perform(timeout: admission.budget.planningTimeout(maximum: planningTimeout)) { [goalPlanner] in
                try await goalPlanner.propose(input)
            }
        } catch ComputerUsePlanningWorker.Failure.busy {
            // A competing request that never acquired planning capacity cannot
            // replace the original request's retry clock.
            admissionInput = previousAdmission
            throw ComputerUsePlanningWorker.Failure.busy
        } catch ComputerUsePlanningWorker.Failure.invalidDeadline {
            admissionInput = previousAdmission
            throw ComputerUsePlanningWorker.Failure.invalidDeadline
        }
        try tools.validateBrowserResearchAdmission()
        guard proposal.input == input else { throw Failure.invalidProposal }
        if proposal.disposition == .unsupported { return nil }
        try admission.budget.admit()
        guard tools.ownedBrowserResearch(taskID: taskID) == nil else { throw Failure.invalidContinuation }
        let owner = try tools.prepareOwnedBrowserResearch(taskID: taskID, prompt: prompt,
            goalPlanner: SeededGoalPlanner(seed: proposal, base: goalPlanner), resultPlanner: resultPlanner,
            referenceDate: admission.date, timeZoneIdentifier: admission.zone, planningWorker: planningWorker, planningTimeout: planningTimeout, workBudget: admission.budget, didPrepare: { [self] owner in
                guard owner.input == input else { throw Failure.invalidContinuation }
                retained = Run(owner: owner, budget: admission.budget) // Survives a later admission-observer error.
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
        do { try run.budget.begin() }
        catch ComputerUseBrowserWorkBudget.Failure.exhausted {
            try validate(run, tools: tools)
            return activeWorkLimitRequired
        }
        defer { run.budget.finish() }
        return try await advance(run, tools: tools, progress: progress)
    }

    private func advance(_ run: Run, tools: ComputerUseHostTools,
                         progress: @escaping (String) -> Void) async throws -> ComputerUseExecutionResult {
        do { return try await navigate(run, tools: tools, progress: progress) }
        catch ComputerUseBrowserWorkBudget.Failure.exhausted {
            try validate(run, tools: tools)
            return activeWorkLimitRequired
        }
        catch ComputerUseBrowserError.observedNavigationUncertain, ComputerUseTaskExecutionError.uncertainEffect,
              ComputerUseTaskExecutionError.journalMismatch, ComputerUseTextTaskError.uncertainEffect,
              ComputerUseTextTaskError.journalMismatch, ComputerUseTextEditError.deliveryUncertain,
              ComputerUseBrowserPopupError.uncertain, ComputerUseBrowserPopupError.retirementPending, ComputerUseBrowserPopupError.retired {
            try validate(run, tools: tools)
            return reconciliationRequired
        } catch is ComputerUseTaskJournalStore.StoreError {
            try validate(run, tools: tools)
            return .userInterventionRequired("The browser could not safely save or recover this action. The original request remains pending; check the Mac before continuing.")
        } catch ComputerUseBrowserResearchTask.Failure.observedCriteriaChanged {
            try validate(run, tools: tools)
            return .userInterventionRequired("A criterion observed before the dropdown action has changed or cannot be checked. Review it on the Mac before continuing; the original request remains pending.")
        } catch ComputerUseBrowserResearchTask.Failure.optionSelectionCriteriaChanged {
            try validate(run, tools: tools)
            return .userInterventionRequired("A criterion observed before the interrupted choice has changed or cannot be checked. Review it on the Mac before continuing; the original request remains pending.")
        } catch ComputerUseBrowserResearchTask.Failure.optionSelectionLimit {
            try validate(run, tools: tools)
            return .userInterventionRequired("The browser reached this task's option-selection limit. Earlier findings and the original request remain pending.")
        } catch is ComputerUseBrowserOptionSelectionError {
            try validate(run, tools: tools)
            return .userInterventionRequired("The selected option could not be prepared or verified. Review the page on the Mac before continuing; the original request remains pending.")
        } catch ComputerUseBrowserResearchTask.Failure.popupLimit {
            try validate(run, tools: tools)
            return .userInterventionRequired("The browser reached this task's dropdown-action limit. Earlier findings and the original request remain pending.")
        } catch is ComputerUseBrowserPopupError {
            try validate(run, tools: tools)
            return .userInterventionRequired("The dropdown could not be prepared or verified on this page. The original request remains pending; review the page before continuing.")
        } catch ComputerUseBrowserError.pageChanged, ComputerUseBrowserError.linkNavigationUnavailable {
            try validate(run, tools: tools)
            return .userInterventionRequired("The page changed before the next browser action. Check the page, then choose Resume to continue the original request.")
        } catch ComputerUseBrowserError.observedNavigationUnavailable, ComputerUseBrowserResearchHistoryNavigation.Failure.invalidIntent {
            try validate(run, tools: tools)
            return .userInterventionRequired("The selected earlier visit is no longer available in this browser session. The original request remains pending; review the page before continuing.")
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
        } catch ComputerUseBrowserActionPlanError.deadlineExceeded {
            try validate(run, tools: tools)
            return .userInterventionRequired("Choosing the next research step ran out of time. Earlier findings and the original task remain pending. Review the page, then choose Resume to continue.")
        } catch is ComputerUseBrowserActionPlanError, is ComputerUseBrowserResearchFormError {
            try validate(run, tools: tools)
            return .userInterventionRequired("The browser could not prepare the next form or reading action from the complete request. Earlier work and the original task remain pending.")
        } catch ComputerUseBrowserLinkPlanError.deadlineExceeded {
            try validate(run, tools: tools)
            return .userInterventionRequired("Choosing the next research link ran out of time. Earlier findings and the original task remain pending. Review the page, then choose Resume to continue.")
        } catch let error as ComputerUsePlanningWorker.Failure {
            try validate(run, tools: tools)
            return .userInterventionRequired(error.localizedDescription + " The original research request remains pending.")
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
        func admitWork() throws { try check(); try run.budget.admit() }
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
        func hasNavigationCapacity() throws -> Bool {
            try admitWork()
            try synchronizeHistory()
            return run.visits.count < navigationLimit
        }
        func stopAtNavigationLimit() async throws -> ComputerUseExecutionResult {
            try admitWork()
            // Report only a completed, still-current reading. Pending native
            // effects retain their original reconciliation obligations.
            if !owner.hasPendingForm, !owner.hasPendingNavigation,
               let report = try await owner.prepareProgressReport(pauseReason: .navigationLimit) {
                try check()
                return .browserResearchProgress(report)
            }
            try check()
            return navigationLimitRequired
        }
        try check()
        // The owner may have received a confirmed child result immediately
        // before Pause cancelled its outer return. Recover those native facts
        // before applying the task limit or selecting another action.
        try synchronizeHistory()
        // A navigation limit restricts another navigation, not observation or
        // verification of the final page already opened under this task.
        while true {
            try admitWork()
            if owner.hasPendingOptionSelection {
                progress("Checking the pending dropdown choice…")
                do { _ = try await owner.resumeOptionSelection() }
                catch { guard try await retireProvenUnsentOptionSelection(owner, after: error) else { throw error } }
                try check()
                continue
            }
            if owner.hasPendingPopup {
                progress("Checking the pending dropdown opening…")
                do { _ = try await owner.resumePopup() }
                catch { guard try await retireProvenUnsentPopup(owner, after: error) else { throw error } }
                try check()
                continue
            }
            if owner.initialSearchState == .pending {
                guard try hasNavigationCapacity() else { return try await stopAtNavigationLimit() }
                progress("Checking the pending search…")
                let document: ComputerUseBrowserDocument?
                do { document = try await owner.resumeInitialSearch() }
                catch ComputerUseBrowserError.pageChanged {
                    let refresh = try await owner.refreshInitialSearchStartingPage()
                    try check()
                    guard refresh == .updated || refresh == .unchanged else { return reconciliationRequired }
                    guard try hasNavigationCapacity() else { return try await stopAtNavigationLimit() }
                    document = try await owner.resumeInitialSearch()
                }
                guard let document, try record(.search, document) else { return reconciliationRequired }
                continue
            }
            if owner.hasPendingFormPreparation {
                let input: ComputerUseBrowserResearchFormInput
                let proposal: ComputerUseBrowserFormProposal
                do {
                    if owner.needsFormPreparationReview {
                        progress("Reviewing the pending form criteria…")
                        let interpretation = try await owner.interpretGoal()
                        try check()
                        if let question = try owner.proposedQuestionRequest() { return .browserClarificationRequired(question) }
                        guard interpretation.proposal.disposition == .research else {
                            return .userInterventionRequired("The complete request still has unresolved work. Review the original task before continuing.")
                        }
                        if run.sources?.policy.goalRevision != run.input.digest {
                            guard let sources = try planning.sources(for: interpretation) else {
                                return .userInterventionRequired("I need a search source that matches your request. The original task is still pending.")
                            }
                            try check(); try owner.configureResearchSources(sources); run.sources = sources
                        }
                        try admitWork()
                        let reviewed = try await owner.reviewFormPreparation(using: actionPlanner)
                        try check()
                        if let question = reviewed.questionRequest { return .browserClarificationRequired(question) }
                        guard case .editForm = reviewed.step else {
                            return .userInterventionRequired("I could not identify justified changes to this form. Your answer and the original task remain pending.")
                        }
                        progress("Checking the revised form preparation…")
                        try admitWork()
                        input = try await owner.applyFormPreparationReview(reviewed)
                    } else {
                        progress("Checking the pending form preparation…")
                        input = try await owner.resumeFormPreparation()
                    }
                    try admitWork()
                    proposal = try await owner.planForm(input, using: formPlanner)
                } catch {
                    guard try await recoverPendingForm(owner, after: error) else { throw error }
                    try check()
                    continue
                }
                try check()
                if let question = try proposal.questionRequest(for: input) { return .browserClarificationRequired(question) }
                guard !proposal.isUnavailable else {
                    return .userInterventionRequired("I could not justify the requested form criteria. The original request remains pending.")
                }
                try admitWork()
                do { _ = try await owner.executeForm(proposal, input: input) }
                catch { guard try await recoverPendingForm(owner, after: error) else { throw error } }
                try check()
                continue
            }
            if owner.hasPendingForm {
                progress("Checking the pending form entries…")
                do {
                    guard try await owner.resumeForm() != nil else { throw Failure.invalidContinuation }
                } catch {
                    guard try await recoverPendingForm(owner, after: error) else { throw error }
                }
                try check()
                continue // Choose the next capability using the retained verified stage.
            }
            if owner.hasPendingFormNavigation {
                guard try hasNavigationCapacity() else { return try await stopAtNavigationLimit() }
                progress("Checking the pending form search…")
                guard let receipt = try await owner.resumeFormNavigation(),
                      try record(.formQuery, receipt.document) else { return reconciliationRequired }
                continue
            }
            if owner.hasPendingNavigation {
                guard try hasNavigationCapacity() else { return try await stopAtNavigationLimit() }
                if owner.hasPendingHistoryNavigation {
                    progress("Checking the pending return to an earlier page…")
                    do {
                        let receipt = try await owner.resumeHistoryNavigation()
                        guard try record(.revisit, receipt.document) else { return reconciliationRequired }
                    } catch {
                        guard try await retireProvenUnsentHistory(owner, after: error) else { throw error }
                    }
                    continue
                }
                progress("Checking the pending result link…")
                let history = run.visits
                let result = try await owner.replanPendingCandidateNavigation(select: { [planning] goal, candidates in
                    try await planning.selectLink(goal: goal, candidates: candidates, history: history, evidence: owner.researchEvidence(for: goal))
                })
                try check()
                switch result {
                case .requiresReconciliation, .updated:
                    guard try hasNavigationCapacity() else { return try await stopAtNavigationLimit() }
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
                guard try hasNavigationCapacity() else { return try await stopAtNavigationLimit() }
                guard let sources = run.sources else { throw Failure.invalidContinuation }
                let query = try await owner.planInitialSearch(using: searchPlanner)
                try check()
                guard query.query != nil else {
                    return .userInterventionRequired("I could not form a search for the complete request. The original task is still pending.")
                }
                progress("Searching for the requested information…")
                guard try hasNavigationCapacity() else { return try await stopAtNavigationLimit() }
                let document = try await owner.openInitialSearch(query, provider: sources.provider)
                guard try record(.search, document) else { return reconciliationRequired }
            } else {
                progress("Choosing the next step for the complete request…")
                try admitWork()
                let action = try await owner.planNextAction(using: actionPlanner)
                try check()
                switch action.step {
                case .recall, .inspectOptions, .extendInspection, .preserveControls, .planFields, .reviewControls: throw Failure.invalidProposal // Resolved inside the owner, never an executable action.
                case .selectOption:
                    progress("Selecting the requested option…")
                    try admitWork()
                    do { _ = try await owner.selectOption(for: action) }
                    catch { guard try await retireProvenUnsentOptionSelection(owner, after: error) else { throw error } }
                    try check()
                    continue // Selection needs fresh application/result evidence.
                case .openPopup:
                    progress("Opening the requested dropdown…")
                    try admitWork()
                    do { _ = try await owner.openPopup(for: action) }
                    catch { guard try await retireProvenUnsentPopup(owner, after: error) else { throw error } }
                    try check()
                    continue // A fresh reading must inspect options; opening is no result fact.
                case .revisit:
                    guard try hasNavigationCapacity() else { return try await stopAtNavigationLimit() }
                    progress("Returning to an earlier page…")
                    do {
                        let receipt = try await owner.revisit(for: action)
                        guard try record(.revisit, receipt.document) else { return reconciliationRequired }
                    } catch {
                        guard try await retireProvenUnsentHistory(owner, after: error) else { throw error }
                    }
                    continue
                case .editForm:
                    guard owner.confirmedFormHistory.count < 32 else {
                        return .userInterventionRequired("The browser reached this task's form-action limit. The original request remains pending.")
                    }
                    let input: ComputerUseBrowserResearchFormInput
                    let proposal: ComputerUseBrowserFormProposal
                    do {
                        try admitWork()
                        input = try await owner.prepareFormInput(for: action)
                        progress("Preparing the requested form criteria…")
                        try admitWork()
                        proposal = try await owner.planForm(input, using: formPlanner)
                    } catch {
                        guard try await recoverPendingForm(owner, after: error) else { throw error }
                        try check()
                        continue
                    }
                    try check()
                    if let question = try proposal.questionRequest(for: input) { return .browserClarificationRequired(question) }
                    guard !proposal.isUnavailable else {
                        return .userInterventionRequired("I could not justify the requested form criteria. The original request remains pending.")
                    }
                    try admitWork()
                    do { _ = try await owner.executeForm(proposal, input: input) }
                    catch {
                        guard try await recoverPendingForm(owner, after: error) else { throw error }
                    }
                    try check()
                    continue
                case .openQuery:
                    guard try hasNavigationCapacity() else { return try await stopAtNavigationLimit() }
                    progress("Opening the verified form search…")
                    let receipt = try await owner.openFormQuery(for: action)
                    guard try record(.formQuery, receipt.document) else { return reconciliationRequired }
                    continue
                case .question:
                    guard let question = action.questionRequest else { throw Failure.invalidProposal }
                    return .browserClarificationRequired(question)
                case .loginHandoff:
                    return .userInterventionRequired(try await owner.requestLoginHandoff(for: action))
                case .unavailable:
                    return .userInterventionRequired("I could not choose a supported next step for the complete request on this page. The original task remains pending.")
                case .readResults: break
                }
                progress("Reading the page against the original request…")
                let history = run.visits
                try admitWork()
                let decision = try await owner.planResearchDecision(for: action, select: { [planning] goal, candidates in
                    try await planning.selectDecision(goal: goal, candidates: candidates, history: history, evidence: owner.researchEvidence(for: goal))
                })
                try check()
                switch decision {
                case .revisit(let option):
                    guard try hasNavigationCapacity() else { return try await stopAtNavigationLimit() }
                    do {
                        let receipt = try await owner.revisitAfterReading(option)
                        guard try record(.revisit, receipt.document) else { return reconciliationRequired }
                    } catch {
                        guard try await retireProvenUnsentHistory(owner, after: error) else { throw error }
                    }
                    continue
                case .answer(let selection):
                    try admitWork()
                    let answer = try await owner.prepareAnswer(selection)
                    try check()
                    return .browserResearchAnswer(answer)
                case .unresolved:
                    try admitWork()
                    if let report = try await owner.prepareProgressReport(pauseReason: run.visits.count >= navigationLimit ? .navigationLimit : nil) {
                        try check()
                        return .browserResearchProgress(report)
                    }
                    try check()
                    return run.visits.count >= navigationLimit ? navigationLimitRequired : selectionRequired
                case .link(let choice):
                    guard try hasNavigationCapacity() else { return try await stopAtNavigationLimit() }
                    let receipt = try await owner.openCandidateLink(candidateID: choice.candidateID, linkID: choice.linkID)
                    guard try record(.resultLink, receipt.document) else { return reconciliationRequired }
                }
            }
        }
    }

    private var navigationLimitRequired: ComputerUseExecutionResult {
        .userInterventionRequired("The browser reached this task's navigation limit. The research answer is still unverified and earlier actions keep their reconciliation requirements. You can continue manually, then choose Resume to review the current page; Resume does not allow additional navigation for this task.")
    }
    private var activeWorkLimitRequired: ComputerUseExecutionResult {
        .userInterventionRequired(ComputerUseBrowserWorkBudget.Failure.exhausted.localizedDescription)
    }
    private var selectionRequired: ComputerUseExecutionResult {
        .userInterventionRequired("I could not select another result link that advances the complete request. More page interaction or result verification is needed; the original task is still pending.")
    }
    private func retireProvenUnsentOptionSelection(_ owner: ComputerUseBrowserResearchTask, after error: Error) async throws -> Bool {
        guard owner.hasPendingOptionSelection,
              error as? ComputerUseBrowserOptionSelectionError == .unavailable || error as? ComputerUseBrowserOptionSelectionError == .uncertain
                || error as? ComputerUseBrowserOptionSelectionError == .retirementPending || error as? ComputerUseBrowserOptionSelectionError == .retired
                || error as? ComputerUseTaskExecutionError == .preconditionFailed("prepared")
                || error as? ComputerUseBrowserError == .pageChanged else { return false }
        return try await owner.retirePendingUnsentOptionSelection() != nil
    }

    private func retireProvenUnsentPopup(_ owner: ComputerUseBrowserResearchTask, after error: Error) async throws -> Bool {
        guard owner.hasPendingPopup,
              error as? ComputerUseBrowserPopupError == .unavailable || error as? ComputerUseBrowserPopupError == .uncertain
                || error as? ComputerUseBrowserPopupError == .retirementPending || error as? ComputerUseBrowserPopupError == .retired
                || error as? ComputerUseBrowserError == .pageChanged
                || error as? ComputerUseTaskExecutionError == .preconditionFailed("prepared") else { return false }
        return try await owner.retirePendingUnsentPopup() != nil
    }
    private func retireProvenUnsentHistory(_ owner: ComputerUseBrowserResearchTask, after error: Error) async throws -> Bool {
        guard error as? ComputerUseBrowserError == .pageChanged
                || error as? ComputerUseBrowserError == .observedNavigationUnavailable
                || error as? ComputerUseBrowserError == .sourceNotAllowed
                || error as? ComputerUseBrowserResearchHistoryNavigation.Failure == .retirementPending else { return false }
        return try await owner.retirePendingUnsentHistoryNavigation() != nil
    }
    private func recoverPendingForm(_ owner: ComputerUseBrowserResearchTask, after error: Error) async throws -> Bool {
        guard error as? ComputerUseBrowserError == .pageChanged
                || error as? ComputerUseBrowserResearchFormError == .inputChanged
                || error as? ComputerUseTextTaskError == .staleTarget
                || error as? ComputerUseTextTaskError == .uncertainEffect
                || error as? ComputerUseTextTaskError == .incompleteOutcome
                || error as? ComputerUseTextEditError == .deliveryUncertain
                || error as? ComputerUseBrowserResearchFormStage.Failure == .retirementPending
                || error as? ComputerUseBrowserResearchFormStage.Failure == .valueCheckpointRequired else { return false }
        if owner.hasPendingFormPreparation { return try await owner.recoverPendingFormPreparationCriteria() }
        if try await owner.recoverPendingRetainedCriteria() != nil { return true }
        if try await owner.retainCompletedFormHistory() != nil { return true }
        if try await owner.retainPendingFormPrefix() != nil { return true }
        return try await owner.retirePendingUnsentForm() != nil
    }
    private var reconciliationRequired: ComputerUseExecutionResult {
        .userInterventionRequired("An earlier browser action needs to be checked before continuing. The original request remains pending.")
    }
}

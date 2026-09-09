import Foundation

/// A complete requirement ledger for one native-bound candidate reading.
/// Arithmetic/date matches are useful evidence, not proof of offer association
/// or whole-goal fulfillment. No completion flag or answer text is produced.
struct ComputerUseBrowserResultAssessment: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    typealias Scalars = ComputerUseBrowserScalarRequirements
    /// Reconcile recorded control episodes only. Even a complete pair does
    /// not prove authentication, callback coverage or authority to act now.
    struct ControlHistory: Equatable, Sendable {
        typealias History = ComputerUseBrowserNavigationDispatchHistory
        typealias Event = History.ControlEvent
        enum Gap: String, CaseIterable, Hashable, Sendable {
            case claimBoundary, discardedClaimHistory, controlOverflow, observationOverflow
            case malformedEvent, outOfOrderEvents, bindingMismatch, reusedOperation, overlappingWorkflowResumes
            case unmatchedNativeHandback, nativeHandbackWithoutWorkflow, unmatchedWorkflowResume
            case resumeWithoutPause, resumeAfterAnotherPause, resumeWithoutNativeHandback, unclosedPause
            case unmatchedSignInWindow, overlappingSignInWindows, signInWindowWithoutRecordedPause
            case openSignInWindow, signInObservationOutsideLifetime, resumeWithSignInWindow
        }
        private struct Context: Hashable {
            let session: UUID
            let epoch: UUID
            init(_ event: Event) { session = event.parentSessionID; epoch = event.ownershipEpoch }
        }
        let completedNativeHandbackCount: Int
        let failedNativeHandbackCount: Int
        let completedWorkflowResumeCount: Int
        let failedWorkflowResumeCount: Int
        let admittedContextCount: Int
        let closedSignInWindowCount: Int
        let openSignInWindowCount: Int
        let unclosedPauseScopeCount: Int
        let gaps: [Gap]

        init(history: History) {
            var found: Set<Gap> = []
            if history.hasClaimBoundary { found.insert(.claimBoundary) }
            if history.beganAfterAnotherClaim { found.insert(.discardedClaimHistory) }
            if history.controlEventsOverflowed { found.insert(.controlOverflow) }
            if history.observationsOverflowed { found.insert(.observationOverflow) }
            var native: [UUID: Event] = [:], workflows: [UUID: Event] = [:], pauses: [Context: Event] = [:]
            var nativeTerminalsByWorkflow: [UUID: (start: Event, terminal: Event)] = [:], nativeCountsByWorkflow: [UUID: Int] = [:]
            var invalidWorkflows: Set<UUID> = []
            var seenNative: Set<UUID> = [], seenWorkflows: Set<UUID> = []
            var windows: [UUID: (open: Event, close: Event?)] = [:]
            var nativeSuccesses = 0, nativeFailures = 0, workflowSuccesses = 0, workflowFailures = 0, admissions = 0, closedWindows = 0
            var lastOrder: Int?
            func sameBinding(_ first: Event, _ second: Event) -> Bool {
                Context(first) == Context(second) && first.handback == second.handback
            }
            for event in history.controlEvents {
                if let lastOrder, event.order <= lastOrder { found.insert(.outOfOrderEvents) }
                lastOrder = event.order
                let context = Context(event)
                if [.signInWindowOpened, .signInWindowClosed].contains(event.phase) {
                    guard let id = event.signInWindowID, event.handback == nil,
                          event.workflowOperationID == nil, event.nativeOperationID == nil else {
                        found.insert(.malformedEvent); continue
                    }
                    if event.phase == .signInWindowOpened {
                        guard windows[id] == nil else { found.insert(.unmatchedSignInWindow); continue }
                        if pauses[context] == nil { found.insert(.signInWindowWithoutRecordedPause) }
                        if windows.values.contains(where: { Context($0.open) == context && $0.close == nil }) { found.insert(.overlappingSignInWindows) }
                        windows[id] = (event, nil)
                    } else {
                        guard let window = windows[id], window.close == nil, window.open.order < event.order,
                              Context(window.open) == context else { found.insert(.unmatchedSignInWindow); continue }
                        windows[id] = (window.open, event); closedWindows += 1
                    }
                    continue
                }
                guard let requirement = event.handback, requirement.taskID == history.taskID else {
                    found.insert(.malformedEvent); continue
                }
                switch event.phase {
                case .workflowPaused:
                    guard event.workflowOperationID == nil, event.nativeOperationID == nil else { found.insert(.malformedEvent); continue }
                    // A second Pause invalidates a suspended Resume, even
                    // though both records bind the same native session.
                    pauses[context] = event
                case .workflowResumeStarted, .workflowContextAdmitted:
                    guard let id = event.workflowOperationID, event.nativeOperationID == nil else { found.insert(.malformedEvent); continue }
                    guard seenWorkflows.insert(id).inserted else { found.insert(.reusedOperation); invalidWorkflows.insert(id); continue }
                    let overlapping = workflows.filter { Context($0.value) == context }.map(\.key)
                    if !overlapping.isEmpty {
                        found.insert(.overlappingWorkflowResumes); invalidWorkflows.formUnion(overlapping); invalidWorkflows.insert(id)
                    }
                    if event.phase == .workflowResumeStarted {
                        if let pause = pauses[context] {
                            if !sameBinding(pause, event) { found.insert(.bindingMismatch); invalidWorkflows.insert(id) }
                        } else { found.insert(.resumeWithoutPause); invalidWorkflows.insert(id) }
                    } else {
                        // This root had no owned context in which to record
                        // its earlier Pause. Native admission starts its pair.
                        pauses[context] = event; admissions += 1
                    }
                    workflows[id] = event
                case .nativeReacquisitionStarted:
                    guard let id = event.nativeOperationID else { found.insert(.malformedEvent); continue }
                    guard seenNative.insert(id).inserted else { found.insert(.reusedOperation); continue }
                    native[id] = event
                    if let ownerID = event.workflowOperationID {
                        nativeCountsByWorkflow[ownerID, default: 0] += 1
                        if let owner = workflows[ownerID], owner.phase == .workflowResumeStarted {
                            if !sameBinding(owner, event) { found.insert(.bindingMismatch); invalidWorkflows.insert(ownerID) }
                        } else { found.insert(.nativeHandbackWithoutWorkflow); invalidWorkflows.insert(ownerID) }
                    } else { found.insert(.nativeHandbackWithoutWorkflow) }
                case .nativeReacquisitionFinished, .nativeReacquisitionFailed:
                    guard let id = event.nativeOperationID, let start = native[id], start.order < event.order else {
                        found.insert(.unmatchedNativeHandback); continue
                    }
                    guard sameBinding(start, event), start.workflowOperationID == event.workflowOperationID else {
                        found.insert(.bindingMismatch); continue
                    }
                    native.removeValue(forKey: id)
                    if event.phase == .nativeReacquisitionFinished { nativeSuccesses += 1 } else { nativeFailures += 1 }
                    if let ownerID = event.workflowOperationID { nativeTerminalsByWorkflow[ownerID] = (start, event) }
                case .workflowResumed, .workflowResumeFailed:
                    guard let id = event.workflowOperationID, event.nativeOperationID == nil,
                          let start = workflows[id], start.order < event.order else { found.insert(.unmatchedWorkflowResume); continue }
                    guard sameBinding(start, event) else { found.insert(.bindingMismatch); continue }
                    workflows.removeValue(forKey: id)
                    if event.phase == .workflowResumeFailed {
                        workflowFailures += 1
                        // Failure is a paired historical outcome, not a
                        // successful handback. A later Resume may close Pause.
                        continue
                    }
                    var accepted = !invalidWorkflows.contains(id)
                    if let pause = pauses[context] {
                        if pause.order > start.order { found.insert(.resumeAfterAnotherPause); accepted = false }
                        if !sameBinding(pause, event) { found.insert(.bindingMismatch); accepted = false }
                    } else { found.insert(.resumeWithoutPause); accepted = false }
                    if start.phase == .workflowResumeStarted {
                        if let pair = nativeTerminalsByWorkflow[id], pair.terminal.phase == .nativeReacquisitionFinished,
                           nativeCountsByWorkflow[id] == 1, start.order < pair.start.order, pair.terminal.order < event.order,
                           sameBinding(pair.terminal, event),
                           !native.values.contains(where: { $0.workflowOperationID == id }) {
                            // Native return and owner acceptance remain two
                            // separately counted, correctly ordered outcomes.
                        } else { found.insert(.resumeWithoutNativeHandback); accepted = false }
                    }
                    if event.signInWindowID != nil || windows.values.contains(where: { Context($0.open) == context && $0.close == nil }) {
                        found.insert(.resumeWithSignInWindow); accepted = false
                    }
                    if accepted { workflowSuccesses += 1; pauses.removeValue(forKey: context) }
                case .signInWindowOpened, .signInWindowClosed: break
                }
            }
            for observation in history.observations where observation.surface == .signInWindow {
                guard let id = observation.signInWindowID, let window = windows[id], window.open.order < observation.order,
                      window.close.map({ observation.order < $0.order }) ?? true,
                      observation.parentSessionID == window.open.parentSessionID,
                      observation.ownershipEpoch == window.open.ownershipEpoch else {
                    found.insert(.signInObservationOutsideLifetime); continue
                }
            }
            if !native.isEmpty { found.insert(.unmatchedNativeHandback) }
            if !workflows.isEmpty { found.insert(.unmatchedWorkflowResume) }
            if !pauses.isEmpty { found.insert(.unclosedPause) }
            let openWindows = windows.values.filter { $0.close == nil }.count
            if openWindows > 0 { found.insert(.openSignInWindow) }
            completedNativeHandbackCount = nativeSuccesses; failedNativeHandbackCount = nativeFailures
            completedWorkflowResumeCount = workflowSuccesses; failedWorkflowResumeCount = workflowFailures
            admittedContextCount = admissions; closedSignInWindowCount = closedWindows; openSignInWindowCount = openWindows
            unclosedPauseScopeCount = pauses.count; gaps = Gap.allCases.filter(found.contains)
        }

        var plannerContext: [String: Any] {
            ["completed_native_handback_count":completedNativeHandbackCount, "failed_native_handback_count":failedNativeHandbackCount,
             "completed_workflow_resume_count":completedWorkflowResumeCount, "failed_workflow_resume_count":failedWorkflowResumeCount,
             "admitted_context_count":admittedContextCount, "closed_sign_in_window_count":closedSignInWindowCount,
             "open_sign_in_window_count":openSignInWindowCount, "unclosed_pause_scope_count":unclosedPauseScopeCount,
             "gaps":gaps.map(\.rawValue)]
        }
    }
    /// A retained candidate is historical evidence, not necessarily the
    /// current page. Adoption and a native handback are distinct transitions.
    struct PageObservationHistory: Equatable, Sendable {
        typealias History = ComputerUseBrowserNavigationDispatchHistory
        typealias Event = History.PageObservationEvent
        enum Gap: String, CaseIterable, Hashable, Sendable {
            case overflow, malformedEvent, outOfOrderEvents, duplicateAcceptance, duplicateAdoption
            case claimTransferUnreconciled, acceptanceBindingMismatch, unmatchedAdoption, adoptionBindingMismatch
            case requiredHandbackMissing, unmatchedNativeHandback, sameDocumentSourceUnqualified
            case unmatchedRetirement, retirementBindingMismatch, duplicateDisposition
        }
        let acceptedCount: Int
        let adoptedCount: Int
        let retiredCount: Int
        let matchedAdoptionCount: Int
        let matchedRetirementCount: Int
        let nativeHandbackLinkedAdoptionCount: Int
        let sameDocumentCandidateCount: Int
        let gaps: [Gap]

        init(history: History) {
            var found: Set<Gap> = []
            if history.pageObservationEventsOverflowed { found.insert(.overflow) }
            var accepted: [UUID: Event] = [:], adopted: Set<UUID> = [], matched = 0, linked = 0
            var retired: Set<UUID> = [], matchedRetirements = 0
            var lastOrder: Int?
            for event in history.pageObservationEvents {
                if let lastOrder, event.order <= lastOrder { found.insert(.outOfOrderEvents) }
                lastOrder = event.order
                let page = event.observation
                guard [.activePageObservation, .userControlObservation].contains(page.source), page.origin != nil,
                      (page.basis == .completedNavigation) == (page.navigationCorrelationID != nil) else {
                    found.insert(.malformedEvent); continue
                }
                if page.basis == .sameDocumentCandidate { found.insert(.sameDocumentSourceUnqualified) }
                let sameClaim = page.taskID == history.taskID && event.parentSessionID == page.parentSessionID
                    && event.ownershipEpoch == page.ownershipEpoch
                if !sameClaim { found.insert(.claimTransferUnreconciled) }
                if event.phase == .accepted {
                    guard sameClaim, event.generation == page.generation, event.adoptedSource == nil,
                          event.nativeReacquisitionID == nil, event.retirement == nil else {
                        found.insert(.acceptanceBindingMismatch); continue
                    }
                    if accepted.updateValue(event, forKey: page.id) != nil { found.insert(.duplicateAcceptance) }
                    continue
                }
                if event.phase == .retired {
                    guard !adopted.contains(page.id), retired.insert(page.id).inserted else { found.insert(.duplicateDisposition); continue }
                    guard let original = accepted[page.id], original.observation == page, original.order < event.order else {
                        found.insert(.unmatchedRetirement); continue
                    }
                    // A replacement load may already have changed generation.
                    // Retirement is about the old candidate, never the new page.
                    guard sameClaim, event.retirement != nil, event.adoptedSource == nil, event.nativeReacquisitionID == nil else {
                        found.insert(.retirementBindingMismatch); continue
                    }
                    matchedRetirements += 1
                    continue
                }
                guard !retired.contains(page.id) else { found.insert(.duplicateDisposition); continue }
                guard adopted.insert(page.id).inserted else { found.insert(.duplicateAdoption); continue }
                guard let original = accepted[page.id], original.observation == page, original.order < event.order else {
                    found.insert(.unmatchedAdoption); continue
                }
                guard sameClaim, event.generation == page.generation, event.adoptedSource == page.source,
                      event.retirement == nil else { found.insert(.adoptionBindingMismatch); continue }
                if let nativeID = event.nativeReacquisitionID {
                    let native = history.controlEvents.filter { $0.nativeOperationID == nativeID }
                    let starts = native.filter { $0.phase == .nativeReacquisitionStarted }
                    let terminals = native.filter { [.nativeReacquisitionFinished, .nativeReacquisitionFailed].contains($0.phase) }
                    guard starts.count == 1, terminals.count == 1, let start = starts.first, let terminal = terminals.first,
                          start.order < event.order, event.order < terminal.order,
                          start.parentSessionID == page.parentSessionID, terminal.parentSessionID == page.parentSessionID,
                          start.ownershipEpoch == page.ownershipEpoch, terminal.ownershipEpoch == page.ownershipEpoch,
                          let requirement = start.handback, start.handback == terminal.handback,
                          requirement.taskID == history.taskID,
                          start.workflowOperationID == terminal.workflowOperationID else {
                        found.insert(.unmatchedNativeHandback); continue
                    }
                    // A paired native failure still contains a real adoption.
                    // This count never means authentication or owner Resume.
                    linked += 1
                } else if page.requiresExplicitHandback || page.source == .userControlObservation {
                    found.insert(.requiredHandbackMissing); continue
                }
                matched += 1
            }
            acceptedCount = history.pageObservationEvents.filter { $0.phase == .accepted }.count
            adoptedCount = history.pageObservationEvents.filter { $0.phase == .adopted }.count
            retiredCount = history.pageObservationEvents.filter { $0.phase == .retired }.count
            matchedRetirementCount = matchedRetirements
            matchedAdoptionCount = matched; nativeHandbackLinkedAdoptionCount = linked
            sameDocumentCandidateCount = history.pageObservationEvents.filter {
                $0.phase == .accepted && $0.observation.basis == .sameDocumentCandidate
            }.count
            gaps = Gap.allCases.filter(found.contains)
        }

        var plannerContext: [String: Any] {
            ["accepted_count":acceptedCount, "adopted_count":adoptedCount, "retired_count":retiredCount,
             "matched_adoption_count":matchedAdoptionCount, "matched_retirement_count":matchedRetirementCount,
             "native_handback_linked_adoption_count":nativeHandbackLinkedAdoptionCount,
             "same_document_candidate_count":sameDocumentCandidateCount, "gaps":gaps.map(\.rawValue)]
        }
    }

    /// Exact callback-object episodes, separate from slot-only policy events
    /// and from the native branch that actually admitted a document receipt.
    struct NavigationEpisodes: Equatable, Sendable {
        typealias History = ComputerUseBrowserNavigationDispatchHistory
        typealias Observation = History.Observation
        enum Gap: String, CaseIterable, Hashable, Sendable {
            case attemptOverflow, observationOverflow, pageObservationOverflow, callbackIdentityMissing, callbackBindingMismatch
            case duplicateCallbackPhase, callbackOrderMismatch, missingProvisionalStart, missingDocumentCommitCallback
            case unfinishedEpisode, observedAdmissionUnverified, unscopedWebContentTermination
            case commitBasisMissing, commitOriginMissing, unmatchedCommittedAttempt, historySourceMissing, instantBackApprovalMissing
            case responseAssociationUnqualified, responseOriginMissing, responseOriginMismatch, redirectDestinationsUnqualified
            case observedEndMissing, observedEndMismatch
        }
        let dispatchEpisodeCount: Int
        let observedEpisodeCount: Int
        let endedObservedEpisodeCount: Int
        let rejectedObservedEpisodeCount: Int
        let observedFinishCallbackCount: Int
        let matchedObservedAdmissionCount: Int
        let matchedCommittedAttemptCount: Int
        let historyRestorationCommitCount: Int
        let redirectCallbackCount: Int
        let gaps: [Gap]

        init(history: History) {
            var found: Set<Gap> = []
            if history.overflowed { found.insert(.attemptOverflow) }
            if history.observationsOverflowed { found.insert(.observationOverflow) }
            if history.pageObservationEventsOverflowed { found.insert(.pageObservationOverflow) }
            let acceptedNavigationPages = history.pageObservationEvents.filter {
                $0.phase == .accepted && $0.observation.basis == .completedNavigation
            }
            var matchedAdmissions: Set<Int> = []
            let main = history.observations.filter { $0.surface == .mainDocument }
            let callbackPhases: [History.Phase] = [.provisionalStart, .serverRedirect, .documentCommitStarted, .documentFinished, .navigationFailure]
            var groups: [UUID: [Observation]] = [:]
            for observation in main {
                if observation.phase == .webContentTerminated { found.insert(.unscopedWebContentTermination) }
                guard callbackPhases.contains(observation.phase) || observation.phase == .observedNavigationEnded else { continue }
                guard [.exactPendingNavigation, .exactObservedNavigation].contains(observation.binding),
                      let id = observation.navigationCorrelationID else { found.insert(.callbackIdentityMissing); continue }
                groups[id, default: []].append(observation)
            }
            var dispatches = 0, observed = 0, validFinishes: [UUID: [Observation]] = [:]
            var endedObserved = 0, rejectedObserved = 0
            for records in groups.values {
                guard let first = records.first, records.allSatisfy({
                    $0.binding == first.binding && $0.attemptID == first.attemptID
                        && $0.parentSessionID == first.parentSessionID && $0.ownershipEpoch == first.ownershipEpoch
                        && $0.generation == first.generation
                }) else { found.insert(.callbackBindingMismatch); continue }
                let attempt: History.Attempt?
                if first.binding == .exactPendingNavigation {
                    guard let id = first.attemptID, let match = history.attempts.first(where: { $0.id == id }),
                          match.sessionID == first.parentSessionID, match.ownershipEpoch == first.ownershipEpoch,
                          match.generation == first.generation,
                          records.allSatisfy({ record in
                              match.order < record.order && (match.terminalOrder.map { record.order < $0 } ?? true)
                          }) else {
                        found.insert(.callbackBindingMismatch); continue
                    }
                    attempt = match; dispatches += 1
                } else {
                    guard first.attemptID == nil else { found.insert(.callbackBindingMismatch); continue }
                    attempt = nil; observed += 1
                }
                let callbacks = records.filter { $0.phase != .observedNavigationEnded }
                let endings = records.filter { $0.phase == .observedNavigationEnded }
                let starts = callbacks.filter { $0.phase == .provisionalStart }
                let commits = records.filter { $0.phase == .documentCommitStarted }
                let terminals = records.filter { [.documentFinished, .navigationFailure].contains($0.phase) }
                var valid = true
                var observedEnd: Observation?
                if first.binding == .exactObservedNavigation {
                    if endings.isEmpty {
                        if !terminals.isEmpty { found.insert(.observedEndMissing) }
                    } else if endings.count == 1, let end = endings.first, let reason = end.observedEnd,
                              callbacks.allSatisfy({ $0.order < end.order }),
                              (reason != .finished && reason != .finishRejected || terminals.first?.phase == .documentFinished),
                              (reason != .callbackFailed || terminals.first?.phase == .navigationFailure) {
                        observedEnd = end
                    } else { found.insert(.observedEndMismatch); valid = false }
                } else if !endings.isEmpty { found.insert(.observedEndMismatch); valid = false }
                if starts.count > 1 || commits.count > 1 || terminals.count > 1 { found.insert(.duplicateCallbackPhase); valid = false }
                if zip(records, records.dropFirst()).contains(where: { pair in pair.0.order >= pair.1.order }) { found.insert(.callbackOrderMismatch); valid = false }
                let cached = attempt?.commitBasis == .historyItemAndFinish || attempt?.commitBasis == .instantBackHistoryItem
                let nativeFailure = (attempt.map { $0.outcome != .pending && $0.outcome != .documentCommitted && $0.terminalOrder != nil } ?? false)
                    || (observedEnd.map { $0.observedEnd != .finished } ?? false)
                if starts.isEmpty && !cached && !nativeFailure { found.insert(.missingProvisionalStart); valid = false }
                if let start = starts.first, records.contains(where: { $0.phase != .provisionalStart && $0.order < start.order }) {
                    found.insert(.callbackOrderMismatch); valid = false
                }
                if let terminal = terminals.first {
                    if callbacks.contains(where: { $0.order > terminal.order }) { found.insert(.callbackOrderMismatch); valid = false }
                    if terminal.phase == .documentFinished && commits.isEmpty && !cached { found.insert(.missingDocumentCommitCallback); valid = false }
                } else if !nativeFailure && attempt?.commitBasis != .instantBackHistoryItem { found.insert(.unfinishedEpisode); valid = false }
                if let commit = commits.first, records.contains(where: { $0.phase == .serverRedirect && $0.order > commit.order }) {
                    found.insert(.callbackOrderMismatch); valid = false
                }
                if valid, let attempt, let finished = terminals.first, finished.phase == .documentFinished {
                    validFinishes[attempt.id, default: []].append(finished)
                }
                if valid, let observedEnd, let reason = observedEnd.observedEnd {
                    endedObserved += 1
                    if [.responseRejected, .sourceBlocked, .callbackFailed, .finishRejected].contains(reason) { rejectedObserved += 1 }
                    if [.responseRejected, .sourceBlocked].contains(reason) { found.insert(.responseAssociationUnqualified) }
                }
                if attempt == nil, let finished = terminals.first, finished.phase == .documentFinished {
                    let admissions = acceptedNavigationPages.filter {
                        let page = $0.observation
                        return page.navigationCorrelationID == first.navigationCorrelationID
                            && page.taskID == history.taskID && page.parentSessionID == first.parentSessionID
                            && page.ownershipEpoch == first.ownershipEpoch && page.generation == first.generation
                            && $0.parentSessionID == page.parentSessionID && $0.ownershipEpoch == page.ownershipEpoch
                            && $0.generation == page.generation && $0.order > finished.order && page.origin != nil && page.origin == finished.origin
                    }
                    if valid, let observedEnd, observedEnd.observedEnd == .finished,
                       admissions.count == 1, let admission = admissions.first, observedEnd.order < admission.order {
                        matchedAdmissions.insert(admission.order); found.insert(.responseAssociationUnqualified)
                    }
                    else if observedEnd?.observedEnd != .finishRejected || !admissions.isEmpty { found.insert(.observedAdmissionUnverified) }
                }
            }
            if acceptedNavigationPages.contains(where: { !matchedAdmissions.contains($0.order) }) { found.insert(.observedAdmissionUnverified) }
            var matched: Set<UUID> = []
            for attempt in history.attempts where attempt.outcome == .documentCommitted {
                guard let basis = attempt.commitBasis, let terminalOrder = attempt.terminalOrder else {
                    found.insert(.commitBasisMissing); continue
                }
                guard attempt.committedOrigin != nil else { found.insert(.commitOriginMissing); found.insert(.unmatchedCommittedAttempt); continue }
                var supported = true
                if basis == .responseAndFinish {
                    found.insert(.responseAssociationUnqualified)
                    if let response = attempt.successfulResponseOrigin {
                        if response != attempt.committedOrigin { found.insert(.responseOriginMismatch); supported = false }
                    } else { found.insert(.responseOriginMissing); supported = false }
                } else {
                    let sources = history.attempts.filter {
                        $0.operationID == attempt.historySourceOperationID && $0.sessionID == attempt.sessionID
                            && $0.ownershipEpoch == attempt.ownershipEpoch && $0.outcome == .documentCommitted
                            && ($0.terminalOrder.map { $0 < attempt.order } ?? false)
                            && $0.committedOrigin == attempt.requestedOrigin && $0.committedOrigin == attempt.committedOrigin
                    }
                    if attempt.historySourceOperationID == nil || sources.count != 1 { found.insert(.historySourceMissing); supported = false }
                }
                if basis == .instantBackHistoryItem {
                    let approvals = main.filter {
                        $0.phase == .historyRequest && $0.binding == .exactHistoryItem && $0.instantBack == true
                            && $0.decision == .allowed && $0.attemptID == attempt.id && $0.parentSessionID == attempt.sessionID
                            && $0.ownershipEpoch == attempt.ownershipEpoch && $0.generation == attempt.generation
                            && $0.order > attempt.order && $0.order < terminalOrder && $0.origin == attempt.committedOrigin
                    }
                    if approvals.count != 1 { found.insert(.instantBackApprovalMissing); supported = false }
                } else {
                    let finishes = validFinishes[attempt.id] ?? []
                    if finishes.count != 1 || finishes.first?.origin != attempt.committedOrigin { supported = false }
                }
                if supported { matched.insert(attempt.id) } else { found.insert(.unmatchedCommittedAttempt) }
            }
            dispatchEpisodeCount = dispatches; observedEpisodeCount = observed
            endedObservedEpisodeCount = endedObserved; rejectedObservedEpisodeCount = rejectedObserved
            observedFinishCallbackCount = main.filter { $0.binding == .exactObservedNavigation && $0.phase == .documentFinished }.count
            matchedObservedAdmissionCount = matchedAdmissions.count
            matchedCommittedAttemptCount = matched.count
            historyRestorationCommitCount = history.attempts.filter {
                $0.outcome == .documentCommitted && ($0.commitBasis == .historyItemAndFinish || $0.commitBasis == .instantBackHistoryItem)
            }.count
            redirectCallbackCount = main.filter { $0.phase == .serverRedirect }.count
            if redirectCallbackCount > 0 { found.insert(.redirectDestinationsUnqualified) }
            gaps = Gap.allCases.filter(found.contains)
        }

        var plannerContext: [String: Any] {
            ["dispatch_episode_count":dispatchEpisodeCount, "observed_episode_count":observedEpisodeCount,
             "ended_observed_episode_count":endedObservedEpisodeCount, "rejected_observed_episode_count":rejectedObservedEpisodeCount,
             "observed_finish_callback_count":observedFinishCallbackCount, "matched_observed_admission_count":matchedObservedAdmissionCount,
             "matched_committed_attempt_count":matchedCommittedAttemptCount,
             "history_restoration_commit_count":historyRestorationCommitCount, "redirect_callback_count":redirectCallbackCount,
             "gaps":gaps.map(\.rawValue)]
        }
    }

    /// Diagnostic facts about a frozen native history. There is deliberately
    /// no success value: episode reconciliation and coverage remain open.
    struct NavigationHistory: Equatable, Sendable {
        enum Gap: String, CaseIterable, Hashable, Sendable {
            case historyUnavailable, foreignContext, unresolvedSourceRequirements
            case discardedClaimHistory, claimBoundary
            case attemptOverflow, observationOverflow, controlOverflow, policyInstallationOverflow
            case unconfiguredDispatch, mismatchedPolicy, earlierGoalPolicy, foreignGoalPolicy
            case pendingDispatch, unsuccessfulDispatch, unknownDispatchOrigin
            case weakObservationBinding, unattributedObservation, unorderedObservation
            case ownerHistoryUnavailable, ownerVisitBindingMismatch, duplicateOwnerVisit, ownerVisitOrderMismatch
            case unclaimedCommittedDispatch
            case controlEpisodesUnreconciled, ownerVisitsUnreconciled, navigationEpisodesUnreconciled, pageObservationsUnreconciled, platformCoverageUnqualified
        }
        let attemptCount: Int
        let observationCount: Int
        let controlEventCount: Int
        let policyInstallationCount: Int
        let ownerVisitCount: Int?
        let matchedOwnerVisitCount: Int
        let controlHistory: ControlHistory?
        let navigationEpisodes: NavigationEpisodes?
        let pageObservationHistory: PageObservationHistory?
        /// Callback count, not distinct requests and not proof of a violation:
        /// the native policy may have successfully prevented the request.
        let blockedSourceObservationCount: Int
        let gaps: [Gap]

        init(history: ComputerUseBrowserNavigationDispatchHistory?, sources: ComputerUseBrowserSourceRequirements,
             contextID: String, ownerVisits: [ComputerUseBrowserResearchVisit]? = nil) {
            attemptCount = history?.attempts.count ?? 0; observationCount = history?.observations.count ?? 0
            controlEventCount = history?.controlEvents.count ?? 0; policyInstallationCount = history?.policyInstallations.count ?? 0
            blockedSourceObservationCount = history?.observations.filter { $0.policyCheck == .blocked }.count ?? 0
            ownerVisitCount = ownerVisits?.count
            controlHistory = history.map { ControlHistory(history: $0) }
            navigationEpisodes = history.map { NavigationEpisodes(history: $0) }
            pageObservationHistory = history.map { PageObservationHistory(history: $0) }
            var found: Set<Gap> = [.platformCoverageUnqualified]
            var matched: Set<UUID> = []
            if !sources.unresolved.isEmpty { found.insert(.unresolvedSourceRequirements) }
            if let history {
                if history.taskID != sources.goal.taskID || history.contextID != contextID { found.insert(.foreignContext) }
                if history.beganAfterAnotherClaim { found.insert(.discardedClaimHistory) }
                if history.hasClaimBoundary { found.insert(.claimBoundary) }
                if history.overflowed { found.insert(.attemptOverflow) }
                if history.observationsOverflowed { found.insert(.observationOverflow) }
                if history.controlEventsOverflowed { found.insert(.controlOverflow) }
                if history.policyInstallationsOverflowed { found.insert(.policyInstallationOverflow) }
                for attempt in history.attempts {
                    if attempt.policy == nil { found.insert(.unconfiguredDispatch) }
                    if attempt.outcome == .pending { found.insert(.pendingDispatch) }
                    else if attempt.outcome != .documentCommitted { found.insert(.unsuccessfulDispatch) }
                    if attempt.requestedOrigin == nil || (attempt.outcome == .documentCommitted && attempt.committedOrigin == nil) {
                        found.insert(.unknownDispatchOrigin)
                    }
                }
                let policies = history.policyInstallations.map(\.policy) + history.attempts.compactMap(\.policy)
                    + history.observations.filter { $0.surface == .mainDocument }.compactMap(\.configuredPolicy)
                for policy in policies {
                    if policy.taskID != sources.goal.taskID || policy.rootDigest != sources.goal.rootDigest { found.insert(.foreignGoalPolicy) }
                    else if policy.goalRevision != sources.goal.digest { found.insert(.earlierGoalPolicy) }
                    else if sources.unresolved.isEmpty && !sources.matchesNavigationPolicy(policy) { found.insert(.mismatchedPolicy) }
                }
                for observation in history.observations {
                    if [.pendingSlot, .observedSlot].contains(observation.binding) { found.insert(.weakObservationBinding) }
                    if observation.binding == .none { found.insert(.unattributedObservation) }
                    if observation.phase == .unorderedLocationChange { found.insert(.unorderedObservation) }
                }
                if controlHistory?.gaps.isEmpty == false { found.insert(.controlEpisodesUnreconciled) }
                if navigationEpisodes?.gaps.isEmpty == false { found.insert(.navigationEpisodesUnreconciled) }
                if pageObservationHistory?.gaps.isEmpty == false { found.insert(.pageObservationsUnreconciled) }
                if let ownerVisits {
                    var previousOrder: Int?
                    for visit in ownerVisits {
                        guard history.taskID == sources.goal.taskID, history.contextID == contextID,
                              visit.taskID == history.taskID, visit.rootDigest == sources.goal.rootDigest,
                              visit.contextID == history.contextID, let native = visit.nativeAttempt,
                              native.outcome == .documentCommitted, let terminalOrder = native.terminalOrder,
                              native.operationID == visit.operationID, native.generation == visit.documentGeneration,
                              history.attempts.first(where: { $0.id == native.id }) == native,
                              native.policy == nil || (native.policy?.taskID == visit.taskID
                                && native.policy?.rootDigest == visit.rootDigest && native.policy?.goalRevision == visit.goalRevision) else {
                            found.insert(.ownerVisitBindingMismatch); continue
                        }
                        guard matched.insert(native.id).inserted else { found.insert(.duplicateOwnerVisit); continue }
                        if let previousOrder, terminalOrder <= previousOrder { found.insert(.ownerVisitOrderMismatch) }
                        previousOrder = terminalOrder
                    }
                    if history.attempts.contains(where: { $0.outcome == .documentCommitted && !matched.contains($0.id) }) {
                        found.insert(.unclaimedCommittedDispatch)
                    }
                } else { found.insert(.ownerHistoryUnavailable) }
            } else { found.insert(.historyUnavailable) }
            if ownerVisits == nil { found.insert(.ownerHistoryUnavailable) }
            if !found.isDisjoint(with: [.historyUnavailable, .foreignContext, .ownerHistoryUnavailable, .ownerVisitBindingMismatch,
                                       .duplicateOwnerVisit, .ownerVisitOrderMismatch, .unclaimedCommittedDispatch,
                                       .attemptOverflow, .claimBoundary, .discardedClaimHistory]) {
                found.insert(.ownerVisitsUnreconciled)
            }
            matchedOwnerVisitCount = matched.count
            gaps = Gap.allCases.filter(found.contains)
        }

        var plannerContext: [String: Any] {
            ["status":"unverified", "gaps":gaps.map(\.rawValue), "retained_attempt_count":attemptCount,
             "retained_observation_count":observationCount, "retained_control_event_count":controlEventCount,
             "retained_policy_installation_count":policyInstallationCount,
             "owner_visit_count":ownerVisitCount.map { $0 as Any } ?? NSNull(), "matched_owner_visit_count":matchedOwnerVisitCount,
             "control_history":controlHistory.map { $0.plannerContext as Any } ?? NSNull(),
             "navigation_episodes":navigationEpisodes.map { $0.plannerContext as Any } ?? NSNull(),
             "page_observations":pageObservationHistory.map { $0.plannerContext as Any } ?? NSNull(),
             "blocked_source_observation_count":blockedSourceObservationCount]
        }
    }
    enum Status: String, Sendable {
        case needsSemanticVerification, needsResultSet, uncompiledRequirement, clarificationApplied
        case needsTicketInventory, needsPartyCapacity
        case reviewSelectedQuantity, reviewPurchaseLimit, reviewPackageSize, reviewQuantityUnresolved
        case quotedCapacitySufficient, quotedCapacityInsufficient
        case missingQuote, ambiguousQuotes, unparsedQuote
        case needsResultObservation, selectedValueConflicts, unparsedSelection, incompatibleSelection
        case quotedValueMatches, quotedValueConflicts, incompatibleLiteral
        case reviewMixedOffers, reviewUnresolved, reviewPageContext, reviewQualifiedPrice
        case reviewRequirementSupported, reviewRequirementConflict, reviewRequirementUnresolved
        case sourceOriginPermitted, sourceOriginExcluded, sourceUnconfigured, sourcePolicyMismatch, incompletePage
        case navigationHistoryUnverified
    }
    struct Requirement: Equatable, Sendable {
        let id: String
        let turn: Int
        let sourceByteOffset: Int
        let sourceByteCount: Int
        let role: ComputerUseBrowserGoalProposal.Role
        let field: ComputerUseBrowserGoalProposal.Field
        let relation: ComputerUseBrowserGoalProposal.Relation
        let quantityScope: Scalars.QuantityScope?
    }
    struct Quote: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let fieldIndex: Int
        let kind: ComputerUseBrowserResultProposal.Kind
        let textIDs: [String]
        let controlIDs: [String]
        let sourceKind: ComputerUseBrowserResultProposal.Field.SourceKind
        /// Complete selected source records, never a numeric substring.
        /// Qualifiers outside these records still need semantic association.
        /// Interpretation uses normalized whitespace only.
        let source: String
        let literal: Scalars.Literal?
        var description: String { "BrowserScalarQuote(kind: \(kind.rawValue), parsed: \(literal != nil))" }
        var debugDescription: String { description }
    }
    struct Evaluation: Equatable, Sendable {
        let requirementID: String
        let status: Status
        let quoteIndices: [Int]
    }
    struct Candidate: Equatable, Sendable {
        let candidateID: String
        let quotes: [Quote]
        /// Exactly one entry for every requirement, in original source order.
        let requirements: [Evaluation]
    }
    let goalRevision: String
    let interpretationDigest: String
    let requirements: [Requirement]
    let candidates: [Candidate]
    let navigationHistory: NavigationHistory?
    private let readingIdentity: String

    init(interpretation: ComputerUseBrowserGoalProposal, reading: ComputerUseBrowserResultCandidates) throws {
        guard interpretation.input.digest == reading.goalRevision else { throw ComputerUseBrowserResultError.goalChanged }
        try reading.review?.validateInterpretation(interpretation)
        goalRevision = interpretation.input.digest; interpretationDigest = interpretation.digest
        readingIdentity = reading.requirementAssessmentIdentity
        let scalars = Scalars(proposal: interpretation), sources = ComputerUseBrowserSourceRequirements(proposal: interpretation)
        navigationHistory = reading.navigationHistoryAssessment(for: sources)
        let unresolvedSources = Set(sources.unresolved.map(\.requirementID))
        let conditions = Dictionary(uniqueKeysWithValues: scalars.entries.map { ($0.requirementID, $0.resolution) })
        requirements = interpretation.requirements.map { requirement in
            let scope: Scalars.QuantityScope?
            if case .bound(let condition)? = conditions[requirement.id], case .quantity(_, _, let unit) = condition.predicate {
                scope = unit.scope
            } else { scope = nil }
            return .init(id: requirement.id, turn: requirement.sourceTurnIndex, sourceByteOffset: requirement.sourceByteOffset,
                sourceByteCount: requirement.sourceByteCount, role: requirement.role, field: requirement.field,
                relation: requirement.relation, quantityScope: scope)
        }
        let pageIncomplete = reading.sourceTruncated || reading.omittedStructure || reading.omittedEmbeddedContent
            || reading.projectionOmittedRecords
        candidates = reading.candidates.enumerated().map { candidateIndex, candidate in
            let review = reading.review?.candidates[candidateIndex]
            let quotes = candidate.fields.enumerated().filter { [.price, .date, .quantity].contains($0.element.kind) }.map { fieldIndex, field -> Quote in
                let source = candidate.source(for: field)
                return Quote(fieldIndex: fieldIndex, kind: field.kind, textIDs: field.textIDs, controlIDs: field.controlIDs,
                    sourceKind: field.sourceKind, source: source, literal: Self.parse(source, kind: field.kind))
            }
            let incomplete = pageIncomplete || !candidate.unprojectedTextIDs.isEmpty || !candidate.unprojectedLinkIDs.isEmpty || !candidate.unprojectedControlIDs.isEmpty
            let evaluations = interpretation.requirements.enumerated().map { requirementIndex, requirement -> Evaluation in
                func result(_ status: Status, quotes: [Int] = []) -> Evaluation {
                    .init(requirementID: requirement.id, status: status, quoteIndices: quotes)
                }
                guard interpretation.disposition == .research else { return result(.uncompiledRequirement) }
                if case .clarification? = conditions[requirement.id] { return result(.clarificationApplied) }
                if case .unresolved(let reason)? = conditions[requirement.id],
                   [.ambiguousClarification, .clarificationScope, .contradictoryClarification].contains(reason) {
                    return result(.uncompiledRequirement)
                }
                if unresolvedSources.contains(requirement.id) { return result(.uncompiledRequirement) }
                // Page citations and the current source policy cannot prove
                // earlier automated visits. Retained constraints also apply
                // when a later interpretation changes this row's field.
                if sources.hasNavigationHistoryObligation(for: requirement.id) { return result(.navigationHistoryUnverified) }
                if sources.hasAnswerPolicyObligation(for: requirement.id), reading.documentAnswerSourceStatus != .unconfigured,
                   !reading.matchesAnswerSourceRequirements(sources) { return result(.sourcePolicyMismatch) }
                if requirement.field == .answerSource {
                    guard reading.documentAnswerSourceStatus != .unconfigured else { return result(.sourceUnconfigured) }
                    guard reading.matchesAnswerSourceRequirements(sources) else { return result(.sourcePolicyMismatch) }
                    switch reading.documentAnswerSourceStatus {
                    case .unconfigured: return result(.sourceUnconfigured)
                    case .excluded: return result(.sourceOriginExcluded)
                    case .permitted: return result(.sourceOriginPermitted)
                    }
                }
                let semantic = review?.requirements?[requirementIndex]
                let canReview = ComputerUseBrowserResultReviewInput.permitsCandidateJudgment(requirement)
                let semanticFailure: Status? = !canReview || semantic == nil || semantic?.judgment == .supports ? nil
                    : (semantic?.judgment == .conflicts ? .reviewRequirementConflict : .reviewRequirementUnresolved)
                guard case .bound(let condition)? = conditions[requirement.id] else {
                    if [.price, .date, .quantity].contains(requirement.field) { return result(.uncompiledRequirement) }
                    if let semanticFailure { return result(semanticFailure) }
                    // This is the reviewer's cited interpretation, not native
                    // verification of geography, availability or goal success.
                    return result(canReview && semantic?.judgment == .supports ? .reviewRequirementSupported : .needsSemanticVerification)
                }
                // The number of discovered cards is not the number of unique,
                // qualifying offers, nor evidence of inventory for a party.
                if case .quantity(_, _, let unit) = condition.predicate {
                    let indices = quotes.indices.filter { quotes[$0].kind == .quantity }
                    if unit.scope == .resultSet { return result(.needsResultSet) }
                    let pending: Status = unit.scope == .ticketInventory ? .needsTicketInventory : .needsPartyCapacity
                    guard !incomplete else { return result(.incompletePage, quotes: indices) }
                    guard let review, !indices.isEmpty else { return result(pending, quotes: indices) }
                    guard review.association != .mixedOffers else { return result(.reviewMixedOffers, quotes: indices) }
                    guard review.association == .singleOffer else { return result(.reviewUnresolved, quotes: indices) }
                    let available = indices.filter { review.fields[quotes[$0].fieldIndex].quantity == .availableQuantity }
                    if available.isEmpty {
                        let meanings = indices.map { review.fields[quotes[$0].fieldIndex].quantity }
                        if meanings.allSatisfy({ $0 == .selectedQuantity }) { return result(.reviewSelectedQuantity, quotes: indices) }
                        if meanings.allSatisfy({ $0 == .purchaseLimit }) { return result(.reviewPurchaseLimit, quotes: indices) }
                        if meanings.allSatisfy({ $0 == .packageSize }) { return result(.reviewPackageSize, quotes: indices) }
                        return result(.reviewQuantityUnresolved, quotes: indices)
                    }
                    // Do not discard another proposed capacity whose unit or
                    // complete literal cannot be parsed; it could conflict.
                    guard available.allSatisfy({ quotes[$0].literal != nil }) else { return result(.unparsedQuote, quotes: available) }
                    let matching = available.filter {
                        if case .quantity(_, let observedUnit)? = quotes[$0].literal { return observedUnit == unit }
                        return false
                    }
                    guard !matching.isEmpty else { return result(.incompatibleLiteral, quotes: available) }
                    guard matching.count == 1 else { return result(.ambiguousQuotes, quotes: matching) }
                    guard let literal = quotes[matching[0]].literal else { return result(.unparsedQuote, quotes: matching) }
                    switch condition.compareProposedCapacity(literal) {
                    case .satisfied: return result(.quotedCapacitySufficient, quotes: matching)
                    case .notSatisfied: return result(.quotedCapacityInsufficient, quotes: matching)
                    case .unverifiable: return result(pending, quotes: matching)
                    }
                }
                let kind: ComputerUseBrowserResultProposal.Kind
                switch condition.predicate { case .price: kind = .price; case .day: kind = .date; case .quantity: return result(.needsResultSet) }
                let allIndices = quotes.indices.filter { quotes[$0].kind == kind }
                let selections = allIndices.filter { quotes[$0].sourceKind != .pageText }
                let indices = allIndices.filter { quotes[$0].sourceKind == .pageText }
                guard !incomplete else { return result(.incompletePage, quotes: allIndices) }
                // A control records a setting, not the result of applying it.
                // Keep every selected value and check it separately; an equal
                // selection cannot replace a missing/conflicting result fact.
                if !selections.isEmpty {
                    guard let review else { return result(.reviewUnresolved, quotes: selections) }
                    guard review.association != .mixedOffers else { return result(.reviewMixedOffers, quotes: selections) }
                    guard review.association == .singleOffer else { return result(.reviewUnresolved, quotes: selections) }
                    let fields = selections.map { review.fields[quotes[$0].fieldIndex] }
                    if fields.contains(where: { $0.scope == .page }) { return result(.reviewPageContext, quotes: selections) }
                    guard fields.allSatisfy({ $0.scope == .offer }) else { return result(.reviewUnresolved, quotes: selections) }
                    guard selections.allSatisfy({ quotes[$0].sourceKind == .controlState && quotes[$0].literal != nil }) else {
                        return result(.unparsedSelection, quotes: selections)
                    }
                    for index in selections {
                        guard let literal = quotes[index].literal else { return result(.unparsedSelection, quotes: selections) }
                        switch condition.compareLiteral(literal) {
                        case .notSatisfied: return result(.selectedValueConflicts, quotes: selections)
                        case .unverifiable: return result(.incompatibleSelection, quotes: selections)
                        case .satisfied: break
                        }
                    }
                }
                guard !indices.isEmpty else { return result(selections.isEmpty ? .missingQuote : .needsResultObservation, quotes: selections) }
                // Negative/uncertain semantic proposals prevent a numeric
                // match from hiding a known association concern. Positive
                // labels still establish only a quoted literal comparison.
                if let review {
                    guard review.association != .mixedOffers else { return result(.reviewMixedOffers, quotes: indices) }
                    guard review.association == .singleOffer else { return result(.reviewUnresolved, quotes: indices) }
                    let fields = indices.map { review.fields[quotes[$0].fieldIndex] }
                    if fields.contains(where: { $0.scope == .page }) { return result(.reviewPageContext, quotes: indices) }
                    if fields.contains(where: { $0.scope != .offer }) { return result(.reviewUnresolved, quotes: indices) }
                    if kind == .price {
                        if fields.contains(where: { $0.price == .qualified }) { return result(.reviewQualifiedPrice, quotes: indices) }
                        if fields.contains(where: { $0.price != .exact }) { return result(.reviewUnresolved, quotes: indices) }
                    }
                }
                if let semanticFailure { return result(semanticFailure, quotes: indices) }
                guard indices.count == 1 else { return result(.ambiguousQuotes, quotes: indices) }
                guard let literal = quotes[indices[0]].literal else { return result(.unparsedQuote, quotes: indices) }
                switch condition.compareLiteral(literal) {
                case .satisfied: return result(.quotedValueMatches, quotes: indices)
                case .notSatisfied: return result(.quotedValueConflicts, quotes: indices)
                case .unverifiable: return result(.incompatibleLiteral, quotes: indices)
                }
            }
            return Candidate(candidateID: candidate.id, quotes: quotes, requirements: evaluations)
        }
    }

    /// Planning gets indices and existing text references, never native URLs,
    /// goal/session hashes, candidate authority or invented normalized prose.
    var plannerContext: [String: Any] {
        let navigationAssessment = navigationHistory != nil || requirements.contains { $0.field == .navigationSource }
            || candidates.contains { $0.requirements.contains { $0.status == .navigationHistoryUnverified } }
        let policyAssessment = requirements.contains { $0.field == .answerSource }
            || candidates.contains { $0.requirements.contains { $0.status == .sourcePolicyMismatch } }
        var context: [String: Any] = ["version":navigationAssessment ? 12 : (policyAssessment ? 5 : (candidates.contains { $0.quotes.contains { !$0.controlIDs.isEmpty } } ? 4 : 3)),
         "requirements":requirements.enumerated().map { index, value in
             ["index":index, "turn":value.turn, "sourceByteOffset":value.sourceByteOffset, "sourceByteCount":value.sourceByteCount,
              "role":value.role.rawValue, "field":value.field.rawValue, "relation":value.relation.rawValue,
              "quantity_scope":value.quantityScope.map { $0.rawValue as Any } ?? NSNull()] as [String: Any]
         },
         "candidates":candidates.enumerated().map { index, candidate in
             ["index":index, "quotes":candidate.quotes.map {
                 ["field":$0.fieldIndex, "kind":$0.kind.rawValue, "texts":$0.textIDs, "controls":$0.controlIDs,
                  "source_kind":$0.sourceKind.rawValue, "parsed":$0.literal != nil] as [String: Any]
             }, "requirements":candidate.requirements.map(\.status.rawValue)] as [String: Any]
         }]
        if let navigationHistory { context["navigation_history_at_reading"] = navigationHistory.plannerContext }
        return context
    }

    private static func parse(_ source: String, kind: ComputerUseBrowserResultProposal.Kind) -> Scalars.Literal? {
        let text = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        switch kind {
        case .price: return price(text)
        case .date: return day(text).map { .day($0) }
        case .quantity:
            guard let parts = groups(#"^([0-9]{1,3}) (results|options|flights|concerts|movies|tickets|people|adults|children)$"#, text),
                  let count = Int64(parts[0]), let unit = Scalars.QuantityUnit(rawValue: parts[1].lowercased()) else { return nil }
            return .quantity(count, unit)
        default: return nil
        }
    }

    private static func groups(_ pattern: String, _ text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.range == NSRange(text.startIndex..., in: text) else { return nil }
        let string = text as NSString
        return (1..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : string.substring(with: match.range(at: $0)) }
    }

    private static func price(_ text: String) -> Scalars.Literal? {
        // Ranges, "from", crossed-out prices, approximate values, unresolved
        // qualifiers and extra prose cannot become exact prices by extraction.
        let pattern = #"^(?:Price: )?((?:USD|EUR|GBP|CAD|AUD|JPY)|[$€£¥])\s*((?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]{1,2})?)(?: (total|per person|per ticket))?(?: (including fees|excluding fees|including taxes and fees|excluding taxes and fees))?$"#
        guard let parts = groups(pattern, text), let currency = Scalars.Currency(rawValue: parts[0].uppercased()) else { return nil }
        let number = parts[1].replacingOccurrences(of: ",", with: "").split(separator: ".", omittingEmptySubsequences: false)
        guard let wholeText = number.first, wholeText.count <= 9, let whole = Int64(wholeText) else { return nil }
        let fraction = number.count == 2 ? String(number[1]) : ""
        guard let cents = Int64(fraction + String(repeating: "0", count: 2 - fraction.count)),
              let amount = Scalars.Amount(hundredths: whole * 100 + cents, currency: currency) else { return nil }
        let basis: Scalars.PriceBasis
        switch parts[2].lowercased() { case "total": basis = .total; case "per person": basis = .perPerson; case "per ticket": basis = .perTicket; default: basis = .unspecified }
        let fees: Scalars.Fees
        switch parts[3].lowercased() { case "including fees", "including taxes and fees": fees = .included
        case "excluding fees", "excluding taxes and fees": fees = .excluded; default: fees = .unspecified }
        return .price(amount, basis, fees)
    }

    private static func day(_ text: String) -> Scalars.CivilDay? {
        if let parts = groups(#"^(?:Date: )?([0-9]{4})-([0-9]{2})-([0-9]{2})$"#, text),
           let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) { return .init(year: year, month: month, day: day) }
        // Explicit English month names and four-digit years are unambiguous.
        // A page's "tomorrow" cannot use the user's original task clock: the
        // page has its own publication/time-zone context, still unresolved.
        let monthPattern = "(January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)"
        let months = ["jan":1, "feb":2, "mar":3, "apr":4, "may":5, "jun":6, "jul":7, "aug":8, "sep":9, "oct":10, "nov":11, "dec":12]
        if let parts = groups("^(?:Date: )?" + monthPattern + " ([0-9]{1,2}), ([0-9]{4})$", text),
           let month = months[String(parts[0].lowercased().prefix(3))], let day = Int(parts[1]), let year = Int(parts[2]) {
            return .init(year: year, month: month, day: day)
        }
        if let parts = groups("^(?:Date: )?([0-9]{1,2}) " + monthPattern + " ([0-9]{4})$", text),
           let day = Int(parts[0]), let month = months[String(parts[1].lowercased().prefix(3))], let year = Int(parts[2]) {
            return .init(year: year, month: month, day: day)
        }
        return nil
    }
    var description: String { "BrowserResultAssessment(requirements: \(requirements.count), candidates: \(candidates.count))" }
    var debugDescription: String { description }
}

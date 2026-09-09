import Foundation
import XCTest
@testable import RemoteDesktopHost

@MainActor
final class ComputerUseBrowserSourcePolicyTests: XCTestCase {
    func testPairedWorkflowFailureCanBeFollowedByAValidResumeWithoutErasingTheFailure() async throws {
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
        browser.recordWorkflowControl(.workflowPaused, requirement: session)
        let failedID = UUID()
        browser.recordWorkflowControl(.workflowResumeStarted, requirement: session, operationID: failedID)
        try await browser.reacquireAfterUserControl(taskID: input.taskID, requirement: session, workflowOperationID: failedID)
        // Model the owner's separate page/authentication check failing after
        // native return; these calls exercise history reconciliation only.
        browser.recordWorkflowControl(.workflowResumeFailed, requirement: session, operationID: failedID)
        let failed = ComputerUseBrowserResultAssessment.ControlHistory(history: try browser.navigationDispatchHistory(taskID: input.taskID))
        XCTAssertEqual(failed.completedNativeHandbackCount, 1); XCTAssertEqual(failed.completedWorkflowResumeCount, 0)
        XCTAssertEqual(failed.failedWorkflowResumeCount, 1); XCTAssertEqual(failed.unclosedPauseScopeCount, 1)
        XCTAssertEqual(failed.gaps, [.unclosedPause])
        let resumedID = UUID()
        browser.recordWorkflowControl(.workflowResumeStarted, requirement: session, operationID: resumedID)
        try await browser.reacquireAfterUserControl(taskID: input.taskID, requirement: session, workflowOperationID: resumedID)
        browser.recordWorkflowControl(.workflowResumed, requirement: session, operationID: resumedID)
        let resumed = ComputerUseBrowserResultAssessment.ControlHistory(history: try browser.navigationDispatchHistory(taskID: input.taskID))
        XCTAssertEqual(resumed.completedNativeHandbackCount, 2); XCTAssertEqual(resumed.completedWorkflowResumeCount, 1)
        XCTAssertEqual(resumed.failedWorkflowResumeCount, 1); XCTAssertEqual(resumed.unclosedPauseScopeCount, 0)
        XCTAssertTrue(resumed.gaps.isEmpty)
    }

    func testAnotherPauseInvalidatesAnEarlierResumeEvenAfterNativeHandbackReturned() async throws {
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID), id = UUID()
        browser.recordWorkflowControl(.workflowPaused, requirement: session)
        browser.recordWorkflowControl(.workflowResumeStarted, requirement: session, operationID: id)
        try await browser.reacquireAfterUserControl(taskID: input.taskID, requirement: session, workflowOperationID: id)
        browser.recordWorkflowControl(.workflowPaused, requirement: session)
        browser.recordWorkflowControl(.workflowResumed, requirement: session, operationID: id)
        let assessment = ComputerUseBrowserResultAssessment.ControlHistory(history: try browser.navigationDispatchHistory(taskID: input.taskID))
        XCTAssertEqual(assessment.completedNativeHandbackCount, 1); XCTAssertEqual(assessment.completedWorkflowResumeCount, 0)
        XCTAssertEqual(assessment.unclosedPauseScopeCount, 1)
        XCTAssertTrue(assessment.gaps.contains(.resumeAfterAnotherPause)); XCTAssertTrue(assessment.gaps.contains(.unclosedPause))
    }

    func testMissingNativeHandbackAndReusedWorkflowIdentityCannotCompleteARecordedResume() throws {
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID), id = UUID()
        browser.recordWorkflowControl(.workflowPaused, requirement: session)
        browser.recordWorkflowControl(.workflowResumeStarted, requirement: session, operationID: id)
        browser.recordWorkflowControl(.workflowResumed, requirement: session, operationID: id)
        browser.recordWorkflowControl(.workflowResumeStarted, requirement: session, operationID: id)
        browser.recordWorkflowControl(.workflowResumed, requirement: session, operationID: id)
        let assessment = ComputerUseBrowserResultAssessment.ControlHistory(history: try browser.navigationDispatchHistory(taskID: input.taskID))
        XCTAssertEqual(assessment.completedNativeHandbackCount, 0); XCTAssertEqual(assessment.completedWorkflowResumeCount, 0)
        XCTAssertTrue(assessment.gaps.contains(.resumeWithoutNativeHandback))
        XCTAssertTrue(assessment.gaps.contains(.reusedOperation)); XCTAssertTrue(assessment.gaps.contains(.unmatchedWorkflowResume))
        XCTAssertEqual(assessment.unclosedPauseScopeCount, 1)
    }

    func testStandaloneNativeHandbackCannotSupplyAMissingOwnerResumeOperation() async throws {
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
        try await browser.reacquireAfterUserControl(taskID: input.taskID, requirement: session)
        browser.recordWorkflowControl(.workflowResumed, requirement: session, operationID: UUID())
        let assessment = ComputerUseBrowserResultAssessment.ControlHistory(history: try browser.navigationDispatchHistory(taskID: input.taskID))
        XCTAssertEqual(assessment.completedNativeHandbackCount, 1); XCTAssertEqual(assessment.completedWorkflowResumeCount, 0)
        XCTAssertTrue(assessment.gaps.contains(.nativeHandbackWithoutWorkflow))
        XCTAssertTrue(assessment.gaps.contains(.unmatchedWorkflowResume))
    }

    func testConfirmedAttemptRequiresTheNativeReceiptAndRemainsReadableDuringPauseWithoutQueryingControl() async throws {
        let server = try OwnedBrowserHTTPFixture(), base = try await server.start()
        defer { server.stop() }
        var allowed = true, gateCalls = 0
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { gateCalls += 1; return allowed })
        defer { browser.close() }
        let input = try goal()
        try browser.claim(taskID: input.taskID)
        let document = try await browser.navigate(taskID: input.taskID, operationID: "confirmed", to: base)
        let native = try XCTUnwrap(browser.confirmedNavigationAttempt(for: document))
        allowed = false
        let calls = gateCalls
        XCTAssertEqual(browser.confirmedNavigationAttempt(for: document), native)
        let wrongURL = ComputerUseBrowserDocument(contextID: document.contextID, taskID: document.taskID,
            generation: document.generation, operationID: document.operationID, requestedURL: document.requestedURL,
            committedURL: base.appendingPathComponent("unobserved"))
        let manual = ComputerUseBrowserDocument(contextID: document.contextID, taskID: document.taskID,
            generation: document.generation, operationID: document.operationID, requestedURL: document.requestedURL,
            committedURL: document.committedURL, source: .userControlObservation)
        let otherContext = ComputerUseBrowserDocument(contextID: "foreign", taskID: document.taskID,
            generation: document.generation, operationID: document.operationID, requestedURL: document.requestedURL,
            committedURL: document.committedURL)
        XCTAssertNil(browser.confirmedNavigationAttempt(for: wrongURL))
        XCTAssertNil(browser.confirmedNavigationAttempt(for: manual))
        XCTAssertNil(browser.confirmedNavigationAttempt(for: otherContext))
        XCTAssertEqual(gateCalls, calls, "Historical binding must not query or acquire permission to act")
    }

    func testOwnerVisitReconciliationRequiresExactDistinctOrderedNativeCommits() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        fixture.policy.choices = [true, true, false]
        _ = try await fixture.start()
        let owner = try fixture.owner(), interpretation = try await owner.interpretGoal()
        let history = try fixture.browser.navigationDispatchHistory(taskID: owner.taskID)
        let visits = owner.confirmedNavigationHistory
        XCTAssertEqual(visits.count, 3)
        func assess(_ visits: [ComputerUseBrowserResearchVisit]?) -> ComputerUseBrowserResultAssessment.NavigationHistory {
            .init(history: history, sources: interpretation.sources, contextID: fixture.browser.contextID, ownerVisits: visits)
        }
        let matched = assess(visits)
        XCTAssertEqual(matched.ownerVisitCount, 3); XCTAssertEqual(matched.matchedOwnerVisitCount, 3)
        XCTAssertFalse(matched.gaps.contains(.ownerVisitsUnreconciled))
        XCTAssertTrue(matched.gaps.contains(.platformCoverageUnqualified))
        XCTAssertTrue(assess(nil).gaps.contains(.ownerHistoryUnavailable))
        XCTAssertNil(assess(nil).ownerVisitCount)
        XCTAssertEqual(assess([]).ownerVisitCount, 0)
        XCTAssertTrue(assess([]).gaps.contains(.unclaimedCommittedDispatch))
        XCTAssertTrue(assess(Array(visits.reversed())).gaps.contains(.ownerVisitOrderMismatch))
        let duplicate = assess(visits + [visits[0]])
        XCTAssertTrue(duplicate.gaps.contains(.duplicateOwnerVisit)); XCTAssertEqual(duplicate.matchedOwnerVisitCount, 3)
        let other = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { other.close() }
        try other.claim(taskID: owner.taskID)
        let foreign = ComputerUseBrowserResultAssessment.NavigationHistory(
            history: try other.navigationDispatchHistory(taskID: owner.taskID), sources: interpretation.sources,
            contextID: other.contextID, ownerVisits: visits)
        XCTAssertEqual(foreign.matchedOwnerVisitCount, 0)
        XCTAssertTrue(foreign.gaps.contains(.ownerVisitBindingMismatch)); XCTAssertTrue(foreign.gaps.contains(.ownerVisitsUnreconciled))
        let logged = String(reflecting: visits)
        for hidden in [owner.taskID, owner.input.digest, history.identity, visits[0].operationID] { XCTAssertFalse(logged.contains(hidden)) }
    }

    func testNativePolicyHistoryRecordsOnlyAcceptedChangesAndCannotEraseAReplacement() throws {
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        let foreign = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close(); foreign.close() }
        let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
        let foreignSession = try foreign.prepareWorkflowSession(taskID: input.taskID)
        let original = try ComputerUseBrowserSourcePolicy(goal: input)
        let replacement = try ComputerUseBrowserSourcePolicy(goal: input,
            excludedOrigins: [ComputerUseBrowserSourceOrigin(url("https://blocked.test"))])
        try browser.installSourcePolicy(original, replacing: nil, session: session)
        let first = try browser.navigationDispatchHistory(taskID: input.taskID)
        try browser.installSourcePolicy(original, replacing: original.digest, session: session)
        XCTAssertEqual(try browser.navigationDispatchHistory(taskID: input.taskID), first, "An idempotent installation adds no history")
        XCTAssertThrowsError(try browser.installSourcePolicy(replacement, replacing: original.digest, session: foreignSession))
        XCTAssertThrowsError(try browser.installSourcePolicy(replacement, replacing: nil, session: session))
        XCTAssertEqual(try browser.navigationDispatchHistory(taskID: input.taskID), first, "Rejected changes add no accepted event")
        try browser.installSourcePolicy(replacement, replacing: original.digest, session: session)
        try browser.installSourcePolicy(original, replacing: replacement.digest, session: session)
        let restored = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertEqual(restored.policyInstallations.map(\.policy), [original, replacement, original])
        XCTAssertEqual(restored.policyInstallations.map(\.previousPolicy), [nil, original, replacement])
        XCTAssertEqual(restored.policyInstallations.map(\.order), [0, 1, 2])
        XCTAssertEqual(Set(restored.policyInstallations.map(\.parentSessionID)).count, 1)
        XCTAssertEqual(Set(restored.policyInstallations.map(\.ownershipEpoch)).count, 1)
        XCTAssertNotEqual(restored.identity, first.identity)
        XCTAssertTrue(restored.attempts.isEmpty); XCTAssertTrue(restored.observations.isEmpty)
        let logged = String(reflecting: restored.policyInstallations)
        for hidden in [input.taskID, original.digest, replacement.digest, "blocked.test"] { XCTAssertFalse(logged.contains(hidden)) }
    }

    func testPolicyHistoryBoundsAlternatingChangesAndInvalidatesEveryOmittedReplacement() throws {
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
        let first = try ComputerUseBrowserSourcePolicy(goal: input)
        let second = try ComputerUseBrowserSourcePolicy(goal: input,
            excludedOrigins: [ComputerUseBrowserSourceOrigin(url("https://blocked.test"))])
        var previous: ComputerUseBrowserSourcePolicy?
        for index in 0..<64 {
            let next = index.isMultiple(of: 2) ? first : second
            try browser.installSourcePolicy(next, replacing: previous?.digest, session: session)
            previous = next
        }
        let full = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertEqual(full.policyInstallations.count, 64); XCTAssertFalse(full.policyInstallationsOverflowed)
        try browser.installSourcePolicy(first, replacing: second.digest, session: session)
        let overflow = try browser.navigationDispatchHistory(taskID: input.taskID)
        try browser.installSourcePolicy(second, replacing: first.digest, session: session)
        let later = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertTrue(overflow.policyInstallationsOverflowed); XCTAssertTrue(later.policyInstallationsOverflowed)
        XCTAssertEqual(full.policyInstallations, overflow.policyInstallations)
        XCTAssertEqual(full.policyInstallations, later.policyInstallations)
        XCTAssertNotEqual(full.identity, overflow.identity); XCTAssertNotEqual(overflow.identity, later.identity)
        XCTAssertTrue(later.attempts.isEmpty); XCTAssertTrue(try browser.isUnnavigatedSession(session))
    }

    func testWorkflowResumeHistoryLinksNativeReacquisitionToTheAcceptedParentOperation() async throws {
        let fixture = try await ResearchDriverFixture.make()
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner(), before = try fixture.browser.navigationDispatchHistory(taskID: owner.taskID)
        owner.pause()
        let paused = try fixture.browser.navigationDispatchHistory(taskID: owner.taskID)
        let pause = try XCTUnwrap(paused.controlEvents.last)
        XCTAssertEqual(pause.phase, .workflowPaused)
        try await owner.resumeAfterUserControl()
        let resumed = try fixture.browser.navigationDispatchHistory(taskID: owner.taskID)
        let controlAssessment = ComputerUseBrowserResultAssessment.ControlHistory(history: resumed)
        XCTAssertEqual(controlAssessment.completedNativeHandbackCount, 1)
        XCTAssertEqual(controlAssessment.completedWorkflowResumeCount, 1)
        XCTAssertEqual(controlAssessment.unclosedPauseScopeCount, 0); XCTAssertTrue(controlAssessment.gaps.isEmpty)
        let workflowStart = try XCTUnwrap(resumed.controlEvents.first { $0.phase == .workflowResumeStarted })
        let nativeStart = try XCTUnwrap(resumed.controlEvents.first { $0.phase == .nativeReacquisitionStarted })
        let nativeFinish = try XCTUnwrap(resumed.controlEvents.first { $0.phase == .nativeReacquisitionFinished })
        let workflowFinish = try XCTUnwrap(resumed.controlEvents.first { $0.phase == .workflowResumed })
        XCTAssertNotNil(workflowStart.workflowOperationID)
        XCTAssertNotNil(nativeStart.nativeOperationID)
        XCTAssertEqual(nativeStart.nativeOperationID, nativeFinish.nativeOperationID)
        for event in [workflowStart, nativeStart, nativeFinish, workflowFinish] {
            XCTAssertEqual(event.workflowOperationID, workflowStart.workflowOperationID)
            XCTAssertEqual(event.handbackBinding, pause.handbackBinding)
            XCTAssertEqual(event.handback, pause.handback)
            XCTAssertEqual(event.parentSessionID, pause.parentSessionID)
            XCTAssertEqual(event.ownershipEpoch, pause.ownershipEpoch)
        }
        let orders = [pause.order, workflowStart.order, nativeStart.order, nativeFinish.order, workflowFinish.order]
        XCTAssertEqual(orders, orders.sorted()); XCTAssertEqual(Set(orders).count, orders.count)
        XCTAssertFalse(resumed.controlEvents.contains { [.workflowResumeFailed, .nativeReacquisitionFailed].contains($0.phase) })
        XCTAssertEqual(resumed.attempts, before.attempts)
        _ = try owner.researchEvidence(for: owner.input)
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
    }

    func testNativeHandbackFinishCannotMasqueradeAsWorkflowResumeAfterAuthenticationAppears() async throws {
        let script = "fetch('/signal').then(() => { const field = document.createElement('input'); field.type = 'password'; field.value = 'private-login-value'; document.body.append(field); fetch('/locked'); });"
        let fixture = try await ResearchDriverFixture.make(additionalCardHTML: "<script>\(script)</script>", heldSignal: true)
        defer { fixture.close() }
        _ = try await fixture.start()
        let owner = try fixture.owner(), before = try fixture.browser.navigationDispatchHistory(taskID: owner.taskID)
        try await waitUntil { fixture.server.count("/signal") == 1 }
        owner.pause(); fixture.state.allowed = false
        fixture.server.releaseHeldResponses()
        try await waitUntil { fixture.server.count("/locked") == 1 }
        fixture.state.allowed = true
        do { try await owner.resumeAfterUserControl(); XCTFail("The new authentication control requires continued user intervention") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        let after = try fixture.browser.navigationDispatchHistory(taskID: owner.taskID)
        let controlAssessment = ComputerUseBrowserResultAssessment.ControlHistory(history: after)
        XCTAssertEqual(controlAssessment.completedNativeHandbackCount, 1)
        XCTAssertEqual(controlAssessment.failedWorkflowResumeCount, 1)
        XCTAssertEqual(controlAssessment.completedWorkflowResumeCount, 0)
        XCTAssertEqual(controlAssessment.unclosedPauseScopeCount, 1)
        XCTAssertTrue(controlAssessment.gaps.contains(.unclosedPause))
        let nativeFinish = try XCTUnwrap(after.controlEvents.first { $0.phase == .nativeReacquisitionFinished })
        let workflowFailure = try XCTUnwrap(after.controlEvents.first { $0.phase == .workflowResumeFailed })
        XCTAssertNotNil(nativeFinish.workflowOperationID)
        XCTAssertEqual(nativeFinish.workflowOperationID, workflowFailure.workflowOperationID)
        XCTAssertLessThan(nativeFinish.order, workflowFailure.order)
        XCTAssertFalse(after.controlEvents.contains { $0.phase == .workflowResumed })
        XCTAssertEqual(after.attempts, before.attempts)
        XCTAssertThrowsError(try owner.researchEvidence(for: owner.input)) {
            XCTAssertEqual($0 as? ComputerUseBrowserResearchTask.Failure, .paused)
        }
        XCTAssertEqual(fixture.server.count("/search?q=concerts"), 1)
        for event in after.controlEvents { XCTAssertFalse(String(reflecting: event).contains("private-login-value")) }
    }

    func testControlHistoryRejectsForeignSessionBindingsAndForgedNativePhases() async throws {
        let first = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        let second = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { first.close(); second.close() }
        let input = try goal(), current = try first.prepareWorkflowSession(taskID: input.taskID)
        let foreign = try second.prepareWorkflowSession(taskID: input.taskID)
        let before = try first.navigationDispatchHistory(taskID: input.taskID)
        first.recordWorkflowControl(.workflowPaused, requirement: foreign)
        first.recordWorkflowControl(.nativeReacquisitionFinished, requirement: current, operationID: UUID())
        do { try await first.reacquireAfterUserControl(taskID: input.taskID, requirement: foreign); XCTFail("Foreign native context") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .handbackContextLost) }
        XCTAssertEqual(try first.navigationDispatchHistory(taskID: input.taskID).controlEvents, before.controlEvents)
        first.stop()
        _ = try first.prepareWorkflowSession(taskID: input.taskID)
        let reclaimed = try first.navigationDispatchHistory(taskID: input.taskID)
        first.recordWorkflowControl(.workflowResumed, requirement: current, operationID: UUID())
        do { try await first.reacquireAfterUserControl(taskID: input.taskID, requirement: current); XCTFail("Retired ownership epoch") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .handbackContextLost) }
        XCTAssertEqual(try first.navigationDispatchHistory(taskID: input.taskID).controlEvents, reclaimed.controlEvents)
    }

    func testRepeatedBlankHandbackBoundsControlRecordsAndRetainsTheOverflowGap() async throws {
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
        for _ in 0..<64 { try await browser.reacquireAfterUserControl(taskID: input.taskID, requirement: session) }
        let full = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertEqual(full.controlEvents.count, 128); XCTAssertFalse(full.controlEventsOverflowed)
        try await browser.reacquireAfterUserControl(taskID: input.taskID, requirement: session)
        let overflowed = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertTrue(overflowed.controlEventsOverflowed)
        XCTAssertEqual(overflowed.controlEvents, full.controlEvents)
        XCTAssertNotEqual(overflowed.identity, full.identity)
        try await browser.reacquireAfterUserControl(taskID: input.taskID, requirement: session)
        let later = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertEqual(later.controlEvents, full.controlEvents)
        XCTAssertNotEqual(later.identity, overflowed.identity, "Omitted control activity still invalidates a frozen reading")
        XCTAssertTrue(overflowed.attempts.isEmpty)
        XCTAssertTrue(try browser.isUnnavigatedSession(session))
    }

    func testNativePolicyObservationsKeepSlotCorrelationSeparateFromExactNavigationCallbacks() async throws {
        let server = try OwnedBrowserHTTPFixture(), base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
        let origin = try ComputerUseBrowserSourceOrigin(base)
        let policy = try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [origin])
        try browser.installSourcePolicy(policy, replacing: nil, session: session)
        _ = try await browser.navigate(taskID: input.taskID, operationID: "native", to: base)
        let history = try browser.navigationDispatchHistory(taskID: input.taskID)
        let attempt = try XCTUnwrap(history.attempts.first)
        let action = try XCTUnwrap(history.observations.first { $0.phase == .navigationAction && $0.attemptID == attempt.id })
        XCTAssertEqual(attempt.commitBasis, .responseAndFinish)
        XCTAssertEqual(attempt.successfulResponseOrigin, origin)
        XCTAssertTrue(history.observations.allSatisfy { $0.instantBack == nil })
        let episodes = ComputerUseBrowserResultAssessment.NavigationEpisodes(history: history)
        XCTAssertEqual(episodes.dispatchEpisodeCount, 1); XCTAssertEqual(episodes.observedEpisodeCount, 0)
        XCTAssertEqual(episodes.matchedCommittedAttemptCount, 1)
        XCTAssertTrue(episodes.gaps.contains(.responseAssociationUnqualified), "A slot response is not an exact navigation-object association")
        XCTAssertFalse(episodes.gaps.contains(.unmatchedCommittedAttempt))
        let response = try XCTUnwrap(history.observations.first { $0.phase == .response && $0.attemptID == attempt.id })
        let start = try XCTUnwrap(history.observations.first { $0.phase == .provisionalStart && $0.attemptID == attempt.id })
        let commit = try XCTUnwrap(history.observations.first { $0.phase == .documentCommitStarted && $0.attemptID == attempt.id })
        let finish = try XCTUnwrap(history.observations.first { $0.phase == .documentFinished && $0.attemptID == attempt.id })
        for event in [action, response] {
            XCTAssertEqual(event.binding, .pendingSlot); XCTAssertEqual(event.decision, .allowed)
            XCTAssertEqual(event.policyCheck, .permitted); XCTAssertEqual(event.configuredPolicy, policy)
            XCTAssertEqual(event.origin, origin)
        }
        XCTAssertEqual(action.control, .automationAllowed)
        XCTAssertEqual(response.control, .unknown, "Response policy enforcement does not query the pending operation's current control gate")
        for event in [start, commit, finish] {
            XCTAssertEqual(event.binding, .exactPendingNavigation); XCTAssertEqual(event.decision, .observed)
            XCTAssertEqual(event.policyCheck, .notChecked)
        }
        for event in [action, response, start, commit, finish] {
            XCTAssertEqual(event.attemptID, attempt.id)
            XCTAssertEqual(event.parentSessionID, attempt.sessionID)
            XCTAssertEqual(event.ownershipEpoch, attempt.ownershipEpoch)
            XCTAssertEqual(event.generation, attempt.generation)
            XCTAssertEqual(event.navigationCorrelationID, start.navigationCorrelationID)
        }
        XCTAssertNotNil(start.navigationCorrelationID)
        XCTAssertTrue(history.observations.contains { $0.phase == .locationChanged })
        XCTAssertFalse(history.observationsOverflowed)
        let terminalOrder = try XCTUnwrap(attempt.terminalOrder)
        XCTAssertLessThan(attempt.order, start.order)
        XCTAssertLessThan(finish.order, terminalOrder)
        let orders = [attempt.order, terminalOrder] + history.observations.map(\.order)
            + history.controlEvents.map(\.order) + history.policyInstallations.map(\.order)
        XCTAssertEqual(orders.sorted(), Array(0..<orders.count), "Retained native records share one ordered sequence")
    }

    func testRedirectCallbacksRemainObservationsRatherThanInventedRequestDecisions() async throws {
        let destination = try OwnedBrowserHTTPFixture(), target = try await destination.start()
        let server = try OwnedBrowserHTTPFixture(routes: ["/redirect": .init(status: 302, location: target.absoluteString + "/callback?code=private-code#private-fragment")])
        let base = try await server.start()
        defer { server.stop(); destination.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
        let policy = try ComputerUseBrowserSourcePolicy(goal: input,
            allowedOrigins: [ComputerUseBrowserSourceOrigin(base), ComputerUseBrowserSourceOrigin(target)])
        try browser.installSourcePolicy(policy, replacing: nil, session: session)
        _ = try await browser.navigate(taskID: input.taskID, operationID: "redirect", to: base.appendingPathComponent("redirect"))
        let history = try browser.navigationDispatchHistory(taskID: input.taskID)
        let attempt = try XCTUnwrap(history.attempts.first)
        let redirect = try XCTUnwrap(history.observations.first { $0.phase == .serverRedirect && $0.attemptID == attempt.id })
        XCTAssertEqual(attempt.commitBasis, .responseAndFinish)
        XCTAssertEqual(attempt.successfulResponseOrigin, try ComputerUseBrowserSourceOrigin(target))
        let episodes = ComputerUseBrowserResultAssessment.NavigationEpisodes(history: history)
        XCTAssertEqual(episodes.dispatchEpisodeCount, 1); XCTAssertEqual(episodes.matchedCommittedAttemptCount, 1)
        XCTAssertGreaterThanOrEqual(episodes.redirectCallbackCount, 1)
        XCTAssertTrue(episodes.gaps.contains(.redirectDestinationsUnqualified))
        XCTAssertEqual(redirect.binding, .exactPendingNavigation); XCTAssertEqual(redirect.attemptID, attempt.id)
        XCTAssertEqual(redirect.decision, .observed); XCTAssertEqual(redirect.policyCheck, .notChecked)
        XCTAssertEqual(redirect.control, .unknown); XCTAssertEqual(redirect.configuredPolicy, policy)
        // WebKit's redirect callback has no destination argument. Do not
        // assert that its live location snapshot is the next requested origin.
        XCTAssertEqual(attempt.committedOrigin, try ComputerUseBrowserSourceOrigin(target))
        XCTAssertTrue(history.observations.contains {
            $0.phase == .response && $0.decision == .allowed && $0.origin == attempt.committedOrigin
        })
        for observation in history.observations {
            let text = String(reflecting: observation)
            XCTAssertFalse(text.contains("private-code")); XCTAssertFalse(text.contains("private-fragment"))
            XCTAssertFalse(text.contains(base.absoluteString)); XCTAssertFalse(text.contains(target.absoluteString))
        }
    }

    func testScriptedNavigationHasItsOwnObservedIdentityWithoutCreatingAnAutomatedDispatch() async throws {
        let destination = try OwnedBrowserHTTPFixture(), target = try await destination.start()
        let script = "fetch('/go').then(() => location.href = '\(target.absoluteString)/landed');"
        let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: "<h1>Starting page</h1><script>\(script)</script>"), "/go": .init(held: true)])
        let base = try await server.start()
        defer { server.stop(); destination.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
        let policy = try ComputerUseBrowserSourcePolicy(goal: input,
            allowedOrigins: [ComputerUseBrowserSourceOrigin(base), ComputerUseBrowserSourceOrigin(target)])
        try browser.installSourcePolicy(policy, replacing: nil, session: session)
        _ = try await browser.navigate(taskID: input.taskID, operationID: "first", to: base.appendingPathComponent("page"))
        try await waitUntil { server.count("/go") == 1 }
        let before = try browser.navigationDispatchHistory(taskID: input.taskID)
        let targetOrigin = try ComputerUseBrowserSourceOrigin(target)
        server.releaseHeldResponses()
        try await waitUntil {
            (try? browser.navigationDispatchHistory(taskID: input.taskID).observations.dropFirst(before.observations.count).contains {
                $0.phase == .documentFinished && $0.binding == .exactObservedNavigation && $0.origin == targetOrigin
            }) == true
        }
        let after = try browser.navigationDispatchHistory(taskID: input.taskID)
        let added = after.observations.dropFirst(before.observations.count)
        let episodes = ComputerUseBrowserResultAssessment.NavigationEpisodes(history: after)
        XCTAssertEqual(episodes.dispatchEpisodeCount, 1); XCTAssertEqual(episodes.observedEpisodeCount, 1)
        XCTAssertEqual(episodes.observedFinishCallbackCount, 1); XCTAssertEqual(episodes.matchedCommittedAttemptCount, 1)
        XCTAssertTrue(episodes.gaps.contains(.observedAdmissionUnverified), "An unrequested finished callback is not an automated receipt")
        let started = try XCTUnwrap(added.first { $0.phase == .provisionalStart && $0.binding == .exactObservedNavigation })
        let finished = try XCTUnwrap(added.first { $0.phase == .documentFinished && $0.binding == .exactObservedNavigation })
        XCTAssertEqual(started.control, .automationAllowed)
        XCTAssertEqual(started.navigationCorrelationID, finished.navigationCorrelationID)
        XCTAssertNotNil(started.navigationCorrelationID)
        XCTAssertNil(started.attemptID); XCTAssertNil(finished.attemptID)
        XCTAssertEqual(after.attempts, before.attempts)
        XCTAssertNotEqual(after.identity, before.identity)
        XCTAssertEqual(finished.origin, try ComputerUseBrowserSourceOrigin(target))
        XCTAssertEqual(destination.count("/landed"), 1)
    }

    func testDispatchHistoryKeepsNativeOriginsAndThePolicyUsedByEachAttempt() async throws {
        let server = try OwnedBrowserHTTPFixture(), base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
        let origin = try ComputerUseBrowserSourceOrigin(base)
        let firstPolicy = try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [origin])
        try browser.installSourcePolicy(firstPolicy, replacing: nil, session: session)
        let empty = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertTrue(empty.attempts.isEmpty); XCTAssertFalse(empty.beganAfterAnotherClaim)
        let destination = try url(base.absoluteString + "/private-callback?code=secret-callback#private-fragment")
        let document = try await browser.navigate(taskID: input.taskID, operationID: "first", to: destination)
        let first = try browser.navigationDispatchHistory(taskID: input.taskID)
        let attempt = try XCTUnwrap(first.attempts.first)
        XCTAssertEqual(first.taskID, input.taskID); XCTAssertEqual(first.contextID, browser.contextID)
        XCTAssertEqual(attempt.operationID, "first"); XCTAssertEqual(attempt.generation, document.generation)
        XCTAssertEqual(attempt.requestedOrigin, origin); XCTAssertEqual(attempt.committedOrigin, origin)
        XCTAssertEqual(attempt.policy, firstPolicy); XCTAssertEqual(attempt.outcome, .documentCommitted)
        XCTAssertNotEqual(first.identity, empty.identity)
        let nextPolicy = try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [origin],
            excludedOrigins: [ComputerUseBrowserSourceOrigin(url("https://blocked.test"))])
        try browser.installSourcePolicy(nextPolicy, replacing: firstPolicy.digest, session: session)
        XCTAssertEqual(try browser.navigationDispatchHistory(taskID: input.taskID).attempts, first.attempts,
            "Installing a new policy cannot rewrite which policy governed earlier work")
        _ = try await browser.navigate(taskID: input.taskID, operationID: "second", to: base)
        let second = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertEqual(first.attempts, [attempt], "Returned history is an immutable value snapshot")
        XCTAssertEqual(second.attempts.map(\.policy), [firstPolicy, nextPolicy])
        XCTAssertNotEqual(first.identity, second.identity)
        XCTAssertEqual(second.attempts.first, attempt)
        for value in [String(reflecting: first), String(reflecting: attempt)] {
            for hidden in [input.taskID, "private-callback", "secret-callback", "private-fragment", base.absoluteString, firstPolicy.digest] {
                XCTAssertFalse(value.contains(hidden))
            }
        }
        XCTAssertThrowsError(try browser.navigationDispatchHistory(taskID: "foreign-task"))
    }

    func testDispatchHistoryRetainsCancellationAndFailureWithoutInventingCommitOrigins() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/held": .init(held: true), "/missing": .init(status: 404)])
        let base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal()
        try browser.claim(taskID: input.taskID)
        let work = Task { try await browser.navigate(taskID: input.taskID, operationID: "cancelled", to: base.appendingPathComponent("held")) }
        try await waitUntil {
            server.count("/held") == 1 && (try? browser.navigationDispatchHistory(taskID: input.taskID).observations.contains {
                $0.phase == .provisionalStart && $0.binding == .exactPendingNavigation
            }) == true
        }
        let pending = try browser.navigationDispatchHistory(taskID: input.taskID)
        let pendingEpisodes = ComputerUseBrowserResultAssessment.NavigationEpisodes(history: pending)
        XCTAssertEqual(pendingEpisodes.dispatchEpisodeCount, 1)
        XCTAssertTrue(pendingEpisodes.gaps.contains(.unfinishedEpisode))
        XCTAssertEqual(pending.attempts.first?.outcome, .pending)
        XCTAssertNil(pending.attempts.first?.committedOrigin)
        work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled navigation cannot return a document") } catch { }
        let cancelled = try browser.navigationDispatchHistory(taskID: input.taskID)
        let cancelledEpisodes = ComputerUseBrowserResultAssessment.NavigationEpisodes(history: cancelled)
        XCTAssertEqual(cancelledEpisodes.dispatchEpisodeCount, 1); XCTAssertEqual(cancelledEpisodes.matchedCommittedAttemptCount, 0)
        XCTAssertFalse(cancelledEpisodes.gaps.contains(.unfinishedEpisode), "Native cancellation closes its episode without inventing a didFinish callback")
        XCTAssertEqual(cancelled.attempts.first?.outcome, .ownershipLost)
        XCTAssertNil(cancelled.attempts.first?.committedOrigin)
        XCTAssertEqual(cancelled.attempts.first?.id, pending.attempts.first?.id)
        XCTAssertEqual(pending.attempts.first?.outcome, .pending)
        XCTAssertNotEqual(cancelled.identity, pending.identity)
        do { _ = try await browser.navigate(taskID: input.taskID, operationID: "failed", to: base.appendingPathComponent("missing")); XCTFail("HTTP failure cannot commit") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .navigationFailed) }
        let failed = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertEqual(failed.attempts.map(\.outcome), [.ownershipLost, .failed])
        XCTAssertTrue(failed.attempts.allSatisfy { $0.policy == nil && $0.committedOrigin == nil })
        XCTAssertTrue(failed.attempts.allSatisfy { $0.commitBasis == nil && $0.successfulResponseOrigin == nil })
        XCTAssertEqual(failed.attempts.map(\.requestedOrigin), [try ComputerUseBrowserSourceOrigin(base), try ComputerUseBrowserSourceOrigin(base)])
        XCTAssertNil(browser.receipt(taskID: input.taskID, operationID: "failed"))
        let rejectedResponse = try XCTUnwrap(failed.observations.first {
            $0.phase == .response && $0.attemptID == failed.attempts.last?.id && $0.decision == .cancelled
        })
        XCTAssertEqual(rejectedResponse.policyCheck, .notChecked, "HTTP failure is rejected before source policy assessment")
        XCTAssertEqual(rejectedResponse.binding, .pendingSlot)
    }

    func testDispatchHistoryRetainsATimedOutNativeAttempt() async throws {
        let server = try OwnedBrowserHTTPFixture(routes: ["/held": .init(held: true)]), base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, navigationTimeout: .milliseconds(250), mayAct: { true })
        defer { browser.close() }
        let input = try goal()
        try browser.claim(taskID: input.taskID)
        do { _ = try await browser.navigate(taskID: input.taskID, operationID: "timed-out", to: base.appendingPathComponent("held")); XCTFail("Held response must time out") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .deadlineExceeded) }
        let history = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertEqual(history.attempts.count, 1); XCTAssertEqual(history.attempts.first?.outcome, .timedOut)
        XCTAssertNil(history.attempts.first?.committedOrigin)
        XCTAssertTrue(browser.hasNavigationAttempt(operationID: "timed-out"))
    }

    func testDispatchHistorySurvivesSameTaskStopAndBrowserRecreationWithoutReusingAttemptIdentity() async throws {
        let server = try OwnedBrowserHTTPFixture(), base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
        let policy = try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [ComputerUseBrowserSourceOrigin(base)])
        try browser.installSourcePolicy(policy, replacing: nil, session: session)
        let originalDocument = try await browser.navigate(taskID: input.taskID, operationID: "same-id", to: base)
        let first = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertEqual(browser.confirmedNavigationAttempt(for: originalDocument), first.attempts.first)
        browser.stop()
        XCTAssertNil(browser.confirmedNavigationAttempt(for: originalDocument))
        XCTAssertThrowsError(try browser.navigationDispatchHistory(taskID: input.taskID))
        try browser.claim(taskID: input.taskID)
        let reclaimedDocument = try await browser.navigate(taskID: input.taskID, operationID: "same-id", to: base)
        let reclaimed = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertNil(browser.confirmedNavigationAttempt(for: originalDocument))
        XCTAssertEqual(browser.confirmedNavigationAttempt(for: reclaimedDocument), reclaimed.attempts.last)
        XCTAssertTrue(reclaimed.hasClaimBoundary); XCTAssertFalse(first.hasClaimBoundary)
        XCTAssertEqual(reclaimed.attempts.count, 2)
        XCTAssertEqual(reclaimed.attempts[0], first.attempts[0])
        XCTAssertEqual(reclaimed.attempts.map(\.operationID), ["same-id", "same-id"])
        XCTAssertNotEqual(reclaimed.attempts[0].id, reclaimed.attempts[1].id)
        XCTAssertNotEqual(reclaimed.attempts[0].ownershipEpoch, reclaimed.attempts[1].ownershipEpoch)
        XCTAssertEqual(reclaimed.attempts[0].sessionID, reclaimed.attempts[1].sessionID)
        XCTAssertNil(reclaimed.attempts[1].policy)
        browser.close(); try browser.claim(taskID: input.taskID)
        _ = try await browser.navigate(taskID: input.taskID, operationID: "after-close", to: base)
        let reopened = try browser.navigationDispatchHistory(taskID: input.taskID)
        let episodes = ComputerUseBrowserResultAssessment.NavigationEpisodes(history: reopened)
        XCTAssertEqual(episodes.dispatchEpisodeCount, 3)
        XCTAssertEqual(episodes.matchedCommittedAttemptCount, 3, "Reused operation text cannot merge distinct native callback identities")
        XCTAssertEqual(reopened.attempts.count, 3)
        XCTAssertEqual(Array(reopened.attempts.prefix(2)), reclaimed.attempts)
        XCTAssertNotEqual(reopened.attempts[1].sessionID, reopened.attempts[2].sessionID)
        XCTAssertNotEqual(reopened.identity, reclaimed.identity)
    }

    func testDispatchHistoryMakesDiscardedOtherClaimHistoryExplicit() async throws {
        let server = try OwnedBrowserHTTPFixture(), base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal()
        try browser.claim(taskID: input.taskID)
        _ = try await browser.navigate(taskID: input.taskID, operationID: "first", to: base)
        let original = try browser.navigationDispatchHistory(taskID: input.taskID)
        browser.stop(); try browser.claim(taskID: "another-task")
        let other = try browser.navigationDispatchHistory(taskID: "another-task")
        XCTAssertTrue(other.beganAfterAnotherClaim); XCTAssertTrue(other.attempts.isEmpty)
        XCTAssertNotEqual(other.identity, original.identity)
        XCTAssertThrowsError(try browser.navigationDispatchHistory(taskID: input.taskID))
        browser.stop(); try browser.claim(taskID: input.taskID)
        let returned = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertTrue(returned.beganAfterAnotherClaim); XCTAssertTrue(returned.attempts.isEmpty)
        XCTAssertNotEqual(returned.identity, original.identity)
        XCTAssertEqual(original.attempts.count, 1)
    }

    func testDispatchHistoryBoundsRepeatedClaimsWithoutSilentlyDroppingEarlierAttempts() async throws {
        let server = try OwnedBrowserHTTPFixture(), base = try await server.start()
        defer { server.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal()
        try browser.claim(taskID: input.taskID)
        for index in 0..<64 {
            _ = try await browser.navigate(taskID: input.taskID, operationID: "attempt-\(index)", to: base)
        }
        let full = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertEqual(full.attempts.count, 64); XCTAssertFalse(full.overflowed)
        browser.stop(); try browser.claim(taskID: input.taskID)
        let omitted = try await browser.navigate(taskID: input.taskID, operationID: "after-limit", to: base)
        XCTAssertNil(browser.confirmedNavigationAttempt(for: omitted), "A receipt cannot fabricate an omitted history attempt")
        let overflowed = try browser.navigationDispatchHistory(taskID: input.taskID)
        XCTAssertTrue(overflowed.overflowed); XCTAssertTrue(overflowed.hasClaimBoundary)
        XCTAssertEqual(overflowed.attempts, full.attempts)
        XCTAssertNotEqual(overflowed.identity, full.identity)
        XCTAssertTrue(browser.hasNavigationAttempt(operationID: "after-limit"))
        XCTAssertNotNil(browser.receipt(taskID: input.taskID, operationID: "after-limit"))
    }

    func testSourceOriginsKeepSchemeHostAndEffectivePortWithoutSuffixOrCredentialAliases() throws {
        let input = try goal(), origin = try ComputerUseBrowserSourceOrigin(url("https://EXAMPLE.test:443/path?private=value"))
        let policy = try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [origin])
        XCTAssertTrue(policy.permits(try url("https://example.test/other#fragment")))
        for raw in ["https://example.test.evil.test", "https://sub.example.test", "https://www.example.test", "http://example.test",
            "https://example.test:444", "https://example.test.", "https://user@example.test", "https://example.test@evil.test"] {
            XCTAssertFalse(policy.permits(try url(raw)))
        }
        let excluded = try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [origin], excludedOrigins: [origin])
        XCTAssertFalse(excluded.permits(try url("https://example.test")))
        let empty = try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [])
        XCTAssertFalse(empty.permits(try url("https://example.test")))
        let unrestricted = try ComputerUseBrowserSourcePolicy(goal: input)
        XCTAssertTrue(unrestricted.permits(try url("https://another.test")))
        XCTAssertNotEqual(empty.digest, unrestricted.digest)
        XCTAssertEqual(policy.digest, try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [origin, origin]).digest)
        let ipv6 = try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [ComputerUseBrowserSourceOrigin(url("http://[::1]"))])
        XCTAssertTrue(ipv6.permits(try url("http://[0:0:0:0:0:0:0:1]:80/path")))
        let excludingIPv4 = try ComputerUseBrowserSourcePolicy(goal: input, excludedOrigins: [ComputerUseBrowserSourceOrigin(url("http://127.0.0.1"))])
        for raw in ["http://127.1", "http://2130706433", "http://0x7f000001", "http://0177.0.0.1"] {
            XCTAssertFalse(excludingIPv4.permits(try url(raw)))
        }
        XCTAssertFalse(String(reflecting: origin).contains("example")); XCTAssertFalse(String(reflecting: policy).contains(input.taskID))
    }

    func testSourcePlanRejectsAProviderOutsideScopeAndBindsInitialSearchToPolicy() async throws {
        let input = try goal(), interpretation = try await BrowserResearchGoalFixture().propose(input)
        let provider = try ComputerUseBrowserSearchProvider(endpoint: url("https://search.test/search"), queryParameter: "q")
        let origin = try ComputerUseBrowserSourceOrigin(url("https://search.test")), other = try ComputerUseBrowserSourceOrigin(url("https://other.test"))
        XCTAssertThrowsError(try ComputerUseBrowserResearchSources(goal: input, provider: provider, allowedOrigins: [other]))
        XCTAssertThrowsError(try ComputerUseBrowserResearchSources(goal: input, provider: provider, excludedOrigins: [origin]))
        let sources = try ComputerUseBrowserResearchSources(goal: input, provider: provider, allowedOrigins: [origin])
        let query = try ComputerUseBrowserSearchQuery.decode(content: #"{"terms":[{"requirement":0,"text":"concerts"}]}"#, interpretation: interpretation)
        let old = try ComputerUseBrowserInitialSearchRequest(interpretation: interpretation, query: query, provider: provider)
        let current = try ComputerUseBrowserInitialSearchRequest(interpretation: interpretation, query: query, provider: provider, sourcePolicy: sources.policy)
        XCTAssertEqual(old.destination, current.destination); XCTAssertNotEqual(old.digest, current.digest)
        let foreign = try ComputerUseBrowserSourcePolicy(goal: goal(id: "foreign"), allowedOrigins: [origin])
        XCTAssertThrowsError(try ComputerUseBrowserInitialSearchRequest(interpretation: interpretation, query: query, provider: provider, sourcePolicy: foreign))
    }

    func testNativeSourcePolicyStopsBeforeDispatchAndRejectsChangedPolicyAtTheEffectBoundary() async throws {
        let first = try OwnedBrowserHTTPFixture(), second = try OwnedBrowserHTTPFixture()
        let base = try await first.start(), outside = try await second.start()
        defer { first.stop(); second.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
        let policy = try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [ComputerUseBrowserSourceOrigin(base)])
        try browser.installSourcePolicy(policy, replacing: nil, session: session)
        var callbacks = 0
        do { _ = try await browser.navigate(taskID: input.taskID, operationID: "outside", to: outside, willBeginEffect: { callbacks += 1 }); XCTFail("Outside source cannot reach dispatch admission") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .sourceNotAllowed) }
        XCTAssertEqual(callbacks, 0); XCTAssertEqual(second.requestCount, 0); XCTAssertFalse(browser.hasNavigationAttempt(operationID: "outside"))
        XCTAssertTrue(try browser.navigationDispatchHistory(taskID: input.taskID).attempts.isEmpty)
        let replacement = try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [])
        do {
            _ = try await browser.navigate(taskID: input.taskID, operationID: "changed", to: base, willBeginEffect: {
                callbacks += 1; try browser.installSourcePolicy(replacement, replacing: policy.digest, session: session)
            })
            XCTFail("The captured policy cannot change before native load")
        } catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
        XCTAssertEqual(callbacks, 1); XCTAssertEqual(first.requestCount, 0); XCTAssertFalse(browser.hasNavigationAttempt(operationID: "changed"))
        XCTAssertTrue(try browser.navigationDispatchHistory(taskID: input.taskID).attempts.isEmpty)
        XCTAssertThrowsError(try browser.installSourcePolicy(policy, replacing: nil, session: session))
        try browser.installSourcePolicy(policy, replacing: replacement.digest, session: session)
        browser.stop(); try browser.claim(taskID: "next-task")
        XCTAssertThrowsError(try browser.installSourcePolicy(policy, replacing: nil, session: session))
        _ = try await browser.navigate(taskID: "next-task", operationID: "next", to: outside)
        XCTAssertEqual(second.requestCount, 1, "A new task does not inherit the retired task's source policy")
    }

    func testSourcePolicyChecksRedirectDestinationsAndCannotReplayABlockedAttempt() async throws {
        for includeDestination in [false, true] {
            let destination = try OwnedBrowserHTTPFixture(), target = try await destination.start()
            let start = try OwnedBrowserHTTPFixture(routes: ["/first": .init(status: 302, location: "/second"),
                "/second": .init(status: 302, location: target.appendingPathComponent("result").absoluteString)])
            let base = try await start.start()
            defer { start.stop(); destination.stop() }
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
            defer { browser.close() }
            let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
            var origins = [try ComputerUseBrowserSourceOrigin(base)]
            if includeDestination { origins.append(try ComputerUseBrowserSourceOrigin(target)) }
            try browser.installSourcePolicy(.init(goal: input, allowedOrigins: origins), replacing: nil, session: session)
            do {
                let document = try await browser.navigate(taskID: input.taskID, operationID: "redirect", to: base.appendingPathComponent("first"))
                XCTAssertTrue(includeDestination); XCTAssertEqual(document.committedURL, target.appendingPathComponent("result"))
            } catch { XCTAssertFalse(includeDestination); XCTAssertEqual(error as? ComputerUseBrowserError, .sourceNotAllowed) }
            XCTAssertEqual(start.count("/first"), 1); XCTAssertEqual(start.count("/second"), 1)
            XCTAssertEqual(destination.count("/result"), includeDestination ? 1 : 0)
            XCTAssertTrue(browser.hasNavigationAttempt(operationID: "redirect"))
            let history = try browser.navigationDispatchHistory(taskID: input.taskID)
            XCTAssertEqual(history.attempts.count, 1)
            XCTAssertEqual(history.attempts.first?.requestedOrigin, try ComputerUseBrowserSourceOrigin(base))
            XCTAssertEqual(history.attempts.first?.outcome, includeDestination ? .documentCommitted : .sourceBlocked)
            XCTAssertEqual(history.attempts.first?.committedOrigin, includeDestination ? try ComputerUseBrowserSourceOrigin(target) : nil)
            if !includeDestination { XCTAssertNil(browser.receipt(taskID: input.taskID, operationID: "redirect")) }
            do { _ = try await browser.navigate(taskID: input.taskID, operationID: "redirect", to: base.appendingPathComponent("first")); XCTFail("A blocked redirect still attempted its first request") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            XCTAssertEqual(start.count("/first"), 1)
        }
    }

    func testObservedLinkAndFormQueryBindingsIncludeTheCurrentSourcePolicy() async throws {
        for isQuery in [false, true] {
            let server = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body:
                "<a href='/target'>Details</a><form action='/query' method='get'><input name='q' value='tickets'><button type='submit'>Search</button></form>")])
            let base = try await server.start()
            defer { server.stop() }
            let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
            defer { browser.close() }
            let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
            let document = try await browser.navigate(taskID: input.taskID, operationID: "page", to: base.appendingPathComponent("page"))
            func prepare() async throws -> ComputerUseBrowserNavigationTarget {
                let evidence = try await browser.observePage(document: document)
                if isQuery {
                    let submit = try XCTUnwrap(evidence.page.controls.first { $0.kind == "submit" })
                    return try await browser.prepareFormQuery(controlID: submit.id, evidence: evidence)
                }
                return try await browser.prepareLinkNavigation(linkID: XCTUnwrap(evidence.page.links.first?.id), evidence: evidence)
            }
            let old = try await prepare(), policy = try ComputerUseBrowserSourcePolicy(goal: input, allowedOrigins: [ComputerUseBrowserSourceOrigin(base)])
            try browser.installSourcePolicy(policy, replacing: nil, session: session)
            do { try await browser.validateObservedDestination(old); XCTFail("An earlier policy is part of the old target binding") }
            catch { XCTAssertEqual(error as? ComputerUseBrowserError, .pageChanged) }
            let current = try await prepare()
            XCTAssertNotEqual(current.payloadDigest, old.payloadDigest)
            _ = try await browser.openObservedDestination(current, operationID: ComputerUseTaskContract.digest(["scoped-target"]))
            XCTAssertEqual(server.count(isQuery ? "/query?q=tickets" : "/target"), 1)
        }
    }

    func testResearchDriverRetainsItsSourcePlanAndRejectsOutsideProviderOrSelectedLink() async throws {
        let outsideServer = try OwnedBrowserHTTPFixture(), outside = try await outsideServer.start()
        defer { outsideServer.stop() }
        for providerOutside in [false, true] {
            let fixture = try await ResearchDriverFixture.make(linkDestinationOverride: outside.appendingPathComponent("offer").absoluteString)
            defer { fixture.close() }
            fixture.policy.choices = [true, true]
            fixture.policy.allowedOrigins = [try ComputerUseBrowserSourceOrigin(providerOutside ? outside : fixture.base)]
            let result = try await fixture.start()
            guard case .userInterventionRequired? = result else { return XCTFail("Source failure must retain the complete task") }
            let owner = try fixture.owner(), original = owner.input
            XCTAssertEqual(fixture.server.count("/search?q=concerts"), providerOutside ? 0 : 1)
            XCTAssertEqual(outsideServer.requestCount, 0); XCTAssertFalse(owner.hasPendingNavigation)
            if !providerOutside {
                fixture.policy.allowedOrigins?.append(try ComputerUseBrowserSourceOrigin(outside))
                owner.pause(); try await owner.resumeAfterUserControl()
                _ = try await fixture.resume()
                XCTAssertEqual(owner.input, original); XCTAssertEqual(fixture.policy.providerCalls, 1)
                XCTAssertEqual(fixture.search.inputs.count, 1); XCTAssertEqual(outsideServer.requestCount, 0)
            }
        }
    }

    func testOwnerPolicyCannotChangeAnAcceptedRevisionOrReplacePendingWork() async throws {
        let fixture = try await ResearchDriverFixture.make(seedPage: true)
        defer { fixture.close() }
        try await fixture.pauseInitialSearch()
        let owner = try fixture.owner(), original = owner.input
        try await owner.resumeAfterUserControl()
        XCTAssertThrowsError(try owner.configureSourcePolicy(.init(goal: original)))
        _ = try await fixture.resume()
        XCTAssertThrowsError(try owner.configureSourcePolicy(.init(goal: original, allowedOrigins: []))) {
            XCTAssertEqual($0 as? ComputerUseBrowserResearchTask.Failure, .goalChanged)
        }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true }), planner = BrowserResearchGoalFixture()
        defer { browser.close() }
        planner.questionTopic = .location
        let unanswered = ComputerUseBrowserResearchTask(input: try goal(id: "question"), browser: browser,
            goalPlanner: planner, resultPlanner: BrowserResearchResultFixture(), mayAct: { true })
        let interpretation = try await unanswered.interpretGoal()
        let before = try ComputerUseBrowserSourcePolicy(goal: unanswered.input)
        try unanswered.configureSourcePolicy(before)
        let question = try unanswered.issueQuestion(topic: .location, requirementIDs: [interpretation.proposal.requirements[0].id], controllerID: "phone", controllerSessionID: "session")
        _ = try unanswered.answerQuestion(questionID: question.id, answerTaskID: "answer", answer: "Paris", controllerID: "phone", controllerSessionID: "session")
        XCTAssertThrowsError(try unanswered.configureSourcePolicy(before))
        try unanswered.configureSourcePolicy(.init(goal: unanswered.input, allowedOrigins: []))
        XCTAssertFalse(browser.hasSession, "Policy selection alone must not allocate a browser")
        unanswered.retire()
        XCTAssertThrowsError(try unanswered.configureSourcePolicy(.init(goal: unanswered.input)))
    }

    func testSourcePolicyAllowsManualLoginOutsideScopeButOnlyUsesAllowedResultsAfterHandback() async throws {
        let loginScript = "fetch('/finish').then(() => location.href = decodeURIComponent(location.hash.slice(1)));"
        let login = try OwnedBrowserHTTPFixture(routes: ["/login": .init(body: "<input type='password'><script>\(loginScript)</script>"), "/finish": .init(held: true)])
        let loginBase = try await login.start()
        let enterScript = "fetch('/enter').then(() => location.href = '\(loginBase.absoluteString)/login#' + encodeURIComponent(location.origin + '/account'));"
        let card = "<article><h2>Concert Alpha</h2><a href='/offer'>Alpha details</a></article>"
        let server = try OwnedBrowserHTTPFixture(routes: ["/search?q=concerts": .init(body: card + "<script>\(enterScript)</script>"),
            "/enter": .init(held: true), "/account": .init(body: card)])
        let base = try await server.start(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { server.stop(); login.stop(); try? FileManager.default.removeItem(at: directory) }
        var allowed = true
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { allowed })
        let coordinator = ComputerUseBrowserNavigationTask(browser: browser, journalDirectory: directory)
        defer { coordinator.close() }
        let tools = ComputerUseHostTools(injector: InputInjector(), mayAct: { allowed }, browserNavigationTask: coordinator)
        let policy = DriverPlanningFixture(provider: try .init(endpoint: base.appendingPathComponent("search"), queryParameter: "q"))
        policy.allowedOrigins = [try ComputerUseBrowserSourceOrigin(base)]
        let results = BrowserResearchResultFixture(), search = DriverSearchFixture()
        results.selectedLinkLabel = "Alpha details"
        let driver = ComputerUseBrowserResearchDriver(goalPlanner: DriverGoalFixture(), resultPlanner: results, searchPlanner: search, actionPlanner: BrowserResearchActionFixture(), formPlanner: BrowserResearchFormFixture(),
            planning: policy, now: { ResearchDriverFixture.date }, timeZoneIdentifier: { "America/Los_Angeles" })
        _ = try await driver.executeBrowserResearch(taskID: "login-policy", prompt: ResearchDriverFixture.prompt, tools: tools, progress: { _ in })
        let owner = try XCTUnwrap(tools.ownedBrowserResearch(taskID: "login-policy")), original = owner.input
        let beforeLogin = try browser.navigationDispatchHistory(taskID: owner.taskID)
        try await waitUntil { server.count("/enter") == 1 }
        owner.pause(); allowed = false; server.releaseHeldResponses()
        try await waitUntil { login.count("/finish") == 1 && browser.hasPageAwaitingHandback }
        let readings = results.inputs.count
        allowed = true
        do { try await owner.resumeAfterUserControl(); XCTFail("The login page still requires manual control") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserError, .authenticationRequired) }
        do { _ = try await driver.continueBrowserResearch(taskID: owner.executionTaskID, research: owner, tools: tools, progress: { _ in }); XCTFail("No implicit handback") }
        catch { XCTAssertEqual(error as? ComputerUseBrowserResearchTask.Failure, .paused) }
        XCTAssertEqual(results.inputs.count, readings)
        allowed = false; login.releaseHeldResponses()
        try await waitUntil { server.count("/account") == 1 && browser.hasPageAwaitingHandback }
        allowed = true; try await owner.resumeAfterUserControl()
        _ = try await driver.continueBrowserResearch(taskID: owner.executionTaskID, research: owner, tools: tools, progress: { _ in })
        XCTAssertEqual(owner.input, original); XCTAssertEqual(search.inputs.count, 1)
        XCTAssertEqual(server.count("/search?q=concerts"), 1); XCTAssertEqual(results.inputs.count, readings + 1)
        let afterLogin = try browser.navigationDispatchHistory(taskID: owner.taskID)
        XCTAssertEqual(afterLogin.attempts, beforeLogin.attempts, "Manual sign-in navigation is not an automated dispatch receipt")
        let loginOrigin = try ComputerUseBrowserSourceOrigin(loginBase)
        let manual = try XCTUnwrap(afterLogin.observations.first {
            $0.phase == .navigationAction && $0.origin == loginOrigin && $0.decision == .allowed
        })
        XCTAssertEqual(manual.control, .userControl); XCTAssertEqual(manual.policyCheck, .notChecked)
        XCTAssertNil(manual.attemptID)
        XCTAssertNotNil(manual.configuredPolicy, "A configured task policy is not automatically applied to a human's login")
    }

    func testSourcePolicyBlocksScriptedHistoryToAnEarlierOutsidePage() async throws {
        let earlier = try OwnedBrowserHTTPFixture(), outside = try await earlier.start()
        let script = "fetch('/signal').then(() => history.back());"
        let current = try OwnedBrowserHTTPFixture(routes: ["/page": .init(body: "<h1>Allowed page</h1><script>\(script)</script>"), "/signal": .init(held: true)])
        let base = try await current.start()
        defer { current.stop(); earlier.stop() }
        let browser = ComputerUseOwnedBrowser(presentsWindow: false, mayAct: { true })
        defer { browser.close() }
        let input = try goal(), session = try browser.prepareWorkflowSession(taskID: input.taskID)
        _ = try await browser.navigate(taskID: input.taskID, operationID: "earlier", to: outside)
        let document = try await browser.navigate(taskID: input.taskID, operationID: "current", to: base.appendingPathComponent("page"))
        try browser.installSourcePolicy(.init(goal: input, allowedOrigins: [ComputerUseBrowserSourceOrigin(base)]), replacing: nil, session: session)
        try await waitUntil { current.count("/signal") == 1 }
        current.releaseHeldResponses()
        try await waitUntil { browser.detail == "Blocked a page outside this task's allowed sources." }
        if let retained = browser.currentDocument(taskID: input.taskID) {
            try browser.validateSourceDocument(retained)
            XCTAssertEqual(retained.committedURL, document.committedURL)
        }
        XCTAssertEqual(earlier.requestCount, 1)
        let history = try browser.navigationDispatchHistory(taskID: input.taskID)
        let outsideOrigin = try ComputerUseBrowserSourceOrigin(outside)
        XCTAssertTrue(history.observations.contains {
            [.historyRequest, .navigationAction].contains($0.phase) && $0.origin == outsideOrigin
                && $0.decision == .cancelled && $0.policyCheck == .blocked && $0.attemptID == nil
        })
    }

    private func goal(id: String = "source-policy") throws -> ComputerUseBrowserGoalInput {
        try .init(taskID: id, prompt: ResearchDriverFixture.prompt, referenceDate: ResearchDriverFixture.date, timeZoneIdentifier: "America/Los_Angeles")
    }
    private func url(_ raw: String) throws -> URL { try XCTUnwrap(URL(string: raw)) }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw FixtureFailure.timeout }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    private enum FixtureFailure: Error { case timeout }
}
